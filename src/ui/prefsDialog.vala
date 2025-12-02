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
using Soup;
using Gdk;

// Small helper widget: a horizontal box that requests a fixed square size.
// This forces prefix areas to remain square (e.g., 24x24) even if parents
// attempt to allocate extra width, preventing circular badges from
// becoming ellipses.
// SquareBox removed: use explicit fixed-size Gtk.Box wrappers instead.

public class PrefsDialog : GLib.Object {
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
    private static void spawn_rssfinder_async(Gtk.Window parent, string query, bool refresh_on_dismiss = true) {
        new Thread<void*>("rssfinder-run", () => {
            try {
                string q = query.strip();
                // If the query contains a comma ("City, State"), use only the city part
                int cpos = q.index_of(",");
                if (cpos > 0) q = q.substring(0, cpos).strip();

                // Use a helper to locate the `rssFinder` helper. This keeps the
                // path-selection logic centralized and easier to test; it also
                // avoids repeated code in the function body.
                string? found = locate_rssfinder();
                string prog;
                SpawnFlags flags;
                // Guard against null return from locate_rssfinder();
                if (found != null && found.length > 0) {
                    prog = found;
                    flags = (SpawnFlags) 0; // execute explicit path
                } else {
                    prog = "rssFinder";
                    flags = SpawnFlags.SEARCH_PATH; // fall back to PATH lookup
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
                Process.spawn_sync(null, argv, null, flags, null, out out, out err, out status);
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
                            discovered_feeds = new string[tmp.size];
                            for (int i = 0; i < tmp.size; i++) discovered_feeds[i] = tmp.get(i);
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

    // Locate the rssFinder binary with a structured search. The priority
    // is: PATH (via GLib.find_program_in_path), local repo, build dir,
    // Meson-configured bindir, and a small set of common system paths.
    private static string? locate_rssfinder() {
        try {
            // We rely on the SpawnFlags.SEARCH_PATH fallback below if
            // nothing is found here. Using PATH lookups here is not
            // portable across all GLib versions via Vala; instead we
            // prefer an explicit candidate search followed by the
            // `SpawnFlags.SEARCH_PATH` fallback.

            // Local repo and build locations (developer-friendly)
            string[] dev_candidates = {
                "./tools/rssFinder",
                "tools/rssFinder",
                "../tools/rssFinder",
                "build/tools/rssFinder",
                "./build/tools/rssFinder",
                "build/rssFinder",
                "./build/rssFinder"
            };

            foreach (var c in dev_candidates) {
                try {
                    if (GLib.FileUtils.test(c, GLib.FileTest.EXISTS | GLib.FileTest.IS_REGULAR)) {
                        AppDebugger.log_if_enabled("/tmp/paperboy-debug.log", "rssFinder candidate found: " + c);
                        return c;
                    }
                } catch (GLib.Error e) { }
            }

            // Meson-configured bindir (respects install prefix)
            try {
                string b = BuildConstants.RSSFINDER_BINDIR;
                if (b != null && b.length > 0) {
                    string installed = GLib.Path.build_filename(b, "rssFinder");
                    if (GLib.FileUtils.test(installed, GLib.FileTest.EXISTS | GLib.FileTest.IS_REGULAR)) {
                        AppDebugger.log_if_enabled("/tmp/paperboy-debug.log", "rssFinder installed in bindir: " + installed);
                        return installed;
                    }
                    string installed_lower = GLib.Path.build_filename(b, "rssfinder");
                    if (GLib.FileUtils.test(installed_lower, GLib.FileTest.EXISTS | GLib.FileTest.IS_REGULAR)) {
                        AppDebugger.log_if_enabled("/tmp/paperboy-debug.log", "rssfinder installed in bindir: " + installed_lower);
                        return installed_lower;
                    }
                }
            } catch (GLib.Error e) { }

            // Final system fallbacks - warned but used rarely.
            string[] sys_fallbacks = { "/usr/local/bin/rssFinder", "/usr/local/bin/rssfinder", "/usr/bin/rssFinder", "/usr/bin/rssfinder" };
            foreach (var s in sys_fallbacks) {
                try {
                    if (GLib.FileUtils.test(s, GLib.FileTest.EXISTS | GLib.FileTest.IS_REGULAR)) {
                        AppDebugger.log_if_enabled("/tmp/paperboy-debug.log", "rssFinder system fallback: " + s);
                        return s;
                    }
                } catch (GLib.Error e) { }
            }
        } catch (GLib.Error e) { }
        // Not found
        AppDebugger.log_if_enabled("/tmp/paperboy-debug.log", "rssFinder not found in candidates");
        return null;
    }
    
    public static void show_source_dialog(Gtk.Window parent) {
        // If an article preview is currently open in the main window, close it
        var maybe_win = parent as NewsWindow;
        if (maybe_win != null) maybe_win.close_article_preview();

        var prefs = NewsPreferences.get_instance();
        string current_source_name = "";
        switch (prefs.news_source) {
            case NewsSource.GUARDIAN:
                current_source_name = "The Guardian";
                break;
            case NewsSource.REDDIT:
                current_source_name = "Reddit";
                break;
            case NewsSource.BBC:
                current_source_name = "BBC News";
                break;
            case NewsSource.NEW_YORK_TIMES:
                current_source_name = "New York Times";
                break;
            case NewsSource.BLOOMBERG:
                current_source_name = "Bloomberg";
                break;
            case NewsSource.REUTERS:
                current_source_name = "Reuters";
                break;
            case NewsSource.NPR:
                current_source_name = "NPR";
                break;
            case NewsSource.FOX:
                current_source_name = "Fox News";
                break;
            case NewsSource.WALL_STREET_JOURNAL:
                current_source_name = "Wall Street Journal";
                break;
        }
        
        // If multiple preferred sources are enabled, show that instead
        string body_text;
        try {
            var p = NewsPreferences.get_instance();
            int enabled_count = p.preferred_sources != null ? p.preferred_sources.size : 0;
            if (enabled_count > 1) {
                body_text = "Paperboy is currently using <b>multiple sources</b> to obtain the news.";
            } else {
                body_text = "Paperboy is currently using <b>" + GLib.Markup.escape_text(current_source_name) + "</b> as the news source.";
            }
        } catch (GLib.Error e) {
            body_text = "Paperboy is currently using <b>" + GLib.Markup.escape_text(current_source_name) + "</b> as the news source.";
        }

        var dialog = new Adw.AlertDialog(
            "Preferences",
            body_text
        );
        dialog.set_body_use_markup(true);
        dialog.add_response("browse", "Configure settings");
        dialog.add_response("ok", "OK");
        dialog.set_default_response("ok");
        dialog.set_close_response("ok");
        dialog.set_response_appearance("browse", Adw.ResponseAppearance.SUGGESTED);
        
        dialog.choose.begin(parent, null, (obj, res) => {
            string response = dialog.choose.end(res);
            if (response == "browse") {
                show_sources_list_dialog(parent);
            }
        });
    }
    
    public static void show_sources_list_dialog(Gtk.Window parent) {
        var win = (NewsWindow) parent;
        var prefs = NewsPreferences.get_instance();
        var sources_dialog = new Adw.AlertDialog(
            "Select News Sources",
            "Choose which news sources to fetch articles from:"
        );
        sources_dialog.set_prefer_wide_layout(true);
        
        // Create a ListBox for interactive source selection
        var list_box = new Gtk.ListBox();
        list_box.set_selection_mode(Gtk.SelectionMode.NONE);
        list_box.add_css_class("boxed-list");

        // Selection summary label and helpers (declare early so switch handlers
        // can call update_selection_label while building the rows).
        var selection_label = new Gtk.Label("");
        selection_label.set_use_markup(true);
        selection_label.set_halign(Gtk.Align.START);
        selection_label.set_valign(Gtk.Align.CENTER);
        selection_label.set_margin_start(8);
        selection_label.set_margin_bottom(6);

        string source_id_to_name(string id) {
            switch (id) {
                case "guardian": return "The Guardian";
                case "reddit": return "Reddit";
                case "bbc": return "BBC News";
                case "nytimes": return "New York Times";
                case "bloomberg": return "Bloomberg";
                case "reuters": return "Reuters";
                case "npr": return "NPR";
                case "fox": return "Fox News";
                case "wsj": return "Wall Street Journal";
                default: return "News";
            }
        }

        void update_selection_label() {
            try {
                var cp = NewsPreferences.get_instance();
                int cnt = cp.preferred_sources != null ? cp.preferred_sources.size : 0;
                if (cnt > 1) {
                    selection_label.set_markup("<b>Multiple Sources</b>");
                } else if (cnt == 1) {
                    string id = cp.preferred_sources.get(0);
                    selection_label.set_text(source_id_to_name(id));
                } else {
                    selection_label.set_text("No source selected");
                }
            } catch (GLib.Error e) {
                selection_label.set_text("");
            }
        }

        // Helper: elide long subtitles to avoid wrapping and row height changes
        string elide_string(string s, int max) {
            if (s == null) return s;
            if (s.length <= max) return s;
            return s.substring(0, max - 1) + "…";
        }

        // Helper: build a title widget with a wrapping subtitle so rows wrap consistently
        Gtk.Widget create_row_title_widget(string title, string? subtitle) {
            var vbox = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            var title_lbl = new Gtk.Label(title);
            title_lbl.set_halign(Gtk.Align.START);
            title_lbl.set_valign(Gtk.Align.CENTER);
            title_lbl.set_xalign(0.0f);
            title_lbl.set_use_markup(false);
            title_lbl.get_style_context().add_class("title");

            vbox.append(title_lbl);

            if (subtitle != null && subtitle.length > 0) {
                var sub_lbl = new Gtk.Label(subtitle);
                sub_lbl.set_halign(Gtk.Align.START);
                sub_lbl.set_valign(Gtk.Align.CENTER);
                sub_lbl.set_xalign(0.0f);
                sub_lbl.set_wrap(true);
                sub_lbl.set_justify(Gtk.Justification.LEFT);
                sub_lbl.get_style_context().add_class("subtitle");
                vbox.append(sub_lbl);
            }

            return vbox;
        }

        // Helper: async load favicon into provided Gtk.Picture with circular clipping
        void load_favicon_circular(Gtk.Picture picture, string url) {
            new Thread<void*>("load-favicon", () => {
                try {
                    var client = Paperboy.HttpClient.get_default();
                    var http_response = client.fetch_sync(url, null);

                    if (http_response.is_success() && http_response.body != null && http_response.body.get_size() > 0) {
                        // Get response data from GLib.Bytes
                        unowned uint8[] body_data = http_response.body.get_data();

                        uint8[] data = new uint8[body_data.length];
                        Memory.copy(data, body_data, body_data.length);

                        Idle.add(() => {
                            try {
                                var loader = new Gdk.PixbufLoader();
                                loader.write(data);
                                loader.close();
                                var pixbuf = loader.get_pixbuf();
                                if (pixbuf != null) {
                                    // Scale larger than the badge and clip to a circular
                                    // mask so the image itself becomes circular. Use a
                                    // slightly oversized image (28x28) so the circle
                                    // crops the edges and reads as a circular crop.
                                    int img_size = 24;
                                    string k = "pixbuf::url:%s::%dx%d".printf(url, img_size, img_size);
                                    var scaled = ImageCache.get_global().get_or_scale_pixbuf(k, pixbuf, img_size, img_size);
                                    if (scaled != null) {
                                        // Create final 24x24 surface and clip to circle
                                        var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, 24, 24);
                                        var cr = new Cairo.Context(surface);

                                        // Clip to circular area first
                                        cr.arc(12, 12, 12, 0, 2 * Math.PI);
                                        cr.clip();

                                        // Compute offsets to center the oversized image;
                                        // negative offsets allow overflow that gets clipped.
                                        int ox = (24 - img_size) / 2;
                                        int oy = (24 - img_size) / 2;
                                        Gdk.cairo_set_source_pixbuf(cr, scaled, ox, oy);
                                        cr.paint();

                                        // Optionally draw a subtle ring on top (uncomment to enable)
                                        // cr.arc(12, 12, 12, 0, 2 * Math.PI);
                                        // cr.set_source_rgba(1,1,1,0.9);
                                        // cr.set_line_width(1.5f);
                                        // cr.stroke();

                                        string surf_key = "pixbuf::circular:prefs:%s:24x24".printf(url);
                                        var circular_pb = ImageCache.get_global().get_or_from_surface(surf_key, surface, 0, 0, 24, 24);
                                        if (circular_pb != null) {
                                            var texture = Gdk.Texture.for_pixbuf(circular_pb);
                                            picture.set_paintable(texture);
                                            picture.set_size_request(26, 26);
                                            picture.set_hexpand(false);
                                            picture.set_vexpand(false);
                                            picture.set_halign(Gtk.Align.CENTER);
                                            picture.set_valign(Gtk.Align.CENTER);
                                            var par = picture.get_parent();
                                            if (par != null) {
                                                try { par.set_hexpand(false); par.set_vexpand(false); } catch (GLib.Error ee) { }
                                            }
                                        }
                                    }
                                }
                            } catch (GLib.Error e) {
                                // keep placeholder
                            }
                            return false;
                        });
                    }
                } catch (GLib.Error e) { }
                return null;
            });
        }

        // Helper: create a 24x24 circular placeholder picture and wrapper
        Gtk.Widget create_pref_prefix(out Gtk.Picture picture, string placeholder_key, string? favicon_url) {
            // Create circular placeholder surface (24x24)
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, 24, 24);
            var cr = new Cairo.Context(surface);
            cr.arc(12, 12, 12, 0, 2 * Math.PI);
            cr.set_source_rgba(0.5, 0.5, 0.5, 0.3);
            cr.fill();
            var pb = ImageCache.get_global().get_or_from_surface(placeholder_key, surface, 0, 0, 24, 24);

            picture = new Gtk.Picture();
            if (pb != null) picture.set_paintable(Gdk.Texture.for_pixbuf(pb));
            picture.set_size_request(24, 24);

            var wrapper = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            wrapper.add_css_class("circular-logo");
            wrapper.set_size_request(24, 24);
            wrapper.set_valign(Gtk.Align.CENTER);
            wrapper.set_hexpand(false);
            wrapper.set_halign(Gtk.Align.CENTER);
            wrapper.set_overflow(Gtk.Overflow.HIDDEN);
            wrapper.append(picture);

            if (favicon_url != null && favicon_url.length > 0) {
                load_favicon_circular(picture, favicon_url);
            }

            return wrapper;
        }
        
    // Track whether any source switches changed while the dialog is open.
    bool sources_changed = false;
    // Track whether any personalized category switches changed while the dialog
    // is open so we can apply a single refresh when the dialog closes.
    bool categories_changed = false;
    // Track whether the personalized_feed_enabled toggle changed so we can
    // update the main view after the dialog closes (avoid refreshing mid-edit).
    bool personalization_toggled = false;

        // Add The Guardian (multi-select)
        var guardian_row = new Adw.ActionRow();
        guardian_row.set_title("The Guardian");
        guardian_row.set_subtitle(elide_string("World news with multiple categories",28));
        guardian_row.add_css_class("source-row");
        
        Gtk.Picture guardian_picture;
        var guardian_wrapper = create_pref_prefix(out guardian_picture, "placeholder:guardian", "https://www.theguardian.com/favicon.ico");
        guardian_row.add_prefix(guardian_wrapper);
        try { guardian_row.set_tooltip_text("The Guardian\nWorld news with multiple categories"); } catch (GLib.Error ee) { }
        var guardian_switch = new Gtk.Switch();
        guardian_switch.set_active(prefs.preferred_source_enabled("guardian"));
        guardian_switch.set_halign(Gtk.Align.END);
        guardian_switch.set_valign(Gtk.Align.CENTER);
        guardian_switch.set_hexpand(false);
        guardian_switch.set_vexpand(false);
        guardian_switch.state_set.connect((sw, state) => {
            prefs.set_preferred_source_enabled("guardian", state);
            prefs.save_config();
            sources_changed = true;
            update_selection_label();
            return false;
        });
        guardian_row.add_suffix(guardian_switch);
        guardian_row.activatable = true;
        guardian_row.activated.connect(() => {
            guardian_switch.set_active(!guardian_switch.get_active());
        });
        list_box.append(guardian_row);
        
        // Add Reddit (multi-select)
        var reddit_row = new Adw.ActionRow();
        reddit_row.set_title("Reddit");
        reddit_row.set_subtitle("Popular posts from subreddits");
        reddit_row.add_css_class("source-row");
        
        Gtk.Picture reddit_picture;
        var reddit_wrapper = create_pref_prefix(out reddit_picture, "placeholder:reddit", "https://www.reddit.com/favicon.ico");
        reddit_row.add_prefix(reddit_wrapper);
        try { reddit_row.set_tooltip_text("Reddit\nPopular posts from subreddits"); } catch (GLib.Error ee) { }
        var reddit_switch = new Gtk.Switch();
        reddit_switch.set_active(prefs.preferred_source_enabled("reddit"));
        reddit_switch.set_halign(Gtk.Align.END);
        reddit_switch.set_valign(Gtk.Align.CENTER);
        reddit_switch.set_hexpand(false);
        reddit_switch.set_vexpand(false);
        reddit_switch.state_set.connect((sw, state) => {
            prefs.set_preferred_source_enabled("reddit", state);
            prefs.save_config();
            sources_changed = true;
            update_selection_label();
            return false;
        });
        reddit_row.add_suffix(reddit_switch);
        reddit_row.activatable = true;
        reddit_row.activated.connect(() => { reddit_switch.set_active(!reddit_switch.get_active()); });
        list_box.append(reddit_row);
        
        // Add BBC (multi-select)
        var bbc_row = new Adw.ActionRow();
        bbc_row.set_title("BBC News");
        bbc_row.set_subtitle(elide_string("Global news and categories",28));
        bbc_row.add_css_class("source-row");
        Gtk.Picture bbc_picture;
        var bbc_wrapper = create_pref_prefix(out bbc_picture, "placeholder:bbc", "https://www.bbc.co.uk/favicon.ico");
        bbc_row.add_prefix(bbc_wrapper);
        try { bbc_row.set_tooltip_text("BBC News\nGlobal news and categories"); } catch (GLib.Error ee) { }
        var bbc_switch = new Gtk.Switch();
        bbc_switch.set_active(prefs.preferred_source_enabled("bbc"));
        bbc_switch.set_halign(Gtk.Align.END);
        bbc_switch.set_valign(Gtk.Align.CENTER);
        bbc_switch.set_hexpand(false);
        bbc_switch.set_vexpand(false);
        bbc_switch.state_set.connect((sw, state) => {
            prefs.set_preferred_source_enabled("bbc", state);
            prefs.save_config();
            sources_changed = true;
            update_selection_label();
            return false;
        });
        bbc_row.add_suffix(bbc_switch);
        bbc_row.activatable = true;
        bbc_row.activated.connect(() => { bbc_switch.set_active(!bbc_switch.get_active()); });
        list_box.append(bbc_row);

        // Add New York Times (multi-select)
        var nyt_row = new Adw.ActionRow();
        nyt_row.set_title("New York Times");
        nyt_row.set_subtitle("NYT RSS feeds by section");
        nyt_row.add_css_class("source-row");
        Gtk.Picture nyt_picture;
        var nyt_wrapper = create_pref_prefix(out nyt_picture, "placeholder:nyt", "https://www.nytimes.com/favicon.ico");
        nyt_row.add_prefix(nyt_wrapper);
        try { nyt_row.set_tooltip_text("New York Times\nNYT RSS feeds by section"); } catch (GLib.Error ee) { }
        var nyt_switch = new Gtk.Switch();
        nyt_switch.set_active(prefs.preferred_source_enabled("nytimes"));
        nyt_switch.set_halign(Gtk.Align.END);
        nyt_switch.set_valign(Gtk.Align.CENTER);
        nyt_switch.set_hexpand(false);
        nyt_switch.set_vexpand(false);
        nyt_switch.state_set.connect((sw, state) => {
            prefs.set_preferred_source_enabled("nytimes", state);
            prefs.save_config();
            sources_changed = true;
            update_selection_label();
            return false;
        });
        nyt_row.add_suffix(nyt_switch);
        nyt_row.activatable = true;
        nyt_row.activated.connect(() => { nyt_switch.set_active(!nyt_switch.get_active()); });
        list_box.append(nyt_row);

        // Add Bloomberg (multi-select)
        var bb_row = new Adw.ActionRow();
        bb_row.set_title("Bloomberg");
        bb_row.set_subtitle("Financial and business news");
        bb_row.add_css_class("source-row");
        Gtk.Picture bb_picture;
        var bb_wrapper = create_pref_prefix(out bb_picture, "placeholder:bb", "https://www.bloomberg.com/favicon.ico");
        bb_row.add_prefix(bb_wrapper);
        try { bb_row.set_tooltip_text("Bloomberg\nFinancial and business news"); } catch (GLib.Error ee) { }
        var bb_switch = new Gtk.Switch();
        bb_switch.set_active(prefs.preferred_source_enabled("bloomberg"));
        bb_switch.set_halign(Gtk.Align.END);
        bb_switch.set_valign(Gtk.Align.CENTER);
        bb_switch.set_hexpand(false);
        bb_switch.set_vexpand(false);
        bb_switch.state_set.connect((sw, state) => {
            prefs.set_preferred_source_enabled("bloomberg", state);
            prefs.save_config();
            sources_changed = true;
            update_selection_label();
            return false;
        });
        bb_row.add_suffix(bb_switch);
        bb_row.activatable = true;
        bb_row.activated.connect(() => { bb_switch.set_active(!bb_switch.get_active()); });
        list_box.append(bb_row);

        // Add Wall Street Journal (multi-select)
        var wsj_row = new Adw.ActionRow();
        wsj_row.set_title("Wall Street Journal");
        wsj_row.set_subtitle("Business and economic news");
        wsj_row.add_css_class("source-row");
        Gtk.Picture wsj_picture;
        var wsj_wrapper = create_pref_prefix(out wsj_picture, "placeholder:wsj", "https://www.wsj.com/favicon.ico");
        wsj_row.add_prefix(wsj_wrapper);
        try { wsj_row.set_tooltip_text("Wall Street Journal\nBusiness and economic news"); } catch (GLib.Error ee) { }
        var wsj_switch = new Gtk.Switch();
        wsj_switch.set_active(prefs.preferred_source_enabled("wsj"));
        wsj_switch.set_halign(Gtk.Align.END);
        wsj_switch.set_valign(Gtk.Align.CENTER);
        wsj_switch.set_hexpand(false);
        wsj_switch.set_vexpand(false);
        wsj_switch.state_set.connect((sw, state) => {
            prefs.set_preferred_source_enabled("wsj", state);
            prefs.save_config();
            sources_changed = true;
            update_selection_label();
            return false;
        });
        wsj_row.add_suffix(wsj_switch);
        wsj_row.activatable = true;
        wsj_row.activated.connect(() => { wsj_switch.set_active(!wsj_switch.get_active()); });
        list_box.append(wsj_row);

        // Add Reuters (multi-select)
        var reuters_row = new Adw.ActionRow();
        reuters_row.set_title("Reuters");
        reuters_row.set_subtitle("International news wire");
        reuters_row.add_css_class("source-row");
        Gtk.Picture reuters_picture;
        var reuters_wrapper = create_pref_prefix(out reuters_picture, "placeholder:reuters", "https://www.reuters.com/favicon.ico");
        reuters_row.add_prefix(reuters_wrapper);
        try { reuters_row.set_tooltip_text("Reuters\nInternational news wire"); } catch (GLib.Error ee) { }
        var reuters_switch = new Gtk.Switch();
        reuters_switch.set_active(prefs.preferred_source_enabled("reuters"));
        reuters_switch.set_halign(Gtk.Align.END);
        reuters_switch.set_valign(Gtk.Align.CENTER);
        reuters_switch.set_hexpand(false);
        reuters_switch.set_vexpand(false);
        reuters_switch.state_set.connect((sw, state) => {
            prefs.set_preferred_source_enabled("reuters", state);
            prefs.save_config();
            sources_changed = true;
            update_selection_label();
            return false;
        });
        reuters_row.add_suffix(reuters_switch);
        reuters_row.activatable = true;
        reuters_row.activated.connect(() => { reuters_switch.set_active(!reuters_switch.get_active()); });
        list_box.append(reuters_row);

        // Add NPR (multi-select)
        var npr_row = new Adw.ActionRow();
        npr_row.set_title("NPR");
        npr_row.set_subtitle("National Public Radio");
        npr_row.add_css_class("source-row");
        Gtk.Picture npr_picture;
        var npr_wrapper = create_pref_prefix(out npr_picture, "placeholder:npr", "https://www.npr.org/favicon.ico");
        npr_row.add_prefix(npr_wrapper);
        try { npr_row.set_tooltip_text("NPR\nNational Public Radio"); } catch (GLib.Error ee) { }
        var npr_switch = new Gtk.Switch();
        npr_switch.set_active(prefs.preferred_source_enabled("npr"));
        npr_switch.set_halign(Gtk.Align.END);
        npr_switch.set_valign(Gtk.Align.CENTER);
        npr_switch.set_hexpand(false);
        npr_switch.set_vexpand(false);
        npr_switch.state_set.connect((sw, state) => {
            prefs.set_preferred_source_enabled("npr", state);
            prefs.save_config();
            sources_changed = true;
            update_selection_label();
            return false;
        });
        npr_row.add_suffix(npr_switch);
        npr_row.activatable = true;
        npr_row.activated.connect(() => { npr_switch.set_active(!npr_switch.get_active()); });
        list_box.append(npr_row);

        // Add Fox News (multi-select)
        var fox_row = new Adw.ActionRow();
        fox_row.set_title("Fox News");
        fox_row.set_subtitle("Conservative-leaning US news");
        fox_row.add_css_class("source-row");
        Gtk.Picture fox_picture;
        var fox_wrapper = create_pref_prefix(out fox_picture, "placeholder:fox", "https://www.foxnews.com/favicon.ico");
        fox_row.add_prefix(fox_wrapper);
        try { fox_row.set_tooltip_text("Fox News\nConservative-leaning US news"); } catch (GLib.Error ee) { }
        var fox_switch = new Gtk.Switch();
        fox_switch.set_active(prefs.preferred_source_enabled("fox"));
        fox_switch.set_halign(Gtk.Align.END);
        fox_switch.set_valign(Gtk.Align.CENTER);
        fox_switch.set_hexpand(false);
        fox_switch.set_vexpand(false);
        fox_switch.state_set.connect((sw, state) => {
            prefs.set_preferred_source_enabled("fox", state);
            prefs.save_config();
            sources_changed = true;
            update_selection_label();
            return false;
        });
        fox_row.add_suffix(fox_switch);
        fox_row.activatable = true;
        fox_row.activated.connect(() => { fox_switch.set_active(!fox_switch.get_active()); });
        list_box.append(fox_row);

        // Add custom RSS sources from database
        var rss_store = Paperboy.RssSourceStore.get_instance();
        var custom_sources = rss_store.get_all_sources();

        // Create separate list for custom sources if they exist
        Gtk.ListBox? custom_list_box = null;
        Gtk.Label? custom_header_label = null;

        if (custom_sources.size > 0) {
            // Create header label outside of any list box
            custom_header_label = new Gtk.Label("<b>Followed Sources</b>");
            custom_header_label.set_use_markup(true);
            custom_header_label.set_halign(Gtk.Align.START);
            custom_header_label.set_margin_start(12);
            custom_header_label.set_margin_top(12);
            custom_header_label.set_margin_bottom(6);

            // Create separate list box for custom sources with card styling
            custom_list_box = new Gtk.ListBox();
            custom_list_box.set_selection_mode(Gtk.SelectionMode.NONE);
            custom_list_box.add_css_class("boxed-list");

            foreach (var rss_source in custom_sources) {
                var custom_row = new Adw.ActionRow();
                
                // Try to get display name from SourceMetadata first (matches what user sees in Front Page/Top Ten)
                string display_name = rss_source.name;
                string? metadata_display_name = SourceMetadata.get_display_name_for_source(rss_source.name);
                if (metadata_display_name != null && metadata_display_name.length > 0) {
                    display_name = metadata_display_name;
                }
                
                // For custom/followed sources we show a single-line,
                // ellipsized label (title + short URL) so it never
                // wraps to two lines. Leave built-in rows untouched.
                custom_row.set_title("");
                custom_row.add_css_class("source-row");

                Gtk.Picture custom_picture;
                var custom_wrapper = create_pref_prefix(out custom_picture, "placeholder:rss:%s".printf(rss_source.url), null);

                // Build a vertical title area: full source name, then a
                // single-line URL underneath that is ellipsized at the end.
                var title_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);

                var name_lbl = new Gtk.Label(display_name);
                name_lbl.set_halign(Gtk.Align.START);
                name_lbl.set_valign(Gtk.Align.CENTER);
                name_lbl.set_xalign(0.0f);
                name_lbl.set_wrap(false);
                name_lbl.get_style_context().add_class("title");
                title_box.append(name_lbl);

                var url_lbl = new Gtk.Label(elide_string(rss_source.url, 28));
                url_lbl.set_halign(Gtk.Align.START);
                url_lbl.set_valign(Gtk.Align.CENTER);
                url_lbl.set_xalign(0.0f);
                url_lbl.set_wrap(false);
                url_lbl.set_ellipsize(Pango.EllipsizeMode.END);
                url_lbl.get_style_context().add_class("subtitle");
                title_box.append(url_lbl);

                // Vertically center the title area so the icon and the
                // labels line up horizontally (same vertical middle).
                title_box.set_valign(Gtk.Align.CENTER);

                var composite_prefix = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 12);
                composite_prefix.set_hexpand(true);
                // Ensure the composite prefix itself is vertically centered
                // so its children (the 24x24 wrapper and the title box)
                // share the same vertical center within the ActionRow.
                composite_prefix.set_valign(Gtk.Align.CENTER);
                composite_prefix.append(custom_wrapper);
                composite_prefix.append(title_box);

                custom_row.add_prefix(composite_prefix);

                // Show full name and URL on hover since the row displays an
                // elided URL in the subtitle. This gives users a quick way
                // to see the full descriptor without expanding the layout.
                try { custom_row.set_tooltip_text(display_name + "\n" + rss_source.url); } catch (GLib.Error ee) { }

                // Helper function to load icon from file with Cairo circular clipping
                void try_load_icon_circular(string path, Gtk.Picture picture) {
                    if (GLib.FileUtils.test(path, GLib.FileTest.EXISTS)) {
                                try {
                                    int img_size = 24;
                                    var pixbuf = new Gdk.Pixbuf.from_file_at_scale(path, img_size, img_size, true);
                                    if (pixbuf != null) {
                                        // Create final 24x24 surface and clip to circular mask
                                        var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, 24, 24);
                                        var cr = new Cairo.Context(surface);

                                        cr.arc(12, 12, 12, 0, 2 * Math.PI);
                                        cr.clip();

                                        int ox = (24 - img_size) / 2;
                                        int oy = (24 - img_size) / 2;
                                        Gdk.cairo_set_source_pixbuf(cr, pixbuf, ox, oy);
                                        cr.paint();

                                        string surf_key = "pixbuf::circular:prefs:%s:24x24".printf(path);
                                        var circular_pb = ImageCache.get_global().get_or_from_surface(surf_key, surface, 0, 0, 24, 24);
                                        if (circular_pb != null) {
                                            var texture = Gdk.Texture.for_pixbuf(circular_pb);
                                            picture.set_paintable(texture);
                                        }
                                    }
                                } catch (GLib.Error e) {
                                    // Keep current icon on error
                                }
                    }
                }

                bool icon_loaded = false;

                // Priority 1: Try to load from saved file (SourceMetadata saved filename)
                string? icon_filename = SourceMetadata.get_saved_filename_for_source(rss_source.name);
                if (icon_filename != null && icon_filename.length > 0) {
                    var data_dir = GLib.Environment.get_user_data_dir();
                    var icon_path = GLib.Path.build_filename(data_dir, "paperboy", "source_logos", icon_filename);
                    if (GLib.FileUtils.test(icon_path, GLib.FileTest.EXISTS)) {
                        try_load_icon_circular(icon_path, custom_picture);
                        icon_loaded = true;
                    }
                }

                // Priority 2: Try API logo URL from SourceMetadata (high quality from logo.dev)
                if (!icon_loaded) {
                    string? meta_logo_url = SourceMetadata.get_logo_url_for_source(rss_source.name);
                    if (meta_logo_url != null && meta_logo_url.length > 0 &&
                        (meta_logo_url.has_prefix("http://") || meta_logo_url.has_prefix("https://"))) {
                        load_favicon_circular(custom_picture, meta_logo_url);
                        icon_loaded = true;
                    }
                }

                // Priority 3: Try Google favicon service
                if (!icon_loaded) {
                    string? host = UrlUtils.extract_host_from_url(rss_source.url);
                    if (host != null && host.length > 0) {
                        string google_favicon_url = "https://www.google.com/s2/favicons?domain=" + host + "&sz=128";
                        load_favicon_circular(custom_picture, google_favicon_url);
                        icon_loaded = true;
                    }
                }

                // Priority 4: Try RSS favicon_url
                if (!icon_loaded && rss_source.favicon_url != null && rss_source.favicon_url.length > 0 &&
                    (rss_source.favicon_url.has_prefix("http://") || rss_source.favicon_url.has_prefix("https://"))) {
                    load_favicon_circular(custom_picture, rss_source.favicon_url);
                    icon_loaded = true;
                }

                // Create delete button
                var delete_btn = new Gtk.Button();
                delete_btn.set_icon_name("user-trash-symbolic");
                delete_btn.set_valign(Gtk.Align.CENTER);
                delete_btn.set_has_frame(false);
                delete_btn.set_tooltip_text("Unfollow this source");
                delete_btn.add_css_class("destructive-action");
                delete_btn.clicked.connect(() => {
                    // Check if we're currently viewing this RSS source
                    bool is_currently_viewing = false;
                    try {
                        if (win != null && win.prefs.category != null && win.prefs.category.has_prefix("rssfeed:")) {
                            string current_url = win.prefs.category.substring(8); // Remove "rssfeed:" prefix
                            if (current_url == rss_source.url) {
                                is_currently_viewing = true;
                            }
                        }
                    } catch (GLib.Error e) { }

                    // Remove from database
                    rss_store.remove_source(rss_source.url);
                    // Remove from preferences if enabled
                    if (prefs.preferred_source_enabled("custom:" + rss_source.url)) {
                        prefs.set_preferred_source_enabled("custom:" + rss_source.url, false);
                        prefs.save_config();
                        sources_changed = true;
                    }
                    // Remove the row from the list
                    custom_list_box.remove(custom_row);
                    update_selection_label();

                    // If we were viewing this source, navigate to Front Page
                    if (is_currently_viewing && win != null) {
                        GLib.Idle.add(() => {
                            try {
                                win.prefs.category = "frontpage";
                                win.prefs.save_config();
                                win.fetch_news();
                            } catch (GLib.Error e) { }
                            return false;
                        });
                    }
                });

                // Add switch to enable/disable this custom source
                var custom_switch = new Gtk.Switch();
                custom_switch.set_active(prefs.preferred_source_enabled("custom:" + rss_source.url));
                custom_switch.set_halign(Gtk.Align.END);
                custom_switch.set_valign(Gtk.Align.CENTER);

                custom_switch.state_set.connect((sw, state) => {
                    prefs.set_preferred_source_enabled("custom:" + rss_source.url, state);
                    prefs.save_config();
                    sources_changed = true;
                    update_selection_label();
                    return false;
                });

                // Add delete button first, then switch
                custom_row.add_suffix(delete_btn);
                custom_row.add_suffix(custom_switch);

                custom_row.activatable = true;
                custom_row.activated.connect(() => {
                    custom_switch.set_active(!custom_switch.get_active());
                });

                custom_list_box.append(custom_row);
            }
        }

    // Build the main container that shows the source list and the
    // personalized toggle; we'll place that inside a Gtk.Stack so we
    // can slide in a categories pane on demand.
    var main_container = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
    main_container.set_margin_top(6);
    main_container.set_margin_bottom(6);
    main_container.set_size_request(325, -1);

    // Append the selection label (declared above) and the list box
    main_container.append(selection_label);
    main_container.append(list_box);

    // Add custom sources header and list if they exist
    if (custom_header_label != null && custom_list_box != null) {
        main_container.append(custom_header_label);
        main_container.append(custom_list_box);
    }

    // Initialize selection label text according to current prefs
    update_selection_label();

    var sep = new Gtk.Separator(Gtk.Orientation.HORIZONTAL);
    sep.set_margin_top(6);
    sep.set_margin_bottom(6);
    main_container.append(sep);

        // App Settings header
        var app_settings_header = new Gtk.Label("App Settings");
        app_settings_header.set_xalign(0);
        app_settings_header.add_css_class("heading");
        app_settings_header.set_margin_start(12);
        app_settings_header.set_margin_end(12);
        app_settings_header.set_margin_top(12);
        app_settings_header.set_margin_bottom(6);
        main_container.append(app_settings_header);

        // Personalized feed toggle (separate from the source list)
        var personalized_row = new Adw.ActionRow();
        personalized_row.set_title("Enable personalized feed");
        personalized_row.set_subtitle("Enable a personalized feed based on your reading habits");
        var personalized_switch = new Gtk.Switch();
        personalized_switch.set_active(prefs.personalized_feed_enabled);
        personalized_switch.set_halign(Gtk.Align.END);
        personalized_switch.set_valign(Gtk.Align.CENTER);
        personalized_switch.set_hexpand(false);
        personalized_switch.set_vexpand(false);
        personalized_switch.set_margin_top(0);
        personalized_switch.set_margin_bottom(0);

        // Create the settings button for personalized feed categories
        var settings_btn = new Gtk.Button();
        settings_btn.set_valign(Gtk.Align.CENTER);
        settings_btn.set_has_frame(false);
        var settings_icon = new Gtk.Image.from_icon_name("settings-symbolic");
        settings_icon.set_pixel_size(16);
        settings_btn.set_child(settings_icon);
        settings_btn.set_tooltip_text("Personalized feed settings");

        // When toggled, persist the preference immediately
        personalized_switch.state_set.connect((sw, state) => {
            prefs.personalized_feed_enabled = state;
            prefs.save_config();
            try {
                if (win != null) personalization_toggled = true;
            } catch (GLib.Error e) { /* ignore if parent doesn't implement it */ }
            return false; // allow the state change to proceed
        });

        // Add settings button first (left), then switch (right)
        personalized_row.add_suffix(settings_btn);
        personalized_row.add_suffix(personalized_switch);

        main_container.append(personalized_row);

        // Add "Custom sources only in My Feed" toggle (independent option)
        var custom_only_row = new Adw.ActionRow();
        custom_only_row.set_title("Custom sources only in My Feed");
        custom_only_row.set_subtitle("Show only followed RSS sources in My Feed, hide built-in sources");
        var custom_only_switch = new Gtk.Switch();
        custom_only_switch.set_active(prefs.myfeed_custom_only);
        custom_only_switch.set_halign(Gtk.Align.END);
        custom_only_switch.set_valign(Gtk.Align.CENTER);
        custom_only_switch.set_hexpand(false);
        custom_only_switch.set_vexpand(false);
        custom_only_switch.state_set.connect((sw, state) => {
            prefs.myfeed_custom_only = state;
            prefs.save_config();
            sources_changed = true;
            return false;
        });
        custom_only_row.add_suffix(custom_only_switch);
        custom_only_row.activatable = true;
        custom_only_row.activated.connect(() => { custom_only_switch.set_active(!custom_only_switch.get_active()); });
        main_container.append(custom_only_row);

        // Unread count badges preference
        var unread_badges_row = new Adw.ActionRow();
        unread_badges_row.set_title("Show unread count badges");
        unread_badges_row.set_subtitle("Display unread article counts in the sidebar");
        var unread_badges_switch = new Gtk.Switch();
        unread_badges_switch.set_active(prefs.unread_badges_enabled);
        unread_badges_switch.set_halign(Gtk.Align.END);
        unread_badges_switch.set_valign(Gtk.Align.CENTER);
        unread_badges_switch.set_hexpand(false);
        unread_badges_switch.set_vexpand(false);

        // Create the settings button for badge visibility options
        var badge_settings_btn = new Gtk.Button();
        badge_settings_btn.set_valign(Gtk.Align.CENTER);
        badge_settings_btn.set_has_frame(false);
        var badge_settings_icon = new Gtk.Image.from_icon_name("settings-symbolic");
        badge_settings_icon.set_pixel_size(16);
        badge_settings_btn.set_child(badge_settings_icon);
        badge_settings_btn.set_tooltip_text("Badge visibility settings");

        // When toggled, persist the preference and refresh sidebar
        unread_badges_switch.state_set.connect((sw, state) => {
            prefs.unread_badges_enabled = state;
            prefs.save_config();
            // Refresh sidebar badges to show/hide them
            if (win != null && win.sidebar_manager != null) {
                win.sidebar_manager.refresh_all_badges();
            }
            return false;
        });

        // Settings button shows a popover with category/source toggles
        badge_settings_btn.clicked.connect(() => {
            var popover = new Gtk.Popover();
            var popover_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
            popover_box.set_margin_start(12);
            popover_box.set_margin_end(12);
            popover_box.set_margin_top(12);
            popover_box.set_margin_bottom(12);

            var categories_check = new Gtk.CheckButton.with_label("Show on categories");
            categories_check.set_active(prefs.unread_badges_categories);
            categories_check.toggled.connect(() => {
                prefs.unread_badges_categories = categories_check.get_active();
                prefs.save_config();
                if (win != null && win.sidebar_manager != null) {
                    win.sidebar_manager.refresh_all_badges();
                }
            });

            var sources_check = new Gtk.CheckButton.with_label("Show on followed sources");
            sources_check.set_active(prefs.unread_badges_sources);
            sources_check.toggled.connect(() => {
                prefs.unread_badges_sources = sources_check.get_active();
                prefs.save_config();
                if (win != null && win.sidebar_manager != null) {
                    win.sidebar_manager.refresh_all_badges();
                }
            });

            popover_box.append(categories_check);
            popover_box.append(sources_check);
            popover.set_child(popover_box);
            popover.set_parent(badge_settings_btn);
            popover.popup();
        });

        // Add settings button first (left), then switch (right)
        unread_badges_row.add_suffix(badge_settings_btn);
        unread_badges_row.add_suffix(unread_badges_switch);
        main_container.append(unread_badges_row);

        // No Local News image limit preference: keep UX simple and load a
        // small, fixed amount by default to avoid excessive memory use.

        // Create categories pane (initially hidden) that slides in over main
        var categories_container = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
        categories_container.set_margin_top(6);
        categories_container.set_margin_bottom(6);

        // Header with back button
        var header_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        var back_btn = new Gtk.Button();
        var back_icon = new Gtk.Image.from_icon_name("go-previous-symbolic");
        back_icon.set_pixel_size(16);
        back_btn.set_child(back_icon);
        back_btn.set_tooltip_text("Back");
        header_box.append(back_btn);
        var header_label = new Gtk.Label("Categories");
        header_label.set_halign(Gtk.Align.START);
        header_label.set_valign(Gtk.Align.CENTER);
        header_box.append(header_label);
        categories_container.append(header_box);

        // Scrolled list for categories (in case there are many)
        var scroller = new Gtk.ScrolledWindow();
        scroller.set_vexpand(true);
        scroller.set_hexpand(true);
        var cats_list = new Gtk.ListBox();
        cats_list.set_selection_mode(Gtk.SelectionMode.NONE);

        // Helper: find data file for bundled icons (copied minimal logic)
        string? find_data_file_local(string relative) {
            string[] dev_prefixes = { "data", "../data" };
            foreach (var prefix in dev_prefixes) {
                var path = GLib.Path.build_filename(prefix, relative);
                if (GLib.FileUtils.test(path, GLib.FileTest.EXISTS)) return path;
            }
            var user_data = GLib.Environment.get_user_data_dir();
            if (user_data != null && user_data.length > 0) {
                var user_path = GLib.Path.build_filename(user_data, "paperboy", relative);
                if (GLib.FileUtils.test(user_path, GLib.FileTest.EXISTS)) return user_path;
            }
            var sys_dirs = GLib.Environment.get_system_data_dirs();
            foreach (var dir in sys_dirs) {
                var sys_path = GLib.Path.build_filename(dir, "paperboy", relative);
                if (GLib.FileUtils.test(sys_path, GLib.FileTest.EXISTS)) return sys_path;
            }
            return null;
        }

        // Local helper to create the category icon (tries bundled mono icons then theme fallbacks)
        Gtk.Widget? create_category_icon_local(string cat) {
            string? filename = null;
                switch (cat) {
                case "myfeed": filename = "myfeed-mono.svg"; break;
                case "general": filename = "world-mono.svg"; break;
                case "business": filename = "business-mono.svg"; break;
                case "markets": filename = "markets-mono.svg"; break;
                case "industries": filename = "industries-mono.svg"; break;
                case "economics": filename = "economics-mono.svg"; break;
                case "wealth": filename = "wealth-mono.svg"; break;
                case "green": filename = "green-mono.svg"; break;
                case "us": filename = "us-mono.svg"; break;
                case "technology": filename = "technology-mono.svg"; break;
                case "science": filename = "science-mono.svg"; break;
                case "sports": filename = "sports-mono.svg"; break;
                case "health": filename = "health-mono.svg"; break;
                case "entertainment": filename = "entertainment-mono.svg"; break;
                case "politics": filename = "politics-mono.svg"; break;
                case "lifestyle": filename = "lifestyle-mono.svg"; break;
                default: filename = null; break;
            }

            if (filename != null) {
                // Prefer pre-bundled symbolic mono icons inside data/icons/symbolic/
                string[] candidates = {
                    GLib.Path.build_filename("icons", "symbolic", filename),
                    GLib.Path.build_filename("icons", filename)
                };
                string? icon_path = null;
                foreach (var c in candidates) {
                    icon_path = find_data_file_local(c);
                    if (icon_path != null) break;
                }

                if (icon_path != null) {
                    try {
                        bool dark = false;
                        var sm = Adw.StyleManager.get_default();
                        if (sm != null) dark = sm.dark;
                        string use_path = icon_path;
                        if (dark) {
                            string alt_name;
                            if (filename.has_suffix(".svg"))
                                alt_name = filename.substring(0, filename.length - 4) + "-white.svg";
                            else
                                alt_name = filename + "-white.svg";

                            string? white_candidate = find_data_file_local(GLib.Path.build_filename("icons", "symbolic", alt_name));
                            if (white_candidate == null) white_candidate = find_data_file_local(GLib.Path.build_filename("icons", alt_name));
                            if (white_candidate != null) use_path = white_candidate;
                        }
                        var img = new Gtk.Image.from_file(use_path);
                        img.set_pixel_size(24);
                        return img;
                    } catch (GLib.Error e) { }
                }
            }
            // Fallback: simple symbolic icon
            var img2 = new Gtk.Image.from_icon_name("tag-symbolic");
            img2.set_pixel_size(16);
            return img2;
        }

        // Helper to (re)build the categories list based on current prefs.
        void rebuild_cats_list() {
            // Clear existing rows
            Gtk.Widget? child = cats_list.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                cats_list.remove(child);
                child = next;
            }

            // Decide whether to show Bloomberg-specific categories. Treat
            // the multi-select `preferred_sources` as authoritative when it
            // contains any entries; only fall back to the legacy single
            // `news_source` when no `preferred_sources` are present. This
            // ensures that if the user unchecks Bloomberg in the multi-select
            // UI, Bloomberg-specific categories are hidden even if a legacy
            // `news_source` value remained set from earlier runs.
            bool is_bloomberg_selected;
            if (prefs.preferred_sources != null && prefs.preferred_sources.size > 0) {
                is_bloomberg_selected = prefs.preferred_source_enabled("bloomberg");
            } else {
                is_bloomberg_selected = (prefs.news_source == NewsSource.BLOOMBERG);
            }

            // Build a merged list of categories. If Bloomberg is the ONLY
            // selected preferred source, show only Bloomberg-specific
            // categories. Otherwise include the base (common) categories and
            // add Bloomberg sections when Bloomberg is selected among others.
            var cat_ids_list = new Gee.ArrayList<string>();
            var cat_titles_list = new Gee.ArrayList<string>();

            // Decide if Bloomberg is the sole enabled source
            bool bloomberg_only = false;
            if (prefs.preferred_sources != null && prefs.preferred_sources.size > 0) {
                bloomberg_only = (prefs.preferred_sources.size == 1 && prefs.preferred_source_enabled("bloomberg"));
            } else {
                bloomberg_only = (prefs.news_source == NewsSource.BLOOMBERG);
            }

            // Bloomberg-specific IDs/titles (used in both bloomberg-only and mixed modes)
            string[] bb_ids = { "markets", "industries", "economics", "wealth", "green", "technology", "politics" };
            string[] bb_titles = { "Markets", "Industries", "Economics", "Wealth", "Green", "Technology", "Politics" };

            if (bloomberg_only) {
                // If Bloomberg is the only source, present only Bloomberg
                // categories so the UI and saved preferences can't pick
                // non-Bloomberg categories.
                for (int j = 0; j < bb_ids.length; j++) {
                    cat_ids_list.add(bb_ids[j]);
                    cat_titles_list.add(bb_titles[j]);
                }
            } else {
                // Base (common) categories - keep these visible normally
                string[] base_ids = { "general", "us", "technology", "business", "science", "sports", "health", "entertainment", "politics", "lifestyle" };
                string[] base_titles = { "World News", "US News", "Technology", "Business", "Science", "Sports", "Health", "Entertainment", "Politics", "Lifestyle" };
                for (int i = 0; i < base_ids.length; i++) {
                    cat_ids_list.add(base_ids[i]);
                    cat_titles_list.add(base_titles[i]);
                }

                if (is_bloomberg_selected) {
                    // Add Bloomberg-specific additional categories; avoid
                    // adding duplicates if they overlap with base categories.
                    for (int j = 0; j < bb_ids.length; j++) {
                        string bid = bb_ids[j];
                        bool exists = false;
                        for (int k = 0; k < cat_ids_list.size; k++) {
                            if (cat_ids_list.get(k) == bid) { exists = true; break; }
                        }
                        if (!exists) {
                            cat_ids_list.add(bid);
                            cat_titles_list.add(bb_titles[j]);
                        }
                    }
                }
            }

            for (int i = 0; i < cat_ids_list.size; i++) {
                string cat_id = cat_ids_list.get(i);
                string cat_title = cat_titles_list.get(i);
                var crow = new Adw.ActionRow();
                crow.set_title(cat_title);
                var prefix = create_category_icon_local(cat_id);
                if (prefix != null) crow.add_prefix(prefix);
                var cswitch = new Gtk.Switch();
                cswitch.set_active(prefs.personalized_category_enabled(cat_id));
                /* Ensure the per-category switch does not expand vertically
                 * or otherwise get sized taller than the row. Align it to the
                 * center and disable expansion so it stays compact. */
                cswitch.set_halign(Gtk.Align.END);
                cswitch.set_valign(Gtk.Align.CENTER);
                cswitch.set_hexpand(false);
                cswitch.set_vexpand(false);
                cswitch.set_margin_top(0);
                cswitch.set_margin_bottom(0);
                // Capture cat_id for the closure
                string _cid = cat_id;
                cswitch.state_set.connect((sw, state) => {
                    prefs.set_personalized_category_enabled(_cid, state);
                    prefs.save_config();
                    // Mark that categories changed; apply a single refresh when
                    // the dialog closes so the user can make multiple edits.
                    try {
                        categories_changed = true;
                    } catch (GLib.Error e) { }
                    return false;
                });
                crow.add_suffix(cswitch);
                cats_list.append(crow);
            }
        }

