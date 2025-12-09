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

public class UnreadFetchService {

    // Weak reference to window for safe lifecycle management.
    // DO NOT use FetchContext here - it would cancel the main content fetch!
    private static weak NewsWindow? _unread_window = null;

    private static void global_metadata_add(string title, string url, string? thumbnail_url, string category_id, string? source_name) {
        try {
            var win = _unread_window;
            if (win == null) return;

            // Safely access article_state_store through local variable
            var store = win.article_state_store;
            if (store == null) return;

            string normalized = win.normalize_article_url(url);
            store.register_article(normalized, category_id, source_name);

            // Also register under myfeed for RSS sources if enabled
            if (category_id != null && category_id.has_prefix("rssfeed:")) {
                string rss_url = category_id.substring("rssfeed:".length);
                try {
                    var prefs = win.prefs;
                    if (prefs != null && prefs.preferred_source_enabled("custom:" + rss_url)) {
                        store.register_article(normalized, "myfeed", source_name);
                    }
                } catch (GLib.Error e) { }
            }
        } catch (GLib.Error e) { }
    }

    // Fetch article metadata for all *regular* categories and RSS sources in background
    // to populate unread counts. Special categories like myfeed, local_news, and saved
    // are handled separately and must not be treated as normal fetchable categories here.
    public static void fetch_all_category_metadata_for_counts(NewsWindow win) {
        if (win == null) return;

        // Store weak reference to window for callbacks.
        // DO NOT use FetchContext.begin_new() here - it would cancel the main content fetch!
        _unread_window = win;

        // Regular news API categories plus Paperboy-provided frontpage/topten.
        string[] categories = {"frontpage", "topten",
                              "general", "us", "sports", "science", "health", "technology",
                              "business", "entertainment", "politics", "lifestyle", "markets", "industries",
                              "green", "wealth", "economics"};

        // Fetch metadata in background (counts will be available when user visits category)
        foreach (string cat in categories) {
            NewsService.fetch(
                win.effective_news_source(),
                cat,
                "",  // no search query
                win.session,
                (s) => {},  // no label updates
                () => {},   // no clear
                UnreadFetchService.global_metadata_add  // global forwarder
            );
        }

        // Fetch local_news articles from user's configured local feeds file
        try {
            string config_dir = GLib.Environment.get_user_config_dir() + "/paperboy";
            string file_path = config_dir + "/local_feeds";
            if (GLib.FileUtils.test(file_path, GLib.FileTest.EXISTS)) {
                string contents = "";
                try { GLib.FileUtils.get_contents(file_path, out contents); } catch (GLib.Error e) { contents = ""; }
                if (contents != null && contents.strip().length > 0) {
                    string[] lines = contents.split("\n");
                    foreach (string line in lines) {
                        string u = line.strip();
                        if (u.length == 0) continue;
                        RssParser.fetch_rss_url(
                            u,
                            "Local Feed",
                            "Local News",
                            "local_news",
                            "",  // no search query
                            win.session,
                            (s) => {},  // no label updates
                            () => {},   // no clear
                            UnreadFetchService.global_metadata_add
                        );
                    }
                }
            }
        } catch (GLib.Error e) { }

        // Fetch metadata for ALL custom RSS sources
        // This ensures the "RSS Feeds" expander badges are populated
        try {
            var rss_store = Paperboy.RssSourceStore.get_instance();
            var all_sources = rss_store.get_all_sources();

            if (all_sources.size > 0) {
                foreach (var rss_src in all_sources) {
                    string rss_category_id = "rssfeed:" + rss_src.url;
                    RssParser.fetch_rss_url(
                        rss_src.url,
                        rss_src.name,
                        rss_src.name,  // category_name = source name
                        rss_category_id,
                        "",  // no search query
                        win.session,
                        (s) => {},  // no label updates
                        () => {},   // no clear
                        UnreadFetchService.global_metadata_add
                    );
                }
            }
        } catch (GLib.Error e) { }

        // Save after fetching all metadata and refresh badges
        Timeout.add(5000, () => {
            try {
                var w = _unread_window;
                if (w == null) return false;

                // Safely access managers through local variables
                var store = w.article_state_store;
                if (store != null) {
                    store.mark_initial_fetch_complete();
                    store.save_article_tracking_to_disk();
                }

                var sidebar_mgr = w.sidebar_manager;
                if (sidebar_mgr != null) {
                    // Refresh all badges so regular categories and frontpage/topten
                    // reflect their initial metadata, and Saved reflects the
                    // registered saved-article set from ArticleStateStore.
                    sidebar_mgr.refresh_all_badge_counts();
                }
            } catch (GLib.Error e) { }
            return false;
        });
    }
}
