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

        // Clear existing icon
        clear_category_icon_holder();

        // A global search takes over the header title (see
        // ContentView.filter_by_query, which sets category_label to
        // "Search results") independently of window.prefs.category, which
        // stays whatever category was selected before searching - so the
        // icon needs the same override, not the category switch below.
        if (window.search_manager != null && window.search_manager.get_query().strip().length > 0) {
            var search_icon = CategoryIconsUtils.create_category_header_icon("search", 36);
            if (search_icon != null) category_icon_holder.append(search_icon);
            return;
        }

        // Handle RSS feed icons
        if (window.prefs.category != null && window.prefs.category.has_prefix("rssfeed:")) {
            set_rss_feed_icon();
            return;
        }

        // Handle regular category icons
        var icon = CategoryIconsUtils.create_category_header_icon(window.prefs.category, 36);
        if (icon != null) category_icon_holder.append(icon);
    }

    private void clear_category_icon_holder() {
        Gtk.Widget? child = category_icon_holder.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            category_icon_holder.remove(child);
            child = next;
        }
    }

    private void set_rss_feed_icon() {
        // Extract feed URL from category
        if (window.prefs.category.length <= 8) {
            warning("Malformed rssfeed category: too short");
            set_fallback_rss_icon();
            return;
        }

        string feed_url = window.prefs.category.substring(8);
        var rss_store = Paperboy.RssSourceStore.get_instance();
        var rss_source = rss_store.get_source_by_url(feed_url);

        if (rss_source == null) {
            set_fallback_rss_icon();
            return;
        }

        // Try to load custom logo
        if (try_set_rss_logo(rss_source.icon_filename)) {
            return;
        }

        // Fallback to generic RSS icon
        set_fallback_rss_icon();
    }

    private bool try_set_rss_logo(string? icon_filename) {
        if (icon_filename == null || icon_filename.length == 0) {
            debug("HeaderManager: icon_filename is null or empty");
            return false;
        }

        var data_dir = GLib.Environment.get_user_data_dir();
        if (data_dir == null) return false;

        string logo_path = GLib.Path.build_filename(data_dir, "paperboy", "source_logos", icon_filename);
        if (!GLib.FileUtils.test(logo_path, GLib.FileTest.EXISTS)) {
            debug("HeaderManager: Logo file does NOT exist at path");
            return false;
        }

        string key = "pixbuf::file:%s::%dx%d".printf(logo_path, 36, 36);
        var pixbuf = ImageCache.get_global().get_or_load_file(key, logo_path, 36, 36);

        if (pixbuf == null || pixbuf.get_width() <= 1 || pixbuf.get_height() <= 1) {
            return false;
        }

        var circular = create_circular_pixbuf(pixbuf, 36);
        if (circular == null) return false;

        var texture = Gdk.Texture.for_pixbuf(circular);
        var img = new Gtk.Image.from_paintable(texture);
        img.set_pixel_size(36);
        category_icon_holder.append(img);
        return true;
    }

    private void set_fallback_rss_icon() {
        var img = new Gtk.Image();
        img.set_from_icon_name("application-rss+xml-symbolic");
        img.set_pixel_size(36);
        category_icon_holder.append(img);
    }

    public void update_content_header() {
        string disp_cat = category_display_name_for(window.prefs.category);
        //string q = window.get_current_search_query();
        //string label_text = (q != null && q.length > 0) ? ("Search Results: \"" + q + "\" in " + disp) : disp;
        Idle.add(() => {
            if (category_label != null) category_label.set_text(disp_cat);
            update_category_icon();
            return false;
        });
    }

    public void update_content_header_now() {
        string disp_cat = category_display_name_for(window.prefs.category);
        //string q = window.get_current_search_query();
        //string label_text = (q != null && q.length > 0) ? ("Search Results: \"" + q + "\" in " + disp) : disp;

        if (category_label != null) category_label.set_text(disp_cat);

        if (window.prefs.category == "topten") {
            if (category_subtitle != null) {
                category_subtitle.set_markup("<span size='22000'><b>TOP STORIES RIGHT NOW</b></span>");
                category_subtitle.set_visible(true);
                // Unlike HeroCarousel's title (created fresh, already
                // visible, every time), this label starts hidden at
                // construction and only toggles visible here - force a
                // resize so its CSS margin actually gets recomputed
                // instead of whatever was cached from while it was hidden.
                category_subtitle.queue_resize();
            }
        } else {
            if (category_subtitle != null) category_subtitle.set_visible(false);
        }

        update_category_icon();
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
            case "saved": return "Saved";
            case "general": return "World News";
            case "us": return "US News";
            case "world": return "World News";
            case "nation": return "US News";
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
            case "myfeed": return "My Feed";
            case "local_news": return "Local News";
            case "podcasts": return "Find Podcasts";
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

}
