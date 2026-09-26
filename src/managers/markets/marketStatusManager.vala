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

/**
 * Tracks whether the US stock market is currently in its regular trading
 * session, independent of whether the user is actually viewing Business, so
 * the sidebar can show an "Open" pill next to the Business badge at any
 * time. Mirrors SportsLiveIndicatorManager's shape, but this is a pure
 * clock computation (regular hours only, no holiday calendar) rather than a
 * network poll, so it just rechecks the time once a minute.
 */
public class MarketStatusManager : GLib.Object {
    private const int POLL_SECONDS = 60;

    private weak NewsWindow window;
    private uint timeout_id = 0;
    private bool is_open = false;

    public signal void market_open_changed(bool is_open);

    public MarketStatusManager(NewsWindow window) {
        this.window = window;
    }

    ~MarketStatusManager() {
        stop();
    }

    public bool get_is_open() {
        return is_open;
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
    }

    private void set_open(bool value) {
        if (is_open == value) return;
        is_open = value;
        market_open_changed(value);
    }

    private void poll() {
        set_open(compute_is_open());
        timeout_id = GLib.Timeout.add_seconds(POLL_SECONDS, () => {
            timeout_id = 0;
            poll();
            return false; // one-shot; poll() reschedules itself
        });
    }

    // Regular session only (9:30am-4:00pm US Eastern, Monday-Friday) - no
    // market holiday calendar, since the app has no source for one. Good
    // enough for a cosmetic sidebar pill.
    private static bool compute_is_open() {
        var tz = new GLib.TimeZone("America/New_York");
        var now = new GLib.DateTime.now(tz);

        int weekday = now.get_day_of_week(); // 1=Monday .. 7=Sunday
        if (weekday < 1 || weekday > 5) return false;

        int minutes_since_midnight = now.get_hour() * 60 + now.get_minute();
        const int OPEN_MINUTES = 9 * 60 + 30;
        const int CLOSE_MINUTES = 16 * 60;
        return minutes_since_midnight >= OPEN_MINUTES && minutes_since_midnight < CLOSE_MINUTES;
    }
}
