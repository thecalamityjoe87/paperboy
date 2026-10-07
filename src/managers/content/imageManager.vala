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

// Worker jobs are plain data objects rather than captured closures; queued
// closures were freed before they ran (use-after-free).
private class ImageDownloadJob : GLib.Object {
    public string url;
    public int target_w;
    public int target_h;
    public uint gen_seq;
    public int device_scale;
    public Soup.Session session;
    public MetaCache? meta_cache;
    public ImageCache? img_cache;
    public bool ignore_fetch_context = false;   // see load_image_async()
}

private class CachedImageJob : GLib.Object {
    public Gtk.Picture image;
    public string url;
    public int target_w;
    public int target_h;
    public int device_scale;
    public string disk_path;
    public ImageCache? img_cache;
    public bool ignore_fetch_context = false;
}

// Result of a download job. ok == false means "show the fallback placeholder".
private class DownloadOutcome : GLib.Object {
    public bool ok = false;
    public string? size_key;
    public Gdk.Pixbuf? pixbuf;
}

public class ImageManager : GLib.Object {
    public weak NewsWindow window;
    private Gee.HashMap<string, int> download_retry_counts;

    // Both pools are sized to NewsWindow.MAX_CONCURRENT_DOWNLOADS.
    private GLib.ThreadPool<ImageDownloadJob> download_pool;
    private GLib.ThreadPool<CachedImageJob> cached_load_pool;

    public Gee.HashMap<string, string> requested_image_sizes;
    public Gee.HashMap<string, Gee.ArrayList<Gtk.Picture>> pending_downloads;
    public Gee.HashMap<Gtk.Picture, DeferredRequest> deferred_downloads;
    public Gee.HashMap<Gtk.Picture, bool> pending_local_placeholder;
    public Gee.HashMap<Gtk.Picture, HeroRequest> hero_requests;
    public GLib.Mutex download_mutex;
    public uint deferred_check_timeout_id = 0;

    // URLs requested with ignore_fetch_context (e.g. podcast covers). They
    // aren't tied to any view, so cleanup and view switches never drop them.
    private Gee.HashSet<string> protected_download_urls;

    // THREADING: GTK widgets and the collections above are main-thread only.
    // Worker jobs (do_image_download, do_cached_image_load) only fetch and
    // decode, then hand the result back with exactly one Idle.add() - on
    // error paths too. Calling GTK from a worker thread caused crashes on
    // ordinary network errors. The sections below follow this split.

    // Max decoded size per side, after the HiDPI scale factor is applied.
    // Without it a 2400px request on a 2x/3x display would decode at 4800px+.
    private const int MAX_DECODE_DIM = 2400;

    // Requests this small (badges, logos) can share one "any size" cache
    // entry per URL - see set_any_key_thumb_if_larger().
    private const int THUMB_MAX_DIM = 64;

    public ImageManager(NewsWindow w) {
        window = w;
        download_retry_counts = new Gee.HashMap<string, int>();
        requested_image_sizes = new Gee.HashMap<string, string>();
        pending_downloads = new Gee.HashMap<string, Gee.ArrayList<Gtk.Picture>>();
        deferred_downloads = new Gee.HashMap<Gtk.Picture, DeferredRequest>();
        pending_local_placeholder = new Gee.HashMap<Gtk.Picture, bool>();
        hero_requests = new Gee.HashMap<Gtk.Picture, HeroRequest>();
        protected_download_urls = new Gee.HashSet<string>();
        download_mutex = new GLib.Mutex();

        try {
            download_pool = new GLib.ThreadPool<ImageDownloadJob>.with_owned_data((job) => {
                do_image_download(job);
            }, NewsWindow.MAX_CONCURRENT_DOWNLOADS, false);
            cached_load_pool = new GLib.ThreadPool<CachedImageJob>.with_owned_data((job) => {
                do_cached_image_load(job);
            }, NewsWindow.MAX_CONCURRENT_DOWNLOADS, false);
        } catch (GLib.ThreadError e) {
            warning("Failed to create image worker pools: %s", e.message);
        }
    }

