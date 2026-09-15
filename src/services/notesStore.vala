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

// Manages user notes attached to article URLs in a SQLite database,
// mirroring PodcastSubscriptionStore's structure/idiom.
// Database location: ~/.local/share/paperboy/notes.db
namespace Paperboy {

    public class NotesStore : GLib.Object {
        public signal void note_added(Paperboy.ArticleNote note);
        public signal void note_updated(Paperboy.ArticleNote note);
        public signal void note_removed(string url, int64 note_id);

        private static NotesStore? instance = null;
        private Sqlite.Database? db = null;

        private NotesStore() {
            string db_path = get_database_path();
            init_database(db_path);
        }

        public static NotesStore get_instance() {
            if (instance == null) {
                instance = new NotesStore();
            }
            return instance;
        }

        private string get_database_path() {
            var data_dir = GLib.Environment.get_user_data_dir();
            var paperboy_dir = GLib.Path.build_filename(data_dir, "paperboy");
            GLib.DirUtils.create_with_parents(paperboy_dir, 0755);
            return GLib.Path.build_filename(paperboy_dir, "notes.db");
        }

        private void init_database(string db_path) {
            int rc = Sqlite.Database.open(db_path, out db);
            if (rc != Sqlite.OK) {
                GLib.critical("Failed to open notes database: %d", rc);
                db = null;
                return;
            }

            string create_table = """
                CREATE TABLE IF NOT EXISTS notes (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    url TEXT NOT NULL,
                    title TEXT NOT NULL,
                    content_html TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                );
            """;

            string errmsg;
            rc = db.exec(create_table, null, out errmsg);
            if (rc != Sqlite.OK) {
                GLib.critical("Failed to create notes table: %s", errmsg);
            }

            db.exec("CREATE INDEX IF NOT EXISTS idx_notes_url ON notes(url);", null, null);

            // Added after the initial release - existing databases need this
            // column added on top of their already-created table. Fails
            // harmlessly (and is ignored) if the column already exists.
            db.exec("ALTER TABLE notes ADD COLUMN quote TEXT;", null, null);
        }

        public Paperboy.ArticleNote? add_note(string url, string title, string content_html, string? quote = null) {
            if (db == null) return null;

            int64 now = GLib.get_real_time() / 1000000;
            string sql = """
                INSERT INTO notes (url, title, content_html, created_at, updated_at, quote)
                VALUES (?, ?, ?, ?, ?, ?);
            """;

            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("Failed to prepare insert note statement: %s", db.errmsg());
                return null;
            }

            stmt.bind_text(1, url);
            stmt.bind_text(2, title);
            stmt.bind_text(3, content_html);
            stmt.bind_int64(4, now);
            stmt.bind_int64(5, now);
            if (quote != null) stmt.bind_text(6, quote); else stmt.bind_null(6);

            rc = stmt.step();
            if (rc != Sqlite.DONE) {
                GLib.warning("Failed to insert note: %s", db.errmsg());
                return null;
            }

            int64 id = db.last_insert_rowid();
            var note = new Paperboy.ArticleNote(id, url, title, content_html, now, now, quote);
            note_added(note);
            return note;
        }

        public bool update_note(int64 id, string title, string content_html) {
            if (db == null) return false;

            int64 now = GLib.get_real_time() / 1000000;
            string sql = "UPDATE notes SET title = ?, content_html = ?, updated_at = ? WHERE id = ?;";

            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("Failed to prepare update note statement: %s", db.errmsg());
                return false;
            }

            stmt.bind_text(1, title);
            stmt.bind_text(2, content_html);
            stmt.bind_int64(3, now);
            stmt.bind_int64(4, id);

            rc = stmt.step();
            if (rc != Sqlite.DONE) {
                GLib.warning("Failed to update note: %s", db.errmsg());
                return false;
            }

            var updated = get_note(id);
            if (updated != null) note_updated(updated);
            return true;
        }

        public bool delete_note(int64 id) {
            if (db == null) return false;

            var existing = get_note(id);
            if (existing == null) return false;

            string sql = "DELETE FROM notes WHERE id = ?;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("Failed to prepare delete note statement: %s", db.errmsg());
                return false;
            }

            stmt.bind_int64(1, id);
            rc = stmt.step();
            if (rc != Sqlite.DONE) {
                GLib.warning("Failed to delete note: %s", db.errmsg());
                return false;
            }

            note_removed(existing.url, id);
            return true;
        }

        public Paperboy.ArticleNote? get_note(int64 id) {
            if (db == null) return null;

            string sql = "SELECT id, url, title, content_html, created_at, updated_at, quote FROM notes WHERE id = ?;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("Failed to prepare get note statement: %s", db.errmsg());
                return null;
            }

            stmt.bind_int64(1, id);
            if (stmt.step() != Sqlite.ROW) return null;

            return new Paperboy.ArticleNote(stmt.column_int64(0), stmt.column_text(1), stmt.column_text(2),
                stmt.column_text(3), stmt.column_int64(4), stmt.column_int64(5), stmt.column_text(6));
        }

        public Gee.ArrayList<Paperboy.ArticleNote> get_notes_for_url(string url) {
            var notes = new Gee.ArrayList<Paperboy.ArticleNote>();
            if (db == null) return notes;

            string sql = "SELECT id, url, title, content_html, created_at, updated_at, quote FROM notes WHERE url = ? ORDER BY updated_at DESC;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("Failed to prepare get notes statement: %s", db.errmsg());
                return notes;
            }

            stmt.bind_text(1, url);
            while (stmt.step() == Sqlite.ROW) {
                notes.add(new Paperboy.ArticleNote(stmt.column_int64(0), stmt.column_text(1), stmt.column_text(2),
                    stmt.column_text(3), stmt.column_int64(4), stmt.column_int64(5), stmt.column_text(6)));
            }
            return notes;
        }

        public Gee.ArrayList<Paperboy.ArticleNote> get_all_notes() {
            var notes = new Gee.ArrayList<Paperboy.ArticleNote>();
            if (db == null) return notes;

            string sql = "SELECT id, url, title, content_html, created_at, updated_at, quote FROM notes ORDER BY updated_at DESC;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("Failed to prepare get all notes statement: %s", db.errmsg());
                return notes;
            }

            while (stmt.step() == Sqlite.ROW) {
                notes.add(new Paperboy.ArticleNote(stmt.column_int64(0), stmt.column_text(1), stmt.column_text(2),
                    stmt.column_text(3), stmt.column_int64(4), stmt.column_int64(5), stmt.column_text(6)));
            }
            return notes;
        }

        public int get_note_count_for_url(string url) {
            if (db == null) return 0;

            string sql = "SELECT COUNT(*) FROM notes WHERE url = ?;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) return 0;

            stmt.bind_text(1, url);
            if (stmt.step() == Sqlite.ROW) return stmt.column_int(0);
            return 0;
        }
    }
}
