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
    private string symbol;

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

        // Illustrative trend line behind everything else - the backend only
        // exposes the current quote, not a price history, so this is a
        // stylized visual cue for the day's direction, not real historical
        // data. Deterministic per symbol so it doesn't reshuffle every poll.
        graph = new Gtk.DrawingArea();
        graph.set_hexpand(true);
        graph.set_vexpand(true);
        graph.set_draw_func((area, cr, width, height) => draw_trend_line(cr, width, height, symbol, positive));
        overlay.add_overlay(graph);

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
        // so the trend line/arrow reflect it.
        graph.set_draw_func((area, cr, width, height) => draw_trend_line(cr, width, height, symbol, positive));
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

    // Deterministic per-symbol squiggle whose overall slope follows today's
    // direction - decoration, not a real price chart (see class doc).
    private static void draw_trend_line(Cairo.Context cr, int width, int height, string symbol, bool positive) {
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
