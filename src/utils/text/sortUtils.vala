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

public class SortUtils : GLib.Object {
    // "The Verge" sorts as "Verge" - matches how libraries/bibliographies
    // alphabetize titles, ignoring a leading article.
    public static string title_sort_key(string title) {
        string t = title.strip();
        string lower = t.down();
        if (lower.has_prefix("the ") && t.length > 4) {
            t = t.substring(4);
        }
        return t.down();
    }

    public static int compare_titles(string a, string b) {
        return GLib.strcmp(title_sort_key(a), title_sort_key(b));
    }
}
