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
using GLib;

/*
* RssSourceStore manages custom RSS sources in a SQLite database.
* Database location: ~/.local/share/paperboy/sources.db
*/

namespace Paperboy {

    public class RssSourceStore : GLib.Object {
        // Signals emitted when sources are added/removed/updated so UI can react
        public signal void source_added(Paperboy.RssSource source);
        public signal void source_removed(Paperboy.RssSource source);
        public signal void source_updated(Paperboy.RssSource source);
        private static RssSourceStore? instance = null;
        private Sqlite.Database? db = null;
        private string db_path;

        private RssSourceStore() {
            db_path = get_database_path();
            init_database();
        }

        public static RssSourceStore get_instance() {
            if (instance == null) {
                instance = new RssSourceStore();
            }
            return instance;
        }

        private string get_database_path() {
            var data_dir = GLib.Environment.get_user_data_dir();
            var paperboy_dir = GLib.Path.build_filename(data_dir, "paperboy");

            // Ensure directory exists
            try {
                GLib.DirUtils.create_with_parents(paperboy_dir, 0755);
            } catch (GLib.Error e) {
                GLib.warning("Failed to create paperboy data directory: %s", e.message);
            }

            return GLib.Path.build_filename(paperboy_dir, "sources.db");
        }

        private void init_database() {
            int rc = Sqlite.Database.open(db_path, out db);
            if (rc != Sqlite.OK) {
                GLib.critical("Failed to open database: %s", db.errmsg());
                db = null;
                return;
            }

            // Create the rss_sources table if it doesn't exist
            string create_table = """
                CREATE TABLE IF NOT EXISTS rss_sources (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    url TEXT NOT NULL UNIQUE,
                    icon_filename TEXT,
                    favicon_url TEXT,
                    created_at INTEGER NOT NULL,
                    last_fetched_at INTEGER DEFAULT 0
                );
            """;

            string errmsg;
            rc = db.exec(create_table, null, out errmsg);
            if (rc != Sqlite.OK) {
                GLib.critical("Failed to create rss_sources table: %s", errmsg);
            }

            // Add favicon_url column if it doesn't exist (for existing databases)
            string add_column = "ALTER TABLE rss_sources ADD COLUMN favicon_url TEXT;";
            rc = db.exec(add_column, null, out errmsg);
            // Ignore error if column already exists
        }

        public bool add_source(string name, string url, string? icon_filename = null) {
            if (db == null) {
                GLib.warning("Database not initialized");
                return false;
            }

            // Normalize URL for comparison
            string normalized_url = normalize_feed_url(url);

            // Check if source already exists by normalized URL
            if (source_exists_normalized(normalized_url)) {
                GLib.warning("RSS source with URL already exists: %s", url);
                return false;
            }

            // Check if source with same name already exists
            if (source_exists_by_name(name)) {
                GLib.warning("RSS source with name already exists: %s", name);
                return false;
            }

            string sql = """
                INSERT INTO rss_sources (name, url, icon_filename, created_at)
                VALUES (?, ?, ?, ?);
            """;

            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("Failed to prepare statement: %s", db.errmsg());
                return false;
            }

            stmt.bind_text(1, name);
            stmt.bind_text(2, url);
            if (icon_filename != null) {
                stmt.bind_text(3, icon_filename);
            } else {
                stmt.bind_null(3);
            }
            stmt.bind_int64(4, GLib.get_real_time() / 1000000); // Convert to seconds

            rc = stmt.step();
            if (rc != Sqlite.DONE) {
                GLib.warning("Failed to insert RSS source: %s", db.errmsg());
                return false;
            }

            // Fetch the inserted source and emit a signal so UI can update
            var added = get_source_by_url(url);
            if (added != null) {
                try { source_added(added); } catch (GLib.Error e) { }
            }

            return true;
        }

        /**
         * Normalize a feed URL for comparison
         * Removes trailing slashes, fragments, and converts to lowercase
         */
        private string normalize_feed_url(string url) {
            string normalized = url.strip();

            // Remove trailing slash
            if (normalized.has_suffix("/")) {
                normalized = normalized.substring(0, normalized.length - 1);
            }

            // Remove URL fragments (#...)
            int fragment_pos = normalized.index_of("#");
            if (fragment_pos >= 0) {
                normalized = normalized.substring(0, fragment_pos);
            }

            // Remove query parameters for feed URLs (optional - can be disabled if needed)
            // Some feeds use query params, so we'll keep them for now

            // Convert to lowercase for case-insensitive comparison
            return normalized.down();
        }

