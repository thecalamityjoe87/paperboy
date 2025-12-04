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
    // Cache regex patterns to avoid recreating them on every call
    private static Regex? time_regex = null;
    private static Regex? date_regex = null;

    // Convert raw published strings into a short, friendly representation.
    // Examples:
    //  - "2025-11-07T02:38:00.000Z" -> "Nov 7, 2025 • 02:38"
    //  - "02:38:00.000" -> "02:38"
    public static string format_published(string raw) {
        if (raw == null) return "";
        string s = raw.strip();
        if (s.length == 0) return "";

        // If ISO-style date/time (contains 'T'), split into date/time
        string date_part = "";
        string time_part = s;
        int tpos = s.index_of("T");
        if (tpos >= 0 && s.length > tpos) {
            date_part = s.substring(0, tpos);
            if (s.length > tpos + 1)
                time_part = s.substring(tpos + 1);
        }

        // Trim timezone designators from time_part (Z or +hh:mm or -hh:mm)
        int tzpos = time_part.index_of("Z");
        if (tzpos < 0) tzpos = time_part.index_of("+");
        if (tzpos < 0) tzpos = time_part.index_of("-");
        if (tzpos >= 0 && time_part.length > tzpos) time_part = time_part.substring(0, tzpos);

        // Extract HH:MM using regex (cached to avoid repeated compilation)
        try {
            if (time_regex == null) {
                time_regex = new Regex("([0-2][0-9]):([0-5][0-9])", RegexCompileFlags.DEFAULT);
            }
            MatchInfo tm_info;
            if (time_regex.match(time_part, 0, out tm_info)) {
                string hh = tm_info.fetch(1);
                string mm = tm_info.fetch(2);
                string hhmm = "%s:%s".printf(hh, mm);

                if (date_part.length >= 8) {
                    // Try to parse YYYY-MM-DD (cached regex)
                    if (date_regex == null) {
                        date_regex = new Regex("^(\\d{4})-(\\d{2})-(\\d{2})", RegexCompileFlags.DEFAULT);
                    }
                    MatchInfo d_info;
                    if (date_regex.match(date_part, 0, out d_info)) {
                        string year = d_info.fetch(1);
                        string mo = d_info.fetch(2);
                        string day = d_info.fetch(3);
                        string mon_name = "";
                        // Map month number to short name
                        if (mo == "01") mon_name = "Jan";
                        else if (mo == "02") mon_name = "Feb";
                        else if (mo == "03") mon_name = "Mar";
                        else if (mo == "04") mon_name = "Apr";
                        else if (mo == "05") mon_name = "May";
                        else if (mo == "06") mon_name = "Jun";
                        else if (mo == "07") mon_name = "Jul";
                        else if (mo == "08") mon_name = "Aug";
                        else if (mo == "09") mon_name = "Sep";
                        else if (mo == "10") mon_name = "Oct";
                        else if (mo == "11") mon_name = "Nov";
                        else if (mo == "12") mon_name = "Dec";
                        // Trim leading zero from day for nicer display
                        if (day.has_prefix("0") && day.length > 1) day = day.substring(1);
                        // Include year in the display per UX request
                        return "%s %s, %s • %s".printf(mon_name, day, year, hhmm);
                    }
                }

                // Fallback: just return HH:MM
                return hhmm;
            }
        } catch (GLib.Error e) {
            // Regex error, fall through to simple fallback
        }

        // No time matched — strip milliseconds/extra and return trimmed
        int dot = s.index_of(".");
        if (dot >= 0 && s.length > dot) s = s.substring(0, dot);
        if (s.has_suffix("Z") && s.length > 0) s = s.substring(0, s.length - 1);
        return s;
    }
}
