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
 * ArticleStateStore: manages only simple per-article metadata (viewed/favorite/timestamps)
 * No pixbufs, textures, widgets, or image URLs. Minimal, thread-safe helpers.
 */

public class ArticleStateStore : GLib.Object {
    // Emitted when saved articles have been loaded from disk
    public signal void saved_articles_loaded();
    // Emitted when a single article is saved or unsaved at runtime
    public signal void saved_article_added(string url);
    public signal void saved_article_removed(string url);
    // Emitted when an article's viewed/unviewed status changes at runtime
    public signal void viewed_status_changed(string url, bool viewed);
    private string cache_dir_path;
    private string cache_dir;
    private Gee.HashSet<string> viewed_meta_paths;
    private Mutex meta_lock = new Mutex();

    // Track articles by category and source for unread count
    private Gee.HashMap<string, Gee.HashSet<string>> category_articles;  // category_id -> set of URLs
    private Gee.HashMap<string, Gee.HashSet<string>> source_articles;    // source_name -> set of URLs
    // Track last registration time (ms since epoch) per source to help debounce badge updates
    private Gee.HashMap<string, long?> source_last_registration_time;
    private Mutex article_tracking_lock = new Mutex();
    
    // Track whether initial background metadata fetch has completed
    private bool initial_metadata_fetch_complete = false;

    // Track saved articles with metadata
    private Gee.HashMap<string, SavedArticle> saved_articles;  // URL -> SavedArticle
    private Mutex saved_lock = new Mutex();

    public class SavedArticle {
        public string url;
        public string title;
        public string? thumbnail;
        public string? source;
        public int64 saved_timestamp;

        public SavedArticle(string url, string title, string? thumbnail, string? source) {
            this.url = url;
            this.title = title;
            this.thumbnail = thumbnail;
            this.source = source;
            this.saved_timestamp = GLib.get_real_time() / 1000000; // Unix timestamp
        }
    }

    public ArticleStateStore() {
        GLib.Object();
        var cache_base = Environment.get_user_cache_dir();
        if (cache_base == null) cache_base = "/tmp";
        cache_dir_path = Path.build_filename(cache_base, "paperboy", "metadata");
        try { DirUtils.create_with_parents(cache_dir_path, 0755); } catch (GLib.Error e) { }
        cache_dir = cache_dir_path;
        viewed_meta_paths = new Gee.HashSet<string>();
        category_articles = new Gee.HashMap<string, Gee.HashSet<string>>();
        source_articles = new Gee.HashMap<string, Gee.HashSet<string>>();
        source_last_registration_time = new Gee.HashMap<string, long?>();
        saved_articles = new Gee.HashMap<string, SavedArticle>();

        // Don't load persisted article tracking on startup
        // The background metadata fetch will populate fresh counts
        // We only use persistence to save counts when app closes
        // load_article_tracking();

        // Load saved articles asynchronously to avoid blocking startup
        Timeout.add(100, () => {
            load_saved_articles();
            return false;
        });

        // Ensure saved articles also participate in category-based tracking so
        // the "saved" category has a stable backing set for unread counts and
        // badge logic on startup.
        try {
            var current_saved = get_saved_articles();
            foreach (var article in current_saved) {
                if (article != null && article.url != null && article.url.length > 0) {
                    try {
                        string norm_url = UrlUtils.normalize_article_url(article.url);
                        if (norm_url == null || norm_url.length == 0) norm_url = article.url.strip();
                        register_article(norm_url, "saved", article.source);
                    } catch (GLib.Error e) {
                        // Best-effort; skip problematic entries
                    }
                }
            }
        } catch (GLib.Error e) { }

        // preload small metadata set: scan .meta files for viewed flag
        try {
            var meta_dir = File.new_for_path(cache_dir_path);
            FileEnumerator? en = null;
            try {
                en = meta_dir.enumerate_children("standard::name", FileQueryInfoFlags.NONE, null);
                FileInfo? info;
                while ((info = en.next_file(null)) != null) {
                    if (info.get_file_type() != FileType.REGULAR) continue;
                    string name = info.get_name();
                    if (!name.has_suffix(".meta")) continue;
                    string full = Path.build_filename(cache_dir_path, name);
                    var kf = read_meta_from_path(full);
                    if (kf != null) {
                        try {
                            string v = kf.get_string("meta", "viewed");
                            if (v == "1" || v.down() == "true") meta_lock_add_viewed(full);
                        } catch (GLib.Error e) { }
                    }
                }
            } catch (GLib.Error e) { } finally { if (en != null) try { en.close(null); } catch (GLib.Error _) { } }
        } catch (GLib.Error e) { }
    }

