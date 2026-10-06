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
            var local = dt.to_local();
            // TRANSLATORS: date before the time in an article's byline, a
            // strftime format ("man strftime"): %b is the abbreviated month,
            // %-d the unpadded day, %Y the year. Reorder to suit, e.g. "%-d %b %Y".
            // xgettext:no-c-format
            string date = format_or(local, _("%b %-d, %Y"), "%b %-d, %Y");
            return date + " • " + format_or(local, clock_time_format(), "%H:%M");
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

        // Timezone-less timestamps ("2026-09-25T13:38:55") are treated as UTC.
        var utc = new GLib.TimeZone.utc();
        var iso = new GLib.DateTime.from_iso8601(s, utc);
        if (iso != null) return iso;

        // Date-only values ("2026-09-25").
        if (s.length == 10) {
            iso = new GLib.DateTime.from_iso8601(s + "T00:00:00", utc);
            if (iso != null) return iso;
        }

        var http_date = Soup.date_time_new_from_http_string(s);
        if (http_date != null) return http_date;

        // Some JSON APIs give a raw Unix epoch
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

        if (seconds < 60) return _("Just now");
        int minutes = (int) (seconds / 60);
        // TRANSLATORS: compact relative times on article cards, where space
        // is tight - abbreviate if your language allows it
        if (minutes < 60) return ngettext("%dm ago", "%dm ago", minutes).printf(minutes);
        int hours = minutes / 60;
        if (hours < 24) return ngettext("%dh ago", "%dh ago", hours).printf(hours);
        int days = hours / 24;
        if (days < 7) return ngettext("%dd ago", "%dd ago", days).printf(days);

        // Older than a week: fall back to a short absolute date ("Aug 27").
        // TRANSLATORS: short date on article cards older than a week, a
        // strftime format ("man strftime"): %b is the abbreviated month and
        // %-d the unpadded day. Reorder to suit, e.g. "%-d %b".
        // xgettext:no-c-format
        return format_or(dt.to_local(), _("%b %-d"), "%b %-d");
    }

    // Page header date, e.g. "Monday, October 5".
    public static string full_date(GLib.DateTime dt) {
        // TRANSLATORS: date in page headers, a strftime format ("man strftime"):
        // %A is the weekday, %B the month and %-d the unpadded day. Reorder to
        // suit, e.g. "%A %-d %B".
        // xgettext:no-c-format
        return format_or(dt, _("%A, %B %-d"), "%A, %B %-d");
    }

    // Weekday and numeric date for game times, e.g. "Mon 10/5".
    public static string short_weekday_date(GLib.DateTime dt) {
        // TRANSLATORS: weekday and date on sports score cards, a strftime
        // format ("man strftime"): %a is the abbreviated weekday, %-m the
        // unpadded month number and %-d the unpadded day. Reorder to suit,
        // e.g. "%a %-d.%-m.".
        // xgettext:no-c-format
        return format_or(dt, _("%a %-m/%-d"), "%a %-m/%-d");
    }

    // A translated strftime format can be broken; fall back to the English one
    // rather than showing nothing.
    private static string format_or(GLib.DateTime dt, string format, string fallback) {
        return dt.format(format) ?? dt.format(fallback) ?? "";
    }

    private static bool clock_format_loaded;
    private static bool clock_12h;
    private static GLib.DBusProxy? settings_portal;

    // strftime format for a time of day, following GNOME's 12h/24h clock setting.
    public static string clock_time_format() {
        if (!clock_format_loaded) {
            clock_format_loaded = true;
            clock_12h = read_clock_format() == "12h";
        }
        return clock_12h ? "%-I:%M %p" : "%H:%M";
    }

    // Settings portal first, since a Flatpak sandbox can't read the host's GSettings.
    private static string? read_clock_format() {
        try {
            settings_portal = new GLib.DBusProxy.for_bus_sync(GLib.BusType.SESSION, GLib.DBusProxyFlags.NONE, null,
                "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings");
            settings_portal.g_signal.connect((sender, signal_name, parameters) => {
                if (signal_name != "SettingChanged") return;
                string ns, key;
                GLib.Variant value;
                parameters.get("(ssv)", out ns, out key, out value);
                if (ns == "org.gnome.desktop.interface" && key == "clock-format" && value.is_of_type(GLib.VariantType.STRING)) {
                    clock_12h = value.get_string() == "12h";
                }
            });
            // Read (unlike the newer ReadOne) exists on every portal version, but nests the value twice.
            var result = settings_portal.call_sync("Read", new GLib.Variant("(ss)", "org.gnome.desktop.interface", "clock-format"),
                GLib.DBusCallFlags.NONE, 1000, null);
            var value = result.get_child_value(0).get_variant();
            if (value.is_of_type(GLib.VariantType.VARIANT)) value = value.get_variant();
            if (value.is_of_type(GLib.VariantType.STRING)) return value.get_string();
        } catch (GLib.Error e) {
            debug("DateUtils: settings portal unavailable for clock-format: %s", e.message);
        }

        var schema = GLib.SettingsSchemaSource.get_default()?.lookup("org.gnome.desktop.interface", true);
        if (schema != null && schema.has_key("clock-format")) {
            return new GLib.Settings.full(schema, null, null).get_string("clock-format");
        }
        return null;
    }
}
