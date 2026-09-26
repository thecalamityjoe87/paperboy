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
 * One visit to one view: the window it renders into, its ViewSession, and
 * the per-visit fetch state. Starting a new context closes the previous
 * session, which cancels its requests, drops its callbacks and undoes its
 * on-screen chrome, so a view owns the screen exactly as long as its session is open.
 */
public class FetchContext : GLib.Object {


    private static FetchContext? _current_context = null;
    private static uint _sequence = 0;
    private static GLib.Mutex _sequence_mutex = GLib.Mutex();

    public uint seq { get; private set; }
    public weak NewsWindow? window { get; private set; default = null; }
    public ViewSession session { get; private set; }

    /**
     * Whether this fetch races more than one source for the same view. When
     * true, incoming articles are buffered briefly and flushed newest-first,
     * so a fast but stale source can't claim the hero slot just by answering
     * first. Set right after begin_new() by the caller that knows the source count.
     */
    public bool is_multi_source { get; set; default = false; }

    // Per-visit state for FetchNewsController's multi-source buffering and Front Page countdown.
    public Gee.ArrayList<ArticleItem>? multi_source_buffer = null;
    public int64 multi_source_started_at = 0;
    public uint multi_source_flush_id = 0;
    public bool multi_source_flushed = false;
    public int frontpage_endpoints_done = 0;

    private FetchContext(uint sequence, NewsWindow? w) {
        this.seq = sequence;
        this.window = w;
        string? category = (w != null && w.prefs != null) ? w.prefs.category : null;
        this.session = new ViewSession(category);
    }

    /** Main thread only. Closes the previous view's session and starts a new one. */
    public static FetchContext begin_new(NewsWindow? w) {
        if (_current_context != null) _current_context.session.close();
        else ViewSession.close_detached();
        _sequence_mutex.lock();
        _sequence++;
        uint s = _sequence;
        _sequence_mutex.unlock();
        _current_context = new FetchContext(s, w);
        return _current_context;
    }

    public static FetchContext? current_context() {
        return _current_context;
    }

    /** Generation counter, bumped per view visit. Read by ImageManager to drop stale image deliveries. */
    public static uint current {
        get {
            _sequence_mutex.lock();
            uint result = _sequence;
            _sequence_mutex.unlock();
            return result;
        }
    }

    /** Whether an async callback from this visit may still touch the shared containers. */
    public bool still_owns_view() {
        return !session.is_closed() && window != null;
    }

    /** Saved and History render only their own local-store items, never network fetch results. */
    public bool is_local_only_view() {
        return session.category == "saved" || session.category == "history";
    }
}
