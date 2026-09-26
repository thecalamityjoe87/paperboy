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

/**
 * One visit to one view. Closing it cancels its network requests, drops
 * anything its fetchers still deliver, and removes its scheduled callbacks.
 */
public class ViewSession : GLib.Object {
    public string? category { get; private set; }
    public GLib.Cancellable cancellable { get; private set; default = new GLib.Cancellable(); }

    private int _closed = 0;
    private Gee.HashSet<uint> sources = new Gee.HashSet<uint>();
    private static ViewSession? _detached = null;

    public ViewSession(string? category) {
        this.category = category;
    }

    // The session of the view on screen. Before any view exists, a session that never closes.
    public static ViewSession current() {
        var ctx = FetchContext.current_context();
        if (ctx != null) return ctx.session;
        if (_detached == null) _detached = new ViewSession(null);
        return _detached;
    }

    // Per-view deferred work for code that doesn't hold a session itself.
    public static uint view_idle(owned GLib.SourceFunc fn) {
        return current().idle((owned) fn);
    }

    public static uint view_timeout(uint ms, owned GLib.SourceFunc fn) {
        return current().timeout(ms, (owned) fn);
    }

    // Safe for an ID whose source a closed session already removed.
    public static void remove_source(ref uint id) {
        if (id > 0 && GLib.MainContext.default().find_source_by_id(id) != null) GLib.Source.remove(id);
        id = 0;
    }

    // Safe from any thread.
    public bool is_closed() {
        return AtomicInt.get(ref _closed) == 1;
    }

    // Main thread only.
    public void close() {
        if (AtomicInt.get(ref _closed) == 1) return;
        AtomicInt.set(ref _closed, 1);
        cancellable.cancel();
        // Some may already have been removed by their owner via remove_source().
        var ctx = GLib.MainContext.default();
        foreach (var sid in sources) {
            if (ctx.find_source_by_id(sid) != null) GLib.Source.remove(sid);
        }
        sources.clear();
    }

    // Main thread only. Never runs once the session is closed. Returns 0 if already closed.
    public uint idle(owned GLib.SourceFunc fn) {
        if (is_closed()) return 0;
        uint sid = 0;
        sid = GLib.Idle.add(() => {
            if (is_closed()) return false;
            bool again = fn();
            if (!again) sources.remove(sid);
            return again;
        });
        sources.add(sid);
        return sid;
    }

    // Main thread only. Never runs once the session is closed. Returns 0 if already closed.
    public uint timeout(uint ms, owned GLib.SourceFunc fn) {
        if (is_closed()) return 0;
        uint sid = 0;
        sid = GLib.Timeout.add(ms, () => {
            if (is_closed()) return false;
            bool again = fn();
            if (!again) sources.remove(sid);
            return again;
        });
        sources.add(sid);
        return sid;
    }
}

public delegate void SinkItemHandler(ArticleItem item);
public delegate void SinkLabelHandler(string text);
public delegate void SinkVoidHandler();

/**
 * What fetchers report into. Callable from any thread; handlers always run
 * on the main loop, and never once the owning session has closed.
 */
public class FetchSink : GLib.Object {
    private ViewSession? session;
    private SinkItemHandler? on_item;
    private SinkLabelHandler? on_label;
    private SinkVoidHandler? on_clear;
    private SinkVoidHandler? on_done;

    // A null session means the sink is never closed (background work not tied to a view).
    public FetchSink(ViewSession? session,
                     owned SinkItemHandler? on_item,
                     owned SinkLabelHandler? on_label = null,
                     owned SinkVoidHandler? on_clear = null,
                     owned SinkVoidHandler? on_done = null) {
        this.session = session;
        this.on_item = (owned) on_item;
        this.on_label = (owned) on_label;
        this.on_clear = (owned) on_clear;
        this.on_done = (owned) on_done;
    }

    public GLib.Cancellable? cancellable {
        get { return session != null ? session.cancellable : null; }
    }

    public bool is_closed() {
        return session != null && session.is_closed();
    }

    public void add_item(string title, string url, string? thumbnail_url, string category_id, string? source_name, string? published = null, string? snippet = null) {
        if (on_item == null || is_closed()) return;
        var item = new ArticleItem(title, url, thumbnail_url, category_id, source_name, published);
        item.snippet = snippet;
        GLib.Idle.add(() => {
            if (!is_closed()) on_item(item);
            return false;
        });
    }

    public void set_label(string text) {
        if (on_label == null || is_closed()) return;
        GLib.Idle.add(() => {
            if (!is_closed()) on_label(text);
            return false;
        });
    }

    public void clear_items() {
        if (on_clear == null || is_closed()) return;
        GLib.Idle.add(() => {
            if (!is_closed()) on_clear();
            return false;
        });
    }

    public void done() {
        if (on_done == null || is_closed()) return;
        GLib.Idle.add(() => {
            if (!is_closed()) on_done();
            return false;
        });
    }
}
