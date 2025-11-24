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


/*
 * ArticleStateStore: manages only simple per-article metadata (viewed/favorite/timestamps)
 * No pixbufs, textures, widgets, or image URLs. Minimal, thread-safe helpers.
 */

 using GLib;
using Gee;

public class ArticleStateStore : GLib.Object {
    private string cache_dir_path;
    private string cache_dir;
    private Gee.HashSet<string> viewed_meta_paths;
    private Mutex meta_lock = new Mutex();

    public ArticleStateStore() {
        GLib.Object();
        var cache_base = Environment.get_user_cache_dir();
        if (cache_base == null) cache_base = "/tmp";
        cache_dir_path = Path.build_filename(cache_base, "paperboy", "metadata");
        try { DirUtils.create_with_parents(cache_dir_path, 0755); } catch (GLib.Error e) { }
        cache_dir = cache_dir_path;
        viewed_meta_paths = new Gee.HashSet<string>();
        // preload small metadata set: scan .meta files for viewed flag
        try {
            var meta_dir = File.new_for_path(cache_dir_path);
            FileEnumerator? en = null;
            try {
                en = meta_dir.enumerate_children("standard::name", FileQueryInfoFlags.NONE, null);
                FileInfo? info;
                while ((info = en.next_file(null)) != null) {
                    if (info.get_file_type() != FileType.REGULAR) continue;
                    string name = info.get_name();
                    if (!name.has_suffix(".meta")) continue;
                    string full = Path.build_filename(cache_dir_path, name);
                    var kf = read_meta_from_path(full);
                    if (kf != null) {
                        try {
                            string v = kf.get_string("meta", "viewed");
                            if (v == "1" || v.down() == "true") meta_lock_add_viewed(full);
                        } catch (GLib.Error e) { }
                    }
                }
            } catch (GLib.Error e) { } finally { if (en != null) try { en.close(null); } catch (GLib.Error _) { } }
        } catch (GLib.Error e) { }
    }

    private string filename_for_url(string url) {
        string u = url;
        if (u.length > 200) u = u.substring(u.length - 200);
        try {
            var re = new Regex("[^A-Za-z0-9._-]", RegexCompileFlags.DEFAULT);
            return re.replace(u, -1, 0, "_");
        } catch (GLib.RegexError e) {
            string out = "";
            for (uint i = 0; i < (uint)u.length; i++) {
                char c = u[i];
                if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-')
                    out += "%c".printf((int)c);
                else
                    out += "_";
            }
            return out;
        }
    }

    private string meta_path_for(string url) {
        string name = filename_for_url(url) + ".meta";
        return Path.build_filename(cache_dir_path, name);
    }

    private KeyFile? read_meta_from_path(string meta_path) {
        if (!FileUtils.test(meta_path, FileTest.EXISTS)) return null;
        try {
            var kf = new KeyFile();
            kf.load_from_file(meta_path, KeyFileFlags.NONE);
            return kf;
        } catch (GLib.Error e) {
            try { FileUtils.remove(meta_path); } catch (GLib.Error _) { }
            return null;
        }
    }

    private void write_meta_for_url(string url, KeyFile kf) {
        string meta = meta_path_for(url);
        try { kf.save_to_file(meta); } catch (GLib.Error e) { }
    }

    private void meta_lock_add_viewed(string meta_path) {
        meta_lock.lock();
        try { viewed_meta_paths.add(meta_path); } finally { meta_lock.unlock(); }
    }

    private bool meta_lock_has_viewed(string meta_path) {
        meta_lock.lock();
        try { return viewed_meta_paths.contains(meta_path); } finally { meta_lock.unlock(); }
    }

    // Public API
    public void mark_viewed(string url) {
        string meta_path = meta_path_for(url);
        if (meta_lock_has_viewed(meta_path)) return;
        try {
            var kf = read_meta_from_path(meta_path);
            if (kf == null) kf = new KeyFile();
            long now_s = (long)(GLib.get_real_time() / 1000000);
            kf.set_string("meta", "viewed", "1");
            kf.set_string("meta", "viewed_at", "%d".printf((int)now_s));
            write_meta_for_url(url, kf);
            meta_lock_add_viewed(meta_path);
        } catch (GLib.Error e) { }
    }

    public bool is_viewed(string url) {
        string meta = meta_path_for(url);
        bool has_it = meta_lock_has_viewed(meta);
        if (has_it) return true;
        // best-effort synchronous check for small set
        var kf = read_meta_from_path(meta);
        if (kf != null) {
            try { string v = kf.get_string("meta", "viewed"); if (v == "1" || v.down() == "true") { meta_lock_add_viewed(meta); return true; } } catch (GLib.Error e) { }
        }
        return false;
    }

    public bool is_favorite(string url) {
        var kf = read_meta_from_path(meta_path_for(url));
        if (kf == null) return false;
        try { string v = kf.get_string("meta", "favorite"); return (v == "1" || v.down() == "true"); } catch (GLib.Error e) { return false; }
    }

    public void set_favorite(string url, bool fav) {
        try {
            var kf = read_meta_from_path(meta_path_for(url));
            if (kf == null) kf = new KeyFile();
            kf.set_string("meta", "favorite", fav ? "1" : "0");
            write_meta_for_url(url, kf);
        } catch (GLib.Error e) { }
    }

    public void load_state() {
        // noop: constructor already preloaded viewed flags; expose for future use
    }

    public void save_state() {
        // noop: writes are atomic per-item via mark_viewed/set_favorite
    }
}
