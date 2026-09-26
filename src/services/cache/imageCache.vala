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

using GLib;
using Gee;
using Gdk;
using Cairo;

/*
 * ImageCache: an in-memory LRU cache for Gdk.Pixbuf and Gdk.Texture objects.
 * Stores both pixbufs and textures to avoid redundant texture creation.
 */

public class ImageCache : GLib.Object {
    private LruCache<string, Gdk.Pixbuf> pixbuf_cache;
    private LruCache<string, Gdk.Texture> texture_cache;
    private static ImageCache? global_instance = null;

    // Byte cap, not just entry count: a few oversized hero/carousel decodes
    // could otherwise blow past a count-based limit.
    private const int64 MAX_PIXBUF_CACHE_BYTES = 200 * 1024 * 1024;

    public ImageCache(int capacity = 256) {
        GLib.Object();
        pixbuf_cache = new LruCache<string, Gdk.Pixbuf>(capacity);
        texture_cache = new LruCache<string, Gdk.Texture>(capacity);
        pixbuf_cache.set_byte_budget(MAX_PIXBUF_CACHE_BYTES, (key, pixbuf) => {
            return (int64) pixbuf.get_byte_length();
        });
        texture_cache.set_byte_budget(MAX_PIXBUF_CACHE_BYTES, (key, tex) => {
            return (int64) tex.get_width() * tex.get_height() * 4;
        });

        // Gee ref/unrefs GObject values automatically on insert/remove, so
        // we don't manually ref/unref pixbufs or textures here.

        // A pixbuf's cached texture must be dropped along with it, or
        // get_texture() would keep serving stale content under that key.
        pixbuf_cache.set_eviction_callback((k, v) => {
            try { texture_cache.remove(k); } catch (GLib.Error e) { }
        });

        texture_cache.set_eviction_callback((k, v) => {
            if (AppDebugger.debug_enabled()) {
            }
        });
    }

    // Legacy static code delegates to this; NewsWindow sets the real
    // instance via set_global() when it creates its per-window cache.
    public static ImageCache get_global() {
        if (global_instance == null) global_instance = new ImageCache(256);
        return global_instance;
    }

    public static void set_global(ImageCache inst) {
        global_instance = inst;
    }

    public Gdk.Pixbuf? get(string key) {
        var v = pixbuf_cache.get(key);
        try {
            if (AppDebugger.debug_enabled()) {
            }
        } catch (GLib.Error e) { }
        return v;
    }

    public void set(string key, Gdk.Pixbuf pixbuf) {
        // Do not ref here. Gee containers will take their own reference
        // (g_object_ref) when storing GObject values; ref/unref is
        // therefore managed by the container.
        if (AppDebugger.debug_enabled()) {
        }
        pixbuf_cache.set(key, pixbuf);
        
        // When a new pixbuf is inserted, invalidate any cached texture for this key
        // so that get_texture() will create a fresh texture from the new pixbuf
        try {
            texture_cache.remove(key);
        } catch (GLib.Error e) { }
    }

    // Convenience: load a pixbuf from a file (scaled) if the key is missing.
    // Creation is centralized here to avoid direct Gdk.Pixbuf creation elsewhere.
    public Gdk.Pixbuf? get_or_load_file(string key, string path, int w, int h) {
        var existing = get(key);
        if (existing != null) return existing;
        try {
            Gdk.Pixbuf? pb = null;
            if (w == 0 && h == 0) {
                pb = new Gdk.Pixbuf.from_file(path);
            } else {
                pb = new Gdk.Pixbuf.from_file_at_size(path, w, h);
            }
            if (pb != null) {
                set(key, pb);
                return pb;
            }
        } catch (GLib.Error e) { }
        return null;
    }

    // Convenience: extract a pixbuf from a Cairo surface and cache it.
    public Gdk.Pixbuf? get_or_from_surface(string key, Cairo.Surface surface, int x, int y, int w, int h) {
        var existing = get(key);
        if (existing != null) return existing;
        var pb = Gdk.pixbuf_get_from_surface(surface, x, y, w, h);
        if (pb != null) {
            set(key, pb);
            return pb;
        }
        return null;
    }