    // ---- Helpers (safe on any thread) ----

    private static int clampi(int v, int lo, int hi) {
        if (v < lo) return lo;
        if (v > hi) return hi;
        return v;
    }

    private static bool is_thumb_size(int w, int h) {
        return w <= THUMB_MAX_DIM && h <= THUMB_MAX_DIM;
    }

    // Memory-cache key for `url` cropped to w x h. 0x0 is the "any size" entry.
    public static string make_cache_key(string url, int w, int h) {
        return "pixbuf::url:%s::%dx%d".printf(url, w, h);
    }

    // Cache key for preview textures.
    public static string make_preview_cache_key(string u, int w, int h) {
        return u + "@" + w.to_string() + "x" + h.to_string();
    }

    // The Guardian's CDN puts the width in the filename (/2000.jpg) and returns
    // 403 above 1000px, so always ask for 1000. Other URLs pass through.
    public static string download_url_for(string url) {
        if (url.index_of("media.guim.co.uk") < 0) return url;
        try {
            var regex = new Regex("/(\\d+)\\.(jpg|png|jpeg)$", RegexCompileFlags.CASELESS);
            return regex.replace(url, -1, 0, "/1000.\\2");
        } catch (GLib.RegexError e) {
            return url;
        }
    }

    // Upgrade pass size: double, capped at 1600px, but never smaller than the
    // original request (heroes are often requested above 1600 already).
    public static int upgraded_dimension(int last) {
        const int UPGRADE_MAX_DIM = 1600;
        return int.max(last, int.min(last * 2, UPGRADE_MAX_DIM));
    }

    private static ImageCache cache_or_global(ImageCache? cache) {
        return cache ?? ImageCache.get_global();
    }

    // Scales and center-crops to fill the target, caching under `size_key`.
    // Returns the original pixbuf if cropping fails.
    private static Gdk.Pixbuf crop_to_target(ImageCache cache, string size_key, Gdk.Pixbuf pixbuf, int target_w, int target_h, int device_scale) {
        var cropped = cache.get_or_scale_and_crop_pixbuf(size_key, pixbuf,
            clampi(target_w * device_scale, 1, MAX_DECODE_DIM),
            clampi(target_h * device_scale, 1, MAX_DECODE_DIM));
        return cropped ?? pixbuf;
    }

    // Decodes a disk-cached file at full size (shared by all requested sizes)
    // and crops it. Null if it can't be decoded.
    private static Gdk.Pixbuf? load_file_cropped(ImageCache cache, string path, string size_key, int target_w, int target_h, int device_scale) {
        string file_key = "pixbuf::file:%s::%dx%d".printf(path, 0, 0);
        var loaded = cache.get_or_load_file(file_key, path, 0, 0);
        if (loaded == null) return null;
        return crop_to_target(cache, size_key, loaded, target_w, target_h, device_scale);
    }

    // ---- Worker threads ----

    // HTTP fetch, disk-cache write, decode and crop.
    private DownloadOutcome fetch_and_decode(ImageDownloadJob job) {
        var outcome = new DownloadOutcome();
        string url = job.url;
        var cache = cache_or_global(job.img_cache);
        string size_key = make_cache_key(url, job.target_w, job.target_h);
        Gdk.Pixbuf? result = null;

        try {
            var client = Paperboy.HttpClientUtils.get_default();
            var options = new Paperboy.HttpClientUtils.RequestOptions().with_image_headers();
            var http_response = client.fetch_sync(download_url_for(url), options);

            uint status = http_response.status_code;
            GLib.Bytes? body = http_response.body;
            int64 length = (body != null) ? (int64) body.get_size() : 0;
            var meta_cache = job.meta_cache;

            if (status == Soup.Status.NOT_MODIFIED) {
                // Use the disk copy, cropped to this job's size.
                if (meta_cache == null) return outcome;
                meta_cache.touch(url);
                var path = meta_cache.get_cached_path(url);
                if (path == null) return outcome;
                result = load_file_cropped(cache, path, size_key, job.target_w, job.target_h, job.device_scale);
            } else if (status == Soup.Status.OK && length > 0 && body != null) {
                unowned uint8[] body_data = body.get_data();
                uint8[] data = new uint8[body_data.length];
                Memory.copy(data, body_data, body_data.length);

                if (meta_cache != null) {
                    meta_cache.write_cache(url, data, http_response.get_header("etag"),
                        http_response.get_header("last-modified"), http_response.get_header("content-type"));
                }

                var loader = new Gdk.PixbufLoader();
                loader.write(data);
                loader.close();
                var pixbuf = loader.get_pixbuf();
                if (pixbuf != null) result = crop_to_target(cache, size_key, pixbuf, job.target_w, job.target_h, job.device_scale);
            }
        } catch (GLib.Error e) {
            // Network or decode failure: outcome.ok stays false.
        }

        if (result != null) {
            outcome.ok = true;
            outcome.size_key = size_key;
            outcome.pixbuf = result;
        }
        return outcome;
    }

