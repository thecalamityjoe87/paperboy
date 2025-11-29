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


public class ImageHandler : GLib.Object {
    public NewsWindow window;
    private Gee.HashMap<string, int> download_retry_counts;

    // Helper: when an image download fails or we need a fallback placeholder,
    // prefer the local placeholder for pictures that were marked as local-news.
    private void set_fallback_placeholder_for(Gtk.Picture pic, int w, int h, string url) {
        bool prefer_local = false;
        try {
            if (window.pending_local_placeholder != null && window.pending_local_placeholder.has_key(pic)) {
                prefer_local = window.pending_local_placeholder.get(pic);
            }
        } catch (GLib.Error e) { prefer_local = false; }

        if (prefer_local) {
            try { window.set_local_placeholder_image(pic, w, h); } catch (GLib.Error e) { try { window.set_placeholder_image_for_source(pic, w, h, window.infer_source_from_url(url)); } catch (GLib.Error _e) { } }
            try { if (window.pending_local_placeholder != null) window.pending_local_placeholder.remove(pic); } catch (GLib.Error e) { }
        } else {
            try { window.set_placeholder_image_for_source(pic, w, h, window.infer_source_from_url(url)); } catch (GLib.Error e) { try { window.set_local_placeholder_image(pic, w, h); } catch (GLib.Error _e) { } }
        }
    }

