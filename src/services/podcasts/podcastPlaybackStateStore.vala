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
        // Emitted when an episode's cover copy lands after its session was
        // already saved or restored (see download_cover()), so whatever's
        // showing that episode can switch to the local file.
        public signal void cover_saved(int64 episode_id, string path);

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
        // Episode whose cover is being downloaded directly (MetaCache didn't
        // have it) - one download per episode, and a late result for an
        // episode that's no longer current is discarded.
        private int64 cover_download_for_episode_id = -1;
        private int64 cover_wanted_episode_id = -1;

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
                CREATE TABLE IF NOT EXISTS podcast_last_queue (
                    position INTEGER PRIMARY KEY,
                    episode_id INTEGER NOT NULL,
                    feed_id INTEGER NOT NULL,
                    title TEXT,
                    audio_url TEXT NOT NULL,
                    image_url TEXT,
                    show_title TEXT,
                    duration_seconds INTEGER NOT NULL,
                    published TEXT
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

            string? local_cover_path = ensure_cover_saved(episode);

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

        // Returns this episode's dedicated on-disk cover, making it if needed.
        // A restored episode already points at its copy - adopted as-is,
        // since the cover was loaded from that copy rather than downloaded,
        // so MetaCache often no longer has it to copy again. Otherwise it's
        // copied from MetaCache, or downloaded directly if MetaCache doesn't
        // have it yet (that result lands later, see download_cover()).
        private string? ensure_cover_saved(Paperboy.PodcastEpisode episode) {
            cover_wanted_episode_id = episode.episode_id;
            if (episode.episode_id == cover_saved_for_episode_id
                    && cover_saved_path != null && GLib.FileUtils.test(cover_saved_path, GLib.FileTest.EXISTS)) {
                return cover_saved_path;
            }

            string? path = null;
            if (episode.cover_local_path != null && GLib.FileUtils.test(episode.cover_local_path, GLib.FileTest.EXISTS)) {
                path = episode.cover_local_path;
            } else {
                path = copy_cover_from_meta_cache(episode);
            }
            if (path == null) {
                download_cover(episode);
                return null;
            }
            adopt_cover(episode.episode_id, path);
            return path;
        }

        private void adopt_cover(int64 episode_id, string path) {
            cover_saved_path = path;
            cover_saved_for_episode_id = episode_id;
            remove_cover_files(path);
        }

        private static string? cover_dir() {
            string? data_dir = DataPathsUtils.get_user_data_dir();
            if (data_dir == null) return null;
            string dir = GLib.Path.build_filename(data_dir, "paperboy");
            if (!GLib.FileUtils.test(dir, GLib.FileTest.EXISTS)) GLib.DirUtils.create_with_parents(dir, 0755);
            return dir;
        }

        // Named per episode so desktop media controls, which cache art by
        // URI, never keep showing the previous episode's cover.
        private static string? cover_path_for(int64 episode_id, string ext) {
            string? dir = cover_dir();
            if (dir == null) return null;
            // Direct-feed episode ids can be negative.
            string id = episode_id.to_string().replace("-", "n");
            return GLib.Path.build_filename(dir, "last_session_cover-" + id + ext);
        }

        // Deletes every saved session cover except `keep` (null deletes all).
        private static void remove_cover_files(string? keep) {
            string? dir = cover_dir();
            if (dir == null) return;
            try {
                var d = GLib.Dir.open(dir);
                string? name;
                while ((name = d.read_name()) != null) {
                    if (!name.has_prefix("last_session_cover")) continue;
                    string p = GLib.Path.build_filename(dir, name);
                    if (keep == null || p != keep) GLib.FileUtils.remove(p);
                }
            } catch (GLib.FileError e) { }
        }

        // Copies whatever MetaCache already has on disk for this cover into
        // a dedicated, non-evictable file - MetaCache is a shared, capped
        // cache other browsing can push this exact file out of, so it's not
        // safe to just point the saved session at a MetaCache path directly.
        private static string? copy_cover_from_meta_cache(Paperboy.PodcastEpisode episode) {
            if (episode.image_url == null || episode.image_url.length == 0) return null;

            string? cached_path = MetaCache.get_instance().get_cached_path(episode.image_url);
            if (cached_path == null) return null;

            string basename = GLib.Path.get_basename(cached_path);
            int dot = basename.last_index_of(".");
            string? dest = cover_path_for(episode.episode_id, dot >= 0 ? basename.substring(dot) : "");
            if (dest == null) return null;
            try {
                GLib.File.new_for_path(cached_path).copy(GLib.File.new_for_path(dest), GLib.FileCopyFlags.OVERWRITE, null, null);
                return dest;
            } catch (GLib.Error e) {
                return null;
            }
        }

        // Fallback when MetaCache doesn't have the cover (yet): fetch it
        // straight into the dedicated file, so a session paused or closed
        // before any view happened to cache the cover still gets one.
        private void download_cover(Paperboy.PodcastEpisode episode) {
            if (episode.image_url == null || episode.image_url.length == 0) return;
            if (cover_download_for_episode_id == episode.episode_id) return;
            cover_download_for_episode_id = episode.episode_id;

            int64 episode_id = episode.episode_id;
            var options = new Paperboy.HttpClientUtils.RequestOptions().with_image_headers();
            Paperboy.HttpClientUtils.get_default().fetch_bytes(episode.image_url, options, (response) => {
                // Worker thread: only the file write happens here.
                string? written = null;
                if (response.is_success() && response.body != null && response.body.get_size() > 0) {
                    string? dest = cover_path_for(episode_id, extension_for(response.get_header("content-type")));
                    if (dest != null) {
                        try {
                            GLib.FileUtils.set_data(dest, response.body.get_data());
                            written = dest;
                        } catch (GLib.FileError e) { }
                    }
                }
                GLib.Idle.add(() => {
                    if (cover_download_for_episode_id == episode_id) cover_download_for_episode_id = -1;
                    if (written == null) return GLib.Source.REMOVE;
                    if (episode_id != cover_wanted_episode_id) {
                        GLib.FileUtils.remove(written);
                        return GLib.Source.REMOVE;
                    }
                    adopt_cover(episode_id, written);
                    set_last_session_cover(episode_id, written);
                    cover_saved(episode_id, written);
                    return GLib.Source.REMOVE;
                });
            });
        }

        private static string extension_for(string? content_type) {
            if (content_type == null) return ".jpg";
            string ct = content_type.split(";")[0].strip().ascii_down();
            switch (ct) {
                case "image/png": return ".png";
                case "image/webp": return ".webp";
                case "image/gif": return ".gif";
                case "image/avif": return ".avif";
                default: return ".jpg";
            }
        }

        private void set_last_session_cover(int64 episode_id, string path) {
            if (db == null) return;
            Sqlite.Statement stmt;
            if (db.prepare_v2("UPDATE podcast_last_session SET image_local_path = ? WHERE id = 1 AND episode_id = ?;", -1, out stmt) != Sqlite.OK) return;
            stmt.bind_text(1, path);
            stmt.bind_int64(2, episode_id);
            stmt.step();
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
            // No usable saved copy (never made, or since lost): make one now,
            // so the restored session isn't left on the network path.
            if (episode.cover_local_path == null) episode.cover_local_path = ensure_cover_saved(episode);

            var session = new Paperboy.PodcastLastSession();
            session.episode = episode;
            session.position_ns = (uint64) stmt.column_int64(7);
            session.rate = stmt.column_double(8);
            return session;
        }

        public void clear_last_session() {
            if (db == null) return;
            db.exec("DELETE FROM podcast_last_session; DELETE FROM podcast_last_queue;", null, null);
            cover_saved_for_episode_id = -1;
            cover_saved_path = null;
            cover_wanted_episode_id = -1;
            remove_cover_files(null);
        }

        // The playing show's episode list, so Next/Previous work right after a restart.
        public void save_last_queue(Gee.ArrayList<Paperboy.PodcastEpisode> episodes) {
            if (db == null) return;
            db.exec("BEGIN; DELETE FROM podcast_last_queue;", null, null);

            string sql = """
                INSERT INTO podcast_last_queue
                    (position, episode_id, feed_id, title, audio_url, image_url, show_title, duration_seconds, published)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """;
            Sqlite.Statement stmt;
            if (db.prepare_v2(sql, -1, out stmt) != Sqlite.OK) {
                GLib.warning("Failed to prepare statement: %s", db.errmsg());
                db.exec("ROLLBACK;", null, null);
                return;
            }
            for (int i = 0; i < episodes.size; i++) {
                var e = episodes[i];
                stmt.reset();
                stmt.bind_int(1, i);
                stmt.bind_int64(2, e.episode_id);
                stmt.bind_int64(3, e.feed_id);
                if (e.title != null) stmt.bind_text(4, e.title); else stmt.bind_null(4);
                stmt.bind_text(5, e.audio_url ?? "");
                if (e.image_url != null) stmt.bind_text(6, e.image_url); else stmt.bind_null(6);
                if (e.show_title != null) stmt.bind_text(7, e.show_title); else stmt.bind_null(7);
                stmt.bind_int64(8, e.duration_seconds);
                if (e.published != null) stmt.bind_text(9, e.published); else stmt.bind_null(9);
                if (stmt.step() != Sqlite.DONE) {
                    GLib.warning("Failed to save podcast queue: %s", db.errmsg());
                    db.exec("ROLLBACK;", null, null);
                    return;
                }
            }
            db.exec("COMMIT;", null, null);
        }

        public Gee.ArrayList<Paperboy.PodcastEpisode> get_last_queue() {
            var episodes = new Gee.ArrayList<Paperboy.PodcastEpisode>();
            if (db == null) return episodes;

            string sql = "SELECT episode_id, feed_id, title, audio_url, image_url, show_title, duration_seconds, published FROM podcast_last_queue ORDER BY position;";
            Sqlite.Statement stmt;
            if (db.prepare_v2(sql, -1, out stmt) != Sqlite.OK) return episodes;
            while (stmt.step() == Sqlite.ROW) {
                var e = new Paperboy.PodcastEpisode();
                e.episode_id = stmt.column_int64(0);
                e.feed_id = stmt.column_int64(1);
                e.title = stmt.column_text(2) ?? "";
                e.audio_url = stmt.column_text(3);
                e.image_url = stmt.column_text(4);
                e.show_title = stmt.column_text(5) ?? "";
                e.duration_seconds = stmt.column_int64(6);
                e.published = stmt.column_text(7);
                episodes.add(e);
            }
            return episodes;
        }
    }
}
