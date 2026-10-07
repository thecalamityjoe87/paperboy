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
using Sqlite;

// Manages per-article metadata (viewed/favorite/timestamps) only - no pixbufs, textures,
// widgets, or image URLs.
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
    private GLib.Mutex meta_lock = new GLib.Mutex();

    // SQLite database for saved articles
    private Sqlite.Database? saved_db = null;
    private GLib.Mutex saved_db_lock = new GLib.Mutex();

    // Track articles by category and source for unread count
    private Gee.HashMap<string, Gee.HashSet<string>> category_articles;  // category_id -> set of URLs
    private Gee.HashMap<string, Gee.HashSet<string>> source_articles;    // source_name -> set of URLs
    // City the Local News page is currently showing
    private string? local_news_area = null;
    // Track last registration time (ms since epoch) per source to help debounce badge updates
    private Gee.HashMap<string, long?> source_last_registration_time;
    // Track which categories have been visited by the user (for popular category badge persistence)
    private Gee.HashSet<string> visited_categories;
    // Track which sources have been visited by the user (for source badge persistence)
    private Gee.HashSet<string> visited_sources;
    // URLs that got a card in the last My Feed build, persisted so the badge survives restarts
    private Gee.HashSet<string> myfeed_displayed_urls;
    private GLib.Mutex article_tracking_lock = new GLib.Mutex();

    // Track whether initial background metadata fetch has completed
    private bool initial_metadata_fetch_complete = false;

    // Track saved articles with metadata (cached in memory from database)
    private Gee.HashMap<string, SavedArticle> saved_articles;  // URL -> SavedArticle
    // Normalized URL -> key in saved_articles, so is_saved()/get_saved_article()
    // can match URL variants with one lookup instead of normalizing every key.
    // Guarded by saved_lock, kept in sync via put_saved()/remove_saved().
    private Gee.HashMap<string, string> saved_keys_by_norm;
    private GLib.Mutex saved_lock = new GLib.Mutex();

    // Reading history: SQLite database, capped and time-expired (see trim_history())
    private const int HISTORY_MAX_ENTRIES = 500;
    private const int HISTORY_MAX_AGE_DAYS = 30;
    private Sqlite.Database? history_db = null;
    private GLib.Mutex history_db_lock = new GLib.Mutex();
    private Gee.HashMap<string, HistoryArticle> history_articles;  // URL -> HistoryArticle
    private GLib.Mutex history_lock = new GLib.Mutex();
    // Emitted when history finishes loading from disk, or is cleared/updated at runtime
    public signal void history_loaded();
    public signal void history_changed();

    // Front Page thumbs up/down votes (+1/-1), stored in history.db and cleared along with history.
    private const int FEEDBACK_MAX_ENTRIES = 500;
    private Gee.HashMap<string, ArticleFeedback> article_feedback;
    private GLib.Mutex feedback_lock = new GLib.Mutex();
    // Main thread only, like the thumbs buttons that set it.
    public signal void feedback_changed(string url, int vote);

    // How often each "Recommended for you" story has been shown, keyed by lowercased title. Main thread only.
    private const int IMPRESSION_MAX_AGE_DAYS = 3;
    // Revisits within this window count as the same showing.
    private const int64 IMPRESSION_MIN_GAP_SECS = 30 * 60;
    private Gee.HashMap<string, RecommendationImpression> recommendation_impressions;

    public class ArticleFeedback {
        public string url;
        public string? title;
        public string? source;
        public string? category_id;
        public int vote;
        public int64 timestamp;
    }

    public class RecommendationImpression {
        public string story;
        public int shown;
        public int64 last_shown;
    }

    public class HistoryArticle {
        public string url;
        public string title;
        public string? thumbnail;
        public string? source;
        public int64 viewed_timestamp;
        public string? published;
        public string? category_id;

        public HistoryArticle(string url, string title, string? thumbnail, string? source, string? published = null, string? category_id = null) {
            this.url = url;
            this.title = title;
            this.thumbnail = thumbnail;
            this.source = source;
            this.published = published;
            this.category_id = category_id;
            this.viewed_timestamp = GLib.get_real_time() / 1000000; // Unix timestamp
        }
    }

    public class SavedArticle {
        public string url;
        public string title;
        public string? thumbnail;
        public string? source;
        public int64 saved_timestamp;
        // The original published date from the article's feed/API, so saved cards can show the
        // same "X ago" caption as everywhere else. Null for articles saved before this field existed.
        public string? published;

        public SavedArticle(string url, string title, string? thumbnail, string? source, string? published = null) {
            this.url = url;
            this.title = title;
            this.thumbnail = thumbnail;
            this.source = source;
            this.published = published;
            this.saved_timestamp = GLib.get_real_time() / 1000000; // Unix timestamp
        }
    }

    public ArticleStateStore() {
        GLib.Object();
        var cache_base = Environment.get_user_cache_dir();
        if (cache_base == null) cache_base = "/tmp";
        cache_dir_path = Path.build_filename(cache_base, "paperboy", "metadata");
        DirUtils.create_with_parents(cache_dir_path, 0755); 
        cache_dir = cache_dir_path;
        viewed_meta_paths = new Gee.HashSet<string>();
        category_articles = new Gee.HashMap<string, Gee.HashSet<string>>();
        source_articles = new Gee.HashMap<string, Gee.HashSet<string>>();
        source_last_registration_time = new Gee.HashMap<string, long?>();
        visited_categories = new Gee.HashSet<string>();
        visited_sources = new Gee.HashSet<string>();
        myfeed_displayed_urls = new Gee.HashSet<string>();
        saved_articles = new Gee.HashMap<string, SavedArticle>();
        saved_keys_by_norm = new Gee.HashMap<string, string>();
        history_articles = new Gee.HashMap<string, HistoryArticle>();
        article_feedback = new Gee.HashMap<string, ArticleFeedback>();
        recommendation_impressions = new Gee.HashMap<string, RecommendationImpression>();

        init_saved_articles_db();
        migrate_saved_articles_from_json();
        init_history_db();

        // Show cached badge counts immediately; the deferred background metadata fetch updates them later.
        load_article_tracking();
        load_saved_articles_from_db();
        load_history_from_db();
        load_feedback_from_db();
        load_impressions_from_db();

        // Saved articles need their own category tracking entry for unread-count/badge logic on startup.
        var current_saved = get_saved_articles();
        foreach (var article in current_saved) {
            if (article != null && article.url != null && article.url.length > 0) {
                string norm_url = UrlUtils.normalize_article_url(article.url);
                if (norm_url == null || norm_url.length == 0) norm_url = article.url.strip();
                register_article(norm_url, "saved", article.source);
            }
        }

        // Preload viewed flags from .meta files
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
                    // A missing "viewed" key just means not viewed
                    try {
                        string v = kf.get_string("meta", "viewed");
                        if (v == "1" || v.down() == "true") meta_lock_add_viewed(full);
                    } catch (GLib.Error e) { }
                }
            }
        } catch (GLib.Error e) {
            warning("ArticleStateStore: failed to preload viewed flags from %s: %s", cache_dir_path, e.message);
        } finally {
            if (en != null) try { en.close(null); } catch (GLib.Error _) { }
        }
    }

    private string filename_for_url(string url) {
        string u = url;
        if (u.length > 200) u = u.substring(u.length - 200);
        try {
            // Regex literal: compiled once, not on every call
            return /[^A-Za-z0-9._-]/.replace(u, -1, 0, "_");
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
            warning("ArticleStateStore: removing unreadable meta %s: %s", meta_path, e.message);
            try { FileUtils.remove(meta_path); } catch (GLib.Error _) { }
            return null;
        }
    }

    private void write_meta_for_url(string url, KeyFile kf) {
        string meta = meta_path_for(url);
        try {
            kf.save_to_file(meta);
        } catch (GLib.Error e) {
            warning("ArticleStateStore: failed to write meta %s: %s", meta, e.message);
        }
    }

    private void meta_lock_add_viewed(string meta_path) {
        meta_lock.lock();
        viewed_meta_paths.add(meta_path);
        meta_lock.unlock();
    }

    private void meta_lock_remove_viewed(string meta_path) {
        meta_lock.lock();
        viewed_meta_paths.remove(meta_path);
        meta_lock.unlock();
    }

    private bool meta_lock_has_viewed(string meta_path) {
        meta_lock.lock();
        bool result = viewed_meta_paths.contains(meta_path);
        meta_lock.unlock();
        return result;
    }

    // Public API
    public void mark_viewed(string url) {
        string meta_path = meta_path_for(url);
        if (meta_lock_has_viewed(meta_path)) return;
        var kf = read_meta_from_path(meta_path);
        if (kf == null) kf = new KeyFile();
        long now_s = (long)(GLib.get_real_time() / 1000000);
        kf.set_string("meta", "viewed", "1");
        kf.set_string("meta", "viewed_at", "%d".printf((int)now_s));
        write_meta_for_url(url, kf);
        meta_lock_add_viewed(meta_path);
        viewed_status_changed(UrlUtils.normalize_article_url(url), true);
    }

    public void mark_unviewed(string url) {
        string meta_path = meta_path_for(url);
        meta_lock_remove_viewed(meta_path);
        var kf = read_meta_from_path(meta_path);
        if (kf == null) return;
        kf.set_string("meta", "viewed", "0");
        // Throws if viewed_at was never set, which is fine
        try { kf.remove_key("meta", "viewed_at"); } catch (GLib.Error e) { }
        write_meta_for_url(url, kf);
        viewed_status_changed(UrlUtils.normalize_article_url(url), false);
    }

    // In-memory only: the constructor preloads every viewed flag from disk and
    // mark_viewed()/mark_unviewed() keep the set current, so a miss means not
    // viewed. Called for every card built, so it must not touch the disk.
    public bool is_viewed(string url) {
        return meta_lock_has_viewed(meta_path_for(url));
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

    // Sets which city Local News page articles are also tracked under
    // (LocalArea.ID_PREFIX + key), for that city's own unread count.
    public void set_local_news_area(string area_key) {
        article_tracking_lock.lock();
        local_news_area = area_key;
        article_tracking_lock.unlock();
    }

    // Register an article with its category and source for unread tracking
    public void register_article(string url, string? category_id, string? source_name) {
        // Normalize outside the lock to reduce contention under concurrent callers
        string norm_url = "";
        norm_url = UrlUtils.normalize_article_url(url);

        article_tracking_lock.lock();
        try {

            if (category_id != null && category_id.length > 0) {
                if (!category_articles.has_key(category_id)) {
                    category_articles.set(category_id, new Gee.HashSet<string>());
                }
                category_articles.get(category_id).add(norm_url);

                if (category_id == "local_news" && local_news_area != null) {
                    string area_category = LocalArea.ID_PREFIX + local_news_area;
                    if (!category_articles.has_key(area_category)) {
                        category_articles.set(area_category, new Gee.HashSet<string>());
                    }
                    category_articles.get(area_category).add(norm_url);
                }
            }
            if (source_name != null && source_name.length > 0) {
                if (!source_articles.has_key(source_name)) {
                    source_articles.set(source_name, new Gee.HashSet<string>());
                }
                source_articles.get(source_name).add(norm_url);

                long now_ms = (long)(GLib.get_real_time() / 1000);
                source_last_registration_time.set(source_name, now_ms);
            }
        } finally {
            article_tracking_lock.unlock();
        }
    }

    public void add_myfeed_displayed_url(string normalized_url) {
        article_tracking_lock.lock();
        myfeed_displayed_urls.add(normalized_url);
        article_tracking_lock.unlock();
    }

    public void reset_myfeed_displayed_urls() {
        article_tracking_lock.lock();
        myfeed_displayed_urls.clear();
        article_tracking_lock.unlock();
    }

    public Gee.HashSet<string> get_myfeed_displayed_urls() {
        var copy = new Gee.HashSet<string>();
        article_tracking_lock.lock();
        copy.add_all(myfeed_displayed_urls);
        article_tracking_lock.unlock();
        return copy;
    }

    // Explicitly save article tracking to disk
    public void save_article_tracking_to_disk() {
        save_article_tracking();
    }

    // Mark a category as visited by the user
    public void mark_category_visited(string category_id) {
        article_tracking_lock.lock();
        visited_categories.add(category_id);
        article_tracking_lock.unlock();
        // Persisted on next article registration or shutdown, not here, to avoid blocking the UI thread.
    }

    // Check if a category has been visited
    public bool is_category_visited(string category_id) {
        article_tracking_lock.lock();
        bool result = visited_categories.contains(category_id);
        article_tracking_lock.unlock();
        return result;
    }

    // Get all visited categories (for SidebarManager to populate its cache)
    public Gee.HashSet<string> get_visited_categories() {
        article_tracking_lock.lock();
        var result = new Gee.HashSet<string>();
        result.add_all(visited_categories);
        article_tracking_lock.unlock();
        return result;
    }

    // Mark a source as visited by the user
    public void mark_source_visited(string source_name) {
        article_tracking_lock.lock();
        visited_sources.add(source_name);
        article_tracking_lock.unlock();
        // Persisted on next article registration or shutdown, not here, to avoid blocking the UI thread.
    }

    // Check if a source has been visited
    public bool is_source_visited(string source_name) {
        article_tracking_lock.lock();
        bool result = visited_sources.contains(source_name);
        article_tracking_lock.unlock();
        return result;
    }

    // Get all visited sources (for SidebarManager to populate its cache)
    public Gee.HashSet<string> get_visited_sources() {
        article_tracking_lock.lock();
        var result = new Gee.HashSet<string>();
        result.add_all(visited_sources);
        article_tracking_lock.unlock();
        return result;
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

            // In-memory cache only - no disk I/O during count calculation
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

    // Get unread count for "myfeed" category, restricted to what actually got
    // a card built in the current My Feed view (displayed_urls - see
    // ArticleManager.get_myfeed_displayed_urls()). category_articles["myfeed"]
    // holds every article ever registered for the category, which is far
    // more than ArticleManager.MYFEED_ROW_CARD_CAP ever lets onto the page,
    // so counting that directly badly overcounts.
    public int get_unread_count_for_myfeed(Gee.HashSet<string>? displayed_urls) {
        if (displayed_urls == null || displayed_urls.size == 0) return 0;

        int total = 0;
        int viewed = 0;

        article_tracking_lock.lock();
        try {
            meta_lock.lock();
            try {
                foreach (string url in displayed_urls) {
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
        norm = UrlUtils.normalize_article_url(url); 
        article_tracking_lock.lock();
        foreach (var entry in category_articles.entries) {
            if (entry.value.contains(norm)) out.add(entry.key);
        }
        article_tracking_lock.unlock();
        return out;
    }

    // Get list of source names that a specific URL belongs to
    public Gee.ArrayList<string> get_sources_for_url(string url) {
        var out = new Gee.ArrayList<string>();
        string norm = url;
        norm = UrlUtils.normalize_article_url(url); 
        article_tracking_lock.lock();
        foreach (var entry in source_articles.entries) {
            if (entry.value.contains(norm)) out.add(entry.key);
        }
        article_tracking_lock.unlock();
        return out;
    }

    // Clear all article tracking (useful when refreshing/reloading), preserving "saved"
    // since saved articles are persistent user data.
    public void clear_article_tracking() {
        article_tracking_lock.lock();
        try {
            Gee.HashSet<string>? saved_set = null;
            if (category_articles.has_key("saved")) {
                saved_set = category_articles.get("saved");
            }

            category_articles.clear();
            source_articles.clear();

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

            // Save visited categories (for popular category badge persistence)
            builder.set_member_name("visited_categories");
            builder.begin_array();
            foreach (string category_id in visited_categories) {
                builder.add_string_value(category_id);
            }
            builder.end_array();

            // Save visited sources (for source badge persistence)
            builder.set_member_name("visited_sources");
            builder.begin_array();
            foreach (string source_name in visited_sources) {
                builder.add_string_value(source_name);
            }
            builder.end_array();

            builder.set_member_name("myfeed_displayed");
            builder.begin_array();
            foreach (string url in myfeed_displayed_urls) {
                builder.add_string_value(url);
            }
            builder.end_array();

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
                        string raw = node.get_string();
                        string norm = UrlUtils.normalize_article_url(raw);
                        if (norm == null || norm.length == 0) norm = raw.strip();
                        url_set.add(norm);
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
                        string raw = node.get_string();
                        string norm = UrlUtils.normalize_article_url(raw);
                        if (norm == null || norm.length == 0) norm = raw.strip();
                        url_set.add(norm);
                    });
                    source_articles.set(source_name, url_set);
                }
            }

            // Load visited categories (for popular category badge persistence)
            if (obj.has_member("visited_categories")) {
                var visited_array = obj.get_array_member("visited_categories");
                visited_array.foreach_element((arr, index, node) => {
                    visited_categories.add(node.get_string());
                });
            }

            // Load visited sources (for source badge persistence)
            if (obj.has_member("visited_sources")) {
                var visited_array = obj.get_array_member("visited_sources");
                visited_array.foreach_element((arr, index, node) => {
                    visited_sources.add(node.get_string());
                });
            }

            if (obj.has_member("myfeed_displayed")) {
                obj.get_array_member("myfeed_displayed").foreach_element((arr, index, node) => {
                    myfeed_displayed_urls.add(node.get_string());
                });
            }
        } catch (GLib.Error e) {
            stderr.printf("Failed to load article tracking: %s\n", e.message);
        }
    }

    public void save_article(string url, string title, string? thumbnail = null, string? source = null, string? published = null) {
        saved_lock.lock();
        var article = new SavedArticle(url, title, thumbnail, source, published);
        put_saved(url, article);
        saved_lock.unlock();

        save_article_to_db(url, title, thumbnail, source, published, GLib.get_real_time() / 1000000);

        // Register outside saved_lock to avoid lock ordering issues.
        string norm = UrlUtils.normalize_article_url(url);
        if (norm == null || norm.length == 0) norm = url.strip();
        register_article(norm, "saved", source);
        saved_article_added(url);
    }

    public void unsave_article(string url) {
        saved_lock.lock();
        try {
            if (saved_articles.has_key(url)) {
                remove_saved(url);
            } else {
                // Fall back to normalized-URL match in case the entry was stored in a
                // slightly different form (missing scheme, trailing slash, etc).
                // Loop because several stored variants can share one normalized form.
                string norm = UrlUtils.normalize_article_url(url);
                while (saved_keys_by_norm.has_key(norm)) {
                    remove_saved(saved_keys_by_norm.get(norm));
                }
            }
        } finally {
            saved_lock.unlock();
        }

        remove_article_from_db(url);

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
        saved_article_removed(url);
    }

    public bool is_saved(string url) {
        saved_lock.lock();
        try {
            if (saved_articles.has_key(url)) return true;
            return saved_keys_by_norm.has_key(UrlUtils.normalize_article_url(url));
        } finally {
            saved_lock.unlock();
        }
    }

    // saved_articles mutators that keep saved_keys_by_norm in sync. Caller holds saved_lock.
    private void put_saved(string key, SavedArticle article) {
        saved_articles.set(key, article);
        saved_keys_by_norm.set(UrlUtils.normalize_article_url(key), key);
    }

    private void remove_saved(string key) {
        saved_articles.unset(key);
        string norm = UrlUtils.normalize_article_url(key);
        if (saved_keys_by_norm.get(norm) != key) return;
        saved_keys_by_norm.unset(norm);
        // Another stored variant with the same normalized form takes over (rare)
        foreach (var k in saved_articles.keys) {
            if (UrlUtils.normalize_article_url(k) == norm) {
                saved_keys_by_norm.set(norm, k);
                break;
            }
        }
    }

    public Gee.ArrayList<SavedArticle?> get_saved_articles() {
        saved_lock.lock();
        var list = new Gee.ArrayList<SavedArticle?>();
        foreach (var article in saved_articles.values) {
            list.add(article);
        }
        list.sort((a, b) => {
            return (int)(b.saved_timestamp - a.saved_timestamp);
        });
        saved_lock.unlock();
        return list;
    }

    public SavedArticle? get_saved_article(string url) {
        saved_lock.lock();
        try {
            if (saved_articles.has_key(url)) return saved_articles.get(url);
            string? key = saved_keys_by_norm.get(UrlUtils.normalize_article_url(url));
            return key != null ? saved_articles.get(key) : null;
        } finally {
            saved_lock.unlock();
        }
    }

    public int get_saved_count() {
        saved_lock.lock();
        int result = saved_articles.size;
        saved_lock.unlock();
        return result;
    }

    // Return count of saved articles that are not yet viewed
    public int get_unread_saved_count() {
        int cnt = 0;
        saved_lock.lock();
        foreach (var article in saved_articles.values) {
            try {
                string norm = UrlUtils.normalize_article_url(article.url);
                if (norm == null || norm.length == 0) norm = article.url.strip();
                if (!is_viewed(norm)) cnt++;
            } catch (GLib.Error e) {
                cnt++; // treat as unread if normalization fails
            }
        }
        saved_lock.unlock();
        return cnt;
    }

    // Initialize SQLite database for saved articles
    private void init_saved_articles_db() {
        var cache_base = Environment.get_user_cache_dir();
        if (cache_base == null) cache_base = "/tmp";
        string db_path = Path.build_filename(cache_base, "paperboy", "saved_articles.db");

        saved_db_lock.lock();
        try {
            int rc = Sqlite.Database.open(db_path, out saved_db);
            if (rc != Sqlite.OK) {
                stderr.printf("Failed to open saved articles database: %d\n", rc);
                saved_db = null;
                return;
            }

            string create_table = """
                CREATE TABLE IF NOT EXISTS saved_articles (
                    url TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    thumbnail TEXT,
                    source TEXT,
                    saved_timestamp INTEGER NOT NULL,
                    published TEXT
                );
            """;

            rc = saved_db.exec(create_table, null, null);
            if (rc != Sqlite.OK) {
                stderr.printf("Failed to create saved articles table: %s\n", saved_db.errmsg());
            }

            // Older databases predate the "published" column; add it, ignoring the error if it exists.
            saved_db.exec("ALTER TABLE saved_articles ADD COLUMN published TEXT;", null, null);
        } finally {
            saved_db_lock.unlock();
        }
    }

    private void save_article_to_db(string url, string title, string? thumbnail, string? source, string? published, int64 timestamp) {
        saved_db_lock.lock();
        if (saved_db == null) {
            saved_db_lock.unlock();
            return;
        }

        string sql = """
            INSERT OR REPLACE INTO saved_articles (url, title, thumbnail, source, saved_timestamp, published)
            VALUES (?, ?, ?, ?, ?, ?);
        """;

        Sqlite.Statement stmt;
        int rc = saved_db.prepare_v2(sql, -1, out stmt);
        if (rc != Sqlite.OK) {
            stderr.printf("Failed to prepare save article statement: %s\n", saved_db.errmsg());
            saved_db_lock.unlock();
            return;
        }

        stmt.bind_text(1, url);
        stmt.bind_text(2, title);
        stmt.bind_text(3, thumbnail);
        stmt.bind_text(4, source);
        stmt.bind_int64(5, timestamp);
        stmt.bind_text(6, published);

        rc = stmt.step();
        if (rc != Sqlite.DONE) {
            stderr.printf("Failed to save article to database: %s\n", saved_db.errmsg());
        }
        saved_db_lock.unlock();
    }

    private void remove_article_from_db(string url) {
        saved_db_lock.lock();
        if (saved_db == null) {
            saved_db_lock.unlock();
            return;
        }

        string sql = "DELETE FROM saved_articles WHERE url = ?;";

        Sqlite.Statement stmt;
        int rc = saved_db.prepare_v2(sql, -1, out stmt);
        if (rc != Sqlite.OK) {
            stderr.printf("Failed to prepare delete article statement: %s\n", saved_db.errmsg());
            saved_db_lock.unlock();
            return;
        }

        stmt.bind_text(1, url);

        rc = stmt.step();
        if (rc != Sqlite.DONE) {
            stderr.printf("Failed to delete article from database: %s\n", saved_db.errmsg());
        }
        saved_db_lock.unlock();
    }

    private void load_saved_articles_from_db() {
        saved_db_lock.lock();
        try {
            if (saved_db == null) return;

            string sql = "SELECT url, title, thumbnail, source, saved_timestamp, published FROM saved_articles ORDER BY saved_timestamp DESC;";

            Sqlite.Statement stmt;
            int rc = saved_db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                stderr.printf("Failed to prepare load articles statement: %s\n", saved_db.errmsg());
                return;
            }

            saved_lock.lock();
            try {
                while (stmt.step() == Sqlite.ROW) {
                    string url = stmt.column_text(0);
                    string title = stmt.column_text(1);
                    string? thumbnail = stmt.column_text(2);
                    string? source = stmt.column_text(3);
                    int64 timestamp = stmt.column_int64(4);
                    string? published = stmt.column_text(5);

                    var article = new SavedArticle(url, title, thumbnail, source, published);
                    article.saved_timestamp = timestamp;
                    put_saved(url, article);
                }
            } finally {
                saved_lock.unlock();
            }

            // So the sidebar can immediately show the correct "Saved" badge count.
            foreach (var article in saved_articles.values) {
                string norm = UrlUtils.normalize_article_url(article.url);
                if (norm == null || norm.length == 0) norm = article.url.strip();
                register_article(norm, "saved", article.source);
            }

            saved_articles_loaded();
        } finally {
            saved_db_lock.unlock();
        }
    }

    // One-time migration of saved articles from the old JSON file to SQLite.
    private void migrate_saved_articles_from_json() {
        string saved_file = Path.build_filename(cache_dir_path, "saved_articles.json");
        if (!FileUtils.test(saved_file, FileTest.EXISTS)) {
            return;
        }

        saved_db_lock.lock();
        if (saved_db == null) {
            saved_db_lock.unlock();
            return;
        }

        string count_sql = "SELECT COUNT(*) FROM saved_articles;";
        Sqlite.Statement stmt;
        int rc = saved_db.prepare_v2(count_sql, -1, out stmt);
        if (rc == Sqlite.OK && stmt.step() == Sqlite.ROW) {
            int count = stmt.column_int(0);
            if (count > 0) {
                saved_db_lock.unlock();
                return;
            }
        }
        saved_db_lock.unlock();

        try {
            var parser = new Json.Parser();
            parser.load_from_file(saved_file);
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) {
                stderr.printf("Warning: saved_articles.json exists but has invalid format, skipping migration\n");
                return;
            }

            var obj = root.get_object();
            if (obj.has_member("saved")) {
                var saved_array = obj.get_array_member("saved");
                int migrated_count = 0;

                saved_array.foreach_element((arr, index, node) => {
                    if (node.get_node_type() == Json.NodeType.OBJECT) {
                        var article_obj = node.get_object();
                        string url = article_obj.get_string_member("url");
                        string title = article_obj.get_string_member("title");
                        string? thumbnail = article_obj.has_member("thumbnail") ? article_obj.get_string_member("thumbnail") : null;
                        string? source = article_obj.has_member("source") ? article_obj.get_string_member("source") : null;
                        int64 timestamp = GLib.get_real_time() / 1000000;
                        if (article_obj.has_member("saved_timestamp")) {
                            timestamp = article_obj.get_int_member("saved_timestamp");
                        }

                        // Old JSON format never recorded published date; nothing to migrate for it.
                        save_article_to_db(url, title, thumbnail, source, null, timestamp);
                        migrated_count++;
                    }
                });

                stderr.printf("Migrated %d saved articles from JSON to SQLite database\n", migrated_count);

                string backup_file = saved_file + ".bak";
                try {
                    FileUtils.rename(saved_file, backup_file);
                    stderr.printf("Renamed %s to %s\n", saved_file, backup_file);
                } catch (GLib.Error e) {
                    stderr.printf("Warning: Failed to rename JSON file: %s\n", e.message);
                }
            }
        } catch (GLib.Error e) {
            stderr.printf("Failed to migrate saved articles from JSON: %s\n", e.message);
        }
    }

    // Initialize SQLite database for reading history
    private void init_history_db() {
        var cache_base = Environment.get_user_cache_dir();
        if (cache_base == null) cache_base = "/tmp";
        string db_path = Path.build_filename(cache_base, "paperboy", "history.db");

        history_db_lock.lock();
        try {
            int rc = Sqlite.Database.open(db_path, out history_db);
            if (rc != Sqlite.OK) {
                stderr.printf("Failed to open history database: %d\n", rc);
                history_db = null;
                return;
            }

            string create_table = """
                CREATE TABLE IF NOT EXISTS history_articles (
                    url TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    thumbnail TEXT,
                    source TEXT,
                    viewed_timestamp INTEGER NOT NULL,
                    published TEXT
                );
            """;

            rc = history_db.exec(create_table, null, null);
            if (rc != Sqlite.OK) {
                stderr.printf("Failed to create history table: %s\n", history_db.errmsg());
            }

            // Older databases predate the "category_id" column; add it, ignoring the error if it exists.
            history_db.exec("ALTER TABLE history_articles ADD COLUMN category_id TEXT;", null, null);

            rc = history_db.exec("""
                CREATE TABLE IF NOT EXISTS article_feedback (
                    url TEXT PRIMARY KEY,
                    title TEXT,
                    source TEXT,
                    category_id TEXT,
                    vote INTEGER NOT NULL,
                    timestamp INTEGER NOT NULL
                );
            """, null, null);
            if (rc != Sqlite.OK) {
                stderr.printf("Failed to create feedback table: %s\n", history_db.errmsg());
            }

            rc = history_db.exec("""
                CREATE TABLE IF NOT EXISTS recommendation_impressions (
                    story TEXT PRIMARY KEY,
                    shown INTEGER NOT NULL,
                    last_shown INTEGER NOT NULL
                );
            """, null, null);
            if (rc != Sqlite.OK) {
                stderr.printf("Failed to create impressions table: %s\n", history_db.errmsg());
            }
        } finally {
            history_db_lock.unlock();
        }
    }

    // Deletes entries older than HISTORY_MAX_AGE_DAYS, then trims down to
    // HISTORY_MAX_ENTRIES (oldest first) if still over the cap. Must be
    // called with history_db_lock already held.
    private void trim_history_locked() {
        if (history_db == null) return;

        int64 cutoff = (GLib.get_real_time() / 1000000) - ((int64)HISTORY_MAX_AGE_DAYS * 24 * 60 * 60);
        string expire_sql = "DELETE FROM history_articles WHERE viewed_timestamp < %s;".printf(cutoff.to_string());
        history_db.exec(expire_sql, null, null);

        string trim_sql = """
            DELETE FROM history_articles WHERE url IN (
                SELECT url FROM history_articles ORDER BY viewed_timestamp DESC LIMIT -1 OFFSET %d
            );
        """.printf(HISTORY_MAX_ENTRIES);
        history_db.exec(trim_sql, null, null);
    }

    // Record (or refresh the timestamp of) a history entry. A null/empty
    // field keeps whatever was already recorded for this URL rather than
    // blanking it out - callers that can't know the full metadata (e.g.
    // the reader view's own "open in browser" menu item, or re-opening
    // from the Notes browser) shouldn't clobber good data a previous,
    // fully-informed card open already captured. Only falls back to the
    // URL as a display title when this is the first record for it and no
    // title was ever known.
    public void record_history(string url, string? title, string? thumbnail, string? source, string? published = null, string? category_id = null) {
        int64 now = GLib.get_real_time() / 1000000;

        history_lock.lock();
        var existing = history_articles.has_key(url) ? history_articles.get(url) : null;
        string? resolved_title_raw = (title != null && title.length > 0) ? title : (existing != null ? existing.title : null);
        string display_title = (resolved_title_raw != null && resolved_title_raw.length > 0) ? resolved_title_raw : url;
        string? resolved_thumbnail = (thumbnail != null && thumbnail.length > 0) ? thumbnail : (existing != null ? existing.thumbnail : null);
        string? resolved_source = (source != null && source.length > 0) ? source : (existing != null ? existing.source : null);
        string? resolved_published = (published != null && published.length > 0) ? published : (existing != null ? existing.published : null);
        string? resolved_category = (category_id != null && category_id.length > 0) ? category_id : (existing != null ? existing.category_id : null);

        var article = new HistoryArticle(url, display_title, resolved_thumbnail, resolved_source, resolved_published, resolved_category);
        article.viewed_timestamp = now;
        history_articles.set(url, article);
        history_lock.unlock();

        history_db_lock.lock();
        if (history_db != null) {
            string sql = """
                INSERT OR REPLACE INTO history_articles (url, title, thumbnail, source, viewed_timestamp, published, category_id)
                VALUES (?, ?, ?, ?, ?, ?, ?);
            """;
            Sqlite.Statement stmt;
            int rc = history_db.prepare_v2(sql, -1, out stmt);
            if (rc == Sqlite.OK) {
                stmt.bind_text(1, url);
                stmt.bind_text(2, display_title);
                stmt.bind_text(3, resolved_thumbnail);
                stmt.bind_text(4, resolved_source);
                stmt.bind_int64(5, now);
                stmt.bind_text(6, resolved_published);
                stmt.bind_text(7, resolved_category);
                if (stmt.step() != Sqlite.DONE) {
                    stderr.printf("Failed to record history entry: %s\n", history_db.errmsg());
                }
            }
            trim_history_locked();
        }
        history_db_lock.unlock();

        history_changed();
    }

    public HistoryArticle? get_history_article(string url) {
        history_lock.lock();
        try {
            if (history_articles.has_key(url)) return history_articles.get(url);
            string norm = url;
            try { norm = UrlUtils.normalize_article_url(url); } catch (GLib.Error e) { norm = url.strip(); }
            foreach (var k in history_articles.keys) {
                try {
                    string kn = UrlUtils.normalize_article_url(k);
                    if (kn == norm) return history_articles.get(k);
                } catch (GLib.Error e) {
                    if (k == url) return history_articles.get(k);
                }
            }
            return null;
        } finally {
            history_lock.unlock();
        }
    }

    // Clears all reading history, both the in-memory cache and the database.
    public void clear_history() {
        history_lock.lock();
        history_articles.clear();
        history_lock.unlock();

        history_db_lock.lock();
        if (history_db != null) {
            history_db.exec("DELETE FROM history_articles;", null, null);
            history_db.exec("DELETE FROM article_feedback;", null, null);
            history_db.exec("DELETE FROM recommendation_impressions;", null, null);
        }
        history_db_lock.unlock();

        feedback_lock.lock();
        article_feedback.clear();
        feedback_lock.unlock();
        recommendation_impressions.clear();

        history_changed();
    }

    public Gee.ArrayList<HistoryArticle?> get_history_articles() {
        history_lock.lock();
        var list = new Gee.ArrayList<HistoryArticle?>();
        foreach (var article in history_articles.values) {
            list.add(article);
        }
        list.sort((a, b) => {
            return (int)(b.viewed_timestamp - a.viewed_timestamp);
        });
        history_lock.unlock();
        return list;
    }

    // Snapshot of reading history as a "Recommended for you" interest profile.
    public InterestProfile build_interest_profile() {
        var profile = new InterestProfile();
        history_lock.lock();
        foreach (var a in history_articles.values) {
            profile.add_read(a.url, a.title, a.source, a.category_id, a.viewed_timestamp);
        }
        history_lock.unlock();
        feedback_lock.lock();
        foreach (var f in article_feedback.values) {
            profile.add_feedback(f.url, f.title, f.source, f.category_id, f.vote, f.timestamp);
        }
        feedback_lock.unlock();
        profile.finish();
        return profile;
    }

    // +1 liked, -1 disliked, 0 no vote. Keyed by normalized URL.
    public int get_feedback(string url) {
        feedback_lock.lock();
        var f = article_feedback.get(url);
        int vote = f != null ? f.vote : 0;
        feedback_lock.unlock();
        return vote;
    }

    // vote 0 clears it.
    public void set_feedback(string url, string? title, string? source, string? category_id, int vote) {
        int64 now = GLib.get_real_time() / 1000000;
        feedback_lock.lock();
        if (vote == 0) {
            article_feedback.unset(url);
        } else {
            var f = new ArticleFeedback();
            f.url = url;
            f.title = title;
            f.source = source;
            f.category_id = category_id;
            f.vote = vote > 0 ? 1 : -1;
            f.timestamp = now;
            article_feedback.set(url, f);
        }
        feedback_lock.unlock();

        history_db_lock.lock();
        if (history_db != null) {
            Sqlite.Statement stmt;
            if (vote == 0) {
                if (history_db.prepare_v2("DELETE FROM article_feedback WHERE url = ?;", -1, out stmt) == Sqlite.OK) {
                    stmt.bind_text(1, url);
                    stmt.step();
                }
            } else if (history_db.prepare_v2("""
                INSERT OR REPLACE INTO article_feedback (url, title, source, category_id, vote, timestamp)
                VALUES (?, ?, ?, ?, ?, ?);
            """, -1, out stmt) == Sqlite.OK) {
                stmt.bind_text(1, url);
                stmt.bind_text(2, title);
                stmt.bind_text(3, source);
                stmt.bind_text(4, category_id);
                stmt.bind_int(5, vote > 0 ? 1 : -1);
                stmt.bind_int64(6, now);
                if (stmt.step() != Sqlite.DONE) {
                    stderr.printf("Failed to record feedback: %s\n", history_db.errmsg());
                }
                history_db.exec("""
                    DELETE FROM article_feedback WHERE url IN (
                        SELECT url FROM article_feedback ORDER BY timestamp DESC LIMIT -1 OFFSET %d
                    );
                """.printf(FEEDBACK_MAX_ENTRIES), null, null);
            }
        }
        history_db_lock.unlock();

        feedback_changed(url, vote);
    }

    private void load_feedback_from_db() {
        history_db_lock.lock();
        if (history_db != null) {
            Sqlite.Statement stmt;
            string sql = "SELECT url, title, source, category_id, vote, timestamp FROM article_feedback ORDER BY timestamp DESC LIMIT %d;".printf(FEEDBACK_MAX_ENTRIES);
            if (history_db.prepare_v2(sql, -1, out stmt) == Sqlite.OK) {
                feedback_lock.lock();
                while (stmt.step() == Sqlite.ROW) {
                    var f = new ArticleFeedback();
                    f.url = stmt.column_text(0);
                    f.title = stmt.column_text(1);
                    f.source = stmt.column_text(2);
                    f.category_id = stmt.column_text(3);
                    f.vote = stmt.column_int(4);
                    f.timestamp = stmt.column_int64(5);
                    article_feedback.set(f.url, f);
                }
                feedback_lock.unlock();
            }
        }
        history_db_lock.unlock();
    }

    public int get_recommendation_impressions(string story) {
        var imp = recommendation_impressions.get(story);
        return imp != null ? imp.shown : 0;
    }

    public void record_recommendation_impressions(Gee.Collection<string> stories) {
        int64 now = GLib.get_real_time() / 1000000;
        var changed = new Gee.ArrayList<RecommendationImpression>();
        foreach (string story in stories) {
            var imp = recommendation_impressions.get(story);
            if (imp != null && now - imp.last_shown < IMPRESSION_MIN_GAP_SECS) continue;
            if (imp == null) {
                imp = new RecommendationImpression();
                imp.story = story;
                recommendation_impressions.set(story, imp);
            }
            imp.shown++;
            imp.last_shown = now;
            changed.add(imp);
        }
        if (changed.size == 0) return;

        history_db_lock.lock();
        if (history_db != null) {
            history_db.exec("BEGIN;", null, null);
            Sqlite.Statement stmt;
            if (history_db.prepare_v2("INSERT OR REPLACE INTO recommendation_impressions (story, shown, last_shown) VALUES (?, ?, ?);", -1, out stmt) == Sqlite.OK) {
                foreach (var imp in changed) {
                    stmt.reset();
                    stmt.bind_text(1, imp.story);
                    stmt.bind_int(2, imp.shown);
                    stmt.bind_int64(3, imp.last_shown);
                    stmt.step();
                }
            }
            history_db.exec("COMMIT;", null, null);
        }
        history_db_lock.unlock();
    }

    // Drops impressions old enough that their articles have left the Front Page.
    private void load_impressions_from_db() {
        int64 cutoff = (GLib.get_real_time() / 1000000) - ((int64)IMPRESSION_MAX_AGE_DAYS * 24 * 60 * 60);
        history_db_lock.lock();
        if (history_db != null) {
            history_db.exec("DELETE FROM recommendation_impressions WHERE last_shown < %s;".printf(cutoff.to_string()), null, null);
            Sqlite.Statement stmt;
            if (history_db.prepare_v2("SELECT story, shown, last_shown FROM recommendation_impressions;", -1, out stmt) == Sqlite.OK) {
                while (stmt.step() == Sqlite.ROW) {
                    var imp = new RecommendationImpression();
                    imp.story = stmt.column_text(0);
                    imp.shown = stmt.column_int(1);
                    imp.last_shown = stmt.column_int64(2);
                    recommendation_impressions.set(imp.story, imp);
                }
            }
        }
        history_db_lock.unlock();
    }

    public int get_history_count() {
        history_lock.lock();
        int result = history_articles.size;
        history_lock.unlock();
        return result;
    }

    private void load_history_from_db() {
        history_db_lock.lock();
        try {
            if (history_db == null) return;

            trim_history_locked();

            string sql = "SELECT url, title, thumbnail, source, viewed_timestamp, published, category_id FROM history_articles ORDER BY viewed_timestamp DESC;";

            Sqlite.Statement stmt;
            int rc = history_db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                stderr.printf("Failed to prepare load history statement: %s\n", history_db.errmsg());
                return;
            }

            history_lock.lock();
            try {
                while (stmt.step() == Sqlite.ROW) {
                    string url = stmt.column_text(0);
                    string title = stmt.column_text(1);
                    string? thumbnail = stmt.column_text(2);
                    string? source = stmt.column_text(3);
                    int64 timestamp = stmt.column_int64(4);
                    string? published = stmt.column_text(5);
                    string? category_id = stmt.column_text(6);

                    var article = new HistoryArticle(url, title, thumbnail, source, published, category_id);
                    article.viewed_timestamp = timestamp;
                    history_articles.set(url, article);
                }
            } finally {
                history_lock.unlock();
            }

            history_loaded();
        } finally {
            history_db_lock.unlock();
        }
    }
}
