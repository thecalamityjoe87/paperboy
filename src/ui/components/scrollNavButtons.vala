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
 */
public class ScrollNavButtons : GLib.Object {
    public Gtk.Button left_button;
    public Gtk.Button right_button;

    public signal void prev_requested();
    public signal void next_requested();

    public ScrollNavButtons(Gtk.Overlay overlay, string css_class, int edge_margin = 8) {
        left_button = new Gtk.Button.from_icon_name("go-previous-symbolic");
        left_button.add_css_class(css_class);
        left_button.add_css_class(css_class + "-left");
        left_button.set_halign(Gtk.Align.START);
        left_button.set_valign(Gtk.Align.CENTER);
        left_button.set_margin_start(edge_margin);
        left_button.set_margin_end(edge_margin);
        overlay.add_overlay(left_button);
        left_button.clicked.connect(() => prev_requested());

        right_button = new Gtk.Button.from_icon_name("go-next-symbolic");
        right_button.add_css_class(css_class);
        right_button.add_css_class(css_class + "-right");
        right_button.set_halign(Gtk.Align.END);
        right_button.set_valign(Gtk.Align.CENTER);
        right_button.set_margin_start(edge_margin);
        right_button.set_margin_end(edge_margin);
        overlay.add_overlay(right_button);
        right_button.clicked.connect(() => next_requested());

        var nav_motion = new Gtk.EventControllerMotion();
        nav_motion.motion.connect((x, y) => {
            int w = overlay.get_width();
            if (w <= 0) return;
            bool left_side = x < (w / 2.0);
            if (left_side) {
                left_button.add_css_class(css_class + "-active");
                right_button.remove_css_class(css_class + "-active");
            } else {
                right_button.add_css_class(css_class + "-active");
                left_button.remove_css_class(css_class + "-active");
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
        adj.value_changed.connect(() => update_sensitivity(adj));
        adj.changed.connect(() => update_sensitivity(adj));
        update_sensitivity(adj);
    }

    private void update_sensitivity(Gtk.Adjustment adj) {
        left_button.set_sensitive(adj.get_value() > adj.get_lower() + 1.0);
        right_button.set_sensitive(adj.get_value() < adj.get_upper() - adj.get_page_size() - 1.0);
    }
}
