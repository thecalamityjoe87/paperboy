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
        // Handle file:// URLs (locally generated feeds)
        if (source.url.has_prefix("file://")) {
            string file_path = source.url.substring(7); // Remove "file://" prefix
            try {
                var file = GLib.File.new_for_path(file_path);
                if (!file.query_exists()) {
                    GLib.warning("  ✗ Local file not found: %s", source.name);
                    return false;
                }
                
                // Read the local XML file
                uint8[] contents;
                file.load_contents(null, out contents, null);
                string xml_content = (string) contents;
                
                // Validate the local RSS file
                string? error = null;
                if (RssValidator.is_valid_rss(xml_content, out error)) {
                    int item_count = RssValidator.get_item_count(xml_content);
                    
                    // Update last_fetched_at timestamp
                    var store = Paperboy.RssSourceStore.get_instance();
                    store.update_last_fetched(source.url);
                    
                    GLib.print("  ✓ Validated local file: %s (%d items)\n", source.name, item_count);
                    return true;
                } else {
                    GLib.warning("  ✗ Invalid local RSS for %s: %s", source.name, error);
                    return false;
                }
            } catch (Error e) {
                GLib.warning("  ✗ Error reading local file %s: %s", source.name, e.message);
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
