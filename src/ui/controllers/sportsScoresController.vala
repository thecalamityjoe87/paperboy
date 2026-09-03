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
 * Drives the live-scores sections shown in the Sports category between the
 * hero and the article grid below it, entirely additive to whatever the
 * Sports category already renders (RSS hero + article grid, untouched) -
 * see NewsWindow.fetch_news(), the only call site that invokes this.
 * Populates ContentView.sports_scores_container directly rather than going
 * through LayoutManager's Front-Page-specific section machinery, since that
 * machinery is tightly coupled to ArticleItem/search/overflow-queue
 * concerns that don't apply to scores.
 */
public class SportsScoresController : GLib.Object {
    private const int POLL_SECONDS = 45;

    private static uint timeout_id = 0;
    private static weak NewsWindow? active_window = null;

    // Last successfully fetched games per league, served on a transient
    // per-poll failure so a section doesn't flicker away just because one
    // refresh tick had a bad request.
    //
    // Lazily constructed (rather than a field initializer) because this
    // class is only ever used as a static namespace - never instantiated -
    // so its class_init, which is where Vala would run a field initializer,
    // never fires; a field initializer here left this null at first use in
    // manual testing (mirrors the exact issue HttpClientUtils.ensure_initialized()
    // works around for its own singleton).
    private static Gee.HashMap<string, Gee.ArrayList<GameScore>>? _last_good = null;
    private static Gee.HashMap<string, Gee.ArrayList<GameScore>> last_good() {
        if (_last_good == null) _last_good = new Gee.HashMap<string, Gee.ArrayList<GameScore>>();
        return _last_good;
    }

    public static void load(NewsWindow win) {
        active_window = win;
        fetch_and_populate(win);
        start_polling();
    }

    public static void stop_polling() {
        if (timeout_id != 0) {
            Source.remove(timeout_id);
            timeout_id = 0;
        }
    }

    // Called when navigating away from Sports: render() only ever runs
    // while still on the Sports category, so without this the container
    // stays visible with its last-rendered score sections showing
    // underneath every other category's content.
    public static void hide(NewsWindow win) {
        if (win.content_view == null || win.content_view.sports_scores_container == null) return;
        win.content_view.sports_scores_container.set_visible(false);
        if (win.content_view.hero_scores_separator != null) win.content_view.hero_scores_separator.set_visible(false);
        if (win.content_view.scores_articles_separator != null) win.content_view.scores_articles_separator.set_visible(false);
    }

    private static void start_polling() {
        if (timeout_id != 0) return; // already running
        timeout_id = Timeout.add_seconds(POLL_SECONDS, () => {
            if (active_window == null || active_window.prefs.category != "sports") {
                timeout_id = 0;
                return false;
            }
            fetch_and_populate(active_window);
            return true;
        });
    }

    private static void fetch_and_populate(NewsWindow win) {
        var league_keys = SportsScoresService.league_keys();
        var results = new Gee.HashMap<string, Gee.ArrayList<GameScore>>();
        int pending = league_keys.size;

        // One fetch_league call per league, each constructing its own
        // closure right here rather than going through a helper that fans
        // out internally - see the comment on SportsScoresService.fetch_league
        // for why (a use-after-free hit during manual testing otherwise).
        foreach (var league_key in league_keys) {
            SportsScoresService.fetch_league(league_key, (returned_key, games) => {
                // The user may have navigated away while this request was
                // in flight; drop the result rather than populate a
                // hidden/stale view.
                if (win.prefs.category != "sports") return;

                if (games != null) {
                    last_good().set(returned_key, games);
                    results.set(returned_key, games);
                } else if (last_good().has_key(returned_key)) {
                    results.set(returned_key, last_good().get(returned_key));
                } else {
                    results.set(returned_key, new Gee.ArrayList<GameScore>());
                }

                pending--;
                if (pending <= 0) {
                    render(win, league_keys, results);
                }
            });
        }
    }

    private static void render(NewsWindow win, Gee.ArrayList<string> league_keys, Gee.HashMap<string, Gee.ArrayList<GameScore>> results) {
        if (win.content_view == null || win.content_view.sports_scores_container == null) return;
        if (win.prefs.category != "sports") return;

        var container = win.content_view.sports_scores_container;

        Gtk.Widget? child = container.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            container.remove(child);
            child = next;
        }

        bool any_section = false;
        foreach (var league_key in league_keys) {
            var games = results.get(league_key);
            if (games == null || games.size == 0) continue;

            var section = new CategorySection(win, SportsScoresService.display_name_for(league_key), "sports:" + league_key, true, true);
            foreach (var game in games) {
                var card = new ScoreCard(game);
                card.activated.connect((url) => {
                    BrowserUtils.open_url_in_browser(url);
                });
                section.add_card(card.root);
            }
            container.append(section.wrapper);
            any_section = true;
        }

        container.set_visible(any_section);
        if (win.content_view.hero_scores_separator != null) win.content_view.hero_scores_separator.set_visible(any_section);
        if (win.content_view.scores_articles_separator != null) win.content_view.scores_articles_separator.set_visible(any_section);
    }
}
