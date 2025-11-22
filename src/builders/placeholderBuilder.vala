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
using Cairo;
using Gdk;

public class PlaceholderBuilder : GLib.Object {

    // Create a simple gradient-based "no image" placeholder
    public static void create_gradient_placeholder(Gtk.Picture image, int width, int height) {
        try {
            var surface = new ImageSurface(Format.RGB24, width, height);
            var cr = new Context(surface);

            var pattern = new Pattern.linear(0, 0, width, height);
            pattern.add_color_stop_rgb(0, 0.2, 0.4, 0.8);
            pattern.add_color_stop_rgb(1, 0.1, 0.3, 0.6);
            cr.set_source(pattern);
            cr.paint();

            cr.set_source_rgb(1.0, 1.0, 1.0);
            cr.select_font_face("Sans", FontSlant.NORMAL, FontWeight.BOLD);
            double font_size = double.max(12.0, height * 0.12);
            cr.set_font_size(font_size);
            TextExtents extents;
            cr.text_extents("No Image", out extents);
            double tx = (width - extents.width) / 2.0 - extents.x_bearing;
            double ty = (height - extents.height) / 2.0 - extents.y_bearing;
            cr.move_to(tx, ty);
            cr.show_text("No Image");

            var texture = Texture.for_pixbuf(Gdk.pixbuf_get_from_surface(surface, 0, 0, width, height));
            image.set_paintable(texture);
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
                default:
                    gradient.add_color_stop_rgb(0, 0.3, 0.3, 0.4);
                    gradient.add_color_stop_rgb(1, 0.5, 0.5, 0.6);
                    break;
            }

            cr.set_source(gradient);
            cr.rectangle(0, 0, width, height);
            cr.fill();

            var icon_pixbuf = new Pixbuf.from_file(icon_path);
            if (icon_pixbuf != null) {
                int orig_w = icon_pixbuf.get_width();
                int orig_h = icon_pixbuf.get_height();
                double max_size = double.min(width, height) * 0.5;
                double scale = double.min(max_size / orig_w, max_size / orig_h);
                int scaled_w = (int)(orig_w * scale);
                int scaled_h = (int)(orig_h * scale);
                var scaled_icon = icon_pixbuf.scale_simple(scaled_w, scaled_h, InterpType.BILINEAR);
                int x = (width - scaled_w) / 2;
                int y = (height - scaled_h) / 2;
                cr.save();
                cr.set_source_rgba(1, 1, 1, 0.9);
                Gdk.cairo_set_source_pixbuf(cr, scaled_icon, x, y);
                cr.paint_with_alpha(0.95);
                cr.restore();
            }

            var texture = Texture.for_pixbuf(Gdk.pixbuf_get_from_surface(surface, 0, 0, width, height));
            image.set_paintable(texture);
        } catch (GLib.Error e) {
            // Fallback to text-based placeholder
            string src = "News";
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
            var texture = Texture.for_pixbuf(Gdk.pixbuf_get_from_surface(surface, 0, 0, width, height));
            image.set_paintable(texture);
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
            string? local_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "local-mono.svg"));
            if (local_icon == null) local_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "local-mono.svg"));
            string? use_path = local_icon;
            if (use_path != null) {
                try {
                    var sm = Adw.StyleManager.get_default();
                    if (sm != null && sm.dark) {
                        string? white_cand = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "local-mono-white.svg"));
                        if (white_cand == null) white_cand = DataPaths.find_data_file(GLib.Path.build_filename("icons", "local-mono-white.svg"));
                        if (white_cand != null) use_path = white_cand;
                    }
                } catch (GLib.Error e) { }

                try {
                    var icon_pix = new Pixbuf.from_file(use_path);
                    if (icon_pix != null) {
                        int orig_w = icon_pix.get_width();
                        int orig_h = icon_pix.get_height();
                        double max_icon = double.min(width, height) * 0.4;
                        double scale = double.min(max_icon / (double)orig_w, max_icon / (double)orig_h);
                        if (scale > 1.0) scale = 1.0;
                        int scaled_w = (int)(orig_w * scale);
                        int scaled_h = (int)(orig_h * scale);
                        if (scaled_w < 1) scaled_w = 1;
                        if (scaled_h < 1) scaled_h = 1;
                        var scaled = icon_pix.scale_simple(scaled_w, scaled_h, InterpType.BILINEAR);

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
                        Gdk.cairo_set_source_pixbuf(cr, scaled, x, y);
                        cr.paint_with_alpha(0.95);
                        cr.restore();

                        var tex = Texture.for_pixbuf(Gdk.pixbuf_get_from_surface(surface, 0, 0, width, height));
                        try { image.set_paintable(tex); } catch (GLib.Error e) { }
                        return;
                    }
                } catch (GLib.Error e) { }
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

            // Center the logo
            int logo_w = logo.get_width();
            int logo_h = logo.get_height();
            double x = (width - logo_w) / 2.0;
            double y = (height - logo_h) / 2.0;
            Gdk.cairo_set_source_pixbuf(cr, logo, x, y);
            cr.paint_with_alpha(0.7);

            var texture = Texture.for_pixbuf(Gdk.pixbuf_get_from_surface(surface, 0, 0, width, height));
            image.set_paintable(texture);
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
            default: return null;
        }
        return DataPaths.find_data_file(GLib.Path.build_filename("icons", icon_filename));
    }
}