    private string filename_for_url(string url) {
        string u = url;
        if (u.length > 200) u = u.substring(u.length - 200);
        try {
            var re = new Regex("[^A-Za-z0-9._-]", RegexCompileFlags.DEFAULT);
            return re.replace(u, -1, 0, "_");
        } catch (GLib.RegexError e) {
            string out = "";
            for (uint i = 0; i < (uint)u.length; i++) {
                char c = u[i];
                if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-')
                    out += "%c".printf((int)c);
                else
                    out += "_";
            }
            return out;
        }
    }

    private string meta_path_for(string url) {
        string name = filename_for_url(url) + ".meta";
        return Path.build_filename(cache_dir_path, name);
    }

    private KeyFile? read_meta_from_path(string meta_path) {
        if (!FileUtils.test(meta_path, FileTest.EXISTS)) return null;
        try {
            var kf = new KeyFile();
            kf.load_from_file(meta_path, KeyFileFlags.NONE);
            return kf;
        } catch (GLib.Error e) {
            try { FileUtils.remove(meta_path); } catch (GLib.Error _) { }
            return null;
        }
    }

    private void write_meta_for_url(string url, KeyFile kf) {
        string meta = meta_path_for(url);
        try { kf.save_to_file(meta); } catch (GLib.Error e) { }
    }

    private void meta_lock_add_viewed(string meta_path) {
        meta_lock.lock();
        try { viewed_meta_paths.add(meta_path); } finally { meta_lock.unlock(); }
    }

    private void meta_lock_remove_viewed(string meta_path) {
        meta_lock.lock();
        try { viewed_meta_paths.remove(meta_path); } finally { meta_lock.unlock(); }
    }

    private bool meta_lock_has_viewed(string meta_path) {
        meta_lock.lock();
        try { return viewed_meta_paths.contains(meta_path); } finally { meta_lock.unlock(); }
    }

    // Public API
    public void mark_viewed(string url) {
        string meta_path = meta_path_for(url);
        if (meta_lock_has_viewed(meta_path)) return;
        try {
            var kf = read_meta_from_path(meta_path);
            if (kf == null) kf = new KeyFile();
            long now_s = (long)(GLib.get_real_time() / 1000000);
            kf.set_string("meta", "viewed", "1");
            kf.set_string("meta", "viewed_at", "%d".printf((int)now_s));
            write_meta_for_url(url, kf);
            meta_lock_add_viewed(meta_path);
            try {
                string norm = url;
                try { norm = UrlUtils.normalize_article_url(url); } catch (GLib.Error e) { norm = url.strip(); }
                try { viewed_status_changed(norm, true); } catch (GLib.Error e) { }
            } catch (GLib.Error e) { }
        } catch (GLib.Error e) { }
    }

    public void mark_unviewed(string url) {
        string meta_path = meta_path_for(url);
        meta_lock_remove_viewed(meta_path);
        try {
            var kf = read_meta_from_path(meta_path);
            if (kf == null) return;
            kf.set_string("meta", "viewed", "0");
            kf.remove_key("meta", "viewed_at");
            write_meta_for_url(url, kf);
            try {
                string norm = url;
                try { norm = UrlUtils.normalize_article_url(url); } catch (GLib.Error e) { norm = url.strip(); }
                try { viewed_status_changed(norm, false); } catch (GLib.Error e) { }
            } catch (GLib.Error e) { }
        } catch (GLib.Error e) { }
    }

