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

/**
 * FeedUpdateManager - Manages automatic updates of RSS feeds
 * 
 * Updates all followed RSS feeds on app startup and tracks update timestamps
 */
public class FeedUpdateManager : GLib.Object {
    private weak NewsWindow window;
    private HashMap<string, int64?> update_timestamps;
    private const int64 UPDATE_INTERVAL = 3600; // 1 hour in seconds
    private bool is_updating = false;
    
    public FeedUpdateManager(NewsWindow window) {
        this.window = window;
        this.update_timestamps = new HashMap<string, int64?>();
    }
    
    /**
     * Update all RSS feeds asynchronously
     * 
     * This method runs in a background thread and updates all feeds
     * that haven't been updated within the UPDATE_INTERVAL
     */
    public void update_all_feeds_async() {
        if (is_updating) {
            GLib.print("Feed update already in progress, skipping\n");
            return;
        }
        
        is_updating = true;
        
        new Thread<void*>("feed-updater", () => {
            var store = Paperboy.RssSourceStore.get_instance();
            var sources = store.get_all_sources();
            
            if (sources.size == 0) {
                GLib.print("No RSS feeds to update\n");
                is_updating = false;
                return null;
            }
            
            GLib.print("Checking %d RSS feeds for updates...\n", sources.size);
            
            int updated_count = 0;
            int skipped_count = 0;
            int failed_count = 0;
            
            foreach (var source in sources) {
                // Check if feed needs update (based on last_fetched_at)
                int64 now = GLib.get_real_time() / 1000000;
                int64 time_since_fetch = now - source.last_fetched_at;
                
                if (time_since_fetch < UPDATE_INTERVAL) {
                    GLib.print("  ⏭  Skipping %s (updated %lld seconds ago)\n", 
                        source.name, time_since_fetch);
                    skipped_count++;
                    continue;
                }
                
                // Fetch and validate feed
                bool success = update_single_feed(source);
                if (success) {
                    updated_count++;
                } else {
                    failed_count++;
                }
                
                // Small delay between requests to avoid overwhelming servers
                Thread.usleep(500000); // 500ms
            }
            
            // Show summary toast
            GLib.Idle.add(() => {
                if (updated_count > 0 || failed_count > 0) {
                    string message = "RSS feeds: %d updated".printf(updated_count);
                    if (failed_count > 0) {
                        message += ", %d failed".printf(failed_count);
                    }
                    window.show_toast(message);
                }
                return false;
            });
            
            GLib.print("Feed update complete: %d updated, %d skipped, %d failed\n", 
                updated_count, skipped_count, failed_count);
            
            is_updating = false;
            return null;
        });
    }
    
