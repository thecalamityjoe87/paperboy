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
[CCode (cname = "getpid", cheader_filename = "unistd.h")]
extern int webview_utils_getpid();
[CCode (cname = "kill", cheader_filename = "signal.h")]
extern int webview_utils_kill(int pid, int sig);

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
        start_memory_watchdog();
        return view;
    }

    // WebKit's own memory limit runs on the page's main thread, so a page stuck in a
    // busy loop never gets killed by it. This watches our web processes from outside.
    private const int64 WEB_PROCESS_MEMORY_LIMIT_KB = 1536 * 1024;
    private static uint watchdog_id = 0;

    private static void start_memory_watchdog() {
        if (watchdog_id != 0) return;
        watchdog_id = GLib.Timeout.add_seconds(1, () => {
            bool any_alive = false;
            foreach (var t in live()) if (t.view.get() != null) { any_alive = true; break; }
            if (!any_alive) {
                watchdog_id = 0;
                return GLib.Source.REMOVE;
            }
            kill_oversized_web_processes();
            return GLib.Source.CONTINUE;
        });
    }

    private static void kill_oversized_web_processes() {
        var parent_of = new Gee.HashMap<int, int>();
        var web_pids = new Gee.ArrayList<int>();
        try {
            var dir = GLib.Dir.open("/proc");
            string? name;
            while ((name = dir.read_name()) != null) {
                int pid = int.parse(name);
                if (pid <= 0) continue;
                string stat;
                try { GLib.FileUtils.get_contents("/proc/%d/stat".printf(pid), out stat); } catch (GLib.FileError e) { continue; }
                // Format is "pid (comm) state ppid ..." and comm may contain spaces.
                int close = stat.last_index_of(")");
                if (close < 0) continue;
                string[] fields = stat.substring(close + 2).split(" ");
                if (fields.length < 2) continue;
                parent_of[pid] = int.parse(fields[1]);
                if (stat.contains("(WebKitWebProces)")) web_pids.add(pid);
            }
        } catch (GLib.FileError e) {
            return;
        }

        int self = webview_utils_getpid();
        foreach (int pid in web_pids) {
            int p = pid;
            for (int depth = 0; depth < 8 && p > 1 && p != self; depth++) {
                p = parent_of.has_key(p) ? parent_of[p] : 0;
            }
            if (p != self) continue;

            int64 rss_kb = 0;
            try {
                string status;
                GLib.FileUtils.get_contents("/proc/%d/status".printf(pid), out status);
                foreach (var line in status.split("\n")) {
                    if (line.has_prefix("VmRSS:")) rss_kb = int64.parse(line.substring(6).strip().split(" ")[0]);
                }
            } catch (GLib.FileError e) {
                continue;
            }
            if (rss_kb > WEB_PROCESS_MEMORY_LIMIT_KB) {
                GLib.warning("Killing web process %d using %lld MB (limit %lld MB)", pid, rss_kb / 1024, WEB_PROCESS_MEMORY_LIMIT_KB / 1024);
                webview_utils_kill(pid, 9); // SIGKILL
            }
        }
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
