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

using Gtk;
using Adw;

public class RssFinderService : GLib.Object {
    // Helper object to hold lookup-related widgets so we can safely
    // take/release references and avoid capturing raw stack locals in
    // async callbacks (which previously led to use-after-free crashes).
    private class LookupHolder : GLib.Object {
        public Gtk.Spinner? spinner;
        public Gtk.Box? spinner_box;
        public Gtk.Label? hint;
        public bool alive = true;
    }

    // Run the external `rssFinder` helper asynchronously with the given
    // query (city name). When finished, present a small dialog with the
    // result and refresh Local News in the parent NewsWindow if present.
    public static void spawn_async(Gtk.Window parent, string query, bool refresh_on_dismiss = true) {
        new Thread<void*>("rssfinder-run", () => {
            try {
                string q = query.strip();
                // If the query contains a comma ("City, State"), use only the city part
                int cpos = q.index_of(",");
                if (cpos > 0) q = q.substring(0, cpos).strip();

                // Use a helper to locate the `rssFinder` helper. This keeps the
                // path-selection logic centralized and easier to test; it also
                // avoids repeated code in the function body.
                string? found = find_rssFinder_binary();
                string prog;
                SpawnFlags flags;
                // Guard against null return from locate_rssfinder();
                // Security: Do not fall back to PATH search - only use explicitly located binary
                if (found != null && found.length > 0) {
                    prog = found;
                    flags = (SpawnFlags) 0; // execute explicit path
                } else {
                    // Binary not found in any expected location - fail safely
                    throw new GLib.Error(GLib.Quark.from_string("rssfinder"), 2, "rssFinder binary not found. Please ensure it is installed correctly.");
                }
                try { AppDebugger.log_if_enabled("/tmp/paperboy-debug.log", "spawn_rssfinder_async: prog='" + prog + "' flags=" + flags.to_string() + " query='" + q + "'"); } catch (GLib.Error _) { }

                // Remove any existing local_feeds file so rssFinder's
                // appended results start from a clean slate for this
                // location change. rssFinder will create the config
                // directory/file when it runs.
                try {
                    string config_dir_rm = GLib.Environment.get_user_config_dir() + "/paperboy";
                    string file_path_rm = config_dir_rm + "/local_feeds";
                    try {
                        if (GLib.FileUtils.test(file_path_rm, GLib.FileTest.EXISTS)) {
                            try { GLib.FileUtils.remove(file_path_rm); } catch (GLib.Error ee) { }
                        }
                    } catch (GLib.Error ee) { }
                } catch (GLib.Error ee) { }

                string[] argv = { prog, "--query", q };
                string out = "";
                string err = "";
                int status = 0;
                try {
                    Process.spawn_sync(null, argv, null, flags, null, out out, out err, out status);
                } catch (SpawnError e) {
                    throw new GLib.Error(GLib.Quark.from_string("rssfinder"), 1, "Failed to spawn rssFinder: %s", e.message);
                }
                try { AppDebugger.log_if_enabled("/tmp/paperboy-debug.log", "spawn_rssfinder_async: exit=" + status.to_string() + " out_len=" + (out != null ? out.length.to_string() : "0") + " err_len=" + (err != null ? err.length.to_string() : "0")); } catch (GLib.Error _) { }

                string message;
                if (status == 0) {
                    int count = 0;
                    if (out != null) {
                        string[] lines = out.split("\n");
                        for (int i = 0; i < lines.length; i++) {
                            if (lines[i].has_prefix("Found feed:")) count++;
                        }
                    }
                    message = "Discovery finished. " + count.to_string() + " feeds reported.";
                    if (err != null && err.length > 0) message += "\n\nErrors:\n" + err;
                } else {
                    message = "rssFinder failed (status " + status.to_string() + ").";
                    if (err != null && err.length > 0) message += "\n\n" + err;
                    if (out != null && out.length > 0) message += "\n\nOutput:\n" + out;
                }

                // Read the local_feeds file now that rssFinder finished so
                // we can tell the user how many feeds were discovered and
                // only start the potentially-long import when they dismiss
                // the dialog (gives them a chance to cancel or be prepared).
                string[] discovered_feeds = {};
                try {
                    string config_dir = GLib.Environment.get_user_config_dir() + "/paperboy";
                    string file_path = config_dir + "/local_feeds";
                    if (GLib.FileUtils.test(file_path, GLib.FileTest.EXISTS)) {
                        string file_contents = "";
                        try { GLib.FileUtils.get_contents(file_path, out file_contents); } catch (GLib.Error ee) { file_contents = ""; }
                        if (file_contents != null && file_contents.strip() != "") {
                            string[] lines = file_contents.split("\n");
                            var tmp = new Gee.ArrayList<string>();
                            for (int i = 0; i < lines.length; i++) {
                                string u = lines[i].strip();
                                if (u.length > 0) tmp.add(u);
                            }
                            // Filter discovered feeds: remove obviously malformed or unsupported URLs
                            var valid = new Gee.ArrayList<string>();
                            for (int i = 0; i < tmp.size; i++) {
                                string cand = tmp.get(i).strip();
                                if (cand.length == 0) continue;
                                // Basic validation: no spaces and supported schemes only
                                if (cand.contains(" ") || !(cand.has_prefix("http://") || cand.has_prefix("https://") || cand.has_prefix("file://"))) {
                                    try { GLib.warning("rssFinderService: skipping malformed/unsupported discovered feed: %s", cand); } catch (GLib.Error _) { }
                                    continue;
                                }
                                valid.add(cand);
                            }
                            discovered_feeds = new string[valid.size];
                            for (int i = 0; i < valid.size; i++) discovered_feeds[i] = valid.get(i);
                        }
                    }
                } catch (GLib.Error ee) { }

                // Present the discovery result in the main loop so the
                // user sees how many feeds were found (and what they are).
                // Keep this on the main thread using Idle.add.
                try {
                    string show_msg = message;
                    if (discovered_feeds != null && discovered_feeds.length > 0) {
                        show_msg += "\n\nDiscovered feeds:\n";
                        for (int i = 0; i < discovered_feeds.length; i++) {
                            show_msg += "- " + discovered_feeds[i] + "\n";
                        }
                    }

                    Idle.add(() => {
                        try {
                            try { AppDebugger.log_if_enabled("/tmp/paperboy-debug.log", "rssFinder: presenting discovery dialog (refresh_on_dismiss=" + refresh_on_dismiss.to_string() + ")"); } catch (GLib.Error _) { }
                            var dlg = new Adw.AlertDialog("Local Feed Discovery", show_msg);
                            dlg.add_response("ok", "OK");
                            // Use the async chooser so we can react when the user
                            // dismisses the dialog. When closed, refresh the main
                            // window's content so newly-discovered feeds are picked up.
                            dlg.choose.begin(parent, null, (obj, res) => {
                                try {
                                    try { AppDebugger.log_if_enabled("/tmp/paperboy-debug.log", "rssFinder: discovery dialog choose callback invoked"); } catch (GLib.Error _) { }
                                    string response = dlg.choose.end(res);
                                    try { AppDebugger.log_if_enabled("/tmp/paperboy-debug.log", "rssFinder: discovery dialog response='" + response + "'"); } catch (GLib.Error _) { }
                                    // Only refresh if caller requested it. Use Idle.add to
                                    // ensure the fetch runs on the main loop and log the
                                    // refresh so we can diagnose missed refreshes.
                                    if (refresh_on_dismiss) {
                                        var parent_win = parent as NewsWindow;
                                        if (parent_win != null) {
                                            try {
                                                AppDebugger.log_if_enabled("/tmp/paperboy-debug.log", "rssFinder: scheduling fetch_news on dismiss");
                                            } catch (GLib.Error _) { }
                                            Idle.add(() => {
                                                try { parent_win.fetch_news(); } catch (GLib.Error _e) { }
                                                return false;
                                            });
                                        } else {
                                            try { AppDebugger.log_if_enabled("/tmp/paperboy-debug.log", "rssFinder: parent is not a NewsWindow; cannot schedule fetch_news"); } catch (GLib.Error _) { }
                                        }
                                    } else {
                                        try { AppDebugger.log_if_enabled("/tmp/paperboy-debug.log", "rssFinder: refresh_on_dismiss is false; not scheduling fetch"); } catch (GLib.Error _) { }
                                    }
                                } catch (GLib.Error _e) { }
                            });
                        } catch (GLib.Error ee) { }
                        return false;
                    });
                } catch (GLib.Error ee) { }
            } catch (GLib.Error e) {
                // accessible inside the nested lambda on some compiler versions).
                string emsg = e.message;
                Idle.add(() => {
                    try {
                        var dlg = new Adw.AlertDialog("Local Feed Discovery", "Error running rssFinder: " + emsg);
                        dlg.add_response("ok", "OK");
                        dlg.present(parent);
                    } catch (GLib.Error ee) { }
                    return false;
                });
            }
            return null;
        });
    }