    /**
     * Update a single RSS feed
     * 
     * @param source The RSS source to update
     * @return true if successful, false otherwise
     */
    private bool update_single_feed(Paperboy.RssSource source) {
        // Handle file:// URLs (locally generated feeds) - REGENERATE instead of just validate
        if (source.url.has_prefix("file://")) {
            // Check if we have the original_url to regenerate from
            if (source.original_url == null || source.original_url.length == 0) {
                GLib.warning("  ✗ Cannot regenerate %s: no original_url stored", source.name);
                return false;
            }

            GLib.print("  ⟳ Regenerating feed for %s from %s\n", source.name, source.original_url);

            // Extract host from original_url
            string? host = UrlUtils.extract_host_from_url(source.original_url);
            if (host == null || host.length == 0) {
                GLib.warning("  ✗ Cannot extract host from original_url: %s", source.original_url);
                return false;
            }

            // Find html2rss binary
            string? html2rss_path = find_html2rss_binary();
            if (html2rss_path == null) {
                GLib.warning("  ✗ html2rss binary not found");
                return false;
            }

            try {
                // Run html2rss to generate fresh feed
                // Match the argument format from sourceManager.vala
                string[] argv = {html2rss_path, "--max-pages", "20", source.original_url};
                var proc = new GLib.Subprocess.newv(argv, GLib.SubprocessFlags.STDOUT_PIPE | GLib.SubprocessFlags.STDERR_PIPE);
                
                string? stdout_str = null;
                string? stderr_str = null;
                proc.communicate_utf8(null, null, out stdout_str, out stderr_str);
                proc.wait();
                
                int exit_status = proc.get_exit_status();
                string gen_feed = stdout_str != null ? stdout_str : "";

                if (exit_status == 0 && gen_feed.length > 0) {
                    // Validate the generated feed
                    string? error = null;
                    if (RssValidator.is_valid_rss(gen_feed, out error)) {
                        int item_count = RssValidator.get_item_count(gen_feed);
                        
                        // Check if content actually changed by comparing with old feed
                        bool content_changed = true;
                        string old_file_path = source.url.substring(7); // Remove "file://" prefix
                        
                        try {
                            var old_file = GLib.File.new_for_path(old_file_path);
                            if (old_file.query_exists()) {
                                // Read old feed content
                                uint8[] old_contents;
                                old_file.load_contents(null, out old_contents, null);
                                string old_feed = (string) old_contents;
                                
                                // Compare feeds by checking if they have the same items
                                // We'll use a simple heuristic: compare item count and a hash of GUIDs/links
                                if (RssValidator.is_valid_rss(old_feed, out error)) {
                                    int old_item_count = RssValidator.get_item_count(old_feed);
                                    
                                    if (old_item_count == item_count) {
                                        // Same number of items - do a deeper comparison
                                        // Extract GUIDs/links from both feeds and compare
                                        string old_signature = extract_feed_signature(old_feed);
                                        string new_signature = extract_feed_signature(gen_feed);
                                        
                                        if (old_signature == new_signature) {
                                            content_changed = false;
                                            GLib.print("  ⏭  Skipping %s - content unchanged (%d items)\n", source.name, item_count);
                                        }
                                    }
                                }
                            }
                        } catch (Error e) {
                            // If we can't read old file, assume content changed
                            GLib.warning("  ⚠ Could not read old feed for comparison: %s", e.message);
                        }
                        
                        // Only update if content actually changed
                        if (content_changed) {
                            // Delete old XML file
                            try {
                                var old_file = GLib.File.new_for_path(old_file_path);
                                if (old_file.query_exists()) {
                                    old_file.delete();
                                    GLib.print("  ✓ Deleted old feed file: %s\n", GLib.Path.get_basename(old_file_path));
                                }
                            } catch (Error e) {
                                GLib.warning("  ⚠ Failed to delete old feed file: %s", e.message);
                            }

                            // Save new XML file
                            string data_dir = GLib.Environment.get_user_data_dir();
                            string paperboy_dir = GLib.Path.build_filename(data_dir, "paperboy");
                            string gen_dir = GLib.Path.build_filename(paperboy_dir, "generated_feeds");
                            GLib.DirUtils.create_with_parents(gen_dir, 0755);

                            string safe_host = host.replace("/", "_").replace(":", "_");
                            long ts_val = (long) (GLib.get_real_time() / 1000000);
                            string ts = ts_val.to_string();
                            string filename = safe_host + "-" + ts + ".xml";
                            string new_file_path = GLib.Path.build_filename(gen_dir, filename);

                            var f = GLib.File.new_for_path(new_file_path);
                            var out_stream = f.replace(null, false, GLib.FileCreateFlags.NONE, null);
                            var writer = new DataOutputStream(out_stream);
                            string safe_feed = RssValidator.sanitize_for_xml(gen_feed);
                            writer.put_string(safe_feed);
                            writer.close(null);

                            // Update database with new file path
                            var store = Paperboy.RssSourceStore.get_instance();
                            string new_url = "file://" + new_file_path;
                            store.update_source_url(source.url, new_url);
                            store.update_last_fetched(new_url);

                            GLib.print("  ✓ Regenerated: %s (%d items)\n", source.name, item_count);
                        } else {
                            // Content unchanged, just update timestamp
                            var store = Paperboy.RssSourceStore.get_instance();
                            store.update_last_fetched(source.url);
                        }
                        
                        return true;
                    } else {
                        GLib.warning("  ✗ Generated invalid RSS for %s: %s", source.name, error);
                        return false;
                    }
                } else {
                    GLib.warning("  ✗ html2rss failed for %s (exit=%d)", source.name, exit_status);
                    if (stderr_str != null && stderr_str.length > 0) {
                        GLib.warning("  ✗ html2rss stderr: %s", stderr_str);
                    }
                    return false;
                }
            } catch (Error e) {
                GLib.warning("  ✗ Error regenerating feed for %s: %s", source.name, e.message);
                return false;
            }
        }
        
        // Handle HTTP/HTTPS URLs
        try {
            var msg = new Soup.Message("GET", source.url);
            msg.get_request_headers().append("User-Agent", "paperboy/0.5.1a");
            msg.get_request_headers().append("Accept", "application/rss+xml, application/atom+xml, application/xml, text/xml");
            
            GLib.Bytes? response = window.session.send_and_read(msg, null);
            var status = msg.get_status();
            
            if (status == Soup.Status.OK && response != null) {
                string body = (string) response.get_data();
                
                // Validate RSS
                string? error = null;
                if (RssValidator.is_valid_rss(body, out error)) {
                    int item_count = RssValidator.get_item_count(body);
                    
                    // Update last_fetched_at timestamp
                    var store = Paperboy.RssSourceStore.get_instance();
                    store.update_last_fetched(source.url);
                    
                    GLib.print("  ✓ Updated: %s (%d items)\n", source.name, item_count);
                    return true;
                } else {
                    GLib.warning("  ✗ Invalid RSS for %s: %s", source.name, error);
                    return false;
                }
            } else {
                GLib.warning("  ✗ Failed to fetch %s: HTTP %u", source.name, status);
                return false;
            }
        } catch (Error e) {
            GLib.warning("  ✗ Error updating %s: %s", source.name, e.message);
            return false;
        }
    }
    
