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
* MagazineLibraryStore persists the user's magazine sources (websites
* scanned for PDF links) and library entries (imported PDFs) in a SQLite
* database, mirroring PodcastSubscriptionStore's structure/idiom.
* Database location: ~/.local/share/paperboy/magazines.db
*/

namespace Paperboy {

    public class MagazineLibraryStore : GLib.Object {
        public signal void source_added(Paperboy.MagazineSource source);
        public signal void source_removed(int64 source_id);
        public signal void entry_added(Paperboy.MagazineEntry entry);
        public signal void entry_removed(int64 entry_id);
        public signal void entry_updated(Paperboy.MagazineEntry entry);
        public signal void entries_reordered();

        private static MagazineLibraryStore? instance = null;
        private Sqlite.Database? db = null;
        private string db_path;

        private Gee.ArrayList<Paperboy.MagazineSource>? cached_sources = null;
        private Gee.ArrayList<Paperboy.MagazineEntry>? cached_entries = null;

        private MagazineLibraryStore() {
            db_path = get_database_path();
            init_database();

            source_added.connect(() => { cached_sources = null; });
            source_removed.connect(() => { cached_sources = null; });
            entry_added.connect(() => { cached_entries = null; });
            entry_removed.connect(() => { cached_entries = null; });
            entry_updated.connect(() => { cached_entries = null; });
            entries_reordered.connect(() => { cached_entries = null; });
        }

        public static MagazineLibraryStore get_instance() {
            if (instance == null) {
                instance = new MagazineLibraryStore();
            }
            return instance;
        }

        private string get_database_path() {
            var data_dir = GLib.Environment.get_user_data_dir();
            var paperboy_dir = GLib.Path.build_filename(data_dir, "paperboy");
            GLib.DirUtils.create_with_parents(paperboy_dir, 0755);
            return GLib.Path.build_filename(paperboy_dir, "magazines.db");
        }

        // Directory downloaded PDFs are saved into.
        public string get_pdf_dir() {
            var data_dir = GLib.Environment.get_user_data_dir();
            var dir = GLib.Path.build_filename(data_dir, "paperboy", "magazines");
            GLib.DirUtils.create_with_parents(dir, 0755);
            return dir;
        }

        // Directory first-page thumbnails are saved into.
        public string get_thumbnail_dir() {
            var data_dir = GLib.Environment.get_user_data_dir();
            var dir = GLib.Path.build_filename(data_dir, "paperboy", "magazine_thumbnails");
            GLib.DirUtils.create_with_parents(dir, 0755);
            return dir;
        }

        private void init_database() {
            int rc = Sqlite.Database.open(db_path, out db);
            if (rc != Sqlite.OK) {
                GLib.critical("Failed to open magazines database: %s", db.errmsg());
                db = null;
                return;
            }

            string create_sources = """
                CREATE TABLE IF NOT EXISTS magazine_sources (
                    id INTEGER PRIMARY KEY,
                    website_url TEXT NOT NULL UNIQUE,
                    name TEXT NOT NULL,
                    added_at INTEGER NOT NULL,
                    last_scanned_at INTEGER NOT NULL DEFAULT 0
                );
            """;
            string errmsg;
            rc = db.exec(create_sources, null, out errmsg);
            if (rc != Sqlite.OK) {
                GLib.critical("Failed to create magazine_sources table: %s", errmsg);
            }

            string create_entries = """
                CREATE TABLE IF NOT EXISTS magazine_entries (
                    id INTEGER PRIMARY KEY,
                    source_id INTEGER NOT NULL DEFAULT 0,
                    title TEXT NOT NULL,
                    source_url TEXT NOT NULL UNIQUE,
                    local_path TEXT NOT NULL,
                    thumbnail_path TEXT,
                    added_at INTEGER NOT NULL
                );
            """;
            rc = db.exec(create_entries, null, out errmsg);
            if (rc != Sqlite.OK) {
                GLib.critical("Failed to create magazine_entries table: %s", errmsg);
            }

            // Added after the initial release - existing databases need
            // this column added on top of their already-created table.
            db.exec("ALTER TABLE magazine_entries ADD COLUMN category TEXT;", null, null);
            db.exec("ALTER TABLE magazine_entries ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0;", null, null);
        }

        // Next free position at the FRONT of the manual drag-and-drop
        // order - new imports land ahead of everything already in the
        // library, not appended after it. get_all_entries() orders by
        // sort_order ASC, so this has to go lower than the current
        // minimum, not higher than the current maximum.
        private int64 next_sort_order() {
            if (db == null) return 0;
            string sql = "SELECT COALESCE(MIN(sort_order), 1) - 1 FROM magazine_entries;";
            Sqlite.Statement stmt;
            if (db.prepare_v2(sql, -1, out stmt) != Sqlite.OK) return 0;
            if (stmt.step() == Sqlite.ROW) return stmt.column_int64(0);
            return 0;
        }