    public bool is_viewed(string url) {
        string meta = meta_path_for(url);
        bool has_it = meta_lock_has_viewed(meta);
        if (has_it) return true;
        // best-effort synchronous check for small set
        var kf = read_meta_from_path(meta);
        if (kf != null) {
            try { string v = kf.get_string("meta", "viewed"); if (v == "1" || v.down() == "true") { meta_lock_add_viewed(meta); return true; } } catch (GLib.Error e) { }
        }
        return false;
    }

    public bool is_favorite(string url) {
        var kf = read_meta_from_path(meta_path_for(url));
        if (kf == null) return false;
        try { string v = kf.get_string("meta", "favorite"); return (v == "1" || v.down() == "true"); } catch (GLib.Error e) { return false; }
    }

    public void set_favorite(string url, bool fav) {
        try {
            var kf = read_meta_from_path(meta_path_for(url));
            if (kf == null) kf = new KeyFile();
            kf.set_string("meta", "favorite", fav ? "1" : "0");
            write_meta_for_url(url, kf);
        } catch (GLib.Error e) { }
    }

    public void load_state() {
        // noop: constructor already preloaded viewed flags; expose for future use
    }

    public void save_state() {
        // noop: writes are atomic per-item via mark_viewed/set_favorite
    }

    // Clear all articles for a specific category (used before re-fetching to avoid accumulation)
    public void clear_category_articles(string category_id) {
        article_tracking_lock.lock();
        try {
            if (category_articles.has_key(category_id)) {
                category_articles.get(category_id).clear();
            }
        } finally {
            article_tracking_lock.unlock();
        }
    }

    // Register an article with its category and source for unread tracking
    public void register_article(string url, string? category_id, string? source_name) {
        // Normalize the URL OUTSIDE the lock to reduce lock contention
        // when many threads are calling this simultaneously
        string norm_url = "";
        try {
            norm_url = UrlUtils.normalize_article_url(url);
        } catch (GLib.Error e) { norm_url = url.strip(); }

        article_tracking_lock.lock();
        try {

            if (category_id != null && category_id.length > 0) {
                if (!category_articles.has_key(category_id)) {
                    category_articles.set(category_id, new Gee.HashSet<string>());
                }
                category_articles.get(category_id).add(norm_url);
            }
            if (source_name != null && source_name.length > 0) {
                if (!source_articles.has_key(source_name)) {
                    source_articles.set(source_name, new Gee.HashSet<string>());
                }
                source_articles.get(source_name).add(norm_url);

                try {
                    long now_ms = (long)(GLib.get_real_time() / 1000);
                    source_last_registration_time.set(source_name, now_ms);
                } catch (GLib.Error e) { }
            }
        } finally {
            article_tracking_lock.unlock();
        }
    }

    // Explicitly save article tracking to disk
    public void save_article_tracking_to_disk() {
        save_article_tracking();
    }

    // Mark that initial metadata fetch is complete
    public void mark_initial_fetch_complete() {
        initial_metadata_fetch_complete = true;
    }

    // Check if initial metadata fetch is complete
    public bool is_initial_fetch_complete() {
        return initial_metadata_fetch_complete;
    }

    // Get total article count for a specific category (all articles, viewed or not)
    public int get_total_count_for_category(string category_id) {
        article_tracking_lock.lock();
        try {
            if (!category_articles.has_key(category_id)) {
                return 0;
            }
            return category_articles.get(category_id).size;
        } finally {
            article_tracking_lock.unlock();
        }
    }

