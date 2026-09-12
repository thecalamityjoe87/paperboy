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


// Plain data carried into the network-download worker pool, not a captured
// closure - the home-grown WorkerPool drops captured-closure ownership and
// use-after-frees once a queued job runs.
private class ImageDownloadJob : GLib.Object {
    public string url;
    public int target_w;
    public int target_h;
    public uint gen_seq;
    public int device_scale;
    public NewsSource news_src;
    public Soup.Session session;
    public MetaCache? meta_cache;
    public ImageCache? img_cache;
    // See ImageManager.load_image_async()'s ignore_fetch_context parameter -
    // skips the FetchContext staleness check in deliver_download_outcome()
    // for downloads that aren't tied to any particular news-article fetch
    // (e.g. the podcast mini player's cover art).
    public bool ignore_fetch_context = false;
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

// Worker-thread download result - plain data only, safe to build off-thread.
// `ok == false` means "show the fallback placeholder".
private class DownloadOutcome : GLib.Object {
    public bool ok = false;
    public string? size_key;
    public Gdk.Pixbuf? pixbuf;
}

public class ImageManager : GLib.Object {
    public weak NewsWindow window;
    private Gee.HashMap<string, int> download_retry_counts;

    // Bounded worker pools for image downloads/decodes, sized to match
    // NewsWindow.MAX_CONCURRENT_DOWNLOADS so this doesn't reduce load
    // throughput compared to the previous one-OS-thread-per-image approach.
    private GLib.ThreadPool<ImageDownloadJob> download_pool;
    private GLib.ThreadPool<CachedImageJob> cached_load_pool;

    // Download queue and state management (moved from appWindow)
    public Gee.HashMap<string, string> requested_image_sizes;
    public Gee.HashMap<string, Gee.ArrayList<Gtk.Picture>> pending_downloads;
    public Gee.HashMap<Gtk.Picture, DeferredRequest> deferred_downloads;
    public Gee.HashMap<Gtk.Picture, bool> pending_local_placeholder;
    public Gee.HashMap<Gtk.Picture, HeroRequest> hero_requests;
    public GLib.Mutex download_mutex;
    public uint deferred_check_timeout_id = 0;

    // ------------------------------------------------------------------
    // THREADING CONTRACT
    //
    // `download_pool` and `cached_load_pool` run their jobs on dedicated
    // worker threads. GTK widgets (Gtk.Picture and friends) and the Gee
    // collections above are not thread-safe and must only ever be touched
    // from the main thread. The methods below are split along that line
    // and named/commented accordingly:
    //
    //   - Methods marked "worker thread" (fetch_and_decode,
    //     apply_cover_crop) do pure computation - HTTP fetch, pixbuf
    //     decode/scale - and never reference a Gtk.Picture, a Gee
    //     collection field, or `window.loading_state`.
    //   - Methods marked "MAIN THREAD ONLY" do the opposite: they are the
    //     only code allowed to mutate pending_downloads/requested_image_
    //     sizes or call into GTK, and must only be invoked from a GLib
    //     main-loop callback (Idle.add/Timeout.add), never directly from
    //     a worker thread.
    //
    // Every worker-thread job function (do_image_download,
    // do_cached_image_load) does its computation, then makes exactly one
    // Idle.add() call to hand the result to a MAIN THREAD ONLY delivery
    // method - including on the error paths. Historically the error
    // paths here skipped that hand-off and called into GTK straight from
    // the worker thread, which is undefined behavior in GTK and is the
    // most likely cause of the segfaults this code used to produce under
    // ordinary network errors (timeouts, DNS failures, resets - ordinary
    // events, not edge cases). Keep new code on the correct side of this
    // line.
    // ------------------------------------------------------------------

    // Helper: when an image download fails or we need a fallback placeholder,
    // prefer the local placeholder for pictures that were marked as local-news.
    // MAIN THREAD ONLY.
    private void set_fallback_placeholder_for(Gtk.Picture pic, int w, int h, string url) {
        bool prefer_local = false;
        try {
            if (pending_local_placeholder != null && pending_local_placeholder.has_key(pic)) {
                prefer_local = pending_local_placeholder.get(pic);
            }
        } catch (GLib.Error e) { prefer_local = false; }

        if (prefer_local) {
            window.set_local_placeholder_image(pic, w, h);
            try { if (pending_local_placeholder != null) pending_local_placeholder.remove(pic); } catch (GLib.Error e) { }
        } else {
            NewsSource source = window.infer_source_from_url(url);
            // For unknown sources, use generic gradient placeholder instead of source branding
            if (source == NewsSource.UNKNOWN) {
                PlaceholderBuilder.create_gradient_placeholder(pic, w, h);
            } else {
                window.set_placeholder_image_for_source(pic, w, h, source);
            }
        }
    }

