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

[CCode (cheader_filename = "webkit/webkit.h")]
extern void webkit_web_view_terminate_web_process(WebKit.WebView web_view);

// Dropping every ref to a WebKit.WebView does not actually kill its
// sandboxed (bwrap) web process here - only webkit_web_view_terminate_web_process()
// does, confirmed by isolated testing. Without this, every WebView we
// discard leaks its bwrap process for the rest of the app's lifetime.
public class WebViewUtils : GLib.Object {
    private class Tracked {
        public GLib.WeakRef view;
        public Tracked(WebKit.WebView v) { view = GLib.WeakRef(v); }
    }

    private static Gee.ArrayList<Tracked>? _live = null;
    private static Gee.ArrayList<Tracked> live() {
        if (_live == null) _live = new Gee.ArrayList<Tracked>();
        return _live;
    }

    // Use instead of `new WebKit.WebView()` so terminate_all() can reach it on quit.
    public static WebKit.WebView create() {
        var view = new WebKit.WebView();
        var dead = new Gee.ArrayList<Tracked>();
        foreach (var t in live()) if (t.view.get() == null) dead.add(t);
        live().remove_all(dead);
        live().add(new Tracked(view));
        return view;
    }

    public static void terminate_process(WebKit.WebView view) {
        webkit_web_view_terminate_web_process(view);
    }

    // A web process still busy when the app exits aborts with "WebProcess didn't
    // exit as expected", so kill them all first.
    public static void terminate_all() {
        foreach (var t in live()) {
            var view = t.view.get() as WebKit.WebView;
            if (view != null) webkit_web_view_terminate_web_process(view);
        }
        live().clear();
    }
}
