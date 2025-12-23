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
    // Scale to square (out_size x out_size) and mask to a circle (alpha outside = 0)
    public static Gdk.Pixbuf? scale_and_circularize (Gdk.Pixbuf? src, int out_size) {
        if (src == null) return null;

        int w = src.get_width();
        int h = src.get_height();
        int src_size = (w < h) ? w : h;

        // Create a square pixbuf scaled to out_size then paint it into a
        // Cairo ARGB surface clipped to a circle. Converting the surface
        // back to a pixbuf avoids accessing raw pixel memory directly.
        Gdk.Pixbuf scaled_pb;
        try {
            // Scale the source pixbuf to the desired output size
            scaled_pb = src.scale_simple (out_size, out_size, Gdk.InterpType.BILINEAR);
        } catch (GLib.Error e) {
            // If scaling fails, fall back to original (best-effort)
            scaled_pb = src;
        }

        // Create ARGB surface and draw a circular badge with the logo
        var surface = new ImageSurface(Format.ARGB32, out_size, out_size);
        var cr = new Context(surface);

        // Fill transparent first
        cr.set_source_rgba(0, 0, 0, 0);
        cr.paint();

        // Use a slight inset (0.5) and best antialiasing to produce a
        // visually-crisp circle across different scale factors / DPI.
        cr.set_antialias(Antialias.BEST);
        double inset_f = 0.5;
        double radius = (out_size - (inset_f * 2.0)) / 2.0;
        double cx = out_size / 2.0;
        double cy = out_size / 2.0;

        // Draw solid circular background (white) so the badge is opaque.
        cr.arc(cx, cy, radius, 0, 2 * Math.PI);
        cr.set_source_rgba(1, 1, 1, 1);
        cr.fill();

        // Clip to circle so the logo doesn't draw outside.
        cr.arc(cx, cy, radius, 0, 2 * Math.PI);
        cr.clip();

        // Draw the scaled pixbuf inset slightly so it sits comfortably inside the badge
        int inset = 4; // matches previous code that centered a 16x16 inside 24x24
        int inner_size = out_size - (inset * 2);
        Gdk.Pixbuf inner_pb;
        try {
            inner_pb = scaled_pb.scale_simple(inner_size, inner_size, Gdk.InterpType.BILINEAR);
        } catch (GLib.Error e) {
            inner_pb = scaled_pb;
        }

        int ox = inset;
        int oy = inset;
        Gdk.cairo_set_source_pixbuf(cr, inner_pb, ox, oy);
        cr.paint();

        // Convert surface back to pixbuf
        try {
            var result_pb = Gdk.pixbuf_get_from_surface(surface, 0, 0, out_size, out_size);
            return result_pb;
        } catch (GLib.Error e) {
            return null;
        }
    }
}
