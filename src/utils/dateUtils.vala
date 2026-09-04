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

public class DateUtils {
    // Convert raw published strings into a short, friendly representation.
    // Examples:
    //  - "2025-11-07T02:38:00.000Z" -> "Nov 7, 2025 • 02:38"
    //  - "Thu, 03 Sep 2026 18:53:15 -0400" (RSS's RFC 822 <pubDate>, used by
    //    most RSS feeds including PBS NewsHour's) -> "Sep 3, 2026 • 18:53"
    //
    // Delegates parsing to parse_published_datetime, which already handles
    // both shapes correctly, rather than hand-rolling date/time extraction
    // here a second time. This function used to do its own regex-based
    // parsing that only recognized the ISO shape (splitting on a literal
    // "T"), so any RFC 822 date - which has no "T" at all - fell through to
    // returning just the bare time with no date, or nothing usable.
    public static string format_published(string raw) {
        if (raw == null) return "";
        string s = raw.strip();
        if (s.length == 0) return "";

        var dt = parse_published_datetime(s);
        if (dt != null) {
            return dt.to_local().format("%b %-d, %Y • %H:%M");
        }

        // Unrecognized format - fall back to the old best-effort string
        // trimming rather than showing nothing at all.
        int dot = s.index_of(".");
        if (dot >= 0 && s.length > dot) s = s.substring(0, dot);
        if (s.has_suffix("Z") && s.length > 0) s = s.substring(0, s.length - 1);
        return s;
    }

    // Parse a raw published string into an absolute GLib.DateTime, trying
    // both shapes seen in the wild: RSS's RFC 822 <pubDate> (e.g. "Thu, 03
    // Sep 2026 07:55:42 -0400") and ISO 8601 (e.g. from JSON-LD/APIs, "2026-
    // 09-03T11:56:14.000Z"). Returns null if neither parser recognizes it.
    public static GLib.DateTime? parse_published_datetime(string? raw) {
        if (raw == null) return null;
        string s = raw.strip();
        if (s.length == 0) return null;

        var iso = new GLib.DateTime.from_iso8601(s, null);
        if (iso != null) return iso;

        var http_date = Soup.date_time_new_from_http_string(s);
        if (http_date != null) return http_date;

        // Some JSON APIs (e.g. Reddit's created_utc) give a raw Unix epoch
        // seconds value instead of a formatted date string.
        double epoch_seconds;
        if (double.try_parse(s, out epoch_seconds)) {
            return new GLib.DateTime.from_unix_utc((int64) epoch_seconds);
        }

        return null;
    }

    // Short relative-time label for article cards, matching what most RSS
    // readers/Apple News show under a title: "Just now", "7m ago", "7h ago",
    // "3d ago", falling back to an absolute short date once it's old enough
    // that "Xd ago" stops being a useful at-a-glance signal.
    public static string time_ago(string? raw) {
        var dt = parse_published_datetime(raw);
        if (dt == null) return "";

        int64 seconds = new GLib.DateTime.now_utc().difference(dt) / GLib.TimeSpan.SECOND;
        if (seconds < 0) seconds = 0; // clock skew / future timestamp

        if (seconds < 60) return "Just now";
        int64 minutes = seconds / 60;
        if (minutes < 60) return "%sm ago".printf(minutes.to_string());
        int64 hours = minutes / 60;
        if (hours < 24) return "%sh ago".printf(hours.to_string());
        int64 days = hours / 24;
        if (days < 7) return "%sd ago".printf(days.to_string());

        // Older than a week: fall back to a short absolute date ("Aug 27").
        string[] months = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
        return "%s %d".printf(months[dt.get_month() - 1], dt.get_day_of_month());
    }
}
