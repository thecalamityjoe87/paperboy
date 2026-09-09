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
* PodcastPlaybackStateStore tracks per-episode "played" state and per-show
* "last viewed" timestamps, mirroring ArticleStateStore's role for
* articles (SQLite-backed, signal-driven so UI updates live) but scoped
* narrowly to just this - subscriptions themselves stay in
* PodcastSubscriptionStore. Kept in its own database file rather than
* podcasts.db so this store's writes (frequent - every play, every show
* opened) never contend with PodcastSubscriptionStore's connection.
* Database location: ~/.local/share/paperboy/podcast_playback_state.db
*/
namespace Paperboy {

    public class PodcastPlaybackStateStore : GLib.Object {
        // Emitted whenever an episode's played state changes, so any
        // visible episode row can refresh its own styling immediately.
        public signal void episode_played_changed(int64 episode_id);
        // Emitted whenever a show's "last viewed" timestamp advances
        // (i.e. its episode list was just opened), so the sidebar badge
        // for that show can clear immediately.
        public signal void show_viewed(int64 feed_id);

        private static PodcastPlaybackStateStore? instance = null;
        private Sqlite.Database? db = null;
        private string db_path;

        private Gee.HashSet<int64?>? played_cache = null;
        private Gee.HashMap<int64?, int64?>? last_viewed_cache = null;

        private PodcastPlaybackStateStore() {
            db_path = get_database_path();
            init_database();
        }

        public static PodcastPlaybackStateStore get_instance() {
            if (instance == null) {
                instance = new PodcastPlaybackStateStore();
            }
            return instance;
        }

        private string get_database_path() {
            var data_dir = GLib.Environment.get_user_data_dir();
            var paperboy_dir = GLib.Path.build_filename(data_dir, "paperboy");
            GLib.DirUtils.create_with_parents(paperboy_dir, 0755);
            return GLib.Path.build_filename(paperboy_dir, "podcast_playback_state.db");
        }

        private void init_database() {
            int rc = Sqlite.Database.open(db_path, out db);
            if (rc != Sqlite.OK) {
                GLib.critical("Failed to open podcast playback state database: %s", db.errmsg());
                db = null;
                return;
            }

            string create_tables = """
                CREATE TABLE IF NOT EXISTS podcast_episode_played (
                    episode_id INTEGER PRIMARY KEY,
                    played_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS podcast_show_viewed (
                    feed_id INTEGER PRIMARY KEY,
                    last_viewed_at INTEGER NOT NULL
                );
            """;

            string errmsg;
            int rc2 = db.exec(create_tables, null, out errmsg);
            if (rc2 != Sqlite.OK) {
                GLib.critical("Failed to create podcast playback state tables: %s", errmsg);
            }
        }

        public bool is_episode_played(int64 episode_id) {
            if (played_cache != null) return played_cache.contains(episode_id);
            load_played_cache();
            return played_cache != null && played_cache.contains(episode_id);
        }

        public void mark_episode_played(int64 episode_id) {
            if (db == null) return;
            if (is_episode_played(episode_id)) return;

            string sql = "INSERT OR REPLACE INTO podcast_episode_played (episode_id, played_at) VALUES (?, ?);";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("Failed to prepare statement: %s", db.errmsg());
                return;
            }
            stmt.bind_int64(1, episode_id);
            stmt.bind_int64(2, GLib.get_real_time() / 1000000);
            if (stmt.step() != Sqlite.DONE) {
                GLib.warning("Failed to mark episode played: %s", db.errmsg());
                return;
            }

            if (played_cache != null) played_cache.add(episode_id);
            episode_played_changed(episode_id);
        }

        // See load_played_cache()'s comment - same boxed-int64-key issue
        // applies to Gee.HashMap<int64?, V>.
        private static Gee.HashMap<int64?, int64?> new_int64_keyed_map() {
            return new Gee.HashMap<int64?, int64?>((v) => { return (uint) v; }, (a, b) => { return a == b; });
        }

        private void load_played_cache() {
            // Gee.HashSet<int64?> without explicit hash/equal funcs defaults
            // to pointer identity on the boxed value, not value equality -
            // contains() would then never match even the exact value just
            // added, since each int64? is boxed fresh at the call site.
            played_cache = new Gee.HashSet<int64?>((v) => { return (uint) v; }, (a, b) => { return a == b; });
            if (db == null) return;

            string sql = "SELECT episode_id FROM podcast_episode_played;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) return;
            while (stmt.step() == Sqlite.ROW) {
                played_cache.add(stmt.column_int64(0));
            }
        }

        // 0 means "never viewed" - every episode counts as new for that show.
        public int64 get_last_viewed(int64 feed_id) {
            if (last_viewed_cache == null) load_last_viewed_cache();
            if (last_viewed_cache.has_key(feed_id)) return last_viewed_cache.get(feed_id);
            return 0;
        }

        // Records "now" as the last time this show's episode list was
        // opened - call once per open, after using the *previous* value
        // (via get_last_viewed()) to decide which episodes were new.
        public void mark_show_viewed(int64 feed_id) {
            if (db == null) return;
            int64 now = GLib.get_real_time() / 1000000;

            string sql = "INSERT OR REPLACE INTO podcast_show_viewed (feed_id, last_viewed_at) VALUES (?, ?);";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("Failed to prepare statement: %s", db.errmsg());
                return;
            }
            stmt.bind_int64(1, feed_id);
            stmt.bind_int64(2, now);
            if (stmt.step() != Sqlite.DONE) {
                GLib.warning("Failed to mark show viewed: %s", db.errmsg());
                return;
            }

            if (last_viewed_cache == null) last_viewed_cache = new Gee.HashMap<int64?, int64?>();
            last_viewed_cache.set(feed_id, now);
            show_viewed(feed_id);
        }

        private void load_last_viewed_cache() {
            last_viewed_cache = new_int64_keyed_map();
            if (db == null) return;

            string sql = "SELECT feed_id, last_viewed_at FROM podcast_show_viewed;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) return;
            while (stmt.step() == Sqlite.ROW) {
                last_viewed_cache.set(stmt.column_int64(0), stmt.column_int64(1));
            }
        }
    }
}
