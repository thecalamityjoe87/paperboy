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

/**
 * A saved Local News location: what the user searched and the city it
 * resolved to. Local News searches Google News for `city`.
 */
public class LocalArea : GLib.Object {
    // Prefix for a city's sidebar row id and unread-tracking category.
    public const string ID_PREFIX = "localarea:";

    public string query { get; set; }
    // "City, State", properly capitalized
    public string city { get; set; }

    public LocalArea(string query, string city) {
        this.query = query;
        this.city = proper_case(city);
    }

    // Stable identity used for de-duping and the active-area setting.
    public string key {
        owned get { return city.down(); }
    }

    // e.g. "localarea:dallas, tx"
    public string id {
        owned get { return ID_PREFIX + key; }
    }

    // List label (sidebar, Preferences), e.g. "Dallas".
    public string name {
        owned get { return short_name(city); }
    }

    // Page header label, e.g. "Dallas News".
    public string display_name {
        owned get { return short_name(city) + " News"; }
    }

    // "Dallas, TX" -> "Dallas"
    public static string short_name(string city) {
        int comma = city.index_of(",");
        return (comma > 0 ? city.substring(0, comma) : city).strip();
    }

    // "dallas, tx" -> "Dallas, TX", "WINSTON-SALEM" -> "Winston-Salem".
    // Mixed-case words like "McKinney" keep their interior casing.
    public static string proper_case(string text) {
        string[] parts = text.strip().split(",");
        string[] cased = {};
        foreach (string raw in parts) {
            string part = raw.strip();
            if (part.length == 0) continue;
            // Two-letter state abbreviations
            if (part.char_count() == 2 && part.get_char(0).isalpha() && part.get_char(1).isalpha()) {
                cased += part.up();
                continue;
            }
            string[] words = {};
            foreach (string word in part.split(" ")) {
                if (word.length == 0) continue;
                words += case_word(word);
            }
            cased += string.joinv(" ", words);
        }
        return string.joinv(", ", cased);
    }

    private static string case_word(string word) {
        bool uniform = (word == word.down() || word == word.up());
        string source = uniform ? word.down() : word;

        var sb = new StringBuilder();
        bool cap_next = true;
        int i = 0;
        unichar c;
        while (source.get_next_char(ref i, out c)) {
            sb.append_unichar(cap_next ? c.toupper() : c);
            cap_next = (c == '-');
        }
        return sb.str;
    }
}
