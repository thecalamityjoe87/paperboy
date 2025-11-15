public class ImageHandler : GLib.Object {
    public NewsWindow window;

    public ImageHandler(NewsWindow w) {
        window = w;
    }

    // Integer clamp helper (valac doesn't provide clampi by default)
    private static int clampi(int v, int lo, int hi) {
        if (v < lo) return lo;
        if (v > hi) return hi;
        return v;
    }

    // Start a single download for a URL and update all registered targets when done.
    public void start_image_download_for_url(string url, int target_w, int target_h) {
        new Thread<void*>("pb-load-image", () => {
            GLib.AtomicInt.inc(ref NewsWindow.active_downloads);
            try {
                var msg = new Soup.Message("GET", url);
                if (window.prefs.news_source == NewsSource.REDDIT) {
                    msg.request_headers.append("User-Agent", "Mozilla/5.0 (compatible; Paperboy/1.0)");
                    msg.request_headers.append("Accept", "image/jpeg,image/png,image/webp,image/*;q=0.8");
                    msg.request_headers.append("Cache-Control", "max-age=3600");
                } else {
                    msg.request_headers.append("User-Agent", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36");
                    msg.request_headers.append("Accept", "image/webp,image/png,image/jpeg,image/*;q=0.8");
                }
                msg.request_headers.append("Accept-Encoding", "gzip, deflate, br");

                window.session.send_message(msg);

                if (window.prefs.news_source == NewsSource.REDDIT && msg.response_body.length > 2 * 1024 * 1024) {
                    Idle.add(() => {
                        var list = window.pending_downloads.get(url);
                        if (list != null) {
                            foreach (var pic in list) {
                                window.set_placeholder_image_for_source(pic, target_w, target_h, window.infer_source_from_url(url));
                                window.on_image_loaded(pic);
                            }
                            window.pending_downloads.remove(url);
                        }
                        return false;
                    });
                    return null;
                }

                if (msg.status_code == 304) {
                    window.append_debug_log("start_image_download_for_url: 304 Not Modified for url=" + url);
                    // Not modified; refresh last-access and serve cached image
                    Idle.add(() => {
                        if (window.meta_cache != null) window.meta_cache.touch(url);
                        var path = window.meta_cache != null ? window.meta_cache.get_cached_path(url) : null;
                        if (path != null) {
                            window.append_debug_log("start_image_download_for_url: serving disk-cached path=" + path + " for url=" + url);
                            try {
                                Gdk.Texture? texture = null;
                                var pix = new Gdk.Pixbuf.from_file(path);

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

                                var size_rec = window.requested_image_sizes.get(url);
                                if (pix != null && size_rec != null && size_rec.length > 0) {
                                    try {
                                        string[] parts = size_rec.split("x");
                                        if (parts.length == 2) {
                                            int sw = int.parse(parts[0]);
                                            int sh = int.parse(parts[1]);
                                            int eff_sw = sw * device_scale;
                                            int eff_sh = sh * device_scale;
                                            try { window.append_debug_log("start_image_download_for_url: 304 serving url=" + url + " requested=" + sw.to_string() + "x" + sh.to_string() + " device_scale=" + device_scale.to_string() + " eff_target=" + eff_sw.to_string() + "x" + eff_sh.to_string() + " pix_before=" + pix.get_width().to_string() + "x" + pix.get_height().to_string()); } catch (GLib.Error e) { }
                                            double sc = double.min((double) eff_sw / pix.get_width(), (double) eff_sh / pix.get_height());
                                            if (sc < 1.0) {
                                                int nw = (int)(pix.get_width() * sc);
                                                if (nw < 1) nw = 1;
                                                int nh = (int)(pix.get_height() * sc);
                                                if (nh < 1) nh = 1;
                                                try { pix = pix.scale_simple(nw, nh, Gdk.InterpType.HYPER); } catch (GLib.Error e) { }
                                            }
                                            texture = Gdk.Texture.for_pixbuf(pix);
                                            string k = window.make_cache_key(url, sw, sh);
                                            window.memory_meta_cache.set(k, texture);
                                            if (sw <= 64 && sh <= 64) window.memory_meta_cache.set(url, texture);
                                            try { window.append_debug_log("start_image_download_for_url: 304 cached size_key=" + k + " pix_after=" + pix.get_width().to_string() + "x" + pix.get_height().to_string()); } catch (GLib.Error e) { }
                                        } else {
                                            texture = Gdk.Texture.for_pixbuf(pix);
                                            if (pix.get_width() <= 64 && pix.get_height() <= 64) window.memory_meta_cache.set(url, texture);
                                        }
                                    } catch (GLib.Error e) {
                                        texture = Gdk.Texture.for_pixbuf(pix);
                                        if (pix.get_width() <= 64 && pix.get_height() <= 64) window.memory_meta_cache.set(url, texture);
                                    }
                                } else if (pix != null) {
                                    texture = Gdk.Texture.for_pixbuf(pix);
                                    if (pix.get_width() <= 64 && pix.get_height() <= 64) window.memory_meta_cache.set(url, texture);
                                }
                                var list2 = window.pending_downloads.get(url);
                                if (list2 != null) {
                                    foreach (var pic in list2) {
                                        if (texture != null) pic.set_paintable(texture);
                                        else window.set_placeholder_image_for_source(pic, target_w, target_h, window.infer_source_from_url(url));
                                        window.on_image_loaded(pic);
                                    }
                                    window.pending_downloads.remove(url);
                                }
                            } catch (GLib.Error e) {
                                var list2 = window.pending_downloads.get(url);
                                if (list2 != null) {
                                    foreach (var pic in list2) { window.set_placeholder_image_for_source(pic, target_w, target_h, window.infer_source_from_url(url)); window.on_image_loaded(pic); }
                                    window.pending_downloads.remove(url);
                                }
                            }
                        } else {
                            var list2 = window.pending_downloads.get(url);
                            if (list2 != null) {
                                foreach (var pic in list2) { window.set_placeholder_image_for_source(pic, target_w, target_h, window.infer_source_from_url(url)); window.on_image_loaded(pic); }
                                window.pending_downloads.remove(url);
                            }
                        }
                        return false;
                    });
                    return null;
                }

                if (msg.status_code == 200 && msg.response_body.length > 0) {
                    try {
                        uint8[] data = new uint8[msg.response_body.length];
                        Memory.copy(data, msg.response_body.data, (size_t)msg.response_body.length);

                        if (window.meta_cache != null) {
                            string? etg = null;
                            string? lm2 = null;
                            try { etg = msg.response_headers.get_one("ETag"); } catch (GLib.Error e) { etg = null; }
                            try { lm2 = msg.response_headers.get_one("Last-Modified"); } catch (GLib.Error e) { lm2 = null; }
                            try {
                                string? ct = null;
                                try { ct = msg.response_headers.get_one("Content-Type"); } catch (GLib.Error e) { ct = null; }
                                window.meta_cache.write_cache(url, data, etg, lm2, ct);
                                window.append_debug_log("start_image_download_for_url: wrote disk cache for url=" + url + " etag=" + (etg != null ? etg : "<null>"));
                            } catch (GLib.Error e) { }
                        }

                        var loader = new Gdk.PixbufLoader();
                        loader.write(data);
                        loader.close();
                        var pixbuf = loader.get_pixbuf();
                        if (pixbuf != null) {
                            int width = pixbuf.get_width();
                            int height = pixbuf.get_height();
                            try { window.append_debug_log("start_image_download_for_url: decoded url=" + url + " orig=" + width.to_string() + "x" + height.to_string() + " requested=" + target_w.to_string() + "x" + target_h.to_string()); } catch (GLib.Error e) { }
                            double scale = double.min((double) target_w / width, (double) target_h / height);
                            if (scale < 1.0) {
                                int new_width = (int)(width * scale);
                                if (new_width < 1) new_width = 1;
                                int new_height = (int)(height * scale);
                                if (new_height < 1) new_height = 1;
                                try { pixbuf = pixbuf.scale_simple(new_width, new_height, Gdk.InterpType.HYPER); } catch (GLib.Error e) { }
                                try { window.append_debug_log("start_image_download_for_url: scaled-down url=" + url + " to=" + pixbuf.get_width().to_string() + "x" + pixbuf.get_height().to_string()); } catch (GLib.Error e) { }
                            } else if (scale > 1.0) {
                                double max_upscale = 2.0;
                                double upscale = double.min(scale, max_upscale);
                                int new_width = (int)(width * upscale);
                                int new_height = (int)(height * upscale);
                                if (upscale > 1.01) {
                                    try { pixbuf = pixbuf.scale_simple(new_width, new_height, Gdk.InterpType.HYPER); } catch (GLib.Error e) { }
                                    try { window.append_debug_log("start_image_download_for_url: upscaled url=" + url + " to=" + pixbuf.get_width().to_string() + "x" + pixbuf.get_height().to_string()); } catch (GLib.Error e) { }
                                }
                            }

                            var pb_for_idle = pixbuf;
                            Idle.add(() => {
                                try {
                                    var texture = Gdk.Texture.for_pixbuf(pb_for_idle);
                                    string size_key = window.make_cache_key(url, target_w, target_h);
                                    window.memory_meta_cache.set(size_key, texture);
                                    try { window.append_debug_log("start_image_download_for_url: cached memory size_key=" + size_key + " url=" + url + " tex_size=" + pb_for_idle.get_width().to_string() + "x" + pb_for_idle.get_height().to_string()); } catch (GLib.Error e) { }

                                    var list = window.pending_downloads.get(url);
                                    if (list != null) {
                                        foreach (var pic in list) {
                                            pic.set_paintable(texture);
                                            window.on_image_loaded(pic);
                                        }
                                        window.pending_downloads.remove(url);
                                    }
                                } catch (GLib.Error e) {
                                    var list = window.pending_downloads.get(url);
                                    if (list != null) {
                                        foreach (var pic in list) {
                                            window.set_placeholder_image_for_source(pic, target_w, target_h, window.infer_source_from_url(url));
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
                                        window.set_placeholder_image_for_source(pic, target_w, target_h, window.infer_source_from_url(url));
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
                                    window.set_placeholder_image_for_source(pic, target_w, target_h, window.infer_source_from_url(url));
                                    window.on_image_loaded(pic);
                                }
                                window.pending_downloads.remove(url);
                            }
                            return false;
                        });
                    }
                } else {
                    Idle.add(() => {
                        var list = window.pending_downloads.get(url);
                        if (list != null) {
                            foreach (var pic in list) {
                                    window.set_placeholder_image_for_source(pic, target_w, target_h, window.infer_source_from_url(url));
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
                            window.set_placeholder_image_for_source(pic, target_w, target_h, window.infer_source_from_url(url));
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
        int cap = window.initial_phase ? NewsWindow.INITIAL_PHASE_MAX_CONCURRENT_DOWNLOADS : NewsWindow.MAX_CONCURRENT_DOWNLOADS;
        if (NewsWindow.active_downloads >= cap) {
            Timeout.add(150, () => { ensure_start_download(url, target_w, target_h); return false; });
            return;
        }
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
                        window.deferred_check_timeout_id = Timeout.add(500, () => {
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
        var cached = window.memory_meta_cache.get(key);
        if (cached != null) {
            window.append_debug_log("load_image_async: memory cache hit key=" + key + " url=" + url + " size=" + target_w.to_string() + "x" + target_h.to_string());
            image.set_paintable(cached);
            window.on_image_loaded(image);
            return;
        }

        var cached_any = window.memory_meta_cache.get(url);
        if (cached_any != null) {
            if (target_w <= 64 && target_h <= 64) {
                window.append_debug_log("load_image_async: memory cache (any-size) hit (small target) url=" + url + " size=" + target_w.to_string() + "x" + target_h.to_string());
                image.set_paintable(cached_any);
                window.on_image_loaded(image);
                return;
            } else {
                window.append_debug_log("load_image_async: memory cache (any-size) hit but skipping due to size mismatch url=" + url + " requested=" + target_w.to_string() + "x" + target_h.to_string());
            }
        }

        try {
            if (window.meta_cache != null) {
                var disk_path = window.meta_cache.get_cached_path(url);
                if (disk_path != null) {
                    window.append_debug_log("load_image_async: disk cache hit path=" + disk_path + " url=" + url + " size=" + target_w.to_string() + "x" + target_h.to_string());
                        try {
                            var pix = new Gdk.Pixbuf.from_file(disk_path);
                            if (pix != null) {
                                int device_scale = 1;
                                try { device_scale = image.get_scale_factor(); if (device_scale < 1) device_scale = 1; } catch (GLib.Error e) { device_scale = 1; }

                                int eff_target_w = target_w * device_scale;
                                int eff_target_h = target_h * device_scale;

                                int width = pix.get_width();
                                int height = pix.get_height();
                                double scale = double.min((double) eff_target_w / width, (double) eff_target_h / height);
                                if (scale < 1.0) {
                                    int new_w = (int)(width * scale);
                                    if (new_w < 1) new_w = 1;
                                    int new_h = (int)(height * scale);
                                    if (new_h < 1) new_h = 1;
                                    try { pix = pix.scale_simple(new_w, new_h, Gdk.InterpType.HYPER); } catch (GLib.Error e) { }
                                }
                                try { window.append_debug_log("load_image_async: disk-cached path=" + disk_path + " url=" + url + " requested=" + target_w.to_string() + "x" + target_h.to_string() + " device_scale=" + device_scale.to_string() + " pix_after=" + pix.get_width().to_string() + "x" + pix.get_height().to_string()); } catch (GLib.Error e) { }
                                var tex = Gdk.Texture.for_pixbuf(pix);
                                string size_key = window.make_cache_key(url, target_w, target_h);
                                window.memory_meta_cache.set(size_key, tex);
                                if (target_w <= 64 && target_h <= 64) window.memory_meta_cache.set(url, tex);
                                image.set_paintable(tex);
                                window.on_image_loaded(image);
                                try { window.append_debug_log("load_image_async: disk-cached served url=" + url + " size_key=" + size_key); } catch (GLib.Error e) { }
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
            window.append_debug_log("load_image_async: pending download exists, enqueueing url=" + url + " size=" + target_w.to_string() + "x" + target_h.to_string());
            existing.add(image);
            return;
        }

        var list = new Gee.ArrayList<Gtk.Picture>();
        list.add(image);
        window.pending_downloads.set(url, list);
        window.append_debug_log("load_image_async: queued download url=" + url + " size=" + target_w.to_string() + "x" + target_h.to_string());
        window.requested_image_sizes.set(url, "%dx%d".printf(target_w, target_h));
        try {
            string nkey = UrlUtils.normalize_article_url(url);
            if (nkey != null && nkey.length > 0) window.requested_image_sizes.set(nkey, "%dx%d".printf(target_w, target_h));
        } catch (GLib.Error e) { }

        int download_w = target_w;
        int download_h = target_h;
        try {
            if (window.initial_phase && target_w >= 160) {
                download_w = clampi(target_w * 2, target_w, 1600);
                download_h = clampi(target_h * 2, target_h, 1600);
                window.append_debug_log("load_image_async: initial_phase bump request for url=" + url + " requested=" + target_w.to_string() + "x" + target_h.to_string() + " -> download=" + download_w.to_string() + "x" + download_h.to_string());
            }
        } catch (GLib.Error e) { }
        ensure_start_download(url, download_w, download_h);
    }
}