    // Get unread count for a specific category
    public int get_unread_count_for_category(string category_id) {
        int total = 0;
        int viewed = 0;

        article_tracking_lock.lock();
        try {
            if (!category_articles.has_key(category_id)) {
                return 0;
            }

            var articles = category_articles.get(category_id);
            total = articles.size;

            // PERFORMANCE: Only check viewed status from in-memory cache
            // Don't do disk I/O during count calculation - that's too slow
            meta_lock.lock();
            try {
                foreach (string url in articles) {
                    string meta_path = meta_path_for(url);
                    if (viewed_meta_paths.contains(meta_path)) {
                        viewed++;
                    }
                }
            } finally {
                meta_lock.unlock();
            }
        } finally {
            article_tracking_lock.unlock();
        }

        return total - viewed;
    }

    // Get unread count for "myfeed" category, filtering by enabled sources only
    public int get_unread_count_for_myfeed(NewsPreferences prefs) {
        int total = 0;
        int viewed = 0;
        int enabled_count = 0;
        int disabled_count = 0;

        article_tracking_lock.lock();
        try {
            if (!category_articles.has_key("myfeed")) {
                return 0;
            }

            var articles = category_articles.get("myfeed");

            // Get personalized categories for built-in source filtering
            var personalized_cats = prefs.personalized_categories;

            // PERFORMANCE: Only check viewed status from in-memory cache
            meta_lock.lock();
            try {
                foreach (string url in articles) {
                    // Check if this article belongs to any enabled source
                    // This includes both custom RSS feeds and built-in sources
                    bool has_enabled_source = false;

                    foreach (var entry in category_articles.entries) {
                        string category_id = entry.key;

                        // Check if this is an RSS feed category
                        if (category_id.has_prefix("rssfeed:")) {
                            var category_urls = entry.value;

                            // Check if this article is in this RSS feed category
                            if (category_urls.contains(url)) {
                                // Extract the RSS URL from the category ID
                                string rss_url = category_id.substring("rssfeed:".length);
                                string check_key = "custom:" + rss_url;

                                // Check if this RSS feed is enabled in preferences
                                if (prefs.preferred_source_enabled(check_key)) {
                                    has_enabled_source = true;
                                    break;  // Found at least one enabled source, no need to check more
                                }
                            }
                        }
                    }

                    // If not found in RSS feed categories, check built-in sources
                    // But only if "custom only" mode is disabled
                    if (!has_enabled_source && !prefs.myfeed_custom_only) {
                        // Check which built-in source(s) this article belongs to
                        foreach (var source_entry in source_articles.entries) {
                            string source_name = source_entry.key;
                            var source_urls = source_entry.value;

                            // Skip rssfeed sources (already checked above)
                            if (source_name.has_prefix("rssfeed:")) continue;

                            // Check if this article belongs to this built-in source
                            if (source_urls.contains(url)) {
                                // Check if this built-in source is enabled
                                if (prefs.preferred_source_enabled(source_name)) {
                                    has_enabled_source = true;
                                    break;
                                }
                            }
                        }
                    }

                    // Only count articles that have at least one enabled source
                    if (!has_enabled_source) {
                        disabled_count++;
                        continue;
                    }

                    enabled_count++;
                    total++;
                    string meta_path = meta_path_for(url);
                    if (viewed_meta_paths.contains(meta_path)) {
                        viewed++;
                    }
                }
            } finally {
                meta_lock.unlock();
            }
        } finally {
            article_tracking_lock.unlock();
        }

        return total - viewed;
    }

    // Get unread count for a specific source
    public int get_unread_count_for_source(string source_name) {
        int total = 0;
        int viewed = 0;

        article_tracking_lock.lock();
        try {
            if (!source_articles.has_key(source_name)) {
                return 0;
            }

            var articles = source_articles.get(source_name);
            total = articles.size;

            // PERFORMANCE: Only check viewed status from in-memory cache
            // Don't do disk I/O during count calculation - that's too slow
            meta_lock.lock();
            try {
                foreach (string url in articles) {
                    string meta_path = meta_path_for(url);
                    if (viewed_meta_paths.contains(meta_path)) {
                        viewed++;
                    }
                }
            } finally {
                meta_lock.unlock();
            }
        } finally {
            article_tracking_lock.unlock();
        }

        return total - viewed;
    }

