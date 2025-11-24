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

/*
 * PreviewCache manager: provide a shared, bounded cache for article preview textures.
 * This centralizes the preview cache so the main window can clear it when
 * switching categories to free memory.
 */

using GLib;
using Gee;
using Gdk;

public class PreviewCacheManager : GLib.Object {
    // Preview cache is now backed by ImageCache (pixbufs). We no longer
    // hold long-lived Gdk.Texture objects here; callers should request a
    // transient texture via `get_paintable` which will create a texture
    // from a cached pixbuf on-demand.

    public static Gdk.Texture? get_paintable(string key) {
        try {
            var ic = ImageCache.get_global();
            var tex = ic.get_texture(key);
            return tex;
        } catch (GLib.Error e) { return null; }
    }

    public static void set_pixbuf(string key, Gdk.Pixbuf pb) {
        try {
            var ic = ImageCache.get_global();
            ic.set(key, pb);
        } catch (GLib.Error e) { }
    }

    public static void clear_cache() {
        // Avoid clearing the global ImageCache from PreviewCacheManager as
        // this can cause excessive eviction when users switch categories.
        // The ImageCache LRU policy will manage memory; keep this as a
        // no-op to avoid thrashing.
        try {
            if (AppDebugger.debug_enabled()) {
            }
        } catch (GLib.Error e) { }
    }

    public static void set_capacity(int c) {
        try { ImageCache.get_global().set_capacity(c); } catch (GLib.Error e) { }
    }

    // Compatibility accessor used by older callsites. Returns the global
    // ImageCache so callers can still invoke `.get()`/`.set()` as before.
    public static ImageCache get_cache() {
        return ImageCache.get_global();
    }
}
