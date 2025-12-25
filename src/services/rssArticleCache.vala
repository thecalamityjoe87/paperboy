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

using Sqlite;
using Gee;

/*
 * Stores and manages articles fetched from RSS feeds to improve performance
 * and reduce network usage. Maintains a local cache of articles for each feed,
 * allowing fast feed switching, offline access, and historical article retrieval.
*/

namespace Paperboy {

    public class RssArticleCache : GLib.Object {
        private static RssArticleCache? instance = null;
        private Sqlite.Database? db = null;
        private string db_path;

        // Cache configuration
        public const int MAX_ARTICLES_PER_FEED = 200;
        public const int MAX_FRONTPAGE_ARTICLES = 120;  // Keep more frontpage articles for variety
        private const int64 CACHE_RETENTION_DAYS = 30;
        private const int64 FRONTPAGE_RETENTION_HOURS = 48;  // Keep frontpage fresh (2 days)

        public struct CachedArticle {
            public string url;
            public string title;
            public string? thumbnail_url;
            public string? published_date;
            public string feed_url;
            public int64 cached_at;
            public string? source_name;
            public string? logo_url;
            public string? category_id;
        }

        private RssArticleCache() {
            string? cache_dir = GLib.Environment.get_user_cache_dir();
            if (cache_dir == null) {
                GLib.critical("RssArticleCache: Failed to get user cache directory");
                return;
            }

            db_path = GLib.Path.build_filename(cache_dir, "paperboy", "rss_cache.db");

            // Ensure parent directory exists
            string parent_dir = GLib.Path.get_dirname(db_path);
            if (!GLib.FileUtils.test(parent_dir, GLib.FileTest.EXISTS)) {
                GLib.DirUtils.create_with_parents(parent_dir, 0755);
            }

            init_database();
        }

        public static RssArticleCache get_instance() {
            if (instance == null) {
                instance = new RssArticleCache();
            }
            return instance;
        }

        private void init_database() {
            int rc = Sqlite.Database.open(db_path, out db);
            if (rc != Sqlite.OK) {
                GLib.critical("RssArticleCache: Failed to open database: %s", db != null ? db.errmsg() : "unknown error");
                db = null;
                return;
            }

            // Create the rss_articles table
            string create_table = """
                CREATE TABLE IF NOT EXISTS rss_articles (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    url TEXT NOT NULL,
                    title TEXT NOT NULL,
                    thumbnail_url TEXT,
                    published_date TEXT,
                    feed_url TEXT NOT NULL,
                    cached_at INTEGER NOT NULL,
                    source_name TEXT,
                    logo_url TEXT,
                    category_id TEXT,
                    UNIQUE(url, feed_url)
                );
            """;

            string errmsg;
            rc = db.exec(create_table, null, out errmsg);
            if (rc != Sqlite.OK) {
                GLib.critical("RssArticleCache: Failed to create rss_articles table: %s", errmsg);
                return;
            }

            // Create index on feed_url for fast queries
            string create_index = """
                CREATE INDEX IF NOT EXISTS idx_feed_url ON rss_articles(feed_url);
            """;

            rc = db.exec(create_index, null, out errmsg);
            if (rc != Sqlite.OK) {
                GLib.warning("RssArticleCache: Failed to create index: %s", errmsg);
            }

            // Create index on cached_at for cleanup queries
            string create_time_index = """
                CREATE INDEX IF NOT EXISTS idx_cached_at ON rss_articles(cached_at);
            """;

            rc = db.exec(create_time_index, null, out errmsg);
            if (rc != Sqlite.OK) {
                GLib.warning("RssArticleCache: Failed to create time index: %s", errmsg);
            }

            // Migrate existing database to add new columns if they don't exist
            migrate_schema();
        }

        private void migrate_schema() {
            if (db == null) return;

            // Add source_name column if it doesn't exist
            string add_source_name = """
                ALTER TABLE rss_articles ADD COLUMN source_name TEXT;
            """;
            db.exec(add_source_name, null, null);  // Ignore errors if column exists

            // Add logo_url column if it doesn't exist
            string add_logo_url = """
                ALTER TABLE rss_articles ADD COLUMN logo_url TEXT;
            """;
            db.exec(add_logo_url, null, null);  // Ignore errors if column exists

            // Add category_id column if it doesn't exist
            string add_category_id = """
                ALTER TABLE rss_articles ADD COLUMN category_id TEXT;
            """;
            db.exec(add_category_id, null, null);  // Ignore errors if column exists
        }

        /**
         * Cache an article from an RSS feed
         */
        public bool cache_article(string url, string title, string? thumbnail_url, string? published_date, string feed_url, string? source_name = null, string? logo_url = null, string? category_id = null) {
            if (db == null) {
                GLib.warning("RssArticleCache: Database not initialized");
                return false;
            }

            if (url == null || url.length == 0 || title == null || title.length == 0 || feed_url == null || feed_url.length == 0) {
                return false;
            }

            int64 now = GLib.get_real_time() / 1000000;

            // Use INSERT OR REPLACE to update cached_at if article already exists
            string sql = """
                INSERT OR REPLACE INTO rss_articles (url, title, thumbnail_url, published_date, feed_url, cached_at, source_name, logo_url, category_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """;

            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("RssArticleCache: Failed to prepare statement: %s", db.errmsg());
                return false;
            }