    // Get all article URLs for a specific source
    public Gee.HashSet<string>? get_articles_for_source(string source_name) {
        article_tracking_lock.lock();
        try {
            if (!source_articles.has_key(source_name)) {
                return null;
            }
            // Return a copy to avoid concurrent modification
            var copy = new Gee.HashSet<string>();
            var articles = source_articles.get(source_name);
            foreach (string url in articles) {
                copy.add(url);
            }
            return copy;
        } finally {
            article_tracking_lock.unlock();
        }
    }

    // Get all article URLs for a specific category
    public Gee.HashSet<string>? get_articles_for_category(string category_id) {
        article_tracking_lock.lock();
        try {
            if (!category_articles.has_key(category_id)) {
                return null;
            }
            var copy = new Gee.HashSet<string>();
            var articles = category_articles.get(category_id);
            foreach (string url in articles) {
                copy.add(url);
            }
            return copy;
        } finally {
            article_tracking_lock.unlock();
        }
    }

    // Get list of category IDs that a specific URL belongs to
    public Gee.ArrayList<string> get_categories_for_url(string url) {
        var out = new Gee.ArrayList<string>();
        string norm = url;
        try { norm = UrlUtils.normalize_article_url(url); } catch (GLib.Error e) { norm = url.strip(); }
        article_tracking_lock.lock();
        try {
            foreach (var entry in category_articles.entries) {
                try {
                    var set = entry.value;
                    if (set.contains(norm)) out.add(entry.key);
                } catch (GLib.Error e) { }
            }
        } finally {
            article_tracking_lock.unlock();
        }
        return out;
    }

    // Get list of source names that a specific URL belongs to
    public Gee.ArrayList<string> get_sources_for_url(string url) {
        var out = new Gee.ArrayList<string>();
        string norm = url;
        try { norm = UrlUtils.normalize_article_url(url); } catch (GLib.Error e) { norm = url.strip(); }
        article_tracking_lock.lock();
        try {
            foreach (var entry in source_articles.entries) {
                try {
                    var set = entry.value;
                    if (set.contains(norm)) out.add(entry.key);
                } catch (GLib.Error e) { }
            }
        } finally {
            article_tracking_lock.unlock();
        }
        return out;
    }

    // Clear all article tracking (useful when refreshing/reloading)
    // Preserves the "saved" category since saved articles are persistent user data
    public void clear_article_tracking() {
        article_tracking_lock.lock();
        try {
            // Preserve saved articles tracking
            Gee.HashSet<string>? saved_set = null;
            if (category_articles.has_key("saved")) {
                saved_set = category_articles.get("saved");
            }
            
            category_articles.clear();
            source_articles.clear();
            
            // Restore saved articles tracking
            if (saved_set != null) {
                category_articles.set("saved", saved_set);
            }
        } finally {
            article_tracking_lock.unlock();
        }
        // DISABLED: No longer persisting article tracking
        // save_article_tracking();
    }

    // Clear article tracking for a specific source (useful when refreshing an RSS feed)
    public void clear_article_tracking_for_source(string source_name) {
        article_tracking_lock.lock();
        try {
            if (source_articles.has_key(source_name)) {
                source_articles.unset(source_name);
            }
        } finally {
            article_tracking_lock.unlock();
        }
        // DISABLED: No longer persisting article tracking
        // save_article_tracking();
    }

    // Clear article tracking for a specific category (useful when refreshing a category feed)
    public void clear_article_tracking_for_category(string category_id) {
        article_tracking_lock.lock();
        try {
            if (category_articles.has_key(category_id)) {
                category_articles.unset(category_id);
            }
        } finally {
            article_tracking_lock.unlock();
        }
        // DISABLED: No longer persisting article tracking
        // save_article_tracking();
    }

