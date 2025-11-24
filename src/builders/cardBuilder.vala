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
        var chip = new Gtk.Label(win.category_display_name_for(category_id));
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

        // If the API did not provide an explicit logo URL and the name maps to a known source,
        // reuse the bundled badge.
        if (provided_logo_url == null && display_name != null && display_name.length > 0) {
            // Try to resolve to built-in sources by simple substring matching
            string low = display_name.down();
            NewsSource resolved = win.prefs.news_source; // fallback
            if (low.index_of("guardian") >= 0) resolved = NewsSource.GUARDIAN;
            else if (low.index_of("bbc") >= 0) resolved = NewsSource.BBC;
            else if (low.index_of("reddit") >= 0) resolved = NewsSource.REDDIT;
            else if (low.index_of("nytimes") >= 0 || low.index_of("new york") >= 0) resolved = NewsSource.NEW_YORK_TIMES;
            else if (low.index_of("wsj") >= 0 || low.index_of("wall street") >= 0) resolved = NewsSource.WALL_STREET_JOURNAL;
            else if (low.index_of("bloomberg") >= 0) resolved = NewsSource.BLOOMBERG;
            else if (low.index_of("reuters") >= 0) resolved = NewsSource.REUTERS;
            else if (low.index_of("npr") >= 0) resolved = NewsSource.NPR;
            else if (low.index_of("fox") >= 0) resolved = NewsSource.FOX;

            string? icon_path = null;
            string? fname = source_icon_filename(resolved);
            if (fname != null) icon_path = DataPaths.find_data_file("icons/" + fname);
            if (icon_path != null) return build_source_badge(resolved);
        }

        bool is_aggregated = (category_id != null && (category_id == "frontpage" || category_id == "topten"));
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