        /**
         * Check if a source exists by normalized URL
         */
        private bool source_exists_normalized(string normalized_url) {
            if (db == null) return false;

            // Get all sources and check normalized URLs
            var sources = get_all_sources();
            foreach (var source in sources) {
                if (normalize_feed_url(source.url) == normalized_url) {
                    return true;
                }
            }
            return false;
        }

        /**
         * Check if a source exists by name (case-insensitive)
         */
        private bool source_exists_by_name(string name) {
            if (db == null) return false;

            string sql = "SELECT COUNT(*) FROM rss_sources WHERE LOWER(name) = LOWER(?);";            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("Failed to prepare statement: %s", db.errmsg());
                return false;
            }

            stmt.bind_text(1, name);
            rc = stmt.step();
            if (rc == Sqlite.ROW) {
                return stmt.column_int(0) > 0;
            }

            return false;
        }

        public bool source_exists(string url) {
            if (db == null) return false;

            string sql = "SELECT COUNT(*) FROM rss_sources WHERE url = ?;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("Failed to prepare statement: %s", db.errmsg());
                return false;
            }

            stmt.bind_text(1, url);
            rc = stmt.step();
            if (rc == Sqlite.ROW) {
                return stmt.column_int(0) > 0;
            }

            return false;
        }

        public bool remove_source(string url) {
            if (db == null) {
                GLib.warning("Database not initialized");
                return false;
            }

            // Get source details before deletion
            var source = get_source_by_url(url);
            if (source == null) {
                GLib.warning("Source not found for deletion: %s", url);
                return false;
            }

            // Delete from database
            string sql = "DELETE FROM rss_sources WHERE url = ?;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("Failed to prepare statement: %s", db.errmsg());
                return false;
            }

            stmt.bind_text(1, url);
            rc = stmt.step();
            if (rc != Sqlite.DONE) {
                GLib.warning("Failed to delete RSS source: %s", db.errmsg());
                return false;
            }

            // Clean up associated files and metadata
            cleanup_source_files(source);

            // Emit removal signal so UI can update
            try { source_removed(source); } catch (GLib.Error e) { }

            GLib.print("Successfully removed RSS source: %s\n", source.name);
            return true;
        }

        /**
         * Clean up files and metadata associated with a deleted source
         */
        private void cleanup_source_files(Paperboy.RssSource source) {
            var data_dir = GLib.Environment.get_user_data_dir();
            var logos_dir = GLib.Path.build_filename(data_dir, "paperboy", "source_logos");

            // Delete generated XML file if it's a file:// URL
            if (source.url.has_prefix("file://")) {
                string file_path = source.url.substring(7); // Remove "file://" prefix
                try {
                    var xml_file = GLib.File.new_for_path(file_path);
                    if (xml_file.query_exists()) {
                        xml_file.delete();
                        GLib.print("  ✓ Deleted generated feed: %s\n", GLib.Path.get_basename(file_path));
                    }
                } catch (Error e) {
                    GLib.warning("  ✗ Failed to delete generated feed file: %s", e.message);
                }
            }

            // Delete icon file if it exists
            if (source.icon_filename != null && source.icon_filename.length > 0) {
                string icon_path = GLib.Path.build_filename(logos_dir, source.icon_filename);
                try {
                    var file = GLib.File.new_for_path(icon_path);
                    if (file.query_exists()) {
                        file.delete();
                        GLib.print("  ✓ Deleted icon: %s\n", source.icon_filename);
                    }
                } catch (Error e) {
                    GLib.warning("  ✗ Failed to delete icon file: %s", e.message);
                }
            }

            // Clean up SourceMetadata cache
            // The SourceMetadata system uses source names as keys, so we attempt to remove by name
            try {
                // Try to extract host from URL for metadata cleanup
                string? host = UrlUtils.extract_host_from_url(source.url);
                if (host != null && host.length > 0) {
                    // Clean up metadata files
                    var meta_dir = GLib.Path.build_filename(data_dir, "paperboy", "source_meta");
                    string meta_filename = SourceMetadata.sanitize_filename(host) + ".meta";
                    string meta_path = GLib.Path.build_filename(meta_dir, meta_filename);
                    
                    var meta_file = GLib.File.new_for_path(meta_path);
                    if (meta_file.query_exists()) {
                        meta_file.delete();
                        GLib.print("  ✓ Deleted metadata: %s\n", meta_filename);
                    }
                }
            } catch (Error e) {
                GLib.warning("  ✗ Failed to clean up source metadata: %s", e.message);
            }
        }

        public Gee.ArrayList<RssSource> get_all_sources() {
            var sources = new Gee.ArrayList<RssSource>();

            if (db == null) {
                GLib.warning("Database not initialized");
                return sources;
            }

            string sql = "SELECT id, name, url, icon_filename, favicon_url, created_at, last_fetched_at FROM rss_sources ORDER BY name ASC;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("Failed to prepare statement: %s", db.errmsg());
                return sources;
            }

            while (stmt.step() == Sqlite.ROW) {
                int64 id = stmt.column_int64(0);
                string name = stmt.column_text(1);
                string url = stmt.column_text(2);
                string? icon_filename = stmt.column_text(3);
                string? favicon_url = stmt.column_text(4);
                int64 created_at = stmt.column_int64(5);
                int64 last_fetched_at = stmt.column_int64(6);

                var source = new RssSource.with_data(id, name, url, icon_filename, created_at, last_fetched_at);
                source.favicon_url = favicon_url;
                sources.add(source);
            }

            return sources;
        }

        public RssSource? get_source_by_url(string url) {
            if (db == null) {
                GLib.warning("Database not initialized");
                return null;
            }

            string sql = "SELECT id, name, url, icon_filename, favicon_url, created_at, last_fetched_at FROM rss_sources WHERE url = ?;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("Failed to prepare statement: %s", db.errmsg());
                return null;
            }

            stmt.bind_text(1, url);
            rc = stmt.step();
            if (rc == Sqlite.ROW) {
                int64 id = stmt.column_int64(0);
                string name = stmt.column_text(1);
                string url_val = stmt.column_text(2);
                string? icon_filename = stmt.column_text(3);
                string? favicon_url = stmt.column_text(4);
                int64 created_at = stmt.column_int64(5);
                int64 last_fetched_at = stmt.column_int64(6);

                var source = new RssSource.with_data(id, name, url_val, icon_filename, created_at, last_fetched_at);
                source.favicon_url = favicon_url;
                return source;
            }

            return null;
        }

        public bool update_last_fetched(string url) {
            if (db == null) {
                GLib.warning("Database not initialized");
                return false;
            }

            string sql = "UPDATE rss_sources SET last_fetched_at = ? WHERE url = ?;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("Failed to prepare statement: %s", db.errmsg());
                return false;
            }

            stmt.bind_int64(1, GLib.get_real_time() / 1000000); // Convert to seconds
            stmt.bind_text(2, url);

            rc = stmt.step();
            if (rc != Sqlite.DONE) {
                GLib.warning("Failed to update last_fetched_at: %s", db.errmsg());
                return false;
            }

            return true;
        }

        public bool update_source_icon(string url, string? icon_filename) {
            if (db == null) {
                GLib.warning("Database not initialized");
                return false;
            }

            string sql = "UPDATE rss_sources SET icon_filename = ? WHERE url = ?;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("Failed to prepare statement: %s", db.errmsg());
                return false;
            }

            if (icon_filename != null) {
                stmt.bind_text(1, icon_filename);
            } else {
                stmt.bind_null(1);
            }
            stmt.bind_text(2, url);

            rc = stmt.step();
            if (rc != Sqlite.DONE) {
                GLib.warning("Failed to update icon filename: %s", db.errmsg());
                return false;
            }

            // Emit an update notification for UI so icons can refresh
            var updated = get_source_by_url(url);
            if (updated != null) {
                try { source_updated(updated); } catch (GLib.Error e) { }
            }

            return true;
        }

        public bool update_favicon_url(string url, string? favicon_url) {
            if (db == null) {
                GLib.warning("Database not initialized");
                return false;
            }

            string sql = "UPDATE rss_sources SET favicon_url = ? WHERE url = ?;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("Failed to prepare statement: %s", db.errmsg());
                return false;
            }

            if (favicon_url != null) {
                stmt.bind_text(1, favicon_url);
            } else {
                stmt.bind_null(1);
            }
            stmt.bind_text(2, url);

            rc = stmt.step();
            if (rc != Sqlite.DONE) {
                GLib.warning("Failed to update favicon URL: %s", db.errmsg());
                return false;
            }

            return true;
        }
    }
}
