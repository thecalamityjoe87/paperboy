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

public class PrefsDialog : GLib.Object {

    public static void show_source_dialog(Gtk.Window parent) {
        // If an article preview is currently open in the main window, close it
        var maybe_win = parent as NewsWindow;
        if (maybe_win != null) maybe_win.close_article_preview();

        // Go directly to preferences dialog
        show_preferences_dialog(parent);
    }

    // Helper class to hold a mutable boolean for category changes
    private class CategoryChangedHolder : GLib.Object {
        public bool changed = false;
    }

    // Show personalized categories selection dialog
    private static void show_personalized_categories_dialog(Gtk.Window parent, NewsPreferences prefs, CategoryChangedHolder holder) {
        var categories_dialog = new Adw.AlertDialog(
            "Personalized Feed Categories",
            "Select which categories to include in your personalized feed"
        );
        categories_dialog.set_prefer_wide_layout(true);

        // Helper to find data file for bundled icons
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

        // Helper to create category icon
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
                    bool dark = false;
                    var sm = Adw.StyleManager.get_default();
                    if (sm != null) dark = sm.dark;
                    string use_path = icon_path;
                    if (dark) {
                        string alt_name;
                        if (filename.has_suffix(".svg")) {
                            if (filename.length > 4)
                                alt_name = filename.substring(0, filename.length - 4) + "-white.svg";
                            else
                                alt_name = filename + "-white.svg";
                        } else
                            alt_name = filename + "-white.svg";

                        string? white_candidate = find_data_file_local(GLib.Path.build_filename("icons", "symbolic", alt_name));
                        if (white_candidate == null) white_candidate = find_data_file_local(GLib.Path.build_filename("icons", alt_name));
                        if (white_candidate != null) use_path = white_candidate;
                    }
                    var img = new Gtk.Image.from_file(use_path);
                    img.set_pixel_size(24);
                    return img;
                }
            }
            var img2 = new Gtk.Image.from_icon_name("tag-symbolic");
            img2.set_pixel_size(16);
            return img2;
        }

        // Create scrolled list for categories
        var scroller = new Gtk.ScrolledWindow();
        scroller.set_vexpand(true);
        scroller.set_min_content_height(500);
        scroller.set_max_content_height(700);
        scroller.set_hexpand(true);
        scroller.set_min_content_width(300);
        var cats_list = new Gtk.ListBox();
        cats_list.set_selection_mode(Gtk.SelectionMode.NONE);
        cats_list.add_css_class("boxed-list");

        // Determine which categories to show
        bool is_bloomberg_selected;
        if (prefs.preferred_sources != null && prefs.preferred_sources.size > 0) {
            is_bloomberg_selected = prefs.preferred_source_enabled("bloomberg");
        } else {
            is_bloomberg_selected = (prefs.news_source == NewsSource.BLOOMBERG);
        }

        var cat_ids_list = new Gee.ArrayList<string>();
        var cat_titles_list = new Gee.ArrayList<string>();

        bool bloomberg_only = false;
        if (prefs.preferred_sources != null && prefs.preferred_sources.size > 0) {
            bloomberg_only = (prefs.preferred_sources.size == 1 && prefs.preferred_source_enabled("bloomberg"));
        } else {
            bloomberg_only = (prefs.news_source == NewsSource.BLOOMBERG);
        }

        string[] bb_ids = { "markets", "industries", "economics", "wealth", "green", "technology", "politics" };
        string[] bb_titles = { "Markets", "Industries", "Economics", "Wealth", "Green", "Technology", "Politics" };

        if (bloomberg_only) {
            for (int j = 0; j < bb_ids.length; j++) {
                cat_ids_list.add(bb_ids[j]);
                cat_titles_list.add(bb_titles[j]);
            }
        } else {
            string[] base_ids = { "general", "us", "technology", "business", "science", "sports", "health", "entertainment", "politics", "lifestyle" };
            string[] base_titles = { "World News", "US News", "Technology", "Business", "Science", "Sports", "Health", "Entertainment", "Politics", "Lifestyle" };
            for (int i = 0; i < base_ids.length; i++) {
                cat_ids_list.add(base_ids[i]);
                cat_titles_list.add(base_titles[i]);
            }

            if (is_bloomberg_selected) {
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

        // Create category rows
        for (int i = 0; i < cat_ids_list.size; i++) {
            string cat_id = cat_ids_list.get(i);
            string cat_title = cat_titles_list.get(i);
            var crow = new Adw.ActionRow();
            crow.set_title(cat_title);
            var prefix = create_category_icon_local(cat_id);
            if (prefix != null) crow.add_prefix(prefix);

            var cswitch = new Gtk.Switch();
            cswitch.set_active(prefs.personalized_category_enabled(cat_id));
            cswitch.set_valign(Gtk.Align.CENTER);

            string _cid = cat_id;
            cswitch.notify["active"].connect(() => {
                prefs.set_personalized_category_enabled(_cid, cswitch.get_active());
                prefs.save_config();
                holder.changed = true;

                // Refresh My Feed metadata to reflect new personalized categories
                try {
                    var win = parent as NewsWindow;
                    if (win != null) {
                        UnreadFetchService.refresh_myfeed_metadata(win);
                    }
                } catch (GLib.Error e) { }
            });

            crow.add_suffix(cswitch);
            crow.set_activatable(true);
            crow.activated.connect(() => {
                cswitch.set_active(!cswitch.get_active());
            });
            cats_list.append(crow);
        }

        scroller.set_child(cats_list);
        categories_dialog.set_extra_child(scroller);

        categories_dialog.add_response("close", "Close");
        categories_dialog.set_default_response("close");
        categories_dialog.set_close_response("close");
        categories_dialog.present(parent);
    }

    // Libadwaita preferences dialog using Adw.PreferencesDialog with tabs
    public static void show_preferences_dialog(Gtk.Window parent) {
        var win = (NewsWindow) parent;
        var prefs = NewsPreferences.get_instance();

        // Create PreferencesDialog
        var dialog = new Adw.PreferencesDialog();
        dialog.set_title("Preferences");

        // Set a more compact width for the dialog
        dialog.set_content_width(425);

        // Track if sources changed for refresh on close
        bool sources_changed = false;

        // ========== SOURCES PAGE ==========
        var sources_page = new Adw.PreferencesPage();
        sources_page.set_title("Sources");
        sources_page.set_icon_name("application-rss+xml-symbolic");
        var header_group = new Adw.PreferencesGroup();

        // Built-in News Sources Group
        var builtin_sources_group = new Adw.PreferencesGroup();
        builtin_sources_group.set_title("Built-in News Sources");

        // Helper to load favicon into provided Gtk.Picture with circular clipping
        void load_favicon_circular(Gtk.Picture picture, string url) {
            new Thread<void*>("load-favicon", () => {
                var client = Paperboy.HttpClientUtils.get_default();
                var http_response = client.fetch_sync(url, null);

                if (http_response != null && http_response.is_success() && http_response.body != null && http_response.body.get_size() > 0) {
                    unowned uint8[] body_data = http_response.body.get_data();
                    uint8[] data = new uint8[body_data.length];
                    Memory.copy(data, body_data, body_data.length);

                    Idle.add(() => {
                        var loader = new Gdk.PixbufLoader();
                        loader.write(data);
                        loader.close();
                        var pixbuf = loader.get_pixbuf();
                        if (pixbuf != null) {
                            int img_size = 24;
                            string k = "pixbuf::url:%s::%dx%d".printf(url, img_size, img_size);
                            var scaled = ImageCache.get_global().get_or_scale_pixbuf(k, pixbuf, img_size, img_size);
                            if (scaled != null) {
                                var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, 24, 24);
                                var cr = new Cairo.Context(surface);
                                cr.arc(12, 12, 12, 0, 2 * Math.PI);
                                cr.clip();
                                int ox = (24 - img_size) / 2;
                                int oy = (24 - img_size) / 2;
                                Gdk.cairo_set_source_pixbuf(cr, scaled, ox, oy);
                                cr.paint();
                                string surf_key = "pixbuf::circular:prefs:%s:24x24".printf(url);
                                var circular_pb = ImageCache.get_global().get_or_from_surface(surf_key, surface, 0, 0, 24, 24);
                                if (circular_pb != null) {
                                    var texture = Gdk.Texture.for_pixbuf(circular_pb);
                                    picture.set_paintable(texture);
                                    picture.set_size_request(26, 26);
                                }
                            }
                        }
                        return false;
                    });
                }
                return null;
            });
        }

        // Helper to elide long strings
        string elide_string(string s, int max) {
            if (s == null) return s;
            if (max < 1) return s;
            if (s.length <= max) return s;
            return s.substring(0, max - 1) + "…";
        }

        // Helper to create circular placeholder picture with proper sizing
        Gtk.Widget create_favicon_picture(string placeholder_key, string? favicon_url) {
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, 24, 24);
            var cr = new Cairo.Context(surface);
            cr.arc(12, 12, 12, 0, 2 * Math.PI);
            cr.set_source_rgba(0.5, 0.5, 0.5, 0.3);
            cr.fill();
            var pb = ImageCache.get_global().get_or_from_surface(placeholder_key, surface, 0, 0, 24, 24);

            var picture = new Gtk.Picture();
            if (pb != null) picture.set_paintable(Gdk.Texture.for_pixbuf(pb));
            picture.set_size_request(24, 24);
            picture.set_can_shrink(false);

            // Wrap in a box to control sizing and prevent expansion
            var wrapper = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            wrapper.set_size_request(24, 24);
            wrapper.set_valign(Gtk.Align.CENTER);
            wrapper.set_halign(Gtk.Align.CENTER);
            wrapper.set_hexpand(false);
            wrapper.set_vexpand(false);
            wrapper.append(picture);

            if (favicon_url != null && favicon_url.length > 0) {
                load_favicon_circular(picture, favicon_url);
            }

            return wrapper;
        }

        // Helper to create source action row with icon
        Adw.ActionRow create_source_row(string title, string subtitle, string source_id, string? favicon_url) {
            var row = new Adw.ActionRow();
            row.set_title(title);
            row.set_subtitle(elide_string(subtitle, 36));
            row.set_tooltip_text(subtitle);
            //row.set_subtitle(subtitle);

            // Add favicon as prefix
            var picture = create_favicon_picture("placeholder:%s".printf(source_id), favicon_url);
            row.add_prefix(picture);

            var sw = new Gtk.Switch();
            sw.set_active(prefs.preferred_source_enabled(source_id));
            sw.set_valign(Gtk.Align.CENTER);
            sw.notify["active"].connect(() => {
                prefs.set_preferred_source_enabled(source_id, sw.get_active());
                prefs.save_config();
                sources_changed = true;

                // Update My Feed unread badge immediately when source is toggled
                if (win != null && win.sidebar_manager != null) {
                    win.sidebar_manager.update_badge_for_category("myfeed");
                }
            });
            row.add_suffix(sw);
            row.set_activatable(true);
            row.activated.connect(() => { sw.set_active(!sw.get_active()); });
            return row;
        }

        // Add all built-in sources with favicons
        builtin_sources_group.add(create_source_row("The Guardian", "Independent global news and analysis", "guardian", "https://www.theguardian.com/favicon.ico"));
        builtin_sources_group.add(create_source_row("Reddit", "Community-driven news and trending topics", "reddit", "https://www.reddit.com/favicon.ico"));
        builtin_sources_group.add(create_source_row("BBC News", "Comprehensive international and UK reporting", "bbc", "https://www.bbc.co.uk/favicon.ico"));
        builtin_sources_group.add(create_source_row("New York Times", "In-depth journalism across major categories", "nytimes", "https://www.nytimes.com/favicon.ico"));
        builtin_sources_group.add(create_source_row("Bloomberg", "Market, business, and finance coverage", "bloomberg", "https://www.bloomberg.com/favicon.ico"));
        builtin_sources_group.add(create_source_row("Wall Street Journal", "Business, economic, and political reporting", "wsj", "https://www.wsj.com/favicon.ico"));
        builtin_sources_group.add(create_source_row("Reuters", "Real-time global wire reporting", "reuters", "https://www.reuters.com/favicon.ico"));
        builtin_sources_group.add(create_source_row("NPR", "Public radio news and feature storytelling", "npr", "https://www.npr.org/favicon.ico"));
        builtin_sources_group.add(create_source_row("Fox News", "U.S. politics, headlines, and commentary", "fox", "https://www.foxnews.com/favicon.ico"));


        sources_page.add(builtin_sources_group);

        // Followed RSS Sources Group
        var rss_sources_group = new Adw.PreferencesGroup();
        rss_sources_group.set_title("Followed Sources");
        
        // Helper to load icon from file with circular clipping
        void try_load_icon_circular(string path, Gtk.Picture picture) {
            if (GLib.FileUtils.test(path, GLib.FileTest.EXISTS)) {
                int img_size = 24;
                var pixbuf = new Gdk.Pixbuf.from_file_at_scale(path, img_size, img_size, true);
                if (pixbuf != null) {
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
                        picture.set_size_request(24, 24);
                        picture.set_can_shrink(false);
                    }
                }
            }
        }

        // Get and display all RSS sources
        var rss_store = Paperboy.RssSourceStore.get_instance();
        var all_sources = rss_store.get_all_sources();

        foreach (var rss_source in all_sources) {
                var rss_row = new Adw.ActionRow();

                // Try to get display name from SourceMetadata
                string display_name = rss_source.name;
                string? metadata_display_name = SourceMetadata.get_display_name_for_source(rss_source.name);
                if (metadata_display_name != null && metadata_display_name.length > 0) {
                    display_name = metadata_display_name;
                }

                // Escape any user-controlled text before assigning to ActionRow
                // Some underlying label implementations parse Pango/markup, so
                // ensure ampersands and other entities are escaped to avoid
                // runtime markup parse errors (e.g. "Food & Wine").
                rss_row.set_title(GLib.Markup.escape_text(display_name ?? ""));
                rss_row.set_subtitle(GLib.Markup.escape_text(elide_string(rss_source.url ?? "", 28)));
                rss_row.set_tooltip_text(rss_source.url);

                // Add favicon/logo as prefix
                var custom_wrapper = create_favicon_picture("placeholder:rss:%s".printf(rss_source.url), null);

                // Extract the picture from the wrapper for icon loading
                Gtk.Picture? custom_picture = null;
                if (custom_wrapper is Gtk.Box) {
                    var box = (Gtk.Box) custom_wrapper;
                    var child = box.get_first_child();
                    if (child is Gtk.Picture) {
                        custom_picture = (Gtk.Picture) child;
                    }
                }

                bool icon_loaded = false;

                // Priority 1: Try to load from saved file
                if (custom_picture != null) {
                    string? icon_filename = SourceMetadata.get_saved_filename_for_source(rss_source.name);
                    if (icon_filename != null && icon_filename.length > 0) {
                        var data_dir = GLib.Environment.get_user_data_dir();
                        var icon_path = GLib.Path.build_filename(data_dir, "paperboy", "source_logos", icon_filename);
                        if (GLib.FileUtils.test(icon_path, GLib.FileTest.EXISTS)) {
                            try_load_icon_circular(icon_path, custom_picture);
                            icon_loaded = true;
                        }
                    }

                    // Priority 2: Try API logo URL from SourceMetadata
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
                    }
                }

                rss_row.add_prefix(custom_wrapper);

                // Delete button
                var delete_btn = new Gtk.Button();
                delete_btn.set_icon_name("user-trash-symbolic");
                delete_btn.set_valign(Gtk.Align.CENTER);
                delete_btn.set_has_frame(false);
                delete_btn.set_tooltip_text("Remove this source");
                delete_btn.add_css_class("destructive-action");
                delete_btn.clicked.connect(() => {
                    // Confirm before removing the followed source
                    var confirm = new Adw.AlertDialog(
                        "Remove this source?",
                        "Are you sure you want to remove '" + (rss_source.name != null ? rss_source.name : rss_source.url) + "' and all of its articles?"
                    );
                    confirm.add_response("cancel", "Cancel");
                    confirm.add_response("remove", "Remove");
                    confirm.set_response_appearance("remove", Adw.ResponseAppearance.DESTRUCTIVE);
                    confirm.set_default_response("cancel");
                    confirm.set_close_response("cancel");

                    confirm.response.connect((response_id) => {
                        if (response_id == "remove") {
                            // Perform removal
                            bool is_currently_viewing = false;
                            if (win != null && win.prefs.category != null && win.prefs.category.has_prefix("rssfeed:")) {
                                if (win.prefs.category.length > 8) {
                                    string current_url = win.prefs.category.substring(8);
                                    if (current_url == rss_source.url) {
                                        is_currently_viewing = true;
                                    }
                                }
                            }

                            rss_store.remove_source(rss_source.url);

                            // Remove from preferences if enabled
                            if (prefs.preferred_source_enabled("custom:" + rss_source.url)) {
                                prefs.set_preferred_source_enabled("custom:" + rss_source.url, false);
                                prefs.save_config();
                            }

                            rss_sources_group.remove(rss_row);
                            sources_changed = true;

                            // If we were viewing this source, navigate to Front Page
                            if (is_currently_viewing && win != null) {
                                GLib.Idle.add(() => {
                                    if (win != null) {
                                        win.prefs.category = "frontpage";
                                        win.prefs.save_config();
                                        win.fetch_news();
                                    }
                                    return false;
                                });
                            }
                        }
                    });

                    confirm.present(dialog);
                });

                // Add switch to enable/disable this custom source
                var custom_switch = new Gtk.Switch();
                custom_switch.set_active(prefs.preferred_source_enabled("custom:" + rss_source.url));
                custom_switch.set_valign(Gtk.Align.CENTER);
                custom_switch.notify["active"].connect(() => {
                    prefs.set_preferred_source_enabled("custom:" + rss_source.url, custom_switch.get_active());
                    prefs.save_config();
                    sources_changed = true;

                    // Update My Feed unread badge immediately when source is toggled
                    if (win != null && win.sidebar_manager != null) {
                        win.sidebar_manager.update_badge_for_category("myfeed");
                    }
                });

                rss_row.add_suffix(delete_btn);
                rss_row.add_suffix(custom_switch);
                rss_row.set_activatable(true);
                rss_row.activated.connect(() => {
                    custom_switch.set_active(!custom_switch.get_active());
                });

                rss_sources_group.add(rss_row);
            }

        sources_page.add(rss_sources_group);

        dialog.add(sources_page);

        // Note: Sources changes will be reflected when user switches views

        // ========== APP PAGE ==========
        var app_page = new Adw.PreferencesPage();
        app_page.set_title("App");
        app_page.set_icon_name("preferences-system-symbolic");

        var app_group = new Adw.PreferencesGroup();
        app_group.set_title("Personalization");

        // Personalized feed toggle (using ActionRow to add settings button)
        var personalized_row = new Adw.ActionRow();
        personalized_row.set_title("Enable personalized feed");
        personalized_row.set_subtitle("Enable a personalized feed based on your reading habits");

        var personalized_switch = new Gtk.Switch();
        personalized_switch.set_active(prefs.personalized_feed_enabled);
        personalized_switch.set_valign(Gtk.Align.CENTER);
        personalized_switch.notify["active"].connect(() => {
            prefs.personalized_feed_enabled = personalized_switch.get_active();
            prefs.save_config();
            // Refresh My Feed badge to show/hide it based on the enabled state
            if (win != null && win.sidebar_manager != null) {
                win.sidebar_manager.update_badge_for_category("myfeed");
            }
            // If user is currently viewing My Feed when they disable it, refresh the view
            // to show the "disabled" message
            if (win != null && win.prefs.category == "myfeed") {
                win.fetch_news();
            }
        });

        // Track if personalized categories changed
        var categories_holder = new CategoryChangedHolder();

        // Settings button for personalized categories
        var pers_settings_btn = new Gtk.Button();
        pers_settings_btn.set_icon_name("settings-symbolic");
        pers_settings_btn.set_valign(Gtk.Align.CENTER);
        pers_settings_btn.set_has_frame(false);
        pers_settings_btn.set_tooltip_text("Personalized feed settings");
        pers_settings_btn.clicked.connect(() => {
            show_personalized_categories_dialog(parent, prefs, categories_holder);
        });

        personalized_row.add_suffix(pers_settings_btn);
        personalized_row.add_suffix(personalized_switch);
        personalized_row.set_activatable(true);
        personalized_row.activated.connect(() => {
            personalized_switch.set_active(!personalized_switch.get_active());
        });
        app_group.add(personalized_row);

        // Custom sources only toggle
        var custom_only_row = new Adw.SwitchRow();
        custom_only_row.set_title("Custom sources only in My Feed");
        custom_only_row.set_subtitle("Show only followed RSS sources in My Feed, hide built-in sources");
        custom_only_row.set_active(prefs.myfeed_custom_only);
        custom_only_row.notify["active"].connect(() => {
            prefs.myfeed_custom_only = custom_only_row.get_active();
            prefs.save_config();
        });
        app_group.add(custom_only_row);

        // Unread badges toggle (using ActionRow to add settings button)
        var unread_badges_row = new Adw.ActionRow();
        unread_badges_row.set_title("Show unread count badges");
        unread_badges_row.set_subtitle("Display unread article counts in the sidebar");

        var unread_badges_switch = new Gtk.Switch();
        unread_badges_switch.set_active(prefs.unread_badges_enabled);
        unread_badges_switch.set_valign(Gtk.Align.CENTER);
        unread_badges_switch.notify["active"].connect(() => {
            prefs.unread_badges_enabled = unread_badges_switch.get_active();
            prefs.save_config();
            if (win != null && win.sidebar_manager != null) {
                win.sidebar_manager.refresh_all_badge_counts();
            }
        });

        // Settings button for badge visibility options
        var badge_settings_btn = new Gtk.Button();
        badge_settings_btn.set_icon_name("settings-symbolic");
        badge_settings_btn.set_valign(Gtk.Align.CENTER);
        badge_settings_btn.set_has_frame(false);
        badge_settings_btn.set_tooltip_text("Badge visibility settings");
        badge_settings_btn.clicked.connect(() => {
            var popover = new Gtk.Popover();
            popover.set_parent(badge_settings_btn);

            var popover_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
            popover_box.set_margin_start(12);
            popover_box.set_margin_end(12);
            popover_box.set_margin_top(12);
            popover_box.set_margin_bottom(12);

            var special_check = new Gtk.CheckButton.with_label("Show on special categories");
            special_check.set_active(prefs.unread_badges_special_categories);
            special_check.toggled.connect(() => {
                prefs.unread_badges_special_categories = special_check.get_active();
                prefs.save_config();
                if (win != null && win.sidebar_manager != null) {
                    win.sidebar_manager.refresh_all_badge_counts();
                }
            });

            var sources_check = new Gtk.CheckButton.with_label("Show on followed sources");
            sources_check.set_active(prefs.unread_badges_sources);
            sources_check.toggled.connect(() => {
                prefs.unread_badges_sources = sources_check.get_active();
                prefs.save_config();
                if (win != null && win.sidebar_manager != null) {
                    win.sidebar_manager.refresh_all_badge_counts();
                }
            });

            var categories_check = new Gtk.CheckButton.with_label("Show on popular categories");
            categories_check.set_active(prefs.unread_badges_categories);
            categories_check.toggled.connect(() => {
                prefs.unread_badges_categories = categories_check.get_active();
                prefs.save_config();
                if (win != null && win.sidebar_manager != null) {
                    win.sidebar_manager.refresh_all_badge_counts();
                }
            });

            popover_box.append(special_check);
            popover_box.append(sources_check);
            popover_box.append(categories_check);
            popover.set_child(popover_box);
            popover.popup();
        });

        unread_badges_row.add_suffix(badge_settings_btn);
        unread_badges_row.add_suffix(unread_badges_switch);
        unread_badges_row.set_activatable(true);
        unread_badges_row.activated.connect(() => {
            unread_badges_switch.set_active(!unread_badges_switch.get_active());
        });
        app_group.add(unread_badges_row);

        app_page.add(app_group);

        // ========== UPDATE INTERVAL GROUP ==========
        var update_interval_group = new Adw.PreferencesGroup();
        update_interval_group.set_title("Update Interval");
        update_interval_group.set_description("Short update intervals can trigger rate limits or cause requests to be blocked.");
        update_interval_group.set_tooltip_text("Updating feeds too often may look like automated traffic. Sites could temporarily block requests or refuse articles if too many are made in a short time. Choose a longer interval to avoid this.");

        // Manual row
        var manual_row = new Adw.ActionRow();
        manual_row.set_title("Manual");
        manual_row.set_subtitle("No automatic synchronization");

        var manual_check = new Gtk.CheckButton();
        manual_check.set_valign(Gtk.Align.CENTER);
        manual_row.add_prefix(manual_check);
        manual_row.set_activatable_widget(manual_check);

        // Sync Every row with dropdown
        var sync_row = new Adw.ActionRow();
        sync_row.set_title("Sync Every");

        var sync_check = new Gtk.CheckButton();
        sync_check.set_group(manual_check);
        sync_check.set_valign(Gtk.Align.CENTER);
        sync_row.add_prefix(sync_check);

        var interval_dropdown = new Gtk.DropDown.from_strings(new string[] {
            "15 Minutes", "30 Minutes", "1 Hour", "2 Hours", "4 Hours"
        });
        interval_dropdown.set_valign(Gtk.Align.CENTER);

        // Set initial state based on prefs
        string current_interval = prefs.update_interval;
        if (current_interval == "manual") {
            manual_check.set_active(true);
            interval_dropdown.set_sensitive(false);
        } else {
            sync_check.set_active(true);
            switch (current_interval) {
                case "15min": interval_dropdown.set_selected(0); break;
                case "30min": interval_dropdown.set_selected(1); break;
                case "1hour": interval_dropdown.set_selected(2); break;
                case "2hours": interval_dropdown.set_selected(3); break;
                case "4hours": interval_dropdown.set_selected(4); break;
                default: interval_dropdown.set_selected(1); break;
            }
        }

        // Handle radio button changes
        manual_check.toggled.connect(() => {
            if (manual_check.get_active()) {
                interval_dropdown.set_sensitive(false);
                prefs.update_interval = "manual";
                prefs.save_config();
            }
        });

        sync_check.toggled.connect(() => {
            if (sync_check.get_active()) {
                interval_dropdown.set_sensitive(true);
                uint selected = interval_dropdown.get_selected();
                string new_interval = "";
                switch (selected) {
                    case 0: new_interval = "15min"; break;
                    case 1: new_interval = "30min"; break;
                    case 2: new_interval = "1hour"; break;
                    case 3: new_interval = "2hours"; break;
                    case 4: new_interval = "4hours"; break;
                }
                prefs.update_interval = new_interval;
                prefs.save_config();
            }
        });

        // Handle dropdown changes
        interval_dropdown.notify["selected"].connect(() => {
            if (sync_check.get_active()) {
                uint selected = interval_dropdown.get_selected();
                string new_interval = "";
                switch (selected) {
                    case 0: new_interval = "15min"; break;
                    case 1: new_interval = "30min"; break;
                    case 2: new_interval = "1hour"; break;
                    case 3: new_interval = "2hours"; break;
                    case 4: new_interval = "4hours"; break;
                }
                prefs.update_interval = new_interval;
                prefs.save_config();
            }
        });

        sync_row.add_suffix(interval_dropdown);
        sync_row.set_activatable_widget(sync_check);

        update_interval_group.add(manual_row);
        update_interval_group.add(sync_row);
        app_page.add(update_interval_group);

        // ========== DATA GROUP ==========
        var data_group = new Adw.PreferencesGroup();
        data_group.set_title("Data");

        // Article Content Cache row (MetaCache)
        var cache_row = new Adw.ActionRow();
        cache_row.set_title("Article content cache");

        // Get formatted cache information from the metacache service
        var meta_cache = MetaCache.get_instance();

        // Get metacache size
        cache_row.set_subtitle(meta_cache.get_metacache_info());

        var clear_cache_btn = new Gtk.Button.with_label("Clear");
        clear_cache_btn.set_valign(Gtk.Align.CENTER);
        clear_cache_btn.add_css_class("destructive-action");
        clear_cache_btn.clicked.connect(() => {
            try {
                // Show confirmation dialog
                var confirm_dialog = new Adw.AlertDialog(
                    "Clear article content cache?",
                    "This will delete cached article content and images. Previously read articles will need to be re-downloaded."
                );
                confirm_dialog.add_response("cancel", "Cancel");
                confirm_dialog.add_response("clear", "Clear Cache");
                confirm_dialog.set_response_appearance("clear", Adw.ResponseAppearance.DESTRUCTIVE);
                confirm_dialog.set_default_response("cancel");
                confirm_dialog.set_close_response("cancel");

                confirm_dialog.response.connect((response_id) => {
                    if (response_id == "clear") {
                        try {
                            // Get window reference for MetaCache
                            var parent_win = parent as NewsWindow;
                            if (parent_win != null && parent_win.meta_cache != null) {
                                parent_win.meta_cache.clear();
                                cache_row.set_subtitle("0 bytes");

                                // Show toast notification
                                if (parent_win.toast_manager != null) {
                                    parent_win.toast_manager.show_toast("Cache cleared successfully");
                                }
                            }
                        } catch (GLib.Error e) {
                            warning("Failed to clear cache: %s", e.message);
                        }
                    }
                });

                confirm_dialog.present(dialog);
            } catch (GLib.Error e) {
                warning("Failed to show confirmation dialog: %s", e.message);
            }
        });

        cache_row.add_suffix(clear_cache_btn);
        data_group.add(cache_row);

        // RSS Feed Cache row
        var rss_cache_row = new Adw.ActionRow();
        rss_cache_row.set_title("RSS feed cache");

        // Get formatted cache information from the cache service
        var rss_cache = Paperboy.RssArticleCache.get_instance();

        // Set initial cache size
        rss_cache_row.set_subtitle(rss_cache.get_cache_info_formatted());

        // Update cache size when sources are removed
        var rss_source_store = Paperboy.RssSourceStore.get_instance();
        ulong source_removed_handler = rss_source_store.source_removed.connect((source) => {
            // Refresh the cache size display when a source is removed
            rss_cache_row.set_subtitle(rss_cache.get_cache_info_formatted());
        });

        // Disconnect signal when dialog is closed
        dialog.closed.connect(() => {
            rss_source_store.disconnect(source_removed_handler);
        });

        var clear_rss_cache_btn = new Gtk.Button.with_label("Clear");
        clear_rss_cache_btn.set_valign(Gtk.Align.CENTER);
        clear_rss_cache_btn.add_css_class("destructive-action");
        clear_rss_cache_btn.clicked.connect(() => {
            try {
                // Show confirmation dialog
                var rss_confirm_dialog = new Adw.AlertDialog(
                    "Clear RSS Feed Cache?",
                    "This will delete all cached RSS feed listings. Feeds will load from the network next time."
                );
                rss_confirm_dialog.add_response("cancel", "Cancel");
                rss_confirm_dialog.add_response("clear", "Clear Cache");
                rss_confirm_dialog.set_response_appearance("clear", Adw.ResponseAppearance.DESTRUCTIVE);
                rss_confirm_dialog.set_default_response("cancel");
                rss_confirm_dialog.set_close_response("cancel");

                rss_confirm_dialog.response.connect((response_id) => {
                    if (response_id == "clear") {
                        try {
                            rss_cache.clear_all();
                            rss_cache_row.set_subtitle("0 bytes (0 articles)");

                            // Show toast notification
                            var parent_win = parent as NewsWindow;
                            if (parent_win != null && parent_win.toast_manager != null) {
                                parent_win.toast_manager.show_toast("RSS feed cache cleared");
                            }
                        } catch (GLib.Error e) {
                            warning("Failed to clear RSS cache: %s", e.message);
                        }
                    }
                });

                rss_confirm_dialog.present(dialog);
            } catch (GLib.Error e) {
                warning("Failed to show RSS cache confirmation dialog: %s", e.message);
            }
        });

        rss_cache_row.add_suffix(clear_rss_cache_btn);
        data_group.add(rss_cache_row);

        app_page.add(data_group);
        dialog.add(app_page);

        // Handle dialog close to refresh if sources or categories changed
        dialog.closed.connect(() => {
            var parent_win = parent as NewsWindow;
            if (parent_win != null && (sources_changed || categories_holder.changed)) {
                // Validate that current category is still supported
                string current_category = prefs.category;
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
                        if (NewsService.supports_category(source, current_category)) {
                            category_supported = true;
                            break;
                        }
                    }
                } else {
                    // No sources enabled, fallback to default source
                    category_supported = NewsService.supports_category(prefs.news_source, current_category);
                }

                // If category no longer supported, redirect to frontpage
                if (!category_supported) {
                    prefs.category = "frontpage";
                    prefs.save_config();
                }

                // Show confirmation dialog asking if user wants to refresh
                var confirm_dialog = new Adw.AlertDialog(
                    "Refresh Content?",
                    "Changes have been made to your news sources. Would you like to refresh the content now?"
                );
                confirm_dialog.add_response("cancel", "Not Now");
                confirm_dialog.add_response("refresh", "Refresh");
                confirm_dialog.set_default_response("refresh");
                confirm_dialog.set_close_response("cancel");
                confirm_dialog.set_response_appearance("refresh", Adw.ResponseAppearance.SUGGESTED);

                confirm_dialog.choose.begin(parent_win, null, (obj, res) => {
                    string response = confirm_dialog.choose.end(res);
                    if (response == "refresh") {
                        parent_win.fetch_news();
                    }
                });
            }
        });

        // Present the dialog
        dialog.present(parent);
    }

    
    public static void show_about_dialog(Gtk.Window parent) {
    var about = new Adw.AboutDialog();
    about.set_application_name("Paperboy");
    about.set_application_icon("paperboy"); // Use the correct icon name
    about.set_version("0.7.3a");
    about.set_developer_name("thecalamityjoe87 (Isaac Joseph)");
    about.set_comments("A simple news app written in Vala, built with GTK4 and Libadwaita.");
    about.set_website("https://github.com/thecalamityjoe87/paperboy");
    about.set_license_type(Gtk.License.GPL_3_0);
    about.set_copyright("© 2025 thecalamityjoe87 (Isaac Joseph)");
    about.present(parent);
    }
}