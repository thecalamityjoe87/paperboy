/*
 * Copyright (C) 2025  Isaac Joseph <calamityjoe87@gmail.com>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
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
        map = new Gee.HashMap<K, V>();
        order = new Gee.ArrayList<K>();
        mutex = new GLib.Mutex();
    }

    // Set an optional eviction callback. Passing null clears the callback.
    public void set_eviction_callback(EvictionCallback<K, V>? cb) {
        on_evict = cb;
    }

    // Retrieve a value or null if missing. Marks the key as recently used.
    public V? get(K key) {
        mutex.lock();
        try {
            var v = map.get(key);
            if (v != null) {
                order.remove(key);
                order.add(key);
            }
            return v;
        } finally {
            mutex.unlock();
        }
    }

    // Insert or update a value and enforce capacity eviction.
    public void set(K key, V value) {
        // We'll collect any evicted entries while holding the lock, then
        // invoke the optional eviction callback after releasing the mutex.
        var evicted_keys = new Gee.ArrayList<K>();
        var evicted_vals = new Gee.ArrayList<V>();

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
            while (order.size > capacity) {
                K oldest = order.get(0);
                order.remove_at(0);
                V? val = map.get(oldest);
                if (val != null) {
                    evicted_keys.add(oldest);
                    evicted_vals.add(val);
                }
                map.remove(oldest);
            }
        } finally {
            mutex.unlock();
        }

        // Debug-print evicted keys outside the lock (safe to inspect types).
        string? dbg_env = GLib.Environment.get_variable("PAPERBOY_DEBUG");
        if (dbg_env != null && dbg_env.length > 0) {
            print("DEBUG: LruCache.evicted count=%d\n", evicted_keys.size);
        }

        // Invoke eviction callbacks outside the lock to avoid reentrant
        // mutations and potential use-after-free issues in callers.
        if (on_evict != null) {
            for (int i = 0; i < evicted_keys.size; i++) {
                try {
                    on_evict(evicted_keys.get(i), evicted_vals.get(i));
                } catch (GLib.Error e) {
                    // Best-effort: ignore callback errors
                }
            }
        }
    }

    // Remove a key from the cache
    public bool remove(K key) {
        V? captured_val = null;
        bool removed = false;
        mutex.lock();
        try {
            order.remove(key);
            captured_val = map.get(key);
            removed = map.remove(key);
        } finally {
            mutex.unlock();
        }

        if (on_evict != null && captured_val != null) {
            try { on_evict(key, captured_val); } catch (GLib.Error e) { }
        }
        return removed;
    }

    public void clear() {
        var evicted_keys = new Gee.ArrayList<K>();
        var evicted_vals = new Gee.ArrayList<V>();

        mutex.lock();
        try {
            for (int i = 0; i < order.size; i++) {
                K k = order.get(i);
                V? v = map.get(k);
                if (v != null) {
                    evicted_keys.add(k);
                    evicted_vals.add(v);
                }
            }
            order.clear();
            map.clear();
        } finally {
            mutex.unlock();
        }

        if (on_evict != null) {
            for (int i = 0; i < evicted_keys.size; i++) {
                try { on_evict(evicted_keys.get(i), evicted_vals.get(i)); } catch (GLib.Error e) { }
            }
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
        var evicted_keys = new Gee.ArrayList<K>();
        var evicted_vals = new Gee.ArrayList<V>();

        mutex.lock();
        try {
            capacity = c;
            // Trim if necessary
            while (order.size > capacity) {
                K oldest = order.get(0);
                order.remove_at(0);
                V? val = map.get(oldest);
                if (val != null) {
                    evicted_keys.add(oldest);
                    evicted_vals.add(val);
                }
                map.remove(oldest);
            }
        } finally {
            mutex.unlock();
        }

        if (on_evict != null) {
            for (int i = 0; i < evicted_keys.size; i++) {
                try { on_evict(evicted_keys.get(i), evicted_vals.get(i)); } catch (GLib.Error e) { }
            }
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
