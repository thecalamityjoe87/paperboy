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

// Persists hero image URLs discovered by ThumbnailBackfillService (see that
// class), keyed by normalized article URL, so an article whose API feed
// gave no thumbnail only needs its page extracted once - later visits to
// the same feed reuse the stored URL instead of re-fetching/re-extracting.
public class DiscoveredThumbnailCache : GLib.Object {
    private static DiscoveredThumbnailCache? instance = null;
    private Sqlite.Database? db = null;

    private DiscoveredThumbnailCache() {
        string? cache_dir = GLib.Environment.get_user_cache_dir();
        if (cache_dir == null) return;

        string db_path = GLib.Path.build_filename(cache_dir, "paperboy", "discovered_thumbnails.db");
        string parent_dir = GLib.Path.get_dirname(db_path);
        if (!GLib.FileUtils.test(parent_dir, GLib.FileTest.EXISTS)) {
            GLib.DirUtils.create_with_parents(parent_dir, 0755);
        }

        int rc = Sqlite.Database.open(db_path, out db);
        if (rc != Sqlite.OK) {
            GLib.warning("DiscoveredThumbnailCache: failed to open database: %s", db != null ? db.errmsg() : "unknown error");
            db = null;
            return;
        }

        db.exec("""
            CREATE TABLE IF NOT EXISTS discovered_thumbnails (
                url TEXT PRIMARY KEY,
                thumbnail_url TEXT NOT NULL,
                discovered_at INTEGER NOT NULL
            );
        """, null, null);
    }

    public static DiscoveredThumbnailCache get_instance() {
        if (instance == null) instance = new DiscoveredThumbnailCache();
        return instance;
    }

    public string? get(string normalized_url) {
        if (db == null) return null;

        Sqlite.Statement stmt;
        int rc = db.prepare_v2("SELECT thumbnail_url FROM discovered_thumbnails WHERE url = ?;", -1, out stmt);
        if (rc != Sqlite.OK) return null;

        stmt.bind_text(1, normalized_url);
        string? result = stmt.step() == Sqlite.ROW ? stmt.column_text(0) : null;
        if (result != null && is_google_news_placeholder(normalized_url, result)) return null;
        return result;
    }

    public void set(string normalized_url, string thumbnail_url) {
        if (db == null) return;
        if (is_google_news_placeholder(normalized_url, thumbnail_url)) return;

        Sqlite.Statement stmt;
        int rc = db.prepare_v2("INSERT OR REPLACE INTO discovered_thumbnails (url, thumbnail_url, discovered_at) VALUES (?, ?, ?);", -1, out stmt);
        if (rc != Sqlite.OK) return;

        stmt.bind_text(1, normalized_url);
        stmt.bind_text(2, thumbnail_url);
        stmt.bind_int64(3, new GLib.DateTime.now_utc().to_unix());
        stmt.step();
    }

    // Undecoded Google News pages only expose Google's own logo as og:image.
    private static bool is_google_news_placeholder(string article_url, string thumbnail_url) {
        return article_url.contains("news.google.com") && thumbnail_url.contains("googleusercontent.com");
    }
}
