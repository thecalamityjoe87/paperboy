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

// An article's source as it travels through fetchers and the article
// pipeline: a display name, optionally with a logo URL and (for Paperboy
// API articles) the API's own category, which picks the Front Page row.
// They're carried as one string, "Name||logo_url##category::cat", with
// both extras optional - and this is the only place that format is read
// or written. Saved and History rows store it too, so it can't change
// without migrating them.
public struct SourceLabel {
    private const string LOGO_SEP = "||";
    private const string CATEGORY_SEP = "##category::";

    public string name;         // "" when there is none
    public string? logo_url;    // null when absent or empty
    public string? category;    // null when absent or empty

    public static SourceLabel parse(string? encoded) {
        var label = SourceLabel() { name = "", logo_url = null, category = null };
        if (encoded == null) return label;

        string rest = encoded;
        int cat_idx = rest.index_of(CATEGORY_SEP);
        if (cat_idx >= 0) {
            label.category = non_empty(rest.substring(cat_idx + CATEGORY_SEP.length).strip());
            rest = rest.substring(0, cat_idx);
        }
        int logo_idx = rest.index_of(LOGO_SEP);
        if (logo_idx >= 0) {
            label.logo_url = non_empty(rest.substring(logo_idx + LOGO_SEP.length).strip());
            rest = rest.substring(0, logo_idx);
        }
        label.name = rest.strip();
        return label;
    }

    public static string encode(string? name, string? logo_url = null, string? category = null) {
        string result = name ?? "";
        if (logo_url != null && logo_url.length > 0) result += LOGO_SEP + logo_url;
        if (category != null && category.length > 0) result += CATEGORY_SEP + category;
        return result;
    }

    // The display name alone, e.g. for matching or showing a source
    public static string name_of(string? encoded) {
        // Bound to a local first: reading a field straight off the returned
        // temporary risks Vala freeing it before the value is used
        var label = parse(encoded);
        return label.name;
    }

    private static string? non_empty(string s) {
        return s.length > 0 ? s : null;
    }
}
