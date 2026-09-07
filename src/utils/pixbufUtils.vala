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

using Gdk;
using GLib;
using Cairo;

public class PixbufUtils {
    // Scales to a square and masks to a circle. border_width, if > 0,
    // strokes a ring around the edge so light/transparent logos don't
    // blend into the page.
    public static Gdk.Pixbuf? scale_and_circularize (Gdk.Pixbuf? src, int out_size, double border_width = 0) {
        if (src == null) return null;

        int w = src.get_width();
        int h = src.get_height();
        int src_size = (w < h) ? w : h;

        // Center-crop to a square on the shorter dimension so non-square
        // logos (e.g. wide wordmarks) don't get stretched.
        int crop_x = (w - src_size) / 2;
        int crop_y = (h - src_size) / 2;
        Gdk.Pixbuf square_src = new Gdk.Pixbuf.subpixbuf(src, crop_x, crop_y, src_size, src_size);

        Gdk.Pixbuf scaled_pb;
        scaled_pb = square_src.scale_simple (out_size, out_size, Gdk.InterpType.BILINEAR);

        var surface = new ImageSurface(Format.ARGB32, out_size, out_size);
        var cr = new Context(surface);

        cr.set_source_rgba(0, 0, 0, 0);
        cr.paint();

        // Slight inset keeps the circle crisp across scale factors/DPI.
        cr.set_antialias(Antialias.BEST);
        double inset_f = 0.5;
        double radius = (out_size - (inset_f * 2.0)) / 2.0;
        double cx = out_size / 2.0;
        double cy = out_size / 2.0;

        cr.arc(cx, cy, radius, 0, 2 * Math.PI);
        cr.set_source_rgba(1, 1, 1, 1);
        cr.fill();

        // Clip to circle so the logo doesn't draw outside.
        cr.arc(cx, cy, radius, 0, 2 * Math.PI);
        cr.clip();

        Gdk.cairo_set_source_pixbuf(cr, scaled_pb, 0, 0);
        cr.paint();

        // reset_clip so the stroke isn't half-clipped by the fill clip above.
        if (border_width > 0) {
            cr.reset_clip();
            cr.set_line_width(border_width);
            cr.arc(cx, cy, radius - (border_width / 2.0), 0, 2 * Math.PI);
            cr.set_source_rgba(0, 0, 0, 0.25);
            cr.stroke();
        }

        var result_pb = Gdk.pixbuf_get_from_surface(surface, 0, 0, out_size, out_size);
        return result_pb;
    }

    // Render at this multiple of display_size and let GTK downsample, so
    // HiDPI screens get sharp scaling instead of upsampling a 1:1 texture.
    private const int LOGO_RENDER_SCALE = 3;

    // Gtk.Image + set_pixel_size (not Gtk.Picture) pins both min and
    // natural size to display_size regardless of the backing texture's
    // resolution; Gtk.Picture's natural size follows the paintable's real
    // pixel size, which would let a supersampled texture balloon past
    // display_size in a container with spare room.
    public static Gtk.Image make_circular_logo_placeholder(int display_size) {
        int render_size = display_size * LOGO_RENDER_SCALE;
        var surface = new ImageSurface(Format.ARGB32, render_size, render_size);
        var cr = new Context(surface);
        cr.set_antialias(Antialias.BEST);
        double radius = render_size / 2.0;
        cr.arc(radius, radius, radius, 0, 2 * Math.PI);
        cr.set_source_rgba(0.5, 0.5, 0.5, 0.25);
        cr.fill();

        double border_width = LOGO_RENDER_SCALE;
        cr.set_line_width(border_width);
        cr.arc(radius, radius, radius - (border_width / 2.0), 0, 2 * Math.PI);
        cr.set_source_rgba(0, 0, 0, 0.25);
        cr.stroke();

        var pb = Gdk.pixbuf_get_from_surface(surface, 0, 0, render_size, render_size);

        var image = new Gtk.Image();
        if (pb != null) image.set_from_paintable(Gdk.Texture.for_pixbuf(pb));
        image.set_pixel_size(display_size);
        return image;
    }

    public static void load_circular_logo_async(Gtk.Image image, string url, int display_size) {
        int render_size = display_size * LOGO_RENDER_SCALE;
        Paperboy.HttpClientUtils.get_default().fetch_bytes(url, null, (response) => {
            if (!response.is_success() || response.body == null) return;
            try {
                var loader = new Gdk.PixbufLoader();
                loader.write(response.body.get_data());
                loader.close();
                var pixbuf = loader.get_pixbuf();
                if (pixbuf == null) return;
                var circular = scale_and_circularize(pixbuf, render_size, LOGO_RENDER_SCALE);
                if (circular == null) return;
                image.set_from_paintable(Gdk.Texture.for_pixbuf(circular));
            } catch (GLib.Error e) {
                warning("Failed to load logo %s: %s", url, e.message);
            }
        });
    }

    // Same as load_circular_logo_async but synchronous, for local files.
    public static void load_circular_logo_from_file(Gtk.Image image, string file_path, int display_size) {
        int render_size = display_size * LOGO_RENDER_SCALE;
        try {
            var pixbuf = new Gdk.Pixbuf.from_file(file_path);
            var circular = scale_and_circularize(pixbuf, render_size, LOGO_RENDER_SCALE);
            if (circular == null) return;
            image.set_from_paintable(Gdk.Texture.for_pixbuf(circular));
        } catch (GLib.Error e) {
            warning("Failed to load logo %s: %s", file_path, e.message);
        }
    }
}
