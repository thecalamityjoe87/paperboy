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

using Gtk;
using Adw;
using Soup;
using Gdk;

public class PrefsDialog : GLib.Object {
    
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
                body_text = "Currently using <b>Multiple Sources</b> as the news source.";
            } else {
                body_text = "Currently using <b>" + GLib.Markup.escape_text(current_source_name) + "</b> as the news source.";
            }
        } catch (GLib.Error e) {
            body_text = "Currently using <b>" + GLib.Markup.escape_text(current_source_name) + "</b> as the news source.";
        }

        var dialog = new Adw.AlertDialog(
            "News Source",
            body_text
        );
        dialog.set_body_use_markup(true);
    dialog.add_response("browse", "Set Source Options");
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
            "Select News Source",
            "Choose a news source to fetch articles from:"
        );
        
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

        // Helper: async load favicon into provided Gtk.Image
        void load_favicon(Gtk.Image image, string url) {
            new Thread<void*>("load-favicon", () => {
                try {
                    var session = new Soup.Session();
                    var msg = new Soup.Message("GET", url);
                    msg.request_headers.append("User-Agent", "news-vala-gnome/0.1");
                    // Request higher quality favicon formats when possible
                    msg.request_headers.append("Accept", "image/png,image/x-icon,image/svg+xml,image/*;q=0.8");
                    session.send_message(msg);
                    if (msg.status_code == 200 && msg.response_body.length > 0) {
                        Idle.add(() => {
                            try {
                                var loader = new Gdk.PixbufLoader();
                                uint8[] data = new uint8[msg.response_body.length];
                                Memory.copy(data, msg.response_body.data, (size_t) msg.response_body.length);
                                loader.write(data);
                                loader.close();
                                var pixbuf = loader.get_pixbuf();
                                if (pixbuf != null) {
                                    // Scale to 24x24 with high quality interpolation
                                    var scaled = pixbuf.scale_simple(24, 24, Gdk.InterpType.HYPER);
                                    if (scaled != null) {
                                        var texture = Gdk.Texture.for_pixbuf(scaled);
                                        image.set_from_paintable(texture);
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
        guardian_row.set_subtitle("World news with multiple categories");
        var guardian_icon = new Gtk.Image.from_icon_name("globe-symbolic");
        guardian_row.add_prefix(guardian_icon);
        load_favicon(guardian_icon, "https://www.theguardian.com/favicon.ico");
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
        var reddit_icon = new Gtk.Image.from_icon_name("internet-chat-symbolic");
        reddit_row.add_prefix(reddit_icon);
        load_favicon(reddit_icon, "https://www.reddit.com/favicon.ico");
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
        bbc_row.set_subtitle("Global news and categories");
        var bbc_icon = new Gtk.Image.from_icon_name("globe-symbolic");
        bbc_row.add_prefix(bbc_icon);
        load_favicon(bbc_icon, "https://www.bbc.co.uk/favicon.ico");
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
        var nyt_icon = new Gtk.Image.from_icon_name("emblem-documents-symbolic");
        nyt_row.add_prefix(nyt_icon);
        load_favicon(nyt_icon, "https://www.nytimes.com/favicon.ico");
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
        var bb_icon = new Gtk.Image.from_icon_name("emblem-money-symbolic");
        bb_row.add_prefix(bb_icon);
        load_favicon(bb_icon, "https://www.bloomberg.com/favicon.ico");
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
        wsj_row.set_subtitle("Business and financial news (site search)");
        var wsj_icon = new Gtk.Image.from_icon_name("emblem-documents-symbolic");
        wsj_row.add_prefix(wsj_icon);
        load_favicon(wsj_icon, "https://www.wsj.com/favicon.ico");
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
        reuters_row.set_subtitle("International news wire service");
        var reuters_icon = new Gtk.Image.from_icon_name("globe-symbolic");
        reuters_row.add_prefix(reuters_icon);
        load_favicon(reuters_icon, "https://www.reuters.com/favicon.ico");
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
        npr_row.set_subtitle("National Public Radio news");
        var npr_icon = new Gtk.Image.from_icon_name("audio-card-symbolic");
        npr_row.add_prefix(npr_icon);
        load_favicon(npr_icon, "https://www.npr.org/favicon.ico");
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
        fox_row.set_subtitle("Conservative news and commentary");
        var fox_icon = new Gtk.Image.from_icon_name("emblem-documents-symbolic");
        fox_row.add_prefix(fox_icon);
        load_favicon(fox_icon, "https://www.foxnews.com/favicon.ico");
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

    // Build the main container that shows the source list and the
    // personalized toggle; we'll place that inside a Gtk.Stack so we
    // can slide in a categories pane on demand.
    var main_container = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
    main_container.set_margin_top(6);
    main_container.set_margin_bottom(6);

    // Append the selection label (declared above) and the list box
    main_container.append(selection_label);
    main_container.append(list_box);
    // Initialize selection label text according to current prefs
    update_selection_label();

    var sep = new Gtk.Separator(Gtk.Orientation.HORIZONTAL);
    sep.set_margin_top(6);
    sep.set_margin_bottom(6);
    main_container.append(sep);

    // Personalized feed toggle (separate from the source list)
        var personalized_row = new Adw.ActionRow();
        personalized_row.set_title("Enable Personalized Feed");
        personalized_row.set_subtitle("Enable a personalized feed based on your reading habits");
        var personalized_switch = new Gtk.Switch();
        personalized_switch.set_active(prefs.personalized_feed_enabled);
    // Ensure the switch uses normal sizing inside the ActionRow suffix
    personalized_switch.set_halign(Gtk.Align.END);
    personalized_switch.set_valign(Gtk.Align.CENTER);
    personalized_switch.set_hexpand(false);
    personalized_switch.set_vexpand(false);
    personalized_switch.set_margin_top(0);
    personalized_switch.set_margin_bottom(0);
        // When toggled, we'll persist the preference and update the
        // settings button and main window UI below (handler attached
        // after the settings button is created).
        // Build a compact suffix containing the switch and a small
        // settings button so the two appear together on the right.
        var suffix_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        suffix_box.set_valign(Gtk.Align.CENTER);

        // Ensure switch uses normal sizing
        personalized_switch.set_halign(Gtk.Align.END);
        personalized_switch.set_valign(Gtk.Align.CENTER);
        personalized_switch.set_hexpand(false);
        personalized_switch.set_vexpand(false);
        personalized_switch.set_margin_top(0);
        personalized_switch.set_margin_bottom(0);

        // Create the settings button early so the switch's handler can
        // enable/disable it when the preference changes.
        var settings_btn = new Gtk.Button();
        settings_btn.set_valign(Gtk.Align.CENTER);
        settings_btn.set_halign(Gtk.Align.END);
        settings_btn.set_hexpand(false);
        settings_btn.set_vexpand(false);
        settings_btn.set_has_frame(false);
        var settings_icon = new Gtk.Image.from_icon_name("settings-symbolic");
        settings_icon.set_pixel_size(16);
        settings_btn.set_child(settings_icon);
        settings_btn.set_tooltip_text("Personalized feed settings");
        // Initially sensitive only if the personalized feed is enabled
        settings_btn.set_sensitive(prefs.personalized_feed_enabled);

        suffix_box.append(personalized_switch);
        suffix_box.append(settings_btn);

        // When toggled, persist the preference immediately and update
        // the sensitivity of the settings button so it's only clickable
        // when personalization is enabled. Don't refresh the main view
        // immediately; instead mark the change and apply it when the
        // dialog closes so the user can make multiple edits before a
        // single refresh occurs.
        personalized_switch.state_set.connect((sw, state) => {
            prefs.personalized_feed_enabled = state;
            prefs.save_config();
            settings_btn.set_sensitive(state);
            try {
                if (win != null) personalization_toggled = true;
            } catch (GLib.Error e) { /* ignore if parent doesn't implement it */ }
            return false; // allow the state change to proceed
        });

        personalized_row.add_suffix(suffix_box);
        main_container.append(personalized_row);

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
                case "all": filename = "all-mono.svg"; break;
                case "myfeed": filename = "myfeed-mono.svg"; break;
                case "general": filename = "world-mono.svg"; break;
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
                        img.set_pixel_size(16);
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
                string[] base_ids = { "general", "us", "technology", "science", "sports", "health", "entertainment", "politics", "lifestyle" };
                string[] base_titles = { "World News", "US News", "Technology", "Science", "Sports", "Health", "Entertainment", "Politics", "Lifestyle" };
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

                // If parent is NewsWindow, refresh its UI to reflect the change
                try {
                    var parent_win = parent as NewsWindow;
                    if (parent_win != null) {
                        // Only refresh once: if sources changed while dialog
                        // was open or we auto-enabled Guardian, or we changed
                        // the persisted news_source, trigger a single fetch.
                        if (sources_changed || did_auto_enable || did_change_news_source || categories_changed || personalization_toggled) {
                            // If personalization or categories changed, update overlay
                            // state first so the UI reflects the new settings quickly,
                            // then re-run the fetch once to refresh articles.
                            try { parent_win.update_personalization_ui(); } catch (GLib.Error e) { }
                            parent_win.fetch_news();
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
    about.set_version("0.1");
    about.set_developer_name("thecalamityjoe87 (Isaac Joseph)");
    about.set_comments("A beautiful news viewer for GNOME");
    about.set_website("https://github.com/thecalamityjoe87/paperboy");
    about.set_license_type(Gtk.License.GPL_3_0);
    about.set_copyright("© 2025 thecalamityjoe87");
    about.present(parent);
    }
}