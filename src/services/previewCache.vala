/* PreviewCache manager: provide a shared, bounded cache for article preview textures.
 * This centralizes the preview cache so the main window can clear it when
 * switching categories to free memory.
 */

using GLib;
using Gee;
using Gdk;

public class PreviewCacheManager : GLib.Object {
    private static LruCache<string, Gdk.Texture>? cache = null;

    public static LruCache<string, Gdk.Texture> get_cache(int capacity = 12) {
        try {
            if (cache == null) cache = new LruCache<string, Gdk.Texture>(capacity);
        } catch (GLib.Error e) { /* best-effort */ }
        return cache;
    }

    public static void clear_cache() {
        try { if (cache != null) cache.clear(); } catch (GLib.Error e) { }
    }
}
