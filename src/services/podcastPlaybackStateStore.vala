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

    // Saved position/duration for one partially-listened episode - see
    // PodcastPlaybackStateStore.get_episode_progress().
    public class PodcastEpisodeProgress : GLib.Object {
        public uint64 position_ns;
        public uint64 duration_ns;
    }

    // The most recently loaded episode plus its playback position/rate -
    // enough to fully reconstruct a PodcastEpisode and resume it without a
    // network fetch (audio_url is stored directly). See
    // PodcastPlaybackStateStore.get_last_session().
    public class PodcastLastSession : GLib.Object {
        public Paperboy.PodcastEpisode episode;
        public uint64 position_ns;
        public double rate;
    }

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
        // save_last_session() runs every ~5s while playing (see
        // PodcastPlaybackManager.maybe_save_progress) - avoid re-copying the
        // same episode's cover on every one of those ticks.
        private int64 cover_saved_for_episode_id = -1;
        private string? cover_saved_path = null;

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
                CREATE TABLE IF NOT EXISTS podcast_episode_progress (
                    episode_id INTEGER PRIMARY KEY,
                    position_ns INTEGER NOT NULL,
                    duration_ns INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS podcast_last_session (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    episode_id INTEGER NOT NULL,
                    feed_id INTEGER NOT NULL,
                    title TEXT NOT NULL,
                    audio_url TEXT NOT NULL,
                    image_url TEXT,
                    show_title TEXT,
                    duration_seconds INTEGER NOT NULL,
                    position_ns INTEGER NOT NULL,
                    rate REAL NOT NULL
                );
            """;

            string errmsg;
            int rc2 = db.exec(create_tables, null, out errmsg);
            if (rc2 != Sqlite.OK) {
                GLib.critical("Failed to create podcast playback state tables: %s", errmsg);
            }

            // Older databases predate this column; add it, ignoring the error if it exists.
            db.exec("ALTER TABLE podcast_last_session ADD COLUMN image_local_path TEXT;", null, null);
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

        public void save_episode_progress(int64 episode_id, uint64 position_ns, uint64 duration_ns) {
            if (db == null) return;

            string sql = "INSERT OR REPLACE INTO podcast_episode_progress (episode_id, position_ns, duration_ns, updated_at) VALUES (?, ?, ?, ?);";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("Failed to prepare statement: %s", db.errmsg());
                return;
            }
            stmt.bind_int64(1, episode_id);
            stmt.bind_int64(2, (int64) position_ns);
            stmt.bind_int64(3, (int64) duration_ns);
            stmt.bind_int64(4, GLib.get_real_time() / 1000000);
            if (stmt.step() != Sqlite.DONE) {
                GLib.warning("Failed to save episode progress: %s", db.errmsg());
            }
        }

        public Paperboy.PodcastEpisodeProgress? get_episode_progress(int64 episode_id) {
            if (db == null) return null;

            string sql = "SELECT position_ns, duration_ns FROM podcast_episode_progress WHERE episode_id = ?;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) return null;
            stmt.bind_int64(1, episode_id);
            if (stmt.step() != Sqlite.ROW) return null;

            var progress = new Paperboy.PodcastEpisodeProgress();
            progress.position_ns = (uint64) stmt.column_int64(0);
            progress.duration_ns = (uint64) stmt.column_int64(1);
            return progress;
        }

        // Records "what's currently loaded" so it can be restored, paused,
        // on the next app launch (see NewsWindow's startup and
        // PodcastPlaybackManager.load_paused()). One row only (id = 1).
        public void save_last_session(Paperboy.PodcastEpisode episode, uint64 position_ns, double rate) {
            if (db == null) return;

            if (episode.episode_id != cover_saved_for_episode_id) {
                string? copied = save_cover_locally(episode.image_url);
                if (copied != null) {
                    cover_saved_path = copied;
                    cover_saved_for_episode_id = episode.episode_id;
                }
            }
            string? local_cover_path = episode.episode_id == cover_saved_for_episode_id ? cover_saved_path : null;

            string sql = """
                INSERT OR REPLACE INTO podcast_last_session
                    (id, episode_id, feed_id, title, audio_url, image_url, show_title, duration_seconds, position_ns, rate, image_local_path)
                VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """;
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("Failed to prepare statement: %s", db.errmsg());
                return;
            }
            stmt.bind_int64(1, episode.episode_id);
            stmt.bind_int64(2, episode.feed_id);
            stmt.bind_text(3, episode.title);
            stmt.bind_text(4, episode.audio_url);
            if (episode.image_url != null) stmt.bind_text(5, episode.image_url); else stmt.bind_null(5);
            stmt.bind_text(6, episode.show_title);
            stmt.bind_int64(7, episode.duration_seconds);
            stmt.bind_int64(8, (int64) position_ns);
            stmt.bind_double(9, rate);
            if (local_cover_path != null) stmt.bind_text(10, local_cover_path); else stmt.bind_null(10);
            if (stmt.step() != Sqlite.DONE) {
                GLib.warning("Failed to save last playback session: %s", db.errmsg());
            }
        }

        // Copies whatever MetaCache already has on disk for this cover into
        // a dedicated, non-evictable file - MetaCache is a shared, capped
        // cache other browsing can push this exact file out of, so it's not
        // safe to just point the saved session at a MetaCache path directly.
        private string? save_cover_locally(string? image_url) {
            if (image_url == null || image_url.length == 0) return null;

            string? cached_path = MetaCache.get_instance().get_cached_path(image_url);
            if (cached_path == null) return null;

            string? data_dir = DataPathsUtils.get_user_data_dir();
            if (data_dir == null) return null;
            string dir = GLib.Path.build_filename(data_dir, "paperboy");
            try {
                if (!GLib.FileUtils.test(dir, GLib.FileTest.EXISTS)) GLib.DirUtils.create_with_parents(dir, 0755);
            } catch (GLib.Error e) { return null; }

            string basename = GLib.Path.get_basename(cached_path);
            int dot = basename.last_index_of(".");
            string ext = dot >= 0 ? basename.substring(dot) : "";
            string dest = GLib.Path.build_filename(dir, "last_session_cover" + ext);
            try {
                var src_file = GLib.File.new_for_path(cached_path);
                var dest_file = GLib.File.new_for_path(dest);
                src_file.copy(dest_file, GLib.FileCopyFlags.OVERWRITE, null, null);
                return dest;
            } catch (GLib.Error e) {
                return null;
            }
        }

        public Paperboy.PodcastLastSession? get_last_session() {
            if (db == null) return null;

            string sql = "SELECT episode_id, feed_id, title, audio_url, image_url, show_title, duration_seconds, position_ns, rate, image_local_path FROM podcast_last_session WHERE id = 1;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) return null;
            if (stmt.step() != Sqlite.ROW) return null;

            var episode = new Paperboy.PodcastEpisode();
            episode.episode_id = stmt.column_int64(0);
            episode.feed_id = stmt.column_int64(1);
            episode.title = stmt.column_text(2);
            episode.audio_url = stmt.column_text(3);
            episode.image_url = stmt.column_text(4);
            episode.show_title = stmt.column_text(5);
            episode.duration_seconds = stmt.column_int64(6);
            string? local_path = stmt.column_text(9);
            episode.cover_local_path = (local_path != null && GLib.FileUtils.test(local_path, GLib.FileTest.EXISTS)) ? local_path : null;

            var session = new Paperboy.PodcastLastSession();
            session.episode = episode;
            session.position_ns = (uint64) stmt.column_int64(7);
            session.rate = stmt.column_double(8);
            return session;
        }

        public void clear_last_session() {
            if (db == null) return;
            db.exec("DELETE FROM podcast_last_session;", null, null);
        }
    }
}
