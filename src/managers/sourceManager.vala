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
using Xml;

/*
 *SourceManager - Centralized source management
 *
 * This class provides a single source of truth for:
 * - Which sources are enabled
 * - Source capabilities (categories, special behavior)
 * - Source inference from URLs
 * - Source validation and filtering
 */

// Callback for RSS feed addition
public delegate void RssFeedAddCallback(bool success, string feed_name);

 public class SourceManager : GLib.Object {

    // All available built-in sources
    private const string[] ALL_BUILTIN_SOURCES = {
        "guardian", "reddit", "bbc", "nytimes", "wsj",
        "bloomberg", "reuters", "npr", "fox"
    };

    // Currently enabled sources (references prefs)
    private weak NewsPreferences prefs;
    private weak NewsWindow window;

    public SourceManager(NewsPreferences prefs) {
        this.prefs = prefs;
    }

    public void set_window(NewsWindow window) {
        this.window = window;
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

    // Determine whether the given article URL belongs to a built-in source
    // This performs the same domain-based checks used elsewhere to avoid
    // treating the fallback "guardian" enum as a custom source.
    public static bool is_article_from_builtin(string? article_url) {
        if (article_url == null || article_url.length == 0) return false;

        NewsSource inferred = infer_source_from_url(article_url);
        string url_lower = article_url.down();

        if (inferred == NewsSource.GUARDIAN && (url_lower.contains("guardian") || url_lower.contains("theguardian"))) return true;
        if (inferred == NewsSource.BBC && (url_lower.contains("bbc.") || url_lower.contains("bbc.co"))) return true;
        if (inferred == NewsSource.REDDIT && (url_lower.contains("reddit") || url_lower.contains("redd.it"))) return true;
        if (inferred == NewsSource.NEW_YORK_TIMES && (url_lower.contains("nytimes") || url_lower.contains("nyti.ms"))) return true;
        if (inferred == NewsSource.WALL_STREET_JOURNAL && (url_lower.contains("wsj.com") || url_lower.contains("on.wsj.com"))) return true;
        if (inferred == NewsSource.BLOOMBERG && url_lower.contains("bloomberg")) return true;
        if (inferred == NewsSource.REUTERS && url_lower.contains("reuters")) return true;
        if (inferred == NewsSource.NPR && url_lower.contains("npr.org")) return true;
        if (inferred == NewsSource.FOX && (url_lower.contains("foxnews") || url_lower.contains("fox.com"))) return true;

        return false;
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

        // My Feed with custom RSS sources - allow articles from custom sources
        // Custom RSS articles will have category "myfeed" but URLs that don't match built-in sources
        if (category == "myfeed") {
            // Check if this URL belongs to a built-in source
            string article_source_id = infer_source_id_from_url(article_url);

            // If it's not a recognized built-in source (fallback to guardian), it's likely a custom RSS source
            // We need to check if the inferred source is actually a match or just the fallback
            NewsSource inferred = infer_source_from_url(article_url);
            bool is_builtin_match = false;

            // Check if URL actually contains source domain
            string url_lower = article_url.down();
            if (inferred == NewsSource.GUARDIAN && (url_lower.contains("guardian") || url_lower.contains("theguardian"))) is_builtin_match = true;
            else if (inferred == NewsSource.BBC && (url_lower.contains("bbc."))) is_builtin_match = true;
            else if (inferred == NewsSource.REDDIT && (url_lower.contains("reddit") || url_lower.contains("redd.it"))) is_builtin_match = true;
            else if (inferred == NewsSource.NEW_YORK_TIMES && (url_lower.contains("nytimes") || url_lower.contains("nyti.ms"))) is_builtin_match = true;
            else if (inferred == NewsSource.WALL_STREET_JOURNAL && (url_lower.contains("wsj.com") || url_lower.contains("on.wsj.com"))) is_builtin_match = true;
            else if (inferred == NewsSource.BLOOMBERG && url_lower.contains("bloomberg")) is_builtin_match = true;
            else if (inferred == NewsSource.REUTERS && url_lower.contains("reuters")) is_builtin_match = true;
            else if (inferred == NewsSource.NPR && url_lower.contains("npr.org")) is_builtin_match = true;
            else if (inferred == NewsSource.FOX && (url_lower.contains("foxnews") || url_lower.contains("fox.com"))) is_builtin_match = true;

            if (!is_builtin_match) {
                // This is likely a custom RSS source - allow it in My Feed
                return true;
            }

            // For built-in sources in My Feed, check if they're enabled
            if (!is_source_enabled(article_source_id)) {
                return false;
            }

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

    // Add an RSS feed with robust metadata discovery
    // This method fetches the feed, parses it to get the real title, and attempts to fetch a favicon
    public void add_rss_feed_with_discovery(string feed_url, string? user_provided_name, owned RssFeedAddCallback callback) {
        new Thread<void*>("rss-add-with-discovery", () => {
            string final_name = user_provided_name != null && user_provided_name.length > 0 ? user_provided_name : "";
            string? logo_url = null;
            string? host = null;

            try {
                host = UrlUtils.extract_host_from_url(feed_url);

                // Step 1: Try to fetch the RSS feed and extract the title
                if (final_name.length == 0) {
                    try {
                        var msg = new Soup.Message("GET", feed_url);
                        msg.get_request_headers().append("User-Agent", "paperboy/0.5.1a");

                        GLib.Bytes? response = window.session.send_and_read(msg, null);
                        var status = msg.get_status();

                        if (status == Soup.Status.OK && response != null) {
                            string body = (string) response.get_data();

                            // Try to extract feed title from RSS/Atom XML
                            final_name = extract_feed_title_from_xml(body);

                            if (final_name.length == 0 && host != null) {
                                final_name = host.replace("www.", "");
                            }
                        }
                    } catch (GLib.Error e) {
                        GLib.warning("Failed to fetch RSS feed for title extraction: %s", e.message);
                    }
                }

                // Fallback to hostname if still no name
                if (final_name.length == 0 && host != null) {
                    final_name = host.replace("www.", "");
                } else if (final_name.length == 0) {
                    final_name = feed_url;
                }

                // Step 2: Try to get a logo/favicon
                // Priority 1: Check if we already have metadata for this source
                string? existing_display_name = null;
                bool force_update_meta = false;
                if (host != null) {
                    string? existing_logo_url = null;
                    string? existing_filename = null;
                    SourceMetadata.get_source_info_by_url(feed_url, out existing_display_name, out existing_logo_url, out existing_filename);

                    // If we have existing display name from source_info, decide whether
                    // to keep it or prefer the newly-discovered feed title. We prefer
                    // the discovered title when the existing name looks like a domain
                    // (contains a dot and no spaces) and the discovered title appears
                    // more human (contains a space or has uppercase letters).
                    if (existing_display_name != null && existing_display_name.length > 0) {
                        bool existing_is_domain = existing_display_name.index_of(".") >= 0 && existing_display_name.index_of(" ") < 0;
                        bool new_is_more_human = (final_name.index_of(" ") >= 0) || (final_name != final_name.down());
                        if (existing_is_domain && new_is_more_human) {
                            // Keep our discovered final_name and request metadata overwrite
                            force_update_meta = true;
                        } else {
                            // Keep the existing curated display name
                            final_name = existing_display_name;
                        }
                    }

                    if (existing_logo_url != null && existing_logo_url.length > 0) {
                        logo_url = existing_logo_url;
                    }
                }

                // Priority 2: Try Google Favicon Service (robust fallback)
                if (logo_url == null && host != null) {
                    logo_url = "https://www.google.com/s2/favicons?domain=" + host + "&sz=128";
                }

                // Step 3: Add to database
                var store = Paperboy.RssSourceStore.get_instance();
                bool success = store.add_source(final_name, feed_url, null);

                // Step 4: Save metadata and fetch logo. If we discovered a more
                // human title than an existing domain-like metadata entry, force
                // an update of the metadata file (overwrite the domain fallback).
                if (success && logo_url != null && host != null && (existing_display_name == null || force_update_meta)) {
                    try {
                        SourceMetadata.update_index_and_fetch(host, final_name, logo_url, "https://" + host, window.session, feed_url);
                    } catch (GLib.Error e) {
                        GLib.warning("Failed to save source metadata: %s", e.message);
                    }
                }

                // Step 5: Callback with result
                GLib.Idle.add(() => {
                    callback(success, final_name);
                    return false;
                });

            } catch (GLib.Error e) {
                GLib.warning("Error adding RSS feed: %s", e.message);
                GLib.Idle.add(() => {
                    callback(false, final_name.length > 0 ? final_name : feed_url);
                    return false;
                });
            }

            return null;
        });
    }

    // Extract feed title from RSS/Atom XML
    // Helper: recursively search an Xml.Node subtree for the first <title> element
    private string? find_first_title_in_xml(Xml.Node* node) {
        if (node == null) return null;
        for (Xml.Node* ch = node->children; ch != null; ch = ch->next) {
            if (ch->type == Xml.ElementType.ELEMENT_NODE) {
                string local = ch->name != null ? (string) ch->name : "";
                if (local == "title") {
                    string val = ch->get_content();
                    if (val != null) return val.strip();
                }
                string? sub = find_first_title_in_xml(ch);
                if (sub != null && sub.length > 0) return sub;
            }
        }
        return null;
    }

    private string extract_feed_title_from_xml(string xml_content) {
        try {
            // Prefer proper XML parsing rather than regex so we handle
            // Atom titles with attributes (e.g. <title type="html">) and CDATA.
            Xml.Doc* doc = null;
            try {
                // Use same safe parser options as rssParser
                int parser_options = (int) (Xml.ParserOption.NONET | Xml.ParserOption.NOCDATA | Xml.ParserOption.NOBLANKS);
                doc = Xml.Parser.read_memory(xml_content, (int) xml_content.length, null, null, parser_options);
            } catch (GLib.Error e) {
                // Fallback: try to repair common issues by removing NULs
                string cleaned = xml_content.replace("\0", "");
                try { doc = Xml.Parser.read_memory(cleaned, (int) cleaned.length, null, null, (int)(Xml.ParserOption.NONET | Xml.ParserOption.NOCDATA | Xml.ParserOption.NOBLANKS)); } catch (GLib.Error ee) { doc = null; }
            }

            if (doc != null) {
                Xml.Node* root = doc->get_root_element();
                if (root != null) {
                    string? found = find_first_title_in_xml(root);
                    if (found != null) {
                        // Decode common HTML entities
                        found = found.replace("&amp;", "&");
                        found = found.replace("&lt;", "<");
                        found = found.replace("&gt;", ">");
                        found = found.replace("&quot;", "\"");
                        found = found.replace("&#39;", "'");
                        found = found.replace("&apos;", "'");
                        found = found.strip();
                        if (found.length > 0 && found.length <= 200) return found;
                    }
                }
            }
        } catch (GLib.Error e) {
            GLib.warning("Failed to extract title from RSS XML: %s", e.message);
        }

        return "";
    }

    // Discover and follow an RSS source from an article URL
    public void follow_rss_source(string article_url, string? source_metadata = null) {
        // If the article appears to be from a built-in source, ignore follow
        // requests and notify the user. This prevents adding built-in sources
        // as custom RSS entries.
        if (is_article_from_builtin(article_url)) {
            GLib.Idle.add(() => {
                try { if (window != null) window.clear_persistent_toast(); } catch (GLib.Error e) { }
                try { if (window != null) window.show_toast("Source is built-in"); } catch (GLib.Error e) { }
                return false;
            });
            return;
        }

        // Call backend /rss/discover endpoint to discover RSS feed from article URL
        new Thread<void*>("rss-discover", () => {
            try {
                // Extract the domain from the article URL to use as RSS discovery URL
                string host = UrlUtils.extract_host_from_url(article_url);
                if (host == null || host.length == 0) {
                    GLib.warning("Cannot follow source: invalid article URL");
                    return null;
                }

                // Parse source metadata from article if provided (format: "Display Name||logo_url##category::cat")
                // We do this early so it's available for both API results and local fallback
                string? article_display_name = null;
                string? article_logo_url = null;
                if (source_metadata != null && source_metadata.length > 0) {
                    article_display_name = source_metadata;
                    int pipe_idx = source_metadata.index_of("||");
                    if (pipe_idx >= 0) {
                        article_display_name = source_metadata.substring(0, pipe_idx).strip();
                        article_logo_url = source_metadata.substring(pipe_idx + 2).strip();
                        // Remove category suffix if present
                        int cat_idx = article_logo_url.index_of("##category::");
                        if (cat_idx >= 0) {
                            article_logo_url = article_logo_url.substring(0, cat_idx).strip();
                        }
                    }
                    // Remove category suffix from display name if present
                    int cat_idx = article_display_name.index_of("##category::");
                    if (cat_idx >= 0) {
                        article_display_name = article_display_name.substring(0, cat_idx).strip();
                    }
                }

                // Call the backend /rss/discover endpoint
                bool rss_discovery_succeeded = false;
                try {
                    string backend_url = "https://paperboybackend.onrender.com/rss/discover";
                    var msg = new Soup.Message("POST", backend_url);
                    var headers = msg.get_request_headers();
                    headers.append("accept", "application/json");
                    headers.append("Content-Type", "application/json");
                    headers.append("User-Agent", "paperboy/0.5.1a");

                    // Create JSON body with the article URL and max_pages parameter
                    string escaped_url = article_url.replace("\\", "\\\\").replace("\"", "\\\"");
                    string json_body = "{\"url\":\"" + escaped_url + "\",\"max_pages\":1}";
                    msg.set_request_body_from_bytes("application/json", new GLib.Bytes(json_body.data));

                    GLib.Bytes? response = window.session.send_and_read(msg, null);
                    var status = msg.get_status();
                    
                    // rss_discovery_succeeded is now defined outside this block

                    if (status == Soup.Status.OK && response != null) {
                        unowned uint8[] data = response.get_data();
                        if (data == null || data.length == 0) {
                            GLib.warning("RSS discovery returned empty response");
                        } else {
                            string body = (string) data;

                            // Parse the JSON response
                            try {
                                var parser = new Json.Parser();
                                parser.load_from_data(body, -1);
                                var root = parser.get_root();
                                
                                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) {
                                    GLib.warning("RSS discovery returned invalid JSON structure");
                                } else {
                                    var root_obj = root.get_object();

                                    // The response has a "feeds" array with discovered RSS feeds
                                    if (root_obj.has_member("feeds")) {
                                        var feeds_array = root_obj.get_array_member("feeds");
                                        if (feeds_array.get_length() > 0) {
                                            // Take the first feed from the discovered feeds
                                            var first_feed = feeds_array.get_object_element(0);
                                            string feed_url = first_feed.get_string_member("url");
                                            string feed_title = first_feed.has_member("title") ? first_feed.get_string_member("title") : host;
                                            string? feed_description = first_feed.has_member("description") ? first_feed.get_string_member("description") : null;

                                            // Extract metadata from API response (highest priority)
                                            string? api_source_name = null;
                                            string? api_logo_url = null;
                                            if (first_feed.has_member("source_name")) {
                                                api_source_name = first_feed.get_string_member("source_name");
                                            }
                                            if (first_feed.has_member("logo_url")) {
                                                api_logo_url = first_feed.get_string_member("logo_url");
                                            }

                                            if (first_feed.has_member("logo_url")) {
                                                api_logo_url = first_feed.get_string_member("logo_url");
                                            }

                                            // (Metadata parsing moved to top of function)

                                            // Priority: API metadata (most reliable) > article metadata (what user saw) > feed title (cleaned)
                                            // We prefer API metadata because it comes from the discovery service which has canonical info
                                            string? metadata_display_name = api_source_name;
                                            string? metadata_logo_url = api_logo_url;

                                            if (metadata_display_name == null || metadata_display_name.length == 0) {
                                                metadata_display_name = article_display_name;
                                            }
                                            if (metadata_logo_url == null || metadata_logo_url.length == 0) {
                                                metadata_logo_url = article_logo_url;
                                            }

                                            // Clean up feed_title if it's too long (likely a description, not a name)
                                            string cleaned_feed_title = feed_title;
                                            if (feed_title.length > 50) {
                                                // Use host as fallback for overly long titles
                                                cleaned_feed_title = host;
                                            }

                                            // Use metadata if available, otherwise use cleaned feed info
                                            string final_title = (metadata_display_name != null && metadata_display_name.length > 0) ? metadata_display_name : cleaned_feed_title;

                                            // Save to SQLite database with the proper display name
                                            var store = Paperboy.RssSourceStore.get_instance();
                                            bool success = store.add_source(final_title, feed_url, null);

                                            // Save source metadata if this is a new source and we have logo information
                                            // Priority: article metadata > API metadata
                                            // This ensures logos are saved even for manually-added sources (not just from articles)
                                            if (success) {
                                                string? save_display_name = metadata_display_name;
                                                string? save_logo_url = metadata_logo_url;


                                                // Priority 2: Check if we already have SourceMetadata for this source
                                                // (from previous Front Page/Top Ten views - this is the key!)
                                                // Use URL-based lookup since we have the article URL, not the exact display name
                                                if (save_display_name == null || save_display_name.length == 0 || save_logo_url == null || save_logo_url.length == 0) {
                                                    string? existing_display_name = null;
                                                    string? existing_logo_url = null;
                                                    string? existing_filename = null;
                                                    SourceMetadata.get_source_info_by_url(article_url, out existing_display_name, out existing_logo_url, out existing_filename);

                                                    if (existing_display_name != null && existing_display_name.length > 0) {
                                                        if (save_display_name == null || save_display_name.length == 0) {
                                                            save_display_name = existing_display_name;
                                                        }
                                                    }
                                                    if (existing_logo_url != null && existing_logo_url.length > 0) {
                                                        if (save_logo_url == null || save_logo_url.length == 0) {
                                                            save_logo_url = existing_logo_url;
                                                        }
                                                    }
                                                }

                                                // Priority 3: Fall back to API-provided metadata
                                                if (save_display_name == null || save_display_name.length == 0) {
                                                    save_display_name = api_source_name;
                                                }
                                                if (save_logo_url == null || save_logo_url.length == 0) {
                                                    save_logo_url = api_logo_url;
                                                }

                                                // Priority 4: Final fallback - use Google favicon service (better quality)
                                                // This ensures we ALWAYS create metadata, even for brand new sources
                                                if (save_logo_url == null || save_logo_url.length == 0) {
                                                    save_logo_url = "https://www.google.com/s2/favicons?domain=" + host + "&sz=128";
                                                    GLib.warning("RSS Discovery: Using Google favicon service for %s", host);
                                                }

                                                // Create metadata - we always have a logo URL now (at minimum, favicon)
                                                try {
                                                    // Use final_title as fallback if we still don't have a display name
                                                    string metadata_name = (save_display_name != null && save_display_name.length > 0) ? save_display_name : final_title;
                                                    SourceMetadata.update_index_and_fetch(host, metadata_name, save_logo_url, "https://" + host, window.session, feed_url);
                                                } catch (GLib.Error e) {
                                                    GLib.warning("Failed to save source metadata: %s", e.message);
                                                }
                                            }

                                            if (success) {
                                                GLib.Idle.add(() => {
                                                    window.show_toast("Following " + final_title);
                                                    return false;
                                                });
                                            } else {
                                                GLib.Idle.add(() => {
                                                    window.show_toast("Source already followed");
                                                    return false;
                                                });
                                            }
                                            
                                            // Mark as successful so we don't fall through to html2rss
                                            rss_discovery_succeeded = true;
                                        } else {
                                            // No feeds returned by the discovery API — will try html2rss fallback below
                                            GLib.warning("RSS discovery returned no feeds; will attempt local html2rss fallback");
                                        }
                                    }
                                }
                            } catch (GLib.Error e) {
                                GLib.warning("Failed to parse RSS discovery JSON response: %s", e.message);
                            }
                        }
                    } else {
                        GLib.warning("RSS discovery request failed with status: %u", status);
                    }
                } catch (GLib.Error e) {
                    GLib.warning("RSS discovery API failed (exception): %s", e.message);
                }
                
                // If RSS discovery didn't succeed, try local html2rss fallback
                GLib.message("RSS Discovery status: succeeded=%s", rss_discovery_succeeded.to_string());
                
                if (!rss_discovery_succeeded) {
                    // Safety check: ensure host is still valid before proceeding with fallback
                    if (host == null || host.length == 0) {
                        GLib.warning("Cannot attempt html2rss fallback: host is null or empty");
                        GLib.Idle.add(() => {
                            window.show_toast("Failed to discover RSS feed");
                            return false;
                        });
                    } else {
                        GLib.message("Attempting local html2rss fallback for host: %s", host);
                        
                        string? script_path = null;
                        var binary_candidates = new ArrayList<string>();

                        // Preferred: meson-generated bindir (configured at build time)
                        binary_candidates.add(BuildConstants.RSSFINDER_BINDIR + "/html2rss");

                        // Common system locations where packagers or users may put helper binaries
                        binary_candidates.add("/usr/bin/html2rss");
                        binary_candidates.add("/usr/local/bin/html2rss");
                        binary_candidates.add("/usr/share/org.gnome.Paperboy/tools/html2rss");

                        // System data dirs (check all entries, not just the first)
                        try {
                            var sys_dirs = GLib.Environment.get_system_data_dirs();
                            if (sys_dirs != null) {
                                for (int i = 0; i < sys_dirs.length; i++) {
                                    var dir = sys_dirs[i];
                                    if (dir != null && dir.length > 0) {
                                        binary_candidates.add(GLib.Path.build_filename(dir, "org.gnome.Paperboy", "tools", "html2rss"));
                                    }
                                }
                            }
                        } catch (GLib.Error e) { }

                        // Flatpak/AppImage-style path
                        binary_candidates.add("/app/share/org.gnome.Paperboy/tools/html2rss");

                        // Development build locations
                        binary_candidates.add("tools/html2rss/target/release/html2rss");
                        binary_candidates.add("./tools/html2rss/target/release/html2rss");
                        binary_candidates.add("../tools/html2rss/target/release/html2rss");
                        string? cwd = GLib.Environment.get_variable("PWD");
                        if (cwd != null && cwd.length > 0) {
                            binary_candidates.add(GLib.Path.build_filename(cwd, "tools", "html2rss", "target", "release", "html2rss"));
                        }

                        // Common user workspace fallback
                        string? home_env = GLib.Environment.get_variable("HOME");
                        if (home_env != null && home_env.length > 0) {
                            string home_candidate = GLib.Path.build_filename(home_env, "paperboy", "tools", "html2rss", "target", "release", "html2rss");
                            binary_candidates.add(home_candidate);
                        }

                        foreach (var c in binary_candidates) {
                            try {
                                var f = GLib.File.new_for_path(c);
                                if (f.query_exists(null)) {
                                    // Ensure it's executable where possible
                                    try {
                                        var info = f.query_info("standard::access", 0, null);
                                        bool can_exec = false;
                                        if (info != null) {
                                            var perms = info.get_attribute_boolean("standard::access");
                                            // fall back to assuming existence means executable on platforms where access attr may not be present
                                            can_exec = true;
                                        }
                                    } catch (GLib.Error ee) {
                                        // ignore permission check, treat existence as sufficient
                                    }
                                    script_path = c;
                                    GLib.message("Found html2rss binary at: %s", c);
                                    break;
                                }
                            } catch (GLib.Error e) {
                                // ignore and continue
                            }
                        }

                        if (script_path != null) {
                            try {
                                // Run the local html2rss binary using Gio/GLib Subprocess
                                // Pass the URL as an argv element (avoids shell quoting issues)
                                string[] argv = { script_path, "--max-pages", "20", article_url };
                                GLib.message("Running html2rss: %s %s %s %s", argv[0], argv[1], argv[2], argv[3]);
                                
                                string? out_stdout = null;
                                string? out_stderr = null;
                                int exit_status = 0;

                                var proc = new GLib.Subprocess.newv(argv, GLib.SubprocessFlags.STDOUT_PIPE | GLib.SubprocessFlags.STDERR_PIPE);
                                // Wait for process to finish and read pipes manually
                                try {
                                    proc.wait_check(null);
                                } catch (GLib.Error e) {
                                    // wait_check failed; we'll still try to read any output
                                }

                                // Read stdout using a safe chunked loop (avoid read_bytes(-1))
                                try {
                                    var stdout_stream = proc.get_stdout_pipe();
                                    string _out_acc = "";
                                    while (true) {
                                        var stdout_bytes = stdout_stream.read_bytes(8192, null);
                                        if (stdout_bytes == null) break;
                                        size_t sz = stdout_bytes.get_size();
                                        if (sz == 0) break;
                                        _out_acc += (string) stdout_bytes.get_data();
                                        if (sz < 8192) break;
                                    }
                                    out_stdout = _out_acc;
                                } catch (GLib.Error e) {
                                    out_stdout = null;
                                }

                                // Read stderr using a safe chunked loop
                                try {
                                    var stderr_stream = proc.get_stderr_pipe();
                                    string _err_acc = "";
                                    while (true) {
                                        var stderr_bytes = stderr_stream.read_bytes(8192, null);
                                        if (stderr_bytes == null) break;
                                        size_t sz2 = stderr_bytes.get_size();
                                        if (sz2 == 0) break;
                                        _err_acc += (string) stderr_bytes.get_data();
                                        if (sz2 < 8192) break;
                                    }
                                    out_stderr = _err_acc;
                                } catch (GLib.Error e) {
                                    out_stderr = null;
                                }

                                exit_status = proc.get_exit_status();
                                GLib.message("html2rss finished with exit code %d", exit_status);
                                if (out_stderr != null && out_stderr.length > 0) GLib.message("html2rss stderr: %s", out_stderr);

                                if (out_stdout != null && out_stdout.strip().length > 0 && exit_status == 0) {
                                    string gen_feed = out_stdout.strip();
                                    
                                    // Clean up any trailing garbage (e.g. HTML links appended by html2rss)
                                    gen_feed = RssValidator.clean_rss_content(gen_feed);

                                    // VALIDATE RSS before saving
                                    string? validation_error = null;
                                    bool is_valid = RssValidator.is_valid_rss(gen_feed, out validation_error);
                                    
                                    if (!is_valid) {
                                        GLib.warning("Generated RSS is invalid: %s", validation_error);
                                        
                                        GLib.Idle.add(() => {
                                            window.show_toast("Failed to generate valid RSS feed");
                                            return false;
                                        });
                                        return null;
                                    }
                                    
                                    int item_count = RssValidator.get_item_count(gen_feed);
                                    if (item_count == 0) {
                                        GLib.warning("Generated RSS has no items");
                                        GLib.Idle.add(() => {
                                            window.show_toast("Generated feed has no articles");
                                            return false;
                                        });
                                        return null;
                                    }
                                    
                                    GLib.print("✓ Generated valid RSS feed with %d items\n", item_count);

                                    // If the script printed raw RSS XML, save it to a local file
                                    if (gen_feed.has_prefix("<?xml") || gen_feed.has_prefix("<rss") || gen_feed.has_prefix("<feed") || gen_feed.has_prefix("<\n<?xml")) {
                                        try {
                                            string data_dir = GLib.Environment.get_user_data_dir();
                                            string paperboy_dir = GLib.Path.build_filename(data_dir, "paperboy");
                                            string gen_dir = GLib.Path.build_filename(paperboy_dir, "generated_feeds");
                                            try { GLib.DirUtils.create_with_parents(gen_dir, 0755); } catch (GLib.Error e) { }

                                            string safe_host = host.replace("/", "_").replace(":", "_");
                                            long ts_val = (long) (GLib.get_real_time() / 1000000);
                                            string ts = ts_val.to_string();
                                            string filename = safe_host + "-" + ts + ".xml";
                                            string file_path = GLib.Path.build_filename(gen_dir, filename);

                                            var f = GLib.File.new_for_path(file_path);
                                            // Write the generated feed string directly to the file
                                            // Write the generated feed via a replacement stream
                                            var out_stream = f.replace(null, false, GLib.FileCreateFlags.NONE, null);
                                            var writer = new DataOutputStream(out_stream);
                                            // Ensure generated feed is safe for XML storage (strip illegal control chars)
                                            string safe_feed = RssValidator.sanitize_for_xml(gen_feed);
                                            writer.put_string(safe_feed);
                                            writer.close(null);

                                            gen_feed = "file://" + file_path;
                                        } catch (GLib.Error e) {
                                            GLib.warning("Failed to save generated RSS feed: %s", e.message);
                                        }
                                    }

                                    var store = Paperboy.RssSourceStore.get_instance();
                                    
                                    // Check if we already have source_info for this host (from Front Page/Top Ten or RSS discovery)
                                    // IMPORTANT: Use host as the key, not article_url, because that's how metadata is saved
                                    string feed_name = host;
                                    string? existing_display_name = null;
                                    string? existing_logo_url = null;
                                    string? existing_filename = null;
                                    
                                    // Try to get metadata by host first (this is where API metadata is stored)
                                    SourceMetadata.get_source_info_by_url(host, out existing_display_name, out existing_logo_url, out existing_filename);
                                    
                                    // Use the existing display name if available (from API/JSON-LD)
                                    if (existing_display_name != null && existing_display_name.length > 0) {
                                        feed_name = existing_display_name;
                                        GLib.print("✓ Using existing metadata: %s\n", feed_name);
                                    } else if (article_display_name != null && article_display_name.length > 0) {
                                        // Use the passed article metadata (e.g. "AP News")
                                        feed_name = article_display_name;
                                        GLib.print("✓ Using article metadata: %s\n", feed_name);
                                    } else {
                                        GLib.print("⚠ No existing metadata found for %s, using host as name\n", host);
                                    }
                                    
                                    // Use add_source_with_original_url to store the original website URL
                                    // This allows us to regenerate the feed later
                                    string original_website_url = "https://" + host;
                                    bool success = store.add_source_with_original_url(feed_name, gen_feed, original_website_url, null);
                                    
                                    // Save or update metadata for this source
                                    // This ensures logos and proper names are set even for newly generated feeds
                                    if (success) {
                                        string? logo_url_to_save = existing_logo_url;
                                        
                                        // If we don't have a logo URL yet, try to construct one from the host
                                        if (logo_url_to_save == null || logo_url_to_save.length == 0) {
                                            if (article_logo_url != null && article_logo_url.length > 0) {
                                                logo_url_to_save = article_logo_url;
                                            } else {
                                                // Use Google favicon service (better quality than direct favicon.ico)
                                                logo_url_to_save = "https://www.google.com/s2/favicons?domain=" + host + "&sz=128";
                                            }
                                        }
                                        
                                        try {
                                            SourceMetadata.update_index_and_fetch(host, feed_name, logo_url_to_save, "https://" + host, window.session, gen_feed);
                                            GLib.print("✓ Saved metadata for %s\n", feed_name);
                                        } catch (GLib.Error e) {
                                            GLib.warning("Failed to save source metadata: %s", e.message);
                                        }
                                    }
                                    
                                    if (success) {
                                        GLib.Idle.add(() => {
                                            // Show followed message with article count
                                            window.show_toast("Following %s (%d articles)".printf(feed_name, item_count));
                                            return false;
                                        });
                                    } else {
                                        GLib.Idle.add(() => {
                                            window.show_toast("Source already followed");
                                            return false;
                                        });
                                    }
                                } else {
                                    GLib.warning("html2rss fallback did not produce a feed (exit=%d); stderr=%s", exit_status, out_stderr != null ? out_stderr : "");
                                    GLib.Idle.add(() => {
                                        window.show_toast("No RSS feeds found");
                                        return false;
                                    });
                                }
                            } catch (GLib.Error e) {
                                GLib.warning("Error running html2rss fallback: %s", e.message);
                                GLib.Idle.add(() => {
                                    window.show_toast("No RSS feeds found");
                                    return false;
                                });
                            }
                        } else {
                            GLib.warning("No html2rss binary found in expected locations");
                            GLib.Idle.add(() => {
                                window.show_toast("No RSS feeds found");
                                return false;
                            });
                        }
                    }
                }
            } catch (GLib.Error e) {
                GLib.warning("Error discovering RSS feed: %s", e.message);
                GLib.Idle.add(() => {
                    window.show_toast("Error discovering RSS feed");
                    return false;
                });
            }
            return null;
        });
    }
}