        // Build initial categories list
        rebuild_cats_list();

        scroller.set_child(cats_list);
        categories_container.append(scroller);

        // Create a stack to slide between main and categories views
        var stack = new Gtk.Stack();
        stack.set_transition_type(Gtk.StackTransitionType.SLIDE_LEFT_RIGHT);
        stack.add_titled(main_container, "main", "Main");
        stack.add_titled(categories_container, "cats", "Categories");

        // Wire back button to return to main view
        back_btn.clicked.connect(() => {
            stack.set_visible_child_name("main");
        });

        // Wire settings button to rebuild categories (reflecting any switch
        // changes) then show the categories pane.
        settings_btn.clicked.connect(() => {
            rebuild_cats_list();
            stack.set_visible_child_name("cats");
        });

        sources_dialog.set_extra_child(stack);

        // Listen for theme (dark) changes and rebuild the categories list
        // so bundled mono icons can be swapped for white variants while the
        // dialog is open.
        var sm_local = Adw.StyleManager.get_default();
        if (sm_local != null) {
            sm_local.notify["dark"].connect(() => {
                try {
                    // Rebuild categories to pick up white/normal icon variants
                    rebuild_cats_list();
                } catch (GLib.Error e) { }
            });
        }
        sources_dialog.add_response("close", "Close");
        sources_dialog.set_default_response("close");
        sources_dialog.set_close_response("close");
        sources_dialog.present(parent);