    private void do_image_download(ImageDownloadJob job) {
        GLib.AtomicInt.inc(ref NewsWindow.active_downloads);
        try {
            string url = job.url;
            int target_w = job.target_w;
            int target_h = job.target_h;
            uint gen_seq = job.gen_seq;
            bool ignore_fetch_context = job.ignore_fetch_context;

            var outcome = fetch_and_decode(job);
            Idle.add(() => {
                deliver_download_outcome(url, target_w, target_h, gen_seq, outcome, ignore_fetch_context);
                return false;
            });
        } finally {
            GLib.AtomicInt.dec_and_test(ref NewsWindow.active_downloads);
        }
    }

    // Decodes a disk-cached image; falls back to the network if that fails.
    private void do_cached_image_load(CachedImageJob job) {
        Gtk.Picture image = job.image;
        string url = job.url;
        int target_w = job.target_w;
        int target_h = job.target_h;
        bool ignore_fetch_context = job.ignore_fetch_context;
        var cache = cache_or_global(job.img_cache);
        string size_key = make_cache_key(url, target_w, target_h);

        Gdk.Pixbuf? pix = load_file_cropped(cache, job.disk_path, size_key, target_w, target_h, job.device_scale);
        if (pix != null) {
            Gdk.Pixbuf ready = pix;
            Idle.add(() => {
                store_decoded(cache, url, target_w, target_h, size_key, ready);
                show_texture(image, cache, size_key, ready);
                notify_loaded(image);
                return false;
            });
            return;
        }

        Idle.add(() => {
            network_fallback(image, url, target_w, target_h, ignore_fetch_context);
            return false;
        });
    }

    // ---- Main thread ----

    // The window's cache, or the global one before the window has created it.
    private ImageCache active_cache() {
        return window.image_cache ?? ImageCache.get_global();
    }

    private void notify_loaded(Gtk.Picture pic) {
        if (window.loading_state != null) window.loading_state.on_image_loaded(pic);
    }

    // Shows `pixbuf` via the cached texture for `key`, creating and
    // registering one if needed (an untracked texture would never be freed).
    private static void show_texture(Gtk.Picture image, ImageCache cache, string key, Gdk.Pixbuf pixbuf) {
        var tex = cache.get_texture(key);
        if (tex == null) {
            tex = Gdk.Texture.for_pixbuf(pixbuf);
            cache.set_texture(key, tex);
        }
        image.set_paintable(tex);
    }

    // Caches a finished decode; small ones also go to the "any size" entry.
    private void store_decoded(ImageCache cache, string url, int target_w, int target_h, string size_key, Gdk.Pixbuf pixbuf) {
        cache.set(size_key, pixbuf);
        if (is_thumb_size(target_w, target_h)) set_any_key_thumb_if_larger(url, pixbuf);
    }

    // Only replaces the "any size" entry with a larger image, so a 20px badge
    // can't downgrade the 44px logo another view still needs.
    private void set_any_key_thumb_if_larger(string url, Gdk.Pixbuf pixbuf) {
        var cache = active_cache();
        string any_key = make_cache_key(url, 0, 0);
        var existing = cache.get(any_key);
        if (existing != null && existing.get_width() >= pixbuf.get_width() && existing.get_height() >= pixbuf.get_height()) return;
        cache.set(any_key, pixbuf);
    }

