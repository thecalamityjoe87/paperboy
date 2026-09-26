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

// Bound directly to the C symbol since GTK4 minor versions ship
// Gtk.DragIcon.get_for_drag's vapi binding in incompatible shapes.
[CCode (cname = "gtk_drag_icon_get_for_drag")]
private static extern unowned Gtk.Widget prefs_dialog_drag_icon_get_for_drag(Gdk.Drag drag);

public class PrefsDialog : GLib.Object {

    private delegate void SportsOrderPersistFunc();

    // Builds the drag-reorderable, per-league enable/disable list used for
    // the Sports Score Cards section - shared between the Preferences
    // dialog and the onboarding flow so both stay in sync automatically.
    // `win` is null during onboarding (no NewsWindow yet to refresh).
    public static Gtk.ListBox build_sports_league_list_box(NewsPreferences prefs, NewsWindow? win) {
        var sports_list_box = new Gtk.ListBox();
        sports_list_box.set_selection_mode(Gtk.SelectionMode.NONE);
        sports_list_box.add_css_class("boxed-list");

        // Persists the listbox's current row order back to prefs, reading
        // each row's league key off the name we stashed on it below rather
        // than tracking a separate parallel list.
        SportsOrderPersistFunc persist_sports_order = () => {
            var new_order = new Gee.ArrayList<string>();
            var row = sports_list_box.get_row_at_index(0);
            int i = 0;
            while (row != null) {
                new_order.add(row.get_name());
                i++;
                row = sports_list_box.get_row_at_index(i);
            }
            prefs.sports_league_order = new_order;

            if (win != null && win.prefs.category == "sports") {
                SportsScoresController.load(win);
            }
        };

        foreach (var league_key in prefs.ordered_sports_league_keys()) {
            string display_name = SportsScoresService.display_name_for(league_key);
            var league_row = new Adw.SwitchRow();
            league_row.set_title(display_name);
            league_row.set_active(prefs.sports_league_enabled(league_key));
            league_row.set_name(league_key);

            // Column-aligned logo, same size and same circular-baked-pixel
            // technique as the source rows' favicons above (PixbufUtils) -
            // a plain "circular-logo" CSS class only clips widgets already
            // scoped under an existing selector, so this bakes the circle
            // into the image itself instead of depending on a new scope.
            var league_logo = PixbufUtils.make_circular_logo_placeholder(26);
            string? logo_url = SportsScoresService.logo_url_for(league_key);
            if (logo_url != null && logo_url.length > 0) {
                PixbufUtils.load_circular_logo_async(league_logo, logo_url, 26);
            }

            // add_prefix inserts each new widget before the ones already
            // added, so the logo goes in first and the handle second to end
            // up leftmost: handle | logo | text.
            league_row.add_prefix(league_logo);
            var drag_handle = new Gtk.Image.from_icon_name("list-drag-handle-symbolic");
            drag_handle.add_css_class("dim-label");
            drag_handle.set_tooltip_text("Drag to reorder");
            league_row.add_prefix(drag_handle);

            string _league_key = league_key;
            league_row.notify["active"].connect(() => {
                prefs.set_sports_league_enabled(_league_key, league_row.get_active());

                // Reflect the change immediately rather than waiting on the
                // "Refresh Content?" dialog other Preferences changes use -
                // toggling a switch here has no other user-visible effect
                // otherwise, since Sports may already be the open category.
                if (win != null && win.prefs.category == "sports") {
                    SportsScoresController.load(win);
                }
            });

            // Drag-and-drop reordering. The drag source is scoped to the
            // handle icon (not the whole row) so the switch and title stay
            // normally clickable/toggleable.
            var drag_source = new Gtk.DragSource();
            drag_source.set_actions(Gdk.DragAction.MOVE);
            drag_source.prepare.connect((source, x, y) => {
                Value val = Value(typeof(Gtk.ListBoxRow));
                val.set_object(league_row);
                return new Gdk.ContentProvider.for_value(val);
            });
            drag_source.drag_begin.connect((source, drag) => {
                var drag_icon = (Gtk.DragIcon) prefs_dialog_drag_icon_get_for_drag(drag);
                var icon_label = new Gtk.Label(display_name);
                icon_label.add_css_class("card");
                icon_label.set_margin_top(6);
                icon_label.set_margin_bottom(6);
                icon_label.set_margin_start(12);
                icon_label.set_margin_end(12);
                drag_icon.set_child(icon_label);
            });
            drag_handle.add_controller(drag_source);

            var drop_target = new Gtk.DropTarget(typeof(Gtk.ListBoxRow), Gdk.DragAction.MOVE);
            drop_target.drop.connect((value, x, y) => {
                Gtk.ListBoxRow? src_row = (Gtk.ListBoxRow) value.get_object();
                if (src_row == null || src_row == league_row) return false;

                int target_index = league_row.get_index();
                sports_list_box.remove(src_row);
                sports_list_box.insert(src_row, target_index);
                persist_sports_order();
                return true;
            });
            league_row.add_controller(drop_target);

            sports_list_box.append(league_row);
        }

        return sports_list_box;
    }

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
        // For now, we'll remove this property call
        // This causes issue with distros that are running
        // older versions of libadwaita.
        //categories_dialog.set_prefer_wide_layout(true);

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
        scroller.set_max_content_height(680);
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

