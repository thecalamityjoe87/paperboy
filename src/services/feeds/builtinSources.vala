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

// One built-in news outlet's plain data. Per-source behavior (which
// fetcher, which categories, placeholder colors) stays with the code that
// uses it - see NewsService.fetch() and the fetchers themselves.
public struct BuiltinSource {
    public NewsSource source;
    public string id;           // preferences/settings id, e.g. "nytimes"
    public string name;         // full name, for source pickers
    public string short_name;   // card badges, labels and placeholders
    public string description;  // one-line blurb in Preferences
    public string logo_file;    // bundled logo under data/icons
    public string favicon_url;
    public string url_hints;    // "|"-separated URL substrings that identify its articles
    public string name_hints;   // "|"-separated source-name substrings that identify it
}

// The table of built-in outlets. Adding an outlet means adding a row here
// (plus its NewsSource value and fetcher). Compile-time constant, so it's
// safe to read from worker threads.
public class BuiltinSources {
    // Display order for pickers. Also the order URLs are matched in, so an
    // earlier row's hints win when a URL matches more than one.
    public const BuiltinSource[] ALL = {
        { NewsSource.GUARDIAN, "guardian", "The Guardian", "The Guardian",
          "Independent global news and analysis",
          "guardian-logo.png", "https://www.theguardian.com/favicon.ico", "guardian", "guardian" },
        { NewsSource.BBC, "bbc", "BBC News", "BBC News",
          "Comprehensive international and UK reporting",
          "bbc-logo.png", "https://www.bbc.co.uk/favicon.ico", "bbc.", "bbc" },
        { NewsSource.NEW_YORK_TIMES, "nytimes", "New York Times", "NY Times",
          "In-depth journalism across major categories",
          "nytimes-logo.png", "https://www.nytimes.com/favicon.ico", "nytimes|nyti.ms", "nytimes|ny times|new york times" },
        { NewsSource.BLOOMBERG, "bloomberg", "Bloomberg", "Bloomberg",
          "Market, business, and finance coverage",
          "bloomberg-logo.png", "https://www.bloomberg.com/favicon.ico", "bloomberg", "bloomberg" },
        { NewsSource.WALL_STREET_JOURNAL, "wsj", "Wall Street Journal", "Wall Street Journal",
          "Business, economic, and political reporting",
          "wsj-logo.png", "https://www.wsj.com/favicon.ico", "wsj.com|dowjones", "wsj|wall street" },
        { NewsSource.ABC_NEWS, "abc", "ABC News", "ABC News",
          "US network coverage across politics, business, and more",
          "abc-logo.png", "https://abcnews.go.com/favicon.ico", "abcnews", "abc news|abcnews" },
        { NewsSource.NPR, "npr", "NPR", "NPR",
          "Public radio news and feature storytelling",
          "npr-logo.png", "https://www.npr.org/favicon.ico", "npr.org", "npr" },
        { NewsSource.FOX, "fox", "Fox News", "Fox News",
          "U.S. politics, headlines, and commentary",
          "foxnews-logo.png", "https://www.foxnews.com/favicon.ico", "foxnews|fox.com", "fox" },
        { NewsSource.PBS, "pbs", "PBS NewsHour", "PBS NewsHour",
          "Neutral, in-depth public affairs reporting",
          "pbs-logo.png", "https://www.pbs.org/favicon.ico", "pbs.org", "pbs" }
    };

    // The outlet with this preferences id; null for anything else
    // (e.g. a "custom:<url>" feed).
    public static BuiltinSource? for_id(string? id) {
        if (id == null) return null;
        foreach (unowned BuiltinSource s in ALL) {
            if (s.id == id) return s;
        }
        return null;
    }

    // Null for NewsSource.UNKNOWN.
    public static BuiltinSource? for_source(NewsSource source) {
        foreach (unowned BuiltinSource s in ALL) {
            if (s.source == source) return s;
        }
        return null;
    }

    public static string short_name(NewsSource source) {
        var s = for_source(source);
        return s != null ? s.short_name : "News";
    }

    // Full path of the outlet's bundled logo, or null if it has none or
    // the file can't be found.
    public static string? logo_path(NewsSource source) {
        var s = for_source(source);
        if (s == null) return null;
        return DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", s.logo_file));
    }

    // The outlet whose name hints appear in `name` (a plain display name,
    // not an encoded "name||logo" string), or UNKNOWN.
    public static NewsSource from_name(string? name) {
        if (name == null || name.length == 0) return NewsSource.UNKNOWN;
        string low = name.down();
        foreach (unowned BuiltinSource s in ALL) {
            foreach (string hint in s.name_hints.split("|")) {
                if (low.contains(hint)) return s.source;
            }
        }
        return NewsSource.UNKNOWN;
    }

    // The outlet whose URL hints appear in `url`, or UNKNOWN. Callers
    // never default an unknown URL to the user's preferred source, to
    // avoid showing the wrong branding.
    public static NewsSource from_url(string? url) {
        if (url == null || url.length == 0) return NewsSource.UNKNOWN;
        string low = url.down();
        foreach (unowned BuiltinSource s in ALL) {
            foreach (string hint in s.url_hints.split("|")) {
                if (low.contains(hint)) return s.source;
            }
        }
        return NewsSource.UNKNOWN;
    }
}
