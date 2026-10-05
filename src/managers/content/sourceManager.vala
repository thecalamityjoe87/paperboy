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
        return prefs.preferred_sources;
    }

    // Enabled built-in sources only - "custom:<url>" feeds and any other
    // unrecognized ids are skipped.
    public ArrayList<NewsSource> get_enabled_source_enums() {
        var result = new ArrayList<NewsSource>();
        foreach (var src_id in get_enabled_sources()) {
            var builtin = BuiltinSources.for_id(src_id);
            if (builtin != null) result.add(builtin.source);
        }
        return result;
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
        resolved_logo_url = resolve_metadata_value(api_logo_url, article_logo_url, existing_logo_url, SourceMetadata.google_favicon_url(host));
    }

    // Normalize source display name to canonical ID
    // Handles names like "The Guardian||logo_url", "Bloomberg", etc.
    // Returns null if not a recognized built-in source
    public static string? normalize_source_display_name_to_id(string? display_name) {
        if (display_name == null || display_name.length == 0) {
            return null;
        }

        string clean_name = SourceLabel.name_of(display_name);
        var builtin = BuiltinSources.for_source(BuiltinSources.from_name(clean_name));
        if (builtin != null) return builtin.id;

        // Not a built-in outlet, but tracked by id the same way
        string low = clean_name.down();
        if (low.index_of("hacker news") >= 0 || low == "hackernews") return "hackernews";

        return null;
    }

    // Resolve a NewsSource from a provided display/source name if possible;
    // fall back to URL inference when the name is missing or unrecognized.
    public static NewsSource resolve_source(string? source_name, string url) {
        // Strip metadata separators
        string? clean_name = SourceLabel.name_of(source_name);

        // The name wins; the URL decides when the name isn't a built-in outlet's
        NewsSource by_name = BuiltinSources.from_name(clean_name);
        return by_name != NewsSource.UNKNOWN ? by_name : BuiltinSources.from_url(url);
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
                result = BuiltinSources.short_name(BuiltinSources.from_url(url));
            }
        } else {
            // Try to match to an RSS source in the database for consistent naming.
            // Keep the category, which Front Page uses to route the article to its row.
            // Whole-name match only: a substring match renamed "TIME" to
            // "The New York Times" (and gave it NYT's branding).
            var label = SourceLabel.parse(result);
            string? name_lower = label.name != null ? label.name.strip().down() : null;
            var rss_store = Paperboy.RssSourceStore.get_instance();
            var all_sources = rss_store.get_all_sources();
            foreach (var src in all_sources) {
                if (src.name == null || name_lower == null || name_lower.length == 0) continue;
                if (src.name.strip().down() == name_lower) {
                    result = SourceLabel.encode(src.name, null, label.category);
                    break;
                }
            }
        }
        return result;
    }

    // Determine whether the given article URL belongs to a built-in source.
    // Returns true if BuiltinSources.from_url() recognizes it (not UNKNOWN).
    public static bool is_article_from_builtin(string? article_url) {
        return builtin_source_for_article(article_url) != NewsSource.UNKNOWN;
    }

    // Matched on the host, so another site's article with "bloomberg" in its slug doesn't count.
    public static NewsSource builtin_source_for_article(string? article_url) {
        if (article_url == null || article_url.length == 0) return NewsSource.UNKNOWN;
        return BuiltinSources.from_url(UrlUtils.extract_host_from_url(article_url));
    }

    // Whether `article_url` is from a built-in outlet the user has turned off.
    // Matched on the host; articles from other sites never are.
    public bool is_from_disabled_source(string article_url) {
        return is_from_disabled_builtin(article_url, get_enabled_sources());
    }

    // Static form for fetchers, which filter before counting toward a cap.
    public static bool is_from_disabled_builtin(string article_url, Gee.List<string> enabled_sources) {
        var builtin = BuiltinSources.for_source(builtin_source_for_article(article_url));
        return builtin != null && !enabled_sources.contains(builtin.id);
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
                    logo_url = SourceMetadata.google_favicon_url(host);
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
                int parser_options = (int) (Xml.ParserOption.NONET | Xml.ParserOption.NOCDATA | Xml.ParserOption.NOBLANKS | Xml.ParserOption.NOERROR | Xml.ParserOption.NOWARNING);
                doc = Xml.Parser.read_memory(xml_content, (int) xml_content.length, null, null, parser_options);
            } catch (GLib.Error e) {
                string cleaned = xml_content.replace("\0", "");
                try { doc = Xml.Parser.read_memory(cleaned, (int) cleaned.length, null, null, (int)(Xml.ParserOption.NONET | Xml.ParserOption.NOCDATA | Xml.ParserOption.NOBLANKS | Xml.ParserOption.NOERROR | Xml.ParserOption.NOWARNING)); } catch (GLib.Error ee) { doc = null; }
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

    private void enable_builtin_source(NewsSource source) {
        var builtin = BuiltinSources.for_source(source);
        if (builtin == null) return;
        if (window != null) window.clear_persistent_toast();
        var prefs = NewsPreferences.get_instance();
        if (!prefs.preferred_source_enabled(builtin.id)) {
            prefs.set_preferred_source_enabled(builtin.id, true);
            prefs.save_config();
        }
        request_show_toast(_("Enabled %s").printf(builtin.short_name));
        if (window != null && window.sidebar_manager != null) window.sidebar_manager.update_badge_for_category("myfeed");
    }

    public void follow_rss_source(string article_url, string? source_metadata = null) {
        // A Google News link's host is Google's, not the outlet's - follow
        // the real article instead, or the source gets saved under news.google.com.
        if (GoogleNewsUrlResolver.is_google_news_url(article_url)) {
            new Thread<void*>("gnews-follow", () => {
                string? resolved = GoogleNewsUrlResolver.resolve_sync(article_url);
                GLib.Idle.add(() => {
                    if (resolved != null && !GoogleNewsUrlResolver.is_google_news_url(resolved)) {
                        follow_rss_source(resolved, source_metadata);
                    } else {
                        request_show_toast(_("Couldn't find this article's source"));
                    }
                    return false;
                });
                return null;
            });
            return;
        }

        // Built-in sources are followed by switching them on, not by adding them as a feed.
        NewsSource builtin = builtin_source_for_article(article_url);
        if (builtin != NewsSource.UNKNOWN) {
            GLib.Idle.add(() => {
                enable_builtin_source(builtin);
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

                var article_label = SourceLabel.parse(source_metadata);
                string? article_display_name = article_label.name.length > 0 ? article_label.name : null;
                string? article_logo_url = article_label.logo_url;

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
                                                    request_show_toast(_("Following %s").printf(final_title));
                                                    return false;
                                                });
                                            } else {
                                                GLib.Idle.add(() => {
                                                    request_show_toast(_("Source already followed"));
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
                            request_show_toast(_("Failed to discover RSS feed"));
                            return false;
                        });
                    } else {
                        GLib.message("Generating feed for host via WebKit render: %s", host);

                        GLib.Idle.add(() => {
                            if (window != null) window.clear_persistent_toast();
                            request_show_toast(_("Generating feed for this source..."), true);
                            return false;
                        });

                        var gen_result = generate_feed_via_webkit_blocking(article_url);

                        if (gen_result.success && gen_result.rss_xml != null) {
                            string gen_feed = gen_result.rss_xml;

                            int item_count = RssValidatorUtils.get_item_count(gen_feed);
                            if (item_count == 0) {
                                GLib.warning("Generated RSS has no items");
                                GLib.Idle.add(() => {
                                    request_show_toast(_("Generated feed has no articles"));
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
                                    logo_url_to_save = (article_logo_url != null && article_logo_url.length > 0) ? article_logo_url : SourceMetadata.google_favicon_url(host);
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
                                    request_show_toast(ngettext("Following %s (%d article)", "Following %s (%d articles)", item_count).printf(feed_name, item_count));
                                    return false;
                                });
                            } else {
                                GLib.Idle.add(() => {
                                    request_show_toast(_("Source already followed"));
                                    return false;
                                });
                            }
                        } else {
                            GLib.warning("WebKit feed generation failed for %s: %s", host, gen_result.error_message ?? "unknown error");
                            GLib.Idle.add(() => {
                                request_show_toast(_("No RSS feeds found"));
                                return false;
                            });
                        }
                    }
                }
            } catch (GLib.Error e) {
                GLib.warning("Error discovering RSS feed: %s", e.message);
                GLib.Idle.add(() => {
                    request_show_toast(_("Error discovering RSS feed"));
                    return false;
                });
            }
            return null;
        });
    }
}
