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

/**
 * A single game score card for the Sports scores sections - sibling to
 * ArticleCard, not a reuse of it, since scores have no article/state-store
 * concept (no save/share/mark-read, no context menu). Reuses the ".card"
 * CSS class for consistent sizing/hover/shadow with the rest of the app.
 *
 * SportsScoresController keeps reusing the same ScoreCard across polls for
 * a game still on the board, calling update() rather than rebuilding -
 * repeatedly destroying/recreating a league's whole CategorySection (Overlay
 * + ScrolledWindow + EventControllerMotion, see ScrollNavButtons) every poll
 * was found to leak memory, a GTK4 quirk unrelated to anything drawn here.
 */
public class ScoreCard : GLib.Object {
    public const int CARD_WIDTH = 220;

    public Gtk.Box root;
    public string url;

    // Set for My Feed's one-shot preview row (see MyFeedExtrasController),
    // which never re-polls: a live game shows a plain "LIVE" there instead
    // of its game clock, since a clock frozen at load time reads as broken
    // where a slightly stale score doesn't. show_league prefixes the status
    // with the league name for rows that mix leagues.
    private bool preview;
    private bool show_league;

    // Head-to-head games use the first two rows (away, then home) and hide
    // the rest; golf/racing fill one row per leader (see GameScore.field),
    // with the place shown in front.
    private const int ROW_COUNT = 3;

    private Gtk.Label status_label;
    private Gtk.Label event_label;
    private Gtk.Widget[] rows = new Gtk.Widget[ROW_COUNT];
    private Gtk.Label[] position_labels = new Gtk.Label[ROW_COUNT];
    private Gtk.Picture[] logos = new Gtk.Picture[ROW_COUNT];
    private Gtk.Label[] name_labels = new Gtk.Label[ROW_COUNT];
    private Gtk.Label[] score_labels = new Gtk.Label[ROW_COUNT];

    public ScoreCard(GameScore game, bool preview = false, bool show_league = false) {
        GLib.Object();
        this.preview = preview;
        this.show_league = show_league;

        root = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
        root.add_css_class("card");
        root.add_css_class("score-card");
        root.set_halign(Gtk.Align.START);
        // The team rows below push their score label to the far right via
        // hexpand on their name label, which otherwise bubbles all the way
        // up through this root box's own auto-computed hexpand and into the
        // section's card row - stretching each card's cell there and
        // leaving a large gap after every card (only visible once a row is
        // short enough to not already overflow the scroller, e.g. a league
        // with just a few games). Pin hexpand off here so that only affects
        // layout inside the card, not the row of cards it sits in.
        root.set_hexpand(false);
        root.set_size_request(CARD_WIDTH, -1);
        set_url(game.espn_link);

        status_label = new Gtk.Label("");
        status_label.set_xalign(0);
        status_label.set_ellipsize(Pango.EllipsizeMode.END);
        status_label.add_css_class("caption");
        status_label.add_css_class("score-card-status");
        root.append(status_label);

        // Tennis round/tournament, or the golf/racing event - hidden for team sports.
        event_label = new Gtk.Label("");
        event_label.set_xalign(0);
        event_label.set_ellipsize(Pango.EllipsizeMode.END);
        event_label.add_css_class("caption");
        event_label.add_css_class("score-card-status");
        root.append(event_label);

        for (int i = 0; i < ROW_COUNT; i++) {
            rows[i] = build_team_row(out position_labels[i], out logos[i], out name_labels[i], out score_labels[i]);
            root.append(rows[i]);
        }

        apply_game(game);

        wire_interactions(root);
    }

    // Refresh this card's status/scores/logos in place - no widgets are
    // created or destroyed, so this can be called every poll without the
    // rebuild-from-scratch leak described in the class doc.
    public void update(GameScore game) {
        set_url(game.espn_link);
        apply_game(game);
    }