    // Centralized scaling helper: given a source pixbuf, produce (and cache)
    // a scaled pixbuf under `key`. This avoids calling `scale_simple` all
    // over the codebase and centralizes pixbuf creation in ImageCache.
    public Gdk.Pixbuf? get_or_scale_pixbuf(string key, Gdk.Pixbuf source, int w, int h) {
        var existing = get(key);
        if (existing != null) return existing;
                // Use HYPER interpolation for highest quality (crisper images)
        // Trade-off: slightly slower but much better visual quality
        var scaled = source.scale_simple(w, h, Gdk.InterpType.HYPER);
        if (scaled != null) {
            set(key, scaled);
            return scaled;
        }
        return null;
    }

    // Scale-and-crop helper: scale `source` so it fully covers `w`x`h` (cover)
    // then center-crop to exactly `w`x`h`. Cache the final pixbuf under `key`.
    public Gdk.Pixbuf? get_or_scale_and_crop_pixbuf(string key, Gdk.Pixbuf source, int w, int h) {
        var existing = get(key);
        if (existing != null) return existing;
        int width = source.get_width();
        int height = source.get_height();
        if (width <= 0 || height <= 0) return null;

        double scale_x = (double) w / width;
        double scale_y = (double) h / height;
        double scale = double.max(scale_x, scale_y);

        int scaled_w = (int) (width * scale);
        int scaled_h = (int) (height * scale);
        if (scaled_w < 1) scaled_w = 1;
        if (scaled_h < 1) scaled_h = 1;

        // Scale to a transient pixbuf - not cached under its own key, since
        // it's only ever an intermediate step towards the cropped `key`
        // result below and would otherwise sit in the cache permanently as
        // a near-duplicate of the final image.
        var scaled = source.scale_simple(scaled_w, scaled_h, Gdk.InterpType.HYPER);
        if (scaled == null) return null;

        // Paint the scaled pixbuf into a target surface and crop by centering it
        var surface = new ImageSurface(Format.ARGB32, w, h);
        var cr = new Context(surface);
        // Transparent background
        cr.set_source_rgba(0, 0, 0, 0);
        cr.paint();

        int x = (w - scaled_w) / 2;
        int y = (h - scaled_h) / 2;
        try { Gdk.cairo_set_source_pixbuf(cr, scaled, x, y); cr.paint(); } catch (GLib.Error e) { }

        var final_pb = get_or_from_surface(key, surface, 0, 0, w, h);
        return final_pb;
    }

    public Gee.ArrayList<string> keys() {
        return pixbuf_cache.keys();
    }

    public void clear() {
        // Clear both caches - LruCache will call eviction callbacks for each entry
        pixbuf_cache.clear();
        texture_cache.clear();
        if (AppDebugger.debug_enabled()) {
        }
    }

    public void set_capacity(int c) {
        pixbuf_cache.set_capacity(c);
        texture_cache.set_capacity(c);
    }

    public int size() {
        return pixbuf_cache.size();
    }

    // Reuse a cached texture instead of re-uploading on every call. Safe
    // because set() and the eviction callback above both drop a key's
    // texture the moment its pixbuf changes or falls out of the LRU, so
    // anything found here always matches the currently-cached pixbuf.
    public Gdk.Texture? get_texture(string key) {
        var cached_tex = texture_cache.get(key);
        if (cached_tex != null) return cached_tex;

        var pb = get(key);
        if (pb == null) return null;

        var tex = Gdk.Texture.for_pixbuf(pb);
        texture_cache.set(key, tex);
        return tex;
    }

    // Register an already-created texture directly, bypassing get_texture()'s
    // get-or-create lookup - needed when the caller already has the source
    // pixbuf in hand and doesn't want an untracked texture (Gdk.Texture.
    // for_pixbuf() keeps its source pixbuf alive for the texture's whole
    // lifetime, so a texture built outside this cache never gets evicted).
    public void set_texture(string key, Gdk.Texture tex) {
        texture_cache.set(key, tex);
    }
}