    // Cache hit: paint immediately.
    private void paint_synchronously(Gtk.Picture image, string key, Gdk.Pixbuf pixbuf) {
        show_texture(image, active_cache(), key, pixbuf);
        notify_loaded(image);
        pending_local_placeholder.unset(image);
    }

    // Stored under both the raw and normalized URL; the upgrade pass looks up
    // the normalized one.
    private void remember_requested_size(string url, int w, int h) {
        string size = "%dx%d".printf(w, h);
        requested_image_sizes.set(url, size);
        string nkey = UrlUtils.normalize_article_url(url);
        if (nkey.length > 0) requested_image_sizes.set(nkey, size);
    }

    private void forget_requested_size(string url) {
        protected_download_urls.remove(url);
        requested_image_sizes.unset(url);
        string nkey = UrlUtils.normalize_article_url(url);
        if (nkey.length > 0) requested_image_sizes.unset(nkey);
    }

    // Placeholder for a failed load: local-news art if the picture was marked
    // for it, else the source's branding, else a plain gradient.
    private void set_fallback_placeholder_for(Gtk.Picture pic, int w, int h, string url) {
        if (pending_local_placeholder.has_key(pic) && pending_local_placeholder.get(pic)) {
            PlaceholderBuilder.set_local_placeholder_image(pic, w, h);
            pending_local_placeholder.unset(pic);
            return;
        }
        NewsSource source = window.infer_source_from_url(url);
        if (source == NewsSource.UNKNOWN) {
            PlaceholderBuilder.create_gradient_placeholder(pic, w, h);
        } else {
            PlaceholderBuilder.set_placeholder_image_for_source(pic, w, h, source);
        }
    }

    // Preview placeholder for callers without an ImageManager. Local-news art
    // is only used when a window is passed.
    public static void set_preview_placeholder(Gtk.Picture pic, int w, int h, NewsSource source, string? category_id = null, bool source_mapped = true, NewsWindow? window = null) {
        if (category_id == "local_news" && window != null) {
            PlaceholderBuilder.set_local_placeholder_image(pic, w, h);
        } else if (category_id == "local_news" || !source_mapped) {
            PlaceholderBuilder.create_gradient_placeholder(pic, w, h);
        } else {
            PlaceholderBuilder.set_placeholder_image_for_source(pic, w, h, source);
        }
    }

    // Queues one download for `url`; every picture waiting on it is painted
    // when it finishes. Everything the worker needs is copied into the job here.
    public void start_image_download_for_url(string url, int target_w, int target_h, bool ignore_fetch_context = false) {
        // Decode for the sharpest display among the waiting pictures.
        int device_scale = 1;
        var waiting = pending_downloads.get(url);
        if (waiting != null) {
            foreach (var pic in waiting) device_scale = int.max(device_scale, pic.get_scale_factor());
        }

        // A pool, not a thread per image: each new thread gets its own malloc
        // arena that glibc never returns, so memory grew steadily.
        var job = new ImageDownloadJob();
        job.url = url;
        job.target_w = target_w;
        job.target_h = target_h;
        job.gen_seq = FetchContext.current;
        job.device_scale = device_scale;
        job.session = window.session;
        job.meta_cache = window.meta_cache;
        job.img_cache = window.image_cache;
        job.ignore_fetch_context = ignore_fetch_context;
        try {
            download_pool.add(job);
        } catch (GLib.ThreadError e) {
            warning("Failed to queue image download: %s", e.message);
        }
    }

    // Drops the result if the user has switched views since the download
    // started, unless it isn't view-bound. protected_download_urls covers a
    // view-free request that joined a download a view-bound one started.
    private void deliver_download_outcome(string url, int target_w, int target_h, uint gen_seq, DownloadOutcome outcome, bool ignore_fetch_context = false) {
        if (!ignore_fetch_context && !protected_download_urls.contains(url) && FetchContext.current != gen_seq) {
            pending_downloads.unset(url);
            forget_requested_size(url);
            return;
        }
        deliver_to_pending(url, target_w, target_h, outcome.ok ? outcome.pixbuf : null, outcome.size_key);
    }

