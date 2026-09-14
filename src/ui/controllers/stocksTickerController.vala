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
 * Drives the Stocks ticker section shown in the Business category between
 * the hero and the article grid - entirely additive, same pattern as
 * SportsScoresController. Populates ContentView.stocks_ticker_container
 * directly rather than going through LayoutManager's article-section
 * machinery, since quotes have no article/search/overflow-queue concept.
 *
 * Indices and crypto are two independent backend data paths (separate
 * refresh cadences, crypto has no market-hours gating) - each is polled on
 * its own timer, but both feed one combined 6-tile row.
 */
public class StocksTickerController : GLib.Object {
    // Backend refreshes its own caches within a 60-120s suggested range;
    // polling here keeps the UI reasonably fresh without hitting either
    // endpoint needlessly often.
    private const int POLL_SECONDS = 90;

    private static uint indices_timeout_id = 0;
    private static uint crypto_timeout_id = 0;
    private static weak NewsWindow? active_window = null;
    private static FetchContext? active_ctx = null;

    // Served on a transient per-poll failure so the section doesn't
    // disappear just because one refresh tick had a bad request. Separate
    // per data path since they refresh independently.
    private static Gee.ArrayList<MarketIndexQuote>? last_good_indices = null;
    private static Gee.ArrayList<MarketIndexQuote>? last_good_crypto = null;

    // The section and its cards are built once and reused across polls (see
    // render()'s comment for why) - static Gee fields need lazy init in
    // Vala, since this class is never instantiated so a field initializer
    // here would never run.
    private static CategorySection? current_section = null;
    private static Gee.HashMap<string, MarketIndexCard>? _current_cards = null;
    private static Gee.HashMap<string, MarketIndexCard> current_cards() {
        if (_current_cards == null) _current_cards = new Gee.HashMap<string, MarketIndexCard>();
        return _current_cards;
    }

    public static void load(NewsWindow win) {
        active_window = win;
        active_ctx = FetchContext.current_context();
        fetch_and_populate_indices(win);
        fetch_and_populate_crypto(win);
    }

    public static void stop_polling() {
        if (indices_timeout_id != 0) {
            Source.remove(indices_timeout_id);
            indices_timeout_id = 0;
        }
        if (crypto_timeout_id != 0) {
            Source.remove(crypto_timeout_id);
            crypto_timeout_id = 0;
        }
    }

    // Drop the reused section/cards - called on window close so this static
    // state doesn't hold a stray reference to a torn-down window's widgets.
    // Navigating away from Business (hide()) deliberately does NOT call
    // this: keeping the built section around is exactly the point (see
    // render()'s comment), so coming back to Business shows the last-known
    // values immediately instead of an empty container until the next poll.
    public static void reset() {
        current_section = null;
        current_cards().clear();
    }

    // The section is built once and reused (see render()'s comment), so its
    // header icon is never naturally re-resolved after that - without this,
    // a light/dark toggle while already sitting on Business left the "Markets
    // Today" icon stuck in whichever theme was active when it was first
    // built. Called from the same app-wide dark-mode listener that already
    // refreshes the sidebar/header category icons (see appWindow.vala).
    public static void refresh_icon_for_theme() {
        if (current_section == null || current_section.plain_icon_widget == null) return;
        string? icon_path = CategoryIconsUtils.resolve_themed_icon_path("markets-mono.svg");
        if (icon_path != null) current_section.plain_icon_widget.set_from_file(icon_path);
    }

    // Called when navigating away from Business - render() only ever runs
    // while still on Business, so without this the container stays visible
    // underneath every other category's content.
    public static void hide(NewsWindow win) {
        if (win.content_view == null || win.content_view.stocks_ticker_container == null) return;
        win.content_view.stocks_ticker_container.set_visible(false);
        if (win.content_view.hero_stocks_separator != null) win.content_view.hero_stocks_separator.set_visible(false);
        if (win.content_view.stocks_articles_separator != null) win.content_view.stocks_articles_separator.set_visible(false);
    }

    private static void schedule_next_indices_poll() {
        if (indices_timeout_id != 0) {
            Source.remove(indices_timeout_id);
            indices_timeout_id = 0;
        }
        indices_timeout_id = Timeout.add_seconds(POLL_SECONDS, () => {
            indices_timeout_id = 0;
            if (active_window == null || active_ctx == null || !active_ctx.still_owns_view()) {
                return false;
            }
            fetch_and_populate_indices(active_window);
            return false; // one-shot; fetch_and_populate_indices reschedules once results are in
        });
    }

    private static void schedule_next_crypto_poll() {
        if (crypto_timeout_id != 0) {
            Source.remove(crypto_timeout_id);
            crypto_timeout_id = 0;
        }
        crypto_timeout_id = Timeout.add_seconds(POLL_SECONDS, () => {
            crypto_timeout_id = 0;
            if (active_window == null || active_ctx == null || !active_ctx.still_owns_view()) {
                return false;
            }
            fetch_and_populate_crypto(active_window);
            return false; // one-shot; fetch_and_populate_crypto reschedules once results are in
        });
    }

