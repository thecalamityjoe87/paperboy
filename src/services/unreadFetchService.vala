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

    // Separate session with shorter timeout for background metadata fetches
    // This ensures background fetches fail fast and don't block the UI
    private static Soup.Session? _metadata_session = null;

    // Fetch queue and throttling
    // NOTE: Static Gee collections must be initialized lazily in Vala
    private static Gee.Queue<FetchTask>? _fetch_queue = null;
    private static int _active_fetches = 0;
    private const int MAX_CONCURRENT_FETCHES = 3;  // Limit concurrent fetches to prevent resource contention

    // Task types for the fetch queue
    private enum TaskType {
        CATEGORY,
        RSS_FEED,
        LOCAL_FEED
    }

    private class FetchTask {
        public TaskType type;
        public string? category;
        public NewsSource? source;
        public string? rss_url;
        public string? rss_name;
        public string? category_id;

        public FetchTask.for_category(string cat, NewsSource src) {
            this.type = TaskType.CATEGORY;
            this.category = cat;
            this.source = src;
        }

        public FetchTask.for_rss(string url, string name, string cat_id) {
            this.type = TaskType.RSS_FEED;
            this.rss_url = url;
            this.rss_name = name;
            this.category_id = cat_id;
        }

        public FetchTask.for_local(string url) {
            this.type = TaskType.LOCAL_FEED;
            this.rss_url = url;
        }
    }

    private static Soup.Session get_metadata_session() {
        if (_metadata_session == null) {
            _metadata_session = new Soup.Session() {
                timeout = 5  // Shorter timeout for background fetches (5 seconds)
            };
        }
        return _metadata_session;
    }

    private static Gee.Queue<FetchTask> get_fetch_queue() {
        if (_fetch_queue == null) {
            _fetch_queue = new Gee.LinkedList<FetchTask>();
        }
        return _fetch_queue;
    }

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

    private static void enqueue_fetch(FetchTask task) {
        get_fetch_queue().offer(task);
        process_fetch_queue();
    }

    private static void process_fetch_queue() {
        var queue = get_fetch_queue();
        while (_active_fetches < MAX_CONCURRENT_FETCHES && !queue.is_empty) {
            var task = queue.poll();
            if (task == null) break;

            _active_fetches++;

            // Debug logging
            try {
                if (GLib.Environment.get_variable("PAPERBOY_DEBUG") != null) {
                    warning("Fetch queue: %d pending, %d active (starting %s)", 
                            get_fetch_queue().size, _active_fetches,
                            task.type == TaskType.CATEGORY ? task.category : 
                            task.type == TaskType.RSS_FEED ? task.rss_name : "local feed");
                }
            } catch (GLib.Error e) { }

            // Execute the fetch based on task type
            var win = _unread_window;
            if (win == null) {
                _active_fetches--;
                continue;
            }

            switch (task.type) {
                case TaskType.CATEGORY:
                    NewsService.fetch(
                        task.source,
                        task.category,
                        "",  // no search query
                        get_metadata_session(),
                        (s) => {},  // no label updates
                        () => {},   // no clear
                        (title, url, thumb, cat_id, src_name) => {
                            global_metadata_add(title, url, thumb, cat_id, src_name);
                        }
                    );
                    // Decrement counter after a short delay to allow fetch to start
                    GLib.Timeout.add(100, () => {
                        _active_fetches--;
                        process_fetch_queue();
                        return false;
                    });
                    break;

                case TaskType.RSS_FEED:
                    RssFeedProcessor.fetch_rss_url(
                        task.rss_url,
                        task.rss_name,
                        task.rss_name,
                        task.category_id,
                        "",  // no search query
                        get_metadata_session(),
                        (s) => {},  // no label updates
                        () => {},   // no clear
                        (title, url, thumb, cat_id, src_name) => {
                            global_metadata_add(title, url, thumb, cat_id, src_name);
                        }
                    );
                    // Decrement counter after a short delay
                    GLib.Timeout.add(100, () => {
                        _active_fetches--;
                        process_fetch_queue();
                        return false;
                    });
                    break;

                case TaskType.LOCAL_FEED:
                    RssFeedProcessor.fetch_rss_url(
                        task.rss_url,
                        "Local Feed",
                        "Local News",
                        "local_news",
                        "",  // no search query
                        get_metadata_session(),
                        (s) => {},  // no label updates
                        () => {},   // no clear
                        (title, url, thumb, cat_id, src_name) => {
                            global_metadata_add(title, url, thumb, cat_id, src_name);
                        }
                    );
                    // Decrement counter after a short delay
                    GLib.Timeout.add(100, () => {
                        _active_fetches--;
                        process_fetch_queue();
                        return false;
                    });
                    break;
            }
        }
    }

    // Fetch article metadata for all *regular* categories and RSS sources in background
    // to populate unread counts. Special categories like myfeed, local_news, and saved
    // are handled separately and must not be treated as normal fetchable categories here.
    public static void fetch_all_category_metadata_for_counts(NewsWindow win) {
        if (win == null) return;

        // Store weak reference to window for callbacks.
        // DO NOT use FetchContext.begin_new() here - it would cancel the main content fetch!
        _unread_window = win;

        // Clear any existing queue
        get_fetch_queue().clear();
        _active_fetches = 0;

        // Priority categories - fetch these first to ensure they load even if RSS feeds timeout
        string[] priority_categories = {"frontpage", "topten"};
        foreach (string cat in priority_categories) {
            enqueue_fetch(new FetchTask.for_category(cat, win.effective_news_source()));
        }

        // Regular news API categories
        string[] regular_categories = {"general", "us", "sports", "science", "health", "technology",
                                       "business", "entertainment", "politics", "lifestyle", "markets", 
                                       "industries", "green", "wealth", "economics"};

        foreach (string cat in regular_categories) {
            enqueue_fetch(new FetchTask.for_category(cat, win.effective_news_source()));
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
                        enqueue_fetch(new FetchTask.for_local(u));
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
                    enqueue_fetch(new FetchTask.for_rss(rss_src.url, rss_src.name, rss_category_id));
                }
            }
        } catch (GLib.Error e) { }

        // Save after fetching all metadata and refresh badges
        // Increased timeout to 10 seconds to allow more time for throttled fetches
        Timeout.add(10000, () => {
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