        public bool source_exists(string website_url) {
            return get_source_by_url(website_url) != null;
        }

        public Paperboy.MagazineSource? get_source_by_url(string website_url) {
            if (db == null) return null;

            string sql = "SELECT id, website_url, name, added_at, last_scanned_at FROM magazine_sources WHERE website_url = ?;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) return null;
            stmt.bind_text(1, website_url);

            if (stmt.step() == Sqlite.ROW) {
                return source_from_row(stmt);
            }
            return null;
        }

        public bool add_source(Paperboy.MagazineSource source) {
            if (db == null) {
                GLib.warning("Database not initialized");
                return false;
            }

            var existing = get_source_by_url(source.website_url);
            if (existing != null) return true;

            string sql = """
                INSERT INTO magazine_sources (id, website_url, name, added_at, last_scanned_at)
                VALUES (?, ?, ?, ?, ?);
            """;
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("Failed to prepare statement: %s", db.errmsg());
                return false;
            }

            stmt.bind_int64(1, source.id);
            stmt.bind_text(2, source.website_url);
            stmt.bind_text(3, source.name);
            stmt.bind_int64(4, source.added_at);
            stmt.bind_int64(5, source.last_scanned_at);

            rc = stmt.step();
            if (rc != Sqlite.DONE) {
                GLib.warning("Failed to insert magazine source: %s", db.errmsg());
                return false;
            }

            source_added(source);
            return true;
        }

        public void update_last_scanned(int64 source_id) {
            if (db == null) return;
            string sql = "UPDATE magazine_sources SET last_scanned_at = ? WHERE id = ?;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) return;
            stmt.bind_int64(1, GLib.get_real_time() / 1000000);
            stmt.bind_int64(2, source_id);
            stmt.step();
            cached_sources = null;
        }

        // Removes the source and every entry that was discovered from it -
        // their downloaded PDFs/thumbnails are deleted from disk too.
        public bool remove_source(int64 source_id) {
            if (db == null) return false;

            foreach (var entry in get_entries_for_source(source_id)) {
                remove_entry(entry.id);
            }

            string sql = "DELETE FROM magazine_sources WHERE id = ?;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) return false;
            stmt.bind_int64(1, source_id);
            rc = stmt.step();
            if (rc != Sqlite.DONE) return false;

            source_removed(source_id);
            return true;
        }

        public Gee.ArrayList<Paperboy.MagazineSource> get_all_sources() {
            if (cached_sources != null) return cached_sources;

            var sources = new Gee.ArrayList<Paperboy.MagazineSource>();
            if (db == null) return sources;

            string sql = "SELECT id, website_url, name, added_at, last_scanned_at FROM magazine_sources ORDER BY added_at DESC;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) return sources;

            while (stmt.step() == Sqlite.ROW) {
                sources.add(source_from_row(stmt));
            }

            cached_sources = sources;
            return sources;
        }

        private Paperboy.MagazineSource source_from_row(Sqlite.Statement stmt) {
            var source = new Paperboy.MagazineSource();
            source.id = stmt.column_int64(0);
            source.website_url = stmt.column_text(1);
            source.name = stmt.column_text(2);
            source.added_at = stmt.column_int64(3);
            source.last_scanned_at = stmt.column_int64(4);
            return source;
        }

        public bool entry_exists_for_url(string source_url) {
            if (db == null) return false;
            string sql = "SELECT COUNT(*) FROM magazine_entries WHERE source_url = ?;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) return false;
            stmt.bind_text(1, source_url);
            if (stmt.step() == Sqlite.ROW) return stmt.column_int(0) > 0;
            return false;
        }

        public bool add_entry(Paperboy.MagazineEntry entry) {
            if (db == null) {
                GLib.warning("Database not initialized");
                return false;
            }

            if (entry_exists_for_url(entry.source_url)) return true;

            entry.sort_order = next_sort_order();

            string sql = """
                INSERT INTO magazine_entries (id, source_id, title, source_url, local_path, thumbnail_path, added_at, category, sort_order)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """;
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("Failed to prepare statement: %s", db.errmsg());
                return false;
            }

            stmt.bind_int64(1, entry.id);
            stmt.bind_int64(2, entry.source_id);
            stmt.bind_text(3, entry.title);
            stmt.bind_text(4, entry.source_url);
            stmt.bind_text(5, entry.local_path);
            if (entry.thumbnail_path != null) stmt.bind_text(6, entry.thumbnail_path); else stmt.bind_null(6);
            stmt.bind_int64(7, entry.added_at);
            if (entry.category != null && entry.category.length > 0) stmt.bind_text(8, entry.category); else stmt.bind_null(8);
            stmt.bind_int64(9, entry.sort_order);

