using GLib;
using Gee;

// Small generic LRU cache backed by Gee.HashMap and an order list.
// Intended for short-lived in-memory caches where simple bounded
// eviction is sufficient. Not optimized for extreme throughput.
public class LruCache<K, V> : GLib.Object {
    private Gee.HashMap<K, V> map;
    private Gee.ArrayList<K> order;
    private int capacity;
    // Optional eviction callback invoked when entries are removed due to
    // capacity limits or explicit clear/remove. Callers can use this to
    // release resources or log heavy textures. Kept optional to remain
    // backwards-compatible.
    public delegate void EvictionCallback<K, V>(K key, V value);
    private EvictionCallback<K, V>? on_evict;

    public LruCache(int capacity) {
        GLib.Object();
        if (capacity <= 0) capacity = 128;
        this.capacity = capacity;
        map = new Gee.HashMap<K, V>();
        order = new Gee.ArrayList<K>();
    }

    // Set an optional eviction callback. Passing null clears the callback.
    public void set_eviction_callback(EvictionCallback<K, V>? cb) {
        on_evict = cb;
    }

    // Retrieve a value or null if missing. Marks the key as recently used.
    public V? get(K key) {
        try {
            var v = map.get(key);
            if (v != null) {
                // move key to back
                try { order.remove(key); } catch (GLib.Error e) { }
                order.add(key);
            }
            return v;
        } catch (GLib.Error e) {
            return null;
        }
    }

    // Insert or update a value and enforce capacity eviction.
    public void set(K key, V value) {
        try {
            bool exists = false;
            try {
                var tmp = map.get(key);
                if (tmp != null) exists = true;
            } catch (GLib.Error e) { exists = false; }

            map.set(key, value);
            if (exists) {
                try { order.remove(key); } catch (GLib.Error e) { }
                order.add(key);
                return;
            }

            order.add(key);
            // Evict oldest if over capacity
            while (order.size > capacity) {
                K oldest = order.get(0);
                order.remove_at(0);
                try {
                    V? val = null;
                    try { val = map.get(oldest); } catch (GLib.Error e) { val = null; }
                    try { map.remove(oldest); } catch (GLib.Error e) { }
                    // Notify caller about eviction (best-effort)
                    try {
                        if (on_evict != null && val != null) on_evict(oldest, val);
                    } catch (GLib.Error e) { }
                    // Optional debug output when PAPERBOY_DEBUG is set (best-effort)
                    try {
                        string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                        if (dbg != null && dbg.length > 0) {
                            // Best-effort stringify the key for debug output; if the
                            // key isn't a string, print a placeholder to avoid
                            // compile-time typing issues with generic K.
                            string key_s = "<non-string>";
                            try {
                                if (oldest is string) key_s = (string) oldest;
                            } catch (GLib.Error _e) { }
                            print("DEBUG: LruCache.evicted key=%s\n", key_s);
                        }
                    } catch (GLib.Error e) { }
                } catch (GLib.Error e) { }
            }
        } catch (GLib.Error e) {
            // best-effort: ignore cache failures
        }
    }

    // Remove a key from the cache
    public bool remove(K key) {
        bool r = false;
        try {
            try { order.remove(key); } catch (GLib.Error e) { }
            V? val = null;
            try { val = map.get(key); } catch (GLib.Error e) { val = null; }
            r = map.remove(key);
            try {
                if (on_evict != null && val != null) on_evict(key, val);
            } catch (GLib.Error e) { }
        } catch (GLib.Error e) { r = false; }
        return r;
    }

    public void clear() {
        try {
            // Notify for each entry before clearing so callers can release
            // resources tied to the cached values.
            try {
                for (int i = 0; i < order.size; i++) {
                    K k = order.get(i);
                    V? v = null;
                    try { v = map.get(k); } catch (GLib.Error e) { v = null; }
                    try { if (on_evict != null && v != null) on_evict(k, v); } catch (GLib.Error e) { }
                }
            } catch (GLib.Error e) { }

            order.clear();
            map.clear();
        } catch (GLib.Error e) { }
    }

    public int size() {
        return map.size;
    }

    public int get_capacity() {
        return capacity;
    }

    public void set_capacity(int c) {
        if (c <= 0) return;
        capacity = c;
        // Trim if necessary
        while (order.size > capacity) {
            K oldest = order.get(0);
            order.remove_at(0);
            try {
                V? val = null;
                try { val = map.get(oldest); } catch (GLib.Error e) { val = null; }
                try { map.remove(oldest); } catch (GLib.Error e) { }
                try { if (on_evict != null && val != null) on_evict(oldest, val); } catch (GLib.Error e) { }
            } catch (GLib.Error e) { }
        }
    }

    // Return a copy of the keys in LRU order (oldest first). Useful for
    // diagnostics; callers should not mutate the returned list expecting
    // it to affect the cache.
    public Gee.ArrayList<K> keys() {
        var copy = new Gee.ArrayList<K>();
        try {
            for (int i = 0; i < order.size; i++) {
                copy.add(order.get(i));
            }
        } catch (GLib.Error e) { }
        return copy;
    }
}
