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

        // Number of columns in the article grid (3 normally, 4 for Top Ten, 2 for adaptive hero layout)
        public int columns_count = 3;

        // Column width for the current layout pass, fixed once by rebuild_columns()
        // so every card created afterward gets identical dimensions.
        public int cached_col_w = 0;

        // Container references (set by NewsWindow after construction)
        // columns_row is a real grid (Gtk.FlowBox): every card is a direct child,
        // laid out into fixed-width rows/columns with uniform gutters, so row and
        // column alignment is enforced structurally instead of by manual bookkeeping.
        public Gtk.FlowBox? columns_row;
        public Gtk.Box? hero_container;
        public Gtk.Box? featured_box;
        public Gtk.Box? main_content_container;
        public Gtk.Widget? content_area;

        // Adaptive layout tracking (for both RSS feeds and regular categories)
        public uint adaptive_layout_timeout_id = 0;
        public int article_count_for_adaptive = 0;

        // Search/filter state - store the original card widgets (in order) so they
        // can be restored when the search query is cleared.
        private Gee.ArrayList<Gtk.Widget>? all_original_cards = null;

        public LayoutManager(NewsWindow w) {
            window = w;
        }

        /**
        * Reset adaptive layout tracking counters. Call at start of fetch.
        */
        public void reset_adaptive_tracking() {
            article_count_for_adaptive = 0;
            if (adaptive_layout_timeout_id > 0) {
                Source.remove(adaptive_layout_timeout_id);
                adaptive_layout_timeout_id = 0;
            }
        }

        // Backward compatibility alias
        public void reset_rss_tracking() {
            reset_adaptive_tracking();
        }

        /**
        * Track a regular category article arrival and schedule adaptive layout check.
        * When article count < 15 and no new articles for 500ms, rebuilds as 2-hero layout.
        *
        * @param current_fetch_seq The fetch sequence to validate against
        */
        public void track_category_article(uint current_fetch_seq) {
            // Don't increment counter - we'll check ArticleStateStore instead
            // to get the actual deduplicated count

            // Cancel any existing timeout and schedule a new one
            if (adaptive_layout_timeout_id > 0) {
                Source.remove(adaptive_layout_timeout_id);
                adaptive_layout_timeout_id = 0;
            }

            // Schedule layout check after 400ms of no new articles
            // Reduced from 500ms to 400ms for faster adaptive layout decision
            adaptive_layout_timeout_id = Timeout.add(400, () => {
                if (current_fetch_seq != FetchContext.current) {
                    return false;
                }

                // Get the actual deduplicated article count from ArticleStateStore
                int actual_count = 0;
                if (window != null && window.article_state_store != null && window.prefs != null) {
                    actual_count = window.article_state_store.get_total_count_for_category(window.prefs.category);
                }

                // Check if we need to adapt the layout
                if (actual_count < 15 && actual_count > 0) {
                    // Rebuild as 2-column hero layout
                    Idle.add(() => {
                        if (current_fetch_seq != FetchContext.current) return false;
                        rebuild_as_category_heroes();
                        return false;
                    });
                } else {
                    // No adaptive layout needed, allow normal spinner hiding
                    if (window != null && window.loading_state != null) {
                        window.loading_state.awaiting_adaptive_layout = false;
                        if (window.loading_state.initial_items_populated && window.loading_state.initial_phase) {
                            window.loading_state.reveal_initial_content();
                        }
                    }
                }

                adaptive_layout_timeout_id = 0;
                return false;
            });
        }

        // Ensure hero container is visible when needed
        public void ensure_hero_container_visible() {
            if (hero_container != null) {
                hero_container.set_visible(true);
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
            w = content_area != null ? content_area.get_width() : window.get_width();
            if (w <= 0) w = 1280;

            int current_margin = 0;
            current_margin = main_content_container != null ? main_content_container.get_margin_start() : H_MARGIN;

            return clampi(w - (current_margin * 2), 600, 1400);
        }

        // Update main content container size based on sidebar visibility
        public void update_main_content_size(bool sidebar_visible) {
            if (main_content_container == null) return;
            int margin = sidebar_visible ? H_MARGIN : 6;
            main_content_container.set_margin_start(margin);
            main_content_container.set_margin_end(margin);
            update_existing_hero_card_size();
        }

        // Update existing hero card to new size if it exists
        public void update_existing_hero_card_size() {
            if (window == null) return;
            if (!window.article_manager.featured_used) return;
            if (featured_box == null) return;
            var hero_card = featured_box.get_first_child();
            if (hero_card != null) {
                hero_card.set_hexpand(true);
                hero_card.set_halign(Gtk.Align.FILL);
            }
            // Also check any registered hero images to see if we should re-request larger variants
            foreach (var kv in window.image_manager.hero_requests.entries) {
                Gtk.Picture pic = kv.key;
                HeroRequest info = kv.value;
                maybe_refetch_hero_for(pic, info);
            }
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
                    window.append_debug_log("Refetching hero image at larger size: " + new_w.to_string() + "x" + new_h.to_string());
                    window.image_manager.load_image_async(picture, info.url, new_w, new_h);
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

        /**
        * Unwrap a Gtk.FlowBox's direct child (a Gtk.FlowBoxChild) down to the
        * actual card widget it wraps.
        */
        private Gtk.Widget? unwrap_flow_child(Gtk.Widget? flow_child) {
            if (flow_child == null) return null;
            if (flow_child is Gtk.FlowBoxChild) {
                return ((Gtk.FlowBoxChild) flow_child).get_child();
            }
            return flow_child;
        }

        // Set the number of columns in the article grid. Existing cards reflow
        // automatically since they're direct children of the FlowBox.
        public void rebuild_columns(int count) {
            if (columns_row == null) return;

            columns_count = count;
            columns_row.set_min_children_per_line(count);
            columns_row.set_max_children_per_line(count);
            columns_row.set_visible(true);

            // Fix the column width for this layout pass so every card created
            // afterward gets identical dimensions. Computing this per-card instead
            // (as before) let it drift as the content area's reported width
            // shifted slightly while articles were still streaming in, so
            // different cards baked in different image heights.
            cached_col_w = estimate_column_width(count);
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
                    featured_box.remove(fchild);
                    fchild.unparent();
                    fchild = next;
                }
            }

            // Restore hero/featured container visibility (may have been hidden by RSS adaptive layout)
            if (hero_container != null) hero_container.set_visible(true);
            if (featured_box != null) featured_box.set_visible(true);

            // Clear hero_container
            if (hero_container != null) {
                Gtk.Widget? hchild = hero_container.get_first_child();
                while (hchild != null) {
                    Gtk.Widget? next = hchild.get_next_sibling();
                    hero_container.remove(hchild);
                    hchild.unparent();
                    hchild = next;
                }
            }

            // For non-topten views, add featured_box back for carousel
            if (!is_topten && hero_container != null && featured_box != null) {
                hero_container.append(featured_box);
            }

            // Rebuild columns: Top Ten uses a 4-column grid, others use 3
            rebuild_columns(is_topten ? 4 : 3);
        }


        /**
        * Common helper for when categories show less than
        * 15 to adaptively build hero cards
        */
        public void rebuild_as_adapative_heroes() {
            // Hide the hero/featured area since we want all articles in columns
            if (hero_container != null) hero_container.set_visible(false);
            if (featured_box != null) featured_box.set_visible(false);

            // Switch the grid to 2 columns - existing cards reflow in place
            rebuild_columns(2);

            if (columns_row == null) return;

            // Apply uniform sizing to all article cards in the grid
            Gtk.Widget? flow_child = columns_row.get_first_child();
            while (flow_child != null) {
                Gtk.Widget? next = flow_child.get_next_sibling();
                Gtk.Widget? child = unwrap_flow_child(flow_child);

                if (child != null) {
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
                }
                flow_child = next;
            }
        }


        /**
        * Rebuild the layout as 2-column hero cards for regular categories with <15 articles.
        * Similar to RSS hero layout but for standard news categories.
        */
        public void rebuild_as_category_heroes() {
            // First, re-add carousel items to columns before hiding the carousel
            // This ensures articles that were in the carousel don't get lost
            if (window != null && window.article_manager != null) {
                var carousel_items = window.article_manager.featured_carousel_items;
                if (carousel_items != null && carousel_items.size > 0) {
                    foreach (var item in carousel_items) {
                        // Re-add each carousel item as a regular card to the grid
                        // Use bypass_limit=true since these articles were already counted
                        window.article_manager.add_item_immediate_to_column(
                            item.title,
                            item.url,
                            item.thumbnail_url,
                            item.category_id,
                            null, // no original_category
                            item.source_name,
                            true  // bypass_limit
                        );
                    }
                }
            }

            // Mark that we're no longer waiting for adaptive layout BEFORE rebuilding
            // This allows the reveal to proceed when we call it
            if (window != null && window.loading_state != null) {
                window.loading_state.awaiting_adaptive_layout = false;
            }

            rebuild_as_adapative_heroes(); // Request for our common helper to rebuild heroes

            // After rebuild completes, reveal content with animations
            // Minimal delay to ensure layout has settled (reduced from 50ms to 30ms)
            Timeout.add(30, () => {
                if (window != null && window.loading_state != null) {
                    if (window.loading_state.initial_items_populated && window.loading_state.initial_phase) {
                        window.loading_state.reveal_initial_content();
                    }
                }
                return false;
            });
        }

        /**
        * Remove all article cards from the grid without destroying the grid widget itself.
        */
        public void clear_columns() {
            if (columns_row == null) return;

            Gtk.Widget? child = columns_row.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                columns_row.remove(child);
                child = next;
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
                featured_box.remove(child);
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
                hero_container.remove(child);
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
                        window.content_box.remove(label);
                        break;
                    }
                }
            }
        }

        /**
        * Force a redraw of the article grid.
        */
        public void refresh_columns() {
            if (columns_row != null) columns_row.queue_draw();
        }

        /**
        * Create and place a hero card in the hero container.
        * Returns the HeroCard object for further configuration.
        */
        public HeroCard create_and_place_hero_card(
            string title,
            string url,
            int max_hero_height,
            int default_hero_h,
            Gtk.Widget hero_chip,
            bool enable_context_menu,
            bool is_topten
        ) {
            var hero_card = new HeroCard(
                title,
                url,
                max_hero_height,
                default_hero_h,
                hero_chip,
                enable_context_menu,
                window.article_state_store,
                window
            );

            if (is_topten) {
                if (hero_container != null) {
                    if (hero_card.root != null) {
                        hero_card.root.set_size_request(-1, max_hero_height);
                    }
                    hero_container.append(hero_card.root);
                }
            }

            return hero_card;
        }

        /**
        * Create and place an article card into the grid.
        * Returns the ArticleCard object for further configuration.
        */
        public ArticleCard create_and_place_article_card(
            string title,
            string url,
            int col_w,
            int img_h,
            Gtk.Widget chip
        ) {
            var article_card = new ArticleCard(
                title,
                url,
                col_w,
                img_h,
                chip,
                window.article_state_store,
                window
            );

            // ArticleCard fixes its own picture and title-area heights, so every
            // card has the same total height without needing anything set here.

            // Append to the grid - Gtk.FlowBox handles row/column placement automatically
            if (columns_row != null) {
                columns_row.append(article_card.root);
            }

            return article_card;
        }

        /**
        * Add an overlay (badge) to an article card.
        */
        public void add_card_overlay(ArticleCard card, Gtk.Widget badge) {
            if (card.overlay != null) {
                card.overlay.add_overlay(badge);
            }
        }

        /**
        * Store the original card widgets (in order) before filtering, so they
        * can be restored exactly when the search query is cleared.
        */
        public Gee.ArrayList<Gtk.Widget> store_original_card_positions() {
            var original_cards = new Gee.ArrayList<Gtk.Widget>();

            if (columns_row == null) return original_cards;

            Gtk.Widget? flow_child = columns_row.get_first_child();
            while (flow_child != null) {
                Gtk.Widget? card_root = unwrap_flow_child(flow_child);
                if (card_root != null) {
                    original_cards.add(card_root);
                }
                flow_child = flow_child.get_next_sibling();
            }

            return original_cards;
        }

        /**
        * Remove all cards from the grid.
        * Used during search filtering to clear the layout.
        */
        public void clear_all_columns_for_filter() {
            clear_columns();
        }

        /**
        * Add matching cards back into the grid after search filtering.
        * Gtk.FlowBox handles row/column placement automatically.
        */
        public void redistribute_cards_across_columns(Gee.ArrayList<ArticleCard> cards) {
            if (columns_row == null) return;

            foreach (var card in cards) {
                columns_row.append(card.root);
            }
        }

        /**
        * Restore cards to their original positions after search is cleared
        */
        public void restore_original_layout() {
            if (all_original_cards == null || all_original_cards.size == 0) return;
            if (columns_row == null) return;

            // Clear current layout first
            clear_all_columns_for_filter();

            // Restore each card in its original order
            foreach (var card_root in all_original_cards) {
                columns_row.append(card_root);
                card_root.set_visible(true);
            }

            // Clear the stored positions
            all_original_cards = null;
        }

        /**
        * Prepare for search filtering - store original positions
        */
        public void prepare_for_search_filter() {
            if (all_original_cards == null) {
                all_original_cards = store_original_card_positions();
            }
        }

        /**
        * Apply search filter - clear and redistribute matching cards
        */
        public void apply_search_filter(Gee.ArrayList<ArticleCard> matching_cards) {
            clear_all_columns_for_filter();
            redistribute_cards_across_columns(matching_cards);
        }

        /**
        * Check if we're currently in search/filter mode
        */
        public bool is_filtered() {
            return all_original_cards != null;
        }

        /**
        * Get the current number of columns in the layout
        * Used by UI components that need to know column count without inspecting widgets
        */
        public int get_column_count() {
            return columns_count;
        }

        /**
        * Calculate card dimensions for the current layout
        * Centralizes all dimension calculations that were previously scattered
        *
        * @param column_width Output parameter for calculated column width
        * @param image_height Output parameter for calculated image height (0.72 aspect ratio)
        */
        public void get_card_dimensions(out int column_width, out int image_height) {
            int col_count = get_column_count();
            column_width = estimate_column_width(col_count);
            image_height = (int)(column_width * 0.72); // Standard aspect ratio
        }

        /**
        * Get the grid's card children for iteration (each item is a Gtk.FlowBoxChild
        * wrapping one article card's root widget).
        * Abstracts away the internal layout structure from UI components.
        * Returns null if columns_row is not initialized
        *
        * This is used by SearchController to iterate through existing cards
        * without exposing the internal grid structure to ContentView
        */
        public GLib.ListModel? get_cards_for_iteration() {
            if (columns_row == null) return null;
            return columns_row.observe_children();
        }
    }
}
