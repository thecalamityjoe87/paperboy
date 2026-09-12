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
using GLib;

/**
 * A single-line label that can scroll its text horizontally when it
 * overflows (see AnimationManager.start_title_marquee/stop_title_marquee).
 *
 * A plain Gtk.Label can't do this: whatever wraps it (Gtk.ScrolledWindow,
 * Gtk.Viewport, even Gtk.Fixed) ultimately reports the label's true full
 * text width as part of its own measure() output, since GTK containers are
 * never allowed to allocate less than a descendant's genuine minimum size -
 * confirmed empirically (a standalone Gtk.Fixed wrapping an un-ellipsized
 * label still grew a fixed-size, non-resizable window to match the label's
 * full text width, despite Gtk.Fixed.set_size_request()). Ellipsizing the
 * label avoids that, but then also collapses its NATURAL width, so there's
 * no full-width text left to scroll through.
 *
 * This widget sidesteps the problem entirely by not using GtkLabel's layout
 * system at all: measure() reports a fixed, tiny size (so it never affects
 * ancestor sizing regardless of text length) and snapshot() draws the
 * Pango layout directly at a controllable pixel offset, clipped to
 * whatever the widget actually gets allocated. Drawing is unconstrained by
 * the reported size, so this is the only reliable way to have "more text
 * than requested" become visible as the offset animates.
 */
public class MarqueeLabel : Gtk.Widget {
    private Pango.Layout layout;
    private double offset = 0.0;

    construct {
        layout = create_pango_layout(null);
        set_hexpand(true);
        set_valign(Gtk.Align.CENTER);
    }

    public string text {
        get { return layout.get_text(); }
        set {
            layout.set_text(value ?? "", -1);
            offset = 0.0;
            queue_resize();
            queue_draw();
        }
    }

    // The text's true, unconstrained pixel width - what a marquee needs to
    // know how far it can scroll. Deliberately not related to measure()'s
    // reported (fixed, tiny) size - see the class doc comment.
    public int text_pixel_width() {
        int w, h;
        layout.get_pixel_size(out w, out h);
        return w;
    }

    public void set_offset(double pixels) {
        offset = pixels;
        queue_draw();
    }

    public override void measure(Gtk.Orientation orientation, int for_size,
            out int minimum, out int natural, out int minimum_baseline, out int natural_baseline) {
        minimum_baseline = -1;
        natural_baseline = -1;
        if (orientation == Gtk.Orientation.HORIZONTAL) {
            minimum = 1;
            natural = 1;
        } else {
            int w, h;
            layout.get_pixel_size(out w, out h);
            minimum = h;
            natural = h;
        }
    }

    public override void snapshot(Gtk.Snapshot snapshot) {
        int w = get_width();
        int h = get_height();
        if (w <= 0 || h <= 0) return;

        int text_w, text_h;
        layout.get_pixel_size(out text_w, out text_h);

        snapshot.push_clip(Graphene.Rect().init(0, 0, w, h));
        snapshot.translate(Graphene.Point().init((float) (-offset), (float) (h - text_h) / 2.0f));
        snapshot.append_layout(layout, get_color());
        snapshot.pop();
    }
}
