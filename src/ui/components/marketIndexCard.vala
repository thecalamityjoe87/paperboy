/*
 * Copyright (C) 2025  Isaac Joseph <calamityjoe87@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

using Gtk;
using GLib;
using Cairo;

/**
 * A single market index card for the Stocks ticker section, styled after
 * PodcastHeroCard - a neutral background with a soft directional glow
 * (standing in for cover art, since a market index has no image) behind a
 * trend line, the white price/arrow badge pinned to the top corner, and a
 * bottom-pinned dark scrim holding the index name/change.
 *
 * StocksTickerController builds one of these per symbol and keeps reusing
 * it across polls via update() rather than rebuilding from scratch each
 * time - repeatedly destroying/recreating this card's Overlay+ScrolledWindow
 * (nested inside CategorySection)-plus-EventControllerMotion combination
 * (see ScrollNavButtons) was found to leak memory, a GTK4 quirk unrelated
 * to anything this card itself draws or holds onto.
 */
public class MarketIndexCard : GLib.Object {
    public Gtk.Box root;

    private Gtk.Box background;
    private Gtk.DrawingArea graph;
    private Gtk.DrawingArea arrow;
    private Gtk.Label price_label;
    private Gtk.Label change_label;
    private Gtk.Label updated_label;
    private Gtk.Label hover_label;
    private string symbol;

    // Real intraday samples from the backend's own history endpoint, and
    // the pixel positions draw_graph() last plotted them at - kept in sync
    // so the hover handler can map a cursor X back to the nearest real
    // (time, price) sample instead of guessing. Null while there isn't
    // enough real history yet (see draw_graph()'s fallback path), or for
    // a symbol the history endpoint doesn't cover (crypto - it only knows
    // the five fixed indices).
    private Gee.ArrayList<MarketIndexHistoryPoint>? history_points = null;
    // The exact points list drawn_xs/drawn_ys were computed from - a fetch
    // can replace history_points with a differently-sized list at any
    // time, but drawn_xs/drawn_ys only update on the next actual
    // draw_graph() call. on_graph_hover() must index into this snapshot,
    // not the (possibly newer/smaller) history_points, or it can read out
    // of bounds in the window between a fetch landing and the next redraw.
    private Gee.ArrayList<MarketIndexHistoryPoint>? drawn_points = null;
    private double[]? drawn_xs = null;
    private double[]? drawn_ys = null;
    private int graph_width = 0;
    // Index into history_points/drawn_xs/drawn_ys currently under the
    // cursor, or -1 - lets draw_graph() paint a dot/guide line on the
    // curve so hovering has a visible "you are here" indicator, since the
    // hover zone doesn't visually match the card's edges (see
    // on_graph_hover()).
    private int hovered_index = -1;
    // Bumped on every fetch_history() call so a slower, older request that
    // resolves after a newer one can't clobber it with stale data.
    private uint history_request_id = 0;

    // size: matches PodcastHeroCard's own square sizing (its `max_total_height`,
    // computed by the caller from the available content width) so these read
    // as the same visual size as the Podcasts page's hero cards.
    public MarketIndexCard(MarketIndexQuote quote, int size) {
        GLib.Object();

        symbol = quote.symbol;
        bool positive = quote.change >= 0;

        root = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        // Not ".card" - that class's own background-color showed through
        // behind this card's rounded corners (GTK4 doesn't clip children to
        // a parent's border-radius, so the flat-colored background below
        // only rounds itself, not what's behind it). ".ticker-card-hero"
        // provides the same border/radius/hover treatment without a
        // background to peek through.
        root.add_css_class("ticker-card-hero");
        // hexpand off, like ScoreCard: this sits in CategorySection's plain
        // Gtk.Box row (not a FlowBox/homogeneous hero_container cell), where
        // hexpand would bubble up and stretch the row instead of just
        // sizing this card.
        root.set_hexpand(false);
        root.set_halign(Gtk.Align.START);
        root.set_size_request(size, size);

        background = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        // Direction-tinted, but as a soft spotlight glow (see the CSS radial
        // gradient) rather than a flat solid fill across the whole card.
        background.add_css_class(positive ? "ticker-card-art-positive" : "ticker-card-art-negative");
        background.set_hexpand(true);
        background.set_vexpand(true);
        background.set_halign(Gtk.Align.FILL);
        background.set_valign(Gtk.Align.FILL);

        var overlay = new Gtk.Overlay();
        overlay.set_child(background);
        overlay.set_hexpand(true);
        overlay.set_vexpand(true);
        overlay.set_size_request(size, size);

        // Trend line behind everything else, from the backend's real
        // intraday history endpoint - falls back to a stylized per-symbol
        // squiggle until that fetch resolves, or for a symbol it doesn't
        // cover (crypto). See draw_graph()'s comment.
        if (is_chartable_symbol(symbol)) fetch_history();
        graph = new Gtk.DrawingArea();
        graph.set_hexpand(true);
        graph.set_vexpand(true);
        graph.set_draw_func((area, cr, width, height) => draw_graph(cr, width, height, positive));
        overlay.add_overlay(graph);

        // Attached to the whole overlay, not just `graph` - the bottom
        // scrim (title_box, added below) and other overlay siblings sit on
        // top of the graph in z-order, and a controller on `graph` alone
        // would go dead the moment the cursor crossed onto one of them
        // (e.g. whenever the traced line dips into the scrim's region).
        // A parent-level controller keeps receiving motion regardless of
        // which child is topmost at the pointer.
        var hover_motion = new Gtk.EventControllerMotion();
        hover_motion.motion.connect((x, y) => on_graph_hover(x));
        hover_motion.leave.connect(() => {
            hovered_index = -1;
            hover_label.set_visible(false);
            graph.queue_draw();
        });
        overlay.add_controller(hover_motion);

        // Price + direction arrow, pinned to the top-right corner.
        var price_badge = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 4);
        price_badge.add_css_class("ticker-card-price-badge");
        price_badge.set_halign(Gtk.Align.END);
        price_badge.set_valign(Gtk.Align.START);
        price_badge.set_margin_end(10);
        price_badge.set_margin_top(10);

