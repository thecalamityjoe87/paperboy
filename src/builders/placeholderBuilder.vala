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
using Cairo;
using Gdk;

public class PlaceholderBuilder : GLib.Object {

    // Create a simple gradient-based "no image" placeholder with icon
    public static void create_gradient_placeholder(Gtk.Picture image, int width, int height) {
        try {
            var surface = new ImageSurface(Format.RGB24, width, height);
            var cr = new Context(surface);

            // Light gray gradient background
            var pattern = new Pattern.linear(0, 0, width, height);
            pattern.add_color_stop_rgb(0, 0.9, 0.9, 0.9);
            pattern.add_color_stop_rgb(1, 0.8, 0.8, 0.8);
            cr.set_source(pattern);
            cr.paint();

            // Try to load and display the no-image.png icon
            string? icon_path = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "no-image.png"));
            if (icon_path != null) {
                    // Calculate target icon size (40% of placeholder)
                    double max_size = double.min(width, height) * 0.4;
                    int target_w = (int)max_size;
                    int target_h = (int)max_size;
                    if (target_w < 1) target_w = 1;
                    if (target_h < 1) target_h = 1;

                    // Load the icon
                var icon_pixbuf = ImageCache.get_global().get_or_load_file("pixbuf::file:%s::%dx%d".printf(icon_path, 0, 0), icon_path, 0, 0);
                if (icon_pixbuf != null) {
                    int orig_w = icon_pixbuf.get_width();
                    int orig_h = icon_pixbuf.get_height();

                        // Scale down if needed
                        int scaled_w = orig_w;
                        int scaled_h = orig_h;
                        if (orig_w > target_w || orig_h > target_h) {
                            double scale = double.min((double)target_w / (double)orig_w, (double)target_h / (double)orig_h);
                            scaled_w = (int)(orig_w * scale);
                            scaled_h = (int)(orig_h * scale);
                            if (scaled_w < 1) scaled_w = 1;
                            if (scaled_h < 1) scaled_h = 1;
                        }

                        Gdk.Pixbuf? scaled_icon = null;
                        if (scaled_w != orig_w || scaled_h != orig_h) {
                            scaled_icon = ImageCache.get_global().get_or_load_file("pixbuf::file:%s::%dx%d".printf(icon_path, scaled_w, scaled_h), icon_path, scaled_w, scaled_h);
                        } else {
                            scaled_icon = icon_pixbuf;
                        }

                        // Center the icon
                        int x = (width - scaled_w) / 2;
                        int y = (height - scaled_h) / 2;
                        if (scaled_icon != null) {
                            Gdk.cairo_set_source_pixbuf(cr, scaled_icon, x, y);
                            cr.paint_with_alpha(0.7);
                        }
                    }
            }

