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

// Single source of truth for which sources are enabled, their capabilities,
// URL-based source inference, and source filtering/validation.

// Callback for RSS feed addition
public delegate void RssFeedAddCallback(bool success, string feed_name);

 public class SourceManager : GLib.Object {

    // All available built-in sources
    private const string[] ALL_BUILTIN_SOURCES = {
        "guardian", "bbc", "nytimes", "wsj",
        "bloomberg", "abc", "npr", "fox", "pbs"
    };

    // Currently enabled sources (references prefs)
    private weak NewsPreferences prefs;
    private weak NewsWindow window;

    // Signals for UI operations
    public signal void request_show_toast(string message, bool persistent = false);

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
            case "abc": return NewsSource.ABC_NEWS;
            case "npr": return NewsSource.NPR;
            case "fox": return NewsSource.FOX;
            case "pbs": return NewsSource.PBS;
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
            case NewsSource.ABC_NEWS: return "abc";
            case NewsSource.NPR: return "npr";
            case NewsSource.FOX: return "fox";
            case NewsSource.PBS: return "pbs";
            default: return "guardian";
        }
    }

    // Get human-readable display name for a NewsSource
    public static string get_source_name(NewsSource source) {
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
                return "NY Times";
            case NewsSource.BLOOMBERG:
                return "Bloomberg";
            case NewsSource.ABC_NEWS:
                return "ABC News";
            case NewsSource.NPR:
                return "NPR";
            case NewsSource.FOX:
                return "Fox News";
            case NewsSource.PBS:
                return "PBS NewsHour";
            default:
                return "News";
        }
    }

    // Filters out "custom:<url>" entries first - source_id_to_enum() falls back to
    // GUARDIAN for unrecognized ids, which would otherwise map every custom feed to a bogus GUARDIAN entry.
    public ArrayList<NewsSource> get_enabled_source_enums() {
        var result = new ArrayList<NewsSource>();
        var enabled = get_enabled_sources();
        foreach (var src_id in enabled) {
            if (src_id.has_prefix("custom:")) continue;
            result.add(source_id_to_enum(src_id));
        }
        return result;
    }

    // Return the NewsSource the UI should treat as "active". If the
    // user has enabled exactly one preferred source, map that id to the
    // corresponding enum; otherwise use the explicit prefs.news_source.
    public NewsSource effective_news_source() {
        if (prefs.preferred_sources != null && prefs.preferred_sources.size == 1) {
            return source_id_to_enum(prefs.preferred_sources.get(0));
        }
        return prefs.news_source;
    }

    // Helper: Strip metadata separators from display name (||logo_url and ##category::cat)
    private static string strip_metadata_separators(string? name) {
        if (name == null || name.length == 0) return "";

        string result = name;

        // Strip logo URL separator
        int pipe_idx = result.index_of("||");
        if (pipe_idx >= 0) {
            result = result.substring(0, pipe_idx);
        }

        // Strip category suffix
        int cat_idx = result.index_of("##category::");
        if (cat_idx >= 0) {
            result = result.substring(0, cat_idx);
        }

        return result.strip();
    }

    // Helper: Construct Google favicon URL for a given host
    private static string get_favicon_url(string host) {
        return "https://www.google.com/s2/favicons?domain=" + host + "&sz=128";
    }

    // Helper: Parse source metadata string and extract display name and logo URL
    // Format: "Display Name||logo_url##category::cat"
    private static void parse_source_metadata(string? metadata, out string? display_name, out string? logo_url) {
        display_name = null;
        logo_url = null;

        if (metadata == null || metadata.length == 0) return;

        display_name = metadata;
        int pipe_idx = metadata.index_of("||");
        if (pipe_idx >= 0 && metadata.length > pipe_idx + 2) {
            display_name = metadata.substring(0, pipe_idx).strip();
            logo_url = metadata.substring(pipe_idx + 2).strip();
            // Remove category suffix from logo URL
            logo_url = strip_metadata_separators(logo_url);
        }

        // Remove category suffix from display name
        display_name = strip_metadata_separators(display_name);
    }

    // Helper: Resolve metadata with priority fallback
    // Priority: primary > secondary > existing > fallback
    private static string? resolve_metadata_value(string? primary, string? secondary, string? existing, string? fallback) {
        if (primary != null && primary.length > 0) return primary;
        if (secondary != null && secondary.length > 0) return secondary;
        if (existing != null && existing.length > 0) return existing;
        return fallback;
    }

    // Helper: Fetch and resolve complete metadata for a source
    // Checks SourceMetadata, falls back to provided values and favicon service
    private void resolve_complete_metadata(
        string host,
        string article_url,
        string? api_display_name,
        string? api_logo_url,
        string? article_display_name,
        string? article_logo_url,
        string fallback_display_name,
        out string resolved_display_name,
        out string resolved_logo_url
    ) {
        // Check if we already have SourceMetadata for this source
        string? existing_display_name = null;
        string? existing_logo_url = null;
        string? existing_filename = null;
        SourceMetadata.get_source_info_by_url(article_url, out existing_display_name, out existing_logo_url, out existing_filename);

        // Resolve with priority: API > article > existing > fallback
        resolved_display_name = resolve_metadata_value(api_display_name, article_display_name, existing_display_name, fallback_display_name);
        resolved_logo_url = resolve_metadata_value(api_logo_url, article_logo_url, existing_logo_url, get_favicon_url(host));
    }

    // Normalize source display name to canonical ID
    // Handles names like "The Guardian||logo_url", "Bloomberg", etc.
    // Returns null if not a recognized built-in source
    public static string? normalize_source_display_name_to_id(string? display_name) {
        if (display_name == null || display_name.length == 0) {
            return null;
        }

        string clean_name = strip_metadata_separators(display_name);
        string low = clean_name.down();

        // Map display names to source IDs
        if (low.index_of("guardian") >= 0) return "guardian";
        if (low == "bbc" || low == "bbc news" || low.index_of("bbc") >= 0) return "bbc";
        if (low == "reddit") return "reddit";
        if (low.index_of("new york times") >= 0 || low.index_of("ny times") >= 0 || low.index_of("nytimes") >= 0) return "nytimes";
        if (low.index_of("wall street") >= 0 || low == "wsj") return "wsj";
        if (low.index_of("bloomberg") >= 0) return "bloomberg";
        if (low.index_of("abc news") >= 0 || low.index_of("abcnews") >= 0) return "abc";
        if (low == "npr") return "npr";
        if (low.index_of("fox") >= 0) return "fox";
        if (low.index_of("pbs") >= 0) return "pbs";
        if (low.index_of("hacker news") >= 0 || low == "hackernews") return "hackernews";

        return null; // Not a recognized built-in source
    }

    // Infer source from URL by checking known domain substrings.
    // Returns UNKNOWN for unrecognized URLs to avoid incorrect branding.
    public static NewsSource infer_source_from_url(string? url) {
        if (url == null || url.length == 0) {
            return NewsSource.UNKNOWN;
        }

        string low = url.down();

        if (low.index_of("guardian") >= 0 || low.index_of("theguardian") >= 0) {
            return NewsSource.GUARDIAN;
        }
        if (low.index_of("bbc.co") >= 0 || low.index_of("bbc.") >= 0) {
            return NewsSource.BBC;
        }
        if (low.index_of("reddit.com") >= 0 || low.index_of("redd.it") >= 0) {
            return NewsSource.REDDIT;
        }
        if (low.index_of("nytimes") >= 0 || low.index_of("nyti.ms") >= 0) {
            return NewsSource.NEW_YORK_TIMES;
        }
        if (low.index_of("wsj.com") >= 0 || low.index_of("dowjones") >= 0) {
            return NewsSource.WALL_STREET_JOURNAL;
        }
        if (low.index_of("bloomberg") >= 0) {
            return NewsSource.BLOOMBERG;
        }
        if (low.index_of("abcnews") >= 0) {
            return NewsSource.ABC_NEWS;
        }
        if (low.index_of("npr.org") >= 0) {
            return NewsSource.NPR;
        }
        if (low.index_of("foxnews") >= 0 || low.index_of("fox.com") >= 0) {
            return NewsSource.FOX;
        }
        if (low.index_of("pbs.org") >= 0) {
            return NewsSource.PBS;
        }

        // Unknown source - don't default to user preference to avoid incorrect branding
        return NewsSource.UNKNOWN;
    }


    // Infer source ID from URL
    public static string infer_source_id_from_url(string? url) {
        return source_enum_to_id(infer_source_from_url(url));
    }

    // Resolve a NewsSource from a provided display/source name if possible;
    // fall back to URL inference when the name is missing or unrecognized.
    public static NewsSource resolve_source(string? source_name, string url) {
        // Strip metadata separators
        string? clean_name = strip_metadata_separators(source_name);

        // Start with URL-inferred source as a sensible default
        NewsSource resolved = infer_source_from_url(url);
        if (clean_name != null && clean_name.length > 0) {
            string low = clean_name.down();
            if (low.index_of("guardian") >= 0) resolved = NewsSource.GUARDIAN;
            else if (low.index_of("bbc") >= 0) resolved = NewsSource.BBC;
            else if (low.index_of("reddit") >= 0) resolved = NewsSource.REDDIT;
            // NYTimes: check for "nytimes" or "ny times" but exclude "new york post"
            else if (low.index_of("nytimes") >= 0 || low.index_of("ny times") >= 0 ||
            (low.index_of("new york times") >= 0 && low.index_of("post") < 0)) resolved = NewsSource.NEW_YORK_TIMES;
            else if (low.index_of("wsj") >= 0 || low.index_of("wall street") >= 0) resolved = NewsSource.WALL_STREET_JOURNAL;
            else if (low.index_of("bloomberg") >= 0) resolved = NewsSource.BLOOMBERG;
            else if (low.index_of("abc news") >= 0 || low.index_of("abcnews") >= 0) resolved = NewsSource.ABC_NEWS;
            else if (low.index_of("npr") >= 0) resolved = NewsSource.NPR;
            else if (low.index_of("fox") >= 0) resolved = NewsSource.FOX;
            else if (low.index_of("pbs") >= 0) resolved = NewsSource.PBS;
            // If we couldn't match the provided name, keep the URL-inferred value
        }
        return resolved;
    }

    // Normalize a source name for consistent tracking across the app.
    // Handles local news special case and tries to match RSS source names.
    public static string? normalize_source_name(string? source_name, string category_id, string url) {
        string? result = source_name;
        if (result == null || result.length == 0) {
            if (category_id == "local_news") {
                var local_area = NewsPreferences.get_instance().get_active_local_area();
                result = local_area != null ? local_area.city : "Local News";
            } else {
                NewsSource inferred = infer_source_from_url(url);
                result = get_source_name(inferred);
            }
        } else {
            // Try to match to an RSS source in the database for consistent naming
            var rss_store = Paperboy.RssSourceStore.get_instance();
            var all_sources = rss_store.get_all_sources();
            foreach (var src in all_sources) {
                if (src.name == null || result == null) continue;
                string src_lower = src.name.down();
                string result_lower = result.down();
                if (src_lower != null && result_lower != null && (src_lower.contains(result_lower) || result_lower.contains(src_lower))) {
                    result = src.name;
                    break;
                }
            }
        }
        return result;
    }

    // Check if a source name string matches a known NewsSource enum.
    // Used to determine if a provided name corresponds to a built-in source.
    public static bool source_name_matches(NewsSource source, string name) {
        if (name == null || name.length == 0) return false;
        string n = name.down();
        if (n == null) return false;
        switch (source) {
            case NewsSource.GUARDIAN: return n.contains("guardian");
            case NewsSource.BBC: return n.contains("bbc");
            case NewsSource.REDDIT: return n.contains("reddit");
            case NewsSource.NEW_YORK_TIMES: return n.contains("nytimes") || n.contains("new york times");
            case NewsSource.WALL_STREET_JOURNAL: return n.contains("wsj") || n.contains("wall street");
            case NewsSource.BLOOMBERG: return n.contains("bloomberg");
            case NewsSource.ABC_NEWS: return n.contains("abc news") || n.contains("abcnews");
            case NewsSource.NPR: return n.contains("npr");
            case NewsSource.FOX: return n.contains("fox");
            case NewsSource.PBS: return n.contains("pbs");
            default: return false;
        }
    }

    // Determine whether the given article URL belongs to a built-in source.
    // Returns true if infer_source_from_url returns a known source (not UNKNOWN).
    public static bool is_article_from_builtin(string? article_url) {
        if (article_url == null || article_url.length == 0) return false;
        return infer_source_from_url(article_url) != NewsSource.UNKNOWN;
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

        // Lifestyle is not provided by BBC, Reddit, ABC News, or PBS NewsHour
        if (category == "lifestyle") {
            if (source_id == "bbc" || source_id == "reddit" || source_id == "abc" || source_id == "pbs") {
                return false;
            }
        }

        // PBS NewsHour also has no dedicated technology or sports desk -
        // see NewsService.supports_category for the matching enum-based check.
        if (source_id == "pbs" && (category == "technology" || category == "sports")) {
            return false;
        }

        // All other sources support standard categories
        return is_standard_category(category);
    }


    // Check if a category is a Bloomberg category (including overlaps with standard categories)
    public static bool is_bloomberg_category(string category) {
        return is_bloomberg_exclusive_category(category) ||
               category == "politics" || category == "technology" || category == "business";
    }


    // Check if a category is Bloomberg-exclusive (not available on other sources)
    public static bool is_bloomberg_exclusive_category(string category) {
        switch (category) {
            case "markets":
            case "industries":
            case "economics":
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

        // Sports articles come from the Paperboy backend's sports supplement, which pulls from
        // third-party sites that don't map to any built-in source id, so skip the enabled-source check.
        if (category == "sports") {
            return true;
        }

        // Business is supplemented with stock market news from the Paperboy
        // backend's Finnhub-backed endpoint, from third-party sites that don't
        // map to any built-in source id, so skip the enabled-source check here too.
        if (category == "business") {
            return true;
        }

        // RSS feed views - show all articles from that feed (no source filtering)
        if (category.has_prefix("rssfeed:")) {
            return true;
        }

        // My Feed with custom RSS sources - allow articles from custom sources
        // Custom RSS articles will have category "myfeed" but URLs that don't match built-in sources
        if (category == "myfeed") {
            // Check if this URL belongs to a built-in source
            if (!is_article_from_builtin(article_url)) {
                // This is likely a custom RSS source - allow it in My Feed
                return true;
            }

            // For built-in sources in My Feed, check if they're enabled
            string article_source_id = infer_source_id_from_url(article_url);
            return is_source_enabled(article_source_id);
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

    // Fetches the feed to discover its real title and a favicon before adding it.
    public void add_rss_feed_with_discovery(string feed_url, string? user_provided_name, owned RssFeedAddCallback callback) {
        new Thread<void*>("rss-add-with-discovery", () => {
            string final_name = user_provided_name != null && user_provided_name.length > 0 ? user_provided_name : "";
            string? logo_url = null;
            string? host = null;

            try {
                host = UrlUtils.extract_host_from_url(feed_url);

                if (final_name.length == 0) {
                    try {
                        var msg = new Soup.Message("GET", feed_url);
                        msg.get_request_headers().append("User-Agent", "paperboy/0.5.1a");

                        GLib.Bytes? response = window.session.send_and_read(msg, null);
                        var status = msg.get_status();

                        if (status == Soup.Status.OK && response != null) {
                            string body = (string) response.get_data();

                            final_name = extract_feed_title_from_xml(body);

                            if (final_name.length == 0 && host != null) {
                                final_name = host.replace("www.", "");
                            }
                        }
                    } catch (GLib.Error e) {
                        GLib.warning("Failed to fetch RSS feed for title extraction: %s", e.message);
                    }
                }

                if (final_name.length == 0 && host != null) {
                    final_name = host.replace("www.", "");
                } else if (final_name.length == 0) {
                    final_name = feed_url;
                }

                string? existing_display_name = null;
                bool force_update_meta = false;
                if (host != null) {
                    string? existing_logo_url = null;
                    string? existing_filename = null;
                    SourceMetadata.get_source_info_by_url(feed_url, out existing_display_name, out existing_logo_url, out existing_filename);

                    // Prefer the newly discovered title over an existing domain-like name
                    // (e.g. "example.com") when the discovered one looks more human.
                    if (existing_display_name != null && existing_display_name.length > 0 && final_name != null && final_name.length > 0) {
                        bool existing_is_domain = existing_display_name.index_of(".") >= 0 && existing_display_name.index_of(" ") < 0;
                        string final_name_lower = final_name.down();
                        bool new_is_more_human = (final_name.index_of(" ") >= 0) || (final_name_lower != null && final_name != final_name_lower);
                        if (existing_is_domain && new_is_more_human) {
                            force_update_meta = true;
                        } else {
                            final_name = existing_display_name;
                        }
                    }

                    if (existing_logo_url != null && existing_logo_url.length > 0) {
                        logo_url = existing_logo_url;
                    }
                }

                if (logo_url == null && host != null) {
                    try {
                        string api_url = "https://paperboybackend.onrender.com/logos?domain=" + host;
                        var msg = new Soup.Message("GET", api_url);
                        msg.get_request_headers().append("User-Agent", "paperboy/0.5.1a");
                        
                        GLib.Bytes? response = window.session.send_and_read(msg, null);
                        var status = msg.get_status();
                        
                        if (status == Soup.Status.OK && response != null) {
                            string body = (string) response.get_data();
                            var parser = new Json.Parser();
                            parser.load_from_data(body, -1);
                            var root = parser.get_root();
                            
                            if (root != null && root.get_node_type() == Json.NodeType.OBJECT) {
                                var obj = root.get_object();
                                if (obj.has_member("logo_url") && !obj.get_null_member("logo_url")) {
                                    logo_url = obj.get_string_member("logo_url");
                                }
                            }
                        }
                    } catch (GLib.Error e) {
                        GLib.warning("Failed to fetch logo from Paperboy API: %s", e.message);
                    }
                }

                if (logo_url == null && host != null) {
                    logo_url = get_favicon_url(host);
                }

                var store = Paperboy.RssSourceStore.get_instance();
                bool success = store.add_source(final_name, feed_url, null);

                if (success && logo_url != null && host != null) {
                    SourceMetadata.update_index_and_fetch(host, final_name, logo_url, "https://" + host, window.session, feed_url);
                }

                GLib.Idle.add(() => {
                    // Show as active without requiring the user to flip its switch in Settings.
                    if (success && window != null && window.prefs != null) {
                        window.prefs.set_preferred_source_enabled("custom:" + feed_url, true);
                        window.prefs.save_config();
                    }
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

    // Recursively search an Xml.Node subtree for the first <title> element
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
            // Real XML parsing (not regex) to handle Atom titles with attributes and CDATA.
            Xml.Doc* doc = null;
            try {
                int parser_options = (int) (Xml.ParserOption.NONET | Xml.ParserOption.NOCDATA | Xml.ParserOption.NOBLANKS);
                doc = Xml.Parser.read_memory(xml_content, (int) xml_content.length, null, null, parser_options);
            } catch (GLib.Error e) {
                string cleaned = xml_content.replace("\0", "");
                try { doc = Xml.Parser.read_memory(cleaned, (int) cleaned.length, null, null, (int)(Xml.ParserOption.NONET | Xml.ParserOption.NOCDATA | Xml.ParserOption.NOBLANKS)); } catch (GLib.Error ee) { doc = null; }
            }

            if (doc != null) {
                Xml.Node* root = doc->get_root_element();
                if (root != null) {
                    string? found = find_first_title_in_xml(root);
                    if (found != null) {
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
    private class GeneratedFeedResult : GLib.Object {
        public bool success = false;
        public string? rss_xml = null;
        public string? error_message = null;
    }

    // GeneratedFeedService.generate_async() must run on the main thread
    // (WebKit), but follow_rss_source runs entirely on a background thread -
    // bridge the two with a condition variable, same pattern used for feed
    // regeneration in FeedUpdateManager.
    private GeneratedFeedResult generate_feed_via_webkit_blocking(string url) {
        var mutex = GLib.Mutex();
        var cond = GLib.Cond();
        bool done = false;
        var result = new GeneratedFeedResult();

        GLib.Idle.add(() => {
            Paperboy.GeneratedFeedService.generate_async(url, (success, rss_xml, error_message) => {
                mutex.lock();
                result.success = success;
                result.rss_xml = rss_xml;
                result.error_message = error_message;
                done = true;
                cond.signal();
                mutex.unlock();
            });
            return false;
        });

        mutex.lock();
        while (!done) {
            cond.wait(mutex);
        }
        mutex.unlock();

        return result;
    }

    public void follow_rss_source(string article_url, string? source_metadata = null) {
        // Built-in sources can't be re-added as custom RSS entries.
        if (is_article_from_builtin(article_url)) {
            GLib.Idle.add(() => {
                if (window != null) window.clear_persistent_toast();
                request_show_toast("Source is built-in");
                return false;
            });
            return;
        }

        new Thread<void*>("rss-discover", () => {
            try {
                string host = UrlUtils.extract_host_from_url(article_url);
                if (host == null || host.length == 0) {
                    GLib.warning("Cannot follow source: invalid article URL");
                    return null;
                }

                string? article_display_name = null;
                string? article_logo_url = null;
                parse_source_metadata(source_metadata, out article_display_name, out article_logo_url);

                bool rss_discovery_succeeded = false;
                try {
                    string backend_url = "https://paperboybackend.onrender.com/rss/discover";
                    var msg = new Soup.Message("POST", backend_url);
                    var headers = msg.get_request_headers();
                    headers.append("accept", "application/json");
                    headers.append("Content-Type", "application/json");
                    headers.append("User-Agent", "paperboy/0.5.1a");

                    string escaped_url = article_url.replace("\\", "\\\\").replace("\"", "\\\"");
                    string json_body = "{\"url\":\"" + escaped_url + "\",\"max_pages\":1}";
                    msg.set_request_body_from_bytes("application/json", new GLib.Bytes(json_body.data));

                    GLib.Bytes? response = window.session.send_and_read(msg, null);
                    var status = msg.get_status();

                    if (status == Soup.Status.OK && response != null) {
                        unowned uint8[] data = response.get_data();
                        if (data == null || data.length == 0) {
                            GLib.warning("RSS discovery returned empty response");
                        } else {
                            string body = (string) data;

                            try {
                                var parser = new Json.Parser();
                                parser.load_from_data(body, -1);
                                var root = parser.get_root();
                                
                                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) {
                                    GLib.warning("RSS discovery returned invalid JSON structure");
                                } else {
                                    var root_obj = root.get_object();

                                    if (root_obj.has_member("feeds")) {
                                        var feeds_array = root_obj.get_array_member("feeds");
                                        if (feeds_array.get_length() > 0) {
                                            var first_feed = feeds_array.get_object_element(0);
                                            string feed_url = first_feed.get_string_member("url");
                                            string feed_title = first_feed.has_member("title") ? first_feed.get_string_member("title") : host;
                                            string? feed_description = first_feed.has_member("description") ? first_feed.get_string_member("description") : null;

                                            string? api_source_name = null;
                                            string? api_logo_url = null;
                                            if (first_feed.has_member("source_name")) {
                                                api_source_name = first_feed.get_string_member("source_name");
                                            }
                                            if (first_feed.has_member("logo_url")) {
                                                api_logo_url = first_feed.get_string_member("logo_url");
                                            }

                                            // Priority: API metadata (canonical) > article metadata > feed title.
                                            string? metadata_display_name = api_source_name;
                                            string? metadata_logo_url = api_logo_url;

                                            if (metadata_display_name == null || metadata_display_name.length == 0) {
                                                metadata_display_name = article_display_name;
                                            }
                                            if (metadata_logo_url == null || metadata_logo_url.length == 0) {
                                                metadata_logo_url = article_logo_url;
                                            }

                                            // A title over 50 chars is likely a description, not a name.
                                            string cleaned_feed_title = feed_title;
                                            if (feed_title.length > 50) {
                                                cleaned_feed_title = host;
                                            }

                                            string final_title = (metadata_display_name != null && metadata_display_name.length > 0) ? metadata_display_name : cleaned_feed_title;

                                            var store = Paperboy.RssSourceStore.get_instance();
                                            bool success = store.add_source(final_title, feed_url, null);

                                            if (success) {
                                                string save_display_name;
                                                string save_logo_url;
                                                resolve_complete_metadata(
                                                    host, article_url,
                                                    api_source_name, api_logo_url,
                                                    article_display_name, article_logo_url,
                                                    final_title,
                                                    out save_display_name, out save_logo_url
                                                );

                                                SourceMetadata.update_index_and_fetch(host, save_display_name, save_logo_url, "https://" + host, window.session, feed_url);
                                            }

                                            if (success) {
                                                GLib.Idle.add(() => {
                                                    // Show as active without requiring the user to flip its switch in Settings.
                                                    if (window != null && window.prefs != null) {
                                                        window.prefs.set_preferred_source_enabled("custom:" + feed_url, true);
                                                        window.prefs.save_config();
                                                    }
                                                    // add_source()'s source_added signal already queued a sidebar rebuild
                                                    // that can run before the source is enabled and filter it back out;
                                                    // rebuild again now that it's enabled.
                                                    if (window != null && window.sidebar_manager != null) {
                                                        window.sidebar_manager.rebuild_sidebar();
                                                    }
                                                    request_show_toast("Following " + final_title);
                                                    return false;
                                                });
                                            } else {
                                                GLib.Idle.add(() => {
                                                    request_show_toast("Source already followed");
                                                    return false;
                                                });
                                            }

                                            rss_discovery_succeeded = true;
                                        } else {
                                            GLib.warning("RSS discovery returned no feeds; will attempt local feed generation fallback");
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
                
                GLib.message("RSS Discovery status: succeeded=%s", rss_discovery_succeeded.to_string());

                if (!rss_discovery_succeeded) {
                    if (host == null || host.length == 0) {
                        GLib.warning("Cannot attempt feed generation fallback: host is null or empty");
                        GLib.Idle.add(() => {
                            request_show_toast("Failed to discover RSS feed");
                            return false;
                        });
                    } else {
                        GLib.message("Generating feed for host via WebKit render: %s", host);

                        GLib.Idle.add(() => {
                            if (window != null) window.clear_persistent_toast();
                            request_show_toast("Generating feed for this source...", true);
                            return false;
                        });

                        var gen_result = generate_feed_via_webkit_blocking(article_url);

                        if (gen_result.success && gen_result.rss_xml != null) {
                            string gen_feed = gen_result.rss_xml;

                            int item_count = RssValidatorUtils.get_item_count(gen_feed);
                            if (item_count == 0) {
                                GLib.warning("Generated RSS has no items");
                                GLib.Idle.add(() => {
                                    request_show_toast("Generated feed has no articles");
                                    return false;
                                });
                                return null;
                            }

                            GLib.print("✓ Generated valid RSS feed with %d items\n", item_count);

                            try {
                                string data_dir = GLib.Environment.get_user_data_dir();
                                string paperboy_dir = GLib.Path.build_filename(data_dir, "paperboy");
                                string gen_dir = GLib.Path.build_filename(paperboy_dir, "generated_feeds");
                                try {
                                    GLib.DirUtils.create_with_parents(gen_dir, 0755);
                                } catch (GLib.Error e) {
                                    GLib.warning("Failed to create directory '%s': %s", gen_dir, e.message);
                                }
                                string safe_host = host.replace("/", "_").replace(":", "_");
                                string filename = safe_host + ".xml";
                                string file_path = GLib.Path.build_filename(gen_dir, filename);

                                var f = GLib.File.new_for_path(file_path);
                                var out_stream = f.replace(null, false, GLib.FileCreateFlags.NONE, null);
                                var writer = new DataOutputStream(out_stream);
                                // Strip illegal control chars so it's safe for XML storage
                                string safe_feed = RssValidatorUtils.sanitize_for_xml(gen_feed);
                                writer.put_string(safe_feed);
                                writer.close(null);

                                gen_feed = "file://" + file_path;
                            } catch (GLib.Error e) {
                                GLib.warning("Failed to save generated RSS feed: %s", e.message);
                            }

                            var store = Paperboy.RssSourceStore.get_instance();

                            // Keyed by host, not article_url, since that's how metadata is saved
                            string feed_name = host;
                            string? existing_display_name = null;
                            string? existing_logo_url = null;
                            string? existing_filename = null;

                            SourceMetadata.get_source_info_by_url(host, out existing_display_name, out existing_logo_url, out existing_filename);

                            if (existing_display_name != null && existing_display_name.length > 0) {
                                feed_name = existing_display_name;
                                GLib.print("✓ Using existing metadata: %s\n", feed_name);
                            } else if (article_display_name != null && article_display_name.length > 0) {
                                feed_name = article_display_name;
                                GLib.print("✓ Using article metadata: %s\n", feed_name);
                            } else {
                                GLib.print("⚠ No existing metadata found for %s, using host as name\n", host);
                            }

                            // Store the original website URL so the feed can be regenerated later
                            string original_website_url = "https://" + host;
                            bool success = store.add_source_with_original_url(feed_name, gen_feed, original_website_url, null);

                            if (success) {
                                string? logo_url_to_save = existing_logo_url;

                                if (logo_url_to_save == null || logo_url_to_save.length == 0) {
                                    logo_url_to_save = (article_logo_url != null && article_logo_url.length > 0) ? article_logo_url : get_favicon_url(host);
                                }

                                SourceMetadata.update_index_and_fetch(host, feed_name, logo_url_to_save, "https://" + host, window.session, gen_feed);
                                GLib.print("✓ Saved metadata for %s\n", feed_name);
                            }

                            if (success) {
                                GLib.Idle.add(() => {
                                    // Show as active without requiring the user to flip its switch in Settings.
                                    if (window != null && window.prefs != null) {
                                        window.prefs.set_preferred_source_enabled("custom:" + gen_feed, true);
                                        window.prefs.save_config();
                                    }
                                    // add_source_with_original_url()'s source_added signal already queued a
                                    // sidebar rebuild that can run before the source is enabled and filter it
                                    // back out; rebuild again now that it's enabled.
                                    if (window != null && window.sidebar_manager != null) {
                                        window.sidebar_manager.rebuild_sidebar();
                                    }
                                    request_show_toast("Following %s (%d articles)".printf(feed_name, item_count));
                                    return false;
                                });
                            } else {
                                GLib.Idle.add(() => {
                                    request_show_toast("Source already followed");
                                    return false;
                                });
                            }
                        } else {
                            GLib.warning("WebKit feed generation failed for %s: %s", host, gen_result.error_message ?? "unknown error");
                            GLib.Idle.add(() => {
                                request_show_toast("No RSS feeds found");
                                return false;
                            });
                        }
                    }
                }
            } catch (GLib.Error e) {
                GLib.warning("Error discovering RSS feed: %s", e.message);
                GLib.Idle.add(() => {
                    request_show_toast("Error discovering RSS feed");
                    return false;
                });
            }
            return null;
        });
    }
}
