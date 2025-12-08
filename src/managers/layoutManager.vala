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
    private weak NewsWindow window;

    // Layout constants
    public const int H_MARGIN = 12;
    public const int COL_SPACING = 12;
    
    // RSS hero card dimensions (for uniform layout in small feeds)
    public const int RSS_HERO_CARD_HEIGHT = 380;
    public const int RSS_HERO_IMAGE_HEIGHT = 300;
    public const int RSS_HERO_TEXT_HEIGHT = 80;

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

    // RSS feed adaptive layout tracking
    public uint rss_feed_layout_timeout_id = 0;
    public int rss_feed_article_count = 0;

    public LayoutManager(NewsWindow w) {
        window = w;
    }

    /**
     * Reset RSS layout tracking counters. Call at start of fetch.
     */
    public void reset_rss_tracking() {
        rss_feed_article_count = 0;
        if (rss_feed_layout_timeout_id > 0) {
            Source.remove(rss_feed_layout_timeout_id);
            rss_feed_layout_timeout_id = 0;
        }
    }

    /**
     * Track an RSS article arrival and schedule adaptive layout check.
     * When article count < 15 and no new articles for 500ms, rebuilds as hero layout.
     *
     * @param current_fetch_seq The fetch sequence to validate against
     */
    public void track_rss_article(uint current_fetch_seq) {
        rss_feed_article_count++;
        
        // Cancel any existing timeout and schedule a new one
        if (rss_feed_layout_timeout_id > 0) {
            Source.remove(rss_feed_layout_timeout_id);
        }
        
        // Schedule layout check after 500ms of no new articles
        rss_feed_layout_timeout_id = Timeout.add(500, () => {
            if (current_fetch_seq != FetchContext.current) {
                rss_feed_layout_timeout_id = 0;
                return false;
            }
            
            // Check if we need to adapt the layout
            if (rss_feed_article_count < 15) {
                // Rebuild as 2-column hero layout
                Idle.add(() => {
                    if (current_fetch_seq != FetchContext.current) return false;
                    try {
                        rebuild_as_rss_heroes();
                    } catch (GLib.Error e) { }
                    return false;
                });
            }
            
            rss_feed_layout_timeout_id = 0;
            return false;
        });
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
            if (!window.article_manager.featured_used) return;
            if (featured_box == null) return;
            var hero_card = featured_box.get_first_child();
            if (hero_card != null) {
                try { hero_card.set_hexpand(true); } catch (GLib.Error e) { }
                try { hero_card.set_halign(Gtk.Align.FILL); } catch (GLib.Error e) { }
            }
            // Also check any registered hero images to see if we should re-request larger variants
            try {
                foreach (var kv in window.image_manager.hero_requests.entries) {
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
            try { window.image_manager.load_image_async(picture, info.url, new_w, new_h); } catch (GLib.Error e) { }
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

        // Collect all existing article widgets from current columns before destroying them
        var existing_articles = new Gee.ArrayList<Gtk.Widget>();
        Gtk.Widget? column_child = columns_row.get_first_child();
        while (column_child != null) {
            // Each column_child is a Gtk.Box (vertical column)
            if (column_child is Gtk.Box) {
                Gtk.Box col_box = (Gtk.Box) column_child;
                Gtk.Widget? article_widget = col_box.get_first_child();
                while (article_widget != null) {
                    Gtk.Widget? next_article = article_widget.get_next_sibling();
                    // Unparent the article from the old column but keep it alive
                    try { col_box.remove(article_widget); } catch (GLib.Error e) { }
                    existing_articles.add(article_widget);
                    article_widget = next_article;
                }
            }
            column_child = column_child.get_next_sibling();
        }

        // Now destroy the old columns
        Gtk.Widget? child = columns_row.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            try { columns_row.remove(child); } catch (GLib.Error e) { }
            try { child.unparent(); } catch (GLib.Error e) { }
            child = next;
        }

        // Create new columns
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

        // Redistribute existing articles into new columns using round-robin
        int current_col = 0;
        foreach (var article in existing_articles) {
            try {
                columns[current_col].append(article);
                current_col = (current_col + 1) % count;
            } catch (GLib.Error e) { }
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

    /**
     * Prepare layout for a new fetch - clears hero/featured containers and rebuilds columns.
     * Call this at the start of fetch_news() to reset layout state.
     * 
     * @param is_topten Whether the current view is Top Ten (uses 4 columns, different hero handling)
     */
    public void prepare_for_new_fetch(bool is_topten) {
        // Clear featured box children
        if (featured_box != null) {
            Gtk.Widget? fchild = featured_box.get_first_child();
            while (fchild != null) {
                Gtk.Widget? next = fchild.get_next_sibling();
                try { featured_box.remove(fchild); } catch (GLib.Error e) { }
                try { fchild.unparent(); } catch (GLib.Error e) { }
                fchild = next;
            }
        }

        // Restore hero/featured container visibility (may have been hidden by RSS adaptive layout)
        try {
            if (hero_container != null) {
                hero_container.set_visible(true);
            }
        } catch (GLib.Error e) { }
        try {
            if (featured_box != null) {
                featured_box.set_visible(true);
            }
        } catch (GLib.Error e) { }

        // Clear hero_container
        if (hero_container != null) {
            Gtk.Widget? hchild = hero_container.get_first_child();
            while (hchild != null) {
                Gtk.Widget? next = hchild.get_next_sibling();
                try { hero_container.remove(hchild); } catch (GLib.Error e) { }
                try { hchild.unparent(); } catch (GLib.Error e) { }
                hchild = next;
            }
        }

        // For non-topten views, add featured_box back for carousel
        if (!is_topten && hero_container != null && featured_box != null) {
            try { hero_container.append(featured_box); } catch (GLib.Error e) { }
        }

        // Rebuild columns: Top Ten uses 4-column grid, others use 3-column masonry
        rebuild_columns(is_topten ? 4 : 3);
    }

    /**
     * Rebuild RSS feed layout as 2-column uniform hero cards (for feeds with < 15 articles).
     * Hides the hero/featured area and applies uniform sizing to all cards.
     */
    public void rebuild_as_rss_heroes() {
        try {
            // Hide the hero/featured area since we want all articles in columns
            try {
                if (hero_container != null) {
                    hero_container.set_visible(false);
                }
            } catch (GLib.Error e) { }

            try {
                if (featured_box != null) {
                    featured_box.set_visible(false);
                }
            } catch (GLib.Error e) { }

            // Rebuild with 2 columns - existing cards will redistribute
            rebuild_columns(2);

            // Apply uniform sizing to all article cards in columns
            for (int i = 0; i < columns.length; i++) {
                Gtk.Widget? child = columns[i].get_first_child();
                while (child != null) {
                    try {
                        // Force uniform tall hero card dimensions
                        child.set_size_request(-1, RSS_HERO_CARD_HEIGHT);
                        child.add_css_class("rss-hero-card");

                        // Dive into the card structure to set uniform heights on image and text sections
                        if (child is Gtk.Box) {
                            Gtk.Box card_root = (Gtk.Box) child;
                            Gtk.Widget? card_child = card_root.get_first_child();
                            int child_index = 0;

                            while (card_child != null) {
                                if (child_index == 0) {
                                    // First child is the overlay with image
                                    if (card_child is Gtk.Overlay) {
                                        Gtk.Overlay overlay = (Gtk.Overlay) card_child;
                                        Gtk.Widget? image = overlay.get_child();
                                        if (image != null) {
                                            image.set_size_request(-1, RSS_HERO_IMAGE_HEIGHT);
                                        }
                                    }
                                } else if (child_index == 1) {
                                    // Second child is the title_box (white part)
                                    if (card_child is Gtk.Box) {
                                        card_child.set_size_request(-1, RSS_HERO_TEXT_HEIGHT);
                                        card_child.set_vexpand(false);
                                    }
                                }
                                child_index++;
                                card_child = card_child.get_next_sibling();
                            }
                        }
                    } catch (GLib.Error e) { }
                    child = child.get_next_sibling();
                }
            }
        } catch (GLib.Error e) {
            warning("Failed to rebuild RSS feed as heroes: %s", e.message);
        }
    }

    /**
     * Clear all article columns without destroying the column widgets themselves.
     */
    public void clear_columns() {
        if (columns == null) return;
        
        for (int i = 0; i < columns.length; i++) {
            if (columns[i] == null) continue;
            
            Gtk.Widget? child = columns[i].get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                try {
                    // Try to properly unparent to avoid lingering refs
                    // Just removing from box should be enough in simplified GTK4, 
                    // but unparent is explicit.
                    columns[i].remove(child);
                } catch (GLib.Error e) { }
                child = next;
            }
            // Reset height tracking
            column_heights[i] = 0;
        }
    }

    /**
     * Clear the featured/hero box content.
     */
    public void clear_featured_box() {
        if (featured_box == null) return;
        
        Gtk.Widget? child = featured_box.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            try { featured_box.remove(child); } catch (GLib.Error e) { }
            child = next;
        }
    }

    /**
     * Clear the hero container content.
     */
    public void clear_hero_container() {
        if (hero_container == null) return;

        Gtk.Widget? child = hero_container.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            try { hero_container.remove(child); } catch (GLib.Error e) { }
            child = next;
        }
    }

    /**
     * Remove the "No more articles" end-of-feed message from the content box.
     */
    public void remove_end_feed_message() {
        if (window == null || window.content_box == null) return;
        
        var children = window.content_box.observe_children();
        for (uint i = 0; i < children.get_n_items(); i++) {
            var child = children.get_item(i) as Gtk.Widget;
            if (child is Gtk.Label) {
                var label = child as Gtk.Label;
                var _txt = label.get_label();
                if (_txt == "<b>No more articles</b>" || _txt == "No more articles") {
                    try { window.content_box.remove(label); } catch (GLib.Error e) { }
                    break;
                }
            }
        }
    }

    /**
     * Force a redraw of all article columns.
     */
    public void refresh_columns() {
        if (columns == null) return;
        
        try {
            for (int i = 0; i < columns.length; i++) {
                if (columns[i] != null) columns[i].queue_draw();
            }
        } catch (GLib.Error e) { }
    }

}
}
