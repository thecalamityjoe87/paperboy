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

/*
 * ImageCache: an in-memory LRU cache for Gdk.Pixbuf and Gdk.Texture objects.
 * Stores both pixbufs and textures to avoid redundant texture creation.
 */

public class ImageCache : GLib.Object {
    private LruCache<string, Gdk.Pixbuf> pixbuf_cache;
    private LruCache<string, Gdk.Texture> texture_cache;
    private static ImageCache? global_instance = null;

    public ImageCache(int capacity = 256) {
        GLib.Object();
        pixbuf_cache = new LruCache<string, Gdk.Pixbuf>(capacity);
        texture_cache = new LruCache<string, Gdk.Texture>(capacity);
        
        // IMPORTANT DEPENDENCY: This implementation relies on Gee.HashMap's automatic
        // reference counting behavior for GObject values. When Gee stores a GObject
        // (like Gdk.Pixbuf or Gdk.Texture), it automatically calls g_object_ref() on
        // insert and g_object_unref() on remove/clear. This means:
        // 1. We do NOT manually ref/unref pixbufs when storing them
        // 2. The container manages the lifecycle automatically
        // 3. If Gee's behavior changes or we switch container libraries, this could break
        // 4. Tests should verify this behavior doesn't regress
        
        // When pixbuf entries are evicted, log for debugging
        // No need to manually unref - HashMap will do it when removing the entry
        pixbuf_cache.set_eviction_callback((k, v) => {
            try {
                if (AppDebugger.debug_enabled()) {
                }
            } catch (GLib.Error e) { }
        });
        
        // When texture entries are evicted, log for debugging
        // Textures are automatically freed when unreferenced
        texture_cache.set_eviction_callback((k, v) => {
            try {
                if (AppDebugger.debug_enabled()) {
                }
            } catch (GLib.Error e) { }
        });
    }

    // Global singleton accessor so legacy static code can delegate to the
    // application's ImageCache instance. The NewsWindow constructor will set
    // the global via `set_global` when it creates its per-window cache.
    public static ImageCache get_global() {
        if (global_instance == null) global_instance = new ImageCache(256);
        return global_instance;
    }

    public static void set_global(ImageCache inst) {
        global_instance = inst;
    }

    public Gdk.Pixbuf? get(string key) {
        try {
            var v = pixbuf_cache.get(key);
            try {
                if (AppDebugger.debug_enabled()) {
                }
            } catch (GLib.Error e) { }
            return v;
        } catch (GLib.Error e) { return null; }
    }

    public void set(string key, Gdk.Pixbuf pixbuf) {
        // Do not ref here. Gee containers will take their own reference
        // (g_object_ref) when storing GObject values; ref/unref is
        // therefore managed by the container.
        try {
            if (AppDebugger.debug_enabled()) {
            }
        } catch (GLib.Error e) { }
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
        try {
            var pb = Gdk.pixbuf_get_from_surface(surface, x, y, w, h);
            if (pb != null) {
                set(key, pb);
                return pb;
            }
        } catch (GLib.Error e) { }
        return null;
    }

    // Centralized scaling helper: given a source pixbuf, produce (and cache)
    // a scaled pixbuf under `key`. This avoids calling `scale_simple` all
    // over the codebase and centralizes pixbuf creation in ImageCache.
    public Gdk.Pixbuf? get_or_scale_pixbuf(string key, Gdk.Pixbuf source, int w, int h) {
        var existing = get(key);
        if (existing != null) return existing;
        try {
            // Use HYPER interpolation for highest quality (crisper images)
            // Trade-off: slightly slower but much better visual quality
            var scaled = source.scale_simple(w, h, Gdk.InterpType.HYPER);
            if (scaled != null) {
                set(key, scaled);
                return scaled;
            }
        } catch (GLib.Error e) { }
        return null;
    }

    public Gee.ArrayList<string> keys() {
        return pixbuf_cache.keys();
    }

    public void clear() {
        // Clear both caches - LruCache will call eviction callbacks for each entry
        pixbuf_cache.clear();
        texture_cache.clear();
        try {
            if (AppDebugger.debug_enabled()) {
            }
        } catch (GLib.Error e) { }
    }

    public void set_capacity(int c) {
        pixbuf_cache.set_capacity(c);
        texture_cache.set_capacity(c);
    }

    public int size() {
        return pixbuf_cache.size();
    }

    // FIXED: Return a cached texture for a cached pixbuf. The texture is created
    // once and stored in texture_cache, so multiple widgets can share the same
    // texture object. This dramatically reduces GPU memory usage by avoiding
    // redundant texture creation.
    public Gdk.Texture? get_texture(string key) {
        // CRITICAL FIX: Don't cache Gdk.Texture objects - they can become invalid
        // across widget tree rebuilds or app state changes. Always create fresh
        // textures from the cached pixbufs to ensure they're valid for the current
        // widget state. This fixes the issue where images appear on first run but
        // are missing on subsequent runs when cached textures are reused.

        // Get the pixbuf from cache
        var pb = get(key);
        if (pb == null) return null;

        try {
            // Always create a fresh texture from the pixbuf
            var tex = Gdk.Texture.for_pixbuf(pb);
            return tex;
        } catch (GLib.Error e) {
            return null;
        }
    }
}