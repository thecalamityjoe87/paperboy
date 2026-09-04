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
    public weak NewsWindow window;
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

    string? size_rec = null;
        size_rec = requested_image_sizes.get(url); 

    // Capture a few more main-thread-only references/values so the
    // worker doesn't dereference `window` fields from a background
    // thread. This keeps the worker self-contained and avoids
    // potential races on `window` pointer fields.
    NewsSource news_src = NewsSource.GUARDIAN;
        news_src = window.prefs.news_source; 
    var session = window.session;
    var meta_cache = window.meta_cache;

        // Concurrency is already bounded by the caller (ensure_start_download
        // admits at most MAX_CONCURRENT_DOWNLOADS at a time), so a plain
        // per-call thread is fine here.
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

                var client = Paperboy.HttpClientUtils.get_default();
                var options = new Paperboy.HttpClientUtils.RequestOptions().with_image_headers();
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
                                    if (window.loading_state != null) window.loading_state.on_image_loaded(pic);
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
                                            string k = make_cache_key(url, sw, sh);
                                            // Create a cover-scaled & center-cropped pixbuf for the requested size
                                            try {
                                                var final_pb = window.image_cache != null ? window.image_cache.get_or_scale_and_crop_pixbuf(k, pix, eff_sw, eff_sh) : ImageCache.get_global().get_or_scale_and_crop_pixbuf(k, pix, eff_sw, eff_sh);
                                                if (final_pb != null) pix = final_pb;
                                            } catch (GLib.Error e) { }
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
                                                            if (window.loading_state != null) window.loading_state.on_image_loaded(pic);
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
                                                        foreach (var pic in list2) { set_fallback_placeholder_for(pic, target_w, target_h, url); if (window.loading_state != null) window.loading_state.on_image_loaded(pic); }
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
                                                            if (window.loading_state != null) window.loading_state.on_image_loaded(pic);
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
                                                        foreach (var pic in list2) { set_fallback_placeholder_for(pic, target_w, target_h, url); if (window.loading_state != null) window.loading_state.on_image_loaded(pic); }
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
                                            foreach (var pic in list2) { set_fallback_placeholder_for(pic, target_w, target_h, url); if (window.loading_state != null) window.loading_state.on_image_loaded(pic); }
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
                                                    if (window.loading_state != null) window.loading_state.on_image_loaded(pic);
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
                                                foreach (var pic in list2) { set_fallback_placeholder_for(pic, target_w, target_h, url); if (window.loading_state != null) window.loading_state.on_image_loaded(pic); }
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
                                foreach (var pic in list2) { set_fallback_placeholder_for(pic, target_w, target_h, url); if (window.loading_state != null) window.loading_state.on_image_loaded(pic); }
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
                                foreach (var pic in list2) { set_fallback_placeholder_for(pic, target_w, target_h, url); if (window.loading_state != null) window.loading_state.on_image_loaded(pic); }
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

                            // Use COVER strategy: scale so image fully covers the target, then center-crop
                            int eff_w = target_w * device_scale;
                            int eff_h = target_h * device_scale;

                            string size_key = make_cache_key(url, target_w, target_h);
                            try {
                                var final_pb = window.image_cache != null ? window.image_cache.get_or_scale_and_crop_pixbuf(size_key, pixbuf, eff_w, eff_h) : ImageCache.get_global().get_or_scale_and_crop_pixbuf(size_key, pixbuf, eff_w, eff_h);
                                if (final_pb != null) {
                                    pixbuf = final_pb;
                                }
                            } catch (GLib.Error e) { }

                            var pb_for_idle = pixbuf;
                            Idle.add(() => {
                                if (FetchContext.current != gen_seq) {
                                    try { pending_downloads.remove(url); } catch (GLib.Error e) { }
                                    return false;
                                }
                                try {
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
                                            if (window.loading_state != null) window.loading_state.on_image_loaded(pic);
                                        }
                                        pending_downloads.remove(url);
                                    }
                                } catch (GLib.Error e) {
                                    var list = pending_downloads.get(url);
                                    if (list != null) {
                                        foreach (var pic in list) {
                                            set_fallback_placeholder_for(pic, target_w, target_h, url);
                                            if (window.loading_state != null) window.loading_state.on_image_loaded(pic);
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
                                        if (window.loading_state != null) window.loading_state.on_image_loaded(pic);
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
                                    if (window.loading_state != null) window.loading_state.on_image_loaded(pic);
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
                                if (window.loading_state != null) window.loading_state.on_image_loaded(pic);
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
                            if (window.loading_state != null) window.loading_state.on_image_loaded(pic);
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
                            if (window.loading_state != null) window.loading_state.on_image_loaded(pic);
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

        // CRITICAL FIX: Revert to old behavior - ALWAYS defer hidden images during initial_phase
        // The refactor changed this to skip_defer=true during initial_phase, which caused
        // set_paintable() to be called on hidden widgets. GTK doesn't render paintables
        // set on invisible widgets, causing blank images at startup.
        bool skip_defer = false;  // Never skip deferral based on initial_phase

        if (!force && !skip_defer) {
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
                var tex = window.image_cache != null ? window.image_cache.get_texture(any_key_thumb) : ImageCache.get_global().get_texture(any_key_thumb);
                if (tex != null) {
                    image.set_paintable(tex);
                } else {
                    try { image.set_paintable(Gdk.Texture.for_pixbuf(thumb_pb)); } catch (GLib.Error e) { }
                }
                if (window.loading_state != null) window.loading_state.on_image_loaded(image);
                return;
            }
        }

        // Check main memory cache (now stored as pixbufs in ImageCache)
        var cached_pb = window.image_cache != null ? window.image_cache.get(key) : ImageCache.get_global().get(key);
        if (cached_pb != null) {
            var tex = window.image_cache != null ? window.image_cache.get_texture(key) : ImageCache.get_global().get_texture(key);
            if (tex != null) {
                image.set_paintable(tex);
            } else {
                try { image.set_paintable(Gdk.Texture.for_pixbuf(cached_pb)); } catch (GLib.Error e) { }
            }
            if (window.loading_state != null) window.loading_state.on_image_loaded(image);
            return;
        }

        var any_key = make_cache_key(url, 0, 0);
        var cached_any_pb = window.image_cache != null ? window.image_cache.get(any_key) : ImageCache.get_global().get(any_key);
        if (cached_any_pb != null) {
                if (target_w <= 64 && target_h <= 64) {
                    var tex = window.image_cache != null ? window.image_cache.get_texture(any_key) : ImageCache.get_global().get_texture(any_key);
                if (tex != null) {
                    image.set_paintable(tex);
                } else {
                    try { image.set_paintable(Gdk.Texture.for_pixbuf(cached_any_pb)); } catch (GLib.Error e) { }
                }
                if (window.loading_state != null) window.loading_state.on_image_loaded(image);
                return;
            } else {
            }
        }

        // Shared fallback: register `image` as waiting for `url` and start
        // (or join) a network download for it. Used both when there's no
        // disk-cached copy at all, and when decoding a disk-cached copy
        // fails (mirrors the original inline fallthrough behavior).
        void network_fallback() {
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
            ensure_start_download(url, download_w, download_h);
        }

        if (window.meta_cache != null) {
            var disk_path = window.meta_cache.get_cached_path(url);
            if (disk_path != null) {
                // PERFORMANCE: decoding + scale/crop of an on-disk cached
                // thumbnail is real CPU work (JPEG/PNG decode, bilinear
                // scale). This used to run inline on the caller's thread,
                // which is the main thread for every card built during
                // article insertion - on views with many already-cached
                // thumbnails (Front Page especially, which can have far
                // more cards than any single-source view) that added up
                // to several seconds of main-thread work and visible
                // churn. Do the decode/scale off the main thread instead,
                // mirroring the pattern already used for network
                // downloads below: only the final texture/cache write
                // touches GTK state, via Idle.add.
                int device_scale = 1;
                try { device_scale = image.get_scale_factor(); if (device_scale < 1) device_scale = 1; } catch (GLib.Error e) { device_scale = 1; }
                var img_cache = window.image_cache;

                new Thread<void*>("cached-image-load", () => {
                    try {
                        string file_key = "pixbuf::file:%s::%dx%d".printf(disk_path, 0, 0);
                        var pix = img_cache != null ? img_cache.get_or_load_file(file_key, disk_path, 0, 0) : ImageCache.get_global().get_or_load_file(file_key, disk_path, 0, 0);
                        if (pix != null) {
                            int eff_target_w = target_w * device_scale;
                            int eff_target_h = target_h * device_scale;

                            // Use COVER strategy: scale so image fully covers the (device-scaled) target, then crop
                            string size_key = make_cache_key(url, target_w, target_h);
                            try {
                                var final_pb = img_cache != null ? img_cache.get_or_scale_and_crop_pixbuf(size_key, pix, eff_target_w, eff_target_h) : ImageCache.get_global().get_or_scale_and_crop_pixbuf(size_key, pix, eff_target_w, eff_target_h);
                                if (final_pb != null) pix = final_pb;
                            } catch (GLib.Error e) { }

                            Gdk.Pixbuf pix_for_idle = pix;
                            Idle.add(() => {
                                try { if (img_cache != null) img_cache.set(size_key, pix_for_idle); else ImageCache.get_global().set(size_key, pix_for_idle); } catch (GLib.Error e) { }
                                if (target_w <= 64 && target_h <= 64) {
                                    try {
                                        string any_key2 = make_cache_key(url, 0, 0);
                                        if (img_cache != null) img_cache.set(any_key2, pix_for_idle);
                                        else ImageCache.get_global().set(any_key2, pix_for_idle);
                                    } catch (GLib.Error e) { }
                                }
                                try {
                                    var tex = img_cache != null ? img_cache.get_texture(size_key) : ImageCache.get_global().get_texture(size_key);
                                    if (tex != null) {
                                        image.set_paintable(tex);
                                    } else {
                                        try { image.set_paintable(Gdk.Texture.for_pixbuf(pix_for_idle)); } catch (GLib.Error e) { }
                                    }
                                } catch (GLib.Error e) { }
                                if (window.loading_state != null) window.loading_state.on_image_loaded(image);
                                return false;
                            });
                            return null;
                        }
                    } catch (GLib.Error e) {
                        // fall through to the Idle.add below
                    }
                    // Disk cache read/decode failed - fall back to a
                    // network download, same as the original inline
                    // behavior. network_fallback() touches GTK/instance
                    // state, so it must run on the main thread.
                    Idle.add(() => {
                        network_fallback();
                        return false;
                    });
                    return null;
                });
                return;
            }
        }

        network_fallback();
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
            DeferredRequest req = kv.value;
            bool vis = false;
            vis = pic.get_visible(); 
            if (vis) {
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

                int new_w = (int)(last_w * 2);
                int new_h = (int)(last_h * 2);
                new_w = clampi(new_w, last_w, 1600);
                new_h = clampi(new_h, last_h, 1600);

                bool has_large = false;
                string key_norm = make_cache_key(norm_url, new_w, new_h);
                if ((window.image_cache != null ? window.image_cache.get(key_norm) : ImageCache.get_global().get(key_norm)) != null) has_large = true;

                string? original = null;
                if (window.view_state != null) original = window.view_state.normalized_to_url.get(norm_url); 
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
            var first = widget.get_first_child();
            var current = first;
            while (current != null) {
                refresh_pictures_in_widget(current);
                current = current.get_next_sibling();
            }
        }
    }

    // Called when an image finished loading
    public void on_image_loaded(Gtk.Picture image) {
        if (window.loading_state == null) return;
        if (!window.loading_state.initial_phase) return;
        if (hero_requests.get(image) != null) window.loading_state.hero_image_loaded = true;

        // Decrement pending_images as images finish loading
        if (window.loading_state.pending_images > 0) window.loading_state.pending_images--;
    }
}

