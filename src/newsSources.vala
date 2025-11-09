/*
 * Copyright (C) 2025  Isaac Joseph <calamityjoe87@gmail.com>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

using GLib;
using Tools;

public enum NewsSource {
    BBC,
    GUARDIAN,
    NEW_YORK_TIMES,
    WALL_STREET_JOURNAL,
    REDDIT,
    BLOOMBERG,
    REUTERS,
    NPR,
    FOX
}

public delegate void SetLabelFunc(string text);
public delegate void ClearItemsFunc();
public delegate void AddItemFunc(string title, string url, string? thumbnail_url, string category_id, string? source_name);

public class NewsSources {
    // Entry point
    public static void fetch(
        NewsSource source,
        string current_category,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        // Handle "all" category by fetching from multiple categories for other sources
        if (current_category == "all") {
            fetch_all_categories(source, current_search_query, session, set_label, clear_items, add_item);
            return;
        }
        switch (source) {
            case NewsSource.GUARDIAN:
                fetch_guardian(current_category, current_search_query, session, set_label, clear_items, add_item);
                break;
            case NewsSource.WALL_STREET_JOURNAL:
                fetch_wsj(current_category, current_search_query, session, set_label, clear_items, add_item);
                break;
            case NewsSource.REDDIT:
                fetch_reddit(current_category, current_search_query, session, set_label, clear_items, add_item);
                break;
            case NewsSource.BBC:
                fetch_bbc(current_category, current_search_query, session, set_label, clear_items, add_item);
                break;
            case NewsSource.NEW_YORK_TIMES:
                fetch_nyt(current_category, current_search_query, session, set_label, clear_items, add_item);
                break;
            case NewsSource.BLOOMBERG:
                fetch_bloomberg(current_category, current_search_query, session, set_label, clear_items, add_item);
                break;
            case NewsSource.REUTERS:
                fetch_reuters(current_category, current_search_query, session, set_label, clear_items, add_item);
                break;
            case NewsSource.NPR:
                fetch_npr(current_category, current_search_query, session, set_label, clear_items, add_item);
                break;
            case NewsSource.FOX:
                fetch_fox(current_category, current_search_query, session, set_label, clear_items, add_item);
                break;
        }
    }

    // Fetch mixed news from all categories
    private static void fetch_all_categories(
        NewsSource source,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        string source_name = get_source_name(source);
        if (current_search_query.length > 0) {
            set_label(@"Search Results: \"$(current_search_query)\" in All Categories — $(source_name)");
        } else {
            set_label(@"All Categories — $(source_name)");
        }
        clear_items();

        // Better randomization: shuffle categories and select a random subset
        string[] all_categories = { "general", 
                                    "technology", 
                                    "us", 
                                    "science", 
                                    "sports", 
                                    "health", 
                                    "entertainment", 
                                    "politics", 
                                    "lifestyle" };

    // If the selected source is Bloomberg, restrict "All Categories" to Bloomberg's available categories
        if (source == NewsSource.BLOOMBERG) {
            all_categories = new string[] { "markets", 
                                            "industries", 
                                            "economics", 
                                            "wealth", 
                                            "green", 
                                            "politics", 
                                            "technology" };
        }
        
        // Shuffle the categories array for random order
        for (int i = all_categories.length - 1; i > 0; i--) {
            int j = Random.int_range(0, i + 1);
            string temp = all_categories[i];
            all_categories[i] = all_categories[j];
            all_categories[j] = temp;
        }
        
        // Select 5-7 categories randomly (not all 9 every time)
        int num_categories = Random.int_range(5, 8);
        string[] selected_categories = new string[num_categories];
        for (int i = 0; i < num_categories; i++) {
            selected_categories[i] = all_categories[i];
        }

        foreach (string category in selected_categories) {
            // Copy loop variable into a local so each timeout closure captures
            // its own category (avoids the common closure-capture bug).
            string cat = category;
            // Use more varied delays between requests (200ms to 2 seconds)
            Timeout.add(Random.int_range(200, 2000), () => {
                switch (source) {
                    case NewsSource.GUARDIAN:
                        fetch_guardian(category, current_search_query, session, 
                            (text) => { /* Keep "All Categories" label */ },
                            () => { /* Don't clear items */ }, 
                            add_item);
                        break;
                    case NewsSource.WALL_STREET_JOURNAL:
                        fetch_google_domain(category, current_search_query, session, 
                            (text) => { /* Keep "All Categories" label */ },
                            () => { /* Don't clear items */ }, 
                            add_item, "wsj.com", "Wall Street Journal");
                        break;
                    case NewsSource.REDDIT:
                        fetch_reddit(category, current_search_query, session, 
                            (text) => { /* Keep "All Categories" label */ },
                            () => { /* Don't clear items */ }, 
                            add_item);
                        break;
                    case NewsSource.BBC:
                        fetch_bbc(category, current_search_query, session, 
                            (text) => { /* Keep "All Categories" label */ },
                            () => { /* Don't clear items */ }, 
                            add_item);
                        break;
                    case NewsSource.NEW_YORK_TIMES:
                        fetch_nyt(category, current_search_query, session, 
                            (text) => { /* Keep "All Categories" label */ },
                            () => { /* Don't clear items */ }, 
                            add_item);
                        break;
                    case NewsSource.BLOOMBERG:
                        // For Bloomberg prefer dedicated feed fetching so categories
                        // match Bloomberg's available sections instead of a generic
                        // Google site search.
                        fetch_bloomberg(cat, current_search_query, session,
                            (text) => { /* Keep "All Categories" label */ },
                            () => { /* Don't clear items */ },
                            add_item);
                        break;
                    case NewsSource.REUTERS:
                        fetch_reuters(category, current_search_query, session, 
                            (text) => { /* Keep "All Categories" label */ },
                            () => { /* Don't clear items */ }, 
                            add_item);
                        break;
                    case NewsSource.NPR:
                        fetch_npr(category, current_search_query, session, 
                            (text) => { /* Keep "All Categories" label */ },
                            () => { /* Don't clear items */ }, 
                            add_item);
                        break;
                    case NewsSource.FOX:
                        fetch_fox(category, current_search_query, session, 
                            (text) => { /* Keep "All Categories" label */ },
                            () => { /* Don't clear items */ }, 
                            add_item);
                        break;
                }
                return false; // Don't repeat the timeout
            });
        }
    }

    // Helpers
    // Utility to strip HTML tags from a string (moved here to live with other helpers)
    private static string strip_html(string input) {
        // Remove all tags
        var regex = new Regex("<[^>]+>", RegexCompileFlags.DEFAULT);
        return regex.replace(input, -1, 0, "");
    }
    private static string category_display_name(string cat) {
        switch (cat) {
            case "all": return "All Categories";
            case "myfeed": return "My Feed";
            case "general": return "World News";
            case "us": return "US News";
            case "technology": return "Technology";
            case "markets": return "Markets";
            case "industries": return "Industries";
            case "economics": return "Economics";
            case "wealth": return "Wealth";
            case "green": return "Green";
            case "science": return "Science";
            case "sports": return "Sports";
            case "health": return "Health";
            case "entertainment": return "Entertainment";
            case "politics": return "Politics";
            case "lifestyle": return "Lifestyle";
        }
        return "News";
    }

    private static string get_source_name(NewsSource source) {
        switch (source) {
            case NewsSource.GUARDIAN:
                return "The Guardian";
            case NewsSource.WALL_STREET_JOURNAL:
                return "Wall Street Journal";
            case NewsSource.BBC:
                return "BBC News";
            case NewsSource.REDDIT:
                return "Reddit";
            case NewsSource.NEW_YORK_TIMES:
                return "New York Times";
            case NewsSource.BLOOMBERG:
                return "Bloomberg";
            case NewsSource.REUTERS:
                return "Reuters";
            case NewsSource.NPR:
                return "NPR";
            case NewsSource.FOX:
                return "Fox News";
            default:
                return "News";
        }
    }

    // Return whether a given NewsSource can provide articles for the
    // requested category. This is used by the UI when multiple sources are
    // selected: if a category (e.g. "markets") is chosen that some sources
    // don't support (Bloomberg-specific sections), we exclude those sources
    // from the multi-source fetch so only compatible sources are queried.
    public static bool supports_category(NewsSource source, string category) {
        // Only Bloomberg needs special handling: it exposes a narrower set
        // of dedicated sections. All other sources can be considered to
        // support the common categories (and many use site-search fallbacks).
        if (source == NewsSource.BLOOMBERG) {
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
        return true;
    }


    private static void fetch_google_domain(
        string current_category,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item,
        string domain,
        string source_name
    ) {
        string base_url = "https://news.google.com/rss/search";
        string ceid = "hl=en-US&gl=US&ceid=US:en";
        string category_name = category_display_name(current_category);
        string query = @"site:$(domain)";
        if (current_search_query.length > 0) {
            query = query + " " + current_search_query;
        }
        string url = @"$(base_url)?q=$(Uri.escape_string(query))&$(ceid)";
        
        RssParser.fetch_rss_url(url, source_name, category_name, current_category, current_search_query, session, set_label, clear_items, add_item);
    }

    private static void fetch_nyt(
        string current_category,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        string base_url = "https://rss.nytimes.com/services/xml/rss/nyt/";
        string path = "World.xml";
        switch (current_category) {
            case "us":
                path = "US.xml";
                break;
            case "technology":
                path = "Technology.xml";
                break;
            case "science":
                path = "Science.xml";
                break;
            case "sports":
                path = "Sports.xml";
                break;
            case "health":
                path = "Health.xml";
                break;
            case "politics":
            case "entertainment":
            case "lifestyle":
                // Use Google site search for reliable category coverage
                fetch_google_domain(current_category, current_search_query, session, set_label, clear_items, add_item, "nytimes.com", "New York Times");
                return;
            default:
                path = "World.xml";
                break;
        }
        if (current_search_query.length > 0) {
            fetch_google_domain(current_category, current_search_query, session, set_label, clear_items, add_item, "nytimes.com", "New York Times");
            return;
        }
    RssParser.fetch_rss_url(@"$(base_url)$(path)", "New York Times", category_display_name(current_category), current_category, current_search_query, session, set_label, clear_items, add_item);
    }

    private static void fetch_bbc(
        string current_category,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        if (current_search_query.length > 0) {
            fetch_google_domain(current_category, current_search_query, session, set_label, clear_items, add_item, "bbc.co.uk", "BBC News");
            return;
        }
        string url = "https://feeds.bbci.co.uk/news/world/rss.xml";
        switch (current_category) {
            case "technology":
                url = "https://feeds.bbci.co.uk/news/technology/rss.xml";
                break;
            case "science":
                url = "https://feeds.bbci.co.uk/news/science_and_environment/rss.xml";
                break;
            case "sports":
                url = "https://feeds.bbci.co.uk/sport/rss.xml";
                break;
            case "health":
                url = "https://feeds.bbci.co.uk/news/health/rss.xml";
                break;
            case "us":
                url = "https://feeds.bbci.co.uk/news/world/us_and_canada/rss.xml";
                break;
            case "politics":
                url = "https://feeds.bbci.co.uk/news/politics/rss.xml";
                break;
            case "entertainment":
                url = "https://feeds.bbci.co.uk/news/entertainment_and_arts/rss.xml";
                break;
            case "lifestyle":
                // No clear lifestyle feed; use site search to approximate
                fetch_google_domain(current_category, current_search_query, session, set_label, clear_items, add_item, "bbc.co.uk", "BBC News");
                return;
            default:
                url = "https://feeds.bbci.co.uk/news/world/rss.xml";
                break;
        }
    RssParser.fetch_rss_url(url, "BBC News", category_display_name(current_category), current_category, current_search_query, session, set_label, clear_items, add_item);
    }

    private static void fetch_guardian(
        string current_category,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        new Thread<void*>("fetch-news", () => {
            try {
                // No article cache: always fetch fresh Guardian API results
                string base_url = "https://content.guardianapis.com/search?show-fields=thumbnail&page-size=30&api-key=test";
                string url;
                switch (current_category) {
                    case "us":
                        url = base_url + "&section=us-news";
                        break;
                    case "technology":
                        url = base_url + "&section=technology";
                        break;
                    case "science":
                        url = base_url + "&section=science";
                        break;
                    case "sports":
                        url = base_url + "&section=sport";
                        break;
                    case "health":
                        url = base_url + "&tag=society/health";
                        break;
                    case "politics":
                        url = base_url + "&section=politics";
                        break;
                    case "entertainment":
                        url = base_url + "&section=culture";
                        break;
                    case "lifestyle":
                        url = base_url + "&section=lifeandstyle";
                        break;
                    case "general":
                    default:
                        url = base_url + "&section=world";
                        break;
                }
                if (current_search_query.length > 0) {
                    url = url + "&q=" + Uri.escape_string(current_search_query);
                }
                var msg = new Soup.Message("GET", url);
                msg.request_headers.append("User-Agent", "paperboy/0.1");
                session.send_message(msg);
                if (msg.status_code != 200) {
                    warning("HTTP error: %u", msg.status_code);
                    return null;
                }
                string body = (string) msg.response_body.flatten().data;
                // No article cache in this build; just proceed with parsing and UI update

                var parser = new Json.Parser();
                parser.load_from_data(body);
                var root = parser.get_root();
                var data = root.get_object();
                if (!data.has_member("response")) {
                    return null;
                }
                var response = data.get_object_member("response");
                if (!response.has_member("results")) {
                    return null;
                }
                var results = response.get_array_member("results");

                string category_name = category_display_name(current_category);
                Idle.add(() => {
                    if (current_search_query.length > 0) {
                        set_label(@"Search Results: \"$(current_search_query)\" in $(category_name) — The Guardian");
                    } else {
                        set_label(@"$(category_name) — The Guardian");
                    }
                    uint len = results.get_length();
                    for (uint i = 0; i < len; i++) {
                        var article = results.get_element(i).get_object();
                        var title = article.has_member("webTitle") ? article.get_string_member("webTitle") : "No title";
                        var article_url = article.has_member("webUrl") ? article.get_string_member("webUrl") : "";
                        string? thumbnail = null;
                        if (article.has_member("fields")) {
                            var fields = article.get_object_member("fields");
                            if (fields.has_member("thumbnail")) {
                                thumbnail = fields.get_string_member("thumbnail");
                            }
                        }
                        add_item(title, article_url, thumbnail, current_category, "The Guardian");
                    }
                    // Attempt to fetch higher-quality images (OG images) for Guardian articles
                    fetch_guardian_article_images(results, session, add_item, current_category);
                    return false;
                });
            } catch (GLib.Error e) { warning("Fetch error: %s", e.message); }
            return null;
        });
    }

    private static void fetch_reddit(
        string current_category,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        new Thread<void*>("fetch-news", () => {
            try {
                string subreddit = "";
                string category_name = "";
                switch (current_category) {
                    case "general":
                        subreddit = "worldnews";
                        category_name = "World News";
                        break;
                    case "us":
                        subreddit = "news";
                        category_name = "US News";
                        break;
                    case "technology":
                        subreddit = "technology";
                        category_name = "Technology";
                        break;
                    case "science":
                        subreddit = "science";
                        category_name = "Science";
                        break;
                    case "sports":
                        subreddit = "sports";
                        category_name = "Sports";
                        break;
                    case "health":
                        subreddit = "health";
                        category_name = "Health";
                        break;
                    case "entertainment":
                        subreddit = "entertainment";
                        category_name = "Entertainment";
                        break;
                    case "politics":
                        subreddit = "politics";
                        category_name = "Politics";
                        break;
                    case "lifestyle":
                        subreddit = "lifestyle";
                        category_name = "Lifestyle";
                        break;
                    default:
                        subreddit = "worldnews";
                        category_name = "World News";
                        break;
                }
                string url = @"https://www.reddit.com/r/$(subreddit)/hot.json?limit=30";
                if (current_search_query.length > 0) {
                    url = @"https://www.reddit.com/r/$(subreddit)/search.json?q=$(Uri.escape_string(current_search_query))&restrict_sr=1&limit=30";
                }
                var msg = new Soup.Message("GET", url);
                msg.request_headers.append("User-Agent", "paperboy/0.1");
                session.send_message(msg);
                if (msg.status_code != 200) {
                    warning("HTTP error: %u", msg.status_code);
                    return null;
                }
                string body = (string) msg.response_body.flatten().data;

                var parser = new Json.Parser();
                parser.load_from_data(body);
                var root = parser.get_root();
                var data = root.get_object();
                if (!data.has_member("data")) {
                    return null;
                }
                var data_obj = data.get_object_member("data");
                if (!data_obj.has_member("children")) {
                    return null;
                }
                var children = data_obj.get_array_member("children");

                Idle.add(() => {
                    if (current_search_query.length > 0) {
                        set_label(@"Search Results: \"$(current_search_query)\" in $(category_name)");
                    } else {
                        set_label(category_name);
                    }
                    uint len = children.get_length();
                    for (uint i = 0; i < len; i++) {
                        var post = children.get_element(i).get_object();
                        var post_data = post.get_object_member("data");
                        var title = post_data.has_member("title") ? post_data.get_string_member("title") : "No title";
                        var post_url = post_data.has_member("url") ? post_data.get_string_member("url") : "";
                        string? thumbnail = null;
                        
                        // Try to get high-quality preview image first
                        if (post_data.has_member("preview")) {
                            var preview = post_data.get_object_member("preview");
                            if (preview.has_member("images")) {
                                var images = preview.get_array_member("images");
                                if (images.get_length() > 0) {
                                    var first_image = images.get_element(0).get_object();
                                    if (first_image.has_member("source")) {
                                        var source = first_image.get_object_member("source");
                                        if (source.has_member("url")) {
                                            string preview_url = source.get_string_member("url");
                                            // Decode HTML entities in URL
                                            thumbnail = preview_url.replace("&amp;", "&");
                                        }
                                    }
                                }
                            }
                        }
                        
                        // Fallback to thumbnail if no preview available
                        if (thumbnail == null && post_data.has_member("thumbnail")) {
                            string thumb = post_data.get_string_member("thumbnail");
                            if (thumb.has_prefix("http") && thumb != "default" && thumb != "self" && thumb != "nsfw") {
                                thumbnail = thumb;
                            }
                        }
                        
                        add_item(title, post_url, thumbnail, current_category, "Reddit");
                    }
                    return false;
                });
            } catch (GLib.Error e) {
                warning("Fetch error: %s", e.message);
            }
            return null;
        });
    }

    private static void fetch_reuters(
        string current_category,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        // Reuters RSS feeds require authentication, so use Google News site search
        // Reuters also doesn't provide images for its RSS feed.
        fetch_google_domain(current_category, current_search_query, session, set_label, clear_items, add_item, "reuters.com", "Reuters");
    }

    // Bloomberg doesn't present tradional news (i.e. doesn't have regular feeds). That's ok, let's just present the categories they do have.
    private static void fetch_bloomberg(
        string current_category,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        if (current_search_query.length > 0) {
            fetch_google_domain(current_category, current_search_query, session, set_label, clear_items, add_item, "bloomberg.com", "Bloomberg");
            return;
        }
        string url = "https://feeds.bloomberg.com/markets/news.rss";
        switch (current_category) {
            case "technology":
                url = "https://feeds.bloomberg.com/technology/news.rss";
                break;
            case "industries":
                url = "https://feeds.bloomberg.com/industries/news.rss";
                break;
            case "markets":
                url = "https://feeds.bloomberg.com/markets/news.rss";
                break;
            case "economics":
                url = "https://feeds.bloomberg.com/economics/news.rss";
                break;
            case "wealth":
                url = "https://feeds.bloomberg.com/wealth/news.rss";
                break;
            case "green":
                url = "https://feeds.bloomberg.com/green/news.rss";
                break;
            case "politics":
                url = "https://feeds.bloomberg.com/politics/news.rss";
                break;
            default:
                url = "https://feeds.bloomberg.com/markets/news.rss";
                break;
        }
        RssParser.fetch_rss_url(url, "Bloomberg", category_display_name(current_category), current_category, current_search_query, session, set_label, clear_items, add_item);
    }

    private static void fetch_npr(
        string current_category,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        if (current_search_query.length > 0) {
            fetch_google_domain(current_category, current_search_query, session, set_label, clear_items, add_item, "npr.org", "NPR");
            return;
        }
        string url = "https://feeds.npr.org/1001/rss.xml";
        switch (current_category) {
            case "technology":
                url = "https://feeds.npr.org/1019/rss.xml";
                break;
            case "science":
                url = "https://feeds.npr.org/1007/rss.xml";
                break;
            case "sports":
                url = "https://feeds.npr.org/1055/rss.xml";
                break;
            case "health":
                url = "https://feeds.npr.org/1128/rss.xml";
                break;
            case "us":
                url = "https://feeds.npr.org/1003/rss.xml";
                break;
            case "politics":
                url = "https://feeds.npr.org/1014/rss.xml";
                break;
            case "entertainment":
                url = "https://feeds.npr.org/1008/rss.xml";
                break;
            case "lifestyle":
                url = "https://feeds.npr.org/1053/rss.xml";
                break;
            default:
                url = "https://feeds.npr.org/1001/rss.xml";
                break;
        }
        RssParser.fetch_rss_url(url, "NPR", category_display_name(current_category), current_category, current_search_query, session, set_label, clear_items, add_item);
    }

    private static void fetch_fox(
        string current_category,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        // Use web scraping for Fox News to get better control over content and images
        // Keep the optimized version with reduced delays and limited concurrent requests
        fetch_fox_scrape(current_category, current_search_query, session, set_label, clear_items, add_item);
    }

    private static void fetch_fox_scrape(
        string current_category,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        new Thread<void*>("fetch-fox-scrape", () => {
            try {
                Gee.ArrayList<string> section_urls = new Gee.ArrayList<string>();
                switch (current_category) {
                    case "politics": section_urls.add("https://www.foxnews.com/politics"); break;
                    case "us": section_urls.add("https://www.foxnews.com/us"); break;
                    case "technology":
                        section_urls.add("https://www.foxnews.com/tech");
                        section_urls.add("https://www.foxnews.com/technology");
                        break;
                    case "science": section_urls.add("https://www.foxnews.com/science"); break;
                    case "sports": section_urls.add("https://www.foxnews.com/sports"); break;
                    case "health": section_urls.add("https://www.foxnews.com/health"); break;
                    case "entertainment": section_urls.add("https://www.foxnews.com/entertainment"); break;
                    case "lifestyle": section_urls.add("https://www.foxnews.com/lifestyle"); break;
                    case "general":
                        section_urls.add("https://www.foxnews.com/world");
                        section_urls.add("https://www.foxnews.com");
                        break;
                    default: section_urls.add("https://www.foxnews.com"); break;
                }

                if (current_search_query.length > 0) {
                    Idle.add(() => {
                        set_label(@"No Fox News results for search: \"$(current_search_query)\"");
                        return false;
                    });
                    return null;
                }

                Gee.ArrayList<Paperboy.NewsArticle> articles = ArticleScraper.scrape_section_urls(section_urls, "https://www.foxnews.com", current_search_query, session);
                // UI batching: add articles in small batches with short delays
                Idle.add(() => {
                    string category_name = category_display_name(current_category) + " — Fox News";
                    if (current_search_query.length > 0) {
                        set_label(@"Search Results: \"$(current_search_query)\" in $(category_name)");
                    } else {
                        set_label(category_name);
                    }
                    int ui_limit = 16;
                    int ui_count = 0;
                    int total = articles.size;
                    int count = 0;
                    foreach (var article in articles) {
                        if (count >= ui_limit) break;
                        Idle.add(() => {
                            add_item(article.title, article.url, article.image_url, current_category, "Fox News");
                            return false;
                        });
                        count++;
                    }
                    fetch_fox_article_images(articles, session, add_item, current_category);
                    return false;
                });
            } catch (GLib.Error e) {
                warning("Error parsing Fox News HTML: %s", e.message);
                    Idle.add(() => {
                        set_label("Fox News: Error loading articles");
                        return false;
                    });
            }
            return null;
        });
    }
    private static bool is_duplicate_url(Gee.ArrayList<Paperboy.NewsArticle> articles, string url) {
        foreach (var article in articles) {
            if (article.url == url) {
                return true;
            }
        }
        return false;
    }

    private static void fetch_fox_article_images(
    Gee.ArrayList<Paperboy.NewsArticle> articles,
        Soup.Session session,
        AddItemFunc add_item,
        string current_category
    ) {
        // Fetch OG images for articles that don't have them yet, limited to a few
        // to avoid long-running work. Delegate to Tools.ImageParser.fetch_open_graph_image
        // which spawns its own background thread and updates the UI via add_item.
        int count = 0;
        foreach (var article in articles) {
            if (article.image_url == null && count < 6 && article.url != null) {
                Tools.ImageParser.fetch_open_graph_image(article.url, session, add_item, current_category, "Fox News");
                count++;
            }
            if (count >= 6) break;
        }
    }

    private static void fetch_guardian_article_images(
        Json.Array results,
        Soup.Session session,
        AddItemFunc add_item,
        string current_category
    ) {
        // results is the Guardian API 'results' array; fetch OG images for first few
        // articles (lower concurrency to speed up perceived load). We spawn
        // fetch threads immediately; the fetch function itself runs in a
        // background thread so no additional scheduling is necessary.
        int count = 0;
        uint len = results.get_length();
        for (uint i = 0; i < len && count < 6; i++) {
            var article = results.get_element(i).get_object();
            if (article.has_member("webUrl")) {
                string url = article.get_string_member("webUrl");
                // Delegate OG image fetching to Tools.ImageParser
                Tools.ImageParser.fetch_open_graph_image(url, session, add_item, current_category, "The Guardian");
                count++;
            }
        }
    }


    private static void fetch_wsj(
        string current_category,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        if (current_search_query.length > 0) {
            fetch_google_domain(current_category, current_search_query, session, set_label, clear_items, add_item, "wsj.com", "WSJ");
            return;
        }
        string url = "https://feeds.content.dowjones.io/public/rss/RSSWorldNews.xml";
        switch (current_category) {
            case "technology":
                url = "https://feeds.content.dowjones.io/public/rss/RSSWSJD";
                break;
            case "sports":
                url = "https://feeds.content.dowjones.io/public/rss/rsssportsfeed";
                break;
            case "health":
                url = "https://feeds.content.dowjones.io/public/rss/socialhealth";
                break;
            case "us":
                url = "https://feeds.content.dowjones.io/public/rss/RSSUSnews";
                break;
            case "politics":
                url = "https://feeds.content.dowjones.io/public/rss/socialpoliticsfeed";
                break;
            case "entertainment":
                url = "https://feeds.content.dowjones.io/public/rss/RSSArtsCulture";
                break;
            case "lifestyle":
                url = "https://feeds.content.dowjones.io/public/rss/RSSLifestyle";
                break;
            default:
                url = "https://feeds.content.dowjones.io/public/rss/RSSWorldNews";
                break;
        }
        RssParser.fetch_rss_url(url, "WSJ", category_display_name(current_category), current_category, current_search_query, session, set_label, clear_items, add_item);
    }


}
