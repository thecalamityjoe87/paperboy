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

public class HeaderManager : GLib.Object {
    private weak NewsWindow window;

    public Gtk.Label category_label;
    public Gtk.Label category_subtitle;
    public Gtk.Box? category_icon_holder;
    public Gtk.Label source_label;
    public Gtk.Image source_logo;

    public HeaderManager(NewsWindow w) {
        window = w;
        
        // Listen for RSS source updates (logo downloads)
        var store = Paperboy.RssSourceStore.get_instance();
        store.source_updated.connect((source) => {
            // If the currently selected category is this RSS feed, refresh the header icon
            if (window.prefs.category != null && window.prefs.category.has_prefix("rssfeed:")) {
                string feed_url = window.prefs.category.substring(8);
                if (feed_url == source.url) {
                    Idle.add(() => {
                        update_category_icon();
                        return false;
                    });
                }
            }
        });
    }

    /**
     * Set up the header for multi-source mode (Frontpage, Top Ten, or multiple preferred sources).
     * Sets source_label to "Multiple Sources" and loads the multi-source icon.
     */
    public void setup_multi_source_header() {
        source_label.set_text("Multiple Sources");
        string? multi_icon = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono.svg"));
        if (multi_icon == null) multi_icon = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "multiple-mono.svg"));
        if (multi_icon != null) {
            string use_path = multi_icon;
            if (window.is_dark_mode()) {
                string? white_cand = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono-white.svg"));
                if (white_cand == null) white_cand = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "multiple-mono-white.svg"));
                if (white_cand != null) use_path = white_cand;
            }
            string cache_key = "pixbuf::file:%s::%dx%d".printf(use_path, 32, 32);
            var cached_pb = ImageCache.get_global().get_or_load_file(cache_key, use_path, 32, 32);
            if (cached_pb != null) {
                var tex = Gdk.Texture.for_pixbuf(cached_pb);
                source_logo.set_from_paintable(tex);
            } else {
                source_logo.set_from_icon_name("application-rss+xml-symbolic");
            }
        } else {
            source_logo.set_from_icon_name("application-rss+xml-symbolic");
        }
    }

    /**
     * Set up the header for Local News mode.
     * Sets source_label to "Local News" and loads the local news icon.
     */
    public void setup_local_news_header() {
        source_label.set_text("Local News");
        string? local_icon = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "symbolic", "local-mono.svg"));
        if (local_icon == null) local_icon = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "local-mono.svg"));
        if (local_icon != null) {
            string use_path = local_icon;
            if (window.is_dark_mode()) {
                string? white_cand = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "symbolic", "local-mono-white.svg"));
                if (white_cand == null) white_cand = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "local-mono-white.svg"));
                if (white_cand != null) use_path = white_cand;
            }
            string cache_key = "pixbuf::file:%s::%dx%d".printf(use_path, 32, 32);
            var cached_pb = ImageCache.get_global().get_or_load_file(cache_key, use_path, 32, 32);
            if (cached_pb != null) {
                var tex = Gdk.Texture.for_pixbuf(cached_pb);
                source_logo.set_from_paintable(tex);
            } else {
                source_logo.set_from_icon_name("application-rss+xml-symbolic");
            }
        } else {
            source_logo.set_from_icon_name("application-rss+xml-symbolic");
        }
    }

    // Create a circular clipped version of a pixbuf
    private Gdk.Pixbuf? create_circular_pixbuf(Gdk.Pixbuf source, int size) {
        var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, size, size);
        if (surface.status() != Cairo.Status.SUCCESS) {
            warning("Cairo surface creation failed: %s", surface.status().to_string());
            return null;
        }
        var cr = new Cairo.Context(surface);

        // Create circular clipping path
        cr.arc(size / 2.0, size / 2.0, size / 2.0, 0, 2 * Math.PI);
        cr.clip();

        // Draw the pixbuf
        Gdk.cairo_set_source_pixbuf(cr, source, 0, 0);
        cr.paint();

        if (surface.status() != Cairo.Status.SUCCESS) {
            warning("Cairo drawing failed: %s", surface.status().to_string());
        return null;
        }

        // Convert surface back to pixbuf
        string key = "pixbuf::circular::%p::%dx%d".printf(source, size, size);
        return ImageCache.get_global().get_or_from_surface(key, surface, 0, 0, size, size);
    }

    public void update_category_icon() {
        if (category_icon_holder == null) return;
        Gtk.Widget? child = category_icon_holder.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            category_icon_holder.remove(child);
            child = next;
        }

            // For RSS feeds, show the source logo on the LEFT (category icon position)
            if (window.prefs.category != null && window.prefs.category.has_prefix("rssfeed:")) {
                string feed_url;
                if (window.prefs.category.length > 8) {
                    feed_url = window.prefs.category.substring(8);
                } else {
                    warning("Malformed rssfeed category: too short");
                    return;
                }
                var rss_store = Paperboy.RssSourceStore.get_instance();
                var rss_source = rss_store.get_source_by_url(feed_url);

                debug("HeaderManager: RSS feed selected: %s", feed_url);
                if (rss_source != null) {
                    debug("HeaderManager: Found RSS source: %s", rss_source.name);
                    // Use icon_filename from database (saved when logo was downloaded)
                    string? icon_filename = rss_source.icon_filename;
                    debug("HeaderManager: icon_filename = %s", icon_filename ?? "NULL");

                    if (icon_filename != null && icon_filename.length > 0) {
                        var data_dir = GLib.Environment.get_user_data_dir();
                        if (data_dir != null) {
                            var logo_path = GLib.Path.build_filename(data_dir, "paperboy", "source_logos", icon_filename);
                            debug("HeaderManager: Checking logo path: %s", logo_path);

                            if (GLib.FileUtils.test(logo_path, GLib.FileTest.EXISTS)) {
                                debug("HeaderManager: Logo file exists, loading...");
                                try {
                                    string key = "pixbuf::file:%s::%dx%d".printf(logo_path, 36, 36);
                                    var cached = ImageCache.get_global().get_or_load_file(key, logo_path, 36, 36);
                                    debug("HeaderManager: Loaded pixbuf: %dx%d", cached != null ? cached.get_width() : 0, cached != null ? cached.get_height() : 0);
                                    if (cached != null && cached.get_width() > 1 && cached.get_height() > 1) {
                                        // Create circular clipped version
                                        var circular = create_circular_pixbuf(cached, 36);
                                        debug("HeaderManager: Created circular pixbuf: %s", circular != null ? "YES" : "NULL");
                                        if (circular != null) {
                                            var texture = Gdk.Texture.for_pixbuf(circular);
                                            var img = new Gtk.Image.from_paintable(texture);
                                            img.set_pixel_size(36);
                                            category_icon_holder.append(img);
                                            debug("HeaderManager: Appended circular logo to header");
                                            return;
                                        }
                                    }
                                } catch (GLib.Error e) {
                                    warning("HeaderManager: Error loading logo: %s", e.message);
                                }
                            } else {
                                debug("HeaderManager: Logo file does NOT exist at path");
                            }
                        }
                    } else {
                        debug("HeaderManager: icon_filename is null or empty");
                    }
                } else {
                    debug("HeaderManager: RSS source not found in database");
                }

                // Fallback to RSS icon if logo not found
                var img = new Gtk.Image();
                img.set_from_icon_name("application-rss+xml-symbolic");
                img.set_pixel_size(36);
                category_icon_holder.append(img);
                return;
            }

            // Regular category icons
            var hdr = CategoryIconsUtils.create_category_header_icon(window.prefs.category, 36);
            if (hdr != null) category_icon_holder.append(hdr);
    }

    public void update_source_info() {
        // Handle saved articles - keep "Saved Articles" header that was set by update_for_saved_articles()
        if (window.prefs.category == "saved") {
            return;  // Header already set by update_for_saved_articles(), don't override
        }

        // Handle RSS feeds - show RSS icon and "Followed Source" on the right
        if (window.prefs.category != null && window.prefs.category.has_prefix("rssfeed:")) {
            source_label.set_text("Followed Source");
            source_logo.set_from_icon_name("application-rss+xml-symbolic");
            return;
        }

        if (window.prefs != null && window.prefs.category == "local_news") {
            source_label.set_text("Local News");
            string? local_icon = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "symbolic", "local-mono.svg"));
            if (local_icon == null) local_icon = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "local-mono.svg"));
            if (local_icon != null) {
                string use_path = local_icon;
                if (window.is_dark_mode()) {
                    string? white_cand = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "symbolic", "local-mono-white.svg"));
                    if (white_cand == null) white_cand = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "local-mono-white.svg"));
                    if (white_cand != null) use_path = white_cand;
                }
                string key = "pixbuf::file:%s::%dx%d".printf(use_path, 32, 32);
                var cached = ImageCache.get_global().get_or_load_file(key, use_path, 32, 32);
                if (cached != null) {
                    var tex = ImageCache.get_global().get_texture(key); if (tex == null) tex = Gdk.Texture.for_pixbuf(cached);
                    source_logo.set_from_paintable(tex);
                } else {
                    source_logo.set_from_icon_name("application-rss+xml-symbolic");
                }
            } else {
                source_logo.set_from_icon_name("application-rss+xml-symbolic");
            }
            return;
        }

        if (window.prefs.category == "frontpage") {
            source_label.set_text("Multiple Sources");
            string? multi_icon = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono.svg"));
            if (multi_icon == null) multi_icon = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "multiple-mono.svg"));
            if (multi_icon != null) {
                string use_path = multi_icon;
                if (window.is_dark_mode()) {
                    string? white_cand = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono-white.svg"));
                    if (white_cand == null) white_cand = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "multiple-mono-white.svg"));
                    if (white_cand != null) use_path = white_cand;
                }
                string key = "pixbuf::file:%s::%dx%d".printf(use_path, 32, 32);
                var cached = ImageCache.get_global().get_or_load_file(key, use_path, 32, 32);
                if (cached != null) {
                    var tex = ImageCache.get_global().get_texture(key); if (tex == null) tex = Gdk.Texture.for_pixbuf(cached);
                    source_logo.set_from_paintable(tex);
                } else {
                    source_logo.set_from_icon_name("application-rss+xml-symbolic");
                }
            } else {
                source_logo.set_from_icon_name("application-rss+xml-symbolic");
            }
            return;
        }

        if (window.prefs.category == "topten") {
            source_label.set_text("Multiple Sources");
            string? multi_icon = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono.svg"));
            if (multi_icon == null) multi_icon = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "multiple-mono.svg"));
            if (multi_icon != null) {
                string use_path = multi_icon;
                if (window.is_dark_mode()) {
                    string? white_cand = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono-white.svg"));
                    if (white_cand == null) white_cand = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "multiple-mono-white.svg"));
                    if (white_cand != null) use_path = white_cand;
                }
                string key = "pixbuf::file:%s::%dx%d".printf(use_path, 32, 32);
                var cached = ImageCache.get_global().get_or_load_file(key, use_path, 32, 32);
                if (cached != null) {
                    var tex = ImageCache.get_global().get_texture(key); if (tex == null) tex = Gdk.Texture.for_pixbuf(cached);
                    source_logo.set_from_paintable(tex);
                } else {
                    source_logo.set_from_icon_name("application-rss+xml-symbolic");
                }
            } else {
                source_logo.set_from_icon_name("application-rss+xml-symbolic");
            }
            return;
        }

        if (window.prefs.preferred_sources != null && window.prefs.preferred_sources.size > 1) {
            source_label.set_text("Multiple Sources");
            string? multi_icon = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono.svg"));
            if (multi_icon == null) multi_icon = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "multiple-mono.svg"));
            if (multi_icon != null) {
                string use_path = multi_icon;
                if (window.is_dark_mode()) {
                    string? white_candidate = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono-white.svg"));
                    if (white_candidate == null) white_candidate = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "multiple-mono-white.svg"));
                    if (white_candidate != null) use_path = white_candidate;
                }
                string key = "pixbuf::file:" + use_path + "::32x32";
                var cached = ImageCache.get_global().get(key);
                if (cached == null) {
                    var pb = ImageCache.get_global().get_or_load_file(key, use_path, 32, 32);
                    if (pb != null) cached = pb;
                }
                if (cached != null) {
                    var tex = ImageCache.get_global().get_texture(key); if (tex == null) tex = Gdk.Texture.for_pixbuf(cached);
                    source_logo.set_from_paintable(tex);
                    return;
                }
            }
            source_logo.set_from_icon_name("application-rss+xml-symbolic");
            return;
        }

        NewsSource eff = window.effective_news_source();

        string source_name = "";
        string? logo_file = null;
        switch (eff) {
            case NewsSource.GUARDIAN:
                source_name = "The Guardian";
                logo_file = "guardian-logo.png";
                break;
            case NewsSource.BBC:
                source_name = "BBC News";
                logo_file = "bbc-logo.png";
                break;
            case NewsSource.REDDIT:
                source_name = "Reddit";
                logo_file = "reddit-logo.png";
                break;
            case NewsSource.NEW_YORK_TIMES:
                source_name = "New York Times";
                logo_file = "nytimes-logo.png";
                break;
            case NewsSource.BLOOMBERG:
                source_name = "Bloomberg";
                logo_file = "bloomberg-logo.png";
                break;
            case NewsSource.REUTERS:
                source_name = "Reuters";
                logo_file = "reuters-logo.png";
                break;
            case NewsSource.NPR:
                source_name = "NPR";
                logo_file = "npr-logo.png";
                break;
            case NewsSource.FOX:
                source_name = "Fox News";
                logo_file = "foxnews-logo.png";
                break;
            case NewsSource.WALL_STREET_JOURNAL:
                source_name = "Wall Street Journal";
                logo_file = "wsj-logo.png";
                break;
            default:
                source_name = "News";
                logo_file = null;
                break;
        }

        source_label.set_text(source_name);

        if (logo_file != null) {
            string? logo_path = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", logo_file));
            if (logo_path != null) {
                try {
                    // Load or fetch cached scaled logo pixbuf
                    // First try to determine target dims by probing original image.
                    var orig_pb = ImageCache.get_global().get_or_load_file("pixbuf::file:%s::%dx%d".printf(logo_path, 0, 0), logo_path, 0, 0);
                    if (orig_pb != null) {
                        int orig_width = orig_pb.get_width(); int orig_height = orig_pb.get_height();
                        double aspect_ratio = orig_width > 0 && orig_height > 0 ? (double)orig_width / orig_height : 1.0;
                        double scale_factor;
                        if (aspect_ratio > 2.0 || aspect_ratio < 0.5) {
                            scale_factor = double.min(40.0 / orig_width, 40.0 / orig_height);
                        } else if (aspect_ratio > 1.5 || aspect_ratio < 0.67) {
                            scale_factor = double.min(36.0 / orig_width, 36.0 / orig_height);
                        } else {
                            scale_factor = double.min(32.0 / orig_width, 32.0 / orig_height);
                        }
                        int new_width = (int)(orig_width * scale_factor);
                        int new_height = (int)(orig_height * scale_factor);
                        string key = "pixbuf::file:%s::%dx%d".printf(logo_path, new_width, new_height);
                        var cached = ImageCache.get_global().get_or_load_file(key, logo_path, new_width, new_height);
                        if (cached != null) {
                            var texture = Gdk.Texture.for_pixbuf(cached);
                            source_logo.set_from_paintable(texture);
                            return;
                        }
                    }
                } catch (GLib.Error e) {
                    warning("Failed to load logo %s: %s", logo_path, e.message);
                }
            }
        }

        source_logo.set_from_icon_name("application-rss+xml-symbolic");
    }

    public void update_content_header() {
        string disp = category_display_name_for(window.prefs.category);
        string q = window.get_current_search_query();
        string label_text = (q != null && q.length > 0) ? ("Search Results: \"" + q + "\" in " + disp) : disp;
        Idle.add(() => {
            if (category_label != null) category_label.set_text(label_text);
            update_category_icon();
            update_source_info();
            return false;
        });
    }

    public void update_content_header_now() {
        string disp = category_display_name_for(window.prefs.category);
        string q = window.get_current_search_query();
        string label_text = (q != null && q.length > 0) ? ("Search Results: \"" + q + "\" in " + disp) : disp;

        if (category_label != null) category_label.set_text(label_text);

        if (window.prefs.category == "topten") {
            if (category_subtitle != null) {
                category_subtitle.set_markup("<span size='11000'>TOP STORIES RIGHT NOW</span>");
                category_subtitle.set_visible(true);
            }
        } else {
            if (category_subtitle != null) category_subtitle.set_visible(false);
        }

        update_category_icon();
        update_source_info();
    }

    public string category_display_name_for(string cat) {
        // Handle RSS feed categories
        if (cat != null && cat.has_prefix("rssfeed:")) {
            if (cat.length <= 8) {
                warning("Malformed rssfeed category in display name");
                return "RSS Feed";
            }
            string feed_url = cat.substring(8); // Extract URL after "rssfeed:" prefix
            var rss_store = Paperboy.RssSourceStore.get_instance();
            var rss_source = rss_store.get_source_by_url(feed_url);
            if (rss_source != null) {
                // Try to get display name from SourceMetadata first
                string? display_name = SourceMetadata.get_display_name_for_source(rss_source.name);
                if (display_name != null && display_name.length > 0) {
                    return display_name;
                }
                return rss_source.name;
            }
            return "RSS Feed";
        }

        switch (cat) {
            case "frontpage": return "Front Page";
            case "topten": return "Top Ten";
            case "general": return "World News";
            case "us": return "US News";
            case "technology": return "Technology";
            case "business": return "Business";
            case "sports": return "Sports";
            case "science": return "Science";
            case "health": return "Health";
            case "entertainment": return "Entertainment";
            case "politics": return "Politics";
            case "lifestyle": return "Lifestyle";
            case "markets": return "Markets";
            case "industries": return "Industries";
            case "economics": return "Economics";
            case "wealth": return "Wealth";
            case "green": return "Green";
            case "myfeed": return "My Feed";
            case "local_news": return "Local News";
            default: break;
        }
        if (cat == null || cat.length == 0) return "News";
        string s = cat.strip();
        if (s.length == 0) return "News";
        s = s.replace("_", " ").replace("-", " ");
        int st = 0;
        while (st < s.length) {
            char ch = s[st];
            bool is_alnum = ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9'));
            if (is_alnum) break;
            st++;
        }
        if (st > 0) s = s.substring(st);
        int en = s.length - 1;
        while (en >= 0) {
            char ch = s[en];
            bool is_alnum = ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9'));
            if (is_alnum) break;
            en--;
        }
        if (en < s.length - 1) s = s.substring(0, en + 1);
        string out = "";
        string[] parts = s.split(" ");
        foreach (var p in parts) {
            if (p.length == 0) continue;
            string w = p;
            char c = w[0];
            char up = c;
            if (c >= 'a' && c <= 'z') up = (char)(c - 32);
            string first = "%c".printf(up);
            string rest = w.length > 1 ? w.substring(1).down() : "";
            out += (out.length > 0 ? " " : "") + first + rest;
        }
        if (out.length == 0) return "News";
        return out;
    }

    /**
     * Load and set the multi-source icon on source_logo.
     * Handles dark mode variant selection.
     */
    public void setup_multi_source_logo() {
        source_label.set_text("Multiple Sources");

        string? multi_icon = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono.svg"));
        if (multi_icon == null) multi_icon = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "multiple-mono.svg"));

        if (multi_icon != null) {
            string use_path = multi_icon;
            if (window.is_dark_mode()) {
                string? white_cand = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono-white.svg"));
                if (white_cand == null) white_cand = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "multiple-mono-white.svg"));
                if (white_cand != null) use_path = white_cand;
            }

            string key = "pixbuf::file:%s::%dx%d".printf(use_path, 32, 32);
            var cached = ImageCache.get_global().get_or_load_file(key, use_path, 32, 32);
            if (cached != null) {
                var tex = ImageCache.get_global().get_texture(key);
                if (tex == null) tex = Gdk.Texture.for_pixbuf(cached);
                source_logo.set_from_paintable(tex);
                return;
            }
        }

        // Fallback to symbolic icon
        source_logo.set_from_icon_name("application-rss+xml-symbolic");
    }

    /**
     * Load and set the local news icon on source_logo.
     * Handles dark mode variant selection.
     */
    public void setup_local_news_logo() {
        source_label.set_text("Local News");

        string? local_icon = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "symbolic", "local-mono.svg"));
        if (local_icon == null) local_icon = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "local-mono.svg"));

        if (local_icon != null) {
            string use_path = local_icon;
            if (window.is_dark_mode()) {
                string? white_cand = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "symbolic", "local-mono-white.svg"));
                if (white_cand == null) white_cand = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "local-mono-white.svg"));
                if (white_cand != null) use_path = white_cand;
            }

            string key = "pixbuf::file:%s::%dx%d".printf(use_path, 32, 32);
            var cached = ImageCache.get_global().get_or_load_file(key, use_path, 32, 32);
            if (cached != null) {
                var tex = ImageCache.get_global().get_texture(key);
                if (tex == null) tex = Gdk.Texture.for_pixbuf(cached);
                source_logo.set_from_paintable(tex);
                return;
            }
        }

        // Fallback to symbolic icon
        source_logo.set_from_icon_name("application-rss+xml-symbolic");
    }
    /**
     * Set up the header for Saved Articles mode.
     */
    public void update_for_saved_articles() {
        source_label.set_text("Saved Articles");
        source_logo.set_from_icon_name("user-bookmarks-symbolic");
    }
}