    // Save article tracking to disk
    private void save_article_tracking() {
        string tracking_file = Path.build_filename(cache_dir_path, "article_tracking.json");
        article_tracking_lock.lock();
        try {
            var builder = new Json.Builder();
            builder.begin_object();

            // Save category articles (write canonical normalized URLs)
            builder.set_member_name("categories");
            builder.begin_object();
            foreach (var entry in category_articles.entries) {
                builder.set_member_name(entry.key);
                builder.begin_array();
                foreach (string url in entry.value) {
                    try {
                        string norm = UrlUtils.normalize_article_url(url);
                        if (norm == null || norm.length == 0) norm = url.strip();
                        builder.add_string_value(norm);
                    } catch (GLib.Error e) {
                        builder.add_string_value(url);
                    }
                }
                builder.end_array();
            }
            builder.end_object();

            // Save source articles (write canonical normalized URLs)
            builder.set_member_name("sources");
            builder.begin_object();
            foreach (var entry in source_articles.entries) {
                builder.set_member_name(entry.key);
                builder.begin_array();
                foreach (string url in entry.value) {
                    try {
                        string norm = UrlUtils.normalize_article_url(url);
                        if (norm == null || norm.length == 0) norm = url.strip();
                        builder.add_string_value(norm);
                    } catch (GLib.Error e) {
                        builder.add_string_value(url);
                    }
                }
                builder.end_array();
            }
            builder.end_object();

            builder.end_object();

            var generator = new Json.Generator();
            generator.set_root(builder.get_root());
            generator.to_file(tracking_file);
        } catch (GLib.Error e) {
            stderr.printf("Failed to save article tracking: %s\n", e.message);
        } finally {
            article_tracking_lock.unlock();
        }
    }