    // Also kept on root, where the click handler reads it - see
    // wire_interactions() for why it can't read this.url.
    private void set_url(string link) {
        url = link;
        root.set_data<string>(URL_DATA_KEY, link);
    }

    private const string URL_DATA_KEY = "score-card-url";

    private void apply_game(GameScore game) {
        string status_text = (preview && game.status == GameStatus.LIVE) ? _("LIVE") : status_text_for(game);
        if (show_league) status_text = _("%s · %s").printf(game.league_display_name, status_text);
        status_label.set_text(status_text);
        if (game.status == GameStatus.LIVE) {
            status_label.add_css_class("score-card-status-live");
        } else {
            status_label.remove_css_class("score-card-status-live");
        }

        // if/else, not a ternary: Vala frees the printf() temp in that form before it's used.
        string event_text = game.event_name;
        if (game.round_name.length > 0 && game.event_name.length > 0) event_text = _("%s · %s").printf(game.round_name, game.event_name);
        else if (game.round_name.length > 0) event_text = game.round_name;
        event_label.set_text(event_text);
        event_label.set_visible(event_text.length > 0);

        bool show_scores = game.status != GameStatus.SCHEDULED && !game.no_result;
        if (game.field == null) {
            apply_team(0, game.away_team, game.away_team_abbr, game.away_logo_url, show_scores ? game.away_score : "");
            apply_team(1, game.home_team, game.home_team_abbr, game.home_logo_url, show_scores ? game.home_score : "");
            for (int i = 0; i < ROW_COUNT; i++) {
                rows[i].set_visible(i < 2);
                position_labels[i].set_visible(false);
            }
            return;
        }

        // Before the start the field's order means nothing yet, so only the event shows.
        for (int i = 0; i < ROW_COUNT; i++) {
            bool shown = show_scores && i < game.field.size;
            rows[i].set_visible(shown);
            if (!shown) continue;
            var entry = game.field.get(i);
            position_labels[i].set_text(entry.position);
            position_labels[i].set_visible(true);
            apply_team(i, entry.short_name, entry.short_name, entry.flag_url, entry.score);
        }
    }

    // Built from the start time in the user's own timezone/clock format, since ESPN's
    // text is always US Eastern. Live games keep ESPN's clock ("Q3 7:42", "67'").
    private static string status_text_for(GameScore game) {
        if (game.status == GameStatus.LIVE || game.start_time == null) return game.status_detail;
        // Golf tournaments have a date but no tee time, given as midnight US
        // Eastern - which lands on the day before west of it, so read the
        // date as-is. Finished, the start date of a multi-day event would
        // read as when it ended, so just "Complete".
        if (!game.time_valid && game.field != null) {
            if (game.status == GameStatus.FINAL) return game.status_detail;
            var utc = game.start_time.to_utc();
            return day_label(new GLib.DateTime.local(utc.get_year(), utc.get_month(), utc.get_day_of_month(), 12, 0, 0));
        }
        var local = game.start_time.to_local();
        if (game.status == GameStatus.FINAL) return _("%s · %s").printf(game.status_detail, day_label(local));
        if (!game.time_valid) return _("TBD");
        return _("%s · %s").printf(day_label(local), local.format(DateUtils.clock_time_format()));
    }

    private static string day_label(GLib.DateTime local) {
        var today = new GLib.DateTime.now_local();
        var d = GLib.Date();
        d.set_dmy((GLib.DateDay) local.get_day_of_month(), local.get_month(), (GLib.DateYear) local.get_year());
        var t = GLib.Date();
        t.set_dmy((GLib.DateDay) today.get_day_of_month(), today.get_month(), (GLib.DateYear) today.get_year());
        int diff = (int) d.get_julian() - (int) t.get_julian();
        if (diff == 0) return _("Today");
        if (diff == -1) return _("Yesterday");
        if (diff == 1) return _("Tomorrow");
        return DateUtils.short_weekday_date(local);
    }

