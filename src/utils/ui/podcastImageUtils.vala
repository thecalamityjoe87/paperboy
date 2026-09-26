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

using GLib;

namespace Paperboy {
    // Some search-result publishers' cover art has real, baked-in letterbox
    // bars or whitespace that ImageManager's shared cover-crop can't strip
    // (it fills the frame but can't remove padding baked into the source
    // pixels). This runs a conservative per-edge trim before handing off to
    // that same shared crop, scoped to podcast search cards only.
    public class PodcastImageUtils : GLib.Object {
        // How close a pixel's channels must be to the edge's reference
        // color to still count as "border" while scanning inward.
        private const double COLOR_TOLERANCE = 16.0;
        // Never trim more than this fraction of a dimension from one edge -
        // caps worst-case damage from a false-positive detection (e.g. a
        // show whose actual artwork is a large flat-color area) to a minor
        // crop instead of destroying the image.
        private const double MAX_TRIM_FRACTION_PER_EDGE = 0.30;
        // A line must be at least this uniform to count as still "border".
        private const double UNIFORM_LINE_FRACTION = 0.92;

        public static void load_trimmed_async(Gtk.Picture pic, string? url, int target_w, int target_h) {
            if (url == null || url.length == 0) return;
            string cache_key = "pixbuf::podcasttrim:%s::%dx%d".printf(url, target_w, target_h);

            var cached_tex = ImageCache.get_global().get_texture(cache_key);
            if (cached_tex != null) {
                pic.set_paintable(cached_tex);
                return;
            }

            new Thread<void>("podcast-img-trim", () => {
                Gdk.Pixbuf? result = fetch_and_trim(url, target_w, target_h, cache_key);
                Idle.add(() => {
                    if (result != null) {
                        try {
                            pic.set_paintable(Gdk.Texture.for_pixbuf(result));
                        } catch (GLib.Error e) { }
                    }
                    return false;
                });
            });
        }

        // Worker-thread only: network + decode + pixel scanning, no GTK access.
        private static Gdk.Pixbuf? fetch_and_trim(string url, int target_w, int target_h, string cache_key) {
            try {
                var client = Paperboy.HttpClientUtils.get_default();
                var options = new Paperboy.HttpClientUtils.RequestOptions().with_image_headers();
                var response = client.fetch_sync(url, options);
                if (response.status_code != Soup.Status.OK || response.body == null) return null;

                var loader = new Gdk.PixbufLoader();
                loader.write(response.body.get_data());
                loader.close();
                var pixbuf = loader.get_pixbuf();
                if (pixbuf == null) return null;

                var trimmed = trim_uniform_edges(pixbuf);
                return ImageCache.get_global().get_or_scale_and_crop_pixbuf(cache_key, trimmed, target_w, target_h);
            } catch (GLib.Error e) {
                return null;
            }
        }

        private static Gdk.Pixbuf trim_uniform_edges(Gdk.Pixbuf pixbuf) {
            int width = pixbuf.get_width();
            int height = pixbuf.get_height();
            if (width < 20 || height < 20) return pixbuf;

            unowned uint8[] pixels = pixbuf.get_pixels();
            int rowstride = pixbuf.get_rowstride();
            int channels = pixbuf.get_n_channels();

            int max_trim_x = (int) (width * MAX_TRIM_FRACTION_PER_EDGE);
            int max_trim_y = (int) (height * MAX_TRIM_FRACTION_PER_EDGE);

            int top = scan_edge(pixels, rowstride, channels, width, height, max_trim_y, true, false, 0, width);
            int bottom = scan_edge(pixels, rowstride, channels, width, height, max_trim_y, true, true, 0, width);
            // Left/right scans are restricted to rows already cleared of
            // top/bottom bars - otherwise a full-width bar alone breaks
            // the uniformity check for every column, so real side padding
            // was never detected.
            int left = scan_edge(pixels, rowstride, channels, width, height, max_trim_x, false, false, top, height - bottom);
            int right = scan_edge(pixels, rowstride, channels, width, height, max_trim_x, false, true, top, height - bottom);

            // Leave most of the image intact even if every edge somehow
            // reported a large trim - never trim more than half of either
            // dimension combined.
            if (top + bottom >= height / 2) { top = 0; bottom = 0; }
            if (left + right >= width / 2) { left = 0; right = 0; }

            if (top == 0 && bottom == 0 && left == 0 && right == 0) return pixbuf;

            int new_w = width - left - right;
            int new_h = height - top - bottom;
            if (new_w < 10 || new_h < 10) return pixbuf;

            try {
                return new Gdk.Pixbuf.subpixbuf(pixbuf, left, top, new_w, new_h);
            } catch (GLib.Error e) {
                return pixbuf;
            }
        }

        // Scans inward from one edge (top/bottom if `horizontal_lines` is
        // true, else left/right) and returns how many rows/cols of uniform
        // "border" color were found, capped at `max_trim`.
        private static int scan_edge(unowned uint8[] pixels, int rowstride, int channels, int width, int height, int max_trim, bool horizontal_lines, bool from_far_side, int line_start, int line_end) {
            int line_length = horizontal_lines ? width : height;
            if (max_trim <= 0 || line_length <= 0) return 0;
            if (line_start < 0) line_start = 0;
            if (line_end > line_length) line_end = line_length;
            if (line_end - line_start < 2) return 0;

            // Reference color: the pixel at the very edge, midway along the
            // (possibly restricted) scan range.
            int ref_a = horizontal_lines ? (from_far_side ? height - 1 : 0) : (from_far_side ? width - 1 : 0);
            int ref_b = (line_start + line_end) / 2;
            uint8 ref_r, ref_g, ref_bch;
            get_pixel(pixels, rowstride, channels, horizontal_lines, ref_a, ref_b, out ref_r, out ref_g, out ref_bch);

            int trimmed = 0;
            for (int i = 0; i < max_trim; i++) {
                int a = horizontal_lines ? (from_far_side ? height - 1 - i : i) : (from_far_side ? width - 1 - i : i);
                int matches = 0;
                int samples = 0;
                for (int b = line_start; b < line_end; b += 3) {
                    uint8 r, g, bch;
                    get_pixel(pixels, rowstride, channels, horizontal_lines, a, b, out r, out g, out bch);
                    samples++;
                    double diff = ((int) r - (int) ref_r).abs() + ((int) g - (int) ref_g).abs() + ((int) bch - (int) ref_bch).abs();
                    if (diff <= COLOR_TOLERANCE * 3) matches++;
                }
                if (samples == 0 || ((double) matches / (double) samples) < UNIFORM_LINE_FRACTION) break;
                trimmed++;
            }
            return trimmed;
        }

        // `a` is the coordinate along the scan direction (row index for a
        // horizontal line scan, column index for a vertical one); `b` is
        // the position along the line itself.
        private static void get_pixel(unowned uint8[] pixels, int rowstride, int channels, bool horizontal_lines, int a, int b, out uint8 r, out uint8 g, out uint8 bch) {
            int x = horizontal_lines ? b : a;
            int y = horizontal_lines ? a : b;
            int offset = y * rowstride + x * channels;
            r = pixels[offset];
            g = pixels[offset + 1];
            bch = pixels[offset + 2];
        }
    }
}
