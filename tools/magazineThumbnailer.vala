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

// Standalone helper binary, run as its own subprocess by
// MagazinePdfImportService instead of parsing an untrusted, downloaded PDF
// inside the main app process. Poppler has a real CVE history for
// malformed-file parsing bugs, so the first parse of a file that just came
// from an arbitrary user-supplied URL happens here: a short-lived process
// that can only crash itself, not the app, and that is watched and killed
// on a timeout by its caller.
//
// Usage: paperboy-magazine-thumbnailer <pdf-path> <output-png-path> <max-dimension>

// Many scanned-magazine PDFs (archive.org's in particular) render their
// page with a blank white margin around the actual cover artwork - the
// scanned sheet is larger than the printed area. That margin is baked into
// the rendered pixels themselves, so no amount of box-sizing in the app's
// card widget can remove it; it has to be cropped out of the source image
// here, before it's ever written to disk.
bool row_is_blank(uint8[] data, int stride, int width, int y, uint8 threshold) {
    int blank_count = 0;
    for (int x = 0; x < width; x++) {
        int offset = y * stride + x * 4;
        if (data[offset] >= threshold && data[offset + 1] >= threshold && data[offset + 2] >= threshold) blank_count++;
    }
    // Tolerate a small fraction of non-white pixels per row/column (scan
    // noise, a faint rule line) rather than requiring an exact all-white row.
    return blank_count >= (int) (width * 0.98);
}

bool col_is_blank(uint8[] data, int stride, int x, int top, int bottom, uint8 threshold) {
    int height = bottom - top + 1;
    int blank_count = 0;
    for (int y = top; y <= bottom; y++) {
        int offset = y * stride + x * 4;
        if (data[offset] >= threshold && data[offset + 1] >= threshold && data[offset + 2] >= threshold) blank_count++;
    }
    return blank_count >= (int) (height * 0.98);
}

// Returns the tightest bounding box around non-blank content, or the full
// surface bounds if nothing looked croppable (e.g. a solid-color cover, or
// content already flush to every edge).
void find_content_bounds(Cairo.ImageSurface surface, out int left, out int top, out int right, out int bottom) {
    surface.flush();
    int w = surface.get_width();
    int h = surface.get_height();
    int stride = surface.get_stride();
    unowned uint8[] data = surface.get_data();
    const uint8 WHITE_THRESHOLD = 245;

    int t = 0, b = h - 1, l = 0, r = w - 1;
    while (t < b && row_is_blank(data, stride, w, t, WHITE_THRESHOLD)) t++;
    while (b > t && row_is_blank(data, stride, w, b, WHITE_THRESHOLD)) b--;
    while (l < r && col_is_blank(data, stride, l, t, b, WHITE_THRESHOLD)) l++;
    while (r > l && col_is_blank(data, stride, r, t, b, WHITE_THRESHOLD)) r--;

    left = l;
    top = t;
    right = r;
    bottom = b;
}

int main(string[] args) {
    if (args.length != 4) {
        stderr.printf("usage: %s <pdf-path> <output-png-path> <max-dimension>\n", args[0]);
        return 1;
    }

    string pdf_path = args[1];
    string output_path = args[2];
    int max_dim = int.parse(args[3]);
    if (max_dim <= 0) max_dim = 400;

    try {
        var file = GLib.File.new_for_path(pdf_path);
        var document = new Poppler.Document.from_gfile(file, null);
        if (document.get_n_pages() < 1) {
            stderr.printf("PDF has no pages\n");
            return 1;
        }

        var page = document.get_page(0);
        double page_w, page_h;
        page.get_size(out page_w, out page_h);
        if (page_w <= 0 || page_h <= 0) {
            stderr.printf("Invalid page size\n");
            return 1;
        }

        double scale = double.min((double) max_dim / page_w, (double) max_dim / page_h);
        if (scale > 1.0) scale = 1.0;
        int out_w = int.max(1, (int) (page_w * scale));
        int out_h = int.max(1, (int) (page_h * scale));

        var surface = new Cairo.ImageSurface(Cairo.Format.RGB24, out_w, out_h);
        var cr = new Cairo.Context(surface);
        cr.set_source_rgb(1, 1, 1);
        cr.paint();
        cr.scale(scale, scale);
        page.render(cr);

        int crop_left, crop_top, crop_right, crop_bottom;
        find_content_bounds(surface, out crop_left, out crop_top, out crop_right, out crop_bottom);
        int crop_w = crop_right - crop_left + 1;
        int crop_h = crop_bottom - crop_top + 1;

        Cairo.ImageSurface output_surface = surface;
        if (crop_left > 0 || crop_top > 0 || crop_right < out_w - 1 || crop_bottom < out_h - 1) {
            output_surface = new Cairo.ImageSurface(Cairo.Format.RGB24, crop_w, crop_h);
            var crop_cr = new Cairo.Context(output_surface);
            crop_cr.set_source_surface(surface, -crop_left, -crop_top);
            crop_cr.paint();
        }

        var status = output_surface.write_to_png(output_path);
        if (status != Cairo.Status.SUCCESS) {
            stderr.printf("Failed to write PNG: %s\n", status.to_string());
            return 1;
        }

        // The PDF's own embedded title (if any) is a far more reliable
        // magazine name than one derived from its download URL - archive.org
        // links in particular are bare identifiers like
        // "sim_popular-science_1975-03_206_3.pdf". Printed on its own stdout
        // line so the caller (still not trusting this file itself) only has
        // to trust this already-sandboxed process's parse of it, not parse
        // the PDF again itself.
        string title = document.get_title();
        if (title != null && title.strip().length > 0) {
            stdout.printf("TITLE:%s\n", title.strip());
        }
    } catch (GLib.Error e) {
        stderr.printf("Failed to render thumbnail: %s\n", e.message);
        return 1;
    }

    return 0;
}
