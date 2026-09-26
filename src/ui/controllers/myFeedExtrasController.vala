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
    // Kept small - this is a preview, not the real Sports page, so it's
    // not worth fetching every enabled league just to fill one row.
    private const int MAX_SPORTS_LEAGUES = 3;
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

        var enabled_leagues = new Gee.ArrayList<string>();
        foreach (var key in SportsScoresService.league_keys()) {
            if (win.prefs.sports_league_enabled(key)) enabled_leagues.add(key);
            if (enabled_leagues.size >= MAX_SPORTS_LEAGUES) break;
        }
        if (enabled_leagues.size == 0) return;

        var collected = new Gee.ArrayList<GameScore>();
        int remaining = enabled_leagues.size;
        foreach (var league_key in enabled_leagues) {
            SportsScoresService.fetch_league(league_key, (returned_key, games) => {
                remaining--;
                // The user may have navigated away (or started a search)
                // while this request was in flight - drop the result
                // rather than populate a hidden/stale/search-owned view.
                if (ctx == null || !ctx.still_owns_view()) return;
                if (games != null) collected.add_all(games);
                if (remaining == 0) render_sports_row(win, collected);
            });
        }
    }

    private static void render_sports_row(NewsWindow win, Gee.ArrayList<GameScore> games) {
        if (win.content_view == null || win.content_view.myfeed_extras_container == null) return;
        if (active_ctx == null || !active_ctx.still_owns_view()) return;
        // still_owns_view() alone isn't enough - it only catches a
        // cancelled FetchContext, and not every page that can be navigated
        // to (e.g. Magazines) invalidates the context on entry. Checking
        // the category directly closes that gap regardless.
        if (win.prefs.category != "myfeed") return;
        if (games.size == 0) return;

        var section = new CategorySection(win, "Sports", "myfeed:sports", true, true, null, false, null, "sports");
        section.wrapper.add_css_class("frontpage-section-divider");
        int n = int.min(MAX_ITEMS_PER_ROW, games.size);
        for (int i = 0; i < n; i++) {
            var card = new ScoreCard(games.get(i));
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
        if (win.prefs.category != "myfeed") return;

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
