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

public class UrlUtils {
    // Normalize article URLs for stable mapping (strip query params, trailing slash, lowercase host)
    public static string normalize_article_url(string url) {
        if (url == null) return "";
        string u = url.strip();
        // Remove query string entirely (utm and tracking params commonly appended)
        int qpos = u.index_of("?");
        if (qpos >= 0) {
            u = u.substring(0, qpos);
        }
        // Remove trailing slash
        while (u.length > 1 && u.has_suffix("/")) {
            u = u.substring(0, u.length - 1);
        }
        // Lowercase scheme and host portion
        int scheme_end = u.index_of("://");
        if (scheme_end >= 0) {
            int path_start = u.index_of("/", scheme_end + 3);
            string host_part = path_start >= 0 ? u.substring(0, path_start) : u;
            string rest = path_start >= 0 ? u.substring(path_start) : "";
            u = host_part.down() + rest;
        } else {
            u = u.down();
        }
        return u;
    }

    // Extract host portion from a URL (e.g., "https://www.example.com/path" -> "example.com").
    public static string extract_host_from_url(string? url) {
        if (url == null) return "";
        string u = url.strip();
        if (u.length == 0) return "";
        // Strip scheme
        int scheme_end = u.index_of("://");
        if (scheme_end >= 0) u = u.substring(scheme_end + 3);
        // Cut at first slash
        int slash = u.index_of("/");
        if (slash >= 0) u = u.substring(0, slash);
        // Remove port if present
        int colon = u.index_of(":");
        if (colon >= 0) u = u.substring(0, colon);
        u = u.down();
        // Strip common www prefix
        if (u.has_prefix("www.")) u = u.substring(4);
        return u;
    }

    // Turn a host like "example-news.co.uk" into a friendly display string
    // such as "Example News". This is intentionally simple and is only
    // used as a fallback when no explicit source name is available.
    public static string prettify_host(string host) {
        if (host == null) return "News";
        string h = host.strip();
        if (h.length == 0) return "News";
        // Take left-most label as the short name (e.g., "example-news")
        int dot = h.index_of(".");
        if (dot >= 0) h = h.substring(0, dot);
        // Replace hyphens/underscores with spaces and split into words
        h = h.replace("-", " ");
        h = h.replace("_", " ");
        // Capitalize words (ASCII-safe simple capitalization)
        string out = "";
        string[] parts = h.split(" ");
        foreach (var p in parts) {
            if (p.length == 0) continue;
            string w = ascii_capitalize(p);
            out += (out.length > 0 ? " " : "") + w;
        }
        // Handle common host-name quirks and a couple of branded exceptions
        // e.g. "theguardian" -> "The Guardian", "nytimes" -> "NY Times"
        string lower_out = out.down();
        if (lower_out.has_prefix("the") && lower_out.length > 3 && lower_out.index_of(" ") < 0) {
            // Split off the leading "the" into a separate word
            string rest = lower_out.substring(3);
            if (rest.length > 0) {
                // Capitalize the remainder nicely and return
                return "The " + ascii_capitalize(rest);
            }
        }
        // Small exceptions map for well-known sites that are commonly
        // concatenated in hosts.
        if (lower_out == "nytimes" || lower_out == "ny time") return "NY Times";
        if (lower_out == "wsj" || lower_out == "wallstreetjournal" || lower_out == "wallstreet") return "Wall Street Journal";
        if (out.length == 0) return "News";
        return out;
    }

    // Simple ASCII capitalization helper: first char upper, remainder lower.
    private static string ascii_capitalize(string s) {
        if (s == null) return "";
        if (s.length == 0) return s;
        char c = s[0];
        char up = c;
        if (c >= 'a' && c <= 'z') up = (char)(c - 32);
        string first = "%c".printf(up);
        string rest = s.length > 1 ? s.substring(1).down() : "";
        return first + rest;
    }
}
