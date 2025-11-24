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
using Gee;

namespace Managers {

public class LayoutManager : GLib.Object {
    private NewsWindow window;

    // Layout constants
    public const int H_MARGIN = 12;
    public const int COL_SPACING = 12;

    // Column tracking
    public Gtk.Box[] columns;
    public int[] column_heights;
    public int columns_count = 3;

    // Container references (set by NewsWindow after construction)
    public Gtk.Box? columns_row;
    public Gtk.Box? hero_container;
    public Gtk.Box? featured_box;
    public Gtk.Box? main_content_container;
    public Gtk.Widget? content_area;

    public LayoutManager(NewsWindow w) {
        window = w;
    }

    // Ensure hero container is visible when needed
    public void ensure_hero_container_visible() {
        if (hero_container != null) {
            try { hero_container.set_visible(true); } catch (GLib.Error e) { }
        }
    }

    // Helper: clamp integer between bounds
    public int clampi(int v, int min, int max) {
        if (v < min) return min;
        if (v > max) return max;
        return v;
    }

    // Estimate the available content width for both hero and columns
    public int estimate_content_width() {
        int w = 0;
        try { w = content_area != null ? content_area.get_width() : window.get_width(); } catch (GLib.Error e) { w = window.get_width(); }
        if (w <= 0) w = 1280;

        int current_margin = 0;
        try { current_margin = main_content_container != null ? main_content_container.get_margin_start() : H_MARGIN; } catch (GLib.Error e) { current_margin = H_MARGIN; }

        return clampi(w - (current_margin * 2), 600, 1400);
    }

    // Update main content container size based on sidebar visibility
    public void update_main_content_size(bool sidebar_visible) {
        if (main_content_container == null) return;
        int margin = sidebar_visible ? H_MARGIN : 6;
        try { main_content_container.set_margin_start(margin); } catch (GLib.Error e) { }
        try { main_content_container.set_margin_end(margin); } catch (GLib.Error e) { }
        update_existing_hero_card_size();
    }

    // Update existing hero card to new size if it exists
    public void update_existing_hero_card_size() {
        try {
            if (window == null) return;
            if (!window.is_featured_used()) return;
            if (featured_box == null) return;
            var hero_card = featured_box.get_first_child();
            if (hero_card != null) {
                try { hero_card.set_hexpand(true); } catch (GLib.Error e) { }
                try { hero_card.set_halign(Gtk.Align.FILL); } catch (GLib.Error e) { }
            }
            // Also check any registered hero images to see if we should re-request larger variants
            try {
                foreach (var kv in window.hero_requests.entries) {
                    Gtk.Picture pic = kv.key;
                    HeroRequest info = kv.value;
                    maybe_refetch_hero_for(pic, info);
                }
            } catch (GLib.Error e) { }
        } catch (GLib.Error e) { }
    }

    // If container/reported content width has grown since we last requested an image, re-request
    public void maybe_refetch_hero_for(Gtk.Picture picture, HeroRequest info) {
        if (picture == null || info == null) return;
        int base_desired = estimate_content_width();
        if (base_desired <= 0) return;
        int last_base = (int)(info.last_requested_w / (double)info.multiplier);
        if (base_desired > last_base * 1.25 && info.retries < 3) {
            info.retries += 1;
            int new_w = base_desired * info.multiplier;
            int new_h = (int)(info.last_requested_h * ((double)base_desired / last_base));
            info.last_requested_w = new_w;
            info.last_requested_h = new_h;
            try { window.append_debug_log("Refetching hero image at larger size: " + new_w.to_string() + "x" + new_h.to_string()); } catch (GLib.Error e) { }
            try { window.image_handler.load_image_async(picture, info.url, new_w, new_h); } catch (GLib.Error e) { }
            Timeout.add(500, () => { maybe_refetch_hero_for(picture, info); return false; });
        }
    }

    // Estimate a single column width given the number of columns
    public int estimate_column_width(int cols) {
        int content_w = estimate_content_width();
        int total_spacing = (cols - 1) * COL_SPACING;
        int col_w = (content_w - total_spacing) / cols;
        if (window.prefs.category == "topten") {
            col_w = (int)(col_w * 0.85);
        }
        return clampi(col_w, 160, 280);
    }

    // Recreate the columns for masonry layout with a new count
    public void rebuild_columns(int count) {
        if (columns_row == null) return;
        Gtk.Widget? child = columns_row.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            try { columns_row.remove(child); } catch (GLib.Error e) { }
            try { child.unparent(); } catch (GLib.Error e) { }
            child = next;
        }
        columns_count = count;
        columns = new Gtk.Box[count];
        column_heights = new int[count];
        for (int i = 0; i < count; i++) {
            var col = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
            try { col.set_valign(Gtk.Align.START); } catch (GLib.Error e) { }
            try { col.set_halign(Gtk.Align.FILL); } catch (GLib.Error e) { }
            try { col.set_hexpand(true); } catch (GLib.Error e) { }
            try { col.set_vexpand(true); } catch (GLib.Error e) { }
            // Ensure each column is visible
            try { col.set_visible(true); } catch (GLib.Error e) { }
            columns[i] = col;
            column_heights[i] = 0;
            try { columns_row.append(col); } catch (GLib.Error e) { }
        }
        try {
            // Log column array and heights after rebuild
            string heights = "";
            for (int i = 0; i < column_heights.length; i++) heights += column_heights[i].to_string() + ",";
        } catch (GLib.Error e) { }
        // Ensure the columns row container is visible after rebuilding, if it exists
        if (columns_row != null) {
            try { columns_row.set_visible(true); } catch (GLib.Error e) { }
        }
    }

}
}