        // A drawn triangle rather than a themed icon (e.g. "go-up-symbolic")
        // - those are thin navigation glyphs that read poorly at this size
        // and vary across icon themes. A solid triangle is unambiguous and
        // looks the same everywhere.
        arrow = new Gtk.DrawingArea();
        arrow.set_content_width(9);
        arrow.set_content_height(9);
        arrow.set_valign(Gtk.Align.CENTER);
        arrow.set_draw_func((area, cr, width, height) => draw_arrow_triangle(cr, width, height, positive));
        price_badge.append(arrow);

        price_label = new Gtk.Label("");
        price_label.add_css_class("ticker-card-price");
        price_badge.append(price_label);

        overlay.add_overlay(price_badge);

        // Bottom-pinned scrim, same fixed-fraction-of-height approach as
        // PodcastHeroCard - see its own comment for why.
        int scrim_height = (int) (size * 0.55);
        var title_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        title_box.add_css_class("hero-podcast-scrim");
        title_box.set_hexpand(true);
        title_box.set_vexpand(false);
        title_box.set_halign(Gtk.Align.FILL);
        title_box.set_valign(Gtk.Align.END);
        title_box.set_size_request(-1, scrim_height);

        var text_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
        text_box.set_margin_start(12);
        text_box.set_margin_end(12);
        text_box.set_margin_bottom(12);
        text_box.set_valign(Gtk.Align.END);
        text_box.set_vexpand(true);
        title_box.append(text_box);

        var name_label = new Gtk.Label(quote.display_name);
        name_label.add_css_class("hero-title");
        name_label.add_css_class("ticker-card-hero-title");
        name_label.set_xalign(0);
        name_label.set_ellipsize(Pango.EllipsizeMode.END);
        text_box.append(name_label);

        change_label = new Gtk.Label("");
        change_label.add_css_class("hero-podcast-author");
        change_label.set_xalign(0);
        change_label.set_ellipsize(Pango.EllipsizeMode.END);
        text_box.append(change_label);

        overlay.add_overlay(title_box);

        // "Updated Xm ago", pinned to the bottom-right corner (added after
        // title_box so it layers on top of the scrim, matching how the
        // price badge already sits above everything at the top-right).
        // Always created (even if initially empty/hidden) so update() can
        // just change its text/visibility later without touching the
        // overlay's children.
        updated_label = new Gtk.Label("");
        updated_label.add_css_class("ticker-card-updated");
        updated_label.set_halign(Gtk.Align.END);
        updated_label.set_valign(Gtk.Align.END);
        updated_label.set_margin_end(12);
        updated_label.set_margin_bottom(12);
        overlay.add_overlay(updated_label);

        // Floating readout shown while hovering the trend line - see
        // on_graph_hover(). Positioned via margin_start, tracking the
        // cursor horizontally; hidden whenever there's no real history to
        // report a value from.
        hover_label = new Gtk.Label("");
        hover_label.add_css_class("ticker-card-hover-label");
        hover_label.set_halign(Gtk.Align.START);
        hover_label.set_valign(Gtk.Align.START);
        hover_label.set_margin_top(10);
        hover_label.set_visible(false);
        overlay.add_overlay(hover_label);

        root.append(overlay);