    /**
    * Find the rssFinder binary in various possible locations
    * @return Path to rssFinder binary or null if not found
    */
    private static string? find_rssFinder_binary() {
        // Fallback candidates: system/AppImage locations and developer build locations
        var candidates = new Gee.ArrayList<string>();

        // Environment variable override (AppRun / AppImage)
        string? env_libexec = GLib.Environment.get_variable("PAPERBOY_LIBEXECDIR");
        if (env_libexec != null && env_libexec.length > 0) {
            candidates.add(GLib.Path.build_filename(env_libexec, "paperboy", "rssFinder"));
            candidates.add(GLib.Path.build_filename(env_libexec, "rssFinder"));
        }

        // Build-time libexecdir (system install)
        string libexec = BuildConstants.LIBEXECDIR;
        if (libexec != null && libexec.length > 0) {
            candidates.add(GLib.Path.build_filename(libexec, "paperboy", "rssFinder"));
        }

        // FHS-compliant: check libexecdir for internal binaries
        // Standard system locations (prefix-aware)
        candidates.add("/usr/libexec/paperboy/rssFinder");
        candidates.add("/usr/local/libexec/paperboy/rssFinder");

        // Flatpak/AppImage locations
        candidates.add("/app/libexec/paperboy/rssFinder");

        // Development build locations (for running from source tree)
        candidates.add("build/rssFinder");
        candidates.add("./build/rssFinder");
        candidates.add("../build/rssFinder");
        candidates.add("./rssFinder");

        string? cwd = GLib.Environment.get_current_dir();
        if (cwd != null) {
            candidates.add(GLib.Path.build_filename(cwd, "rssfinder", "rssFinder"));
        }

        // Check each candidate and return the first executable match
        foreach (string c in candidates) {
            try {
                if (GLib.FileUtils.test(c, GLib.FileTest.EXISTS) &&
                    GLib.FileUtils.test(c, GLib.FileTest.IS_EXECUTABLE)) {
                    GLib.message("Using rssFinder at: %s", c);
                    return c;
                }
            } catch (GLib.Error e) {
                // Not found
                AppDebugger.log_if_enabled("/tmp/paperboy-debug.log", "rssFinder not found in candidates");
            }
        }
        return null;
    }

}
