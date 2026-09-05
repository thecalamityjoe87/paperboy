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
 * Tracks whether any sports game is currently live, independent of whether
 * the user is actually viewing the Sports category, so the sidebar can show
 * a "Live" pill next to the Sports badge at any time. Mirrors the adaptive
 * polling cadence in SportsScoresController (fast while a game is live or
 * about to start, slow otherwise) but runs for the lifetime of the window
 * instead of being gated on prefs.category == "sports".
 *
 * Deliberately does not cache "last good" results the way
 * SportsScoresController does for rendering score cards - a single failed
 * poll here just means the pill briefly reflects "not live" instead of a
 * stale visual, which is an acceptable tradeoff for a cosmetic indicator.
 */
public class SportsLiveIndicatorManager : GLib.Object {
    private const int LIVE_POLL_SECONDS = 45;
    private const int SOON_THRESHOLD_SECONDS = 300;   // next game starts within 5 min
    private const int SOON_POLL_SECONDS = 45;
    private const int UPCOMING_THRESHOLD_SECONDS = 1800; // next game starts within 30 min
    private const int UPCOMING_POLL_SECONDS = 300;
    private const int FAR_OUT_POLL_SECONDS = 1800; // next game is >30 min out, or nothing scheduled

    private weak NewsWindow window;
    private uint timeout_id = 0;
    private bool is_live = false;

    public signal void live_state_changed(bool is_live);

    public SportsLiveIndicatorManager(NewsWindow window) {
        this.window = window;
    }

    ~SportsLiveIndicatorManager() {
        stop();
    }

    public bool get_is_live() {
        return is_live;
    }

    public void start() {
        if (timeout_id != 0) return;
        poll();
    }

    public void stop() {
        if (timeout_id != 0) {
            GLib.Source.remove(timeout_id);
            timeout_id = 0;
        }
        set_live(false);
    }

    private void set_live(bool value) {
        if (is_live == value) return;
        is_live = value;
        live_state_changed(value);
    }

    private void schedule_next(int seconds) {
        if (timeout_id != 0) {
            GLib.Source.remove(timeout_id);
            timeout_id = 0;
        }
        timeout_id = GLib.Timeout.add_seconds(seconds, () => {
            timeout_id = 0;
            poll();
            return false; // one-shot; poll() reschedules once results are in
        });
    }

    private void poll() {
        if (window == null || !window.prefs.sports_live_indicator_enabled || !window.prefs.sports_scores_enabled) {
            stop();
            return;
        }

        var all_league_keys = window.prefs.ordered_sports_league_keys();
        var league_keys = new Gee.ArrayList<string>();
        foreach (var key in all_league_keys) {
            if (window.prefs.sports_league_enabled(key)) league_keys.add(key);
        }

        if (league_keys.size == 0) {
            set_live(false);
            schedule_next(FAR_OUT_POLL_SECONDS);
            return;
        }

        var results = new Gee.HashMap<string, Gee.ArrayList<GameScore>>();
        int pending = league_keys.size;

        // One fetch_league call per league, each constructing its own
        // closure right here - matches SportsScoresController.fetch_and_populate,
        // which fans calls out the same way rather than through a shared
        // helper (see its comment for the use-after-free that was hit
        // during manual testing when it didn't).
        foreach (var league_key in league_keys) {
            SportsScoresService.fetch_league(league_key, (returned_key, games) => {
                if (window == null) return;
                if (games != null) results.set(returned_key, games);

                pending--;
                if (pending <= 0) {
                    finish_poll(results);
                }
            });
        }
    }

    private void finish_poll(Gee.HashMap<string, Gee.ArrayList<GameScore>> results) {
        bool any_live = false;
        GLib.DateTime? soonest_start = null;

        foreach (var games_list in results.values) {
            foreach (var game in games_list) {
                if (game.status == GameStatus.LIVE) {
                    any_live = true;
                } else if (game.status == GameStatus.SCHEDULED && game.start_time != null) {
                    if (soonest_start == null || game.start_time.compare(soonest_start) < 0) {
                        soonest_start = game.start_time;
                    }
                }
            }
        }

        set_live(any_live);

        if (any_live) {
            schedule_next(LIVE_POLL_SECONDS);
            return;
        }

        if (soonest_start == null) {
            schedule_next(FAR_OUT_POLL_SECONDS);
            return;
        }

        int64 seconds_until = soonest_start.difference(new GLib.DateTime.now_utc()) / GLib.TimeSpan.SECOND;
        if (seconds_until <= SOON_THRESHOLD_SECONDS) {
            schedule_next(SOON_POLL_SECONDS);
        } else if (seconds_until <= UPCOMING_THRESHOLD_SECONDS) {
            schedule_next(UPCOMING_POLL_SECONDS);
        } else {
            schedule_next(FAR_OUT_POLL_SECONDS);
        }
    }
}
