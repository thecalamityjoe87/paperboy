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
    }

    // Create a circular clipped version of a pixbuf
    private Gdk.Pixbuf? create_circular_pixbuf(Gdk.Pixbuf source, int size) {
        try {
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, size, size);
            var cr = new Cairo.Context(surface);

            // Create circular clipping path
            cr.arc(size / 2.0, size / 2.0, size / 2.0, 0, 2 * Math.PI);
            cr.clip();

            // Draw the pixbuf
            Gdk.cairo_set_source_pixbuf(cr, source, 0, 0);
            cr.paint();

            // Convert surface back to pixbuf
            string key = "pixbuf::circular::%p::%dx%d".printf(source, size, size);
            return ImageCache.get_global().get_or_from_surface(key, surface, 0, 0, size, size);
        } catch (GLib.Error e) {
            return null;
        }
    }

    public void update_category_icon() {
        try {
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

                if (rss_source != null) {
                    // Try to load the source logo from SourceMetadata
                    string? icon_filename = SourceMetadata.get_saved_filename_for_source(rss_source.name);
                    if (icon_filename == null || icon_filename.length == 0) {
                        icon_filename = rss_source.icon_filename;
                    }
                    if (icon_filename == null || icon_filename.length == 0) {
                        icon_filename = SourceMetadata.sanitize_filename(rss_source.name) + "-logo.png";
                    }

                    if (icon_filename != null && icon_filename.length > 0) {
                        var data_dir = GLib.Environment.get_user_data_dir();
                        var logo_path = GLib.Path.build_filename(data_dir, "paperboy", "source_logos", icon_filename);

                        if (GLib.FileUtils.test(logo_path, GLib.FileTest.EXISTS)) {
                            try {
                                string key = "pixbuf::file:%s::%dx%d".printf(logo_path, 36, 36);
                                var cached = ImageCache.get_global().get_or_load_file(key, logo_path, 36, 36);
                                if (cached != null) {
                                    // Create circular clipped version
                                    var circular = create_circular_pixbuf(cached, 36);
                                    if (circular != null) {
                                        var texture = Gdk.Texture.for_pixbuf(circular);
                                        var img = new Gtk.Image.from_paintable(texture);
                                        img.set_pixel_size(36);
                                        category_icon_holder.append(img);
                                        return;
                                    }
                                }
                            } catch (GLib.Error e) { }
                        }
                    }
                }

                // Fallback to RSS icon if logo not found
                var img = new Gtk.Image();
                img.set_from_icon_name("application-rss+xml-symbolic");
                img.set_pixel_size(36);
                category_icon_holder.append(img);
                return;
            }

            // Regular category icons
            var hdr = CategoryIcons.create_category_header_icon(window.prefs.category, 36);
            if (hdr != null) category_icon_holder.append(hdr);
        } catch (GLib.Error e) { }
    }

    public void update_source_info() {
        // Handle RSS feeds - show RSS icon and "Followed Source" on the right
        try {
            if (window.prefs.category != null && window.prefs.category.has_prefix("rssfeed:")) {
                try { source_label.set_text("Followed Source"); } catch (GLib.Error e) { }
                try { source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error e) { }
                return;
            }
        } catch (GLib.Error e) { }

        try {
            if (window.prefs != null && window.prefs.category == "local_news") {
                try { source_label.set_text("Local News"); } catch (GLib.Error e) { }
                try {
                    string? local_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "local-mono.svg"));
                    if (local_icon == null) local_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "local-mono.svg"));
                    if (local_icon != null) {
                        string use_path = local_icon;
                        try {
                            if (window.is_dark_mode()) {
                                string? white_cand = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "local-mono-white.svg"));
                                if (white_cand == null) white_cand = DataPaths.find_data_file(GLib.Path.build_filename("icons", "local-mono-white.svg"));
                                if (white_cand != null) use_path = white_cand;
                            }
                        } catch (GLib.Error e) { }
                        string key = "pixbuf::file:%s::%dx%d".printf(use_path, 32, 32);
                        var cached = ImageCache.get_global().get_or_load_file(key, use_path, 32, 32);
                        if (cached != null) {
                            try {
                                var tex = ImageCache.get_global().get_texture(key); if (tex == null) tex = Gdk.Texture.for_pixbuf(cached);
                                try { source_logo.set_from_paintable(tex); } catch (GLib.Error e) { try { source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { } }
                            } catch (GLib.Error e) { try { source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { } }
                        } else {
                            try { source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error e) { }
                        }
                    } else {
                        try { source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error e) { }
                    }
                } catch (GLib.Error e) { try { source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { } }
                return;
            }
        } catch (GLib.Error e) { }

        if (window.prefs.category == "frontpage") {
            try { source_label.set_text("Multiple Sources"); } catch (GLib.Error e) { }
            try {
                string? multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono.svg"));
                if (multi_icon == null) multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "multiple-mono.svg"));
                if (multi_icon != null) {
                    string use_path = multi_icon;
                    try {
                        if (window.is_dark_mode()) {
                            string? white_cand = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono-white.svg"));
                            if (white_cand == null) white_cand = DataPaths.find_data_file(GLib.Path.build_filename("icons", "multiple-mono-white.svg"));
                            if (white_cand != null) use_path = white_cand;
                        }
                    } catch (GLib.Error e) { }
                    try {
                        string key = "pixbuf::file:%s::%dx%d".printf(use_path, 32, 32);
                        var cached = ImageCache.get_global().get_or_load_file(key, use_path, 32, 32);
                        if (cached != null) {
                            var tex = ImageCache.get_global().get_texture(key); if (tex == null) tex = Gdk.Texture.for_pixbuf(cached);
                            source_logo.set_from_paintable(tex);
                        } else {
                            try { source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { }
                        }
                    } catch (GLib.Error e) { try { source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { } }
                } else {
                    try { source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error e) { }
                }
            } catch (GLib.Error e) { }
            return;
        }

        if (window.prefs.category == "topten") {
            try { source_label.set_text("Multiple Sources"); } catch (GLib.Error e) { }
            try {
                string? multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono.svg"));
                if (multi_icon == null) multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "multiple-mono.svg"));
                if (multi_icon != null) {
                    string use_path = multi_icon;
                    try {
                        if (window.is_dark_mode()) {
                            string? white_cand = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono-white.svg"));
                            if (white_cand == null) white_cand = DataPaths.find_data_file(GLib.Path.build_filename("icons", "multiple-mono-white.svg"));
                            if (white_cand != null) use_path = white_cand;
                        }
                    } catch (GLib.Error e) { }
                    try {
                        string key = "pixbuf::file:%s::%dx%d".printf(use_path, 32, 32);
                        var cached = ImageCache.get_global().get_or_load_file(key, use_path, 32, 32);
                        if (cached != null) {
                            var tex = ImageCache.get_global().get_texture(key); if (tex == null) tex = Gdk.Texture.for_pixbuf(cached);
                            source_logo.set_from_paintable(tex);
                        } else {
                            try { source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { }
                        }
                    } catch (GLib.Error e) { try { source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { } }
                } else {
                    try { source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error e) { }
                }
            } catch (GLib.Error e) { }
            return;
        }

        if (window.prefs.preferred_sources != null && window.prefs.preferred_sources.size > 1) {
            source_label.set_text("Multiple Sources");
            string? multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono.svg"));
            if (multi_icon == null) multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "multiple-mono.svg"));
            if (multi_icon != null) {
                try {
                    string use_path = multi_icon;
                    try {
                        if (window.is_dark_mode()) {
                            string? white_candidate = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono-white.svg"));
                            if (white_candidate == null) white_candidate = DataPaths.find_data_file(GLib.Path.build_filename("icons", "multiple-mono-white.svg"));
                            if (white_candidate != null) use_path = white_candidate;
                        }
                    } catch (GLib.Error e) { }
                    string key = "pixbuf::file:" + use_path + "::32x32";
                    var cached = ImageCache.get_global().get(key);
                    if (cached == null) {
                        try {
                            var pb = ImageCache.get_global().get_or_load_file(key, use_path, 32, 32);
                            if (pb != null) cached = pb;
                        } catch (GLib.Error e) { }
                    }
                    if (cached != null) {
                        try {
                            var tex = ImageCache.get_global().get_texture(key); if (tex == null) tex = Gdk.Texture.for_pixbuf(cached);
                            source_logo.set_from_paintable(tex);
                            return;
                        } catch (GLib.Error e) { }
                    }
                } catch (GLib.Error e) { }
            }
            try { source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error e) { }
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

        try { source_label.set_text(source_name); } catch (GLib.Error e) { }

        if (logo_file != null) {
            string? logo_path = DataPaths.find_data_file(GLib.Path.build_filename("icons", logo_file));
            if (logo_path != null) {
                try {
                    // Load or fetch cached scaled logo pixbuf
                    // First try to determine target dims by probing original image.
                    var orig_pb = ImageCache.get_global().get_or_load_file("pixbuf::file:%s::%dx%d".printf(logo_path, 0, 0), logo_path, 0, 0);
                    if (orig_pb != null) {
                        int orig_width = 0; int orig_height = 0;
                        try { orig_width = orig_pb.get_width(); } catch (GLib.Error e) { orig_width = 0; }
                        try { orig_height = orig_pb.get_height(); } catch (GLib.Error e) { orig_height = 0; }
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
        string label_text;
        try {
            string q = window.get_current_search_query();
            if (q != null && q.length > 0)
                label_text = "Search Results: \"" + q + "\" in " + disp;
            else
                label_text = disp;
        } catch (GLib.Error e) {
            label_text = disp;
        }
        Idle.add(() => {
            try { if (category_label != null) category_label.set_text(label_text); } catch (GLib.Error e) { }
            try { update_category_icon(); } catch (GLib.Error e) { }
            try { update_source_info(); } catch (GLib.Error e) { }
            return false;
        });
    }

    public void update_content_header_now() {
        string disp = category_display_name_for(window.prefs.category);
        string label_text;
        try {
            string q = window.get_current_search_query();
            if (q != null && q.length > 0)
                label_text = "Search Results: \"" + q + "\" in " + disp;
            else
                label_text = disp;
        } catch (GLib.Error e) {
            label_text = disp;
        }

        try { if (category_label != null) category_label.set_text(label_text); } catch (GLib.Error e) { }

        if (window.prefs.category == "topten") {
            try {
                if (category_subtitle != null) {
                    // Make subtitle slightly larger for emphasis using Pango markup
                    try { category_subtitle.set_markup("<span size='11000'>TOP STORIES RIGHT NOW</span>"); } catch (GLib.Error e) { category_subtitle.set_text("TOP STORIES RIGHT NOW"); }
                    category_subtitle.set_visible(true);
                }
            } catch (GLib.Error e) { }
        } else {
            try {
                if (category_subtitle != null) category_subtitle.set_visible(false);
            } catch (GLib.Error e) { }
        }

        try { update_category_icon(); } catch (GLib.Error e) { }
        try { update_source_info(); } catch (GLib.Error e) { }
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
}
