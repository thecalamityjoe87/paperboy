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
 * FetchContext: A robust context object for managing async fetch operations.
 * 
 * This solves the segfault problem where async callbacks try to access
 * a destroyed NewsWindow. The context is a separate, long-lived object that:
 * 
 * 1. Tracks whether the fetch is still valid (not cancelled by a newer fetch)
 * 2. Holds a WEAK reference to the window (becomes null if window destroyed)
 * 3. Provides a single is_valid() check for callbacks
 * 
 * Usage in fetch_news():
 *   var ctx = FetchContext.begin_new(this);
 *   // ... in async callback ...
 *   if (!ctx.is_valid()) return false;  // Safe - context never crashes
 *   ctx.window.some_method();  // Only accessed after is_valid() check
 */
public class FetchContext : GLib.Object {
    private static FetchContext? _current_context = null;
    private static uint _sequence = 0;
    
    /** The sequence number for this fetch context */
    public uint seq { get; private set; }
    
    /** Whether this context has been superseded by a newer fetch */
    public bool cancelled { get; private set; default = false; }
    
    /** Weak reference to the window - may become null if window is destroyed */
    public weak NewsWindow? window { get; private set; default = null; }
    
    /**
     * Private constructor - use begin_new() to create contexts.
     */
    private FetchContext(uint sequence, NewsWindow? w) {
        this.seq = sequence;
        this.window = w;
    }
    
    /**
     * Begin a new fetch context, invalidating any previous context.
     * Call this at the start of fetch_news().
     * 
     * @param w The NewsWindow initiating the fetch
     * @return The new FetchContext to capture in callbacks
     */
    public static FetchContext begin_new(NewsWindow? w) {
        // Mark old context as cancelled
        if (_current_context != null) {
            _current_context.cancelled = true;
        }
        
        // Increment sequence
        _sequence++;
        
        // Create and store new context
        _current_context = new FetchContext(_sequence, w);
        return _current_context;
    }
    
    /**
     * Check if this context is still valid for executing callbacks.
     * Returns true only if:
     * - This context has not been cancelled by a newer fetch
     * - The window reference is still alive
     * 
     * @return true if safe to proceed with callback operations
     */
    public bool is_valid() {
        return !cancelled && window != null;
    }
    
    /**
     * Check if this context's sequence matches the current sequence.
     * Use this for lightweight staleness checks without window access.
     */
    public bool is_current_seq() {
        return seq == _sequence;
    }
    
    // ============================================================
    // BACKWARD COMPATIBILITY: Static FetchSequence-style API
    // These allow existing code to continue working during migration
    // ============================================================
    
    /**
     * Get the current fetch sequence number (backward compat).
     */
    public static uint current {
        get { return _sequence; }
    }
    
    /**
     * Increment and return the new sequence number (backward compat).
     * NOTE: This does NOT create a context. Use begin_new() for full safety.
     */
    public static uint next() {
        if (_current_context != null) {
            _current_context.cancelled = true;
        }
        _sequence++;
        return _sequence;
    }
    
    /**
     * Check if a sequence is current (backward compat).
     */
    public static bool is_current(uint seq) {
        return seq == _sequence;
    }
    
    /**
     * Get the current context, if any.
     */
    public static FetchContext? current_context() {
        return _current_context;
    }
}
