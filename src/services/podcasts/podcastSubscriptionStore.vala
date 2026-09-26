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
* PodcastSubscriptionStore manages the user's subscribed podcast shows in a
* SQLite database, mirroring RssSourceStore's structure/idiom.
* Database location: ~/.local/share/paperboy/podcasts.db
*/

namespace Paperboy {

    public class PodcastSubscriptionStore : GLib.Object {
        public signal void subscription_added(Paperboy.PodcastSubscription subscription);
        public signal void subscription_removed(int64 feed_id);

        private static PodcastSubscriptionStore? instance = null;
        private Sqlite.Database? db = null;
        private string db_path;

        private Gee.ArrayList<Paperboy.PodcastSubscription>? cached_subscriptions = null;

        private PodcastSubscriptionStore() {
            db_path = get_database_path();
            init_database();

            subscription_added.connect(() => { cached_subscriptions = null; });
            subscription_removed.connect(() => { cached_subscriptions = null; });
        }

        public static PodcastSubscriptionStore get_instance() {
            if (instance == null) {
                instance = new PodcastSubscriptionStore();
            }
            return instance;
        }

        private string get_database_path() {
            var data_dir = GLib.Environment.get_user_data_dir();
            var paperboy_dir = GLib.Path.build_filename(data_dir, "paperboy");
            GLib.DirUtils.create_with_parents(paperboy_dir, 0755);
            return GLib.Path.build_filename(paperboy_dir, "podcasts.db");
        }

        private void init_database() {
            int rc = Sqlite.Database.open(db_path, out db);
            if (rc != Sqlite.OK) {
                GLib.critical("Failed to open podcasts database: %s", db.errmsg());
                db = null;
                return;
            }

            string create_table = """
                CREATE TABLE IF NOT EXISTS podcast_subscriptions (
                    feed_id INTEGER PRIMARY KEY,
                    title TEXT NOT NULL,
                    author TEXT,
                    image_url TEXT,
                    feed_url TEXT NOT NULL,
                    subscribed_at INTEGER NOT NULL
                );
            """;

            string errmsg;
            rc = db.exec(create_table, null, out errmsg);
            if (rc != Sqlite.OK) {
                GLib.critical("Failed to create podcast_subscriptions table: %s", errmsg);
            }

            // Added after the initial release - existing databases need this
            // column added on top of their already-created table.
            db.exec("ALTER TABLE podcast_subscriptions ADD COLUMN description TEXT;", null, null);
        }

        public bool is_subscribed(int64 feed_id) {
            if (db == null) return false;

            string sql = "SELECT COUNT(*) FROM podcast_subscriptions WHERE feed_id = ?;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("Failed to prepare statement: %s", db.errmsg());
                return false;
            }

            stmt.bind_int64(1, feed_id);
            rc = stmt.step();
            if (rc == Sqlite.ROW) {
                return stmt.column_int(0) > 0;
            }
            return false;
        }

        public bool subscribe(Paperboy.PodcastShow show) {
            if (db == null) {
                GLib.warning("Database not initialized");
                return false;
            }

            if (is_subscribed(show.feed_id)) {
                return true;
            }

            string sql = """
                INSERT INTO podcast_subscriptions (feed_id, title, author, image_url, feed_url, subscribed_at, description)
                VALUES (?, ?, ?, ?, ?, ?, ?);
            """;

            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("Failed to prepare statement: %s", db.errmsg());
                return false;
            }

            stmt.bind_int64(1, show.feed_id);
            stmt.bind_text(2, show.title);
            if (show.author != null) stmt.bind_text(3, show.author); else stmt.bind_null(3);
            if (show.image_url != null) stmt.bind_text(4, show.image_url); else stmt.bind_null(4);
            stmt.bind_text(5, show.feed_url);
            stmt.bind_int64(6, GLib.get_real_time() / 1000000);
            if (show.description != null) stmt.bind_text(7, show.description); else stmt.bind_null(7);

            rc = stmt.step();
            if (rc != Sqlite.DONE) {
                GLib.warning("Failed to insert podcast subscription: %s", db.errmsg());
                return false;
            }

            var subscription = new Paperboy.PodcastSubscription.from_show(show);
            subscription_added(subscription);
            return true;
        }

        // Backfills a description for a show that was subscribed before
        // descriptions were persisted (or was subscribed from a source that
        // didn't have one yet) - see PodcastPane's re-fetch-on-open logic.
        public void update_description(int64 feed_id, string description) {
            if (db == null) return;

            string sql = "UPDATE podcast_subscriptions SET description = ? WHERE feed_id = ?;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("Failed to prepare statement: %s", db.errmsg());
                return;
            }
            stmt.bind_text(1, description);
            stmt.bind_int64(2, feed_id);
            if (stmt.step() != Sqlite.DONE) {
                GLib.warning("Failed to update podcast subscription description: %s", db.errmsg());
                return;
            }
            cached_subscriptions = null;
        }

        public bool unsubscribe(int64 feed_id) {
            if (db == null) {
                GLib.warning("Database not initialized");
                return false;
            }

            string sql = "DELETE FROM podcast_subscriptions WHERE feed_id = ?;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("Failed to prepare statement: %s", db.errmsg());
                return false;
            }

            stmt.bind_int64(1, feed_id);
            rc = stmt.step();
            if (rc != Sqlite.DONE) {
                GLib.warning("Failed to delete podcast subscription: %s", db.errmsg());
                return false;
            }

            subscription_removed(feed_id);
            return true;
        }

        public Gee.ArrayList<Paperboy.PodcastSubscription> get_all_subscriptions() {
            if (cached_subscriptions != null) {
                return cached_subscriptions;
            }

            var subscriptions = new Gee.ArrayList<Paperboy.PodcastSubscription>();

            if (db == null) {
                GLib.warning("Database not initialized");
                return subscriptions;
            }

            string sql = "SELECT feed_id, title, author, image_url, feed_url, subscribed_at, description FROM podcast_subscriptions ORDER BY subscribed_at DESC;";
            Sqlite.Statement stmt;
            int rc = db.prepare_v2(sql, -1, out stmt);
            if (rc != Sqlite.OK) {
                GLib.warning("Failed to prepare statement: %s", db.errmsg());
                return subscriptions;
            }

            while (stmt.step() == Sqlite.ROW) {
                var subscription = new Paperboy.PodcastSubscription();
                subscription.feed_id = stmt.column_int64(0);
                subscription.title = stmt.column_text(1);
                subscription.author = stmt.column_text(2);
                subscription.image_url = stmt.column_text(3);
                subscription.feed_url = stmt.column_text(4);
                subscription.subscribed_at = stmt.column_int64(5);
                subscription.description = stmt.column_text(6);
                subscriptions.add(subscription);
            }

            subscriptions.sort((a, b) => { return SortUtils.compare_titles(a.title, b.title); });

            cached_subscriptions = subscriptions;
            return subscriptions;
        }
    }
}
