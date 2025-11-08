/*
 * Copyright (C) 2025  Isaac Joseph <calamityjoe87@gmail.com>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

using GLib;

public class MetaCache : GLib.Object {
    private string cache_dir_path;
    private string cache_dir;
    private string images_dir_path;
    // Maximum allowed cache size on disk. If the images folder exceeds this
    // size we perform a full clear() to avoid unbounded disk usage.
    private long max_total_bytes = 200 * 1024 * 1024; // 200 MB

    // If the cache grows beyond `max_total_bytes`, clear it entirely.
    private void maybe_clear_if_oversized() {
        try {
            long total = 0;
            var images_dir = File.new_for_path(images_dir_path);
            FileEnumerator? enumerator = null;
            try {
                enumerator = images_dir.enumerate_children("standard::size", FileQueryInfoFlags.NONE, null);
                FileInfo? info;
                while ((info = enumerator.next_file(null)) != null) {
                    if (info.get_file_type() != FileType.REGULAR) continue;
                    total += (long) info.get_size();
                }
            } catch (GLib.Error e) {
                // If enumeration fails, don't clear (best-effort only)
                return;
            } finally {
                if (enumerator != null) try { enumerator.close(null); } catch (GLib.Error e) { }
            }

            if (total > max_total_bytes) {
                // Best-effort: clear everything
                try { clear(); } catch (GLib.Error e) { }
            }
        } catch (GLib.Error e) {
            // ignore
        }
    }

    public MetaCache() {
        var cache_base = Environment.get_user_cache_dir();
        if (cache_base == null) cache_base = "/tmp";
        cache_dir_path = Path.build_filename(cache_base, "paperboy", "metadata");
        try {
            DirUtils.create_with_parents(cache_dir_path, 0755);
        } catch (GLib.Error e) {
            warning("Failed to create cache dir %s: %s", cache_dir_path, e.message);
        }
        // Images are stored in a separate subdirectory to keep metadata separate
        images_dir_path = Path.build_filename(cache_dir_path, "images");
        try {
            DirUtils.create_with_parents(images_dir_path, 0755);
        } catch (GLib.Error e) {
            warning("Failed to create images cache dir %s: %s", images_dir_path, e.message);
        }

    cache_dir = cache_dir_path;
    }

    // Simple sanitization to produce reasonably short filenames from URL.
    private string filename_for_url(string url) {
        // Keep last 200 chars to avoid overly long filenames
        string u = url;
        if (u.length > 200) u = u.substring(u.length - 200);
        // Try a regex-based replace for safety and unicode correctness
        try {
            var re = new Regex("[^A-Za-z0-9._-]", RegexCompileFlags.DEFAULT);
            return re.replace(u, -1, 0, "_");
        } catch (GLib.RegexError e) {
            // Fallback to conservative byte-wise replacement
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

    // Return an existing cached image path (with a proper image extension) or
    // null if no cached image exists for the URL.
    private string? image_path_for(string url) {
        string base_name = filename_for_url(url);
        string[] exts = { ".webp", ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".tiff", ".avif" };
        foreach (var e in exts) {
            string p = Path.build_filename(images_dir_path, base_name + e);
            if (FileUtils.test(p, FileTest.EXISTS)) return p;
        }
        return null;
    }

    // Path to write an image for the given url with the chosen extension.
    private string image_write_path_for(string url, string ext) {
        string name = filename_for_url(url);
        // Avoid double extensions like "foo.jpg.jpg" or "foo.jpg.img" when
        // the sanitized filename already ends with the desired extension.
        if (name.has_suffix(ext))
            return Path.build_filename(images_dir_path, name);
        return Path.build_filename(images_dir_path, name + ext);
    }

    private string meta_path_for(string url) {
        string name = filename_for_url(url) + ".meta";
        return Path.build_filename(cache_dir_path, name);
    }

    // Return cached image path if exists else null
    public string? get_cached_path(string url) {
        string? p = image_path_for(url);
        if (p == null) return null;
        if (FileUtils.test(p, FileTest.EXISTS)) return p;
        return null;
    }

    // Read metadata from .meta using KeyFile; returns a dictionary-like KeyFile or null
    public KeyFile? read_meta(string url) {
        string meta = meta_path_for(url);
        if (!FileUtils.test(meta, FileTest.EXISTS)) return null;
        try {
            var kf = new KeyFile();
            kf.load_from_file(meta, KeyFileFlags.NONE);
            return kf;
        } catch (GLib.Error e) {
            warning("Failed to read meta %s: %s", meta, e.message);
            return null;
        }
    }

    private void write_meta(string url, KeyFile kf) {
        string meta = meta_path_for(url);
        try {
            kf.save_to_file(meta);
        } catch (GLib.Error e) {
            warning("Failed to write meta %s: %s", meta, e.message);
        }
    }

    // Atomically write image bytes and metadata (.jpg/.png/.webp/etc + .meta).
    // The caller should pass the Content-Type when available so we can pick
    // an appropriate file extension. If content_type is null or unknown we
    // will try to infer from the URL; otherwise we will not write a binary
    // image file.
    public void write_cache(string url, uint8[] data, string? etag, string? last_modified, string? content_type) {
        // Determine extension from content-type (strip params)
        string? ext = null;
        if (content_type != null) {
            string ct = content_type;
            int semi = ct.index_of(";");
            if (semi >= 0) ct = ct.substring(0, semi).strip();
            if (ct == "image/jpeg") ext = ".jpg";
            else if (ct == "image/png") ext = ".png";
            else if (ct == "image/webp") ext = ".webp";
            else if (ct == "image/gif") ext = ".gif";
            else if (ct == "image/svg+xml") ext = ".svg";
            else if (ct == "image/bmp") ext = ".bmp";
            else if (ct == "image/tiff") ext = ".tiff";
            else if (ct == "image/avif") ext = ".avif";
        }

    string? img = null;
    if (ext != null) img = image_write_path_for(url, ext);
        // Ensure parent dir exists (constructor already attempted, but be safe)
        try {
            DirUtils.create_with_parents(cache_dir_path, 0755);
        } catch (GLib.Error e) { /* best-effort */ }

        if (img != null) {
            try {
                var gfile = File.new_for_path(img);
                try {
                    // Replace the destination; 'etag' param not provided here.
                    var out_stream = gfile.replace(null, false, FileCreateFlags.REPLACE_DESTINATION, null);
                    try {
                        // Write all bytes and close the stream
                        size_t written = 0;
                        out_stream.write_all(data, out written, null);
                        out_stream.close(null);
                    } catch (GLib.Error e) {
                        warning("Failed to write image cache %s: %s", img, e.message);
                        try { out_stream.close(null); } catch (GLib.Error e) { }
                    }
                } catch (GLib.Error e) {
                    // Fall back: try creating (non-atomic) if replace not supported
                    try {
                        var out2 = gfile.create(FileCreateFlags.NONE, null);
                        size_t written2 = 0;
                        out2.write_all(data, out written2, null);
                        out2.close(null);
                    } catch (GLib.Error e2) {
                        warning("Failed to write image cache (fallback) %s: %s", img, e2.message);
                    }
                }
            } catch (GLib.Error e) {
                warning("Failed to open image cache path %s: %s", img, e.message);
            }
        } else {
            // No image file will be written for this URL (unknown/unsupported content type)
        }

        // Write metadata (ETag, Last-Modified, last_access, size)
        try {
            var kf = new KeyFile();
            if (etag != null) kf.set_string("cache", "etag", etag);
            if (last_modified != null) kf.set_string("cache", "last_modified", last_modified);
            long now_s = (long)(GLib.get_real_time() / 1000000);
            kf.set_string("cache", "last_access", "%d".printf((int)now_s));
            kf.set_string("cache", "size", "%d".printf((int)data.length));
            write_meta(url, kf);
            // If cache folder grew too large, clear it (best-effort) to avoid
            // unbounded disk usage between application runs.
            try { maybe_clear_if_oversized(); } catch (GLib.Error e) { }
        } catch (GLib.Error e) {
            warning("Failed to write cache meta for %s: %s", url, e.message);
        }
    }

    public void touch(string url) {
        var kf = read_meta(url);
        if (kf == null) return;
    long now_s = (long)(GLib.get_real_time() / 1000000);
    kf.set_string("cache", "last_access", "%d".printf((int)now_s));
        write_meta(url, kf);
    }

    // Eviction removed: cache is cleared on application exit instead.

    // Return etag and last_modified from meta if present (out params)
    public void get_etag_and_modified(string url, out string? etag, out string? last_modified) {
        etag = null;
        last_modified = null;
        var kf = read_meta(url);
        if (kf == null) return;
        try { etag = kf.get_string("cache", "etag"); } catch (GLib.Error e) { etag = null; }
        try { last_modified = kf.get_string("cache", "last_modified"); } catch (GLib.Error e) { last_modified = null; }
    }

    // Remove all cached images and metadata. Best-effort; used on application exit
    public void clear() {
        try {
            // Remove image files
            var images_dir = File.new_for_path(images_dir_path);
            FileEnumerator? img_enum = null;
            try {
                img_enum = images_dir.enumerate_children("standard::name", FileQueryInfoFlags.NONE, null);
                FileInfo? info;
                while ((info = img_enum.next_file(null)) != null) {
                    if (info.get_file_type() != FileType.REGULAR) continue;
                    string name = info.get_name();
                    string full = Path.build_filename(images_dir_path, name);
                    try { FileUtils.remove(full); } catch (GLib.Error e) { }
                }
            } catch (GLib.Error e) {
                // ignore
            } finally {
                if (img_enum != null) try { img_enum.close(null); } catch (GLib.Error e) { }
            }

            // Remove metadata files
            var meta_dir = File.new_for_path(cache_dir_path);
            FileEnumerator? meta_enum = null;
            try {
                meta_enum = meta_dir.enumerate_children("standard::name", FileQueryInfoFlags.NONE, null);
                FileInfo? minfo;
                while ((minfo = meta_enum.next_file(null)) != null) {
                    string mname = minfo.get_name();
                    string full = Path.build_filename(cache_dir_path, mname);
                    try { FileUtils.remove(full); } catch (GLib.Error e) { }
                }
            } catch (GLib.Error e) {
                // ignore
            } finally {
                if (meta_enum != null) try { meta_enum.close(null); } catch (GLib.Error e) { }
            }

            // Attempt to remove the now-empty directories
            try { FileUtils.remove(images_dir_path); } catch (GLib.Error e) { }
            try { FileUtils.remove(cache_dir_path); } catch (GLib.Error e) { }
        } catch (GLib.Error e) {
            // Best-effort only; don't propagate
        }
    }

}