    // Paints every picture waiting on `url` and clears its bookkeeping.
    // A null pixbuf gives them all their fallback placeholder.
    private void deliver_to_pending(string url, int target_w, int target_h, Gdk.Pixbuf? pixbuf, string? size_key) {
        bool ok = pixbuf != null && size_key != null;
        var cache = active_cache();
        if (ok) store_decoded(cache, url, target_w, target_h, size_key, pixbuf);

        var list = pending_downloads.get(url);
        if (list != null) {
            foreach (var pic in list) {
                if (ok) {
                    show_texture(pic, cache, size_key, pixbuf);
                    pending_local_placeholder.unset(pic);
                } else {
                    set_fallback_placeholder_for(pic, target_w, target_h, url);
                }
                notify_loaded(pic);
            }
            pending_downloads.unset(url);
        }
        forget_requested_size(url);
    }

    private void fail_pending(string url, int target_w, int target_h) {
        deliver_to_pending(url, target_w, target_h, null, null);
    }

    // Starts the download if a slot is free, else retries every 150ms. Gives
    // up after 100 tries (~15s) in case active_downloads gets stuck.
    public void ensure_start_download(string url, int target_w, int target_h, bool ignore_fetch_context = false) {
        int cap = (window.loading_state != null && window.loading_state.initial_phase) ? NewsWindow.INITIAL_PHASE_MAX_CONCURRENT_DOWNLOADS : NewsWindow.MAX_CONCURRENT_DOWNLOADS;
        if (NewsWindow.active_downloads >= cap) {
            int retry_count = download_retry_counts.has_key(url) ? download_retry_counts.get(url) : 0;
            if (retry_count >= 100) {
                fail_pending(url, target_w, target_h);
                download_retry_counts.unset(url);
                return;
            }

            download_retry_counts.set(url, retry_count + 1);
            Timeout.add(150, () => { ensure_start_download(url, target_w, target_h, ignore_fetch_context); return false; });
            return;
        }
        download_retry_counts.unset(url);
        start_image_download_for_url(url, target_w, target_h, ignore_fetch_context);
    }

    // Loads `url` into `image`: memory cache, then disk cache, then network.
    // Hidden pictures wait until visible unless `force` is set.
    // ignore_fetch_context: for images not tied to the current view (e.g. the
    // podcast player cover), so a view switch doesn't discard them.
    public void load_image_async(Gtk.Picture image, string url, int target_w, int target_h, bool force = false, bool ignore_fetch_context = false) {
        if (!force && !image.get_visible()) {
            remember_requested_size(url, target_w, target_h);
            deferred_downloads.set(image, new DeferredRequest(url, target_w, target_h, ignore_fetch_context));
            schedule_deferred_check(1000);
            return;
        }

        var cache = active_cache();

        // Small requests can use the "any size" entry if it's big enough.
        if (is_thumb_size(target_w, target_h)) {
            string any_key = make_cache_key(url, 0, 0);
            var thumb_pb = cache.get(any_key);
            if (thumb_pb != null && thumb_pb.get_width() >= target_w && thumb_pb.get_height() >= target_h) {
                paint_synchronously(image, any_key, thumb_pb);
                return;
            }
        }

        string key = make_cache_key(url, target_w, target_h);
        var cached_pb = cache.get(key);
        if (cached_pb != null) {
            paint_synchronously(image, key, cached_pb);
            return;
        }

        if (window.meta_cache != null) {
            var disk_path = window.meta_cache.get_cached_path(url);
            if (disk_path != null) {
                // Decode off the main thread; inline decoding stutters on card-heavy views.
                var job = new CachedImageJob();
                job.image = image;
                job.url = url;
                job.target_w = target_w;
                job.target_h = target_h;
                job.device_scale = int.max(1, image.get_scale_factor());
                job.disk_path = disk_path;
                job.img_cache = window.image_cache;
                job.ignore_fetch_context = ignore_fetch_context;
                try {
                    cached_load_pool.add(job);
                } catch (GLib.ThreadError e) {
                    warning("Failed to queue cached image load: %s", e.message);
                    network_fallback(image, url, target_w, target_h, ignore_fetch_context);
                }
                return;
            }
        }

        network_fallback(image, url, target_w, target_h, ignore_fetch_context);
    }