    // Load article tracking from disk
    private void load_article_tracking() {
        string tracking_file = Path.build_filename(cache_dir_path, "article_tracking.json");
        if (!FileUtils.test(tracking_file, FileTest.EXISTS)) {
            return;
        }

        try {
            var parser = new Json.Parser();
            parser.load_from_file(tracking_file);
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) {
                return;
            }

            var obj = root.get_object();

            // Load category articles (normalize loaded URLs to canonical form)
            if (obj.has_member("categories")) {
                var categories_obj = obj.get_object_member("categories");
                foreach (string category_id in categories_obj.get_members()) {
                    var urls_array = categories_obj.get_array_member(category_id);
                    var url_set = new Gee.HashSet<string>();
                    urls_array.foreach_element((arr, index, node) => {
                        try {
                            string raw = node.get_string();
                            string norm = UrlUtils.normalize_article_url(raw);
                            if (norm == null || norm.length == 0) norm = raw.strip();
                            url_set.add(norm);
                        } catch (GLib.Error e) {
                            try { url_set.add(node.get_string()); } catch (GLib.Error _) { }
                        }
                    });
                    category_articles.set(category_id, url_set);
                }
            }

            // Load source articles (normalize loaded URLs to canonical form)
            if (obj.has_member("sources")) {
                var sources_obj = obj.get_object_member("sources");
                foreach (string source_name in sources_obj.get_members()) {
                    var urls_array = sources_obj.get_array_member(source_name);
                    var url_set = new Gee.HashSet<string>();
                    urls_array.foreach_element((arr, index, node) => {
                        try {
                            string raw = node.get_string();
                            string norm = UrlUtils.normalize_article_url(raw);
                            if (norm == null || norm.length == 0) norm = raw.strip();
                            url_set.add(norm);
                        } catch (GLib.Error e) {
                            try { url_set.add(node.get_string()); } catch (GLib.Error _) { }
                        }
                    });
                    source_articles.set(source_name, url_set);
                }
            }
        } catch (GLib.Error e) {
            stderr.printf("Failed to load article tracking: %s\n", e.message);
        }
    }

    // Saved articles management
    public void save_article(string url, string title, string? thumbnail = null, string? source = null) {
        // Persist saved metadata and ensure the article is registered under the
        // "saved" category for unread-count tracking.
        saved_lock.lock();
        try {
            var article = new SavedArticle(url, title, thumbnail, source);
            saved_articles.set(url, article);
            persist_saved_articles();
        } finally {
            saved_lock.unlock();
        }

        // Register the saved article for category-based unread tracking. Do
        // this outside of the saved_lock to avoid lock ordering issues.
        try {
            string norm = UrlUtils.normalize_article_url(url);
            if (norm == null || norm.length == 0) norm = url.strip();
            register_article(norm, "saved", source);
            try { saved_article_added(url); } catch (GLib.Error e) { }
        } catch (GLib.Error e) { }
    }

    public void unsave_article(string url) {
        // Remove from saved list and from the "saved" category tracking so
        // unread counts update correctly.
        saved_lock.lock();
        try {
            // Attempt direct remove first
            if (saved_articles.has_key(url)) {
                saved_articles.unset(url);
            } else {
                // Fallback: remove any entry whose canonical normalized URL
                // matches the requested URL's normalized form. This covers
                // situations where saved entries were stored with a slightly
                // different URL form (scheme missing, trailing slash, etc.).
                string norm = url;
                try { norm = UrlUtils.normalize_article_url(url); } catch (GLib.Error e) { norm = url.strip(); }
                var keys_to_remove = new Gee.ArrayList<string>();
                foreach (var k in saved_articles.keys) {
                    try {
                        string kn = UrlUtils.normalize_article_url(k);
                        if (kn == norm) keys_to_remove.add(k);
                    } catch (GLib.Error e) {
                        if (k == url) keys_to_remove.add(k);
                    }
                }
                foreach (var k in keys_to_remove) {
                    try { saved_articles.unset(k); } catch (GLib.Error e) { }
                }
            }
            persist_saved_articles();
        } finally {
            saved_lock.unlock();
        }

        // Also remove from category tracking
        try {
            string norm = UrlUtils.normalize_article_url(url);
            if (norm == null || norm.length == 0) norm = url.strip();
            article_tracking_lock.lock();
            try {
                if (category_articles.has_key("saved")) {
                    var s = category_articles.get("saved");
                    if (s != null) s.remove(norm);
                }
            } finally {
                article_tracking_lock.unlock();
            }
            try { saved_article_removed(url); } catch (GLib.Error e) { }
        } catch (GLib.Error e) { }
    }

    public bool is_saved(string url) {
        saved_lock.lock();
        try {
            if (saved_articles.has_key(url)) return true;
            // Check normalized match
            string norm = url;
            try { norm = UrlUtils.normalize_article_url(url); } catch (GLib.Error e) { norm = url.strip(); }
            foreach (var k in saved_articles.keys) {
                try {
                    string kn = UrlUtils.normalize_article_url(k);
                    if (kn == norm) return true;
                } catch (GLib.Error e) {
                    if (k == url) return true;
                }
            }
            return false;
        } finally {
            saved_lock.unlock();
        }
    }

    public Gee.ArrayList<SavedArticle?> get_saved_articles() {
        saved_lock.lock();
        try {
            var list = new Gee.ArrayList<SavedArticle?>();
            foreach (var article in saved_articles.values) {
                list.add(article);
            }
            // Sort by saved timestamp, newest first
            list.sort((a, b) => {
                return (int)(b.saved_timestamp - a.saved_timestamp);
            });
            return list;
        } finally {
            saved_lock.unlock();
        }
    }

    public SavedArticle? get_saved_article(string url) {
        saved_lock.lock();
        try {
            if (saved_articles.has_key(url)) return saved_articles.get(url);
            // Try normalized lookup
            string norm = url;
            try { norm = UrlUtils.normalize_article_url(url); } catch (GLib.Error e) { norm = url.strip(); }
            foreach (var k in saved_articles.keys) {
                try {
                    string kn = UrlUtils.normalize_article_url(k);
                    if (kn == norm) return saved_articles.get(k);
                } catch (GLib.Error e) {
                    if (k == url) return saved_articles.get(k);
                }
            }
            return null;
        } finally {
            saved_lock.unlock();
        }
    }

    public int get_saved_count() {
        saved_lock.lock();
        try {
            return saved_articles.size;
        } finally {
            saved_lock.unlock();
        }
    }

    // Return count of saved articles that are not yet viewed
    public int get_unread_saved_count() {
        int cnt = 0;
        saved_lock.lock();
        try {
            foreach (var article in saved_articles.values) {
                try {
                    string norm = UrlUtils.normalize_article_url(article.url);
                    if (norm == null || norm.length == 0) norm = article.url.strip();
                    if (!is_viewed(norm)) cnt++;
                } catch (GLib.Error e) {
                    // Best-effort: treat as unread if we cannot normalize/check
                    cnt++;
                }
            }
        } finally {
            saved_lock.unlock();
        }
        return cnt;
    }

    private void persist_saved_articles() {
        string saved_file = Path.build_filename(cache_dir_path, "saved_articles.json");
        try {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("saved");
            builder.begin_array();
            foreach (var article in saved_articles.values) {
                builder.begin_object();
                builder.set_member_name("url");
                builder.add_string_value(article.url);
                builder.set_member_name("title");
                builder.add_string_value(article.title);
                if (article.thumbnail != null) {
                    builder.set_member_name("thumbnail");
                    builder.add_string_value(article.thumbnail);
                }
                if (article.source != null) {
                    builder.set_member_name("source");
                    builder.add_string_value(article.source);
                }
                builder.set_member_name("saved_timestamp");
                builder.add_int_value(article.saved_timestamp);
                builder.end_object();
            }
            builder.end_array();
            builder.end_object();

            var generator = new Json.Generator();
            generator.set_root(builder.get_root());
            generator.set_pretty(true);
            generator.to_file(saved_file);
        } catch (GLib.Error e) {
            stderr.printf("Failed to save saved articles: %s\n", e.message);
        }
    }

    private void load_saved_articles() {
        string saved_file = Path.build_filename(cache_dir_path, "saved_articles.json");
        if (!FileUtils.test(saved_file, FileTest.EXISTS)) {
            return;
        }

        try {
            var parser = new Json.Parser();
            parser.load_from_file(saved_file);
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) {
                return;
            }

            var obj = root.get_object();
            if (obj.has_member("saved")) {
                var saved_array = obj.get_array_member("saved");
                saved_array.foreach_element((arr, index, node) => {
                if (node.get_node_type() == Json.NodeType.OBJECT) {
                    var article_obj = node.get_object();
                    string url = article_obj.get_string_member("url");
                    string title = article_obj.get_string_member("title");
                    string? thumbnail = article_obj.has_member("thumbnail") ? article_obj.get_string_member("thumbnail") : null;
                    string? source = article_obj.has_member("source") ? article_obj.get_string_member("source") : null;

                    var article = new SavedArticle(url, title, thumbnail, source);
                    if (article_obj.has_member("saved_timestamp")) {
                        article.saved_timestamp = article_obj.get_int_member("saved_timestamp");
                    }
                    saved_articles.set(url, article);
                }
            });

            // Register loaded saved articles into category tracking so the
            // sidebar can immediately show the correct "Saved" badge count.
            try {
                foreach (var article in saved_articles.values) {
                    try {
                        string norm = UrlUtils.normalize_article_url(article.url);
                        if (norm == null || norm.length == 0) norm = article.url.strip();
                        register_article(norm, "saved", article.source);
                    } catch (GLib.Error e) { }
                }
            } catch (GLib.Error e) { }

            // Notify listeners (UI) that saved articles are now available
            try { saved_articles_loaded(); } catch (GLib.Error e) { }
            }
        } catch (GLib.Error e) {
            stderr.printf("Failed to load saved articles: %s\n", e.message);
        }
    }
}
