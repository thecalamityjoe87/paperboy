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

// Reading-time estimates (in minutes) for the article cards, keyed by
// normalized article URL. Filled from full-text RSS feeds at parse time
// and from any full article extraction (reader view, thumbnail backfill),
// preferring the site's own reported reading time when it has one.
public class ArticleReadingTimeCache : GLib.Object {
    // Below this, feed content is probably an excerpt rather than the full article.
    public const int MIN_FULL_TEXT_WORDS = 250;
    private const int WORDS_PER_MINUTE = 230;
    private const int MAX_AGE_DAYS = 30;

    private static ArticleReadingTimeCache? instance = null;
    private Sqlite.Database? db = null;
    private GLib.Mutex db_lock = GLib.Mutex();

    // Main thread only - see set_minutes().
    public signal void reading_time_changed(string normalized_url, int minutes);

    private ArticleReadingTimeCache() {
        string? cache_dir = GLib.Environment.get_user_cache_dir();
        if (cache_dir == null) return;

        string db_path = GLib.Path.build_filename(cache_dir, "paperboy", "article_reading_times.db");
        GLib.DirUtils.create_with_parents(GLib.Path.get_dirname(db_path), 0755);

        if (Sqlite.Database.open(db_path, out db) != Sqlite.OK) {
            GLib.warning("ArticleReadingTimeCache: failed to open database: %s", db != null ? db.errmsg() : "unknown error");
            db = null;
            return;
        }

        db.exec("""
            CREATE TABLE IF NOT EXISTS reading_times (
                url TEXT PRIMARY KEY,
                minutes INTEGER NOT NULL,
                recorded_at INTEGER NOT NULL
            );
        """, null, null);
        int64 cutoff = new GLib.DateTime.now_utc().to_unix() - MAX_AGE_DAYS * 86400;
        db.exec("DELETE FROM reading_times WHERE recorded_at < %s;".printf(cutoff.to_string()), null, null);
    }

    public static ArticleReadingTimeCache get_instance() {
        if (instance == null) instance = new ArticleReadingTimeCache();
        return instance;
    }

    public static int count_words(string plain_text) {
        int words = 0;
        bool in_word = false;
        unichar c;
        int i = 0;
        while (plain_text.get_next_char(ref i, out c)) {
            if (c.isspace()) {
                in_word = false;
            } else if (!in_word) {
                in_word = true;
                words++;
            }
        }
        return words;
    }

    // "5 min read", or "" if unknown.
    public static string label_for(int minutes) {
        return minutes > 0 ? "%d min read".printf(minutes) : "";
    }

    public static int minutes_for_words(int words) {
        return int.max(1, (words + WORDS_PER_MINUTE - 1) / WORDS_PER_MINUTE);
    }

    // 0 if unknown.
    public int get_minutes(string url) {
        if (db == null) return -1;
        string normalized = UrlUtils.normalize_article_url(url);
        db_lock.lock();
        int result = 0;
        Sqlite.Statement stmt;
        if (db.prepare_v2("SELECT minutes FROM reading_times WHERE url = ?;", -1, out stmt) == Sqlite.OK) {
            stmt.bind_text(1, normalized);
            if (stmt.step() == Sqlite.ROW) result = stmt.column_int(0);
        }
        db_lock.unlock();
        return result;
    }

    // Main thread; notifies any cards already showing this article.
    public void set_minutes(string url, int minutes) {
        if (db == null || minutes <= 0) return;
        string normalized = UrlUtils.normalize_article_url(url);
        if (get_minutes(normalized) == minutes) return;
        var batch = new Gee.HashMap<string, int>();
        batch.set(normalized, minutes);
        set_many(batch);
        reading_time_changed(normalized, minutes);
    }

    // Safe from worker threads (no signal emitted); one transaction per call.
    public void set_many(Gee.Map<string, int> counts) {
        if (db == null || counts.size == 0) return;
        int64 now = new GLib.DateTime.now_utc().to_unix();
        db_lock.lock();
        db.exec("BEGIN;", null, null);
        Sqlite.Statement stmt;
        if (db.prepare_v2("INSERT OR REPLACE INTO reading_times (url, minutes, recorded_at) VALUES (?, ?, ?);", -1, out stmt) == Sqlite.OK) {
            foreach (var entry in counts.entries) {
                stmt.reset();
                stmt.bind_text(1, UrlUtils.normalize_article_url(entry.key));
                stmt.bind_int(2, entry.value);
                stmt.bind_int64(3, now);
                stmt.step();
            }
        }
        db.exec("COMMIT;", null, null);
        db_lock.unlock();
    }
}