    public ImageManager(NewsWindow w) {
        window = w;
        download_retry_counts = new Gee.HashMap<string, int>();
        requested_image_sizes = new Gee.HashMap<string, string>();
        pending_downloads = new Gee.HashMap<string, Gee.ArrayList<Gtk.Picture>>();
        deferred_downloads = new Gee.HashMap<Gtk.Picture, DeferredRequest>();
        pending_local_placeholder = new Gee.HashMap<Gtk.Picture, bool>();
        hero_requests = new Gee.HashMap<Gtk.Picture, HeroRequest>();
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

    // Integer clamp helper (valac doesn't provide clampi by default)
    private static int clampi(int v, int lo, int hi) {
        if (v < lo) return lo;
        if (v > hi) return hi;
        return v;
    }

    // Hard ceiling on the pixel dimensions we'll ever decode/crop an image
    // to, applied *after* multiplying by device_scale. The 2400px clamp in
    // network_fallback() only bounds target_w/target_h before that
    // multiplication, so on a HiDPI (2x/3x) display the actual decode size
    // could otherwise reach 4800px+ per side - tens of megabytes for a
    // single hero image that's displayed under a megapixel.
    private const int MAX_DECODE_DIM = 2400;

    // Start a single download for a URL and update all registered targets when done.
    // MAIN THREAD ONLY (reads Gtk.Picture.get_scale_factor and window fields).
    public void start_image_download_for_url(string url, int target_w, int target_h, bool ignore_fetch_context = false) {
        // Capture a snapshot of main-thread-only data we need in the worker
        // so do_image_download() never has to dereference `window` or a
        // Gtk.Picture from a background thread.
        int device_scale = 1;
        var list_try = pending_downloads.get(url);
        if (list_try != null && list_try.size > 0) {
            foreach (var pic_obj in list_try) {
                try {
                    var pic = (Gtk.Picture) pic_obj;
                    int s = pic.get_scale_factor();
                    if (s > device_scale) device_scale = s;
                } catch (GLib.Error e) {
                    // ignore and continue
                }
            }
            if (device_scale < 1) device_scale = 1;
        }

        // Concurrency is already bounded by the caller (ensure_start_download
        // admits at most MAX_CONCURRENT_DOWNLOADS at a time). Run on the
        // bounded download_pool rather than a dedicated OS thread per
        // download: spawning a raw Thread per image causes glibc to hand out
        // a fresh malloc arena per thread, and those arenas are never
        // returned to the OS even after the thread exits, which showed up as
        // steady RSS growth over a browsing session.
        var job = new ImageDownloadJob();
        job.url = url;
        job.target_w = target_w;
        job.target_h = target_h;
        job.gen_seq = FetchContext.current;
        job.device_scale = device_scale;
        job.news_src = window.prefs.news_source;
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

    // Runs on the download_pool worker threads. Pure computation only: HTTP
    // fetch plus decode/scale/crop. Deliberately touches nothing that
    // requires the main thread - see the THREADING CONTRACT note above.
    private DownloadOutcome fetch_and_decode(ImageDownloadJob job) {
        var outcome = new DownloadOutcome();
        string url = job.url;
        int target_w = job.target_w;
        int target_h = job.target_h;
        int device_scale = job.device_scale;
        var meta_cache = job.meta_cache;
        var img_cache = job.img_cache;

        try {
            // Upgrade Guardian image URLs to request higher resolution for network download.
            // Guardian URLs end with /XXX.jpg where XXX is the width; their CDN allows
            // 1000px but returns 403 for larger sizes like 2000px/2400px.
            string download_url = url;
            if (url.index_of("media.guim.co.uk") >= 0) {
                try {
                    var regex = new Regex("/(\\d+)\\.(jpg|png|jpeg)$", RegexCompileFlags.CASELESS);
                    download_url = regex.replace(url, -1, 0, "/1000.\\2");
                } catch (GLib.Error e) {
                    // Regex error, use original URL
                }
            }

            var client = Paperboy.HttpClientUtils.get_default();
            var options = new Paperboy.HttpClientUtils.RequestOptions().with_image_headers();
            var http_response = client.fetch_sync(download_url, options);

            uint status = http_response.status_code;
            GLib.Bytes? body = http_response.body;
            int64 length = (body != null) ? (int64) body.get_size() : 0;

            if (job.news_src == NewsSource.REDDIT && length > 2 * 1024 * 1024) {
                // Reddit oversized image - report failure, caller shows a placeholder.
                return outcome;
            }

            if (status == Soup.Status.NOT_MODIFIED) {
                // Not modified; refresh last-access and re-decode the cached copy at
                // the size this specific job was requested for.
                if (meta_cache != null) meta_cache.touch(url);
                var path = meta_cache != null ? meta_cache.get_cached_path(url) : null;
                if (path == null) return outcome;

                string file_key = "pixbuf::file:%s::%dx%d".printf(path, 0, 0);
                var pix = img_cache != null ? img_cache.get_or_load_file(file_key, path, 0, 0) : ImageCache.get_global().get_or_load_file(file_key, path, 0, 0);
                if (pix == null) return outcome;

                outcome.size_key = make_cache_key(url, target_w, target_h);
                outcome.pixbuf = apply_cover_crop(img_cache, outcome.size_key, pix,
                    clampi(target_w * device_scale, 1, MAX_DECODE_DIM),
                    clampi(target_h * device_scale, 1, MAX_DECODE_DIM));
                outcome.ok = true;
                return outcome;
            }

            if (status == Soup.Status.OK && length > 0 && body != null) {
                unowned uint8[] body_data = body.get_data();
                uint8[] data = new uint8[body_data.length];
                Memory.copy(data, body_data, body_data.length);

                string? etag = http_response.get_header("etag");
                string? last_modified = http_response.get_header("last-modified");
                string? content_type = http_response.get_header("content-type");
                if (meta_cache != null) {
                    try { meta_cache.write_cache(url, data, etag, last_modified, content_type); } catch (GLib.Error e) { }
                }

                var loader = new Gdk.PixbufLoader();
                loader.write(data);
                loader.close();
                var pixbuf = loader.get_pixbuf();
                loader = null;
                if (pixbuf == null) return outcome;

                outcome.size_key = make_cache_key(url, target_w, target_h);
                outcome.pixbuf = apply_cover_crop(img_cache, outcome.size_key, pixbuf,
                    clampi(target_w * device_scale, 1, MAX_DECODE_DIM),
                    clampi(target_h * device_scale, 1, MAX_DECODE_DIM));
                outcome.ok = true;
                return outcome;
            }
        } catch (GLib.Error e) {
            // Network or decode failure - outcome.ok stays false, caller shows a placeholder.
        }
        return outcome;
    }

    // Worker-thread-safe: scales+center-crops to fully cover the (device-scaled)
    // target, via the shared ImageCache pixbuf cache. No GTK/collection access.
    private Gdk.Pixbuf apply_cover_crop(ImageCache? cache, string size_key, Gdk.Pixbuf pixbuf, int eff_w, int eff_h) {
        try {
            var final_pb = cache != null ? cache.get_or_scale_and_crop_pixbuf(size_key, pixbuf, eff_w, eff_h) : ImageCache.get_global().get_or_scale_and_crop_pixbuf(size_key, pixbuf, eff_w, eff_h);
            if (final_pb != null) return final_pb;
        } catch (GLib.Error e) { }
        return pixbuf;
    }

    // Runs on the download_pool worker threads.
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
            // Decrement active downloads counter
            GLib.AtomicInt.dec_and_test(ref NewsWindow.active_downloads);
        }
    }

