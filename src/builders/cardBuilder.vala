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
using Gdk;
using Cairo;

public class CardBuilder : GLib.Object {

    public CardBuilder() {
        GLib.Object();
    }

    public static Gtk.Widget build_category_chip(NewsWindow win, string category_id) {
        // For RSS feed categories, show "Followed Source" instead of "My Feed"
        string label_text;
        if (category_id != null && category_id.has_prefix("rssfeed:")) {
            label_text = "Followed Source";
        } else {
            label_text = win.category_display_name_for(category_id);
        }
        
        var chip = new Gtk.Label(label_text);
        chip.add_css_class("category-chip");
        chip.set_halign(Gtk.Align.START);
        chip.set_valign(Gtk.Align.START);
        return chip;
    }

    // Helper to map NewsSource -> display name (copied from NewsWindow.get_source_name)
    private static string source_display_name(NewsSource source) {
        switch (source) {
            case NewsSource.GUARDIAN: return "The Guardian";
            case NewsSource.WALL_STREET_JOURNAL: return "Wall Street Journal";
            case NewsSource.BBC: return "BBC News";
            case NewsSource.REDDIT: return "Reddit";
            case NewsSource.NEW_YORK_TIMES: return "NY Times";
            case NewsSource.BLOOMBERG: return "Bloomberg";
            case NewsSource.REUTERS: return "Reuters";
            case NewsSource.NPR: return "NPR";
            case NewsSource.FOX: return "Fox News";
            default: return "News";
        }
    }

    private static string? source_icon_filename(NewsSource source) {
        switch (source) {
            case NewsSource.GUARDIAN: return "guardian-logo.png";
            case NewsSource.BBC: return "bbc-logo.png";
            case NewsSource.REDDIT: return "reddit-logo.png";
            case NewsSource.NEW_YORK_TIMES: return "nytimes-logo.png";
            case NewsSource.BLOOMBERG: return "bloomberg-logo.png";
            case NewsSource.REUTERS: return "reuters-logo.png";
            case NewsSource.NPR: return "npr-logo.png";
            case NewsSource.FOX: return "foxnews-logo.png";
            case NewsSource.WALL_STREET_JOURNAL: return "wsj-logo.png";
            default: return null;
        }
    }

    public static Gtk.Widget build_source_badge(NewsSource source) {
        var box = new Gtk.Box(Orientation.HORIZONTAL, 6);
        box.add_css_class("source-badge");
        box.set_margin_bottom(8);
        box.set_margin_end(8);
        box.set_valign(Gtk.Align.END);
        box.set_halign(Gtk.Align.END);

        string? filename = source_icon_filename(source);
        if (filename != null) {
            string? path = DataPaths.find_data_file("icons/" + filename);
            if (path != null) {
                try {
                    // Use ImageCache for all generated pixbufs so we never keep long-lived
                    // pixbufs/textures outside the central cache. Ask ImageCache to
                    // provide a scaled pixbuf for the requested size.
                    // Determine a scaled size that fits into 20x20 while preserving aspect.
                    // We'll request the scaled backend pixbuf directly from ImageCache.
                    // First, probe original image size using a best-effort full-size load.
                    Gdk.Pixbuf? probe = ImageCache.get_global().get_or_load_file("pixbuf::file:%s::%dx%d".printf(path, 0, 0), path, 0, 0);
                    if (probe != null) {
                        int orig_w = 0; int orig_h = 0;
                        try { orig_w = probe.get_width(); } catch (GLib.Error e) { orig_w = 0; }
                        try { orig_h = probe.get_height(); } catch (GLib.Error e) { orig_h = 0; }
                        double scale = 1.0;
                        if (orig_w > 0 && orig_h > 0) scale = double.max(20.0 / orig_w, 20.0 / orig_h);
                        int sw = (int)(orig_w * scale);
                        int sh = (int)(orig_h * scale);
                        if (sw < 1) sw = 1;
                        if (sh < 1) sh = 1;

                        // Request the scaled pixbuf from ImageCache (centralized creation)
                        string key = "pixbuf::file:%s::%dx%d".printf(path, sw, sh);
                        Gdk.Pixbuf? used_pb = ImageCache.get_global().get_or_load_file(key, path, sw, sh);

                        if (used_pb != null) {
                            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, 20, 20);
                            var cr = new Cairo.Context(surface);
                            int x = (20 - sw) / 2;
                            int y = (20 - sh) / 2;
                            try { Gdk.cairo_set_source_pixbuf(cr, used_pb, x, y); cr.paint(); } catch (GLib.Error e) { }
                            string surf_key = "pixbuf::surface:icon:%s::%dx%d".printf(path, 20, 20);
                            var pb_surface = ImageCache.get_global().get_or_from_surface(surf_key, surface, 0, 0, 20, 20);
                            var cached_surface = pb_surface;

                            var pic = new Gtk.Picture();
                            Gdk.Pixbuf? final_pb = cached_surface != null ? cached_surface : pb_surface;
                            if (final_pb != null) {
                                try { pic.set_paintable(Gdk.Texture.for_pixbuf(final_pb)); } catch (GLib.Error e) { }
                            }
                            pic.set_size_request(20, 20);

                            var logo_wrapper = new Gtk.Box(Orientation.HORIZONTAL, 0);
                            logo_wrapper.add_css_class("circular-logo");
                            logo_wrapper.set_size_request(20, 20);
                            logo_wrapper.set_valign(Gtk.Align.CENTER);
                            logo_wrapper.set_halign(Gtk.Align.CENTER);
                            logo_wrapper.append(pic);
                            box.append(logo_wrapper);
                        }
                    }
                } catch (GLib.Error e) { }
            }
        }

