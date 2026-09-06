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
    // Scale to square (out_size x out_size) and mask to a circle (alpha
    // outside = 0). border_width (in the same pixel space as out_size), if
    // > 0, strokes a subtle ring around the circle's edge - without it, a
    // logo whose own colors are close to the background it sits on (e.g. a
    // mostly-white or mostly-transparent logo in light mode) can look like
    // it has no circle at all, since the white circular backdrop below
    // blends straight into the page.
    public static Gdk.Pixbuf? scale_and_circularize (Gdk.Pixbuf? src, int out_size, double border_width = 0) {
        if (src == null) return null;

        int w = src.get_width();
        int h = src.get_height();
        int src_size = (w < h) ? w : h;

        // Create a square pixbuf scaled to out_size then paint it into a
        // Cairo ARGB surface clipped to a circle. Converting the surface
        // back to a pixbuf avoids accessing raw pixel memory directly.
        Gdk.Pixbuf scaled_pb;
                // Scale the source pixbuf to the desired output size
        scaled_pb = src.scale_simple (out_size, out_size, Gdk.InterpType.BILINEAR);

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
        inner_pb = scaled_pb.scale_simple(inner_size, inner_size, Gdk.InterpType.BILINEAR);

        int ox = inset;
        int oy = inset;
        Gdk.cairo_set_source_pixbuf(cr, inner_pb, ox, oy);
        cr.paint();

        // Stroke a subtle ring around the edge, outside the fill clip
        // above (reset_clip so the full stroke width is visible rather
        // than just its inward half).
        if (border_width > 0) {
            cr.reset_clip();
            cr.set_line_width(border_width);
            cr.arc(cx, cy, radius - (border_width / 2.0), 0, 2 * Math.PI);
            cr.set_source_rgba(0, 0, 0, 0.25);
            cr.stroke();
        }

        // Convert surface back to pixbuf
        var result_pb = Gdk.pixbuf_get_from_surface(surface, 0, 0, out_size, out_size);
        return result_pb;
    }

    // Logos are rendered at this many times `display_size` and then scaled
    // back down into that logical box via CONTAIN, rather than rendered at
    // exactly display_size and shown 1:1 - a 1:1 texture only has enough
    // pixels for a 1x display, so on any HiDPI screen (scale factor 2+)
    // GTK has to upscale it to fill the physical pixels, which is what
    // made these logos look blurry. Supersampling first means there's
    // always more source detail than the box needs, so GTK downsamples
    // (sharp) instead of upsampling (blurry) at every scale factor.
    private const int LOGO_RENDER_SCALE = 3;

    // Neutral gray circle the same size/shape a fetched logo will end up
    // as, baked into the pixels (not CSS) so it stays circular regardless
    // of the widget/theme it's dropped into. Used as the initial contents
    // of the returned Gtk.Image before its real logo has loaded (or if it
    // never does).
    //
    // Gtk.Image (not Gtk.Picture) + set_pixel_size, same as every other
    // fixed-size icon in this codebase (see categoryIconsUtils.vala,
    // sidebarView.vala, etc.) - pixel_size pins BOTH the widget's minimum
    // and natural size to exactly display_size regardless of the backing
    // texture's actual resolution. Gtk.Picture has no equivalent: its
    // natural size always follows the paintable's real pixel dimensions,
    // and size_request is only a floor, not a ceiling - any container with
    // spare room (an Adw.ActionRow prefix, sized for the row's full
    // title+subtitle height) was free to grant it that larger natural
    // size, which is why supersampling it for sharpness (see
    // LOGO_RENDER_SCALE) also made it balloon past display_size.
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

    // Fetches `url`, circularizes it at display_size * LOGO_RENDER_SCALE
    // (see make_circular_logo_placeholder), and swaps it into `image` in
    // place of whatever placeholder it's showing. Same one-off
    // fetch-and-forget approach as ScoreCard.load_team_logo: leaves the
    // placeholder showing on any failure rather than erroring.
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
                // Leave the placeholder showing.
            }
        });
    }
}