            rc = stmt.step();
            if (rc != Sqlite.DONE) {
                GLib.warning("Failed to insert magazine entry: %s", db.errmsg());
                return false;
            }

            entry_added(entry);
            return true;
        }

        // Blank/null clears the category (back to "Uncategorized").
        public void update_category(int64 entry_id, string? category) {
            if (db == null) return;
            string sql = "UPDATE magazine_entries SET category = ? WHERE id = ?;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) return;
            if (category != null && category.strip().length > 0) stmt.bind_text(1, category.strip()); else stmt.bind_null(1);
            stmt.bind_int64(2, entry_id);
            if (stmt.step() != Sqlite.DONE) {
                GLib.warning("Failed to update magazine entry category: %s", db.errmsg());
                return;
            }

            cached_entries = null;
            var updated = get_entry(entry_id);
            if (updated != null) entry_updated(updated);
        }

        // Rewrites sort_order to 0..N-1 following ordered_ids exactly -
        // used after a drag-and-drop reorder, where the caller has already
        // computed the full desired display order for every entry
        // currently in the library (see MagazineLibraryManager's
        // reorder handling).
        public void reorder_entries(Gee.ArrayList<int64?> ordered_ids) {
            if (db == null) return;
            for (int i = 0; i < ordered_ids.size; i++) {
                string sql = "UPDATE magazine_entries SET sort_order = ? WHERE id = ?;";
                Sqlite.Statement stmt;
                if (db.prepare_v2(sql, -1, out stmt) != Sqlite.OK) continue;
                stmt.bind_int64(1, i);
                stmt.bind_int64(2, ordered_ids.get(i));
                stmt.step();
            }
            cached_entries = null;
            entries_reordered();
        }

        public bool remove_entry(int64 entry_id) {
            if (db == null) return false;

            var entry = get_entry(entry_id);

            string sql = "DELETE FROM magazine_entries WHERE id = ?;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) return false;
            stmt.bind_int64(1, entry_id);
            rc = stmt.step();
            if (rc != Sqlite.DONE) return false;

            if (entry != null) {
                try { GLib.File.new_for_path(entry.local_path).delete(); } catch (GLib.Error e) { }
                if (entry.thumbnail_path != null) {
                    try { GLib.File.new_for_path(entry.thumbnail_path).delete(); } catch (GLib.Error e) { }
                }
            }

            entry_removed(entry_id);
            return true;
        }

        public Paperboy.MagazineEntry? get_entry(int64 entry_id) {
            if (db == null) return null;
            string sql = "SELECT id, source_id, title, source_url, local_path, thumbnail_path, added_at, category, sort_order FROM magazine_entries WHERE id = ?;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) return null;
            stmt.bind_int64(1, entry_id);
            if (stmt.step() == Sqlite.ROW) return entry_from_row(stmt);
            return null;
        }

        public Gee.ArrayList<Paperboy.MagazineEntry> get_all_entries() {
            if (cached_entries != null) return cached_entries;

            var entries = new Gee.ArrayList<Paperboy.MagazineEntry>();
            if (db == null) return entries;

            // sort_order first (the manual drag-and-drop order), added_at
            // as a tiebreaker for legacy rows that all default to 0.
            string sql = "SELECT id, source_id, title, source_url, local_path, thumbnail_path, added_at, category, sort_order FROM magazine_entries ORDER BY sort_order ASC, added_at DESC;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) return entries;

            while (stmt.step() == Sqlite.ROW) {
                entries.add(entry_from_row(stmt));
            }

            cached_entries = entries;
            return entries;
        }

        public Gee.ArrayList<Paperboy.MagazineEntry> get_entries_for_source(int64 source_id) {
            var results = new Gee.ArrayList<Paperboy.MagazineEntry>();
            foreach (var entry in get_all_entries()) {
                if (entry.source_id == source_id) results.add(entry);
            }
            return results;
        }

        private Paperboy.MagazineEntry entry_from_row(Sqlite.Statement stmt) {
            var entry = new Paperboy.MagazineEntry();
            entry.id = stmt.column_int64(0);
            entry.source_id = stmt.column_int64(1);
            entry.title = stmt.column_text(2);
            entry.source_url = stmt.column_text(3);
            entry.local_path = stmt.column_text(4);
            entry.thumbnail_path = stmt.column_text(5);
            entry.added_at = stmt.column_int64(6);
            entry.category = stmt.column_text(7);
            entry.sort_order = stmt.column_int64(8);
            return entry;
        }
    }
}
