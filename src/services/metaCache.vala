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
using Gee;

public class MetaCache : GLib.Object {
    private string cache_dir_path;
    private string cache_dir;
    private string images_dir_path;
    // Maximum allowed cache size on disk. If the images folder exceeds this
    // size we perform a full clear() to avoid unbounded disk usage.
    private long max_total_bytes = 200 * 1024 * 1024; // 200 MB
    // In-memory set of meta file paths that have been observed as "viewed".
    // Populated asynchronously at startup to avoid blocking the main loop
    // when many articles are checked during UI construction.
    private Gee.HashSet<string> viewed_meta_paths;
    // Track meta paths currently being checked in background to avoid
    // spawning duplicate reader threads for the same file.
    private Gee.HashSet<string> pending_meta_checks;
    // Queue of URLs that need background meta checks. A single background
    // worker thread consumes this queue to avoid spawning many short-lived
    // threads when UI constructs a large list of articles.
    private Gee.ArrayList<string> meta_check_queue;
    // Condition variable used to signal the background worker when new
    // work is available.
    private Cond meta_cond = new Cond();
    // Mutex to protect the above sets from concurrent access.
    private Mutex meta_lock = new Mutex();

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
                // Clear only images, preserve metadata (viewed states)
                try { clear_images(); } catch (GLib.Error e) { }
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
    // Initialize in-memory sets
    viewed_meta_paths = new Gee.HashSet<string>();
    pending_meta_checks = new Gee.HashSet<string>();
    meta_check_queue = new Gee.ArrayList<string>();