            // Cache gradient placeholder pixbuf by size so it's managed centrally
            string key = "pixbuf::placeholder:gradient::%dx%d".printf(width, height);
            var cached = ImageCache.get_global().get(key);
            if (cached == null) cached = ImageCache.get_global().get_or_from_surface(key, surface, 0, 0, width, height);
            // Use get_texture() to reuse cached texture and avoid GPU memory leak
            var tex = ImageCache.get_global().get_texture(key);
            if (tex != null) image.set_paintable(tex);
        } catch (GLib.Error e) {
            // best-effort: leave image blank on error
        }
    }

    // Draw a branded icon-centered placeholder for a specific source
    public static void create_icon_placeholder(Gtk.Picture image, string icon_path, NewsSource source, int width, int height) {
        try {
            var surface = new ImageSurface(Format.ARGB32, width, height);
            var cr = new Context(surface);

            var gradient = new Pattern.linear(0, 0, 0, height);
            switch (source) {
                case NewsSource.GUARDIAN:
                    gradient.add_color_stop_rgb(0, 0.0, 0.2, 0.4);
                    gradient.add_color_stop_rgb(1, 0.0, 0.4, 0.6);
                    break;
                case NewsSource.BBC:
                    gradient.add_color_stop_rgb(0, 0.6, 0.0, 0.0);
                    gradient.add_color_stop_rgb(1, 0.8, 0.1, 0.1);
                    break;
                case NewsSource.REDDIT:
                    gradient.add_color_stop_rgb(0, 1.0, 0.2, 0.0);
                    gradient.add_color_stop_rgb(1, 1.0, 0.4, 0.1);
                    break;
                case NewsSource.NEW_YORK_TIMES:
                    gradient.add_color_stop_rgb(0, 0.1, 0.1, 0.1);
                    gradient.add_color_stop_rgb(1, 0.3, 0.3, 0.3);
                    break;
                case NewsSource.BLOOMBERG:
                    gradient.add_color_stop_rgb(0, 0.0, 0.3, 0.7);
                    gradient.add_color_stop_rgb(1, 0.1, 0.5, 0.9);
                    break;
                case NewsSource.REUTERS:
                    gradient.add_color_stop_rgb(0, 0.3, 0.3, 0.4);
                    gradient.add_color_stop_rgb(1, 0.5, 0.5, 0.6);
                    break;
                case NewsSource.NPR:
                    gradient.add_color_stop_rgb(0, 0.1, 0.2, 0.5);
                    gradient.add_color_stop_rgb(1, 0.2, 0.3, 0.7);
                    break;
                case NewsSource.FOX:
                    gradient.add_color_stop_rgb(0, 0.0, 0.2, 0.6);
                    gradient.add_color_stop_rgb(1, 0.1, 0.3, 0.8);
                    break;
                case NewsSource.UNKNOWN:
                    gradient.add_color_stop_rgb(0, 0.9, 0.9, 0.9);
                    gradient.add_color_stop_rgb(1, 0.8, 0.8, 0.8);
                    break;
                default:
                    gradient.add_color_stop_rgb(0, 0.3, 0.3, 0.4);
                    gradient.add_color_stop_rgb(1, 0.5, 0.5, 0.6);
                    break;
            }

            cr.set_source(gradient);
            cr.rectangle(0, 0, width, height);
            cr.fill();

            // Load icon and request a scaled variant from ImageCache
            // Check if this is an SVG (vector) or raster icon
            string ipath = icon_path != null ? icon_path : "";
            bool is_svg = ipath.down().has_suffix(".svg");

            // Calculate target icon size (50% of placeholder)
            double max_size = double.min(width, height) * 0.5;
            int target_w = (int)max_size;
            int target_h = (int)max_size;
            if (target_w < 1) target_w = 1;
            if (target_h < 1) target_h = 1;

            // For SVG: load directly at target size; for PNG: load original then scale
            Gdk.Pixbuf? probe;
            if (is_svg) {
                probe = ImageCache.get_global().get_or_load_file("pixbuf::file:%s::%dx%d".printf(icon_path, target_w, target_h), icon_path, target_w, target_h);
            } else {
                probe = ImageCache.get_global().get_or_load_file("pixbuf::file:%s::%dx%d".printf(icon_path, 0, 0), icon_path, 0, 0);
            }

            if (probe != null) {
                int orig_w = 0; int orig_h = 0;
                try { orig_w = probe.get_width(); } catch (GLib.Error e) { orig_w = 0; }
                try { orig_h = probe.get_height(); } catch (GLib.Error e) { orig_h = 0; }

                // For raster icons, scale down if needed (never upscale)
                int scaled_w = orig_w;
                int scaled_h = orig_h;
                if (!is_svg && orig_w > 0 && orig_h > 0 && (orig_w > target_w || orig_h > target_h)) {
                    double scale = double.min((double)target_w / (double)orig_w, (double)target_h / (double)orig_h);
                    scaled_w = (int)(orig_w * scale);
                    scaled_h = (int)(orig_h * scale);
                    if (scaled_w < 1) scaled_w = 1;
                    if (scaled_h < 1) scaled_h = 1;
                }

                Gdk.Pixbuf? scaled_icon;
                if (scaled_w != orig_w || scaled_h != orig_h) {
                    scaled_icon = ImageCache.get_global().get_or_load_file("pixbuf::file:%s::%dx%d".printf(icon_path, scaled_w, scaled_h), icon_path, scaled_w, scaled_h);
                } else {
                    scaled_icon = probe;
                }
                int x = (width - scaled_w) / 2;
                int y = (height - scaled_h) / 2;
                cr.save();
                cr.set_source_rgba(1, 1, 1, 0.9);
                if (scaled_icon != null) {
                    Gdk.cairo_set_source_pixbuf(cr, scaled_icon, x, y);
                    cr.paint_with_alpha(0.95);
                }
                cr.restore();
            }

            // Cache surface-derived placeholder so it's managed by ImageCache
            string key = "pixbuf::placeholder:icon:%s::%dx%d".printf(icon_path, width, height);
            var cached = ImageCache.get_global().get(key);
            if (cached == null) cached = ImageCache.get_global().get_or_from_surface(key, surface, 0, 0, width, height);
            // Use get_texture() to reuse cached texture and avoid GPU memory leak
            var tex = ImageCache.get_global().get_texture(key);
            if (tex != null) image.set_paintable(tex);
        } catch (GLib.Error e) {
            // Fallback to text-based placeholder
            string src = "News Source";
            try { src = PlaceholderBuilder.get_source_name(source); } catch (GLib.Error ee) { }
            PlaceholderBuilder.create_source_text_placeholder(image, src, source, width, height);
        }
    }

    // Create a text-based placeholder using a brand gradient and name
    public static void create_source_text_placeholder(Gtk.Picture image, string source_name, NewsSource source, int width, int height) {
        try {
            var surface = new ImageSurface(Format.ARGB32, width, height);
            var cr = new Context(surface);
            var gradient = new Pattern.linear(0, 0, 0, height);
            switch (source) {
                case NewsSource.GUARDIAN:
                    gradient.add_color_stop_rgb(0, 0.0, 0.3, 0.6);
                    gradient.add_color_stop_rgb(1, 0.0, 0.5, 0.8);
                    break;
                case NewsSource.BBC:
                    gradient.add_color_stop_rgb(0, 0.7, 0.0, 0.0);
                    gradient.add_color_stop_rgb(1, 0.9, 0.2, 0.2);
                    break;
                case NewsSource.REDDIT:
                    gradient.add_color_stop_rgb(0, 1.0, 0.3, 0.0);
                    gradient.add_color_stop_rgb(1, 1.0, 0.5, 0.2);
                    break;
                case NewsSource.NEW_YORK_TIMES:
                    gradient.add_color_stop_rgb(0, 0.0, 0.0, 0.0);
                    gradient.add_color_stop_rgb(1, 0.2, 0.2, 0.2);
                    break;
                case NewsSource.BLOOMBERG:
                    gradient.add_color_stop_rgb(0, 0.0, 0.4, 0.8);
                    gradient.add_color_stop_rgb(1, 0.2, 0.6, 1.0);
                    break;
                case NewsSource.REUTERS:
                    gradient.add_color_stop_rgb(0, 0.4, 0.4, 0.4);
                    gradient.add_color_stop_rgb(1, 0.6, 0.6, 0.6);
                    break;
                case NewsSource.NPR:
                    gradient.add_color_stop_rgb(0, 0.2, 0.2, 0.6);
                    gradient.add_color_stop_rgb(1, 0.4, 0.4, 0.8);
                    break;
                case NewsSource.FOX:
                    gradient.add_color_stop_rgb(0, 0.0, 0.3, 0.7);
                    gradient.add_color_stop_rgb(1, 0.2, 0.5, 0.9);
                    break;
                case NewsSource.UNKNOWN:
                    gradient.add_color_stop_rgb(0, 0.9, 0.9, 0.9);
                    gradient.add_color_stop_rgb(1, 0.8, 0.8, 0.8);
                    break;
                default:
                    gradient.add_color_stop_rgb(0, 0.4, 0.4, 0.4);
                    gradient.add_color_stop_rgb(1, 0.6, 0.6, 0.6);
                    break;
            }
            cr.set_source(gradient);
            cr.rectangle(0, 0, width, height);
            cr.fill();

            cr.select_font_face("Sans", FontSlant.NORMAL, FontWeight.BOLD);
            double font_size = double.min(width / 8.0, height / 4.0);
            font_size = double.max(font_size, 12.0);
            cr.set_font_size(font_size);
            TextExtents extents;
            cr.text_extents(source_name, out extents);
            double x = (width - extents.width) / 2;
            double y = (height + extents.height) / 2;
            cr.set_source_rgba(0, 0, 0, 0.5);
            cr.move_to(x + 2, y + 2);
            cr.show_text(source_name);
            cr.set_source_rgba(1, 1, 1, 0.9);
            cr.move_to(x, y);
            cr.show_text(source_name);
            string key = "pixbuf::placeholder:text:%s::%dx%d".printf(source_name, width, height);
            var cached = ImageCache.get_global().get(key);
            if (cached == null) cached = ImageCache.get_global().get_or_from_surface(key, surface, 0, 0, width, height);
            // Use get_texture() to reuse cached texture and avoid GPU memory leak
            var tex = ImageCache.get_global().get_texture(key);
            if (tex != null) image.set_paintable(tex);
        } catch (GLib.Error e) {
            // As last resort fall back to a simple gradient
            PlaceholderBuilder.create_gradient_placeholder(image, width, height);
        }
    }

    // Public wrapper to pick icon vs text based on available icon path
    public static void set_placeholder_image_for_source(Gtk.Picture image, int width, int height, NewsSource source) {
        string? icon_path = PlaceholderBuilder.get_source_icon_path(source);
        string source_name = PlaceholderBuilder.get_source_name(source);
        if (icon_path != null) {
            PlaceholderBuilder.create_icon_placeholder(image, icon_path, source, width, height);
        } else {
            PlaceholderBuilder.create_source_text_placeholder(image, source_name, source, width, height);
        }
    }

    // Local-news specific placeholder
    public static void set_local_placeholder_image(Gtk.Picture image, int width, int height) {
        try {
            string? local_icon = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "symbolic", "local-mono.svg"));
            if (local_icon == null) local_icon = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "local-mono.svg"));
            string? use_path = local_icon;
            if (use_path != null) {
                var sm = Adw.StyleManager.get_default();
                if (sm != null && sm.dark) {
                    string? white_cand = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "symbolic", "local-mono-white.svg"));
                    if (white_cand == null) white_cand = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "local-mono-white.svg"));
                    if (white_cand != null) use_path = white_cand;
                }

                // Check if this is an SVG (vector) or raster icon
                string upath = use_path != null ? use_path : "";
                bool is_svg = upath.down().has_suffix(".svg");

                // Calculate target icon size (50% of placeholder)
                double max_icon = double.min(width, height) * 0.5;
                int target_w = (int)max_icon;
                int target_h = (int)max_icon;
                if (target_w < 1) target_w = 1;
                if (target_h < 1) target_h = 1;

                // For SVG: load directly at target size to avoid rasterization artifacts
                // For PNG: load original then scale down if needed
                Gdk.Pixbuf? icon_pix = null;
                if (is_svg) {
                    icon_pix = ImageCache.get_global().get_or_load_file("pixbuf::file:%s::%dx%d".printf(use_path, target_w, target_h), use_path, target_w, target_h);
                } else {
                    icon_pix = ImageCache.get_global().get_or_load_file("pixbuf::file:%s::%dx%d".printf(use_path, 0, 0), use_path, 0, 0);
                }

                if (icon_pix != null) {
                    int orig_w = icon_pix.get_width();
                    int orig_h = icon_pix.get_height();

                    // For raster icons, scale down if needed (never upscale)
                    int scaled_w = orig_w;
                    int scaled_h = orig_h;
                    if (!is_svg && (orig_w > target_w || orig_h > target_h)) {
                        double scale = double.min((double)target_w / (double)orig_w, (double)target_h / (double)orig_h);
                        scaled_w = (int)(orig_w * scale);
                        scaled_h = (int)(orig_h * scale);
                        if (scaled_w < 1) scaled_w = 1;
                        if (scaled_h < 1) scaled_h = 1;
                    }

                    Gdk.Pixbuf? scaled = null;
                    if (scaled_w != orig_w || scaled_h != orig_h) {
                        scaled = ImageCache.get_global().get_or_scale_pixbuf("pixbuf::file:%s::%dx%d".printf(use_path, scaled_w, scaled_h), icon_pix, scaled_w, scaled_h);
                    } else {
                        scaled = icon_pix;
                    }

                    var surface = new ImageSurface(Format.ARGB32, width, height);
                    var cr = new Context(surface);
                    var pattern = new Pattern.linear(0, 0, 0, height);
                    pattern.add_color_stop_rgb(0, 0.80, 0.90, 0.98);
                    pattern.add_color_stop_rgb(1, 0.70, 0.84, 0.98);
                    cr.set_source(pattern);
                    cr.rectangle(0, 0, width, height);
                    cr.fill();

                    int x = (width - scaled_w) / 2;
                    int y = (height - scaled_h) / 2;
                    cr.save();
                    if (scaled != null) Gdk.cairo_set_source_pixbuf(cr, scaled, x, y);
                    cr.paint_with_alpha(0.95);
                    cr.restore();

                    string key = "pixbuf::placeholder:local:" + use_path + "::" + width.to_string() + "x" + height.to_string();
                    var cached = ImageCache.get_global().get(key);
                    if (cached == null) cached = ImageCache.get_global().get_or_from_surface(key, surface, 0, 0, width, height);
                    if (cached != null) image.set_paintable(Gdk.Texture.for_pixbuf(cached));
                    return;
                }
            }
        } catch (GLib.Error e) { }
        // Fallback
        PlaceholderBuilder.create_gradient_placeholder(image, width, height);
    }

    // Compose a subtle logo-on-gradient placeholder from an already-loaded Pixbuf
    public static void create_logo_placeholder(Gtk.Picture image, Gdk.Pixbuf logo, int width, int height) {
        try {
            var surface = new ImageSurface(Format.ARGB32, width, height);
            var cr = new Context(surface);

            // Subtle gradient background
            var pattern = new Pattern.linear(0, 0, width, height);
            pattern.add_color_stop_rgb(0, 0.95, 0.95, 0.97);
            pattern.add_color_stop_rgb(1, 0.88, 0.88, 0.92);
            cr.set_source(pattern);
            cr.paint();

            // Scale the logo to a sensible fraction of the placeholder area
            int logo_w = logo.get_width();
            int logo_h = logo.get_height();
            double max_size = double.min(width, height) * 0.5; // aim for up to 50%

            double scale = 1.0;
            if (logo_w > 0 && logo_h > 0) {
                scale = double.min(max_size / (double)logo_w, max_size / (double)logo_h);
            }
            // Prevent upscaling raster logos to avoid blurriness
            // (logos passed here are typically raster images)
            if (scale > 1.0) {
                scale = 1.0;
            }

            int draw_w = logo_w;
            int draw_h = logo_h;
            Gdk.Pixbuf? draw_pix = logo;
            if (scale != 1.0) {
                if (scale <= 0) scale = 1.0;
                draw_w = (int)(logo_w * scale);
                draw_h = (int)(logo_h * scale);
                if (draw_w < 1) draw_w = 1;
                if (draw_h < 1) draw_h = 1;
                string key = "pixbuf::placeholder:logo:scaled:%dx%d::%dx%d".printf(logo_w, logo_h, draw_w, draw_h);
                var scaled = ImageCache.get_global().get_or_scale_pixbuf(key, logo, draw_w, draw_h);
                if (scaled != null) draw_pix = scaled;
            }

            double x = (width - draw_w) / 2.0;
            double y = (height - draw_h) / 2.0;
            if (draw_pix != null) Gdk.cairo_set_source_pixbuf(cr, draw_pix, x, y);
            cr.paint_with_alpha(0.7);

            string key = "pixbuf::placeholder:logo:%dx%d::%dx%d".printf(logo.get_width(), logo.get_height(), width, height);
            var cached = ImageCache.get_global().get(key);
            if (cached == null) cached = ImageCache.get_global().get_or_from_surface(key, surface, 0, 0, width, height);
            // Use get_texture() to reuse cached texture and avoid GPU memory leak
            var tex = ImageCache.get_global().get_texture(key);
            if (tex != null) image.set_paintable(tex);
        } catch (GLib.Error e) {
            PlaceholderBuilder.create_gradient_placeholder(image, width, height);
        }
    }

    // Minimal source name/icon mapping duplicated here so placeholder helper
    // can be used without depending on NewsWindow internals.
    public static string get_source_name(NewsSource source) {
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
            case NewsSource.UNKNOWN: return "News Source";
            default: return "News";
        }
    }

    public static string? get_source_icon_path(NewsSource source) {
        string icon_filename;
        switch (source) {
            case NewsSource.GUARDIAN: icon_filename = "guardian-logo.png"; break;
            case NewsSource.BBC: icon_filename = "bbc-logo.png"; break;
            case NewsSource.REDDIT: icon_filename = "reddit-logo.png"; break;
            case NewsSource.NEW_YORK_TIMES: icon_filename = "nytimes-logo.png"; break;
            case NewsSource.BLOOMBERG: icon_filename = "bloomberg-logo.png"; break;
            case NewsSource.REUTERS: icon_filename = "reuters-logo.png"; break;
            case NewsSource.NPR: icon_filename = "npr-logo.png"; break;
            case NewsSource.FOX: icon_filename = "foxnews-logo.png"; break;
            case NewsSource.WALL_STREET_JOURNAL: icon_filename = "wsj-logo.png"; break;
            case NewsSource.UNKNOWN: return null;
            default: return null;
        }
        return DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", icon_filename));
    }

    // Create a placeholder for RSS feed sources using their logo from source_logos directory
    public static void set_rss_placeholder_image(Gtk.Picture image, int width, int height, string source_name) {
        try {
            // Try to get a validated saved filename from SourceMetadata. This
            // avoids using corrupted/zero-byte files that can create blank icons.
            string? icon_filename = SourceMetadata.get_valid_saved_filename_for_source(source_name, width, height);

            // Fall back to sanitized filename (validate that as well)
            if (icon_filename == null || icon_filename.length == 0) {
                string cand = SourceMetadata.sanitize_filename(source_name) + "-logo.png";
                var data_dir = GLib.Environment.get_user_data_dir();
                if (data_dir != null) {
                    var logo_path = GLib.Path.build_filename(data_dir, "paperboy", "source_logos", cand);
                    if (GLib.FileUtils.test(logo_path, GLib.FileTest.EXISTS)) {
                        try {
                            var logo_pixbuf = ImageCache.get_global().get_or_load_file("pixbuf::file:%s::%dx%d".printf(logo_path, width, height), logo_path, width, height);
                            if (logo_pixbuf != null && logo_pixbuf.get_width() > 1 && logo_pixbuf.get_height() > 1) {
                                icon_filename = cand;
                            } else {
                                try { GLib.FileUtils.remove(logo_path); } catch (GLib.Error _) { }
                            }
                        } catch (GLib.Error _) { }
                    }
                }
            }

            if (icon_filename != null && icon_filename.length > 0) {
                var data_dir = GLib.Environment.get_user_data_dir();
                var logo_path = GLib.Path.build_filename(data_dir, "paperboy", "source_logos", icon_filename);

                if (GLib.FileUtils.test(logo_path, GLib.FileTest.EXISTS)) {
                    // Load the logo and create a placeholder with it
                    try {
                        var logo_pixbuf = ImageCache.get_global().get_or_load_file("pixbuf::file:%s::%dx%d".printf(logo_path, 0, 0), logo_path, 0, 0);
                        if (logo_pixbuf != null) {
                            PlaceholderBuilder.create_logo_placeholder(image, logo_pixbuf, width, height);
                            return;
                        }
                    } catch (GLib.Error e) {
                        GLib.warning("Failed to load RSS feed logo from %s: %s", logo_path, e.message);
                    }
                }
            }
        } catch (GLib.Error e) {
            GLib.warning("Error creating RSS placeholder: %s", e.message);
        }
        
        // Fallback to generic gradient placeholder (no source branding)
        PlaceholderBuilder.create_gradient_placeholder(image, width, height);
    }
}
