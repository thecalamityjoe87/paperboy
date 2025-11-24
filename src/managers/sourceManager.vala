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

/*
 *SourceManager - Centralized source management
 *
 * This class provides a single source of truth for:
 * - Which sources are enabled
 * - Source capabilities (categories, special behavior)
 * - Source inference from URLs
 * - Source validation and filtering
 */


 public class SourceManager : GLib.Object {

    // All available built-in sources
    private const string[] ALL_BUILTIN_SOURCES = {
        "guardian", "reddit", "bbc", "nytimes", "wsj",
        "bloomberg", "reuters", "npr", "fox"
    };

    // Currently enabled sources (references prefs)
    private weak NewsPreferences prefs;

    public SourceManager(NewsPreferences prefs) {
        this.prefs = prefs;
    }

    // Get list of currently enabled sources
    public ArrayList<string> get_enabled_sources() {
        if (prefs.preferred_sources == null || prefs.preferred_sources.size == 0) {
            // Default to all sources if none specified
            var result = new ArrayList<string>();
            foreach (var src in ALL_BUILTIN_SOURCES) {
                result.add(src);
            }
            return result;
        }
        return prefs.preferred_sources;
    }

    // Check if we're in single-source mode
    public bool is_single_source_mode() {
        var enabled = get_enabled_sources();
        return enabled.size == 1;
    }

    // Check if we're in multi-source mode
    public bool is_multi_source_mode() {
        var enabled = get_enabled_sources();
        return enabled.size > 1;
    }

    // Get the single enabled source (only valid in single-source mode)
    public string? get_single_source() {
        var enabled = get_enabled_sources();
        if (enabled.size == 1) {
            return enabled.get(0);
        }
        return null;
    }

    // Check if a specific source is enabled
    public bool is_source_enabled(string source_id) {
        var enabled = get_enabled_sources();
        foreach (var src in enabled) {
            if (src == source_id) {
                return true;
            }
        }
        return false;
    }

    // Convert source ID string to NewsSource enum
    public static NewsSource source_id_to_enum(string source_id) {
        switch (source_id) {
            case "guardian": return NewsSource.GUARDIAN;
            case "reddit": return NewsSource.REDDIT;
            case "bbc": return NewsSource.BBC;
            case "nytimes": return NewsSource.NEW_YORK_TIMES;
            case "wsj": return NewsSource.WALL_STREET_JOURNAL;
            case "bloomberg": return NewsSource.BLOOMBERG;
            case "reuters": return NewsSource.REUTERS;
            case "npr": return NewsSource.NPR;
            case "fox": return NewsSource.FOX;
            default: return NewsSource.GUARDIAN; // fallback
        }
    }

    // Convert NewsSource enum to source ID string
    public static string source_enum_to_id(NewsSource source) {
        switch (source) {
            case NewsSource.GUARDIAN: return "guardian";
            case NewsSource.REDDIT: return "reddit";
            case NewsSource.BBC: return "bbc";
            case NewsSource.NEW_YORK_TIMES: return "nytimes";
            case NewsSource.WALL_STREET_JOURNAL: return "wsj";
            case NewsSource.BLOOMBERG: return "bloomberg";
            case NewsSource.REUTERS: return "reuters";
            case NewsSource.NPR: return "npr";
            case NewsSource.FOX: return "fox";
            default: return "guardian";
        }
    }

    // Get list of enabled sources as NewsSource enums
    public ArrayList<NewsSource> get_enabled_source_enums() {
        var result = new ArrayList<NewsSource>();
        var enabled = get_enabled_sources();
        foreach (var src_id in enabled) {
            result.add(source_id_to_enum(src_id));
        }
        return result;
    }

    // Infer source from URL
    public static NewsSource infer_source_from_url(string? url) {
        if (url == null || url.length == 0) {
            return NewsSource.GUARDIAN; // fallback
        }

        string low = url.down();

        if (low.index_of("guardian") >= 0 || low.index_of("theguardian") >= 0) {
            return NewsSource.GUARDIAN;
        }
        if (low.index_of("reddit") >= 0 || low.index_of("redd.it") >= 0) {
            return NewsSource.REDDIT;
        }
        if (low.index_of("bbc.co") >= 0 || low.index_of("bbc.") >= 0) {
            return NewsSource.BBC;
        }
        if (low.index_of("nytimes") >= 0 || low.index_of("nyti.ms") >= 0) {
            return NewsSource.NEW_YORK_TIMES;
        }
        if (low.index_of("wsj.com") >= 0 || low.index_of("on.wsj.com") >= 0) {
            return NewsSource.WALL_STREET_JOURNAL;
        }
        if (low.index_of("bloomberg") >= 0) {
            return NewsSource.BLOOMBERG;
        }
        if (low.index_of("reuters") >= 0) {
            return NewsSource.REUTERS;
        }
        if (low.index_of("npr.org") >= 0) {
            return NewsSource.NPR;
        }
        if (low.index_of("foxnews") >= 0 || low.index_of("fox.com") >= 0) {
            return NewsSource.FOX;
        }

        return NewsSource.GUARDIAN; // fallback
    }


    // Infer source ID from URL
    public static string infer_source_id_from_url(string? url) {
        return source_enum_to_id(infer_source_from_url(url));
    }


    // Check if a source supports a given category
    public static bool source_supports_category(string source_id, string category) {
        // Bloomberg has exclusive categories
        if (source_id == "bloomberg") {
            return is_bloomberg_category(category);
        }

        // Special views are handled separately
        if (category == "frontpage" || category == "topten" || category == "local_news") {
            return false; // These are backend aggregates, not source-specific
        }

        // "myfeed" is a special personalized view
        if (category == "myfeed") {
            return true;
        }

        // Check if this is a Bloomberg-exclusive category
        if (is_bloomberg_exclusive_category(category)) {
            return source_id == "bloomberg";
        }

        // Lifestyle is not provided by BBC, Reddit, Reuters
        if (category == "lifestyle") {
            if (source_id == "bbc" || source_id == "reddit" || source_id == "reuters") {
                return false;
            }
        }

        // All other sources support standard categories
        return is_standard_category(category);
    }


    // Check if a category is a Bloomberg category (including overlaps)
    public static bool is_bloomberg_category(string category) {
        switch (category) {
            case "markets":
            case "industries":
            case "economics":
            case "wealth":
            case "green":
            case "politics":
            case "technology":
                return true;
            default:
                return false;
        }
    }


    // Check if a category is Bloomberg-exclusive (not available on other sources)
    public static bool is_bloomberg_exclusive_category(string category) {
        switch (category) {
            case "markets":
            case "industries":
            case "economics":
            case "wealth":
            case "green":
                return true;
            default:
                return false;
        }
    }


    // Check if a category is a standard category (available on most sources)
    public static bool is_standard_category(string category) {
        switch (category) {
            case "general":
            case "us":
            case "technology":
            case "business":
            case "science":
            case "sports":
            case "health":
            case "entertainment":
            case "politics":
            case "lifestyle":
                return true;
            default:
                return false;
        }
    }


    // Get all categories supported by currently enabled sources
    public ArrayList<string> get_supported_categories() {
        var enabled = get_enabled_sources();

        // If only Bloomberg is enabled, return only Bloomberg categories
        if (enabled.size == 1 && enabled.get(0) == "bloomberg") {
            return get_bloomberg_categories();
        }

        // If Bloomberg is one of multiple sources, include both Bloomberg and standard categories
        if (enabled.size > 1 && is_source_enabled("bloomberg")) {
            var result = get_standard_categories();
            // Add Bloomberg-exclusive categories
            result.add("markets");
            result.add("industries");
            result.add("economics");
            result.add("wealth");
            result.add("green");
            return result;
        }

        // Otherwise, return standard categories
        return get_standard_categories();
    }


    // Get standard categories
    public static ArrayList<string> get_standard_categories() {
        var result = new ArrayList<string>();
        result.add("general");
        result.add("us");
        result.add("technology");
        result.add("business");
        result.add("science");
        result.add("sports");
        result.add("health");
        result.add("entertainment");
        result.add("politics");
        result.add("lifestyle");
        return result;
    }


    // Get Bloomberg categories
    public static ArrayList<string> get_bloomberg_categories() {
        var result = new ArrayList<string>();
        result.add("markets");
        result.add("industries");
        result.add("economics");
        result.add("wealth");
        result.add("green");
        result.add("politics");
        result.add("technology");
        return result;
    }


    // Filter enabled sources to only those that support the given category
    public ArrayList<string> get_sources_for_category(string category) {
        var result = new ArrayList<string>();
        var enabled = get_enabled_sources();

        foreach (var src_id in enabled) {
            if (source_supports_category(src_id, category)) {
                result.add(src_id);
            }
        }

        return result;
    }


    // Check if an article should be displayed based on source filtering
    // Returns true if article should be shown, false if filtered out
    public bool should_display_article(string article_url, string category) {
        // Front Page, Top Ten, and Local News are always shown (backend aggregates)
        if (category == "frontpage" || category == "topten" || category == "local_news") {
            return true;
        }

        // Infer article's source
        string article_source_id = infer_source_id_from_url(article_url);

        // Check if article's source is enabled
        if (!is_source_enabled(article_source_id)) {
            return false;
        }

        // Check if the source supports this category
        if (!source_supports_category(article_source_id, category)) {
            return false;
        }

        return true;
    }
}