    // Preload metadata directory synchronously to ensure viewed states are
    // available immediately when articles are first displayed. This prevents
    // a race condition where articles load before the background preload completes.
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
                // Use read_meta (which is defensive) to parse and handle corrupted files
                var kf = read_meta_from_path(full);
                if (kf != null) {
                    try {
                        string v = kf.get_string("meta", "viewed");
                        if (v == "1" || v.down() == "true") {
                            meta_lock_add_viewed(full);
                            stderr.printf("[PRELOAD] Added viewed path: %s\n", full);
                        }
                    } catch (GLib.Error e) { /* no viewed flag */ }
                }
            }
        } catch (GLib.Error e) {
            /* best-effort */
        } finally {
            if (en != null) try { en.close(null); } catch (GLib.Error e) { }
        }
    } catch (GLib.Error e) { }

    // Start a single persistent background worker that consumes
    // `meta_check_queue` items and performs read_meta() calls. This worker
    // runs continuously, so it stays as a dedicated thread (not pooled).
    new Thread<void*>("meta-worker", () => {
        while (true) {
            string? url_to_check = null;
            // Wait for work
            meta_lock.lock();
            try {
                while (meta_check_queue.size == 0) {
                    // Wait until new work arrives. Condition.wait will atomically
                    // release the lock and re-acquire it when woken.
                    try { meta_cond.wait(meta_lock); } catch (GLib.Error e) { }
                }
                // Pop first URL (capture remaining queue size for logging)
                url_to_check = meta_check_queue.remove_at(0);
                int remaining_queue = meta_check_queue.size;
                try { warning("MetaCache.worker: popped %s (remaining queued=%d)", url_to_check, remaining_queue); } catch (GLib.Error e) { }
            } finally {
                meta_lock.unlock();
            }

            if (url_to_check == null) continue;

            // Perform the non-locking part of the check: read and inspect the meta
            var kf = read_meta(url_to_check);
            string meta_path = meta_path_for(url_to_check);
            if (kf != null) {
                try {
                    string v = kf.get_string("meta", "viewed");
                    if (v == "1" || v.down() == "true") {
                        meta_lock_add_viewed(meta_path);
                    }
                } catch (GLib.Error e) { }
            }

            // Remove pending marker so future checks for this path can be enqueued
            meta_lock_remove_pending(meta_path);
        }
        return null;
    });
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

    // Helper: read a KeyFile directly from a meta file path (skips filename->url mapping)
    private KeyFile? read_meta_from_path(string meta_path) {
        if (!FileUtils.test(meta_path, FileTest.EXISTS)) return null;
        try {
            var meta_file = File.new_for_path(meta_path);
            try {
                var kf = new KeyFile();
                kf.load_from_file(meta_path, KeyFileFlags.NONE);
                return kf;
            } catch (GLib.Error e) {
                // Corrupt - remove
                try { FileUtils.remove(meta_path); } catch (GLib.Error ee) { }
                return null;
            }
        } catch (GLib.Error e) {
            return null;
        }
    }

    // Thread-safe helpers to manipulate viewed_meta_paths and pending_meta_checks
    private void meta_lock_add_viewed(string meta_path) {
        meta_lock.lock();
        try {
            viewed_meta_paths.add(meta_path);
        } finally {
            meta_lock.unlock();
        }
    }

    private bool meta_lock_has_viewed(string meta_path) {
        meta_lock.lock();
        try {
            return viewed_meta_paths.contains(meta_path);
        } finally {
            meta_lock.unlock();
        }
    }

    private bool meta_lock_try_add_pending(string meta_path) {
        meta_lock.lock();
        try {
            if (pending_meta_checks.contains(meta_path)) return false;
            pending_meta_checks.add(meta_path);
            return true;
        } finally {
            meta_lock.unlock();
        }
    }

    // Try to add a pending marker and enqueue a URL for background checking.
    // Returns true if the URL was enqueued (i.e. it wasn't already pending).
    private bool meta_lock_try_add_pending_and_enqueue(string meta_path, string url) {
        meta_lock.lock();
        try {
            if (pending_meta_checks.contains(meta_path)) return false;
            pending_meta_checks.add(meta_path);
            try { meta_check_queue.add(url); } catch (GLib.Error e) { }
            // Debug: log queue/pending sizes so we can observe if many items are being enqueued
            try { warning("MetaCache.enqueue: %s queued (pending=%d, queued=%d)", meta_path, pending_meta_checks.size, meta_check_queue.size); } catch (GLib.Error e) { }
            try { meta_cond.signal(); } catch (GLib.Error e) { }
            return true;
        } finally {
            meta_lock.unlock();
        }
    }

    private void meta_lock_remove_pending(string meta_path) {
        meta_lock.lock();
        try {
            try { pending_meta_checks.remove(meta_path); } catch (GLib.Error e) { }
        } finally {
            meta_lock.unlock();
        }
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
        // Defensive checks: detect obviously-broken or maliciously-large
        // metadata files that could lead to allocator issues when parsed.
        try {
            var meta_file = File.new_for_path(meta);
            try {
                var info = meta_file.query_info("standard::size", FileQueryInfoFlags.NONE, null);
                long size = (long) info.get_size();
                // If a .meta file is unreasonably large it is likely corrupt (e.g. binary image written
                // into it). Treat files > 1MB as corrupted and remove them to avoid heap/alloc crashes.
                const long MAX_META_SIZE = 1024 * 1024; // 1 MB
                if (size > MAX_META_SIZE) {
                    try { warning("MetaCache.read_meta: meta file too large (%d bytes), removing %s", (int)size, meta); } catch (GLib.Error ee) { }
                    try { FileUtils.remove(meta); } catch (GLib.Error e2) { }
                    return null;
                }
            } catch (GLib.Error e) {
                // Can't query size; continue and let KeyFile handle malformed contents.
            }

            var kf = new KeyFile();
            try {
                kf.load_from_file(meta, KeyFileFlags.NONE);
                return kf;
            } catch (GLib.Error e) {
                // If parsing fails, treat the file as corrupted: remove it so we don't
                // repeatedly try to parse a bad file and risk allocator corruption.
                try { warning("MetaCache.read_meta: failed to parse meta %s: %s -- removing corrupted file", meta, e.message); } catch (GLib.Error ee) { }
                try { FileUtils.remove(meta); } catch (GLib.Error e2) { }
                return null;
            }
        } catch (GLib.Error e) {
            // Any other filesystem error: log and return null (best-effort)
            try { warning("MetaCache.read_meta: unexpected error accessing %s: %s", meta, e.message); } catch (GLib.Error ee) { }
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
        // Ensure parent dirs exist (constructor already attempted, but be safe)
        try {
            DirUtils.create_with_parents(cache_dir_path, 0755);
            DirUtils.create_with_parents(images_dir_path, 0755);
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

    // Mark an article URL as viewed by setting a small flag in its metadata
    public void mark_viewed(string url) {
        string meta_path = meta_path_for(url);
        
        // Check if already marked to avoid unnecessary disk I/O
        if (meta_lock_has_viewed(meta_path)) {
            stderr.printf("[SAVE_VIEWED] Already marked, skipping: %s\n", meta_path);
            return;
        }
        
        try {
            var kf = read_meta(url);
            if (kf == null) kf = new KeyFile();
            long now_s = (long)(GLib.get_real_time() / 1000000);
            // Store under a 'meta' group to avoid colliding with cache-specific keys
            kf.set_string("meta", "viewed", "1");
            kf.set_string("meta", "viewed_at", "%d".printf((int)now_s));
            // Debug: log metadata path we will write to
            try { warning("MetaCache.mark_viewed: writing meta for %s", meta_path); } catch (GLib.Error e) { }
            stderr.printf("[SAVE_VIEWED] Path: %s | URL: %s\n", meta_path, url);
            write_meta(url, kf);
            // Update in-memory cache immediately so UI checks can see the change
            try { meta_lock_add_viewed(meta_path); } catch (GLib.Error e) { }
        } catch (GLib.Error e) {
            warning("Failed to mark viewed for %s: %s", url, e.message);
        }
    }

    // Return whether the given URL has been marked as viewed in its metadata
    public bool is_viewed(string url) {
        string meta = meta_path_for(url);
        try { warning("MetaCache.is_viewed: checking meta path %s", meta); } catch (GLib.Error e) { }
        bool has_it = meta_lock_has_viewed(meta);
        stderr.printf("[CHECK_VIEWED] Path: %s | URL: %s | Found: %s\n", meta, url, has_it ? "YES" : "NO");

        // Fast path: check our in-memory set that was preloaded (or updated
        // via mark_viewed). This avoids expensive disk IO on the main loop.
        if (has_it) return true;

        // If we don't have it in-memory, schedule a single background check
        // for this meta path (do not perform any disk IO on the main loop).
        // Return false for now; subsequent calls will find the cached value
        // once the background task completes.
        // Enqueue a single background check for this meta path (if not already pending).
        // The background worker will perform read_meta() and update the in-memory set.
        if (meta_lock_try_add_pending_and_enqueue(meta, url)) {
            // enqueued
        }

        return false;
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

    // Remove only cached image files but keep metadata (.meta) files.
    // This is useful when we want to evict large image blobs but preserve
    // small per-article metadata such as viewed flags across app restarts.
    public void clear_images() {
        try {
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
            // Attempt to remove the now-empty images directory
            try { FileUtils.remove(images_dir_path); } catch (GLib.Error e) { }
            
            // Also clean up old metadata files (older than 90 days) to prevent
            // unbounded growth, but preserve recent viewed states
            try { clean_old_metadata(90); } catch (GLib.Error e) { }
        } catch (GLib.Error e) {
            // Best-effort only; don't propagate
        }
    }
    
    // Remove metadata files older than the specified number of days.
    // This prevents unbounded metadata accumulation while preserving
    // recently viewed article states.
    private void clean_old_metadata(int days) {
        long cutoff_time = (long)(GLib.get_real_time() / 1000000) - (days * 24 * 60 * 60);
        
        try {
            var meta_dir = File.new_for_path(cache_dir_path);
            FileEnumerator? meta_enum = null;
            try {
                meta_enum = meta_dir.enumerate_children("standard::name,time::modified", FileQueryInfoFlags.NONE, null);
                FileInfo? info;
                while ((info = meta_enum.next_file(null)) != null) {
                    if (info.get_file_type() != FileType.REGULAR) continue;
                    string name = info.get_name();
                    if (!name.has_suffix(".meta")) continue;
                    
                    // Check file modification time
                    var modified_time = info.get_modification_date_time();
                    if (modified_time != null) {
                        int64 file_time = modified_time.to_unix();
                        if (file_time < cutoff_time) {
                            string full = Path.build_filename(cache_dir_path, name);
                            try { 
                                FileUtils.remove(full);
                                // Remove from in-memory cache too
                                try { viewed_meta_paths.remove(full); } catch (GLib.Error e) { }
                            } catch (GLib.Error e) { }
                        }
                    }
                }
            } catch (GLib.Error e) {
                // ignore
            } finally {
                if (meta_enum != null) try { meta_enum.close(null); } catch (GLib.Error e) { }
            }
        } catch (GLib.Error e) {
            // Best-effort
        }
    }

}
