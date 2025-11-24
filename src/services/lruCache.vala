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
 * Small generic LRU cache backed by Gee.HashMap and an order list.
 * Intended for short-lived in-memory caches where simple bounded
 * eviction is sufficient. Not optimized for extreme throughput.
 */

using GLib;
using Gee;


public class LruCache<K, V> : GLib.Object {
    private Gee.HashMap<K, V> map;
    private Gee.ArrayList<K> order;
    // Protect internal state from concurrent access across threads
    private GLib.Mutex mutex;
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
        // Use default Gee containers. Gee will handle GObject
        // duplication/destroy semantics for stored values (it will
        // ref on insert and unref on remove/clear). ImageCache is
        // adjusted to avoid double-unref and therefore we rely on
        // the container to manage the pixbuf lifecycle.
        map = new Gee.HashMap<K, V>();
        order = new Gee.ArrayList<K>();
        mutex = new GLib.Mutex();
    }

    // Set an optional eviction callback. Passing null clears the callback.
    public void set_eviction_callback(EvictionCallback<K, V>? cb) {
        on_evict = cb;
    }

    // Retrieve a value or null if missing. Marks the key as recently used.
    // Returns an unowned reference - the cache still owns the object.
    // Callers should NOT unref the returned value.
    public V? get(K key) {
        mutex.lock();
        try {
            var v = map.get(key);
            if (v == null) {
                return null;
            }
            order.remove(key);
            order.add(key);
            return v;
        } finally {
            mutex.unlock();
        }
    }

    // Insert or update a value and enforce capacity eviction.
    public void set(K key, V value) {
        mutex.lock();
        try {
            bool exists = false;
            var tmp = map.get(key);
            if (tmp != null) exists = true;

            map.set(key, value);
            if (exists) {
                order.remove(key);
                order.add(key);
                return;
            }

            order.add(key);
            // Evict oldest if over capacity
            // Invoke eviction callback immediately while we still hold the mutex
            // and the value is still valid in the map
            while (order.size > capacity) {
                K oldest = order.get(0);
                order.remove_at(0);
                V? val = map.get(oldest);
                if (val != null && on_evict != null) {
                    try {
                        on_evict(oldest, val);
                    } catch (GLib.Error e) {
                        // Best-effort: ignore callback errors
                    }
                }
                map.remove(oldest);
            }
        } finally {
            mutex.unlock();
        }
    }

    // Remove a key from the cache
    public bool remove(K key) {
        bool removed = false;
        mutex.lock();
        try {
            order.remove(key);
            V? val = map.get(key);
            if (val != null && on_evict != null) {
                try {
                    on_evict(key, val);
                } catch (GLib.Error e) {
                    // Best-effort: ignore callback errors
                }
            }
            removed = map.remove(key);
        } finally {
            mutex.unlock();
        }
        return removed;
    }

    public void clear() {
        mutex.lock();
        try {
            if (on_evict != null) {
                for (int i = 0; i < order.size; i++) {
                    K k = order.get(i);
                    V? v = map.get(k);
                    if (v != null) {
                        try {
                            on_evict(k, v);
                        } catch (GLib.Error e) {
                            // Best-effort: ignore callback errors
                        }
                    }
                }
            }
            order.clear();
            map.clear();
        } finally {
            mutex.unlock();
        }
    }

    public int size() {
        mutex.lock();
        try {
            return map.size;
        } finally {
            mutex.unlock();
        }
    }

    public int get_capacity() {
        return capacity;
    }

    public void set_capacity(int c) {
        if (c <= 0) return;
        mutex.lock();
        try {
            capacity = c;
            // Trim if necessary
            while (order.size > capacity) {
                K oldest = order.get(0);
                order.remove_at(0);
                V? val = map.get(oldest);
                if (val != null && on_evict != null) {
                    try {
                        on_evict(oldest, val);
                    } catch (GLib.Error e) {
                        // Best-effort: ignore callback errors
                    }
                }
                map.remove(oldest);
            }
        } finally {
            mutex.unlock();
        }
    }

    // Return a copy of the keys in LRU order (oldest first). Useful for
    // diagnostics; callers should not mutate the returned list expecting
    // it to affect the cache.
    public Gee.ArrayList<K> keys() {
        var copy = new Gee.ArrayList<K>();
        mutex.lock();
        try {
            for (int i = 0; i < order.size; i++) {
                copy.add(order.get(i));
            }
        } finally {
            mutex.unlock();
        }
        return copy;
    }
}
