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
    // Fast cadence while at least one fetched game is actually in progress.
    // Otherwise, scale the wait to how far off the *next* scheduled game
    // actually is - a game a month out doesn't need re-checking every few
    // minutes, but one kicking off in the next few minutes should still be
    // caught promptly so it flips over to live-cadence polling on time.
    private const int LIVE_POLL_SECONDS = 45;
    private const int SOON_THRESHOLD_SECONDS = 300;   // next game starts within 5 min
    private const int SOON_POLL_SECONDS = 45;
    private const int UPCOMING_THRESHOLD_SECONDS = 1800; // next game starts within 30 min
    private const int UPCOMING_POLL_SECONDS = 300;
    private const int FAR_OUT_POLL_SECONDS = 1800; // next game is >30 min out, or nothing scheduled

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
        if (!win.prefs.sports_scores_enabled) {
            stop_polling();
            hide(win);
            return;
        }

        active_window = win;
        fetch_and_populate(win);
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

    // Re-schedules itself (rather than a single recurring GLib.Timeout) so
    // the cadence can change poll-to-poll based on whether any game is
    // currently live. Always cancels any outstanding poll first, so calling
    // this repeatedly (e.g. load() firing again before the previous fetch's
    // callback lands) collapses down to one live timer instead of leaking.
    private static void schedule_next_poll(int seconds) {
        if (timeout_id != 0) {
            Source.remove(timeout_id);
            timeout_id = 0;
        }
        timeout_id = Timeout.add_seconds(seconds, () => {
            timeout_id = 0;
            if (active_window == null || active_window.prefs.category != "sports") {
                return false;
            }
            fetch_and_populate(active_window);
            return false; // one-shot; fetch_and_populate reschedules once results are in
        });
    }

    // Any game live -> poll fast. Otherwise, look at the soonest scheduled
    // (not yet started) game across every league and scale the wait so we
    // re-check well before it's due to start, without polling constantly
    // for games that are still hours or weeks away.
    private static int next_poll_seconds(Gee.HashMap<string, Gee.ArrayList<GameScore>> results) {
        GLib.DateTime? soonest_start = null;
        foreach (var games_list in results.values) {
            foreach (var game in games_list) {
                if (game.status == GameStatus.LIVE) return LIVE_POLL_SECONDS;
                if (game.status == GameStatus.SCHEDULED && game.start_time != null) {
                    if (soonest_start == null || game.start_time.compare(soonest_start) < 0) {
                        soonest_start = game.start_time;
                    }
                }
            }
        }

        if (soonest_start == null) return FAR_OUT_POLL_SECONDS;

        int64 seconds_until = soonest_start.difference(new GLib.DateTime.now_utc()) / GLib.TimeSpan.SECOND;
        if (seconds_until <= SOON_THRESHOLD_SECONDS) return SOON_POLL_SECONDS;
        if (seconds_until <= UPCOMING_THRESHOLD_SECONDS) return UPCOMING_POLL_SECONDS;
        return FAR_OUT_POLL_SECONDS;
    }

    private static void fetch_and_populate(NewsWindow win) {
        var all_league_keys = win.prefs.ordered_sports_league_keys();
        var league_keys = new Gee.ArrayList<string>();
        foreach (var key in all_league_keys) {
            if (win.prefs.sports_league_enabled(key)) league_keys.add(key);
        }
        var results = new Gee.HashMap<string, Gee.ArrayList<GameScore>>();
        int pending = league_keys.size;

        if (pending == 0) {
            render(win, league_keys, results);
            schedule_next_poll(FAR_OUT_POLL_SECONDS);
            return;
        }

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
                    schedule_next_poll(next_poll_seconds(results));
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

            var section = new CategorySection(win, SportsScoresService.display_name_for(league_key), "sports:" + league_key, true, true, SportsScoresService.logo_url_for(league_key));
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
