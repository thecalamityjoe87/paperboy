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


public class ImageManager : GLib.Object {
    public NewsWindow window;
    private Gee.HashMap<string, int> download_retry_counts;
    
    // Download queue and state management (moved from appWindow)
    public Gee.HashMap<string, string> requested_image_sizes;
    public Gee.HashMap<string, Gee.ArrayList<Gtk.Picture>> pending_downloads;
    public Gee.HashMap<Gtk.Picture, DeferredRequest> deferred_downloads;
    public Gee.HashMap<Gtk.Picture, bool> pending_local_placeholder;
    public Gee.HashMap<Gtk.Picture, HeroRequest> hero_requests;
    public GLib.Mutex download_mutex;
    public uint deferred_check_timeout_id = 0;

    // Helper: when an image download fails or we need a fallback placeholder,
    // prefer the local placeholder for pictures that were marked as local-news.
    private void set_fallback_placeholder_for(Gtk.Picture pic, int w, int h, string url) {
        bool prefer_local = false;
        try {
            if (pending_local_placeholder != null && pending_local_placeholder.has_key(pic)) {
                prefer_local = pending_local_placeholder.get(pic);
            }
        } catch (GLib.Error e) { prefer_local = false; }

        if (prefer_local) {
            try { window.set_local_placeholder_image(pic, w, h); } catch (GLib.Error e) { try { PlaceholderBuilder.create_gradient_placeholder(pic, w, h); } catch (GLib.Error _e) { } }
            try { if (pending_local_placeholder != null) pending_local_placeholder.remove(pic); } catch (GLib.Error e) { }
        } else {
            NewsSource source = window.infer_source_from_url(url);
            // For unknown sources, use generic gradient placeholder instead of source branding
            if (source == NewsSource.UNKNOWN) {
                try { PlaceholderBuilder.create_gradient_placeholder(pic, w, h); } catch (GLib.Error e) { }
            } else {
                try { window.set_placeholder_image_for_source(pic, w, h, source); } catch (GLib.Error e) { try { PlaceholderBuilder.create_gradient_placeholder(pic, w, h); } catch (GLib.Error _e) { } }
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
    }

    // Integer clamp helper (valac doesn't provide clampi by default)
    private static int clampi(int v, int lo, int hi) {
        if (v < lo) return lo;
        if (v > hi) return hi;
        return v;
    }

    // Start a single download for a URL and update all registered targets when done.
    public void start_image_download_for_url(string url, int target_w, int target_h) {
        // Capture a snapshot of main-thread-only data we need in the worker:
        int device_scale = 1;
        try {
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
        } catch (GLib.Error e) { device_scale = 1; }

    string? size_rec = null;
    try { size_rec = requested_image_sizes.get(url); } catch (GLib.Error e) { size_rec = null; }

    // Capture a few more main-thread-only references/values so the
    // worker doesn't dereference `window` fields from a background
    // thread. This keeps the worker self-contained and avoids
    // potential races on `window` pointer fields.
    NewsSource news_src = NewsSource.GUARDIAN;
    try { news_src = window.prefs.news_source; } catch (GLib.Error e) { }
    var session = window.session;
    var meta_cache = window.meta_cache;

        // Submit the actual download+decoding job. Using a dedicated thread
        // here avoids storing Vala delegates into our WorkerPool queue which
        // can lead to delegate-copying issues (see Vala warnings). This is a
        // conservative short-term fix to prevent corrupted closure data from
        // causing crashes; we can replace with a safer pooled implementation
        // later (for example using GLib.ThreadPool or a C-level queue).
        // CRITICAL: Soup.Message is NOT thread-safe in a shared pool context!
        // Snapshot the current window fetch sequence so we can ignore
        // downloads that complete after the user has switched categories
        // (the UI will schedule a new fetch and bump `fetch_sequence`).
        uint gen_seq = FetchContext.current;

        new Thread<void*>("image-download", () => {
            GLib.AtomicInt.inc(ref NewsWindow.active_downloads);
            try {
                // Upgrade Guardian image URLs to request higher resolution for network download
                // Guardian URLs end with /XXX.jpg where XXX is the width
                // Guardian CDN allows 1000px but returns 403 for larger sizes like 2000px/2400px
                string download_url = url;
                if (url.index_of("media.guim.co.uk") >= 0) {
                    try {
                        var regex = new Regex("/(\\d+)\\.(jpg|png|jpeg)$", RegexCompileFlags.CASELESS);
                        // Request 1000px - Guardian's CDN allows this size
                        string replacement = "/1000.\\2";
                        download_url = regex.replace(url, -1, 0, replacement);
                    } catch (GLib.Error e) {
                        // Regex error, use original URL
                    }
                }

                var client = Paperboy.HttpClient.get_default();
                var options = new Paperboy.HttpClient.RequestOptions().with_image_headers();
                var http_response = client.fetch_sync(download_url, options);

                // Capture response data
                uint response_status = http_response.status_code;
                GLib.Bytes? response = http_response.body;
                int64 response_length = (response != null) ? (int64)response.get_size() : 0;
                uint8[]? response_data = null;
                string? etag = null;
                string? last_modified = null;
                string? content_type = null;

                if (news_src == NewsSource.REDDIT && response_length > 2 * 1024 * 1024) {
                    // Reddit oversized image - bail early
                    Idle.add(() => {
                        // If the fetch sequence changed since this download started,
                        // the results no longer belong to the current view. Avoid
                        // populating caches and painting images for stale fetches.
                        if (FetchContext.current != gen_seq) {
                            try { pending_downloads.remove(url); } catch (GLib.Error e) { }
                            try { requested_image_sizes.remove(url); } catch (GLib.Error e) { }
                            try {
                                string nkey = UrlUtils.normalize_article_url(url);
                                if (nkey != null && nkey.length > 0) requested_image_sizes.remove(nkey);
                            } catch (GLib.Error e) { }
                            return false;
                        }
                        var list = pending_downloads.get(url);
                            if (list != null) {
                                foreach (var pic in list) {
                                    set_fallback_placeholder_for(pic, target_w, target_h, url);
                                    on_image_loaded(pic);
                                }
                                pending_downloads.remove(url);
                                try { requested_image_sizes.remove(url); } catch (GLib.Error e1) { }
                                try {
                                    string nkey = UrlUtils.normalize_article_url(url);
                                    if (nkey != null && nkey.length > 0) requested_image_sizes.remove(nkey);
                                } catch (GLib.Error e1) { }
                            }
                        return false;
                    });
                    // Don't return early - let finally block decrement active_downloads
                }

                if (response_status == Soup.Status.NOT_MODIFIED) {
                    // 304 Not Modified
                    // Not modified; refresh last-access and serve cached image
                    if (meta_cache != null) meta_cache.touch(url);
                    var path = meta_cache != null ? meta_cache.get_cached_path(url) : null;
                    if (path != null) {
                        try {
                            string file_key = "pixbuf::file:%s::%dx%d".printf(path, 0, 0);
                            var pix = window.image_cache != null ? window.image_cache.get_or_load_file(file_key, path, 0, 0) : ImageCache.get_global().get_or_load_file(file_key, path, 0, 0);
                            if (pix != null) {
                                if (pix != null && size_rec != null && size_rec.length > 0) {
                                    try {
                                        string[] parts = size_rec.split("x");
                                        if (parts.length == 2) {
                                            int sw = int.parse(parts[0]);
                                            int sh = int.parse(parts[1]);
                                            int eff_sw = sw * device_scale;
                                            int eff_sh = sh * device_scale;
                                            double sc = double.min((double) eff_sw / pix.get_width(), (double) eff_sh / pix.get_height());
                                            if (sc < 1.0) {
                                                int nw = (int)(pix.get_width() * sc);
                                                if (nw < 1) nw = 1;
                                                int nh = (int)(pix.get_height() * sc);
                                                if (nh < 1) nh = 1;
                                                try {
                                                    string scale_key = make_cache_key(url, nw, nh);
                                                    var scaled = window.image_cache != null ? window.image_cache.get_or_scale_pixbuf(scale_key, pix, nw, nh) : ImageCache.get_global().get_or_scale_pixbuf(scale_key, pix, nw, nh);
                                                    if (scaled != null) pix = scaled;
                                                } catch (GLib.Error e) { }
                                            }
                                            string k = make_cache_key(url, sw, sh);
                                            var pb_for_idle = pix;
                                            Idle.add(() => {
                                                if (FetchContext.current != gen_seq) {
                                                    try { pending_downloads.remove(url); } catch (GLib.Error e) { }
                                                    try { requested_image_sizes.remove(url); } catch (GLib.Error e) { }
                                                    try {
                                                        string nkey = UrlUtils.normalize_article_url(url);
                                                        if (nkey != null && nkey.length > 0) requested_image_sizes.remove(nkey);
                                                    } catch (GLib.Error e) { }
                                                    return false;
                                                }
                                                try {
                                                    // Cache the pixbuf (not a texture) so long-lived
                                                    // storage is centralized in ImageCache. Create a
                                                    // transient texture only for widgets.
                                                    try {
                                                        if (window.image_cache != null) window.image_cache.set(k, pb_for_idle);
                                                        else ImageCache.get_global().set(k, pb_for_idle);
                                                    } catch (GLib.Error e) { }
                                                    if (sw <= 64 && sh <= 64) {
                                                        try {
                                                            string any_key2 = make_cache_key(url, 0, 0);
                                                            if (window.image_cache != null) window.image_cache.set(any_key2, pb_for_idle);
                                                            else ImageCache.get_global().set(any_key2, pb_for_idle);
                                                        } catch (GLib.Error e) { }
                                                    }

                                                    var list2 = pending_downloads.get(url);
                                                    if (list2 != null) {
                                                        foreach (var pic in list2) {
                                                            try {
                                                                var tex = window.image_cache != null ? window.image_cache.get_texture(k) : ImageCache.get_global().get_texture(k);
                                                                if (tex != null) {
                                                                    pic.set_paintable(tex);
                                                                } else {
                                                                    try { pic.set_paintable(Gdk.Texture.for_pixbuf(pb_for_idle)); } catch (GLib.Error e) { set_fallback_placeholder_for(pic, target_w, target_h, url); }
                                                                }
                                                            } catch (GLib.Error e) { set_fallback_placeholder_for(pic, target_w, target_h, url); }
                                                            on_image_loaded(pic);
                                                        }
                                                        pending_downloads.remove(url);
                                                        try { requested_image_sizes.remove(url); } catch (GLib.Error e1) { }
                                                        try {
                                                            string nkey = UrlUtils.normalize_article_url(url);
                                                            if (nkey != null && nkey.length > 0) requested_image_sizes.remove(nkey);
                                                        } catch (GLib.Error e1) { }
                                                    }
                                                } catch (GLib.Error e) {
                                                    var list2 = pending_downloads.get(url);
                                                    if (list2 != null) {
                                                        foreach (var pic in list2) { set_fallback_placeholder_for(pic, target_w, target_h, url); on_image_loaded(pic); }
                                                        pending_downloads.remove(url);
                                                        try { requested_image_sizes.remove(url); } catch (GLib.Error e2) { }
                                                        try {
                                                            string nkey = UrlUtils.normalize_article_url(url);
                                                            if (nkey != null && nkey.length > 0) requested_image_sizes.remove(nkey);
                                                        } catch (GLib.Error e2) { }
                                                    }
                                                }
                                                return false;
                                            });
                                        } else {
                                            var pb_for_idle = pix;
                                            Idle.add(() => {
                                                if (FetchContext.current != gen_seq) {
                                                    try { pending_downloads.remove(url); } catch (GLib.Error e) { }
                                                    try { requested_image_sizes.remove(url); } catch (GLib.Error e) { }
                                                    try {
                                                        string nkey = UrlUtils.normalize_article_url(url);
                                                        if (nkey != null && nkey.length > 0) requested_image_sizes.remove(nkey);
                                                    } catch (GLib.Error e) { }
                                                    return false;
                                                }
                                                try {
                                                    // Cache pixbuf and emit transient textures to widgets
                                                    string any_key = make_cache_key(url, pb_for_idle.get_width(), pb_for_idle.get_height());
                                                    try {
                                                        if (window.image_cache != null) window.image_cache.set(any_key, pb_for_idle);
                                                        else ImageCache.get_global().set(any_key, pb_for_idle);
                                                    } catch (GLib.Error e) { }
                                                    var list2 = pending_downloads.get(url);
                                                    if (list2 != null) {
                                                        foreach (var pic in list2) {
                                                            try {
                                                                var tex = window.image_cache != null ? window.image_cache.get_texture(any_key) : ImageCache.get_global().get_texture(any_key);
                                                                if (tex != null) {
                                                                    pic.set_paintable(tex);
                                                                } else {
                                                                    try { pic.set_paintable(Gdk.Texture.for_pixbuf(pb_for_idle)); } catch (GLib.Error e) { set_fallback_placeholder_for(pic, target_w, target_h, url); }
                                                                }
                                                            } catch (GLib.Error e) { set_fallback_placeholder_for(pic, target_w, target_h, url); }
                                                            on_image_loaded(pic);
                                                        }
                                                        pending_downloads.remove(url);
                                                        try { requested_image_sizes.remove(url); } catch (GLib.Error e1) { }
                                                        try {
                                                            string nkey = UrlUtils.normalize_article_url(url);
                                                            if (nkey != null && nkey.length > 0) requested_image_sizes.remove(nkey);
                                                        } catch (GLib.Error e1) { }
                                                    }
                                                } catch (GLib.Error e) {
                                                    var list2 = pending_downloads.get(url);
                                                    if (list2 != null) {
                                                        foreach (var pic in list2) { set_fallback_placeholder_for(pic, target_w, target_h, url); on_image_loaded(pic); }
                                                        pending_downloads.remove(url);
                                                        try { requested_image_sizes.remove(url); } catch (GLib.Error e2) { }
                                                        try {
                                                            string nkey = UrlUtils.normalize_article_url(url);
                                                            if (nkey != null && nkey.length > 0) requested_image_sizes.remove(nkey);
                                                        } catch (GLib.Error e2) { }
                                                    }
                                                }
                                                return false;
                                            });
                                        }
                                    } catch (GLib.Error e) {
                                        var list2 = pending_downloads.get(url);
                                        if (list2 != null) {
                                                        foreach (var pic in list2) { set_fallback_placeholder_for(pic, target_w, target_h, url); on_image_loaded(pic); }
                                            pending_downloads.remove(url);
                                            try { requested_image_sizes.remove(url); } catch (GLib.Error e3) { }
                                            try {
                                                string nkey = UrlUtils.normalize_article_url(url);
                                                if (nkey != null && nkey.length > 0) requested_image_sizes.remove(nkey);
                                            } catch (GLib.Error e3) { }
                                        }
                                    }
                                } else {
                                    var pb_for_idle = pix;
                                    Idle.add(() => {
                                        if (FetchContext.current != gen_seq) {
                                            try { pending_downloads.remove(url); } catch (GLib.Error e) { }
                                            try { requested_image_sizes.remove(url); } catch (GLib.Error e) { }
                                            try {
                                                string nkey = UrlUtils.normalize_article_url(url);
                                                if (nkey != null && nkey.length > 0) requested_image_sizes.remove(nkey);
                                            } catch (GLib.Error e) { }
                                            return false;
                                        }
                                        try {
                                            string size_key = make_cache_key(url, target_w, target_h);
                                            try { if (window.image_cache != null) window.image_cache.set(size_key, pb_for_idle); else ImageCache.get_global().set(size_key, pb_for_idle); } catch (GLib.Error e) { }
                                            if (pb_for_idle.get_width() <= 64 && pb_for_idle.get_height() <= 64) {
                                                try {
                                                    string any_key2 = make_cache_key(url, 0, 0);
                                                    if (window.image_cache != null) window.image_cache.set(any_key2, pb_for_idle);
                                                    else ImageCache.get_global().set(any_key2, pb_for_idle);
                                                } catch (GLib.Error e) { }
                                            }

                                            var list2 = pending_downloads.get(url);
                                            if (list2 != null) {
                                                foreach (var pic in list2) {
                                                    try {
                                                        var tex = window.image_cache != null ? window.image_cache.get_texture(size_key) : ImageCache.get_global().get_texture(size_key);
                                                        if (tex != null) {
                                                            pic.set_paintable(tex);
                                                        } else {
                                                            try { pic.set_paintable(Gdk.Texture.for_pixbuf(pb_for_idle)); } catch (GLib.Error e) { set_fallback_placeholder_for(pic, target_w, target_h, url); }
                                                        }
                                                    } catch (GLib.Error e) { set_fallback_placeholder_for(pic, target_w, target_h, url); }
                                                    on_image_loaded(pic);
                                                }
                                                pending_downloads.remove(url);
                                                try { requested_image_sizes.remove(url); } catch (GLib.Error e4) { }
                                                try {
                                                    string nkey = UrlUtils.normalize_article_url(url);
                                                    if (nkey != null && nkey.length > 0) requested_image_sizes.remove(nkey);
                                                } catch (GLib.Error e4) { }
                                            }
                                        } catch (GLib.Error e) {
                                                    var list2 = pending_downloads.get(url);
                                                    if (list2 != null) {
                                                        foreach (var pic in list2) { set_fallback_placeholder_for(pic, target_w, target_h, url); on_image_loaded(pic); }
                                                        pending_downloads.remove(url);
                                                        try { requested_image_sizes.remove(url); } catch (GLib.Error e2) { }
                                                        try {
                                                            string nkey = UrlUtils.normalize_article_url(url);
                                                            if (nkey != null && nkey.length > 0) requested_image_sizes.remove(nkey);
                                                        } catch (GLib.Error e2) { }
                                                    }
                                        }
                                        return false;
                                    });
                                }
                            }
                        } catch (GLib.Error e) {
                            var list2 = pending_downloads.get(url);
                            if (list2 != null) {
                                                        foreach (var pic in list2) { set_fallback_placeholder_for(pic, target_w, target_h, url); on_image_loaded(pic); }
                                pending_downloads.remove(url);
                                try { requested_image_sizes.remove(url); } catch (GLib.Error e6) { }
                                try {
                                    string nkey = UrlUtils.normalize_article_url(url);
                                    if (nkey != null && nkey.length > 0) requested_image_sizes.remove(nkey);
                                } catch (GLib.Error e6) { }
                            }
                        }
                    } else {
                                    Idle.add(() => {
                                        if (FetchContext.current != gen_seq) {
                                            try { pending_downloads.remove(url); } catch (GLib.Error e) { }
                                            try { requested_image_sizes.remove(url); } catch (GLib.Error e) { }
                                            try {
                                                string nkey = UrlUtils.normalize_article_url(url);
                                                if (nkey != null && nkey.length > 0) requested_image_sizes.remove(nkey);
                                            } catch (GLib.Error e) { }
                                            return false;
                                        }
                            var list2 = pending_downloads.get(url);
                            if (list2 != null) {
                                foreach (var pic in list2) { set_fallback_placeholder_for(pic, target_w, target_h, url); on_image_loaded(pic); }
                                pending_downloads.remove(url);
                            }
                            return false;
                        });
                    }
                    // continue after handling 304
                }

                if (response_status == Soup.Status.OK && response_length > 0 && response != null) {
                    try {
                        // Get response data from GLib.Bytes
                        unowned uint8[] body_data = response.get_data();

                        // Copy to uint8[] array for processing
                        uint8[] data = new uint8[body_data.length];
                        Memory.copy(data, body_data, body_data.length);

                        // Extract response headers
                        etag = http_response.get_header("etag");
                        last_modified = http_response.get_header("last-modified");
                        content_type = http_response.get_header("content-type");

                        if (meta_cache != null) {
                            try {
                                meta_cache.write_cache(url, data, etag, last_modified, content_type);
                            } catch (GLib.Error e) { }
                        }

                        var loader = new Gdk.PixbufLoader();
                        loader.write(data);
                        loader.close();
                        var pixbuf = loader.get_pixbuf();
                        // Set loader to null to free it (Vala auto-manages GObject refs)
                        loader = null;
                        if (pixbuf != null) {
                            int width = pixbuf.get_width();
                            int height = pixbuf.get_height();
                            double scale = double.min((double) target_w / width, (double) target_h / height);
                                if (scale < 1.0) {
                                int new_width = (int)(width * scale);
                                if (new_width < 1) new_width = 1;
                                int new_height = (int)(height * scale);
                                if (new_height < 1) new_height = 1;
                                try {
                                    string scale_key = make_cache_key(url, new_width, new_height);
                                    var scaled = window.image_cache != null ? window.image_cache.get_or_scale_pixbuf(scale_key, pixbuf, new_width, new_height) : ImageCache.get_global().get_or_scale_pixbuf(scale_key, pixbuf, new_width, new_height);
                                    if (scaled != null) {
                                        pixbuf = scaled;
                                    }
                                } catch (GLib.Error e) { }
                            } else if (scale > 1.0) {
                                // Allow larger upscales for hero images so high-DPI displays get crisper results.
                                double max_upscale = 2.0;  // previously 1.5
                                double upscale = double.min(scale, max_upscale);
                                int new_width = (int)(width * upscale);
                                int new_height = (int)(height * upscale);
                                if (upscale > 1.01) {
                                    try {
                                        string scale_key = make_cache_key(url, new_width, new_height);
                                        var scaled = window.image_cache != null ? window.image_cache.get_or_scale_pixbuf(scale_key, pixbuf, new_width, new_height) : ImageCache.get_global().get_or_scale_pixbuf(scale_key, pixbuf, new_width, new_height);
                                        if (scaled != null) pixbuf = scaled;
                                    } catch (GLib.Error e) { }
                                }
                            }

                            var pb_for_idle = pixbuf;
                            Idle.add(() => {
                                if (FetchContext.current != gen_seq) {
                                    try { pending_downloads.remove(url); } catch (GLib.Error e) { }
                                    return false;
                                }
                                try {
                                    string size_key = make_cache_key(url, target_w, target_h);
                                    try { if (window.image_cache != null) window.image_cache.set(size_key, pb_for_idle); else ImageCache.get_global().set(size_key, pb_for_idle); } catch (GLib.Error e) { }

                                    var list = pending_downloads.get(url);
                                    if (list != null) {
                                        foreach (var pic in list) {
                                            try {
                                                var tex = window.image_cache != null ? window.image_cache.get_texture(size_key) : ImageCache.get_global().get_texture(size_key);
                                                if (tex != null) {
                                                    pic.set_paintable(tex);
                                                    try { if (pending_local_placeholder != null) pending_local_placeholder.remove(pic); } catch (GLib.Error e) { }
                                                } else {
                                                    try { pic.set_paintable(Gdk.Texture.for_pixbuf(pb_for_idle)); } catch (GLib.Error e) { set_fallback_placeholder_for(pic, target_w, target_h, url); }
                                                }
                                            } catch (GLib.Error e) { set_fallback_placeholder_for(pic, target_w, target_h, url); }
                                            on_image_loaded(pic);
                                        }
                                        pending_downloads.remove(url);
                                    }
                                } catch (GLib.Error e) {
                                    var list = pending_downloads.get(url);
                                    if (list != null) {
                                        foreach (var pic in list) {
                                            set_fallback_placeholder_for(pic, target_w, target_h, url);
                                            on_image_loaded(pic);
                                        }
                                        pending_downloads.remove(url);
                                    }
                                }
                                return false;
                            });
                        } else {
                            Idle.add(() => {
                                var list = pending_downloads.get(url);
                                if (list != null) {
                                    foreach (var pic in list) {
                                        set_fallback_placeholder_for(pic, target_w, target_h, url);
                                        on_image_loaded(pic);
                                    }
                                    pending_downloads.remove(url);
                                }
                                return false;
                            });
                        }
                    } catch (GLib.Error e) {
                        // Error during image decode - make sure to unref msg if we haven't already
                        Idle.add(() => {
                            var list = pending_downloads.get(url);
                            if (list != null) {
                                foreach (var pic in list) {
                                    set_fallback_placeholder_for(pic, target_w, target_h, url);
                                    on_image_loaded(pic);
                                }
                                pending_downloads.remove(url);
                            }
                            return false;
                        });
                    }
                } else {
                    // Status is not 200 or 304
                    Idle.add(() => {
                        if (FetchContext.current != gen_seq) {
                            try { pending_downloads.remove(url); } catch (GLib.Error e) { }
                            return false;
                        }
                        var list = pending_downloads.get(url);
                        if (list != null) {
                            foreach (var pic in list) {
                                    set_fallback_placeholder_for(pic, target_w, target_h, url);
                                on_image_loaded(pic);
                            }
                            pending_downloads.remove(url);
                        }
                        return false;
                    });
                }
            } catch (GLib.Error e) {
                Idle.add(() => {
                    var list = pending_downloads.get(url);
                    if (list != null) {
                        foreach (var pic in list) {
                            set_fallback_placeholder_for(pic, target_w, target_h, url);
                            on_image_loaded(pic);
                        }
                        pending_downloads.remove(url);
                    }
                    return false;
                });
            } finally {
                // Decrement active downloads counter
                GLib.AtomicInt.dec_and_test(ref NewsWindow.active_downloads);
            }
            return null;
        });
    }

    // Ensure we don't start more than MAX_CONCURRENT_DOWNLOADS downloads; if we are at capacity,
    // retry shortly until a slot frees up.
    public void ensure_start_download(string url, int target_w, int target_h) {
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
                    var list = pending_downloads.get(url);
                    if (list != null) {
                                foreach (var pic in list) {
                                    set_fallback_placeholder_for(pic, target_w, target_h, url);
                                    on_image_loaded(pic);
                                }
                        pending_downloads.remove(url);
                        try { requested_image_sizes.remove(url); } catch (GLib.Error e) { }
                        try {
                            string nkey = UrlUtils.normalize_article_url(url);
                            if (nkey != null && nkey.length > 0) requested_image_sizes.remove(nkey);
                        } catch (GLib.Error e) { }
                    }
                    download_retry_counts.remove(url);
                } catch (GLib.Error e) { }
                return;
            }

            download_retry_counts.set(url, retry_count + 1);
            Timeout.add(150, () => { ensure_start_download(url, target_w, target_h); return false; });
            return;
        }
        // Clear retry count on successful start
        try { download_retry_counts.remove(url); } catch (GLib.Error e) { }
        start_image_download_for_url(url, target_w, target_h);
    }

    public void load_image_async(Gtk.Picture image, string url, int target_w, int target_h, bool force = false) {

        if (!force) {
            try {
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
            } catch (GLib.Error e) { }
        }

        string key = make_cache_key(url, target_w, target_h);
        
        // Check thumbnail cache first for small images (faster lookup, better hit rate)
        if (target_w <= 64 && target_h <= 64) {
            var any_key_thumb = make_cache_key(url, 0, 0);
            var thumb_pb = window.image_cache != null ? window.image_cache.get(any_key_thumb) : ImageCache.get_global().get(any_key_thumb);
            if (thumb_pb != null) {
                try {
                    var tex = window.image_cache != null ? window.image_cache.get_texture(any_key_thumb) : ImageCache.get_global().get_texture(any_key_thumb);
                    if (tex != null) {
                        image.set_paintable(tex);
                    } else {
                        try { image.set_paintable(Gdk.Texture.for_pixbuf(thumb_pb)); } catch (GLib.Error e) { }
                    }
                } catch (GLib.Error e) { }
                on_image_loaded(image);
                return;
            }
        }

        // Check main memory cache (now stored as pixbufs in ImageCache)
        var cached_pb = window.image_cache != null ? window.image_cache.get(key) : ImageCache.get_global().get(key);
        if (cached_pb != null) {
            try {
                var tex = window.image_cache != null ? window.image_cache.get_texture(key) : ImageCache.get_global().get_texture(key);
                if (tex != null) {
                    image.set_paintable(tex);
                } else {
                    try { image.set_paintable(Gdk.Texture.for_pixbuf(cached_pb)); } catch (GLib.Error e) { }
                }
            } catch (GLib.Error e) { }
            on_image_loaded(image);
            return;
        }

        var any_key = make_cache_key(url, 0, 0);
        var cached_any_pb = window.image_cache != null ? window.image_cache.get(any_key) : ImageCache.get_global().get(any_key);
        if (cached_any_pb != null) {
                if (target_w <= 64 && target_h <= 64) {
                try {
                    var tex = window.image_cache != null ? window.image_cache.get_texture(any_key) : ImageCache.get_global().get_texture(any_key);
                    if (tex != null) {
                        image.set_paintable(tex);
                    } else {
                        try { image.set_paintable(Gdk.Texture.for_pixbuf(cached_any_pb)); } catch (GLib.Error e) { }
                    }
                } catch (GLib.Error e) { }
                on_image_loaded(image);
                return;
            } else {
            }
        }

        try {
            if (window.meta_cache != null) {
                var disk_path = window.meta_cache.get_cached_path(url);
                if (disk_path != null) {
                        try {
                            string file_key = "pixbuf::file:%s::%dx%d".printf(disk_path, 0, 0);
                            var pix = window.image_cache != null ? window.image_cache.get_or_load_file(file_key, disk_path, 0, 0) : ImageCache.get_global().get_or_load_file(file_key, disk_path, 0, 0);
                            if (pix != null) {
                                int device_scale = 1;
                                try { device_scale = image.get_scale_factor(); if (device_scale < 1) device_scale = 1; } catch (GLib.Error e) { device_scale = 1; }

                                int eff_target_w = target_w * device_scale;
                                int eff_target_h = target_h * device_scale;

                                int width = pix.get_width();
                                int height = pix.get_height();
                                double scale = double.min((double) eff_target_w / width, (double) eff_target_h / height);
                                if (scale < 1.0) {
                                    // Scale down if image is too large
                                    int new_w = (int)(width * scale);
                                    if (new_w < 1) new_w = 1;
                                    int new_h = (int)(height * scale);
                                    if (new_h < 1) new_h = 1;
                                    try {
                                        string scale_key = make_cache_key(url, new_w, new_h);
                                        var scaled = window.image_cache != null ? window.image_cache.get_or_scale_pixbuf(scale_key, pix, new_w, new_h) : ImageCache.get_global().get_or_scale_pixbuf(scale_key, pix, new_w, new_h);
                                        if (scaled != null) pix = scaled;
                                    } catch (GLib.Error e) { }
                                } else if (scale > 1.0) {
                                    // Allow upscaling for high-DPI displays (same logic as network download path)
                                    double max_upscale = 2.0;
                                    double upscale = double.min(scale, max_upscale);
                                    int new_w = (int)(width * upscale);
                                    int new_h = (int)(height * upscale);
                                    if (upscale > 1.01) {
                                        try {
                                            string scale_key = make_cache_key(url, new_w, new_h);
                                            var scaled = window.image_cache != null ? window.image_cache.get_or_scale_pixbuf(scale_key, pix, new_w, new_h) : ImageCache.get_global().get_or_scale_pixbuf(scale_key, pix, new_w, new_h);
                                            if (scaled != null) pix = scaled;
                                        } catch (GLib.Error e) { }
                                    }
                                }
                                string size_key = make_cache_key(url, target_w, target_h);
                                try { if (window.image_cache != null) window.image_cache.set(size_key, pix); else ImageCache.get_global().set(size_key, pix); } catch (GLib.Error e) { }
                                if (target_w <= 64 && target_h <= 64) {
                                    try {
                                        string any_key2 = make_cache_key(url, 0, 0);
                                        if (window.image_cache != null) window.image_cache.set(any_key2, pix);
                                        else ImageCache.get_global().set(any_key2, pix);
                                    } catch (GLib.Error e) { }
                                }
                                try {
                                    var tex = window.image_cache != null ? window.image_cache.get_texture(size_key) : ImageCache.get_global().get_texture(size_key);
                                    if (tex != null) {
                                        image.set_paintable(tex);
                                    } else {
                                        try { image.set_paintable(Gdk.Texture.for_pixbuf(pix)); } catch (GLib.Error e) { }
                                    }
                                } catch (GLib.Error e) { }
                                on_image_loaded(image);
                                return;
                            }
                        } catch (GLib.Error e) {
                            // Fall through to network fetch
                        }
                }
            }
        } catch (GLib.Error e) { }

        // THREAD SAFETY: Lock mutex while checking and modifying pending_downloads
        // to prevent race with background threads accessing the HashMap
        download_mutex.lock();
        try {
            var existing = pending_downloads.get(url);
            if (existing != null) {
                existing.add(image);
                // Don't unlock here - finally block will handle it
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
        //try { GLib.message("ImageManager: queue download for %s target=%dx%d download=%dx%d", url, target_w, target_h, download_w, download_h); } catch (GLib.Error e) { }
        ensure_start_download(url, download_w, download_h);
    }
    
    // Helper to form memory cache keys that include requested size
    public string make_cache_key(string url, int w, int h) {
        return "pixbuf::url:%s::%dx%d".printf(url, w, h);
    }
    
    // Cleanup stale downloads to prevent unbounded HashMap growth and memory leaks
    public void cleanup_stale_downloads() {
        download_mutex.lock();
        try {
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
                
                warning("cleanup_stale_downloads: removed %d stale entries, new size=%d", keys_to_remove.size, pending_downloads.size);
            }
        } catch (GLib.Error e) {
            warning("cleanup_stale_downloads: error during cleanup: %s", e.message);
        } finally {
            download_mutex.unlock();
        }
    }
    
    // Process deferred download requests: if a deferred widget becomes visible, start its download
    public void process_deferred_downloads() {
        const int MAX_BATCH = 5;
        int processed = 0;
        
        var to_start = new Gee.ArrayList<Gtk.Picture>();
        foreach (var kv in deferred_downloads.entries) {
            if (processed >= MAX_BATCH) break;
            Gtk.Picture pic = kv.key;
            DeferredRequest req = kv.value;
            bool vis = false;
            try { vis = pic.get_visible(); } catch (GLib.Error e) { vis = true; }
            if (vis) {
                to_start.add(pic);
                processed++;
            }
        }

        foreach (var pic in to_start) {
            var req = deferred_downloads.get(pic);
            if (req == null) continue;
            try { deferred_downloads.remove(pic); } catch (GLib.Error e) { }
            try { load_image_async(pic, req.url, req.w, req.h, true); } catch (GLib.Error e) { }
        }
        
        if (deferred_downloads.size > 0) {
            if (deferred_check_timeout_id == 0) {
                deferred_check_timeout_id = Timeout.add(1200, () => {
                    try { process_deferred_downloads(); } catch (GLib.Error e) { }
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

                int new_w = (int)(last_w * 2);
                int new_h = (int)(last_h * 2);
                new_w = clampi(new_w, last_w, 1600);
                new_h = clampi(new_h, last_h, 1600);

                bool has_large = false;
                string key_norm = make_cache_key(norm_url, new_w, new_h);
                if ((window.image_cache != null ? window.image_cache.get(key_norm) : ImageCache.get_global().get(key_norm)) != null) has_large = true;

                string? original = null;
                try { if (window.view_state != null) original = window.view_state.normalized_to_url.get(norm_url); } catch (GLib.Error e) { original = null; }
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
    
    // Called when an image finished loading
    public void on_image_loaded(Gtk.Picture image) {
        if (window.loading_state == null) return;
        if (!window.loading_state.initial_phase) return;
        if (hero_requests.get(image) != null) window.loading_state.hero_image_loaded = true;
        if (window.loading_state.pending_images > 0) window.loading_state.pending_images--;

        if (window.loading_state.initial_items_populated && window.loading_state.pending_images == 0) {
            try { window.loading_state.reveal_initial_content(); } catch (GLib.Error e) { }
        }
    }
}