    // Adds `image` to the waiters for `url`, starting a download if none is
    // in flight.
    private void network_fallback(Gtk.Picture image, string url, int target_w, int target_h, bool ignore_fetch_context = false) {
        // pending_downloads is main-thread only, so this lock is defensive.
        // try/finally keeps the early return from leaving it locked.
        download_mutex.lock();
        try {
            if (ignore_fetch_context) protected_download_urls.add(url);

            var existing = pending_downloads.get(url);
            if (existing != null) {
                existing.add(image);
                return;
            }

            var list = new Gee.ArrayList<Gtk.Picture>();
            list.add(image);
            pending_downloads.set(url, list);
            remember_requested_size(url, target_w, target_h);
        } finally {
            download_mutex.unlock();
        }

        // Callers already apply their multipliers (6x heroes, 3x cards); cap at 2400px.
        ensure_start_download(url, int.min(target_w, 2400), int.min(target_h, 2400), ignore_fetch_context);
    }

    // Article preview image: placeholder if there's no usable URL, else the
    // preview cache, else an async load at 3x.
    public void load_preview_image(Gtk.Picture pic, string? thumbnail_url, int img_w, int img_h, NewsSource source, string? category_id = null, bool source_mapped = true) {
        bool will_load_image = thumbnail_url != null &&
        thumbnail_url.length > 0 &&
        (thumbnail_url.has_prefix("http://") || thumbnail_url.has_prefix("https://"));

        if (!will_load_image) {
            set_preview_placeholder(pic, img_w, img_h, source, category_id, source_mapped, window);
            return;
        }

        int multiplier = 3;
        int target_w = img_w * multiplier;
        int target_h = img_h * multiplier;

        var texture = PreviewCacheManager.get_cache().get_texture(make_preview_cache_key(thumbnail_url, target_w, target_h));
        if (texture != null) {
            pic.set_paintable(texture);
            return;
        }

        if (category_id == "local_news") pending_local_placeholder.set(pic, true);
        load_image_async(pic, thumbnail_url, target_w, target_h, true);
    }

    // Over 100 pending downloads, drops about half (never protected URLs).
    public void cleanup_stale_downloads() {
        download_mutex.lock();
        const int MAX_PENDING_DOWNLOADS = 100;

        if (pending_downloads.size > MAX_PENDING_DOWNLOADS) {
            warning("cleanup_stale_downloads: pending_downloads size=%d exceeds limit, clearing oldest entries", pending_downloads.size);

            int to_remove = pending_downloads.size / 2;
            var keys_to_remove = new Gee.ArrayList<string>();

            int count = 0;
            foreach (var entry in pending_downloads.entries) {
                if (count >= to_remove) break;
                if (protected_download_urls.contains(entry.key)) continue;
                keys_to_remove.add(entry.key);
                count++;
            }

            foreach (var key in keys_to_remove) {
                pending_downloads.unset(key);
                requested_image_sizes.unset(key);
            }
        }
        download_mutex.unlock();
    }

