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

using GLib;
using Gee;

/**
 * Drives up to four opt-in preview rows shown at the top of My Feed for
 * other app features - Sports scores, Markets, Podcasts, and Magazines
 * (see Prefs.myfeed_show_*) - each a CategorySection with a handful of
 * items and a trailing "Go to X" button (CategorySection's own
 * nav_target_id, see SidebarManager.handle_item_activation). Entirely
 * additive to My Feed's own source/category rows below, same pattern as
 * SportsScoresController/StocksTickerController: populates
 * ContentView.myfeed_extras_container directly rather than going through
 * LayoutManager's article-section machinery, since none of these rows have
 * any article/search/overflow-queue concept. Unlike those two controllers
 * this doesn't poll - a preview row only needs to be reasonably fresh each
 * time My Feed is opened, not continuously live.
 */
public class MyFeedExtrasController : GLib.Object {
    private const int MAX_ITEMS_PER_ROW = 6;
    private const int MARKET_CARD_SIZE = 240;

    private static FetchContext? active_ctx = null;

    public static void load(NewsWindow win) {
        if (win.content_view == null || win.content_view.myfeed_extras_container == null) return;
        active_ctx = FetchContext.current_context();

        var container = win.content_view.myfeed_extras_container;
        Gtk.Widget? child = container.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            container.remove(child);
            child = next;
        }

        bool any_enabled = win.prefs.myfeed_show_sports || win.prefs.myfeed_show_market
            || win.prefs.myfeed_show_podcasts || win.prefs.myfeed_show_magazines;
        container.set_visible(any_enabled);
        if (!any_enabled) return;