    // MAIN THREAD ONLY. If the fetch sequence changed since this download
    // started (view/category switched), the result no longer belongs to the
    // current view: drop it without touching any picture - unless
    // ignore_fetch_context is set, for downloads that were never tied to any
    // particular news-article fetch in the first place (e.g. the podcast
    // mini player's cover art), which this staleness check would otherwise
    // wrongly catch every time an unrelated news fetch happens to land while
    // they're still in flight (near-guaranteed at app startup). Otherwise
    // deliver it (or the fallback placeholder, if the fetch failed) to every
    // picture waiting on this url.
    private void deliver_download_outcome(string url, int target_w, int target_h, uint gen_seq, DownloadOutcome outcome, bool ignore_fetch_context = false) {
        if (target_w == 36 && target_h == 36) GLib.print("  [img-debug] deliver_download_outcome for %s: ok=%s ignore_fetch_context=%s gen_seq=%u current=%u\n", url, outcome.ok ? "true" : "false", ignore_fetch_context ? "true" : "false", gen_seq, FetchContext.current);
        if (!ignore_fetch_context && FetchContext.current != gen_seq) {
            pending_downloads.remove(url);
            forget_requested_size(url);
            return;
        }
        deliver_to_pending(url, target_w, target_h, outcome.ok ? outcome.pixbuf : null, outcome.size_key);
    }

