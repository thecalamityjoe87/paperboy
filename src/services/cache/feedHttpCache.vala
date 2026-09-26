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

namespace Paperboy {
    // Last body + ETag/Last-Modified per feed URL, so refetches can be conditional
    // and a 304 Not Modified is served from disk.
    public class FeedHttpCache : GLib.Object {
        private const int64 PRUNE_AFTER_SECONDS = 30 * 24 * 60 * 60;
        private static GLib.Mutex mutex;
        private static bool pruned = false;

        private static string cache_dir() {
            string dir = GLib.Path.build_filename(GLib.Environment.get_user_cache_dir(), "paperboy", "feeds");
            GLib.DirUtils.create_with_parents(dir, 0755);
            return dir;
        }

        private static string path_for(string url, string ext) {
            string key = GLib.Checksum.compute_for_string(GLib.ChecksumType.SHA1, url);
            return GLib.Path.build_filename(cache_dir(), key + ext);
        }

        // Validators are only returned when the body is on disk to fall back on.
        public static void get_validators(string url, out string? etag, out string? last_modified) {
            etag = null;
            last_modified = null;
            mutex.lock();
            if (GLib.FileUtils.test(path_for(url, ".xml"), GLib.FileTest.EXISTS)) {
                var kf = new GLib.KeyFile();
                try {
                    kf.load_from_file(path_for(url, ".meta"), GLib.KeyFileFlags.NONE);
                    if (kf.has_key("feed", "etag")) etag = kf.get_string("feed", "etag");
                    if (kf.has_key("feed", "last_modified")) last_modified = kf.get_string("feed", "last_modified");
                } catch (GLib.Error e) { }
            }
            mutex.unlock();
        }

        public static string? load_body(string url) {
            mutex.lock();
            string? body = null;
            try {
                GLib.FileUtils.get_contents(path_for(url, ".xml"), out body);
            } catch (GLib.Error e) {
                body = null;
            }
            mutex.unlock();
            return body;
        }

        // Returns whether the body differs from what was cached before.
        public static bool store(string url, string body, string? etag, string? last_modified) {
            mutex.lock();
            maybe_prune();
            string checksum = GLib.Checksum.compute_for_string(GLib.ChecksumType.SHA1, body);
            string meta_path = path_for(url, ".meta");
            var kf = new GLib.KeyFile();
            string? old_checksum = null;
            try {
                kf.load_from_file(meta_path, GLib.KeyFileFlags.NONE);
                if (kf.has_key("feed", "checksum")) old_checksum = kf.get_string("feed", "checksum");
            } catch (GLib.Error e) { }

            var fresh = new GLib.KeyFile();
            fresh.set_string("feed", "checksum", checksum);
            if (etag != null) fresh.set_string("feed", "etag", etag);
            if (last_modified != null) fresh.set_string("feed", "last_modified", last_modified);
            try {
                GLib.FileUtils.set_contents(path_for(url, ".xml"), body);
                fresh.save_to_file(meta_path);
            } catch (GLib.Error e) {
                GLib.warning("FeedHttpCache: failed to store %s: %s", url, e.message);
            }
            mutex.unlock();
            return old_checksum != checksum;
        }

        // Once per run: drop bodies not rewritten in a month (e.g. removed sources).
        private static void maybe_prune() {
            if (pruned) return;
            pruned = true;
            int64 cutoff = GLib.get_real_time() / 1000000 - PRUNE_AFTER_SECONDS;
            try {
                var dir = GLib.Dir.open(cache_dir());
                string? name;
                while ((name = dir.read_name()) != null) {
                    if (!name.has_suffix(".xml")) continue;
                    string path = GLib.Path.build_filename(cache_dir(), name);
                    try {
                        var info = GLib.File.new_for_path(path).query_info("time::modified", GLib.FileQueryInfoFlags.NONE);
                        if (info.get_modification_date_time().to_unix() < cutoff) {
                            GLib.FileUtils.remove(path);
                            GLib.FileUtils.remove(path.substring(0, path.length - 4) + ".meta");
                        }
                    } catch (GLib.Error e) { }
                }
            } catch (GLib.FileError e) { }
        }
    }
}
