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

/**
 * Hover-reveal prev/next buttons overlaid on a Gtk.Overlay, shared between
 * HeroCarousel and the Front Page category sections. Only the button on
 * whichever side the pointer is currently over is shown - tracked against
 * the overlay's actual allocated width rather than a CSS hover-zone split,
 * since half-width boxes relying on hexpand didn't stretch reliably across
 * the overlay.
 *
 * Callers connect to prev_requested/next_requested to define what a click
 * actually does (switch a Gtk.Stack page, page a ScrolledWindow, etc).
 * Call bind_adjustment() only for a bounded scroller that should disable
 * (and hide) a button once there's nothing left in that direction; a
 * cyclic carousel that always has a next/prev slide should skip it.
 *
 * By default (edge_zone_width null) hovering is a plain left-half/right-
 * half split of the whole overlay - fine for the narrow card rows this was
 * originally built for (CategorySection/HeroCarousel/LeagueBadgeCarousel),
 * where "which half" and "near that edge" are basically the same thing.
 * Pass edge_zone_width (pixels) for a much wider overlay - e.g.
 * MagazineReaderSheet's full page area - where a half-split means hovering
 * anywhere across half the page lights up an arrow nowhere near the
 * pointer; that switches to real edge-distance detection, with a dead
 * zone in the middle where neither button activates.
 */
public class ScrollNavButtons : GLib.Object {
    public Gtk.Button left_button;
    public Gtk.Button right_button;

    public signal void prev_requested();
    public signal void next_requested();

    public ScrollNavButtons(Gtk.Overlay overlay, string css_class, int edge_margin = 8, int? edge_zone_width = null) {
        // No standard GTK/Adwaita icon actually renders as a literal arrow
        // (shaft + head) - go-previous/pan-start/media-playback-start all
        // land back on a chevron or triangle. Using the plain Unicode arrow
        // glyphs as bold button text instead: they're in the core Arrows
        // block, present in every GNOME distro's default font stack
        // (Cantarell, Noto, DejaVu), so this needs no icon theme lookup or
        // bundled asset.
        left_button = new Gtk.Button.with_label("←");
        left_button.add_css_class("scroll-nav-arrow-label");
        left_button.add_css_class(css_class);
        left_button.add_css_class(css_class + "-left");
        left_button.set_halign(Gtk.Align.START);
        left_button.set_valign(Gtk.Align.CENTER);
        left_button.set_margin_start(edge_margin);
        left_button.set_margin_end(edge_margin);
        overlay.add_overlay(left_button);

        right_button = new Gtk.Button.with_label("→");
        right_button.add_css_class("scroll-nav-arrow-label");
        right_button.add_css_class(css_class);
        right_button.add_css_class(css_class + "-right");
        right_button.set_halign(Gtk.Align.END);
        right_button.set_valign(Gtk.Align.CENTER);
        right_button.set_margin_start(edge_margin);
        right_button.set_margin_end(edge_margin);
        overlay.add_overlay(right_button);

        // The overlay owns this object. Every closure below lives on the overlay or its
        // children, so it holds them unowned - a strong capture kept whole sections alive.
        overlay.set_data<ScrollNavButtons>("scroll-nav-buttons", this);
        wire(this, overlay, left_button, right_button, css_class, edge_zone_width);
    }

    private static void wire(ScrollNavButtons nav, Gtk.Overlay overlay, Gtk.Button left, Gtk.Button right, string css_class, int? edge_zone_width) {
        unowned ScrollNavButtons self_ref = nav;
        unowned Gtk.Overlay ov = overlay;
        unowned Gtk.Button left_button = left;
        unowned Gtk.Button right_button = right;
        left_button.clicked.connect(() => self_ref.prev_requested());
        right_button.clicked.connect(() => self_ref.next_requested());

        var nav_motion = new Gtk.EventControllerMotion();
        nav_motion.motion.connect((x, y) => {
            int w = ov.get_width();
            if (w <= 0) return;

            bool left_side, right_side;
            if (edge_zone_width != null) {
                left_side = x < edge_zone_width;
                right_side = x > w - edge_zone_width;
            } else {
                left_side = x < (w / 2.0);
                right_side = !left_side;
            }

            if (left_side) {
                left_button.add_css_class(css_class + "-active");
                right_button.remove_css_class(css_class + "-active");
            } else if (right_side) {
                right_button.add_css_class(css_class + "-active");
                left_button.remove_css_class(css_class + "-active");
            } else {
                // Dead zone (middle of a wide edge_zone_width overlay) -
                // neither edge is actually near the pointer.
                left_button.remove_css_class(css_class + "-active");
                right_button.remove_css_class(css_class + "-active");
            }
        });
        nav_motion.leave.connect(() => {
            left_button.remove_css_class(css_class + "-active");
            right_button.remove_css_class(css_class + "-active");
        });
        overlay.add_controller(nav_motion);
    }

    /**
    * Wire disable-at-ends behavior for a bounded scroller: the button
    * pointing past whichever end is reached becomes insensitive (and, via
    * the ":disabled" CSS rule, invisible even when hovered).
    */
    public void bind_adjustment(Gtk.Adjustment adj) {
        bind_sensitivity(adj, left_button, right_button);
    }

    // Static and unowned for the same reason as wire(): these live on the scroller's own adjustment.
    private static void bind_sensitivity(Gtk.Adjustment adj, Gtk.Button left, Gtk.Button right) {
        unowned Gtk.Adjustment a = adj;
        unowned Gtk.Button l = left;
        unowned Gtk.Button r = right;
        adj.value_changed.connect(() => update_sensitivity(a, l, r));
        adj.changed.connect(() => update_sensitivity(a, l, r));
        update_sensitivity(adj, left, right);
    }

    private static void update_sensitivity(Gtk.Adjustment adj, Gtk.Button left, Gtk.Button right) {
        left.set_sensitive(adj.get_value() > adj.get_lower() + 1.0);
        right.set_sensitive(adj.get_value() < adj.get_upper() - adj.get_page_size() - 1.0);
    }
}