    // MAIN THREAD ONLY. Shared delivery path for both network downloads and
    // disk-cache loads: caches the pixbuf (when present), paints every
    // Gtk.Picture waiting on `url`, notifies loading_state, and clears
    // bookkeeping for the url. Pass a null pixbuf to fail every waiting
    // picture with its fallback placeholder instead.
    private void deliver_to_pending(string url, int target_w, int target_h, Gdk.Pixbuf? pixbuf, string? size_key) {
        if (pixbuf != null && size_key != null) {
            try { if (window.image_cache != null) window.image_cache.set(size_key, pixbuf); else ImageCache.get_global().set(size_key, pixbuf); } catch (GLib.Error e) { }
            if (target_w <= 64 && target_h <= 64) {
                try {
                    string any_key = make_cache_key(url, 0, 0);
                    if (window.image_cache != null) window.image_cache.set(any_key, pixbuf);
                    else ImageCache.get_global().set(any_key, pixbuf);
                } catch (GLib.Error e) { }
            }
        }

        var list = pending_downloads.get(url);
        if (list != null) {
            foreach (var pic in list) {
                if (pixbuf != null && size_key != null) {
                    try {
                        var cache = window.image_cache != null ? window.image_cache : ImageCache.get_global();
                        var tex = cache.get_texture(size_key);
                        if (tex == null) {
                            tex = Gdk.Texture.for_pixbuf(pixbuf);
                            cache.set_texture(size_key, tex);
                        }
                        pic.set_paintable(tex);
                        try { pending_local_placeholder.remove(pic); } catch (GLib.Error e) { }
                    } catch (GLib.Error e) { set_fallback_placeholder_for(pic, target_w, target_h, url); }
                } else {
                    set_fallback_placeholder_for(pic, target_w, target_h, url);
                }
                if (window.loading_state != null) window.loading_state.on_image_loaded(pic);
            }
            pending_downloads.remove(url);
        }
        forget_requested_size(url);
    }

    // MAIN THREAD ONLY. Convenience wrapper for the failure case.
    private void fail_pending(string url, int target_w, int target_h) {
        deliver_to_pending(url, target_w, target_h, null, null);
    }

    // MAIN THREAD ONLY.
    private void forget_requested_size(string url) {
        try { requested_image_sizes.remove(url); } catch (GLib.Error e) { }
        try {
            string nkey = UrlUtils.normalize_article_url(url);
            if (nkey != null && nkey.length > 0) requested_image_sizes.remove(nkey);
        } catch (GLib.Error e) { }
    }

    // Ensure we don't start more than MAX_CONCURRENT_DOWNLOADS downloads; if we are at capacity,
    // retry shortly until a slot frees up.
    public void ensure_start_download(string url, int target_w, int target_h, bool ignore_fetch_context = false) {
        int cap = (window.loading_state != null && window.loading_state.initial_phase) ? NewsWindow.INITIAL_PHASE_MAX_CONCURRENT_DOWNLOADS : NewsWindow.MAX_CONCURRENT_DOWNLOADS;
        if (NewsWindow.active_downloads >= cap) {
            // Track retries to prevent infinite loops if active_downloads gets stuck
            int retry_count = 0;
            try {
                if (download_retry_counts.has_key(url)) {
                    retry_count = download_retry_counts.get(url);
                }
            } catch (GLib.Error e) { retry_count = 0; }

            if (retry_count >= 100) {
                // Give up after 100 retries (15 seconds). Clean up pending downloads.
                try {
                    fail_pending(url, target_w, target_h);
                    download_retry_counts.remove(url);
                } catch (GLib.Error e) { }
                return;
            }

            download_retry_counts.set(url, retry_count + 1);
            Timeout.add(150, () => { ensure_start_download(url, target_w, target_h, ignore_fetch_context); return false; });
            return;
        }
        // Clear retry count on successful start
        try { download_retry_counts.remove(url); } catch (GLib.Error e) { }
        start_image_download_for_url(url, target_w, target_h, ignore_fetch_context);
    }