    /**
     * Extract a signature from an RSS feed based on item GUIDs/links
     * This is used to determine if feed content has changed
     * @param feed_xml The RSS feed XML content
     * @return A signature string representing the feed's items
     */
    private string extract_feed_signature(string feed_xml) {
        var signature = new StringBuilder();
        
        try {
            Xml.Doc* doc = Xml.Parser.parse_doc(feed_xml);
            if (doc == null) {
                return "";
            }
            
            Xml.Node* root = doc->get_root_element();
            if (root == null) {
                delete doc;
                return "";
            }
            
            // Find all <item> or <entry> elements
            for (Xml.Node* node = root->children; node != null; node = node->next) {
                if (node->type != Xml.ElementType.ELEMENT_NODE) continue;
                
                // Handle RSS <channel> wrapper
                if (node->name == "channel") {
                    for (Xml.Node* item = node->children; item != null; item = item->next) {
                        if (item->type != Xml.ElementType.ELEMENT_NODE) continue;
                        if (item->name == "item") {
                            extract_item_signature(item, signature);
                        }
                    }
                }
                // Handle Atom <entry> elements directly under root
                else if (node->name == "entry") {
                    extract_item_signature(node, signature);
                }
            }
            
            delete doc;
        } catch (Error e) {
            GLib.warning("Error extracting feed signature: %s", e.message);
        }
        
        return signature.str;
    }
    
    /**
     * Extract signature from a single RSS item or Atom entry
     */
    private void extract_item_signature(Xml.Node* item, StringBuilder signature) {
        for (Xml.Node* child = item->children; child != null; child = child->next) {
            if (child->type != Xml.ElementType.ELEMENT_NODE) continue;
            
            // Look for GUID, link, or id elements
            if (child->name == "guid" || child->name == "link" || child->name == "id") {
                string? content = child->get_content();
                if (content != null && content.length > 0) {
                    signature.append(content);
                    signature.append("|");
                }
            }
        }
    }
    
    /**
     * Find the html2rss binary in various possible locations
     * @return Path to html2rss binary or null if not found
     */
    private string? find_html2rss_binary() {
        var candidates = new Gee.ArrayList<string>();
        
        // Installed binary locations
        candidates.add(BuildConstants.RSSFINDER_BINDIR + "/html2rss");
        
        var sys_dirs = GLib.Environment.get_system_data_dirs();
        if (sys_dirs != null && sys_dirs.length > 0) {
            candidates.add(GLib.Path.build_filename(sys_dirs[0], "org.gnome.Paperboy", "tools", "html2rss"));
        }
        
        candidates.add("/app/share/org.gnome.Paperboy/tools/html2rss");
        
        // Development build locations
        candidates.add("tools/html2rss/target/release/html2rss");
        candidates.add("./tools/html2rss/target/release/html2rss");
        candidates.add("../tools/html2rss/target/release/html2rss");
        
        string? cwd = GLib.Environment.get_current_dir();
        if (cwd != null) {
            candidates.add(GLib.Path.build_filename(cwd, "tools", "html2rss", "target", "release", "html2rss"));
        }
        
        string? home_env = GLib.Environment.get_variable("HOME");
        if (home_env != null) {
            string home_candidate = GLib.Path.build_filename(home_env, "paperboy", "tools", "html2rss", "target", "release", "html2rss");
            candidates.add(home_candidate);
        }
        
        // Check each candidate
        foreach (string c in candidates) {
            if (GLib.FileUtils.test(c, GLib.FileTest.EXISTS) && GLib.FileUtils.test(c, GLib.FileTest.IS_EXECUTABLE)) {
                return c;
            }
        }
        
        return null;
    }
    
    /**
     * Force update a specific feed by URL
     * 
     * @param feed_url The URL of the feed to update
     * @return true if successful, false otherwise
     */
    public bool force_update_feed(string feed_url) {
        var store = Paperboy.RssSourceStore.get_instance();
        var source = store.get_source_by_url(feed_url);
        
        if (source == null) {
            GLib.warning("Feed not found: %s", feed_url);
            return false;
        }
        
        return update_single_feed(source);
    }
}