    // On view switch (NewsWindow.cleanup_old_content()): forgets requests for
    // the old view. View-free ones are kept, or their pictures stay blank.
    public void clear_view_requests() {
        download_mutex.lock();
        try {
            var drop = new Gee.ArrayList<string>();
            foreach (var key in pending_downloads.keys) {
                if (!protected_download_urls.contains(key)) drop.add(key);
            }
            foreach (var key in drop) pending_downloads.unset(key);
        } finally {
            download_mutex.unlock();
        }

        var drop_sizes = new Gee.ArrayList<string>();
        foreach (var key in requested_image_sizes.keys) {
            if (!protected_download_urls.contains(key)) drop_sizes.add(key);
        }
        foreach (var key in drop_sizes) requested_image_sizes.unset(key);

        var drop_deferred = new Gee.ArrayList<Gtk.Picture>();
        foreach (var entry in deferred_downloads.entries) {
            if (!entry.value.ignore_fetch_context) drop_deferred.add(entry.key);
        }
        foreach (var pic in drop_deferred) deferred_downloads.unset(pic);

        hero_requests.clear();
        pending_local_placeholder.clear();
    }

    // Schedules one deferred-download pass unless one is pending. The id is
    // cleared first so the pass can schedule the next one itself.
    private void schedule_deferred_check(uint interval_ms) {
        if (deferred_check_timeout_id != 0) return;
        deferred_check_timeout_id = Timeout.add(interval_ms, () => {
            deferred_check_timeout_id = 0;
            process_deferred_downloads();
            return false;
        });
    }

    // Starts up to 5 deferred loads whose pictures are now visible.
    public void process_deferred_downloads() {
        const int MAX_BATCH = 5;

        var to_start = new Gee.ArrayList<Gtk.Picture>();
        foreach (var kv in deferred_downloads.entries) {
            if (to_start.size >= MAX_BATCH) break;
            if (kv.key.get_visible()) to_start.add(kv.key);
        }

        foreach (var pic in to_start) {
            var req = deferred_downloads.get(pic);
            if (req == null) continue;
            deferred_downloads.unset(pic);
            load_image_async(pic, req.url, req.w, req.h, true, req.ignore_fetch_context);
        }

        if (deferred_downloads.size > 0) schedule_deferred_check(1200);
    }

    // After the initial load, re-fetches images at higher resolution,
    // 3 at a time, one batch per second.
    public void upgrade_images_after_initial() {
        const int UPGRADE_BATCH_SIZE = 3;
        int processed = 0;

        if (window.view_state == null) return;
        var cache = active_cache();

        foreach (var kv in window.view_state.url_to_picture.entries) {
            string norm_url = kv.key;
            Gtk.Picture? pic = kv.value;
            if (pic == null) continue;

            var rec = requested_image_sizes.get(norm_url);
            if (rec == null || rec.length == 0) continue;
            string[] parts = rec.split("x");
            if (parts.length < 2) continue;
            int last_w = int.parse(parts[0]);
            int last_h = int.parse(parts[1]);

            int new_w = upgraded_dimension(last_w);
            int new_h = upgraded_dimension(last_h);
            if (new_w == last_w && new_h == last_h) continue;

            string? original = window.view_state.normalized_to_url.get(norm_url);
            bool has_large = cache.get(make_cache_key(norm_url, new_w, new_h)) != null;
            if (!has_large && original != null) has_large = cache.get(make_cache_key(original, new_w, new_h)) != null;

            if (has_large) continue;
            if (original == null) continue;
            load_image_async(pic, original, new_w, new_h);

            processed += 1;
            if (processed >= UPGRADE_BATCH_SIZE) {
                Timeout.add(1000, () => {
                    upgrade_images_after_initial();
                    return false;
                });
                return;
            }
        }
    }

    // Redraws every picture in the content area; images set while their
    // container was hidden otherwise don't render.
    public void refresh_visible_images() {
        var children = window.content_box.observe_children();
        for (uint i = 0; i < children.get_n_items(); i++) {
            var child = children.get_item(i);
            refresh_pictures_in_widget(child as Gtk.Widget);
        }
    }

    private void refresh_pictures_in_widget(Gtk.Widget? widget) {
        if (widget == null) return;

        if (widget is Gtk.Picture) {
            widget.queue_draw();
            return;
        }

        if (widget is Gtk.Box || widget is Gtk.Grid || widget is Adw.Clamp) {
            var current = widget.get_first_child();
            while (current != null) {
                refresh_pictures_in_widget(current);
                current = current.get_next_sibling();
            }
        }
    }
}