            stmt.bind_text(1, url);
            stmt.bind_text(2, title);
            stmt.bind_text(3, thumbnail_url ?? "");
            stmt.bind_text(4, published_date ?? "");
            stmt.bind_text(5, feed_url);
            stmt.bind_int64(6, now);
            stmt.bind_text(7, source_name ?? "");
            stmt.bind_text(8, logo_url ?? "");
            stmt.bind_text(9, category_id ?? "");

            rc = stmt.step();
            if (rc != Sqlite.DONE) {
                GLib.warning("RssArticleCache: Failed to cache article: %s", db.errmsg());
                return false;
            }

            return true;
        }

        /**
         * Get cached articles for a specific feed
         */
        public Gee.ArrayList<CachedArticle?> get_cached_articles(string feed_url, int limit = MAX_ARTICLES_PER_FEED) {
            var articles = new Gee.ArrayList<CachedArticle?>();

            if (db == null) {
                GLib.warning("RssArticleCache: Database not initialized");
                return articles;
            }

            if (feed_url == null || feed_url.length == 0) {
                return articles;
            }

            // Get articles ordered by cached_at (most recent first)
            string sql = """
                SELECT url, title, thumbnail_url, published_date, feed_url, cached_at, source_name, logo_url, category_id
                FROM rss_articles
                WHERE feed_url = ?
                ORDER BY cached_at DESC
                LIMIT ?;
            """;

            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("RssArticleCache: Failed to prepare statement: %s", db.errmsg());
                return articles;
            }

            stmt.bind_text(1, feed_url);
            stmt.bind_int(2, limit);

            while ((rc = stmt.step()) == Sqlite.ROW) {
                CachedArticle article = CachedArticle();
                article.url = stmt.column_text(0);
                article.title = stmt.column_text(1);
                string? thumb = stmt.column_text(2);
                article.thumbnail_url = (thumb != null && thumb.length > 0) ? thumb : null;
                string? pub = stmt.column_text(3);
                article.published_date = (pub != null && pub.length > 0) ? pub : null;
                article.feed_url = stmt.column_text(4);
                article.cached_at = stmt.column_int64(5);
                string? src_name = stmt.column_text(6);
                article.source_name = (src_name != null && src_name.length > 0) ? src_name : null;
                string? logo = stmt.column_text(7);
                article.logo_url = (logo != null && logo.length > 0) ? logo : null;
                string? cat_id = stmt.column_text(8);
                article.category_id = (cat_id != null && cat_id.length > 0) ? cat_id : null;

                articles.add(article);
            }

            if (rc != Sqlite.DONE) {
                GLib.warning("RssArticleCache: Error reading cached articles: %s", db.errmsg());
            }