        // Podcasts/Magazines read straight from local stores, so render
        // immediately; Sports/Markets need a network round trip first.
        if (win.prefs.myfeed_show_podcasts) render_podcasts(win);
        if (win.prefs.myfeed_show_magazines) render_magazines(win);
        if (win.prefs.myfeed_show_sports && win.prefs.sports_scores_enabled) load_sports(win);
        if (win.prefs.myfeed_show_market && win.prefs.market_cards_enabled) load_market(win);
    }

    // Called when navigating away from My Feed - render() only ever runs
    // while still on My Feed, so without this the container would stay
    // visible underneath every other category's content.
    public static void hide(NewsWindow win) {
        if (win.content_view == null || win.content_view.myfeed_extras_container == null) return;
        active_ctx = null;
        var container = win.content_view.myfeed_extras_container;
        container.set_visible(false);
        Gtk.Widget? child = container.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            container.remove(child);
            child = next;
        }
    }

    private static void load_sports(NewsWindow win) {
        var ctx = active_ctx;

        // Every enabled league in the user's own order, plus any league a
        // favorited team plays in even if that league is disabled - a
        // favorite is a stronger interest signal than the league toggle.
        // Leagues that come back empty (off-season) simply drop out in
        // select_sports_games(), so fetching them all costs nothing in the
        // row itself.
        var favorites = win.prefs.favorite_teams();
        var league_order = new Gee.ArrayList<string>();
        foreach (var key in win.prefs.ordered_sports_league_keys()) {
            bool has_favorite = false;
            foreach (var f in favorites) if (f.league_key == key) { has_favorite = true; break; }
            if (win.prefs.sports_league_enabled(key) || has_favorite) league_order.add(key);
        }
        if (league_order.size == 0) return;

        var results = new Gee.HashMap<string, Gee.ArrayList<GameScore>>();
        int remaining = league_order.size;
        foreach (var league_key in league_order) {
            SportsScoresService.fetch_league(league_key, (returned_key, games) => {
                remaining--;
                // The user may have navigated away (or started a search)
                // while this request was in flight - drop the result
                // rather than populate a hidden/stale/search-owned view.
                if (ctx == null || !ctx.still_owns_view()) return;
                if (games != null) results.set(returned_key, games);
                if (remaining == 0) {
                    render_sports_row(win, select_sports_games(league_order, results, favorites));
                }
            });
        }
    }

    // Picks up to MAX_ITEMS_PER_ROW games for the one-row preview, in
    // priority order:
    //   1. favorited teams' live games
    //   2. other live games, spread across leagues (closest score first)
    //   3. favorited teams' other games - one slot is held back for these
    //      so a busy live slate can't push every favorite out of the row
    //   4. remaining slots filled one league at a time, in the user's order
    // Games outside a freshness window are dropped first; if that leaves
    // the row thin (a sparse or off-season league), the window is widened
    // rather than padding the row with filler.
    private static Gee.ArrayList<GameScore> select_sports_games(Gee.ArrayList<string> league_order,
            Gee.HashMap<string, Gee.ArrayList<GameScore>> results, Gee.ArrayList<FavoriteTeamRef> favorites) {
        var now = new GLib.DateTime.now_utc();
        var pool = filter_by_window(league_order, results, now, STRICT_PAST_HOURS, STRICT_FUTURE_HOURS);
        if (pool.size < MIN_SPORTS_POOL) {
            pool = filter_by_window(league_order, results, now, RELAXED_PAST_HOURS, RELAXED_FUTURE_HOURS);
        }

        var favorite_live = new Gee.ArrayList<GameScore>();
        var favorite_other = new Gee.ArrayList<GameScore>();
        var live_by_league = new Gee.HashMap<string, Gee.ArrayList<GameScore>>();
        var other_by_league = new Gee.HashMap<string, Gee.ArrayList<GameScore>>();
        foreach (var game in pool) {
            bool fav = is_favorite_game(game, favorites);
            bool live = game.status == GameStatus.LIVE;
            if (fav && live) favorite_live.add(game);
            else if (fav) favorite_other.add(game);
            else {
                var bucket = live ? live_by_league : other_by_league;
                if (!bucket.has_key(game.league)) bucket.set(game.league, new Gee.ArrayList<GameScore>());
                bucket.get(game.league).add(game);
            }
        }
        favorite_live.sort(compare_live);
        favorite_other.sort(compare_not_live);
        foreach (var list in live_by_league.values) list.sort(compare_live);
        foreach (var list in other_by_league.values) list.sort(compare_not_live);

        var selected = new Gee.ArrayList<GameScore>();
        foreach (var game in favorite_live) {
            if (selected.size >= MAX_ITEMS_PER_ROW) return selected;
            selected.add(game);
        }
        int reserved = (favorite_live.size == 0 && favorite_other.size > 0) ? 1 : 0;
        take_round_robin(selected, league_order, live_by_league, MAX_ITEMS_PER_ROW - reserved);
        foreach (var game in favorite_other) {
            if (selected.size >= MAX_ITEMS_PER_ROW) break;
            selected.add(game);
        }
        take_round_robin(selected, league_order, other_by_league, MAX_ITEMS_PER_ROW);
        return selected;
    }

    // Freshness window, in hours relative to each game's start time. Live
    // games always pass. The strict window keeps a busy league's row
    // current (e.g. the NFL scoreboard returns the whole week, Thursday's
    // finals included); the relaxed one is only used when the strict pool
    // is too thin to fill a reasonable row.
    private const int MIN_SPORTS_POOL = 3;
    private const int STRICT_PAST_HOURS = 27;    // ~24h after a game ends
    private const int STRICT_FUTURE_HOURS = 72;
    private const int RELAXED_PAST_HOURS = 75;
    private const int RELAXED_FUTURE_HOURS = 240;

    private static Gee.ArrayList<GameScore> filter_by_window(Gee.ArrayList<string> league_order,
            Gee.HashMap<string, Gee.ArrayList<GameScore>> results, GLib.DateTime now, int past_hours, int future_hours) {
        var pool = new Gee.ArrayList<GameScore>();
        var seen = new Gee.HashSet<string>();
        foreach (var league_key in league_order) {
            var games = results.get(league_key);
            if (games == null) continue;
            foreach (var game in games) {
                if (!seen.add(game.league + "|" + game.game_id)) continue;
                if (game.status != GameStatus.LIVE && game.start_time != null) {
                    int64 hours_from_now = game.start_time.difference(now) / GLib.TimeSpan.HOUR;
                    if (hours_from_now < -past_hours || hours_from_now > future_hours) continue;
                }
                pool.add(game);
            }
        }
        return pool;
    }

    private static bool is_favorite_game(GameScore game, Gee.ArrayList<FavoriteTeamRef> favorites) {
        foreach (var f in favorites) {
            if (f.league_key != game.league) continue;
            if (f.team_id == game.home_team_id || f.team_id == game.away_team_id) return true;
        }
        return false;
    }

    // Takes one game per league per pass, in the user's league order, until
    // `limit` total games are selected or every league runs dry - so a
    // league with a packed slate can't take over the row, and a league with
    // a single game never blocks the others.
    private static void take_round_robin(Gee.ArrayList<GameScore> selected, Gee.ArrayList<string> league_order,
            Gee.HashMap<string, Gee.ArrayList<GameScore>> by_league, int limit) {
        int index = 0;
        bool took_any = true;
        while (selected.size < limit && took_any) {
            took_any = false;
            foreach (var league_key in league_order) {
                if (selected.size >= limit) return;
                var games = by_league.get(league_key);
                if (games == null || index >= games.size) continue;
                selected.add(games.get(index));
                took_any = true;
            }
            index++;
        }
    }

    // Closest game first - a cheap stand-in for "most worth watching".
    // Unparseable scores (e.g. cricket's "245/6") sort after numeric ones.
    private static int compare_live(GameScore a, GameScore b) {
        return score_margin(a) - score_margin(b);
    }

    private static int score_margin(GameScore game) {
        int home = 0, away = 0;
        if (!int.try_parse(game.home_score, out home) || !int.try_parse(game.away_score, out away)) return int.MAX / 2;
        return (home - away).abs();
    }

    // Starting within a day (soonest first), then finals (most recent
    // first), then anything further out (soonest first).
    private static int compare_not_live(GameScore a, GameScore b) {
        var now = new GLib.DateTime.now_utc();
        int bucket_a = not_live_bucket(a, now);
        int bucket_b = not_live_bucket(b, now);
        if (bucket_a != bucket_b) return bucket_a - bucket_b;
        if (a.start_time == null || b.start_time == null) return 0;
        int cmp = a.start_time.compare(b.start_time);
        return bucket_a == 1 ? -cmp : cmp;
    }

    private static int not_live_bucket(GameScore game, GLib.DateTime now) {
        if (game.status == GameStatus.FINAL) return 1;
        if (game.start_time != null && game.start_time.difference(now) > 24 * GLib.TimeSpan.HOUR) return 2;
        return 0;
    }

    private static void render_sports_row(NewsWindow win, Gee.ArrayList<GameScore> games) {
        if (win.content_view == null || win.content_view.myfeed_extras_container == null) return;
        if (active_ctx == null || !active_ctx.still_owns_view()) return;
        if (games.size == 0) return;

        // A single-league row is titled after that league; a mixed row gets
        // a generic title and a league prefix on each card instead.
        bool mixed = false;
        bool any_live = false;
        foreach (var game in games) {
            if (game.league != games.get(0).league) mixed = true;
            if (game.status == GameStatus.LIVE) any_live = true;
        }
        string title = mixed ? "Your Scores" : games.get(0).league_display_name;

        var section = new CategorySection(win, title, "myfeed:sports", true, true, null, any_live, null, "sports");
        section.wrapper.add_css_class("frontpage-section-divider");
        foreach (var game in games) {
            var card = new ScoreCard(game, true, mixed);
            section.add_card(card.root);
        }
        win.content_view.myfeed_extras_container.append(section.wrapper);
    }

    private static void load_market(NewsWindow win) {
        var ctx = active_ctx;
        MarketIndicesService.fetch_indices((quotes) => {
            if (ctx == null || !ctx.still_owns_view()) return;
            if (quotes == null || quotes.size == 0) return;
            render_market_row(win, quotes);
        });
    }

    private static void render_market_row(NewsWindow win, Gee.ArrayList<MarketIndexQuote> quotes) {
        if (win.content_view == null || win.content_view.myfeed_extras_container == null) return;
        if (active_ctx == null || !active_ctx.still_owns_view()) return;

        var section = new CategorySection(win, "Markets", "myfeed:market", true, false, null, false, null, "business", false);
        section.wrapper.add_css_class("frontpage-section-divider");
        int n = int.min(MAX_ITEMS_PER_ROW, quotes.size);
        for (int i = 0; i < n; i++) {
            var card = new MarketIndexCard(quotes.get(i), MARKET_CARD_SIZE);
            section.add_card(card.root);
        }
        win.content_view.myfeed_extras_container.append(section.wrapper);
    }

    private static void render_podcasts(NewsWindow win) {
        if (win.content_view == null || win.content_view.myfeed_extras_container == null) return;
        var subscriptions = Paperboy.PodcastSubscriptionStore.get_instance().get_all_subscriptions();
        if (subscriptions.size == 0) return;

        var section = new CategorySection(win, "Podcasts", "myfeed:podcasts", false, false, null, false, null, "podcasts");
        section.wrapper.add_css_class("frontpage-section-divider");
        int n = int.min(MAX_ITEMS_PER_ROW, subscriptions.size);
        for (int i = 0; i < n; i++) {
            var show = subscriptions.get(i).to_show();
            var card = new PodcastCard.for_show(show);
            if (show.image_url != null && show.image_url.length > 0) {
                win.image_manager.load_image_async(card.image, show.image_url, PodcastCard.IMAGE_WIDTH, PodcastCard.IMAGE_HEIGHT);
            }
            section.add_card(card.root);
        }
        win.content_view.myfeed_extras_container.append(section.wrapper);
    }

    private static void render_magazines(NewsWindow win) {
        if (win.content_view == null || win.content_view.myfeed_extras_container == null) return;
        var entries = Paperboy.MagazineLibraryStore.get_instance().get_all_entries();
        if (entries.size == 0) return;

        var section = new CategorySection(win, "Magazines", "myfeed:magazines", false, false, null, false, null, "magazines");
        section.wrapper.add_css_class("frontpage-section-divider");
        int n = int.min(MAX_ITEMS_PER_ROW, entries.size);
        for (int i = 0; i < n; i++) {
            var card = new MagazineCard.for_entry(entries.get(i));
            section.add_card(card.root);
        }
        win.content_view.myfeed_extras_container.append(section.wrapper);
    }
}