    // ignore_fetch_context: skip the FetchContext staleness check that
    // normally discards a network image result if a news-article fetch has
    // moved on since the download started (see deliver_download_outcome()).
    // That check exists to stop a stale category/search fetch's images from
    // landing after the user has navigated away - it has nothing to do with
    // requests that aren't tied to any news fetch at all, like the podcast
    // mini player's cover art, which was otherwise getting silently dropped
    // whenever the app's own initial fetch_news() call happened to land
    // while the cover was still downloading (near-guaranteed at startup).
    public void load_image_async(Gtk.Picture image, string url, int target_w, int target_h, bool force = false, bool ignore_fetch_context = false) {
        if (!force) {
            bool vis = false;
            try { vis = image.get_visible(); } catch (GLib.Error e) { vis = true; }
            if (!vis) {
                requested_image_sizes.set(url, "%dx%d".printf(target_w, target_h));
                try {
                    string nkey = UrlUtils.normalize_article_url(url);
                    if (nkey != null && nkey.length > 0) requested_image_sizes.set(nkey, "%dx%d".printf(target_w, target_h));
                } catch (GLib.Error e) { }

                deferred_downloads.set(image, new DeferredRequest(url, target_w, target_h));
                if (deferred_check_timeout_id == 0) {
                    deferred_check_timeout_id = Timeout.add(1000, () => {
                        try { process_deferred_downloads(); } catch (GLib.Error e) { }
                        deferred_check_timeout_id = 0;
                        return false;
                    });
                }
                return;
            }
        }

        string key = make_cache_key(url, target_w, target_h);

        // Check thumbnail cache first for small images (faster lookup, better hit rate)
        if (target_w <= 64 && target_h <= 64) {
            var any_key_thumb = make_cache_key(url, 0, 0);
            var thumb_pb = window.image_cache != null ? window.image_cache.get(any_key_thumb) : ImageCache.get_global().get(any_key_thumb);
            if (thumb_pb != null) {
                paint_synchronously(image, any_key_thumb, thumb_pb);
                return;
            }
        }

        // Check main memory cache (now stored as pixbufs in ImageCache)
        var cached_pb = window.image_cache != null ? window.image_cache.get(key) : ImageCache.get_global().get(key);
        if (cached_pb != null) {
            paint_synchronously(image, key, cached_pb);
            return;
        }

        var any_key = make_cache_key(url, 0, 0);
        var cached_any_pb = window.image_cache != null ? window.image_cache.get(any_key) : ImageCache.get_global().get(any_key);
        if (cached_any_pb != null && target_w <= 64 && target_h <= 64) {
            paint_synchronously(image, any_key, cached_any_pb);
            return;
        }

        if (window.meta_cache != null) {
            var disk_path = window.meta_cache.get_cached_path(url);
            if (target_w == 36 && target_h == 36) GLib.print("  [img-debug] disk_path for %s = %s\n", url, disk_path ?? "(null)");
            if (disk_path != null) {
                // Decode/scale off the main thread, same as network downloads
                // below - only the final texture/cache write touches GTK
                // state, via Idle.add. Decoding cached thumbnails inline adds
                // up fast on views with many cards.
                int device_scale = 1;
                try { device_scale = image.get_scale_factor(); if (device_scale < 1) device_scale = 1; } catch (GLib.Error e) { device_scale = 1; }

                var job = new CachedImageJob();
                job.image = image;
                job.url = url;
                job.target_w = target_w;
                job.target_h = target_h;
                job.device_scale = device_scale;
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

    // MAIN THREAD ONLY. Paints an already-cached pixbuf onto `image`
    // immediately (synchronous cache-hit path - no worker pool involved).
    private void paint_synchronously(Gtk.Picture image, string key, Gdk.Pixbuf pixbuf) {
        var cache = window.image_cache != null ? window.image_cache : ImageCache.get_global();
        var tex = cache.get_texture(key);
        try {
            if (tex == null) {
                tex = Gdk.Texture.for_pixbuf(pixbuf);
                cache.set_texture(key, tex);
            }
            image.set_paintable(tex);
        } catch (GLib.Error e) { }
        if (window.loading_state != null) window.loading_state.on_image_loaded(image);
        try { pending_local_placeholder.remove(image); } catch (GLib.Error e) { }
    }

    // Shared fallback: register `image` as waiting for `url` and start
    // (or join) a network download for it. Used both when there's no
    // disk-cached copy at all, and when decoding a disk-cached copy fails.
    // MAIN THREAD ONLY.
    private void network_fallback(Gtk.Picture image, string url, int target_w, int target_h, bool ignore_fetch_context = false) {
        // THREAD SAFETY: Lock mutex while checking and modifying pending_downloads
        // to prevent race with background threads accessing the HashMap.
        // Wrapped in try/finally (not just a trailing unlock call) because
        // of the early `return` below - without finally, that return path
        // would leak the lock and permanently deadlock every subsequent
        // caller of network_fallback() on any thread.
        download_mutex.lock();
        try {
            var existing = pending_downloads.get(url);
            if (existing != null) {
                existing.add(image);
                return;
            }

            var list = new Gee.ArrayList<Gtk.Picture>();
            list.add(image);
            pending_downloads.set(url, list);
            requested_image_sizes.set(url, "%dx%d".printf(target_w, target_h));
            try {
                string nkey = UrlUtils.normalize_article_url(url);
                if (nkey != null && nkey.length > 0) requested_image_sizes.set(nkey, "%dx%d".printf(target_w, target_h));
            } catch (GLib.Error e) { }
        } finally {
            download_mutex.unlock();
        }

        // Download at the requested size - multipliers are already applied by callers
        // (articleManager applies 6x for heroes, 3x for articles, etc.)
        // Note: Guardian URLs are upgraded to 1000px during download (their CDN allows
        // 1000px but returns 403 for larger sizes like 2000px/2400px)
        int download_w = clampi(target_w, target_w, 2400);
        int download_h = clampi(target_h, target_h, 2400);
        ensure_start_download(url, download_w, download_h, ignore_fetch_context);
    }

    // Runs on the cached_load_pool worker threads. Pure computation only
    // (disk read + decode/scale/crop) up until the final Idle.add - see the
    // THREADING CONTRACT note above.
    private void do_cached_image_load(CachedImageJob job) {
        Gtk.Picture image = job.image;
        string url = job.url;
        int target_w = job.target_w;
        int target_h = job.target_h;
        int device_scale = job.device_scale;
        string disk_path = job.disk_path;
        var img_cache = job.img_cache;
        bool ignore_fetch_context = job.ignore_fetch_context;

        Gdk.Pixbuf? pix = null;
        string size_key = make_cache_key(url, target_w, target_h);
        try {
            string file_key = "pixbuf::file:%s::%dx%d".printf(disk_path, 0, 0);
            var loaded = img_cache != null ? img_cache.get_or_load_file(file_key, disk_path, 0, 0) : ImageCache.get_global().get_or_load_file(file_key, disk_path, 0, 0);
            if (target_w == 36 && target_h == 36) GLib.print("  [img-debug] disk decode of %s: loaded=%s\n", disk_path, loaded != null ? "ok" : "null");
            if (loaded != null) {
                pix = apply_cover_crop(img_cache, size_key, loaded,
                    clampi(target_w * device_scale, 1, MAX_DECODE_DIM),
                    clampi(target_h * device_scale, 1, MAX_DECODE_DIM));
            }
        } catch (GLib.Error e) {
            if (target_w == 36 && target_h == 36) GLib.print("  [img-debug] disk decode threw: %s\n", e.message);
        }
        if (target_w == 36 && target_h == 36) GLib.print("  [img-debug] final pix=%s\n", pix != null ? "ok" : "null");

        if (pix != null) {
            Gdk.Pixbuf pix_for_idle = pix;
            Idle.add(() => {
                try { if (img_cache != null) img_cache.set(size_key, pix_for_idle); else ImageCache.get_global().set(size_key, pix_for_idle); } catch (GLib.Error e) { }
                if (target_w <= 64 && target_h <= 64) {
                    try {
                        string any_key = make_cache_key(url, 0, 0);
                        if (img_cache != null) img_cache.set(any_key, pix_for_idle);
                        else ImageCache.get_global().set(any_key, pix_for_idle);
                    } catch (GLib.Error e) { }
                }
                try {
                    var cache = img_cache != null ? img_cache : ImageCache.get_global();
                    var tex = cache.get_texture(size_key);
                    if (tex == null) {
                        // Build from the pixbuf already in hand and register
                        // it directly, so a concurrent eviction of size_key
                        // can't leave this texture untracked.
                        tex = Gdk.Texture.for_pixbuf(pix_for_idle);
                        cache.set_texture(size_key, tex);
                    }
                    image.set_paintable(tex);
                    if (target_w == 36 && target_h == 36) GLib.print("  [img-debug] set_paintable succeeded for %s\n", url);
                } catch (GLib.Error e) {
                    if (target_w == 36 && target_h == 36) GLib.print("  [img-debug] set_paintable threw: %s\n", e.message);
                }
                if (window.loading_state != null) window.loading_state.on_image_loaded(image);
                return false;
            });
            return;
        }

        // Disk cache read/decode failed - fall back to a network download.
        // network_fallback() touches GTK/instance state, so it must run on
        // the main thread.
        Idle.add(() => {
            network_fallback(image, url, target_w, target_h, ignore_fetch_context);
            return false;
        });
    }

    // Generate a cache key for preview textures (url + requested size)
    public static string make_preview_cache_key(string u, int w, int h) {
        return u + "@" + w.to_string() + "x" + h.to_string();
    }

    // Public helper to set a preview placeholder when no ImageManager instance
    // is available (used by legacy code paths that don't hold an ImageManager).
    public static void set_preview_placeholder(Gtk.Picture pic, int w, int h, NewsSource source, string? category_id = null, bool source_mapped = true, NewsWindow? window = null) {
        if (category_id != null && category_id == "local_news") {
            if (window != null) {
                window.set_local_placeholder_image(pic, w, h);
            } else {
                PlaceholderBuilder.create_gradient_placeholder(pic, w, h);
            }
        } else if (!source_mapped) {
            PlaceholderBuilder.create_gradient_placeholder(pic, w, h);
        } else {
            if (window != null) window.set_placeholder_image_for_source(pic, w, h, source);
            else PlaceholderBuilder.set_placeholder_image_for_source(pic, w, h, source);
        }
    }

    // High-level helper to load article preview images. Centralizes
    // placeholder selection, preview cache lookup, and async loading
    // so UI code remains layout-only.
    public void load_preview_image(Gtk.Picture pic, string? thumbnail_url, int img_w, int img_h, NewsSource source, string? category_id = null, bool source_mapped = true) {
        bool will_load_image = thumbnail_url != null &&
        thumbnail_url.length > 0 &&
        (thumbnail_url.has_prefix("http://") || thumbnail_url.has_prefix("https://"));

        // Handle cases where no thumbnail is provided
        if (!will_load_image) {
            if (category_id != null && category_id == "local_news") {
                window.set_local_placeholder_image(pic, img_w, img_h);
            } else if (!source_mapped) {
                PlaceholderBuilder.create_gradient_placeholder(pic, img_w, img_h);
            } else {
                PlaceholderBuilder.set_placeholder_image_for_source(pic, img_w, img_h, source);
            }
            return;
        }

        int multiplier = (source == NewsSource.REDDIT) ? 2 : 3;
        int target_w = img_w * multiplier;
        int target_h = img_h * multiplier;

        // Try to serve a cached preview texture synchronously for snappy opens
        bool loaded_from_cache = false;
        string key = ImageManager.make_preview_cache_key(thumbnail_url, target_w, target_h);
        var texture = PreviewCacheManager.get_cache().get_texture(key);
        if (texture != null) {
            pic.set_paintable(texture);
            loaded_from_cache = true;
        }

        // If not in cache, fallback to async loading
        if (!loaded_from_cache) {
            if (category_id != null && category_id == "local_news") {
                pending_local_placeholder.set(pic, true);
            }
            load_image_async(pic, thumbnail_url, target_w, target_h, true);
        }
    }

    // Helper to form memory cache keys that include requested size
    public string make_cache_key(string url, int w, int h) {
        return "pixbuf::url:%s::%dx%d".printf(url, w, h);
    }

    // Cleanup stale downloads to prevent unbounded HashMap growth and memory leaks
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
                keys_to_remove.add(entry.key);
                count++;
            }

            foreach (var key in keys_to_remove) {
                try {
                    pending_downloads.unset(key);
                    requested_image_sizes.unset(key);
                } catch (GLib.Error e) { }
            }
        }
        download_mutex.unlock();
    }