            return articles;
        }

        /**
         * Clean up old articles and enforce per-feed limits
         */
        public void cleanup() {
            if (db == null) {
                return;
            }

            int64 now = GLib.get_real_time() / 1000000;

            // Different retention for frontpage vs RSS feeds
            int64 frontpage_cutoff = now - (FRONTPAGE_RETENTION_HOURS * 60 * 60);
            int64 rss_cutoff = now - (CACHE_RETENTION_DAYS * 24 * 60 * 60);

            // Delete old frontpage articles (older than 48 hours)
            string delete_old_frontpage = """
                DELETE FROM rss_articles
                WHERE feed_url = 'paperboy:frontpage' AND cached_at < ?;
            """;

            Sqlite.Statement stmt;
            int rc = db.prepare_v2(delete_old_frontpage, -1, out stmt);
            if (rc == Sqlite.OK) {
                stmt.bind_int64(1, frontpage_cutoff);
                rc = stmt.step();
                if (rc != Sqlite.DONE) {
                    GLib.warning("RssArticleCache: Failed to delete old frontpage articles: %s", db.errmsg());
                }
            }

            // Delete old RSS articles (older than 30 days)
            string delete_old_rss = """
                DELETE FROM rss_articles
                WHERE feed_url != 'paperboy:frontpage' AND cached_at < ?;
            """;

            rc = db.prepare_v2(delete_old_rss, -1, out stmt);
            if (rc == Sqlite.OK) {
                stmt.bind_int64(1, rss_cutoff);
                rc = stmt.step();
                if (rc != Sqlite.DONE) {
                    GLib.warning("RssArticleCache: Failed to delete old RSS articles: %s", db.errmsg());
                }
            }

            // Enforce frontpage article limit (120 articles)
            string delete_excess_frontpage = """
                DELETE FROM rss_articles
                WHERE feed_url = 'paperboy:frontpage' AND id NOT IN (
                    SELECT id FROM rss_articles
                    WHERE feed_url = 'paperboy:frontpage'
                    ORDER BY cached_at DESC
                    LIMIT ?
                );
            """;

            rc = db.prepare_v2(delete_excess_frontpage, -1, out stmt);
            if (rc == Sqlite.OK) {
                stmt.bind_int(1, MAX_FRONTPAGE_ARTICLES);
                rc = stmt.step();
                if (rc != Sqlite.DONE) {
                    GLib.warning("RssArticleCache: Failed to delete excess frontpage articles: %s", db.errmsg());
                }
            }

            // Enforce per-feed article limit for RSS feeds (200 articles each)
            string delete_excess_rss = """
                DELETE FROM rss_articles
                WHERE feed_url != 'paperboy:frontpage' AND id IN (
                    SELECT id FROM (
                        SELECT id,
                               ROW_NUMBER() OVER (PARTITION BY feed_url ORDER BY cached_at DESC) AS rn
                        FROM rss_articles
                        WHERE feed_url != 'paperboy:frontpage'
                    )
                    WHERE rn > ?
                );
            """;

            rc = db.prepare_v2(delete_excess_rss, -1, out stmt);
            if (rc == Sqlite.OK) {
                stmt.bind_int(1, MAX_ARTICLES_PER_FEED);
                rc = stmt.step();
                if (rc != Sqlite.DONE) {
                    GLib.warning("RssArticleCache: Failed to delete excess RSS articles: %s", db.errmsg());
                }
            }

            // Vacuum to reclaim space
            db.exec("VACUUM;", null, null);
        }

        /**
         * Clear all cached articles for a specific feed
         */
        public void clear_feed_cache(string feed_url) {
            if (db == null || feed_url == null || feed_url.length == 0) {
                return;
            }

            string sql = "DELETE FROM rss_articles WHERE feed_url = ?;";

            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("RssArticleCache: Failed to prepare clear statement: %s", db.errmsg());
                return;
            }

            stmt.bind_text(1, feed_url);
            rc = stmt.step();
            if (rc != Sqlite.DONE) {
                GLib.warning("RssArticleCache: Failed to clear feed cache: %s", db.errmsg());
            }
        }

        /**
         * Get count of cached articles for a feed
         */
        public int get_article_count(string feed_url) {
            if (db == null || feed_url == null || feed_url.length == 0) {
                return 0;
            }

            string sql = "SELECT COUNT(*) FROM rss_articles WHERE feed_url = ?;";

            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                return 0;
            }

            stmt.bind_text(1, feed_url);

            if (stmt.step() == Sqlite.ROW) {
                return stmt.column_int(0);
            }

            return 0;
        }

        /**
         * Get total number of cached articles across all feeds
         */
        public int get_total_article_count() {
            if (db == null) {
                return 0;
            }

            string sql = "SELECT COUNT(*) FROM rss_articles;";

            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                return 0;
            }

            if (stmt.step() == Sqlite.ROW) {
                return stmt.column_int(0);
            }

            return 0;
        }

        /*
        * Get the size of the cache database file in bytes
        * Returns -1 on failure
        */
        public int64 get_cache_size() {
            var file = GLib.File.new_for_path(db_path);

            try {
                if (file.query_exists()) {
                    var info = file.query_info(
                        "standard::size",
                        GLib.FileQueryInfoFlags.NONE
                    );
                    return info.get_size();
                }
            } catch (GLib.Error e) {
                GLib.warning("Failed to get cache size: %s", e.message);
            }

            return -1;
        }

        /*
        * Get formatted cache information (size and article count)
        * Returns a user-friendly string like "2.5 MB (1,234 articles)" or "Unknown"
        */
        public string get_cache_info_formatted() {
            int article_count = get_total_article_count();
            int64 cache_size = get_cache_size();

            // If either piece of data failed, return Unknown
            if (article_count < 0 || cache_size < 0) {
                return "Unknown";
            }

            string size_text;
            if (cache_size < 1024) {
                size_text = "%lld bytes".printf(cache_size);
            } else if (cache_size < 1024 * 1024) {
                size_text = "%.1f KB".printf(cache_size / 1024.0);
            } else {
                size_text = "%.1f MB".printf(cache_size / (1024.0 * 1024.0));
            }

            return "%s (%d articles)".printf(size_text, article_count);
        }

        /**
         * Clear all cached articles from the database
         */
        public void clear_all() {
            if (db == null) {
                return;
            }

            string sql = "DELETE FROM rss_articles;";
            string errmsg;
            int rc = db.exec(sql, null, out errmsg);
            if (rc != Sqlite.OK) {
                GLib.warning("RssArticleCache: Failed to clear cache: %s", errmsg);
            } else {
                // Vacuum to reclaim space
                db.exec("VACUUM;", null, null);
            }
        }
    }
}
