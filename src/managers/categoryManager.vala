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
 * CategoryManager - Centralized category management
 *
 * This class provides a single source of truth for:
 * - What categories exist
 * - Category validation
 * - Category filtering based on view mode
 * - My Feed category management
 */

 public class CategoryManager : GLib.Object {

    private weak NewsPreferences prefs;
    private weak SourceManager source_manager;

    public CategoryManager(NewsPreferences prefs, SourceManager source_manager) {
        this.prefs = prefs;
        this.source_manager = source_manager;
    }


    // Get the current view category
    public string get_current_category() {
        return prefs.category ?? "general";
    }

    // Check if we're in a special view mode (frontpage, topten, myfeed, local_news, or RSS feed)
    public bool is_special_view() {
        string cat = get_current_category();
        return cat == "frontpage" || cat == "topten" || cat == "myfeed" || cat == "local_news" || is_rssfeed_view();
    }

    // Check if we're viewing Front Page
    public bool is_frontpage_view() {
        return get_current_category() == "frontpage";
    }

    // Check if we're viewing Top Ten
    public bool is_topten_view() {
        return get_current_category() == "topten";
    }

    // Check if the current category is "myfeed" (regardless of whether it's enabled)
    // Use this to determine if we're LOOKING AT the My Feed page
    public bool is_myfeed_category() {
        return get_current_category() == "myfeed";
    }

    // Check if we're viewing My Feed AND it's properly enabled
    // Use this to determine if My Feed should SHOW CONTENT
    public bool is_myfeed_view() {
        return is_myfeed_category() && prefs.personalized_feed_enabled;
    }

    // Check if we're viewing Local News
    public bool is_local_news_view() {
        return get_current_category() == "local_news";
    }

    // Check if we're viewing an individual RSS feed
    public bool is_rssfeed_view() {
        string cat = get_current_category();
        return cat.has_prefix("rssfeed:");
    }

    // Get the RSS feed URL from the category (if in RSS feed view)
    // Returns null if not in RSS feed view
    public string? get_rssfeed_url() {
        if (!is_rssfeed_view()) {
            return null;
        }
        string cat = get_current_category();
        // Extract URL after "rssfeed:" prefix
        return extract_feed_url_from_category(cat);
    }

    public string extract_feed_url_from_category(string cat) {
        if (cat.length <= 8) {
            warning("Malformed rssfeed category: too short");
            return "";
        }
        return cat.substring(8); // "rssfeed:".length == 8
    }

    // Check if My Feed is properly configured
    public bool is_myfeed_configured() {
        if (!prefs.personalized_feed_enabled) {
            return false;
        }
        if (prefs.personalized_categories == null || prefs.personalized_categories.size == 0) {
            return false;
        }
        return true;
    }

    // Get categories configured for My Feed
    public ArrayList<string> get_myfeed_categories() {
        var result = new ArrayList<string>();
        if (prefs.personalized_categories != null) {
            foreach (var cat in prefs.personalized_categories) {
                result.add(cat);
            }
        }
        return result;
    }

    // Get categories to fetch for the current view
    // Returns list of categories to fetch articles for
    public ArrayList<string> get_categories_to_fetch() {
        var result = new ArrayList<string>();
        string current = get_current_category();

        // Front Page and Top Ten are handled by backend API
        // Local News uses discovered RSS feeds per user's location
        // RSS feed views fetch from a single RSS feed
        if (current == "frontpage" || current == "topten" || current == "local_news" || is_rssfeed_view()) {
            result.add(current);
            return result;
        }

        // My Feed fetches multiple personalized categories
        if (current == "myfeed") {
            if (is_myfeed_configured()) {
                return get_myfeed_categories();
            }
            //If not configured, return empty (will show overlay)
            return result;
        }

        // Regular single category
        result.add(current);
        return result;
    }

    // Check if an article should be displayed based on category filtering
    // Returns true if article should be shown, false if filtered out
    public bool should_display_article(string article_category) {
        string view_category = get_current_category();

        // Special views have their own logic
        if (view_category == "frontpage" || view_category == "topten" || view_category == "local_news") {
            return true; //Backend determines what to show
        }

        // RSS feed view: accept all articles (filtering happens during fetch)
        if (is_rssfeed_view()) {
            return true;
        }

        // My Feed filters by personalized categories
        if (view_category == "myfeed") {
            // Custom RSS sources use "myfeed" as their category - always accept those
            if (article_category == "myfeed") {
                return true;
            }
            if (!is_myfeed_configured()) {
                return false; //Drop everything if not configured
            }
            // Check if article's category is in personalized list
            foreach (var cat in prefs.personalized_categories) {
                if (cat == article_category) {
                    return true;
                }
            }
            return false; // Not in personalized categories
        }

        // Regular single-category view: must match exactly
        return view_category == article_category;
    }

    // Get display name for a category
    public static string get_category_display_name(string category) {
        switch (category) {
            case "general": return "General";
            case "us": return "U.S.";
            case "technology": return "Technology";
            case "business": return "Business";
            case "science": return "Science";
            case "sports": return "Sports";
            case "health": return "Health";
            case "entertainment": return "Entertainment";
            case "politics": return "Politics";
            case "lifestyle": return "Lifestyle";
            case "markets": return "Markets";
            case "industries": return "Industries";
            case "economics": return "Economics";
            case "wealth": return "Wealth";
            case "green": return "Green";
            case "frontpage": return "Front Page";
            case "topten": return "Top Ten";
            case "myfeed": return "My Feed";
            case "local_news": return "Local News";
            default: return category;
        }
    }

    // Get icon name for a category
    public static string get_category_icon(string category) {
        switch (category) {
            case "general": return "view-grid-symbolic";
            case "us": return "flag-outline-thick-symbolic";
            case "technology": return "computer-symbolic";
            case "business": return "briefcase-symbolic";
            case "science": return "flask-symbolic";
            case "sports": return "trophy-symbolic";
            case "health": return "heart-symbolic";
            case "entertainment": return "music-note-symbolic";
            case "politics": return "emblem-system-symbolic";
            case "lifestyle": return "home-symbolic";
            case "markets": return "stock-market-symbolic";
            case "industries": return "factory-symbolic";
            case "economics": return "currency-dollar-symbolic";
            case "wealth": return "money-symbolic";
            case "green": return "weather-clear-symbolic";
            case "frontpage": return "star-symbolic";
            case "topten": return "trophy-symbolic";
            case "myfeed": return "user-bookmarks-symbolic";
            case "local_news": return "mark-location-symbolic";
            default: return "view-grid-symbolic";
        }
    }

    // Check if a category has article limits applied (most categories do).
    // Used by ArticleManager to determine when to queue overflow articles.
    public static bool is_limited_category(string category) {
        return (
            category == "general" ||
            category == "us" ||
            category == "sports" ||
            category == "science" ||
            category == "health" ||
            category == "technology" ||
            category == "business" ||
            category == "entertainment" ||
            category == "politics" ||
            category == "lifestyle" ||
            category == "markets" ||
            category == "industries" ||
            category == "economics" ||
            category == "wealth" ||
            category == "green" ||
            category == "local_news" ||
            category == "myfeed" ||
            category.has_prefix("rssfeed:")
        );
    }

    // Check if this is a regular news category (not frontpage, topten, myfeed, local_news, saved, or RSS).
    // Used for filtering and display logic.
    public static bool is_regular_news_category(string category) {
        return (
            category == "general" ||
            category == "us" ||
            category == "sports" ||
            category == "science" ||
            category == "health" ||
            category == "technology" ||
            category == "business" ||
            category == "entertainment" ||
            category == "politics" ||
            category == "lifestyle" ||
            category == "markets" ||
            category == "industries" ||
            category == "economics" ||
            category == "wealth" ||
            category == "green"
        );
    }
}