    // Must stay static: Vala folds a strong ref to `self` into the shared
    // closure block of any instance method that defines a lambda, even one
    // that never touches `self`. It also refs captured parameters, so the
    // lambdas use an unowned alias of root rather than root_widget or a
    // ScoreCard - either would close a root -> controller -> closure ->
    // root cycle. The link is read from root on each click, so one
    // updated via update() is reflected on the next click.
    private static void wire_interactions(Gtk.Box root_widget) {
        unowned Gtk.Box r = root_widget;
        var gesture = new Gtk.GestureClick();
        gesture.set_button(1);
        gesture.released.connect(() => {
            string? link = r.get_data<string>(URL_DATA_KEY);
            if (link != null) BrowserUtils.open_url_in_browser(link);
        });
        root_widget.add_controller(gesture);

        var motion = new Gtk.EventControllerMotion();
        motion.enter.connect(() => { r.add_css_class("card-hover"); });
        motion.leave.connect(() => { r.remove_css_class("card-hover"); });
        root_widget.add_controller(motion);
    }

    private Gtk.Widget build_team_row(out Gtk.Label position_label, out Gtk.Picture logo, out Gtk.Label name_label, out Gtk.Label score_label) {
        var row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
        row.set_hexpand(true);

        position_label = new Gtk.Label("");
        position_label.set_xalign(1);
        position_label.add_css_class("score-card-position");
        row.append(position_label);

        logo = new Gtk.Picture();
        logo.set_size_request(24, 24);
        logo.set_content_fit(Gtk.ContentFit.CONTAIN);
        logo.set_can_shrink(true);
        row.append(logo);

        name_label = new Gtk.Label("");
        name_label.set_xalign(0);
        name_label.set_hexpand(true);
        name_label.set_ellipsize(Pango.EllipsizeMode.END);
        name_label.add_css_class("score-card-team");
        row.append(name_label);

        score_label = new Gtk.Label("");
        score_label.set_xalign(1);
        score_label.add_css_class("score-card-score");
        row.append(score_label);

        return row;
    }

    private void apply_team(int row, string team_name, string abbr, string? logo_url, string score) {
        string display_name = team_name.length > 0 ? team_name : abbr;
        name_labels[row].set_text(display_name);
        score_labels[row].set_text(score);

        if (logo_url != null && logo_url.length > 0) {
            load_team_logo(logos[row], logo_url);
        } else {
            // A leaderboard row can change athlete between polls - don't leave the last one's flag.
            logos[row].set_paintable(null);
        }
    }

    // Team logos are small and few (max 3 per card, ~15 cards per league
    // section) so a plain one-off fetch via the shared HTTP client is
    // enough - no need for the app's stateful image cache/defer pipeline
    // used for article thumbnails, which assumes callers pair it with
    // article-specific loading-state bookkeeping this card doesn't have.
    // Static for the same reason as wire_interactions() above.
    //
    // Decoded-texture cache keyed by logo URL: team logos never change, but
    // score cards rebuild from scratch on every live-game poll, so without
    // this every poll re-fetched and re-decoded the same handful of
    // textures. Byte-budgeted (not just count-based) since these are
    // decoded GPU textures, not compressed file bytes - a heaptrack profile
    // of real usage found this cache alone holding 450MB+ of leaked-looking
    // (never-evicted) textures after only a few minutes of live-score
    // polling, once accounting for the retry/thundering-herd duplicate
    // fetches fixed below.
    //
    // Lazily constructed rather than a field initializer, since this class
    // is only ever used through its constructor/static helpers, never a
    // path that would run a static field initializer.
    private const int64 MAX_LOGO_CACHE_BYTES = 40 * 1024 * 1024;
    // Displayed at 24x24 (see build_team_row); 72 gives 3x HiDPI headroom
    // without keeping the CDN's full 500x500 source resolution around.
    private const int LOGO_DECODE_DIM = 72;
    private static LruCache<string, Gdk.Texture>? _logo_texture_cache = null;
    private static LruCache<string, Gdk.Texture> logo_texture_cache() {
        if (_logo_texture_cache == null) {
            _logo_texture_cache = new LruCache<string, Gdk.Texture>(256);
            _logo_texture_cache.set_byte_budget(MAX_LOGO_CACHE_BYTES, (key, tex) => {
                return (int64) tex.get_width() * tex.get_height() * 4;
            });
        }
        return _logo_texture_cache;
    }