        // Ensure at least one source is selected when the dialog closes.
        // If the user managed to disable all sources (or closed without
        // selecting any), auto-enable Guardian and persist the change so
        // the app always has a valid source to fetch from.
        sources_dialog.destroy.connect(() => {
            try {
                // Re-read prefs instance in case handlers mutated it
                var check_prefs = NewsPreferences.get_instance();
                bool did_auto_enable = false;
                bool did_change_news_source = false;
                if (check_prefs.preferred_sources == null || check_prefs.preferred_sources.size == 0) {
                    // Enable guardian and persist immediately
                    check_prefs.set_preferred_source_enabled("guardian", true);
                    check_prefs.save_config();
                    did_auto_enable = true;
                }

                // Quick workaround: if Bloomberg is enabled together with other
                // preferred sources, ensure the persisted single `news_source`
                // isn't left pointing at Bloomberg. Pick the first non-Bloomberg
                // preferred source and persist it so legacy checks that still
                // read `prefs.news_source` behave sensibly.
                try {
                    if (check_prefs.preferred_sources != null && check_prefs.preferred_sources.size > 1) {
                        // If Bloomberg is one of the enabled preferred sources,
                        // prefer persisting the single `news_source` value as
                        // Bloomberg so legacy code paths that read
                        // `prefs.news_source` reflect the user's selection.
                        bool has_bb = false;
                        foreach (var sid in check_prefs.preferred_sources) {
                            if (sid == "bloomberg") { has_bb = true; break; }
                        }
                                if (has_bb) {
                                    // If Bloomberg is one of several preferred sources,
                                    // persist a sensible single `news_source` for legacy
                                    // compatibility: prefer the first non-Bloomberg
                                    // preferred source so we don't force Bloomberg-only
                                    // category semantics (which would disable "My Feed").
                                    string chosen = "";
                                    foreach (var sid in check_prefs.preferred_sources) {
                                        if (sid != "bloomberg") { chosen = sid; break; }
                                    }
                                    if (chosen.length == 0) {
                                        // All enabled sources are Bloomberg (edge-case) - keep Bloomberg
                                        check_prefs.news_source = NewsSource.BLOOMBERG;
                                    } else {
                                        switch (chosen) {
                                            case "guardian": check_prefs.news_source = NewsSource.GUARDIAN; break;
                                            case "reddit": check_prefs.news_source = NewsSource.REDDIT; break;
                                            case "bbc": check_prefs.news_source = NewsSource.BBC; break;
                                            case "nytimes": check_prefs.news_source = NewsSource.NEW_YORK_TIMES; break;
                                            case "wsj": check_prefs.news_source = NewsSource.WALL_STREET_JOURNAL; break;
                                            case "reuters": check_prefs.news_source = NewsSource.REUTERS; break;
                                            case "npr": check_prefs.news_source = NewsSource.NPR; break;
                                            case "fox": check_prefs.news_source = NewsSource.FOX; break;
                                            default: /* leave as-is for unknown ids */ break;
                                        }
                                    }
                                    check_prefs.save_config();
                                    did_change_news_source = true;
                                }
                    }
                } catch (GLib.Error e) { /* best-effort only */ }

                // If parent is NewsWindow, check if we need to prompt for refresh
                try {
                    var parent_win = parent as NewsWindow;
                    if (parent_win != null) {
                        // Only prompt if sources changed while dialog was open or we
                        // auto-enabled Guardian, or we changed the persisted news_source,
                        // or categories/personalization changed
                        if (sources_changed || did_auto_enable || did_change_news_source || categories_changed || personalization_toggled) {
                            // If sources changed, validate that current category is still supported
                            if (sources_changed) {
                                string current_category = prefs.category;
                                // Check if current category is supported by any enabled source
                                bool category_supported = false;

                                // Get list of enabled sources
                                if (prefs.preferred_sources != null && prefs.preferred_sources.size > 0) {
                                    foreach (string source_id in prefs.preferred_sources) {
                                        NewsSource source;
                                        switch (source_id) {
                                            case "guardian": source = NewsSource.GUARDIAN; break;
                                            case "reddit": source = NewsSource.REDDIT; break;
                                            case "bbc": source = NewsSource.BBC; break;
                                            case "nytimes": source = NewsSource.NEW_YORK_TIMES; break;
                                            case "wsj": source = NewsSource.WALL_STREET_JOURNAL; break;
                                            case "bloomberg": source = NewsSource.BLOOMBERG; break;
                                            case "reuters": source = NewsSource.REUTERS; break;
                                            case "npr": source = NewsSource.NPR; break;
                                            case "fox": source = NewsSource.FOX; break;
                                            default: continue;
                                        }

                                        // Check if this source supports the current category
                                        if (NewsSources.supports_category(source, current_category)) {
                                            category_supported = true;
                                            break;
                                        }
                                    }
                                } else {
                                    // No sources enabled, fallback to default source
                                    category_supported = NewsSources.supports_category(prefs.news_source, current_category);
                                }

                                // If category no longer supported, redirect to frontpage
                                if (!category_supported) {
                                    prefs.category = "frontpage";
                                    prefs.save_config();
                                }
                            }

                            // Update UI state first (doesn't require refresh)
                            try { parent_win.update_personalization_ui(); } catch (GLib.Error e) { }

                            // Show confirmation dialog asking if user wants to refresh
                            var confirm_dialog = new Adw.AlertDialog(
                                "Refresh Content?",
                                "Changes have been made to your settings. Would you like to refresh the content now?"
                            );
                            confirm_dialog.add_response("cancel", "Not Now");
                            confirm_dialog.add_response("refresh", "Refresh");
                            confirm_dialog.set_default_response("refresh");
                            confirm_dialog.set_close_response("cancel");
                            confirm_dialog.set_response_appearance("refresh", Adw.ResponseAppearance.SUGGESTED);

                            confirm_dialog.choose.begin(parent, null, (obj, res) => {
                                try {
                                    string response = confirm_dialog.choose.end(res);
                                    if (response == "refresh") {
                                        parent_win.fetch_news();
                                    }
                                } catch (GLib.Error e) { }
                            });
                        }
                    }
                } catch (GLib.Error e) { }
            } catch (GLib.Error e) {
                // best-effort only; nothing sensible to do on error
            }
        });
    }
    
    public static void show_about_dialog(Gtk.Window parent) {
    var about = new Adw.AboutDialog();
    about.set_application_name("Paperboy");
    about.set_application_icon("paperboy"); // Use the correct icon name
    about.set_version("0.7.0a");
    about.set_developer_name("thecalamityjoe87 (Isaac Joseph)");
    about.set_comments("A simple news app written in Vala, built with GTK4 and Libadwaita.");
    about.set_website("https://github.com/thecalamityjoe87/paperboy");
    about.set_license_type(Gtk.License.GPL_3_0);
    about.set_copyright("© 2025 thecalamityjoe87 (Isaac Joseph)");
    about.present(parent);
    }

    
    // Simple dialog to set a free-form user location string. This is a UI
    // shell that persists the value to NewsPreferences. Validation is minimal
    // (non-empty) and saving happens immediately when the user clicks Save.
    public static void show_set_location_dialog(Gtk.Window parent) {
        var prefs = NewsPreferences.get_instance();

        // Guidance text updated to explicitly mention city name or US ZIP code.
        var dialog = new Adw.AlertDialog("Set User Location",
            "Enter a city name or a ZIP code (used for localized content).\nExamples: \"San Francisco, CA\" or \"94103\" or \"94103-1234\"");
        dialog.set_body_use_markup(false);

    var entry = new Gtk.Entry();
    // Keep the input blank by default (user must type a value).
    entry.set_text("");
        entry.set_placeholder_text("City name or ZIP code (e.g. San Francisco, 94103)");
        entry.set_hexpand(true);
        entry.set_margin_top(6);
        entry.set_margin_bottom(6);

    // Suggestions area: an inline list that appears below the entry
    var suggestions_scroller = new Gtk.ScrolledWindow();
    suggestions_scroller.set_min_content_height(0);
    suggestions_scroller.set_max_content_height(200);
    suggestions_scroller.set_vexpand(false);
    var suggestions_list = new Gtk.ListBox();
    suggestions_list.set_selection_mode(Gtk.SelectionMode.NONE);
    suggestions_scroller.set_child(suggestions_list);
    suggestions_scroller.hide();

        // Small helper label for inline hints / validation messages
        var hint = new Gtk.Label("");
        hint.add_css_class("dim-label");
        hint.set_halign(Gtk.Align.START);
        hint.set_valign(Gtk.Align.CENTER);
        hint.set_margin_top(4);

        // If a user location is already set in preferences, show it here
        // as an informational message while keeping the entry blank.
        try {
            string cur_city = "";
            if (prefs.user_location_city != null && prefs.user_location_city.length > 0) {
                cur_city = prefs.user_location_city;
            } else if (prefs.user_location != null && prefs.user_location.length > 0) {
                // Fallback to raw stored location if no resolved city is present
                cur_city = prefs.user_location;
            }
            if (cur_city.length > 0) {
                // Use markup to emphasize the current setting
                hint.set_use_markup(true);
                hint.set_markup("Current location: <b>" + GLib.Markup.escape_text(cur_city) + "</b>");
            }
        } catch (GLib.Error e) { /* best-effort */ }

        var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
        box.append(entry);
    box.append(suggestions_scroller);
        box.append(hint);
    dialog.set_extra_child(box);
        // Track whether the dialog is still alive; if the user closes
        // the prefs dialog before an async ZIP lookup completes we
        // should avoid showing the inline detected row or a late
        // confirmation dialog (which is confusing). We set a flag on
        // destroy and check it from the async callback. Later, after
        // creating the spinner/detected widgets we also nullify those
        // references on destroy so async callbacks don't call methods
        // on freed GTK objects (which can cause SIGSEGV).
        bool dialog_alive = true;
        dialog.destroy.connect(() => {
            dialog_alive = false;
        });

    dialog.add_response("save", "Save");
    dialog.add_response("cancel", "Cancel");
    dialog.set_default_response("save");
    dialog.set_close_response("cancel");
    dialog.set_response_appearance("save", Adw.ResponseAppearance.SUGGESTED);
    
    // Disable Save button initially if no location is set yet
    // (first-time users must perform a search to enable it)
    bool has_existing_location = false;
    try {
        if ((prefs.user_location_city != null && prefs.user_location_city.length > 0) ||
            (prefs.user_location != null && prefs.user_location.length > 0)) {
            has_existing_location = true;
        }
    } catch (GLib.Error e) { }
    
    if (!has_existing_location) {
        dialog.set_response_enabled("save", false);
    }

    // Ensure the prefs dialog is presented so inline UI (spinner,
    // detected row, hints) can be shown immediately while a
    // background lookup runs.
    try { dialog.present(parent); } catch (GLib.Error e) { }

    // Spinner row shown while lookup is in progress
        var spinner_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
        try { spinner_box.set_halign(Gtk.Align.CENTER); } catch (GLib.Error e) { }
        try { spinner_box.set_valign(Gtk.Align.CENTER); } catch (GLib.Error e) { }
        var spinner = new Gtk.Spinner();
        var spinner_label = new Gtk.Label("Searching...");
        try { spinner.set_halign(Gtk.Align.CENTER); } catch (GLib.Error e) { }
        try { spinner_label.set_halign(Gtk.Align.CENTER); } catch (GLib.Error e) { }
        spinner_box.append(spinner);
        spinner_box.append(spinner_label);
        try { spinner_box.hide(); box.append(spinner_box); } catch (GLib.Error e) { }

        // When the dialog is destroyed, null out local widget references
        // so any outstanding async callbacks that capture these locals
        // will see `null` and skip calling methods on freed objects.
        dialog.destroy.connect(() => {
            try { spinner = null; } catch (GLib.Error e) { }
            try { spinner_box = null; } catch (GLib.Error e) { }
        });

        // Search button: user explicitly starts a ZIP lookup. This allows
        // repeated searches when the result isn't satisfactory.
        var search_btn = new Gtk.Button.with_label("Search");
        search_btn.set_valign(Gtk.Align.CENTER);
        try { box.append(search_btn); } catch (GLib.Error e) { }

        // Track the last detected values so the Save button can use them
        // if the user performed a ZIP lookup.
        string last_detected_zip = "";
        string last_detected_city = "";
        
        // Helper function to enable/disable Save button based on validation
        void update_save_button_state() {
            // Enable Save if:
            // 1. User has performed a successful ZIP search (last_detected_city is set), OR
            // 2. User already has a location configured
            bool should_enable = false;
            if (last_detected_city.length > 0) {
                should_enable = true;
            } else if (has_existing_location) {
                should_enable = true;
            }
            dialog.set_response_enabled("save", should_enable);
        }

        // No longer need the Use Detected button handler - Save button handles everything

        dialog.choose.begin(parent, null, (obj, res) => {
            string response = dialog.choose.end(res);
            if (response == "save") {
                string val = entry.get_text().strip();
                // Empty value clears the preference
                if (val.length == 0) {
                    try { prefs.user_location = ""; prefs.save_config(); } catch (GLib.Error e) { }
                    try { dialog.close(); } catch (GLib.Error e) { }
                    return;
                }

                // Determine what to save: if we have a detected city from a ZIP lookup,
                // use that; otherwise use the raw input as a city name.
                string location_to_save;
                string city_to_save;
                string query_for_rssfinder;
                
                if (last_detected_city.length > 0) {
                    // User performed a ZIP lookup - use the detected city
                    location_to_save = last_detected_zip;
                    city_to_save = last_detected_city;
                    query_for_rssfinder = last_detected_city;
                } else {
                    // User entered a city name directly
                    location_to_save = val;
                    city_to_save = "";
                    query_for_rssfinder = val;
                }
                
                try {
                    prefs.user_location = location_to_save;
                    prefs.user_location_city = city_to_save;
                    prefs.save_config();
                    
                    // Close the dialog immediately
                    try { dialog.close(); } catch (GLib.Error e) { }
                    
                    // After dialog closes, update UI and run rssFinder
                    Idle.add(() => {
                        try {
                            var parent_win2 = parent as NewsWindow;
                            if (parent_win2 != null) {
                                try { parent_win2.update_personalization_ui(); } catch (GLib.Error e) { }
                                try { parent_win2.update_local_news_ui(); } catch (GLib.Error e) { }
                                // Run rssFinder with the appropriate query
                                try { spawn_rssfinder_async(parent, query_for_rssfinder, true); } catch (GLib.Error e) { }
                            }
                        } catch (GLib.Error e) { }
                        return false;
                    });
                } catch (GLib.Error e) { /* best-effort only */ }
                return;
            } else {
                // For any non-save response (cancel/close), close the dialog.
                try { dialog.close(); } catch (GLib.Error e) { }
                return;
            }
        });

        // Debounced live suggestions: when the user types, wait 250ms after
        // the last keystroke before computing suggestions. This avoids
        // heavy repeated work while the user is typing quickly.
        uint suggest_timeout_id = 0;
        entry.changed.connect(() => {
            try {
                // Cancel any pending scheduled suggestion work
                if (suggest_timeout_id != 0) {
                    try { GLib.Source.remove(suggest_timeout_id); } catch (GLib.Error e) { }
                    suggest_timeout_id = 0;
                }

                // Schedule suggestion computation after 250ms of inactivity
                suggest_timeout_id = GLib.Timeout.add(250, () => {
                    suggest_timeout_id = 0;
                    try {
                        string txt = entry.get_text().strip();
                        // Only show suggestions for text input (not pure numeric ZIPs)
                        bool looks_numeric = true;
                        for (uint i = 0; i < (uint) txt.length; i++) {
                            char c = txt[i];
                            if (!(c >= '0' && c <= '9') && c != '-' && c != ' ') { looks_numeric = false; break; }
                        }

                        if (txt.length < 2 || looks_numeric) {
                            try { suggestions_scroller.hide(); } catch (GLib.Error e) { }
                            return false; // don't repeat
                        }

                        // Query ZipLookup for city suggestions
                        var sugg = ZipLookup.get_instance().suggest_cities(txt, 8);

                        // Clear existing rows
                        Gtk.Widget? child = suggestions_list.get_first_child();
                        while (child != null) {
                            Gtk.Widget? next = child.get_next_sibling();
                            suggestions_list.remove(child);
                            child = next;
                        }

                        for (int i = 0; i < sugg.size; i++) {
                            string label_text = sugg.get(i);
                            var row = new Gtk.ListBoxRow();
                            var btn = new Gtk.Button();
                            btn.set_hexpand(true);
                            btn.set_valign(Gtk.Align.CENTER);
                            var lbl = new Gtk.Label(label_text);
                            lbl.set_halign(Gtk.Align.START);
                            lbl.set_valign(Gtk.Align.CENTER);
                            lbl.set_margin_start(6);
                            btn.set_child(lbl);
                            // When clicked, set the entry text and hide suggestions
                            btn.clicked.connect(() => {
                                entry.set_text(label_text);
                                try { suggestions_scroller.hide(); } catch (GLib.Error e) { }
                            });
                            row.set_child(btn);
                            suggestions_list.append(row);
                        }

                        if (sugg.size > 0) {
                            suggestions_scroller.show();
                        } else {
                            suggestions_scroller.hide();
                        }
                    } catch (GLib.Error e) { /* best-effort */ }
                    return false; // one-shot
                });
            } catch (GLib.Error e) { /* best-effort */ }
        });

        // Search button behavior: start a ZIP lookup when the user clicks
        // the explicit Search button. This supports repeated searches.
        search_btn.clicked.connect(() => {
            try {
                string txt = entry.get_text().strip();
                bool looks_numeric_local = true;
                for (uint i = 0; i < (uint) txt.length; i++) {
                    char c = txt[i];
                    if (!(c >= '0' && c <= '9') && c != '-' && c != ' ') { looks_numeric_local = false; break; }
                }
                if (!looks_numeric_local || txt.length == 0) {
                    try { hint.set_use_markup(false); hint.set_text("Enter a ZIP code and press Search."); } catch (GLib.Error e) { }
                    return;
                }

                // Prepare UI for lookup
                try {
                    // Clear hint text - the spinner provides sufficient feedback
                    hint.set_use_markup(false);
                    hint.set_text("");
                    // Reset previous detection state
                    last_detected_zip = txt;
                    last_detected_city = "";
                    // Show spinner
                    try { spinner.start(); } catch (GLib.Error e) { }
                    try { spinner_box.show(); } catch (GLib.Error e) { }
                    // Ensure dialog is visible
                    try { dialog_alive = true; dialog.present(parent); } catch (GLib.Error e) { }
                    try {
                        ZipLookup.get_instance().lookup_async(txt, (resolved) => {
                            try {
                                if (!dialog_alive) return;

                                if (spinner != null) {
                                    try { spinner.stop(); } catch (GLib.Error e) { }
                                }
                                if (spinner_box != null) {
                                    try { spinner_box.hide(); } catch (GLib.Error e) { }
                                }

                                if (resolved.length > 0) {
                                    last_detected_city = resolved;
                                    try { 
                                        hint.set_use_markup(true); 
                                        hint.set_markup("Detected: <b>" + GLib.Markup.escape_text(resolved) + "</b> — click Save to use this location"); 
                                    } catch (GLib.Error e) { }
                                    // Enable Save button now that we have a valid detected city
                                    update_save_button_state();
                                } else {
                                    try { hint.set_use_markup(false); hint.set_text("No local mapping found for this ZIP code."); } catch (GLib.Error e) { }
                                    // Keep Save button disabled if search failed
                                    last_detected_city = "";
                                    update_save_button_state();
                                }
                            } catch (GLib.Error e) { }
                        });
                    } catch (GLib.Error e) { }
                } catch (GLib.Error e) { }
            } catch (GLib.Error e) { }
        });
    }
}