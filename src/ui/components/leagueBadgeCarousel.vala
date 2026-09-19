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
 * Seamlessly-looping row of LeagueBadges for the Sports category. Badge set
 * is laid out COPY_COUNT times; crossing into a buffer copy silently jumps
 * back by one copy-width into the home copy.
 *
 * Skips CategorySection's ScrollNavButtons combo deliberately, to avoid its
 * Overlay+ScrolledWindow+EventControllerMotion leak - safe here since this
 * carousel is built once, never destroyed/recreated.
 */
public class LeagueBadgeCarousel : GLib.Object {
    public Gtk.Widget root;
    public signal void badge_selected(string league_key);

    // Needs enough spare copies each side to cover a wide viewport.
    private const int COPY_COUNT = 9;
    private const int HOME_COPY_INDEX = COPY_COUNT / 2;

    private Gtk.ScrolledWindow scroller;
    private Gtk.Box track;
    private Gtk.Box? first_copy = null;
    private Gee.HashMap<string, Gee.ArrayList<LeagueBadge>> badges_by_key = new Gee.HashMap<string, Gee.ArrayList<LeagueBadge>>();
    private bool wrap_connected = false;
    private weak NewsWindow? window;

    public void set_window(NewsWindow win) {
        window = win;
    }

    public LeagueBadgeCarousel() {
        var overlay = new Gtk.Overlay();
        overlay.set_hexpand(true);

        track = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 32);
        track.set_valign(Gtk.Align.START);
        track.set_halign(Gtk.Align.CENTER);
        track.set_hexpand(true);
        // Headroom so a selected badge's larger size isn't clipped.
        track.set_margin_top(16);
        track.set_margin_bottom(4);
        track.set_margin_start(16);
        track.set_margin_end(16);

        scroller = new Gtk.ScrolledWindow();
        scroller.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.NEVER);
        scroller.add_css_class("section-scroller");
        scroller.set_hexpand(true);
        scroller.set_propagate_natural_height(true);
        scroller.set_child(track);
        overlay.set_child(scroller);

        var left_fade = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        left_fade.add_css_class("section-scroll-fade");
        left_fade.add_css_class("section-scroll-fade-left");
        left_fade.set_halign(Gtk.Align.START);
        left_fade.set_valign(Gtk.Align.FILL);
        left_fade.set_vexpand(true);
        left_fade.set_can_target(false);
        overlay.add_overlay(left_fade);

        var right_fade = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        right_fade.add_css_class("section-scroll-fade");
        right_fade.set_halign(Gtk.Align.END);
        right_fade.set_valign(Gtk.Align.FILL);
        right_fade.set_vexpand(true);
        right_fade.set_can_target(false);
        overlay.add_overlay(right_fade);

        // Same hover-reveal nav arrows as CategorySection's rows. Skips
        // bind_adjustment() - this carousel loops, so always has more
        // content in both directions.
        var nav_buttons = new ScrollNavButtons(overlay, "league-nav", 4);
        nav_buttons.prev_requested.connect(() => { nudge_by_badges(-2); });
        nav_buttons.next_requested.connect(() => { nudge_by_badges(2); });

        root = overlay;
    }

    // Rebuilds all copies - only called when the active league set changes.
    public void rebuild(Gee.ArrayList<string> league_keys) {
        Gtk.Widget? child = track.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            track.remove(child);
            child = next;
        }
        badges_by_key.clear();
        first_copy = null;
        wrap_connected = false;

        if (league_keys.size == 0) return;

        for (int copy = 0; copy < COPY_COUNT; copy++) {
            var copy_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 32);
            foreach (var key in league_keys) {
                var badge = new LeagueBadge(key);
                badge.selected.connect(() => {
                    badge_selected(key);
                    center_on(key);
                });
                copy_box.append(badge.root);

                if (!badges_by_key.has_key(key)) badges_by_key.set(key, new Gee.ArrayList<LeagueBadge>());
                badges_by_key.get(key).add(badge);
            }
            track.append(copy_box);
            if (copy == 0) first_copy = copy_box;
        }

        // Deferred to idle - first copy's width isn't known until layout.
        GLib.Idle.add(() => {
            reset_to_home_copy();
            connect_wrap_handler();
            return false;
        });
    }

    public void set_live(string league_key, bool live) {
        var copies = badges_by_key.get(league_key);
        if (copies == null) return;
        foreach (var badge in copies) badge.set_live(live);
    }

    public void set_selected(string league_key, bool is_selected) {
        var copies = badges_by_key.get(league_key);
        if (copies == null) return;
        foreach (var badge in copies) badge.set_selected(is_selected);
    }

    // Scrolls so the given league's badge (home copy instance) is centered.
    public void center_on(string league_key) {
        var copies = badges_by_key.get(league_key);
        if (copies == null || copies.size <= HOME_COPY_INDEX) return;
        var badge = copies.get(HOME_COPY_INDEX);

        Graphene.Rect bounds;
        if (!badge.root.compute_bounds(track, out bounds)) return;

        var adj = scroller.get_hadjustment();
        double viewport = adj.get_page_size();
        double badge_center = bounds.get_x() + bounds.get_width() / 2.0;
        double target = badge_center - viewport / 2.0;
        double lower = adj.get_lower();
        double upper = adj.get_upper() - viewport;
        if (target < lower) target = lower;
        if (target > upper) target = upper;

        animate_scroll_to(adj, target);
    }

    // Scrolls by N badge-widths instead of a full page - a full page was
    // too far given how few badges are usually in this carousel.
    private void nudge_by_badges(int count) {
        if (first_copy == null) return;
        int n = 0;
        for (var c = first_copy.get_first_child(); c != null; c = c.get_next_sibling()) n++;
        if (n == 0) return;
        double badge_step = first_copy.get_width() / (double) n;

        var adj = scroller.get_hadjustment();
        animate_scroll_to(adj, adj.get_value() + badge_step * count);
    }

    private void animate_scroll_to(Gtk.Adjustment adj, double target) {
        double start = adj.get_value();
        double distance = target - start;
        if (Math.fabs(distance) < 1.0) return;

        int64 duration_us = 350000;
        int64 start_time = 0;

        root.add_tick_callback((widget, frame_clock) => {
            int64 now = frame_clock.get_frame_time();
            if (start_time == 0) start_time = now;
            double t = (double)(now - start_time) / duration_us;
            if (t >= 1.0) {
                adj.set_value(target);
                return false;
            }
            double eased = 1.0 - Math.pow(1.0 - t, 3); // ease-out cubic
            adj.set_value(start + distance * eased);
            return true;
        });
    }

    private void reset_to_home_copy() {
        if (first_copy == null) return;
        int copy_width = first_copy.get_width();
        if (copy_width <= 0) return;
        var adj = scroller.get_hadjustment();
        adj.set_value(copy_width * HOME_COPY_INDEX);
    }

    private void connect_wrap_handler() {
        if (wrap_connected || first_copy == null) return;
        wrap_connected = true;
        var adj = scroller.get_hadjustment();
        adj.value_changed.connect(() => {
            int copy_width = first_copy.get_width();
            if (copy_width <= 0) return;
            double v = adj.get_value();
            double ideal_center = copy_width * HOME_COPY_INDEX;
            double drift = v - ideal_center;
            // Drifted past one copy-width - jump back by whole copies (invisible, copies are identical).
            if (Math.fabs(drift) > copy_width) {
                double shift = Math.round(drift / copy_width) * copy_width;
                adj.set_value(v - shift);
            }
        });
    }
}