        string[] bb_ids = { "markets", "industries", "economics", "technology", "politics" };
        string[] bb_titles = { "Markets", "Industries", "Economics", "Technology", "Politics" };

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
                var win = parent as NewsWindow;
                if (win != null) {
                    UnreadFetchService.refresh_myfeed_metadata(win);
                }
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
    public static void show_preferences_dialog(Gtk.Window parent, bool open_personalization = false, bool open_sports_settings = false, bool open_local_news = false) {
        var win = (NewsWindow) parent;
        var prefs = NewsPreferences.get_instance();

        // Create PreferencesDialog
        var dialog = new Adw.PreferencesDialog();
        dialog.set_title("Preferences");

        // Wide enough to keep the top view-switcher showing all three tabs
        // as pills - narrower than this and Adw.PreferencesDialog collapses
        // them into a dropdown menu instead.
        dialog.set_content_width(600);
        dialog.set_content_height(680);

        // Track if sources changed for refresh on close
        bool sources_changed = false;

        // ========== SOURCES PAGE ==========
        var sources_page = new Adw.PreferencesPage();
        sources_page.set_title("Sources");
        sources_page.set_icon_name("application-rss+xml-symbolic");
        var header_group = new Adw.PreferencesGroup();

        // Built-in sources and Feeds each get their own subpage, since
        // the feeds list can grow long.
        Adw.NavigationPage build_sources_subpage(Adw.PreferencesPage content, string title) {
            var toolbar_view = new Adw.ToolbarView();
            toolbar_view.add_top_bar(new Adw.HeaderBar());
            toolbar_view.set_content(content);
            return new Adw.NavigationPage(toolbar_view, title);
        }

        // Built-in News Sources Group
        var builtin_page = new Adw.PreferencesPage();
        var builtin_sources_group = new Adw.PreferencesGroup();

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
        builtin_sources_group.add(create_source_row("PBS NewsHour", "Neutral, in-depth public affairs reporting", "pbs", "https://www.pbs.org/favicon.ico"));
        builtin_sources_group.add(create_source_row("BBC News", "Comprehensive international and UK reporting", "bbc", "https://www.bbc.co.uk/favicon.ico"));
        builtin_sources_group.add(create_source_row("New York Times", "In-depth journalism across major categories", "nytimes", "https://www.nytimes.com/favicon.ico"));
        builtin_sources_group.add(create_source_row("Bloomberg", "Market, business, and finance coverage", "bloomberg", "https://www.bloomberg.com/favicon.ico"));
        builtin_sources_group.add(create_source_row("Wall Street Journal", "Business, economic, and political reporting", "wsj", "https://www.wsj.com/favicon.ico"));
        builtin_sources_group.add(create_source_row("ABC News", "US network coverage across politics, business, and more", "abc", "https://abcnews.go.com/favicon.ico"));
        builtin_sources_group.add(create_source_row("NPR", "Public radio news and feature storytelling", "npr", "https://www.npr.org/favicon.ico"));
        builtin_sources_group.add(create_source_row("Fox News", "U.S. politics, headlines, and commentary", "fox", "https://www.foxnews.com/favicon.ico"));


        builtin_page.add(builtin_sources_group);

        // Followed RSS Sources Group
        var feeds_page = new Adw.PreferencesPage();
        var rss_sources_group = new Adw.PreferencesGroup();
        int feed_row_count = 0;

        var feeds_nav_row = new Adw.ActionRow();
        feeds_nav_row.set_title("Followed feeds");

        void update_feeds_summary() {
            if (feed_row_count == 0) {
                feeds_nav_row.set_subtitle("No feeds followed yet");
                rss_sources_group.set_description("No feeds followed yet. Add one from the sidebar's Feeds section.");
            } else {
                feeds_nav_row.set_subtitle(feed_row_count == 1 ? "1 followed feed" : "%d followed feeds".printf(feed_row_count));
                rss_sources_group.set_description(null);
            }
        }
        
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
        var rendered_source_urls = new Gee.HashSet<string>();

        void add_rss_source_row(Paperboy.RssSource rss_source) {
                var rss_row = new Adw.ActionRow();

                string display_name = rss_source.get_display_name();

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
                        "Are you sure you want to remove '" + rss_source.get_display_name() + "' and all of its articles?"
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
                            feed_row_count--;
                            update_feeds_summary();
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
                    bool now_enabled = custom_switch.get_active();
                    prefs.set_preferred_source_enabled("custom:" + rss_source.url, now_enabled);
                    prefs.save_config();
                    sources_changed = true;

                    // Reflect the enable/disable immediately in the sidebar
                    // rather than waiting on the "Refresh Content?" dialog
                    // that only appears once Preferences is closed.
                    if (win != null && win.sidebar_manager != null) {
                        win.sidebar_manager.rebuild_sidebar();
                        win.sidebar_manager.update_badge_for_category("myfeed");
                    }

                    // If the user just disabled the feed they're currently
                    // viewing, its sidebar row is now gone - leaving its
                    // content on screen would be stale and unreachable, so
                    // redirect to Front Page like the "no sources support
                    // this category" fallback below does on dialog close.
                    if (!now_enabled && win != null && win.prefs.category == "rssfeed:" + rss_source.url) {
                        win.prefs.category = "frontpage";
                        win.prefs.save_config();
                        win.update_content_header();
                        win.fetch_news();
                    }
                });

                var edit_btn = new Gtk.Button();
                edit_btn.set_icon_name("document-edit-symbolic");
                edit_btn.set_valign(Gtk.Align.CENTER);
                edit_btn.set_has_frame(false);
                edit_btn.set_tooltip_text("Rename this source");
                edit_btn.clicked.connect(() => {
                    FeedRenameDialog.present(dialog, win, rss_source.url, (updated) => {
                        rss_row.set_title(GLib.Markup.escape_text(updated.get_display_name()));
                    });
                });

                rss_row.add_suffix(edit_btn);
                rss_row.add_suffix(delete_btn);
                rss_row.add_suffix(custom_switch);
                rss_row.set_activatable(true);
                rss_row.activated.connect(() => {
                    custom_switch.set_active(!custom_switch.get_active());
                });