    // Process deferred download requests: if a deferred widget becomes visible, start its download
    public void process_deferred_downloads() {
        const int MAX_BATCH = 5;
        int processed = 0;

        var to_start = new Gee.ArrayList<Gtk.Picture>();
        foreach (var kv in deferred_downloads.entries) {
            if (processed >= MAX_BATCH) break;
            Gtk.Picture pic = kv.key;
            if (pic.get_visible()) {
                to_start.add(pic);
                processed++;
            }
        }

        foreach (var pic in to_start) {
            var req = deferred_downloads.get(pic);
            if (req == null) continue;
            try { deferred_downloads.remove(pic); } catch (GLib.Error e) { }
            load_image_async(pic, req.url, req.w, req.h, true);
        }

        if (deferred_downloads.size > 0) {
            if (deferred_check_timeout_id == 0) {
                deferred_check_timeout_id = Timeout.add(1200, () => {
                    process_deferred_downloads();
                    deferred_check_timeout_id = 0;
                    return false;
                });
            }
        }
    }

    // Upgrade images to higher resolution after initial load phase
    public void upgrade_images_after_initial() {
        const int UPGRADE_BATCH_SIZE = 3;
        int processed = 0;

        if (window.view_state != null) {
            foreach (var kv in window.view_state.url_to_picture.entries) {
                string norm_url = kv.key;
                Gtk.Picture? pic = kv.value;
                if (pic == null) continue;

                var rec = requested_image_sizes.get(norm_url);
                if (rec == null || rec.length == 0) continue;
                string[] parts = rec.split("x");
                if (parts.length < 2) continue;
                int last_w = 0; int last_h = 0;
                try { last_w = int.parse(parts[0]); last_h = int.parse(parts[1]); } catch (GLib.Error e) { continue; }

                int new_w = clampi(last_w * 2, last_w, 1600);
                int new_h = clampi(last_h * 2, last_h, 1600);

                bool has_large = false;
                string key_norm = make_cache_key(norm_url, new_w, new_h);
                if ((window.image_cache != null ? window.image_cache.get(key_norm) : ImageCache.get_global().get(key_norm)) != null) has_large = true;

                string? original = window.view_state != null ? window.view_state.normalized_to_url.get(norm_url) : null;
                if (!has_large && original != null) {
                    string key_orig = make_cache_key(original, new_w, new_h);
                    if ((window.image_cache != null ? window.image_cache.get(key_orig) : ImageCache.get_global().get(key_orig)) != null) has_large = true;
                }

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
    }

    // Force GTK to re-render all visible images by calling queue_draw on their pictures
    // This fixes the issue where images set while container was hidden don't render properly
    public void refresh_visible_images() {
        var children = window.content_box.observe_children();
        for (uint i = 0; i < children.get_n_items(); i++) {
            var child = children.get_item(i);
            // Recursively find all Gtk.Picture widgets and force them to redraw
            refresh_pictures_in_widget(child as Gtk.Widget);
        }
    }

    private void refresh_pictures_in_widget(Gtk.Widget? widget) {
        if (widget == null) return;

        if (widget is Gtk.Picture) {
            var pic = widget as Gtk.Picture;
            // Force the picture to redraw by calling queue_draw
            pic.queue_draw();
            return;
        }

        // Recurse into container widgets
        if (widget is Gtk.Box || widget is Gtk.Grid || widget is Adw.Clamp) {
            var current = widget.get_first_child();
            while (current != null) {
                refresh_pictures_in_widget(current);
                current = current.get_next_sibling();
            }
        }
    }
}