    private static void fetch_and_populate_indices(NewsWindow win) {
        var ctx = active_ctx;
        MarketIndicesService.fetch_indices((quotes) => {
            // The user may have navigated away (or started a search) while
            // this request was in flight - drop the result rather than
            // populate a hidden/stale/search-owned view.
            if (ctx == null || !ctx.still_owns_view()) return;

            if (quotes != null && quotes.size > 0) last_good_indices = quotes;
            render_combined(win);
            schedule_next_indices_poll();
        });
    }

    private static void fetch_and_populate_crypto(NewsWindow win) {
        var ctx = active_ctx;
        MarketIndicesService.fetch_crypto((quotes) => {
            if (ctx == null || !ctx.still_owns_view()) return;

            if (quotes != null && quotes.size > 0) last_good_crypto = quotes;
            render_combined(win);
            schedule_next_crypto_poll();
        });
    }

    // Combines whatever's currently known from both independent data paths
    // (indices first, then crypto) and renders the result. Called after
    // either poll resolves, so a crypto-only update still refreshes the
    // shared row without waiting on the index poll's own cadence.
    private static void render_combined(NewsWindow win) {
        var combined = new Gee.ArrayList<MarketIndexQuote>();
        if (last_good_indices != null) combined.add_all(last_good_indices);
        if (last_good_crypto != null) combined.add_all(last_good_crypto);
        render(win, combined);
    }

    private static void render(NewsWindow win, Gee.ArrayList<MarketIndexQuote> quotes) {
        if (win.content_view == null || win.content_view.stocks_ticker_container == null) return;
        if (active_ctx == null || !active_ctx.still_owns_view()) return;

        var container = win.content_view.stocks_ticker_container;

        if (quotes.size == 0) {
            Gtk.Widget? child = container.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                container.remove(child);
                child = next;
            }
            reset();
            container.set_visible(false);
            if (win.content_view.hero_stocks_separator != null) win.content_view.hero_stocks_separator.set_visible(false);
            if (win.content_view.stocks_articles_separator != null) win.content_view.stocks_articles_separator.set_visible(false);
            return;
        }

        // Once the section/cards exist for this exact set of symbols, every
        // later poll just updates their text/colors in place (see
        // MarketIndexCard.update()) instead of tearing the whole thing down
        // and rebuilding it. Repeatedly destroying/recreating this section's
        // Overlay+ScrolledWindow+EventControllerMotion combination (see
        // ScrollNavButtons, used by every CategorySection) was found to leak
        // memory - a GTK4 quirk confirmed via an isolated repro, unrelated
        // to anything this feature itself draws or holds onto. A full
        // rebuild is still needed if the symbol set actually changes (e.g.
        // crypto finishing its first fetch after indices already rendered).
        bool needs_rebuild = current_section == null || current_cards().size != quotes.size;
        if (!needs_rebuild) {
            foreach (var quote in quotes) {
                if (!current_cards().has_key(quote.symbol)) {
                    needs_rebuild = true;
                    break;
                }
            }
        }

        if (needs_rebuild) {
            Gtk.Widget? child = container.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                container.remove(child);
                child = next;
            }
            current_cards().clear();

            // The exact same square sizing formula PodcastManager uses for
            // its hero cards (see render_hero_cards' comment) - dividing by
            // a fixed 4 (not quotes.size) is what actually makes these come
            // out the same size as the Podcasts page's hero cards,
            // regardless of how many tiles this row happens to have. This
            // row won't always fit the content width at that size - that's
            // fine, CategorySection's row scrolls horizontally, same as
            // Sports' score sections do for a league with many games.
            const int HERO_REFERENCE_COUNT = 4;
            int content_w = win.estimate_content_width();
            int base_size = (content_w - (HERO_REFERENCE_COUNT - 1) * Managers.LayoutManager.COL_SPACING) / HERO_REFERENCE_COUNT;
            int card_size = (int) (base_size * 1.1);
            if (card_size < 220) card_size = 220;
            if (card_size > 420) card_size = 420;

            // card_container=false: no wrapping bordered panel behind the
            // row - these cards are already fully self-contained (colored
            // tile, own border/radius), so an outer panel background just
            // read as a redundant card-behind-cards. circular_logo=false:
            // the markets icon is a symbolic glyph, not a team/source photo
            // logo, so it shouldn't get CategorySection's default
            // circular-logo treatment.
            string? icon_path = CategoryIconsUtils.resolve_themed_icon_path("markets-mono.svg");
            var section = new CategorySection(win, "Markets Today", "business:stocks", true, false, null, false, icon_path, null, false);
            foreach (var quote in quotes) {
                var card = new MarketIndexCard(quote, card_size);
                section.add_card(card.root);
                current_cards().set(quote.symbol, card);
            }
            container.append(section.wrapper);
            current_section = section;
        } else {
            foreach (var quote in quotes) {
                current_cards().get(quote.symbol).update(quote);
            }
        }

        container.set_visible(true);
        if (win.content_view.hero_stocks_separator != null) win.content_view.hero_stocks_separator.set_visible(true);
        if (win.content_view.stocks_articles_separator != null) win.content_view.stocks_articles_separator.set_visible(true);
    }
}