                rss_sources_group.add(rss_row);
                feed_row_count++;
                update_feeds_summary();
        }

        foreach (var rss_source in all_sources) {
            add_rss_source_row(rss_source);
            rendered_source_urls.add(rss_source.url);
        }

        feeds_page.add(rss_sources_group);
        update_feeds_summary();

        var builtin_nav_page = build_sources_subpage(builtin_page, "Built-in sources");
        var feeds_nav_page = build_sources_subpage(feeds_page, "Custom feeds");

        var builtin_group = new Adw.PreferencesGroup();
        builtin_group.set_title("Built-in sources");
        builtin_group.set_description("News outlets that come with Paperboy");
        var builtin_nav_row = new Adw.ActionRow();
        builtin_nav_row.set_title("News outlets");
        builtin_nav_row.set_subtitle("Choose which outlets to follow");
        builtin_nav_row.add_suffix(new Gtk.Image.from_icon_name("go-next-symbolic"));
        builtin_nav_row.set_activatable(true);
        builtin_nav_row.activated.connect(() => {
            if (builtin_nav_page.get_parent() == null) dialog.push_subpage(builtin_nav_page);
        });
        builtin_group.add(builtin_nav_row);
        sources_page.add(builtin_group);

        var custom_group = new Adw.PreferencesGroup();
        custom_group.set_title("Custom feeds");
        custom_group.set_description("RSS feeds you've followed");
        feeds_nav_row.add_suffix(new Gtk.Image.from_icon_name("go-next-symbolic"));
        feeds_nav_row.set_activatable(true);
        feeds_nav_row.activated.connect(() => {
            if (feeds_nav_page.get_parent() == null) dialog.push_subpage(feeds_nav_page);
        });
        custom_group.add(feeds_nav_row);
        sources_page.add(custom_group);

        // Podcast subscriptions subpage
        var podcast_store = Paperboy.PodcastSubscriptionStore.get_instance();
        var podcasts_page = new Adw.PreferencesPage();
        var podcasts_list_group = new Adw.PreferencesGroup();
        var podcast_rows = new Gee.ArrayList<Gtk.Widget>();
        var podcasts_nav_row = new Adw.ActionRow();
        podcasts_nav_row.set_title("Subscribed podcasts");

        var remove_all_podcasts_row = new Adw.ButtonRow();
        remove_all_podcasts_row.set_title("Remove all podcasts");
        remove_all_podcasts_row.set_start_icon_name("user-trash-symbolic");
        remove_all_podcasts_row.add_css_class("destructive-action");
        var remove_all_podcasts_group = new Adw.PreferencesGroup();
        remove_all_podcasts_group.add(remove_all_podcasts_row);

        void update_podcasts_summary() {
            int n = podcast_rows.size;
            // if/else, not a nested ternary: Vala frees the printf() temp in that form before it's used.
            if (n == 0) podcasts_nav_row.set_subtitle("No podcasts yet");
            else if (n == 1) podcasts_nav_row.set_subtitle("1 podcast");
            else podcasts_nav_row.set_subtitle("%d podcasts".printf(n));
            podcasts_list_group.set_description(n == 0 ? "No podcasts yet. Find some from the sidebar's Podcasts section." : null);
            remove_all_podcasts_group.set_visible(n > 0);
        }

        void populate_podcast_rows() {
            foreach (var old_row in podcast_rows) podcasts_list_group.remove(old_row);
            podcast_rows.clear();
            foreach (var sub in podcast_store.get_all_subscriptions()) {
                int64 feed_id = sub.feed_id;
                string show_title = sub.title;
                var row = new Adw.ActionRow();
                row.set_title(GLib.Markup.escape_text(show_title));
                if (sub.author != null && sub.author.length > 0) row.set_subtitle(GLib.Markup.escape_text(sub.author));
                row.add_prefix(create_favicon_picture("placeholder:podcast:%s".printf(feed_id.to_string()), sub.image_url));

                var delete_btn = new Gtk.Button();
                delete_btn.set_icon_name("user-trash-symbolic");
                delete_btn.set_valign(Gtk.Align.CENTER);
                delete_btn.set_has_frame(false);
                delete_btn.set_tooltip_text("Remove podcast");
                delete_btn.add_css_class("destructive-action");
                delete_btn.clicked.connect(() => {
                    var confirm = new Adw.AlertDialog("Remove podcast?", "\"%s\" will be removed from your podcasts.".printf(show_title));
                    confirm.add_response("cancel", "Cancel");
                    confirm.add_response("remove", "Remove");
                    confirm.set_response_appearance("remove", Adw.ResponseAppearance.DESTRUCTIVE);
                    confirm.set_default_response("cancel");
                    confirm.set_close_response("cancel");
                    confirm.response.connect((response_id) => {
                        if (response_id != "remove") return;
                        podcast_store.unsubscribe(feed_id);
                        podcasts_list_group.remove(row);
                        podcast_rows.remove(row);
                        update_podcasts_summary();
                    });
                    confirm.present(dialog);
                });
                row.add_suffix(delete_btn);

                podcasts_list_group.add(row);
                podcast_rows.add(row);
            }
            update_podcasts_summary();
        }

        remove_all_podcasts_row.activated.connect(() => {
            int n = podcast_rows.size;
            var confirm = new Adw.AlertDialog("Remove all podcasts?",
                n == 1 ? "Your 1 podcast will be removed." : "All %d of your podcasts will be removed.".printf(n));
            confirm.add_response("cancel", "Cancel");
            confirm.add_response("remove", "Remove all");
            confirm.set_response_appearance("remove", Adw.ResponseAppearance.DESTRUCTIVE);
            confirm.set_default_response("cancel");
            confirm.set_close_response("cancel");
            confirm.response.connect((response_id) => {
                if (response_id != "remove") return;
                foreach (var sub in podcast_store.get_all_subscriptions()) podcast_store.unsubscribe(sub.feed_id);
                populate_podcast_rows();
            });
            confirm.present(dialog);
        });

        populate_podcast_rows();
        podcasts_page.add(podcasts_list_group);
        podcasts_page.add(remove_all_podcasts_group);
        var podcasts_nav_page = build_sources_subpage(podcasts_page, "Podcasts");

        var podcasts_group = new Adw.PreferencesGroup();
        podcasts_group.set_title("Podcasts");
        podcasts_group.set_description("Shows you've subscribed to");
        podcasts_nav_row.add_suffix(new Gtk.Image.from_icon_name("go-next-symbolic"));
        podcasts_nav_row.set_activatable(true);
        podcasts_nav_row.activated.connect(() => {
            if (podcasts_nav_page.get_parent() == null) dialog.push_subpage(podcasts_nav_page);
        });
        podcasts_group.add(podcasts_nav_row);
        sources_page.add(podcasts_group);

        // Magazine sources subpage - websites scanned for PDFs
        var magazine_store = Paperboy.MagazineLibraryStore.get_instance();
        var magazine_sources_page = new Adw.PreferencesPage();
        var magazine_sources_list_group = new Adw.PreferencesGroup();
        int magazine_source_count = 0;
        var magazine_sources_nav_row = new Adw.ActionRow();
        magazine_sources_nav_row.set_title("Magazine sources");

        void update_magazine_sources_summary() {
            int n = magazine_source_count;
            if (n == 0) magazine_sources_nav_row.set_subtitle("No sources yet");
            else if (n == 1) magazine_sources_nav_row.set_subtitle("1 source");
            else magazine_sources_nav_row.set_subtitle("%d sources".printf(n));
            magazine_sources_list_group.set_description(n == 0 ? "No sources yet. Websites you add from the Magazines page show up here." : null);
        }

        foreach (var source in magazine_store.get_all_sources()) {
            int64 source_id = source.id;
            string source_name = (source.name != null && source.name.length > 0) ? source.name : source.website_url;
            var row = new Adw.ActionRow();
            row.set_title(GLib.Markup.escape_text(source_name));
            row.set_subtitle(GLib.Markup.escape_text(elide_string(source.website_url, 28)));
            row.set_tooltip_text(source.website_url);
            string? host = UrlUtils.extract_host_from_url(source.website_url);
            string? icon_url = (host != null && host.length > 0) ? "https://www.google.com/s2/favicons?domain=" + host + "&sz=128" : null;
            row.add_prefix(create_favicon_picture("placeholder:magsource:%s".printf(source_id.to_string()), icon_url));

            var delete_btn = new Gtk.Button();
            delete_btn.set_icon_name("user-trash-symbolic");
            delete_btn.set_valign(Gtk.Align.CENTER);
            delete_btn.set_has_frame(false);
            delete_btn.set_tooltip_text("Remove source");
            delete_btn.add_css_class("destructive-action");
            delete_btn.clicked.connect(() => {
                int n_entries = magazine_store.get_entries_for_source(source_id).size;
                string body;
                if (n_entries == 0) {
                    body = "\"%s\" will be removed.".printf(source_name);
                } else if (n_entries == 1) {
                    body = "\"%s\" and the 1 magazine added from it will be removed, including its downloaded file.".printf(source_name);
                } else {
                    body = "\"%s\" and the %d magazines added from it will be removed, including their downloaded files.".printf(source_name, n_entries);
                }
                var confirm = new Adw.AlertDialog("Remove source?", body);
                confirm.add_response("cancel", "Cancel");
                confirm.add_response("remove", "Remove");
                confirm.set_response_appearance("remove", Adw.ResponseAppearance.DESTRUCTIVE);
                confirm.set_default_response("cancel");
                confirm.set_close_response("cancel");
                confirm.response.connect((response_id) => {
                    if (response_id != "remove") return;
                    magazine_store.remove_source(source_id);
                    magazine_sources_list_group.remove(row);
                    magazine_source_count--;
                    update_magazine_sources_summary();
                });
                confirm.present(dialog);
            });
            row.add_suffix(delete_btn);

            magazine_sources_list_group.add(row);
            magazine_source_count++;
        }
        update_magazine_sources_summary();
        magazine_sources_page.add(magazine_sources_list_group);
        var magazine_sources_nav_page = build_sources_subpage(magazine_sources_page, "Magazine sources");

        var magazines_group = new Adw.PreferencesGroup();
        magazines_group.set_title("Magazines");
        magazines_group.set_description("Websites scanned for magazine PDFs");
        magazine_sources_nav_row.add_suffix(new Gtk.Image.from_icon_name("go-next-symbolic"));
        magazine_sources_nav_row.set_activatable(true);
        magazine_sources_nav_row.activated.connect(() => {
            if (magazine_sources_nav_page.get_parent() == null) dialog.push_subpage(magazine_sources_nav_page);
        });
        magazines_group.add(magazine_sources_nav_row);
        sources_page.add(magazines_group);

        // Local News locations
        var local_group = new Adw.PreferencesGroup();
        local_group.set_title("Local News");
        var local_rows = new Gee.ArrayList<Gtk.Widget>();
        var add_location_row = new Adw.ButtonRow();
        add_location_row.set_title("Add a location");
        add_location_row.set_start_icon_name("list-add-symbolic");

        add_location_row.activated.connect(() => {
            LocationDialog.choose(dialog, null, (chosen) => {
                LocationDialog.save_areas(win, chosen);
                populate_local_group(local_group, local_rows, add_location_row, win, dialog);
            });
        });

        populate_local_group(local_group, local_rows, add_location_row, win, dialog);
        sources_page.add(local_group);

        dialog.add(sources_page);

        // Note: Sources changes will be reflected when user switches views

        // ========== APP PAGE ==========
        var app_page = new Adw.PreferencesPage();
        app_page.set_title("App");
        app_page.set_icon_name("preferences-system-symbolic");

        // ========== APPEARANCE GROUP ==========
        var appearance_group = new Adw.PreferencesGroup();
        appearance_group.set_title("Appearance");

        var theme_row = new Adw.ActionRow();
        theme_row.set_title("Theme");
        theme_row.set_subtitle("Follow the system theme, or force light or dark mode");

        var theme_dropdown = new Gtk.DropDown.from_strings(new string[] {
            "Follow System", "Light", "Dark"
        });
        theme_dropdown.set_valign(Gtk.Align.CENTER);
        switch (prefs.color_scheme) {
            case "light": theme_dropdown.set_selected(1); break;
            case "dark": theme_dropdown.set_selected(2); break;
            default: theme_dropdown.set_selected(0); break;
        }
        theme_dropdown.notify["selected"].connect(() => {
            switch (theme_dropdown.get_selected()) {
                case 1: prefs.color_scheme = "light"; break;
                case 2: prefs.color_scheme = "dark"; break;
                default: prefs.color_scheme = "system"; break;
            }
            prefs.save_config();
        });
        theme_row.add_suffix(theme_dropdown);
        theme_row.set_activatable_widget(theme_dropdown);
        appearance_group.add(theme_row);

        app_page.add(appearance_group);

        // ========== PERSONALIZATION PAGE ==========
        var personalization_page = new Adw.PreferencesPage();
        personalization_page.set_title("Personalization");
        personalization_page.set_icon_name("preferences-desktop-symbolic");

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
            // Drop the stale count so re-enabling starts from a fresh build
            if (!prefs.personalized_feed_enabled && win != null && win.article_state_store != null) {
                win.article_state_store.reset_myfeed_displayed_urls();
                win.article_state_store.save_article_tracking_to_disk();
            }
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

        // Separate place (its own row, its own slide-in page) for choosing
        // which followed custom RSS feeds show up in My Feed - deliberately
        // not folded into the "Personalized Feed Categories" dialog above.
        // Pushed as an Adw.NavigationPage via the PreferencesDialog's own
        // push_subpage() rather than opened as a separate modal dialog, so
        // it slides in/out like any other libadwaita preferences subpage.
        //
        // A local closure (not a static method) so it can reuse the
        // favicon-loading helpers (create_favicon_picture/
        // load_favicon_circular/try_load_icon_circular) already defined
        // above in this function, the same ones the "Feeds" section below
        // uses for its own favicons - giving these rows the same icons
        // instead of none.
        bool myfeed_feeds_subpage_open = false;
        Adw.NavigationPage build_myfeed_feeds_page() {
            var page = new Adw.PreferencesPage();
            var group = new Adw.PreferencesGroup();
            group.set_description("Choose which of your followed RSS feeds appear in My Feed");

            var myfeed_rss_store = Paperboy.RssSourceStore.get_instance();
            var enabled_feeds = new Gee.ArrayList<Paperboy.RssSource>();
            foreach (var src in myfeed_rss_store.get_all_sources()) {
                if (prefs.preferred_source_enabled("custom:" + src.url)) enabled_feeds.add(src);
            }

            if (enabled_feeds.size == 0) {
                var empty_row = new Adw.ActionRow();
                empty_row.set_title("No feeds followed yet");
                empty_row.set_subtitle("Follow a custom RSS feed in Preferences -> Feeds first, then come back here to include it in My Feed.");
                group.add(empty_row);
            } else {
                foreach (var src in enabled_feeds) {
                    string feed_url = src.url;
                    var frow = new Adw.ActionRow();
                    // Escape before set_title(): ActionRow parses this as
                    // Pango markup, so an unescaped "&" (e.g. "Food & Wine")
                    // breaks the parser and the title renders blank instead
                    // of erroring - same fix already applied to the "Feeds"
                    // section's rows below.
                    frow.set_title(GLib.Markup.escape_text(src.get_display_name()));

                    // Same favicon priority order as the "Feeds" section:
                    // saved local file, then SourceMetadata's logo URL,
                    // then Google's favicon service, then the RSS source's
                    // own favicon_url.
                    var wrapper = create_favicon_picture("placeholder:myfeed-feed:%s".printf(feed_url), null);
                    Gtk.Picture? picture = null;
                    if (wrapper is Gtk.Box) {
                        var wbox = (Gtk.Box) wrapper;
                        var child = wbox.get_first_child();
                        if (child is Gtk.Picture) picture = (Gtk.Picture) child;
                    }
                    if (picture != null) {
                        bool icon_loaded = false;
                        string? icon_filename = SourceMetadata.get_saved_filename_for_source(src.name);
                        if (icon_filename != null && icon_filename.length > 0) {
                            var data_dir = GLib.Environment.get_user_data_dir();
                            var icon_path = GLib.Path.build_filename(data_dir, "paperboy", "source_logos", icon_filename);
                            if (GLib.FileUtils.test(icon_path, GLib.FileTest.EXISTS)) {
                                try_load_icon_circular(icon_path, picture);
                                icon_loaded = true;
                            }
                        }
                        if (!icon_loaded) {
                            string? meta_logo_url = SourceMetadata.get_logo_url_for_source(src.name);
                            if (meta_logo_url != null && meta_logo_url.length > 0 &&
                                (meta_logo_url.has_prefix("http://") || meta_logo_url.has_prefix("https://"))) {
                                load_favicon_circular(picture, meta_logo_url);
                                icon_loaded = true;
                            }
                        }
                        if (!icon_loaded) {
                            string? host = UrlUtils.extract_host_from_url(feed_url);
                            if (host != null && host.length > 0) {
                                load_favicon_circular(picture, "https://www.google.com/s2/favicons?domain=" + host + "&sz=128");
                                icon_loaded = true;
                            }
                        }
                        if (!icon_loaded && src.favicon_url != null && src.favicon_url.length > 0 &&
                            (src.favicon_url.has_prefix("http://") || src.favicon_url.has_prefix("https://"))) {
                            load_favicon_circular(picture, src.favicon_url);
                        }
                    }
                    frow.add_prefix(wrapper);

                    var fswitch = new Gtk.Switch();
                    fswitch.set_active(prefs.myfeed_feed_enabled(feed_url));
                    fswitch.set_valign(Gtk.Align.CENTER);

                    string _furl = feed_url;
                    fswitch.notify["active"].connect(() => {
                        prefs.set_myfeed_feed_enabled(_furl, fswitch.get_active());
                        prefs.save_config();
                        categories_holder.changed = true;

                        var myfeed_win = parent as NewsWindow;
                        if (myfeed_win != null) {
                            UnreadFetchService.refresh_myfeed_metadata(myfeed_win);
                        }
                    });

                    frow.add_suffix(fswitch);
                    frow.set_activatable(true);
                    frow.activated.connect(() => {
                        fswitch.set_active(!fswitch.get_active());
                    });
                    group.add(frow);
                }
            }

            page.add(group);

            // Adw.HeaderBar shows its own contextual back chevron once inside
            // pushed-subpage content - wrap in one for that, but don't add a
            // manual back button too or it doubles up.
            var toolbar_view = new Adw.ToolbarView();
            toolbar_view.add_top_bar(new Adw.HeaderBar());
            toolbar_view.set_content(page);

            var nav_page = new Adw.NavigationPage(toolbar_view, "Custom feeds in My Feed");
            nav_page.hidden.connect(() => { myfeed_feeds_subpage_open = false; });
            return nav_page;
        }

        var myfeed_feeds_row = new Adw.ActionRow();
        myfeed_feeds_row.set_title("Custom feeds in My Feed");
        myfeed_feeds_row.set_subtitle("Choose which followed RSS feeds appear in My Feed");
        myfeed_feeds_row.add_suffix(new Gtk.Image.from_icon_name("go-next-symbolic"));
        myfeed_feeds_row.set_activatable(true);
        myfeed_feeds_row.activated.connect(() => {
            if (myfeed_feeds_subpage_open) return;
            myfeed_feeds_subpage_open = true;
            dialog.push_subpage(build_myfeed_feeds_page());
        });
        app_group.add(myfeed_feeds_row);

        // Custom sources only toggle
        var custom_only_row = new Adw.SwitchRow();
        custom_only_row.set_title("Custom feeds only in My Feed");
        custom_only_row.set_subtitle("Only show followed RSS feeds in My Feed, hide built-in sources");
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

            var sources_check = new Gtk.CheckButton.with_label("Show on Feeds");
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

        personalization_page.add(app_group);

        // ========== MY FEED EXTRAS GROUP ==========
        var myfeed_extras_group = new Adw.PreferencesGroup();
        myfeed_extras_group.set_title("My Feed Extras");
        myfeed_extras_group.set_description("Show a preview row for other features at the top of My Feed, with a button to jump to the full page");

        var myfeed_sports_row = new Adw.SwitchRow();
        myfeed_sports_row.set_title("Sports scores");
        myfeed_sports_row.set_active(prefs.myfeed_show_sports);
        myfeed_sports_row.notify["active"].connect(() => {
            prefs.myfeed_show_sports = myfeed_sports_row.get_active();
            prefs.save_config();
            if (win != null && win.prefs.category == "myfeed") win.fetch_news();
        });
        myfeed_extras_group.add(myfeed_sports_row);

        var myfeed_market_row = new Adw.SwitchRow();
        myfeed_market_row.set_title("Markets");
        myfeed_market_row.set_active(prefs.myfeed_show_market);
        myfeed_market_row.notify["active"].connect(() => {
            prefs.myfeed_show_market = myfeed_market_row.get_active();
            prefs.save_config();
            if (win != null && win.prefs.category == "myfeed") win.fetch_news();
        });
        myfeed_extras_group.add(myfeed_market_row);

        var myfeed_podcasts_row = new Adw.SwitchRow();
        myfeed_podcasts_row.set_title("Podcasts");
        myfeed_podcasts_row.set_active(prefs.myfeed_show_podcasts);
        myfeed_podcasts_row.notify["active"].connect(() => {
            prefs.myfeed_show_podcasts = myfeed_podcasts_row.get_active();
            prefs.save_config();
            if (win != null && win.prefs.category == "myfeed") win.fetch_news();
        });
        myfeed_extras_group.add(myfeed_podcasts_row);

        var myfeed_magazines_row = new Adw.SwitchRow();
        myfeed_magazines_row.set_title("Magazine Rack");
        myfeed_magazines_row.set_active(prefs.myfeed_show_magazines);
        myfeed_magazines_row.notify["active"].connect(() => {
            prefs.myfeed_show_magazines = myfeed_magazines_row.get_active();
            prefs.save_config();
            if (win != null && win.prefs.category == "myfeed") win.fetch_news();
        });
        myfeed_extras_group.add(myfeed_magazines_row);

        personalization_page.add(myfeed_extras_group);

        // ========== READING GROUP ==========
        var reading_group = new Adw.PreferencesGroup();
        reading_group.set_title("Reading");

        var reader_view_row = new Adw.SwitchRow();
        reader_view_row.set_title("Open articles in reader view");
        reader_view_row.set_subtitle("Show an extracted, distraction-free view of the article text instead of the full webpage by default. You can still switch views per article.");
        reader_view_row.set_active(prefs.reader_view_enabled);
        reader_view_row.notify["active"].connect(() => {
            prefs.reader_view_enabled = reader_view_row.get_active();
        });
        reading_group.add(reader_view_row);

        var article_click_row = new Adw.SwitchRow();
        article_click_row.set_title("Clicking an article opens reader view directly");
        article_click_row.set_subtitle("Skip the preview pane and jump straight into reader view when you click an article card");
        article_click_row.set_active(prefs.article_click_opens_reader);
        article_click_row.notify["active"].connect(() => {
            prefs.article_click_opens_reader = article_click_row.get_active();
        });
        reading_group.add(article_click_row);

        var hover_actions_row = new Adw.SwitchRow();
        hover_actions_row.set_title("Show quick-open buttons on hover");
        hover_actions_row.set_subtitle("Show reader view / preview buttons over an article card's image when you hover it");
        hover_actions_row.set_active(prefs.card_hover_actions_enabled);
        hover_actions_row.notify["active"].connect(() => {
            bool enabled = hover_actions_row.get_active();
            prefs.card_hover_actions_enabled = enabled;
            if (win != null) ArticleCard.set_hover_actions_visible_for_all(win, enabled);
        });
        reading_group.add(hover_actions_row);

        personalization_page.add(reading_group);

        // ========== MARKET CARDS GROUP ==========
        var market_group = new Adw.PreferencesGroup();
        market_group.set_title("Market Cards");
        market_group.set_description("Choose whether the Business category shows live market index cards");

        var market_master_row = new Adw.SwitchRow();
        market_master_row.set_title("Show market cards");
        market_master_row.set_subtitle("Turn off to hide the live market index cards from the Business category");
        market_master_row.set_active(prefs.market_cards_enabled);
        market_master_row.notify["active"].connect(() => {
            bool enabled = market_master_row.get_active();
            prefs.market_cards_enabled = enabled;
            if (win != null && win.prefs.category == "business" && enabled) {
                StocksTickerController.load(win);
            } else if (win != null) {
                StocksTickerController.stop_polling();
                StocksTickerController.hide(win);
            }
        });

        var market_pill_row = new Adw.SwitchRow();
        market_pill_row.set_title("Show market status pill");
        market_pill_row.set_subtitle("Show an \"Open\" pill next to the Business sidebar count while the market is open");
        market_pill_row.set_active(prefs.market_pill_enabled);
        market_pill_row.notify["active"].connect(() => {
            prefs.market_pill_enabled = market_pill_row.get_active();
            if (win != null && win.sidebar_manager != null) {
                win.sidebar_manager.rebuild_sidebar();
            }
        });

        market_group.add(market_master_row);
        market_group.add(market_pill_row);
        personalization_page.add(market_group);

        // ========== SPORTS SCORE CARDS GROUP ==========
        var sports_group = new Adw.PreferencesGroup();
        sports_group.set_title("Sports Score Cards");
        sports_group.set_description("Choose which leagues show score cards, and drag a row (by its handle) to set the order their sections appear in the Sports category");

        // Two-level drill-down subpage for favoriting individual teams -
        // same push_subpage()/Adw.NavigationPage pattern as "Custom feeds
        // in My Feed" above. MMA has no teams (individual fighters), so
        // it's the only league excluded from the first-level list.
        bool favorite_teams_subpage_open = false;

        Adw.NavigationPage build_favorite_team_picker_page(string league_key) {
            var page = new Adw.PreferencesPage();
            var group = new Adw.PreferencesGroup();
            group.set_title(SportsScoresService.display_name_for(league_key));

            var loading_row = new Adw.ActionRow();
            loading_row.set_title("Loading teams…");
            group.add(loading_row);

            page.add(group);

            var toolbar_view = new Adw.ToolbarView();
            toolbar_view.add_top_bar(new Adw.HeaderBar());
            toolbar_view.set_content(page);
            var nav_page = new Adw.NavigationPage(toolbar_view, SportsScoresService.display_name_for(league_key));

            SportsScoresService.fetch_teams(league_key, (returned_key, teams) => {
                group.remove(loading_row);

                if (teams == null || teams.size == 0) {
                    var empty_row = new Adw.ActionRow();
                    empty_row.set_title("Couldn't load teams");
                    empty_row.set_subtitle("Check your connection and try again later.");
                    group.add(empty_row);
                    return;
                }

                foreach (var team in teams) {
                    var team_row = new Adw.SwitchRow();
                    team_row.set_title(GLib.Markup.escape_text(team.display_name));
                    team_row.set_active(prefs.is_team_favorited(league_key, team.id));

                    var team_logo = PixbufUtils.make_circular_logo_placeholder(26);
                    if (team.logo_url != null && team.logo_url.length > 0) {
                        PixbufUtils.load_circular_logo_async(team_logo, team.logo_url, 26);
                    }
                    team_row.add_prefix(team_logo);

                    string _team_id = team.id;
                    team_row.notify["active"].connect(() => {
                        if (team_row.get_active()) {
                            prefs.add_favorite_team(league_key, _team_id);
                        } else {
                            prefs.remove_favorite_team(league_key, _team_id);
                        }
                        if (win != null && win.prefs.category == "sports") {
                            SportsScoresController.load(win);
                        }
                    });

                    group.add(team_row);
                }
            });

            return nav_page;
        }

        Adw.NavigationPage build_favorite_teams_leagues_page() {
            var page = new Adw.PreferencesPage();
            var group = new Adw.PreferencesGroup();
            group.set_description("Pick a league, then choose teams to follow - each followed team gets its own score-card row in \"My Teams\"");

            foreach (var league_key in SportsScoresService.league_keys()) {
                if (league_key == "mma") continue; // individual fighters, not teams

                var league_row = new Adw.ActionRow();
                league_row.set_title(SportsScoresService.display_name_for(league_key));

                var league_logo = PixbufUtils.make_circular_logo_placeholder(26);
                string? logo_url = SportsScoresService.logo_url_for(league_key);
                if (logo_url != null && logo_url.length > 0) {
                    PixbufUtils.load_circular_logo_async(league_logo, logo_url, 26);
                }
                league_row.add_prefix(league_logo);
                league_row.add_suffix(new Gtk.Image.from_icon_name("go-next-symbolic"));
                league_row.set_activatable(true);

                string _league_key = league_key;
                league_row.activated.connect(() => {
                    dialog.push_subpage(build_favorite_team_picker_page(_league_key));
                });
                group.add(league_row);
            }

            page.add(group);

            var toolbar_view = new Adw.ToolbarView();
            toolbar_view.add_top_bar(new Adw.HeaderBar());
            toolbar_view.set_content(page);
            var nav_page = new Adw.NavigationPage(toolbar_view, "Favorite Teams");
            nav_page.hidden.connect(() => { favorite_teams_subpage_open = false; });
            return nav_page;
        }

        var favorite_teams_row = new Adw.ActionRow();
        favorite_teams_row.set_title("Favorite Teams");
        favorite_teams_row.set_subtitle("Follow specific teams to show their own score cards");
        favorite_teams_row.add_suffix(new Gtk.Image.from_icon_name("go-next-symbolic"));
        favorite_teams_row.set_activatable(true);
        favorite_teams_row.activated.connect(() => {
            if (favorite_teams_subpage_open) return;
            favorite_teams_subpage_open = true;
            dialog.push_subpage(build_favorite_teams_leagues_page());
        });

        var sports_list_box = build_sports_league_list_box(prefs, win);
        sports_list_box.set_margin_top(18);

        var sports_master_row = new Adw.SwitchRow();
        sports_master_row.set_title("Show score cards");
        sports_master_row.set_subtitle("Turn off to hide all live score cards from the Sports category");
        sports_master_row.set_active(prefs.sports_scores_enabled);
        sports_list_box.set_sensitive(prefs.sports_scores_enabled);
        sports_master_row.notify["active"].connect(() => {
            bool enabled = sports_master_row.get_active();
            prefs.sports_scores_enabled = enabled;
            sports_list_box.set_sensitive(enabled);
            if (win != null && win.prefs.category == "sports") {
                SportsScoresController.load(win);
            }
        });

        var sports_live_indicator_row = new Adw.SwitchRow();
        sports_live_indicator_row.set_title("Show live indicator");
        sports_live_indicator_row.set_subtitle("Show a \"Live\" pill next to the Sports sidebar count while a game is in progress");
        sports_live_indicator_row.set_active(prefs.sports_live_indicator_enabled);
        sports_live_indicator_row.set_sensitive(prefs.sports_scores_enabled);
        sports_live_indicator_row.notify["active"].connect(() => {
            bool enabled = sports_live_indicator_row.get_active();
            prefs.sports_live_indicator_enabled = enabled;
            if (win != null && win.sports_live_indicator != null) {
                if (enabled && prefs.sports_scores_enabled) {
                    win.sports_live_indicator.start();
                } else {
                    win.sports_live_indicator.stop();
                }
            }
        });

        // Keep the live-indicator row in sync with the master switch: it
        // can't be enabled while score cards themselves are off.
        sports_master_row.notify["active"].connect(() => {
            bool enabled = sports_master_row.get_active();
            sports_live_indicator_row.set_sensitive(enabled);
            if (win != null && win.sports_live_indicator != null) {
                if (enabled && prefs.sports_live_indicator_enabled) {
                    win.sports_live_indicator.start();
                } else {
                    win.sports_live_indicator.stop();
                }
            }
        });

        sports_group.add(sports_master_row);
        sports_group.add(favorite_teams_row);
        sports_group.add(sports_live_indicator_row);
        sports_group.add(sports_list_box);
        personalization_page.add(sports_group);

        dialog.add(personalization_page);

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

        // ========== IMPORT & EXPORT GROUP ==========
        var import_export_group = new Adw.PreferencesGroup();
        import_export_group.set_title("Backup &amp; Restore");

        var opml_row = new Adw.ActionRow();
        opml_row.set_title("Feeds");
        opml_row.set_subtitle("Export or import your custom RSS feeds and podcast subscriptions as an OPML file.");

        var opml_export_btn = new Gtk.Button.with_label("Export");
        opml_export_btn.set_valign(Gtk.Align.CENTER);
        opml_export_btn.clicked.connect(() => {
            var file_dialog = new Gtk.FileDialog();
            file_dialog.set_title("Export Feeds & Podcasts");
            file_dialog.set_initial_name("paperboy-feeds.opml");
            var filter = new Gtk.FileFilter();
            filter.set_filter_name("OPML files");
            filter.add_suffix("opml");
            file_dialog.set_default_filter(filter);

            file_dialog.save.begin(win, null, (obj, res) => {
                try {
                    var file = file_dialog.save.end(res);
                    if (file == null || file.get_path() == null) return;
                    Paperboy.OpmlService.export_to_file(file.get_path());
                    if (win.toast_manager != null) win.toast_manager.show_toast("Exported feeds and podcasts");
                } catch (GLib.Error e) {
                    if (!(e is Gtk.DialogError.DISMISSED)) warning("Failed to export OPML: %s", e.message);
                }
            });
        });

        var opml_import_btn = new Gtk.Button.with_label("Import");
        opml_import_btn.set_valign(Gtk.Align.CENTER);
        opml_import_btn.clicked.connect(() => {
            var file_dialog = new Gtk.FileDialog();
            file_dialog.set_title("Import Feeds & Podcasts");
            var filter = new Gtk.FileFilter();
            filter.set_filter_name("OPML files");
            filter.add_suffix("opml");
            filter.add_pattern("*.xml");
            file_dialog.set_default_filter(filter);

            file_dialog.open.begin(win, null, (obj, res) => {
                try {
                    var file = file_dialog.open.end(res);
                    if (file == null || file.get_path() == null) return;

                    if (win.toast_manager != null) win.toast_manager.show_toast("Importing feeds and podcasts…");

                    Paperboy.OpmlService.import_from_file(file.get_path(), win.source_manager, win.session, win.feed_updater, (import_result) => {
                        sources_changed = true;

                        // Add rows for the newly imported feeds immediately so
                        // they show up (already enabled) without reopening Preferences.
                        if (import_result.feeds_added > 0) {
                            foreach (var rss_source in rss_store.get_all_sources()) {
                                if (rendered_source_urls.contains(rss_source.url)) continue;
                                add_rss_source_row(rss_source);
                                rendered_source_urls.add(rss_source.url);
                            }
                        }

                        if (win.sidebar_manager != null) win.sidebar_manager.rebuild_sidebar();

                        if (win.toast_manager != null) {
                            win.toast_manager.show_toast("Imported %d feed(s) and %d podcast(s)".printf(import_result.feeds_added, import_result.podcasts_added));
                        }
                    });
                } catch (GLib.Error e) {
                    if (!(e is Gtk.DialogError.DISMISSED)) warning("Failed to import OPML: %s", e.message);
                }
            });
        });

        var opml_btn_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        opml_btn_box.append(opml_export_btn);
        opml_btn_box.append(opml_import_btn);
        opml_row.add_suffix(opml_btn_box);
        import_export_group.add(opml_row);

        var notes_export_row = new Adw.ActionRow();
        notes_export_row.set_title("Notes");
        notes_export_row.set_subtitle("Export or import your article notes as a JSON file.");

        var notes_export_btn = new Gtk.Button.with_label("Export");
        notes_export_btn.set_valign(Gtk.Align.CENTER);
        notes_export_btn.clicked.connect(() => {
            var file_dialog = new Gtk.FileDialog();
            file_dialog.set_title("Export Notes");
            file_dialog.set_initial_name("paperboy-notes.json");
            var filter = new Gtk.FileFilter();
            filter.set_filter_name("JSON files");
            filter.add_suffix("json");
            file_dialog.set_default_filter(filter);

            file_dialog.save.begin(win, null, (obj, res) => {
                try {
                    var file = file_dialog.save.end(res);
                    if (file == null || file.get_path() == null) return;
                    Paperboy.NotesExportService.export_to_file(file.get_path());
                    if (win.toast_manager != null) win.toast_manager.show_toast("Exported notes");
                } catch (GLib.Error e) {
                    if (!(e is Gtk.DialogError.DISMISSED)) warning("Failed to export notes: %s", e.message);
                }
            });
        });

        var notes_import_btn = new Gtk.Button.with_label("Import");
        notes_import_btn.set_valign(Gtk.Align.CENTER);
        notes_import_btn.clicked.connect(() => {
            var file_dialog = new Gtk.FileDialog();
            file_dialog.set_title("Import Notes");
            var filter = new Gtk.FileFilter();
            filter.set_filter_name("JSON files");
            filter.add_suffix("json");
            file_dialog.set_default_filter(filter);

            file_dialog.open.begin(win, null, (obj, res) => {
                try {
                    var file = file_dialog.open.end(res);
                    if (file == null || file.get_path() == null) return;
                    int imported = Paperboy.NotesExportService.import_from_file(file.get_path());
                    if (win.toast_manager != null) win.toast_manager.show_toast("Imported %d note(s)".printf(imported));
                } catch (GLib.Error e) {
                    if (!(e is Gtk.DialogError.DISMISSED)) warning("Failed to import notes: %s", e.message);
                }
            });
        });

        var notes_btn_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        notes_btn_box.append(notes_export_btn);
        notes_btn_box.append(notes_import_btn);
        notes_export_row.add_suffix(notes_btn_box);
        import_export_group.add(notes_export_row);

        app_page.add(import_export_group);

        // ========== DANGER ZONE GROUP ==========
        var danger_group = new Adw.PreferencesGroup();
        danger_group.set_title("Danger Zone");

        var reset_row = new Adw.ActionRow();
        reset_row.set_title("Reset app to factory settings");
        reset_row.set_subtitle("Erases all sources, saved articles, notes, settings, and cached data, then restarts Paperboy as if freshly installed.");

        var reset_btn = new Gtk.Button.with_label("Reset");
        reset_btn.set_valign(Gtk.Align.CENTER);
        reset_btn.add_css_class("destructive-action");
        reset_btn.clicked.connect(() => {
            var reset_confirm_dialog = new Adw.AlertDialog(
                "Reset to factory settings?",
                "This permanently deletes all sources, saved articles, notes, and settings, and cannot be undone. Paperboy will restart as if freshly installed."
            );
            reset_confirm_dialog.add_response("cancel", "Cancel");
            reset_confirm_dialog.add_response("reset", "Reset App");
            reset_confirm_dialog.set_response_appearance("reset", Adw.ResponseAppearance.DESTRUCTIVE);
            reset_confirm_dialog.set_default_response("cancel");
            reset_confirm_dialog.set_close_response("cancel");

            reset_confirm_dialog.response.connect((response_id) => {
                if (response_id == "reset") {
                    prefs.factory_reset();
                    restart_application(win);
                }
            });

            reset_confirm_dialog.present(dialog);
        });

        reset_row.add_suffix(reset_btn);
        danger_group.add(reset_row);
        app_page.add(danger_group);

        // ========== EXPERIMENTAL GROUP ==========
        var experimental_group = new Adw.PreferencesGroup();
        experimental_group.set_title("Experimental");

        var comments_row = new Adw.SwitchRow();
        comments_row.set_title("Show article comments");
        comments_row.set_subtitle("Show a comments button on the reader page for articles with a discoverable comment source (native feed, Disqus, or Hacker News discussion). Coverage is limited - many sites don't expose comments through any of these.");
        comments_row.set_active(prefs.comments_enabled);
        comments_row.notify["active"].connect(() => {
            prefs.comments_enabled = comments_row.get_active();
        });
        experimental_group.add(comments_row);

        app_page.add(experimental_group);

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
                            case "bbc": source = NewsSource.BBC; break;
                            case "nytimes": source = NewsSource.NEW_YORK_TIMES; break;
                            case "wsj": source = NewsSource.WALL_STREET_JOURNAL; break;
                            case "bloomberg": source = NewsSource.BLOOMBERG; break;
                            case "abc": source = NewsSource.ABC_NEWS; break;
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
                    // Always rebuild sidebar when sources change, regardless of refresh choice
                    // This ensures Bloomberg-specific categories are removed when Bloomberg is disabled
                    if (parent_win.sidebar_manager != null) {
                        parent_win.sidebar_manager.rebuild_sidebar();
                    }
                    if (response == "refresh") {
                        parent_win.fetch_news();
                    }
                });
            }
        });

        if (open_personalization || open_sports_settings) {
            dialog.set_visible_page(personalization_page);
        }

        // Present the dialog
        dialog.present(parent);

        if (open_local_news) {
            ulong local_handler_id = 0;
            local_handler_id = add_location_row.map.connect(() => {
                add_location_row.grab_focus();
                add_location_row.disconnect(local_handler_id);
            });
        }

        if (open_sports_settings) {
            // Land on the sports score cards settings in preferences
            // dialog after clicking the settings badge
            ulong handler_id = 0;
            handler_id = sports_master_row.map.connect(() => {
                sports_master_row.grab_focus();
                sports_master_row.disconnect(handler_id);
            });
        }
    }

    // Fills the Local News group: one row per saved location, then the add row.
    private static void populate_local_group(Adw.PreferencesGroup local_group, Gee.ArrayList<Gtk.Widget> local_rows,
                                             Adw.ButtonRow add_location_row, NewsWindow win, Adw.PreferencesDialog dialog) {
        var prefs = NewsPreferences.get_instance();
        foreach (var old_row in local_rows) local_group.remove(old_row);
        local_rows.clear();
        if (add_location_row.get_parent() != null) local_group.remove(add_location_row);

        var areas = prefs.get_local_areas();
        int max = NewsPreferences.MAX_LOCAL_AREAS;
        if (areas.size >= max) {
            local_group.set_description("%d of %d locations added. Remove one to add another.".printf(areas.size, max));
        } else {
            local_group.set_description("Up to %d locations · %d added".printf(max, areas.size));
        }

        for (int i = 0; i < areas.size; i++) {
            var area = areas[i];
            var row = new Adw.ActionRow();
            row.set_title(GLib.Markup.escape_text(area.name));
            row.set_subtitle(GLib.Markup.escape_text(area.city));
            // add_prefix prepends, so the icon goes in first: handle | icon | text.
            var icon = CategoryIconsUtils.create_category_icon("local_news");
            if (icon != null) row.add_prefix(icon);
            var drag_handle = new Gtk.Image.from_icon_name("list-drag-handle-symbolic");
            drag_handle.add_css_class("dim-label");
            drag_handle.set_tooltip_text("Drag to reorder");
            row.add_prefix(drag_handle);

            var edit_btn = new Gtk.Button.from_icon_name("document-edit-symbolic");
            edit_btn.set_tooltip_text("Change location");
            var delete_btn = new Gtk.Button.from_icon_name("user-trash-symbolic");
            delete_btn.set_tooltip_text("Remove location");
            delete_btn.add_css_class("destructive-action");
            foreach (var btn in new Gtk.Button[] { edit_btn, delete_btn }) {
                btn.set_valign(Gtk.Align.CENTER);
                btn.set_has_frame(false);
                row.add_suffix(btn);
            }

            // Drag from the handle only, so the row's buttons stay clickable.
            var drag_source = new Gtk.DragSource();
            drag_source.set_actions(Gdk.DragAction.MOVE);
            drag_source.prepare.connect((source, x, y) => {
                return new Gdk.ContentProvider.for_value(area.key);
            });
            drag_source.drag_begin.connect((source, drag) => {
                var drag_icon = (Gtk.DragIcon) prefs_dialog_drag_icon_get_for_drag(drag);
                var icon_label = new Gtk.Label(area.name);
                icon_label.add_css_class("card");
                icon_label.set_margin_top(6);
                icon_label.set_margin_bottom(6);
                icon_label.set_margin_start(12);
                icon_label.set_margin_end(12);
                drag_icon.set_child(icon_label);
            });
            drag_handle.add_controller(drag_source);

            int target_index = i;
            var drop_target = new Gtk.DropTarget(typeof(string), Gdk.DragAction.MOVE);
            drop_target.drop.connect((value, x, y) => {
                string src_key = value.get_string();
                if (src_key == area.key) return false;
                prefs.move_local_area(src_key, target_index);
                // Rebuild after the drop finishes, not while its row is mid-drag.
                Idle.add(() => {
                    populate_local_group(local_group, local_rows, add_location_row, win, dialog);
                    if (win.sidebar_manager != null) win.sidebar_manager.rebuild_sidebar();
                    return false;
                });
                return true;
            });
            row.add_controller(drop_target);
            edit_btn.clicked.connect(() => {
                LocationDialog.choose(dialog, area, (chosen) => {
                    LocationDialog.save_areas(win, chosen, area.key);
                    populate_local_group(local_group, local_rows, add_location_row, win, dialog);
                });
            });
            delete_btn.clicked.connect(() => {
                prefs.remove_local_area(area.key);
                prefs.save_config();
                populate_local_group(local_group, local_rows, add_location_row, win, dialog);
                LocationDialog.refresh_local_news(win);
            });

            local_group.add(row);
            local_rows.add(row);
        }

        add_location_row.set_sensitive(areas.size < max);
        local_group.add(add_location_row);
    }

    // Launches a fresh Paperboy process and quits this one. Looked up by
    // name (rather than re-exec'ing /proc/self/exe) so it works the same
    // whether installed via .deb or Flatpak.
    private static void restart_application(NewsWindow win) {
        string? exe_path = GLib.Environment.find_program_in_path("paperboy");
        if (exe_path != null) {
            try {
                GLib.Process.spawn_async(null, { exe_path }, null, GLib.SpawnFlags.SEARCH_PATH, null, null);
            } catch (GLib.Error e) {
                warning("Failed to restart Paperboy: %s", e.message);
            }
        } else {
            warning("Failed to restart Paperboy: could not locate the 'paperboy' executable");
        }

        win.application.quit();
    }
}