        var lbl = new Gtk.Label(source_display_name(source));
        lbl.add_css_class("source-badge-label");
        lbl.set_valign(Gtk.Align.CENTER);
        lbl.set_xalign(0.5f);
        lbl.set_ellipsize(Pango.EllipsizeMode.END);
        lbl.set_max_width_chars(12);
        box.append(lbl);

        return box;
    }

    public static Gtk.Widget build_source_badge_dynamic(NewsWindow win, string? source_name, string? url, string? category_id) {
        string? provided_logo_url = null;
        string? display_name = source_name;
        if (source_name != null && source_name.index_of("||") >= 0) {
            string[] parts = source_name.split("||");
            if (parts.length >= 1) display_name = parts[0].strip();
            if (parts.length >= 2) {
                provided_logo_url = parts[1].strip();
                int cat_idx = provided_logo_url.index_of("##category::");
                if (cat_idx >= 0) provided_logo_url = provided_logo_url.substring(0, cat_idx).strip();
            }
        }
        if (display_name != null) {
            int cat_idx = display_name.index_of("##category::");
            if (cat_idx >= 0) display_name = display_name.substring(0, cat_idx).strip();
        }

        // For My Feed articles, prioritize source_info metadata from when the article
        // was originally fetched from frontpage/topten. This ensures we use the
        // correct display name and logo from the JSON API data rather than trying
        // to match against potentially incorrect RSS feed metadata.
        if (category_id == "myfeed") {
            string? meta_logo_url = null;
            string? meta_filename = null;
            string? meta_display_name = null;

            // First try matching by display_name if available
            if (display_name != null && display_name.length > 0) {
                meta_logo_url = SourceMetadata.get_logo_url_for_source(display_name);
                meta_filename = SourceMetadata.get_saved_filename_for_source(display_name);
                meta_display_name = SourceMetadata.get_display_name_for_source(display_name);
            }

            // If no match by name, try matching by article URL domain
            if (meta_logo_url == null && meta_filename == null && url != null && url.length > 0) {
                string? url_display_name = null;
                string? url_logo_url = null;
                string? url_filename = null;
                SourceMetadata.get_source_info_by_url(url, out url_display_name, out url_logo_url, out url_filename);
                if (url_display_name != null || url_logo_url != null || url_filename != null) {
                    meta_display_name = url_display_name;
                    meta_logo_url = url_logo_url;
                    meta_filename = url_filename;
                }
            }

            // If we found source_info metadata, use it directly
            if (meta_logo_url != null || meta_filename != null) {
                // Use the proper display name from metadata (e.g., "Tom's Guide" not "Tom s Guide")
                if (meta_display_name != null && meta_display_name.length > 0) {
                    display_name = meta_display_name;
                }
                var box = new Gtk.Box(Orientation.HORIZONTAL, 6);
                box.add_css_class("source-badge");
                box.set_margin_bottom(8);
                box.set_margin_end(8);
                box.set_valign(Gtk.Align.END);
                box.set_halign(Gtk.Align.END);

                bool icon_loaded = false;

                // Try to load from saved file first
                if (meta_filename != null) {
                    var data_dir = GLib.Environment.get_user_data_dir();
                    var icon_path = GLib.Path.build_filename(data_dir, "paperboy", "source_logos", meta_filename);
                    if (GLib.FileUtils.test(icon_path, GLib.FileTest.EXISTS)) {
                        try {
                            var probe = ImageCache.get_global().get_or_load_file("pixbuf::file:%s::%dx%d".printf(icon_path, 0, 0), icon_path, 0, 0);
                            if (probe != null) {
                                int orig_w = 0; int orig_h = 0;
                                try { orig_w = probe.get_width(); } catch (GLib.Error e) { orig_w = 0; }
                                try { orig_h = probe.get_height(); } catch (GLib.Error e) { orig_h = 0; }
                                double scale = 1.0;
                                if (orig_w > 0 && orig_h > 0) scale = double.max(20.0 / orig_w, 20.0 / orig_h);
                                int sw = (int)(orig_w * scale);
                                int sh = (int)(orig_h * scale);
                                if (sw < 1) sw = 1; if (sh < 1) sh = 1;

                                var scaled_icon = ImageCache.get_global().get_or_load_file("pixbuf::file:%s::%dx%d".printf(icon_path, sw, sh), icon_path, sw, sh);

                                var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, 20, 20);
                                var cr = new Cairo.Context(surface);
                                int x = (20 - sw) / 2;
                                int y = (20 - sh) / 2;
                                try { Gdk.cairo_set_source_pixbuf(cr, scaled_icon, x, y); cr.paint(); } catch (GLib.Error e) { }
                                var surf_key = "pixbuf::surface:icon:%s::%dx%d".printf(icon_path, 20, 20);
                                var pb_surf = ImageCache.get_global().get_or_from_surface(surf_key, surface, 0, 0, 20, 20);

                                var pic = new Gtk.Picture();
                                if (pb_surf != null) {
                                    try { pic.set_paintable(Gdk.Texture.for_pixbuf(pb_surf)); } catch (GLib.Error e) { }
                                }
                                pic.set_size_request(20, 20);

                                var logo_wrapper = new Gtk.Box(Orientation.HORIZONTAL, 0);
                                logo_wrapper.add_css_class("circular-logo");
                                logo_wrapper.set_size_request(20, 20);
                                logo_wrapper.set_valign(Gtk.Align.CENTER);
                                logo_wrapper.set_halign(Gtk.Align.CENTER);
                                logo_wrapper.append(pic);
                                box.append(logo_wrapper);
                                icon_loaded = true;
                            }
                        } catch (GLib.Error e) { }
                    }
                }

                // Fall back to loading from URL if file not found
                if (!icon_loaded && meta_logo_url != null && meta_logo_url.length > 0 &&
                    (meta_logo_url.has_prefix("http://") || meta_logo_url.has_prefix("https://"))) {
                    var logo_wrapper = new Gtk.Box(Orientation.HORIZONTAL, 0);
                    logo_wrapper.add_css_class("circular-logo");
                    logo_wrapper.set_size_request(20, 20);
                    logo_wrapper.set_valign(Gtk.Align.CENTER);
                    logo_wrapper.set_halign(Gtk.Align.CENTER);

                    var pic = new Gtk.Picture();
                    pic.set_size_request(20, 20);
                    pic.set_valign(Gtk.Align.CENTER);
                    pic.set_halign(Gtk.Align.CENTER);
                    try { if (win.image_handler != null) win.image_handler.load_image_async(pic, meta_logo_url, 20, 20); } catch (GLib.Error e) { }

                    logo_wrapper.append(pic);
                    box.append(logo_wrapper);
                    icon_loaded = true;
                }

                var lbl = new Gtk.Label(display_name);
                lbl.add_css_class("source-badge-label");
                lbl.set_valign(Gtk.Align.CENTER);
                lbl.set_xalign(0.5f);
                lbl.set_ellipsize(Pango.EllipsizeMode.END);
                lbl.set_max_width_chars(14);
                box.append(lbl);
                return box;
            }
        }

        // Check if this is a custom RSS source (fallback if source_info not found)
        if (provided_logo_url == null && category_id == "myfeed") {
            var rss_store = Paperboy.RssSourceStore.get_instance();
            var all_sources = rss_store.get_all_sources();
            foreach (var src in all_sources) {
                // Match by source_name (which comes from RSS feed) or by URL domain
                bool is_match = false;

                // First try matching by source name
                if (source_name != null && source_name == src.name) {
                    is_match = true;
                }

                // Also try matching by URL domain as fallback
                if (!is_match && url != null && url.length > 0) {
                    string src_host = UrlUtils.extract_host_from_url(src.url);
                    string article_host = UrlUtils.extract_host_from_url(url);
                    if (src_host != null && article_host != null && src_host == article_host) {
                        is_match = true;
                    }
                }

                if (is_match) {
                    // This article is from a custom RSS source
                    var box = new Gtk.Box(Orientation.HORIZONTAL, 6);
                    box.add_css_class("source-badge");
                    box.set_margin_bottom(8);
                    box.set_margin_end(8);
                    box.set_valign(Gtk.Align.END);
                    box.set_halign(Gtk.Align.END);

                    // Apply article pane source name logic for better display names
                    string final_display_name = src.name;
                    try {
                        var prefs = NewsPreferences.get_instance();
                        // Parse encoded source name (format: "SourceName||logo_url##category::cat")
                        string? explicit_source_name = src.name;
                        if (explicit_source_name != null && explicit_source_name.length > 0) {
                            int pipe_idx = explicit_source_name.index_of("||");
                            if (pipe_idx >= 0) {
                                explicit_source_name = explicit_source_name.substring(0, pipe_idx);
                            }
                            int cat_idx = explicit_source_name.index_of("##category::");
                            if (cat_idx >= 0) {
                                explicit_source_name = explicit_source_name.substring(0, cat_idx);
                            }
                            final_display_name = explicit_source_name;
                        }
                    } catch (GLib.Error e) { }

                    // Priority 1: Check source_info meta files first (from frontpage/topten)
                    bool icon_loaded = false;
                    string? meta_logo_url = SourceMetadata.get_logo_url_for_source(final_display_name);
                    string? meta_filename = SourceMetadata.get_saved_filename_for_source(final_display_name);

                    // Try to load from saved source_info file first
                    if (meta_filename != null) {
                        var data_dir = GLib.Environment.get_user_data_dir();
                        var icon_path = GLib.Path.build_filename(data_dir, "paperboy", "source_logos", meta_filename);
                        if (GLib.FileUtils.test(icon_path, GLib.FileTest.EXISTS)) {
                            try {
                                var probe = ImageCache.get_global().get_or_load_file("pixbuf::file:%s::%dx%d".printf(icon_path, 0, 0), icon_path, 0, 0);
                                if (probe != null) {
                                    int orig_w = 0; int orig_h = 0;
                                    try { orig_w = probe.get_width(); } catch (GLib.Error e) { orig_w = 0; }
                                    try { orig_h = probe.get_height(); } catch (GLib.Error e) { orig_h = 0; }
                                    double scale = 1.0;
                                    if (orig_w > 0 && orig_h > 0) scale = double.max(20.0 / orig_w, 20.0 / orig_h);
                                    int sw = (int)(orig_w * scale);
                                    int sh = (int)(orig_h * scale);
                                    if (sw < 1) sw = 1; if (sh < 1) sh = 1;

                                    var scaled_icon = ImageCache.get_global().get_or_load_file("pixbuf::file:%s::%dx%d".printf(icon_path, sw, sh), icon_path, sw, sh);

                                    var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, 20, 20);
                                    var cr = new Cairo.Context(surface);
                                    int x = (20 - sw) / 2;
                                    int y = (20 - sh) / 2;
                                    try { Gdk.cairo_set_source_pixbuf(cr, scaled_icon, x, y); cr.paint(); } catch (GLib.Error e) { }
                                    var surf_key = "pixbuf::surface:icon:%s::%dx%d".printf(icon_path, 20, 20);
                                    var pb_surf = ImageCache.get_global().get_or_from_surface(surf_key, surface, 0, 0, 20, 20);

                                    var pic = new Gtk.Picture();
                                    if (pb_surf != null) {
                                        try { pic.set_paintable(Gdk.Texture.for_pixbuf(pb_surf)); } catch (GLib.Error e) { }
                                    }
                                    pic.set_size_request(20, 20);

                                    var logo_wrapper = new Gtk.Box(Orientation.HORIZONTAL, 0);
                                    logo_wrapper.add_css_class("circular-logo");
                                    logo_wrapper.set_size_request(20, 20);
                                    logo_wrapper.set_valign(Gtk.Align.CENTER);
                                    logo_wrapper.set_halign(Gtk.Align.CENTER);
                                    logo_wrapper.append(pic);
                                    box.append(logo_wrapper);
                                    icon_loaded = true;
                                }
                            } catch (GLib.Error e) { }
                        }
                    }

                    // Priority 2: Try RSS icon_filename as fallback
                    if (!icon_loaded && src.icon_filename != null && src.icon_filename.length > 0) {
                        var data_dir = GLib.Environment.get_user_data_dir();
                        var icon_path = GLib.Path.build_filename(data_dir, "paperboy", "source_logos", src.icon_filename);
                        if (GLib.FileUtils.test(icon_path, GLib.FileTest.EXISTS)) {
                            try {
                                var probe = ImageCache.get_global().get_or_load_file("pixbuf::file:%s::%dx%d".printf(icon_path, 0, 0), icon_path, 0, 0);
                                if (probe != null) {
                                    int orig_w = 0; int orig_h = 0;
                                    try { orig_w = probe.get_width(); } catch (GLib.Error e) { orig_w = 0; }
                                    try { orig_h = probe.get_height(); } catch (GLib.Error e) { orig_h = 0; }
                                    double scale = 1.0;
                                    if (orig_w > 0 && orig_h > 0) scale = double.max(20.0 / orig_w, 20.0 / orig_h);
                                    int sw = (int)(orig_w * scale);
                                    int sh = (int)(orig_h * scale);
                                    if (sw < 1) sw = 1; if (sh < 1) sh = 1;

                                    var scaled_icon = ImageCache.get_global().get_or_load_file("pixbuf::file:%s::%dx%d".printf(icon_path, sw, sh), icon_path, sw, sh);

                                    var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, 20, 20);
                                    var cr = new Cairo.Context(surface);
                                    int x = (20 - sw) / 2;
                                    int y = (20 - sh) / 2;
                                    try { Gdk.cairo_set_source_pixbuf(cr, scaled_icon, x, y); cr.paint(); } catch (GLib.Error e) { }
                                    var surf_key = "pixbuf::surface:icon:%s::%dx%d".printf(icon_path, 20, 20);
                                    var pb_surf = ImageCache.get_global().get_or_from_surface(surf_key, surface, 0, 0, 20, 20);

                                    var pic = new Gtk.Picture();
                                    if (pb_surf != null) {
                                        try { pic.set_paintable(Gdk.Texture.for_pixbuf(pb_surf)); } catch (GLib.Error e) { }
                                    }
                                    pic.set_size_request(20, 20);

                                    var logo_wrapper = new Gtk.Box(Orientation.HORIZONTAL, 0);
                                    logo_wrapper.add_css_class("circular-logo");
                                    logo_wrapper.set_size_request(20, 20);
                                    logo_wrapper.set_valign(Gtk.Align.CENTER);
                                    logo_wrapper.set_halign(Gtk.Align.CENTER);
                                    logo_wrapper.append(pic);
                                    box.append(logo_wrapper);
                                    icon_loaded = true;
                                }
                            } catch (GLib.Error e) { }
                        }
                    }

                    // Priority 3: Last resort - use RSS favicon_url
                    if (!icon_loaded && src.favicon_url != null && src.favicon_url.length > 0 &&
                        (src.favicon_url.has_prefix("http://") || src.favicon_url.has_prefix("https://"))) {
                        var logo_wrapper = new Gtk.Box(Orientation.HORIZONTAL, 0);
                        logo_wrapper.add_css_class("circular-logo");
                        logo_wrapper.set_size_request(20, 20);
                        logo_wrapper.set_valign(Gtk.Align.CENTER);
                        logo_wrapper.set_halign(Gtk.Align.CENTER);

                        var pic = new Gtk.Picture();
                        pic.set_size_request(20, 20);
                        pic.set_valign(Gtk.Align.CENTER);
                        pic.set_halign(Gtk.Align.CENTER);
                        try { if (win.image_handler != null) win.image_handler.load_image_async(pic, src.favicon_url, 20, 20); } catch (GLib.Error e) { }

                        logo_wrapper.append(pic);
                        box.append(logo_wrapper);
                        icon_loaded = true;
                    }

                    var lbl = new Gtk.Label(final_display_name);
                    lbl.add_css_class("source-badge-label");
                    lbl.set_valign(Gtk.Align.CENTER);
                    lbl.set_xalign(0.5f);
                    lbl.set_ellipsize(Pango.EllipsizeMode.END);
                    lbl.set_max_width_chars(14);
                    box.append(lbl);
                    return box;
                }
            }
        }


        // If the API did not provide an explicit logo URL and the name maps to a known source,
        // reuse the bundled badge.
        if (provided_logo_url == null && display_name != null && display_name.length > 0) {
            // Try to resolve to built-in sources by simple substring matching
            string low = display_name.down();
            NewsSource? resolved = null; // Don't fallback to user preference
            if (low.index_of("guardian") >= 0) resolved = NewsSource.GUARDIAN;
            else if (low.index_of("bbc") >= 0) resolved = NewsSource.BBC;
            else if (low.index_of("reddit") >= 0) resolved = NewsSource.REDDIT;
            else if (low.index_of("nytimes") >= 0 || low.index_of("new york") >= 0) resolved = NewsSource.NEW_YORK_TIMES;
            else if (low.index_of("wsj") >= 0 || low.index_of("wall street") >= 0) resolved = NewsSource.WALL_STREET_JOURNAL;
            else if (low.index_of("bloomberg") >= 0) resolved = NewsSource.BLOOMBERG;
            else if (low.index_of("reuters") >= 0) resolved = NewsSource.REUTERS;
            else if (low.index_of("npr") >= 0) resolved = NewsSource.NPR;
            else if (low.index_of("fox") >= 0) resolved = NewsSource.FOX;

            // Only use bundled badge if we have a positive match
            if (resolved != null) {
                string? icon_path = null;
                string? fname = source_icon_filename(resolved);
                if (fname != null) icon_path = DataPaths.find_data_file("icons/" + fname);
                if (icon_path != null) return build_source_badge(resolved);
            }
        }

        // Check source_info meta files for logo data (for frontpage/topten/myfeed articles)
        // This should happen BEFORE the text-only fallback to ensure we use saved logos
        if (provided_logo_url == null && display_name != null && display_name.length > 0) {
            // Try to get logo URL from meta files first
            string? meta_logo_url = SourceMetadata.get_logo_url_for_source(display_name);
            string? meta_filename = SourceMetadata.get_saved_filename_for_source(display_name);
            
            if (meta_logo_url != null || meta_filename != null) {
                var box = new Gtk.Box(Orientation.HORIZONTAL, 6);
                box.add_css_class("source-badge");
                box.set_margin_bottom(8);
                box.set_margin_end(8);
                box.set_valign(Gtk.Align.END);
                box.set_halign(Gtk.Align.END);

                bool icon_loaded = false;

                // Try to load from saved file first
                if (meta_filename != null) {
                    var data_dir = GLib.Environment.get_user_data_dir();
                    var icon_path = GLib.Path.build_filename(data_dir, "paperboy", "source_logos", meta_filename);
                    if (GLib.FileUtils.test(icon_path, GLib.FileTest.EXISTS)) {
                        try {
                            var probe = ImageCache.get_global().get_or_load_file("pixbuf::file:%s::%dx%d".printf(icon_path, 0, 0), icon_path, 0, 0);
                            if (probe != null) {
                                int orig_w = 0; int orig_h = 0;
                                try { orig_w = probe.get_width(); } catch (GLib.Error e) { orig_w = 0; }
                                try { orig_h = probe.get_height(); } catch (GLib.Error e) { orig_h = 0; }
                                double scale = 1.0;
                                if (orig_w > 0 && orig_h > 0) scale = double.max(20.0 / orig_w, 20.0 / orig_h);
                                int sw = (int)(orig_w * scale);
                                int sh = (int)(orig_h * scale);
                                if (sw < 1) sw = 1; if (sh < 1) sh = 1;

                                var scaled_icon = ImageCache.get_global().get_or_load_file("pixbuf::file:%s::%dx%d".printf(icon_path, sw, sh), icon_path, sw, sh);

                                var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, 20, 20);
                                var cr = new Cairo.Context(surface);
                                int x = (20 - sw) / 2;
                                int y = (20 - sh) / 2;
                                try { Gdk.cairo_set_source_pixbuf(cr, scaled_icon, x, y); cr.paint(); } catch (GLib.Error e) { }
                                var surf_key = "pixbuf::surface:icon:%s::%dx%d".printf(icon_path, 20, 20);
                                var pb_surf = ImageCache.get_global().get_or_from_surface(surf_key, surface, 0, 0, 20, 20);

                                var pic = new Gtk.Picture();
                                if (pb_surf != null) {
                                    try { pic.set_paintable(Gdk.Texture.for_pixbuf(pb_surf)); } catch (GLib.Error e) { }
                                }
                                pic.set_size_request(20, 20);

                                var logo_wrapper = new Gtk.Box(Orientation.HORIZONTAL, 0);
                                logo_wrapper.add_css_class("circular-logo");
                                logo_wrapper.set_size_request(20, 20);
                                logo_wrapper.set_valign(Gtk.Align.CENTER);
                                logo_wrapper.set_halign(Gtk.Align.CENTER);
                                logo_wrapper.append(pic);
                                box.append(logo_wrapper);
                                icon_loaded = true;
                            }
                        } catch (GLib.Error e) { }
                    }
                }

                // Fall back to loading from URL if file not found
                if (!icon_loaded && meta_logo_url != null && meta_logo_url.length > 0 &&
                    (meta_logo_url.has_prefix("http://") || meta_logo_url.has_prefix("https://"))) {
                    var logo_wrapper = new Gtk.Box(Orientation.HORIZONTAL, 0);
                    logo_wrapper.add_css_class("circular-logo");
                    logo_wrapper.set_size_request(20, 20);
                    logo_wrapper.set_valign(Gtk.Align.CENTER);
                    logo_wrapper.set_halign(Gtk.Align.CENTER);

                    var pic = new Gtk.Picture();
                    pic.set_size_request(20, 20);
                    pic.set_valign(Gtk.Align.CENTER);
                    pic.set_halign(Gtk.Align.CENTER);
                    try { if (win.image_handler != null) win.image_handler.load_image_async(pic, meta_logo_url, 20, 20); } catch (GLib.Error e) { }

                    logo_wrapper.append(pic);
                    box.append(logo_wrapper);
                    icon_loaded = true;
                }

                var lbl = new Gtk.Label(display_name);
                lbl.add_css_class("source-badge-label");
                lbl.set_valign(Gtk.Align.CENTER);
                lbl.set_xalign(0.5f);
                lbl.set_ellipsize(Pango.EllipsizeMode.END);
                lbl.set_max_width_chars(14);
                box.append(lbl);
                return box;
            }
        }

        // Text-only badge for aggregated views when no logo is available
        bool is_aggregated = (category_id != null && (category_id == "frontpage" || category_id == "topten" || category_id == "myfeed"));
        if (is_aggregated && display_name != null && display_name.length > 0 && provided_logo_url == null) {
            var box = new Gtk.Box(Orientation.HORIZONTAL, 6);
            box.add_css_class("source-badge");
            box.set_margin_bottom(8);
            box.set_margin_end(8);
            box.set_valign(Gtk.Align.END);
            box.set_halign(Gtk.Align.END);

            var lbl = new Gtk.Label(display_name);
            lbl.add_css_class("source-badge-label");
            lbl.set_valign(Gtk.Align.CENTER);
            lbl.set_xalign(0.5f);
            lbl.set_ellipsize(Pango.EllipsizeMode.END);
            lbl.set_max_width_chars(14);
            box.append(lbl);
            return box;
        }

        // If an explicit remote logo URL is provided, use it
        if (provided_logo_url != null) {
            provided_logo_url = provided_logo_url.strip();
            if (provided_logo_url.has_prefix("//")) provided_logo_url = "https:" + provided_logo_url;
        }

        if (provided_logo_url != null && (provided_logo_url.has_prefix("http://") || provided_logo_url.has_prefix("https://"))) {
            var box = new Gtk.Box(Orientation.HORIZONTAL, 6);
            box.add_css_class("source-badge");
            box.set_margin_bottom(8);
            box.set_margin_end(8);
            box.set_valign(Gtk.Align.END);
            box.set_halign(Gtk.Align.END);

            var logo_wrapper = new Gtk.Box(Orientation.HORIZONTAL, 0);
            logo_wrapper.add_css_class("circular-logo");
            logo_wrapper.set_size_request(20, 20);
            logo_wrapper.set_valign(Gtk.Align.CENTER);
            logo_wrapper.set_halign(Gtk.Align.CENTER);

            var pic = new Gtk.Picture();
            pic.set_size_request(20, 20);
            pic.set_valign(Gtk.Align.CENTER);
            pic.set_halign(Gtk.Align.CENTER);
            try { if (win.image_handler != null) win.image_handler.load_image_async(pic, provided_logo_url, 20, 20); } catch (GLib.Error e) { }

            logo_wrapper.append(pic);
            box.append(logo_wrapper);

            var lbl = new Gtk.Label(display_name != null && display_name.length > 0 ? display_name : source_name);
            lbl.add_css_class("source-badge-label");
            lbl.set_valign(Gtk.Align.CENTER);
            lbl.set_xalign(0.5f);
            lbl.set_ellipsize(Pango.EllipsizeMode.END);
            lbl.set_max_width_chars(14);
            box.append(lbl);
            return box;
        }

        // Try local icon candidates derived from display_name
        if (display_name != null && display_name.length > 0) {
            // Build simple candidates: hyphen, underscore, concat
            string low = display_name.down();
            var sb = new StringBuilder();
            for (int i = 0; i < low.length; i++) {
                char c = low[i];
                if (c.isalnum() || c == ' ' || c == '-' || c == '_') sb.append_c(c);
                else sb.append_c(' ');
            }
            string cleaned = sb.str.strip();
            string hyphen = cleaned.replace(" ", "-").replace("--", "-");
            string underscore = cleaned.replace(" ", "_").replace("__", "_");
            string concat = cleaned.replace(" ", "");
            string[] cands = { hyphen, underscore, concat };
            foreach (var cand in cands) {
                string[] paths = {
                    GLib.Path.build_filename("icons", cand + "-logo.png"),
                    GLib.Path.build_filename("icons", cand + "-logo.svg"),
                    GLib.Path.build_filename("icons", "symbolic", cand + "-symbolic.svg"),
                    GLib.Path.build_filename("icons", cand + ".png"),
                    GLib.Path.build_filename("icons", cand + ".svg")
                };
                foreach (var rel in paths) {
                    string? full = DataPaths.find_data_file(rel);
                    if (full != null) {
                        var box = new Gtk.Box(Orientation.HORIZONTAL, 6);
                        box.add_css_class("source-badge");
                        box.set_margin_bottom(8);
                        box.set_margin_end(8);
                        box.set_valign(Gtk.Align.END);
                        box.set_halign(Gtk.Align.END);
                        try {
                                // Centralize file loading and scaling in ImageCache
                                var probe = ImageCache.get_global().get_or_load_file("pixbuf::file:%s::%dx%d".printf(full, 0, 0), full, 0, 0);
                                if (probe != null) {
                                    int orig_w = 0; int orig_h = 0;
                                    try { orig_w = probe.get_width(); } catch (GLib.Error e) { orig_w = 0; }
                                    try { orig_h = probe.get_height(); } catch (GLib.Error e) { orig_h = 0; }
                                    double scale = 1.0;
                                    if (orig_w > 0 && orig_h > 0) scale = double.max(20.0 / orig_w, 20.0 / orig_h);
                                    int sw = (int)(orig_w * scale);
                                    int sh = (int)(orig_h * scale);
                                    if (sw < 1) sw = 1; if (sh < 1) sh = 1;

                                    var scaled_icon = ImageCache.get_global().get_or_load_file("pixbuf::file:%s::%dx%d".printf(full, sw, sh), full, sw, sh);

                                    var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, 20, 20);
                                    var cr = new Cairo.Context(surface);
                                    int x = (20 - sw) / 2;
                                    int y = (20 - sh) / 2;
                                    try { Gdk.cairo_set_source_pixbuf(cr, scaled_icon, x, y); cr.paint(); } catch (GLib.Error e) { }
                                    var surf_key = "pixbuf::surface:icon:%s::%dx%d".printf(full, 20, 20);
                                    var pb_surf = ImageCache.get_global().get_or_from_surface(surf_key, surface, 0, 0, 20, 20);

                                    Gdk.Pixbuf? final_pb = pb_surf;

                                    var pic = new Gtk.Picture();
                                    if (final_pb != null) {
                                        try { pic.set_paintable(Gdk.Texture.for_pixbuf(final_pb)); } catch (GLib.Error e) { }
                                    }
                                    pic.set_size_request(20, 20);

                                var logo_wrapper = new Gtk.Box(Orientation.HORIZONTAL, 0);
                                logo_wrapper.add_css_class("circular-logo");
                                logo_wrapper.set_size_request(20, 20);
                                logo_wrapper.set_valign(Gtk.Align.CENTER);
                                logo_wrapper.set_halign(Gtk.Align.CENTER);
                                logo_wrapper.append(pic);
                                box.append(logo_wrapper);
                            }
                        } catch (GLib.Error e) { }

                        var lbl = new Gtk.Label(display_name != null && display_name.length > 0 ? display_name : source_name);
                        lbl.add_css_class("source-badge-label");
                        lbl.set_valign(Gtk.Align.CENTER);
                        lbl.set_xalign(0.5f);
                        lbl.set_ellipsize(Pango.EllipsizeMode.END);
                        lbl.set_max_width_chars(14);
                        box.append(lbl);
                        return box;
                    }
                }
            }
        }

        var box_fallback = new Gtk.Box(Orientation.HORIZONTAL, 6);
        box_fallback.add_css_class("source-badge");
        box_fallback.set_margin_bottom(8);
        box_fallback.set_margin_end(8);
        box_fallback.set_valign(Gtk.Align.END);
        box_fallback.set_halign(Gtk.Align.END);
        var lbl_f = new Gtk.Label(display_name != null && display_name.length > 0 ? display_name : (source_name != null && source_name.length > 0 ? source_name : "News"));
        lbl_f.add_css_class("source-badge-label");
        lbl_f.set_valign(Gtk.Align.CENTER);
        lbl_f.set_xalign(0.5f);
        lbl_f.set_ellipsize(Pango.EllipsizeMode.END);
        lbl_f.set_max_width_chars(14);
        box_fallback.append(lbl_f);
        return box_fallback;
    }

    public static Gtk.Widget build_viewed_badge() {
        var box = new Gtk.Box(Orientation.HORIZONTAL, 6);
        box.add_css_class("viewed-badge");
        box.set_valign(Gtk.Align.START);
        box.set_halign(Gtk.Align.END);
        box.set_margin_top(8);
        box.set_margin_end(8);

        try {
            var icon = new Gtk.Image.from_icon_name("emblem-ok-symbolic");
            try { icon.set_pixel_size(12); } catch (GLib.Error e) { }
            try { icon.get_style_context().add_class("viewed-badge-icon"); } catch (GLib.Error e) { }
            try { icon.set_valign(Gtk.Align.CENTER); icon.set_halign(Gtk.Align.CENTER); } catch (GLib.Error e) { }
            box.append(icon);
        } catch (GLib.Error e) { }

        var lbl = new Gtk.Label("Viewed");
        try { lbl.get_style_context().remove_class("dim-label"); } catch (GLib.Error e) { }
        lbl.add_css_class("viewed-badge-label");
        lbl.add_css_class("caption");
        box.append(lbl);
        return box;
    }
}