    // Score cards for the same team logo can be built many times in quick
    // succession (every league section on every live-game poll), and the
    // HTTP fetch is async - without tracking in-flight requests, every one
    // of those cards would race to fetch/decode its own independent texture
    // for the same URL before the first fetch's result had a chance to
    // populate the cache above, each leaving its own several-hundred-KB to
    // multi-MB decoded texture in memory. Track waiters per URL instead, the
    // same pattern ImageManager uses for article thumbnail downloads.
    private static Gee.HashMap<string, Gee.ArrayList<Gtk.Picture>>? _pending_logo_pictures = null;
    private static Gee.HashMap<string, Gee.ArrayList<Gtk.Picture>> pending_logo_pictures() {
        if (_pending_logo_pictures == null) _pending_logo_pictures = new Gee.HashMap<string, Gee.ArrayList<Gtk.Picture>>();
        return _pending_logo_pictures;
    }

    // Public so LeagueBadge (Sports carousel) can reuse the same
    // cached/de-duplicated logo loading for league shield logos.
    public static void load_team_logo(Gtk.Picture picture, string logo_url) {
        var cached = logo_texture_cache().get(logo_url);
        if (cached != null) {
            picture.set_paintable(cached);
            return;
        }

        var pending = pending_logo_pictures();
        var waiters = pending.get(logo_url);
        if (waiters != null) {
            // A fetch for this exact URL is already in flight - just join it.
            waiters.add(picture);
            return;
        }
        waiters = new Gee.ArrayList<Gtk.Picture>();
        waiters.add(picture);
        pending.set(logo_url, waiters);

        var client = Paperboy.HttpClientUtils.get_default();
        client.fetch_bytes(logo_url, null, (response) => {
            var waiting = pending.get(logo_url);
            pending.unset(logo_url);
            if (!response.is_success() || response.body == null) return;
            try {
                // Team logos ship from ESPN's CDN at 500x500 but render here
                // at 24x24 (see build_team_row) - decoding straight to a
                // texture from the raw network bytes (the previous
                // approach) kept every distinct team's logo around at full
                // resolution, ~1-2MB each. A heaptrack profile of live
                // sports polling found this the single largest source of
                // growth in the app (400MB+) once enough distinct teams had
                // been shown. Downscale before texturing, same as article
                // thumbnails elsewhere - LOGO_DECODE_DIM leaves headroom for
                // HiDPI displays without keeping the full source resolution.
                var loader = new Gdk.PixbufLoader();
                loader.write(response.body.get_data());
                loader.close();
                var pixbuf = loader.get_pixbuf();
                if (pixbuf == null) return;
                if (pixbuf.get_width() > LOGO_DECODE_DIM || pixbuf.get_height() > LOGO_DECODE_DIM) {
                    pixbuf = pixbuf.scale_simple(LOGO_DECODE_DIM, LOGO_DECODE_DIM, Gdk.InterpType.HYPER);
                    if (pixbuf == null) return;
                }
                var texture = Gdk.Texture.for_pixbuf(pixbuf);
                logo_texture_cache().set(logo_url, texture);
                if (waiting != null) {
                    foreach (var pic in waiting) pic.set_paintable(texture);
                }
            } catch (GLib.Error e) {
                // Missing/broken team logo - leave the placeholder blank
                // rather than failing the whole card.
            }
        });
    }
}