        apply_quote_text(quote);
    }

    // Refresh this card's price/change/updated text and direction in place -
    // no widgets are created or destroyed, so this can be called every poll
    // without the rebuild-from-scratch leak described in the class doc.
    public void update(MarketIndexQuote quote) {
        bool positive = quote.change >= 0;

        background.remove_css_class("ticker-card-art-positive");
        background.remove_css_class("ticker-card-art-negative");
        background.add_css_class(positive ? "ticker-card-art-positive" : "ticker-card-art-negative");

        // Direction can flip between polls near breakeven - reset the draw
        // funcs (cheap: just swapping the callback, not rebuilding widgets)
        // so the trend line/arrow reflect it. Re-fetch history on the same
        // cadence this is called on (StocksTickerController's own poll) -
        // no separate timer needed.
        if (is_chartable_symbol(symbol)) fetch_history();
        graph.set_draw_func((area, cr, width, height) => draw_graph(cr, width, height, positive));
        arrow.set_draw_func((area, cr, width, height) => draw_arrow_triangle(cr, width, height, positive));
        graph.queue_draw();
        arrow.queue_draw();

        apply_quote_text(quote);
    }

    private void apply_quote_text(MarketIndexQuote quote) {
        bool positive = quote.change >= 0;
        string sign = positive ? "+" : "";

        price_label.set_text("$%.2f".printf(quote.price));
        change_label.set_text("%s%.2f (%s%.2f%%)".printf(sign, quote.change, sign, quote.change_percent));

        string updated = DateUtils.time_ago(quote.last_updated);
        updated_label.set_text(updated.length > 0 ? "Updated " + updated : "");
        updated_label.set_visible(updated.length > 0);
    }

    private static bool is_index_symbol(string symbol) {
        switch (symbol) {
            case "SPY": case "DIA": case "QQQ": case "VIXY": case "IWM": return true;
            default: return false;
        }
    }

    // Only the five fixed indices and BTC have real history behind them -
    // the history endpoints 404 for anything else.
    private static bool is_chartable_symbol(string symbol) {
        return is_index_symbol(symbol) || symbol == "BINANCE:BTCUSDT";
    }

    private void fetch_history() {
        uint my_id = ++history_request_id;
        MarketIndicesService.HistoryCallback on_result = (history) => {
            if (my_id != history_request_id) return; // superseded by a newer fetch
            history_points = (history != null && history.points.size >= 2) ? history.points : null;
            graph.queue_draw();
        };
        if (is_index_symbol(symbol)) {
            MarketIndicesService.fetch_history(symbol, (owned) on_result);
        } else {
            MarketIndicesService.fetch_crypto_history(symbol, (owned) on_result);
        }
    }

    // Draws the real trend line from the backend's intraday history once
    // there are at least 2 points, mapping elapsed time to X and price to
    // Y; drawn_xs/history_points are kept in sync so on_graph_hover() can
    // map a cursor position back to a real sample. Falls back to the old
    // decorative squiggle (draw_fallback_trend_line) when there's no real
    // history yet - e.g. right after launch, before the fetch resolves,
    // or before the market has produced any points yet today.
    private void draw_graph(Cairo.Context cr, int width, int height, bool positive) {
        if (width <= 0 || height <= 0) return;
        graph_width = width;

        if (history_points == null || history_points.size < 2) {
            drawn_xs = null;
            drawn_points = null;
            draw_fallback_trend_line(cr, width, height, symbol, positive);
            return;
        }

        int n = history_points.size;
        double min_price = double.MAX;
        double max_price = -double.MAX;
        foreach (var p in history_points) {
            if (p.price < min_price) min_price = p.price;
            if (p.price > max_price) max_price = p.price;
        }
        double range = max_price - min_price;
        if (range < 0.0001) range = 1.0;

        double t0 = history_points[0].t;
        double span = history_points[n - 1].t - t0;
        if (span <= 0) span = 1;

        double margin = height * 0.22;
        double usable_h = height - margin * 2;

        var xs = new double[n];
        var ys = new double[n];
        for (int i = 0; i < n; i++) {
            var p = history_points[i];
            double tx = (p.t - t0) / span;
            xs[i] = tx * width;
            double norm = (p.price - min_price) / range;
            ys[i] = margin + (1.0 - norm) * usable_h; // higher price -> higher on screen
        }
        drawn_xs = xs;
        drawn_ys = ys;
        drawn_points = history_points;

        cr.set_line_width(2.5);
        cr.set_source_rgba(1, 1, 1, 0.55);
        cr.move_to(xs[0], ys[0]);
        for (int i = 1; i < n; i++) cr.line_to(xs[i], ys[i]);
        cr.stroke();

        // "You are here" indicator on the traced point - a vertical guide
        // plus a dot on the curve itself, so hovering has clear visual
        // feedback regardless of where on the card the cursor actually is.
        if (hovered_index >= 0 && hovered_index < n) {
            double hx = xs[hovered_index];
            double hy = ys[hovered_index];

            cr.set_line_width(1.0);
            cr.set_source_rgba(1, 1, 1, 0.35);
            cr.move_to(hx, 0);
            cr.line_to(hx, height);
            cr.stroke();

            cr.arc(hx, hy, 4.0, 0, 2 * Math.PI);
            cr.set_source_rgba(1, 1, 1, 1.0);
            cr.fill();
        }
    }

    // Called on every pointer-motion event over the card while real
    // history is available - finds the sample nearest the cursor's X,
    // marks it as the current hover point (draw_graph() paints the dot/
    // guide line for it), and shows its real price/time in the floating
    // hover label, positioned right above the dot rather than fixed in a
    // corner. No-ops (hides the label) while only the decorative fallback
    // line is showing, since there's no real value to report there.
    private void on_graph_hover(double x) {
        if (drawn_xs == null || drawn_ys == null || drawn_points == null || drawn_xs.length == 0
            || drawn_xs.length != drawn_points.size) {
            hovered_index = -1;
            hover_label.set_visible(false);
            return;
        }

        int nearest = 0;
        double best_dist = double.MAX;
        for (int i = 0; i < drawn_xs.length; i++) {
            double d = Math.fabs(drawn_xs[i] - x);
            if (d < best_dist) {
                best_dist = d;
                nearest = i;
            }
        }
        hovered_index = nearest;
        graph.queue_draw();

        var p = drawn_points[nearest];
        // Indices: always Eastern, regardless of the viewer's own timezone
        // - that's the actual trading session (9:30am-4:00pm ET) this data
        // reflects. Crypto: always UTC, since its day resets at UTC
        // midnight (it trades 24/7, so there's no "market timezone" the
        // way there is for the indices).
        string zone_label;
        GLib.DateTime dt;
        if (is_index_symbol(symbol)) {
            var et = new GLib.TimeZone("America/New_York");
            dt = new GLib.DateTime.from_unix_utc((int64) p.t).to_timezone(et);
            zone_label = "ET";
        } else {
            dt = new GLib.DateTime.from_unix_utc((int64) p.t);
            zone_label = "UTC";
        }
        hover_label.set_text("$%.2f · %s %s".printf(p.price, dt.format("%-I:%M %p"), zone_label));
        hover_label.set_visible(true);

        int label_width = hover_label.get_allocated_width();
        int label_height = hover_label.get_allocated_height();
        int target_x = (int) drawn_xs[nearest] - label_width / 2;
        int max_start_x = int.max(4, graph_width - label_width - 4);
        hover_label.set_margin_start(int.max(4, int.min(target_x, max_start_x)));

        int target_y = (int) drawn_ys[nearest] - label_height - 12;
        hover_label.set_margin_top(int.max(4, target_y));
    }

    // Deterministic per-symbol squiggle whose overall slope follows today's
    // direction - decoration for when there's no real history yet (see
    // draw_graph()'s comment above).
    private static void draw_fallback_trend_line(Cairo.Context cr, int width, int height, string symbol, bool positive) {
        if (width <= 0 || height <= 0) return;

        uint32 seed = 0;
        foreach (var c in symbol.data) seed = seed * 31 + c;
        var rand = new GLib.Rand.with_seed(seed);

        const int POINTS = 7;
        double[] xs = new double[POINTS];
        double[] ys = new double[POINTS];
        double margin = height * 0.22;
        double usable_h = height - margin * 2;

        for (int i = 0; i < POINTS; i++) {
            double t = (double) i / (POINTS - 1);
            xs[i] = t * width;
            // Overall slope follows the day's direction, with small
            // per-point noise so it reads as a real chart line.
            double trend = positive ? (1.0 - t) : t;
            double noise = rand.double_range(-0.12, 0.12);
            double v = trend + noise;
            if (v < 0) v = 0;
            if (v > 1) v = 1;
            ys[i] = margin + v * usable_h;
        }

        cr.set_line_width(2.5);
        cr.set_source_rgba(1, 1, 1, 0.35);
        cr.move_to(xs[0], ys[0]);
        for (int i = 1; i < POINTS; i++) {
            cr.line_to(xs[i], ys[i]);
        }
        cr.stroke();
    }

    // Solid up/down triangle for the price badge - see the arrow's own
    // comment above for why this is drawn rather than a themed icon.
    private static void draw_arrow_triangle(Cairo.Context cr, int width, int height, bool positive) {
        double w = width;
        double h = height;
        cr.set_source_rgba(1, 1, 1, 1);
        if (positive) {
            cr.move_to(w * 0.5, 0);
            cr.line_to(w, h);
            cr.line_to(0, h);
        } else {
            cr.move_to(0, 0);
            cr.line_to(w, 0);
            cr.line_to(w * 0.5, h);
        }
        cr.close_path();
        cr.fill();
    }
}