    public ImageHandler(NewsWindow w) {
        window = w;
        download_retry_counts = new Gee.HashMap<string, int>();
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
            var list_try = window.pending_downloads.get(url);
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
    try { size_rec = window.requested_image_sizes.get(url); } catch (GLib.Error e) { size_rec = null; }

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
        uint gen_seq = 0;
        try { gen_seq = window.fetch_sequence; } catch (GLib.Error e) { gen_seq = 0; }

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
                        if (window.fetch_sequence != gen_seq) {
                            try { window.pending_downloads.remove(url); } catch (GLib.Error e) { }
                            try { window.requested_image_sizes.remove(url); } catch (GLib.Error e) { }
                            try {
                                string nkey = UrlUtils.normalize_article_url(url);
                                if (nkey != null && nkey.length > 0) window.requested_image_sizes.remove(nkey);
                            } catch (GLib.Error e) { }
                            return false;
                        }
                        var list = window.pending_downloads.get(url);
                            if (list != null) {
                                foreach (var pic in list) {
                                    set_fallback_placeholder_for(pic, target_w, target_h, url);
                                    window.on_image_loaded(pic);
                                }
                                window.pending_downloads.remove(url);
                                try { window.requested_image_sizes.remove(url); } catch (GLib.Error e1) { }
                                try {
                                    string nkey = UrlUtils.normalize_article_url(url);
                                    if (nkey != null && nkey.length > 0) window.requested_image_sizes.remove(nkey);
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
                                                    string scale_key = window.make_cache_key(url, nw, nh);
                                                    var scaled = window.image_cache != null ? window.image_cache.get_or_scale_pixbuf(scale_key, pix, nw, nh) : ImageCache.get_global().get_or_scale_pixbuf(scale_key, pix, nw, nh);
                                                    if (scaled != null) pix = scaled;
                                                } catch (GLib.Error e) { }
                                            }
                                            string k = window.make_cache_key(url, sw, sh);
                                            var pb_for_idle = pix;
                                            Idle.add(() => {
                                                if (window.fetch_sequence != gen_seq) {
                                                    try { window.pending_downloads.remove(url); } catch (GLib.Error e) { }
                                                    try { window.requested_image_sizes.remove(url); } catch (GLib.Error e) { }
                                                    try {
                                                        string nkey = UrlUtils.normalize_article_url(url);
                                                        if (nkey != null && nkey.length > 0) window.requested_image_sizes.remove(nkey);
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
                                                            string any_key2 = window.make_cache_key(url, 0, 0);
                                                            if (window.image_cache != null) window.image_cache.set(any_key2, pb_for_idle);
                                                            else ImageCache.get_global().set(any_key2, pb_for_idle);
                                                        } catch (GLib.Error e) { }
                                                    }

                                                    var list2 = window.pending_downloads.get(url);
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
                                                            window.on_image_loaded(pic);
                                                        }
                                                        window.pending_downloads.remove(url);
                                                        try { window.requested_image_sizes.remove(url); } catch (GLib.Error e1) { }
                                                        try {
                                                            string nkey = UrlUtils.normalize_article_url(url);
                                                            if (nkey != null && nkey.length > 0) window.requested_image_sizes.remove(nkey);
                                                        } catch (GLib.Error e1) { }
                                                    }
                                                } catch (GLib.Error e) {
                                                    var list2 = window.pending_downloads.get(url);
                                                    if (list2 != null) {
                                                        foreach (var pic in list2) { set_fallback_placeholder_for(pic, target_w, target_h, url); window.on_image_loaded(pic); }
                                                        window.pending_downloads.remove(url);
                                                        try { window.requested_image_sizes.remove(url); } catch (GLib.Error e2) { }
                                                        try {
                                                            string nkey = UrlUtils.normalize_article_url(url);
                                                            if (nkey != null && nkey.length > 0) window.requested_image_sizes.remove(nkey);
                                                        } catch (GLib.Error e2) { }
                                                    }
                                                }
                                                return false;
                                            });
                                        } else {
                                            var pb_for_idle = pix;
                                            Idle.add(() => {
                                                if (window.fetch_sequence != gen_seq) {
                                                    try { window.pending_downloads.remove(url); } catch (GLib.Error e) { }
                                                    try { window.requested_image_sizes.remove(url); } catch (GLib.Error e) { }
                                                    try {
                                                        string nkey = UrlUtils.normalize_article_url(url);
                                                        if (nkey != null && nkey.length > 0) window.requested_image_sizes.remove(nkey);
                                                    } catch (GLib.Error e) { }
                                                    return false;
                                                }
                                                try {
                                                    // Cache pixbuf and emit transient textures to widgets
                                                    string any_key = window.make_cache_key(url, pb_for_idle.get_width(), pb_for_idle.get_height());
                                                    try {
                                                        if (window.image_cache != null) window.image_cache.set(any_key, pb_for_idle);
                                                        else ImageCache.get_global().set(any_key, pb_for_idle);
                                                    } catch (GLib.Error e) { }
                                                    var list2 = window.pending_downloads.get(url);
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
                                                            window.on_image_loaded(pic);
                                                        }
                                                        window.pending_downloads.remove(url);
                                                        try { window.requested_image_sizes.remove(url); } catch (GLib.Error e1) { }
                                                        try {
                                                            string nkey = UrlUtils.normalize_article_url(url);
                                                            if (nkey != null && nkey.length > 0) window.requested_image_sizes.remove(nkey);
                                                        } catch (GLib.Error e1) { }
                                                    }
                                                } catch (GLib.Error e) {
                                                    var list2 = window.pending_downloads.get(url);
                                                    if (list2 != null) {
                                                        foreach (var pic in list2) { set_fallback_placeholder_for(pic, target_w, target_h, url); window.on_image_loaded(pic); }
                                                        window.pending_downloads.remove(url);
                                                        try { window.requested_image_sizes.remove(url); } catch (GLib.Error e2) { }
                                                        try {
                                                            string nkey = UrlUtils.normalize_article_url(url);
                                                            if (nkey != null && nkey.length > 0) window.requested_image_sizes.remove(nkey);
                                                        } catch (GLib.Error e2) { }
                                                    }
                                                }
                                                return false;
                                            });
                                        }
                                    } catch (GLib.Error e) {
                                        var list2 = window.pending_downloads.get(url);
                                        if (list2 != null) {
                                                        foreach (var pic in list2) { set_fallback_placeholder_for(pic, target_w, target_h, url); window.on_image_loaded(pic); }
                                            window.pending_downloads.remove(url);
                                            try { window.requested_image_sizes.remove(url); } catch (GLib.Error e3) { }
                                            try {
                                                string nkey = UrlUtils.normalize_article_url(url);
                                                if (nkey != null && nkey.length > 0) window.requested_image_sizes.remove(nkey);
                                            } catch (GLib.Error e3) { }
                                        }
                                    }
                                } else {
                                    var pb_for_idle = pix;
                                    Idle.add(() => {
                                        if (window.fetch_sequence != gen_seq) {
                                            try { window.pending_downloads.remove(url); } catch (GLib.Error e) { }
                                            try { window.requested_image_sizes.remove(url); } catch (GLib.Error e) { }
                                            try {
                                                string nkey = UrlUtils.normalize_article_url(url);
                                                if (nkey != null && nkey.length > 0) window.requested_image_sizes.remove(nkey);
                                            } catch (GLib.Error e) { }
                                            return false;
                                        }
                                        try {
                                            string size_key = window.make_cache_key(url, target_w, target_h);
                                            try { if (window.image_cache != null) window.image_cache.set(size_key, pb_for_idle); else ImageCache.get_global().set(size_key, pb_for_idle); } catch (GLib.Error e) { }
                                            if (pb_for_idle.get_width() <= 64 && pb_for_idle.get_height() <= 64) {
                                                try {
                                                    string any_key2 = window.make_cache_key(url, 0, 0);
                                                    if (window.image_cache != null) window.image_cache.set(any_key2, pb_for_idle);
                                                    else ImageCache.get_global().set(any_key2, pb_for_idle);
                                                } catch (GLib.Error e) { }
                                            }

                                            var list2 = window.pending_downloads.get(url);
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
                                                    window.on_image_loaded(pic);
                                                }
                                                window.pending_downloads.remove(url);
                                                try { window.requested_image_sizes.remove(url); } catch (GLib.Error e4) { }
                                                try {
                                                    string nkey = UrlUtils.normalize_article_url(url);
                                                    if (nkey != null && nkey.length > 0) window.requested_image_sizes.remove(nkey);
                                                } catch (GLib.Error e4) { }
                                            }
                                        } catch (GLib.Error e) {
                                                    var list2 = window.pending_downloads.get(url);
                                                    if (list2 != null) {
                                                        foreach (var pic in list2) { set_fallback_placeholder_for(pic, target_w, target_h, url); window.on_image_loaded(pic); }
                                                        window.pending_downloads.remove(url);
                                                        try { window.requested_image_sizes.remove(url); } catch (GLib.Error e2) { }
                                                        try {
                                                            string nkey = UrlUtils.normalize_article_url(url);
                                                            if (nkey != null && nkey.length > 0) window.requested_image_sizes.remove(nkey);
                                                        } catch (GLib.Error e2) { }
                                                    }
                                        }
                                        return false;
                                    });
                                }
                            }
                        } catch (GLib.Error e) {
                            var list2 = window.pending_downloads.get(url);
                            if (list2 != null) {
                                                        foreach (var pic in list2) { set_fallback_placeholder_for(pic, target_w, target_h, url); window.on_image_loaded(pic); }
                                window.pending_downloads.remove(url);
                                try { window.requested_image_sizes.remove(url); } catch (GLib.Error e6) { }
                                try {
                                    string nkey = UrlUtils.normalize_article_url(url);
                                    if (nkey != null && nkey.length > 0) window.requested_image_sizes.remove(nkey);
                                } catch (GLib.Error e6) { }
                            }
                        }
                    } else {
                                    Idle.add(() => {
                                        if (window.fetch_sequence != gen_seq) {
                                            try { window.pending_downloads.remove(url); } catch (GLib.Error e) { }
                                            try { window.requested_image_sizes.remove(url); } catch (GLib.Error e) { }
                                            try {
                                                string nkey = UrlUtils.normalize_article_url(url);
                                                if (nkey != null && nkey.length > 0) window.requested_image_sizes.remove(nkey);
                                            } catch (GLib.Error e) { }
                                            return false;
                                        }
                            var list2 = window.pending_downloads.get(url);
                            if (list2 != null) {
                                foreach (var pic in list2) { set_fallback_placeholder_for(pic, target_w, target_h, url); window.on_image_loaded(pic); }
                                window.pending_downloads.remove(url);
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

                        // Note: Response headers (ETag, Last-Modified, Content-Type) not captured in HttpClient migration
                        etag = null;
                        last_modified = null;
                        content_type = null;

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
                                    string scale_key = window.make_cache_key(url, new_width, new_height);
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
                                        string scale_key = window.make_cache_key(url, new_width, new_height);
                                        var scaled = window.image_cache != null ? window.image_cache.get_or_scale_pixbuf(scale_key, pixbuf, new_width, new_height) : ImageCache.get_global().get_or_scale_pixbuf(scale_key, pixbuf, new_width, new_height);
                                        if (scaled != null) pixbuf = scaled;
                                    } catch (GLib.Error e) { }
                                }
                            }

                            var pb_for_idle = pixbuf;
                            Idle.add(() => {
                                if (window.fetch_sequence != gen_seq) {
                                    try { window.pending_downloads.remove(url); } catch (GLib.Error e) { }
                                    return false;
                                }
                                try {
                                    string size_key = window.make_cache_key(url, target_w, target_h);
                                    try { if (window.image_cache != null) window.image_cache.set(size_key, pb_for_idle); else ImageCache.get_global().set(size_key, pb_for_idle); } catch (GLib.Error e) { }

                                    var list = window.pending_downloads.get(url);
                                    if (list != null) {
                                        foreach (var pic in list) {
                                            try {
                                                var tex = window.image_cache != null ? window.image_cache.get_texture(size_key) : ImageCache.get_global().get_texture(size_key);
                                                if (tex != null) {
                                                    pic.set_paintable(tex);
                                                    try { if (window.pending_local_placeholder != null) window.pending_local_placeholder.remove(pic); } catch (GLib.Error e) { }
                                                } else {
                                                    try { pic.set_paintable(Gdk.Texture.for_pixbuf(pb_for_idle)); } catch (GLib.Error e) { set_fallback_placeholder_for(pic, target_w, target_h, url); }
                                                }
                                            } catch (GLib.Error e) { set_fallback_placeholder_for(pic, target_w, target_h, url); }
                                            window.on_image_loaded(pic);
                                        }
                                        window.pending_downloads.remove(url);
                                    }
                                } catch (GLib.Error e) {
                                    var list = window.pending_downloads.get(url);
                                    if (list != null) {
                                        foreach (var pic in list) {
                                            set_fallback_placeholder_for(pic, target_w, target_h, url);
                                            window.on_image_loaded(pic);
                                        }
                                        window.pending_downloads.remove(url);
                                    }
                                }
                                return false;
                            });
                        } else {
                            Idle.add(() => {
                                var list = window.pending_downloads.get(url);
                                if (list != null) {
                                    foreach (var pic in list) {
                                        set_fallback_placeholder_for(pic, target_w, target_h, url);
                                        window.on_image_loaded(pic);
                                    }
                                    window.pending_downloads.remove(url);
                                }
                                return false;
                            });
                        }
                    } catch (GLib.Error e) {
                        // Error during image decode - make sure to unref msg if we haven't already
                        Idle.add(() => {
                            var list = window.pending_downloads.get(url);
                            if (list != null) {
                                foreach (var pic in list) {
                                    set_fallback_placeholder_for(pic, target_w, target_h, url);
                                    window.on_image_loaded(pic);
                                }
                                window.pending_downloads.remove(url);
                            }
                            return false;
                        });
                    }
                } else {
                    // Status is not 200 or 304
                    Idle.add(() => {
                        if (window.fetch_sequence != gen_seq) {
                            try { window.pending_downloads.remove(url); } catch (GLib.Error e) { }
                            return false;
                        }
                        var list = window.pending_downloads.get(url);
                        if (list != null) {
                            foreach (var pic in list) {
                                    set_fallback_placeholder_for(pic, target_w, target_h, url);
                                window.on_image_loaded(pic);
                            }
                            window.pending_downloads.remove(url);
                        }
                        return false;
                    });
                }
            } catch (GLib.Error e) {
                Idle.add(() => {
                    var list = window.pending_downloads.get(url);
                    if (list != null) {
                        foreach (var pic in list) {
                            set_fallback_placeholder_for(pic, target_w, target_h, url);
                            window.on_image_loaded(pic);
                        }
                        window.pending_downloads.remove(url);
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
                    var list = window.pending_downloads.get(url);
                    if (list != null) {
                                foreach (var pic in list) {
                                    set_fallback_placeholder_for(pic, target_w, target_h, url);
                                    window.on_image_loaded(pic);
                                }
                        window.pending_downloads.remove(url);
                        try { window.requested_image_sizes.remove(url); } catch (GLib.Error e) { }
                        try {
                            string nkey = UrlUtils.normalize_article_url(url);
                            if (nkey != null && nkey.length > 0) window.requested_image_sizes.remove(nkey);
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
                    window.requested_image_sizes.set(url, "%dx%d".printf(target_w, target_h));
                    try {
                        string nkey = UrlUtils.normalize_article_url(url);
                        if (nkey != null && nkey.length > 0) window.requested_image_sizes.set(nkey, "%dx%d".printf(target_w, target_h));
                    } catch (GLib.Error e) { }

                    window.deferred_downloads.set(image, new DeferredRequest(url, target_w, target_h));
                    if (window.deferred_check_timeout_id == 0) {
                        window.deferred_check_timeout_id = Timeout.add(1000, () => {
                            try { window.process_deferred_downloads(); } catch (GLib.Error e) { }
                            window.deferred_check_timeout_id = 0;
                            return false;
                        });
                    }
                    return;
                }
            } catch (GLib.Error e) { }
        }

        string key = window.make_cache_key(url, target_w, target_h);
        
        // Check thumbnail cache first for small images (faster lookup, better hit rate)
        if (target_w <= 64 && target_h <= 64) {
            var any_key_thumb = window.make_cache_key(url, 0, 0);
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
                window.on_image_loaded(image);
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
            window.on_image_loaded(image);
            return;
        }

        var any_key = window.make_cache_key(url, 0, 0);
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
                window.on_image_loaded(image);
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
                                        string scale_key = window.make_cache_key(url, new_w, new_h);
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
                                            string scale_key = window.make_cache_key(url, new_w, new_h);
                                            var scaled = window.image_cache != null ? window.image_cache.get_or_scale_pixbuf(scale_key, pix, new_w, new_h) : ImageCache.get_global().get_or_scale_pixbuf(scale_key, pix, new_w, new_h);
                                            if (scaled != null) pix = scaled;
                                        } catch (GLib.Error e) { }
                                    }
                                }
                                string size_key = window.make_cache_key(url, target_w, target_h);
                                try { if (window.image_cache != null) window.image_cache.set(size_key, pix); else ImageCache.get_global().set(size_key, pix); } catch (GLib.Error e) { }
                                if (target_w <= 64 && target_h <= 64) {
                                    try {
                                        string any_key2 = window.make_cache_key(url, 0, 0);
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
                                window.on_image_loaded(image);
                                return;
                            }
                        } catch (GLib.Error e) {
                            // Fall through to network fetch
                        }
                }
            }
        } catch (GLib.Error e) { }

        var existing = window.pending_downloads.get(url);
        if (existing != null) {
            existing.add(image);
            return;
        }

        var list = new Gee.ArrayList<Gtk.Picture>();
        list.add(image);
        window.pending_downloads.set(url, list);
        window.requested_image_sizes.set(url, "%dx%d".printf(target_w, target_h));
        try {
            string nkey = UrlUtils.normalize_article_url(url);
            if (nkey != null && nkey.length > 0) window.requested_image_sizes.set(nkey, "%dx%d".printf(target_w, target_h));
        } catch (GLib.Error e) { }

        // Download at the requested size - multipliers are already applied by callers
        // (articleManager applies 6x for heroes, 3x for articles, etc.)
        // Note: Guardian URLs are upgraded to 1000px during download (their CDN allows
        // 1000px but returns 403 for larger sizes like 2000px/2400px)
        int download_w = clampi(target_w, target_w, 2400);
        int download_h = clampi(target_h, target_h, 2400);
        ensure_start_download(url, download_w, download_h);
    }
}
