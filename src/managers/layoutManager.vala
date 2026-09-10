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

// glibc-specific: forces freed heap pages back to the OS immediately instead
// of waiting on glibc's own heuristics. Needed because rebuilding My Feed's
// rows frees up to ~120 full-size card textures at once, which otherwise
// leaves RSS elevated even though everything was properly freed.
[CCode (cname = "malloc_trim")]
private static extern int malloc_trim(size_t pad);

namespace Managers {

    public class LayoutManager : GLib.Object {
        private weak NewsWindow window;

        // Layout constants
        public const int H_MARGIN = 30;
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
        public Gtk.Label? podcasts_hero_title;
        public Gtk.FlowBox? podcast_search_flow;
        public Gtk.Box? hero_container;
        public Gtk.Box? featured_box;
        public Gtk.Box? main_content_container;
        public Gtk.Widget? content_area;

        // Category-grouped sections (Front Page only). Each section is a
        // vertical wrapper (label + horizontally-scrollable row of cards),
        // pre-built in a fixed priority order and hidden until its first
        // card arrives, since articles stream in asynchronously.
        public Gtk.Box? category_sections_container;
        public Gtk.Separator? hero_frontpage_separator;
        private bool using_category_sections = false;
        private Gee.HashMap<string, CategorySection>? category_sections;
        // Ordered section keys for the active mode: FRONTPAGE_SECTION_CATEGORIES
        // for Front Page, or the interleaved key list from prepare_myfeed_sections()
        // for My Feed - both modes share the same iteration code over this.
        private Gee.ArrayList<string>? active_section_order;
        // Card root -> its home section, so search filtering (which temporarily
        // removes non-matching cards) can restore them to their own section.
        private Gee.HashMap<Gtk.Widget, CategorySection>? card_home_section;
        // Each section's randomly-rolled top-up target (see
        // reveal_sections_with_pending_overflow), cached so repeated calls
        // don't re-roll a different target each time.
        private Gee.HashMap<string, int>? section_target_depth;
        private const string MISC_SECTION_KEY = "more";
        // These are the actual category ids the Paperboy frontpage API sends;
        // anything else falls through to the "more" catch-all.
        private static string[] FRONTPAGE_SECTION_CATEGORIES = {
            "headlines", "world", "nation", "politics", "business",
            "technology", "science", "health", "sports", "entertainment",
            "lifestyle", "general", "us", "markets", "industries",
            "economics",
            "more"
        };

        // The sidebar uses "general"/"us" for World/US news where the
        // frontpage API uses "world"/"nation" - map to the sidebar's id so
        // the "..." button's navigation and highlight land on the right
        // row. Returns null when a category has no sidebar entry at all
        // (e.g. "headlines"), which hides the button for that row.
        private static string? sidebar_nav_id_for(string cat) {
            switch (cat) {
                case "world": return "general";
                case "nation": return "us";
                case "headlines": return null;
                case MISC_SECTION_KEY: return null;
                default: return cat;
            }
        }

        // Adaptive layout tracking (for both RSS feeds and regular categories)
        public uint adaptive_layout_timeout_id = 0;
        public int article_count_for_adaptive = 0;

        // Search/filter state - store the original card widgets (in order) so they
        // can be restored when the search query is cleared.
        private Gee.ArrayList<Gtk.Widget>? all_original_cards = null;

        public LayoutManager(NewsWindow w) {
            window = w;
        }

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

        // Schedules an adaptive layout check 400ms after the last article
        // arrival; if the category ends up with fewer than 15 articles,
        // rebuilds it as a 2-column hero layout.
        public void track_category_article(uint current_fetch_seq) {
            if (adaptive_layout_timeout_id > 0) {
                Source.remove(adaptive_layout_timeout_id);
                adaptive_layout_timeout_id = 0;
            }

            adaptive_layout_timeout_id = Timeout.add(400, () => {
                if (current_fetch_seq != FetchContext.current) {
                    return false;
                }

                int actual_count = 0;
                if (window != null && window.article_state_store != null && window.prefs != null) {
                    actual_count = window.article_state_store.get_total_count_for_category(window.prefs.category);
                }

                // Sports runs two concurrent fetches (the normal one plus an
                // extra sports-desk fetch), which can arrive in uneven
                // bursts under load - a mid-stream gap here can read as
                // "fetch done" while more articles are still on the way.
                // Converting to the sparse-category hero grid hides the
                // normal hero carousel with nothing to un-hide it once the
                // rest lands, so Sports always keeps its normal layout
                // regardless of count.
                bool is_sports = window != null && window.prefs != null && window.prefs.category == "sports";

                if (actual_count < 15 && actual_count > 0 && !is_sports) {
                    Idle.add(() => {
                        if (current_fetch_seq != FetchContext.current) return false;
                        rebuild_as_category_heroes();
                        return false;
                    });
                } else {
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
            int margin = sidebar_visible ? H_MARGIN : 20;
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

            // Fixed once per layout pass so every card gets identical
            // dimensions, rather than drifting as content width is
            // re-measured while articles stream in.
            cached_col_w = estimate_column_width(count);
        }

        // Clears hero/featured containers and rebuilds columns. Call at the
        // start of fetch_news(). is_topten: Top Ten uses 4 columns, others 3.
        public void prepare_for_new_fetch(bool is_topten) {
            // Only the Podcasts page shows this - see
            // Managers.PodcastManager.prepare_containers(). Hide it here so
            // it never lingers over a news category's own hero row after
            // leaving Podcasts.
            if (podcasts_hero_title != null) podcasts_hero_title.set_visible(false);

            // Podcasts' own search results grid (see PodcastManager.
            // run_search()) is a separate widget the news pipeline
            // otherwise never touches - only PodcastManager itself ever
            // cleared/hid it, so leaving Podcasts mid-search (cleared or
            // not) for a news category left its stale result cards showing
            // alongside the new category's articles. Tear it down here too,
            // the same way podcasts_hero_title is above.
            if (podcast_search_flow != null) {
                Gtk.Widget? pchild = podcast_search_flow.get_first_child();
                while (pchild != null) {
                    Gtk.Widget? next = pchild.get_next_sibling();
                    podcast_search_flow.remove(pchild);
                    pchild = next;
                }
                podcast_search_flow.set_visible(false);
            }

            if (featured_box != null) {
                Gtk.Widget? fchild = featured_box.get_first_child();
                while (fchild != null) {
                    Gtk.Widget? next = fchild.get_next_sibling();
                    featured_box.remove(fchild);
                    fchild.unparent();
                    fchild = next;
                }
            }

            // Restore visibility in case adaptive layout hid these.
            if (hero_container != null) hero_container.set_visible(true);
            if (featured_box != null) featured_box.set_visible(true);

            if (hero_container != null) {
                Gtk.Widget? hchild = hero_container.get_first_child();
                while (hchild != null) {
                    Gtk.Widget? next = hchild.get_next_sibling();
                    hero_container.remove(hchild);
                    hchild.unparent();
                    hchild = next;
                }
            }

            if (!is_topten && hero_container != null && featured_box != null) {
                hero_container.append(featured_box);
            }

            rebuild_columns(is_topten ? 4 : 3);

            // Front Page and My Feed both group articles into per-row
            // sections instead of the flat grid; every other view uses the
            // flat grid as before.
            bool is_frontpage = (window != null && window.category_manager != null && window.category_manager.is_frontpage_view());
            bool is_myfeed = (window != null && window.category_manager != null && window.category_manager.is_myfeed_view());
            if (is_frontpage) {
                prepare_category_sections();
            } else if (is_myfeed) {
                prepare_myfeed_sections();
            } else {
                teardown_category_sections();
            }
        }


        // Builds adaptive hero cards for categories/feeds with under 15 articles.
        public void rebuild_as_adapative_heroes() {
            if (hero_container != null) hero_container.set_visible(false);
            if (featured_box != null) featured_box.set_visible(false);

            rebuild_columns(2);

            if (columns_row == null) return;

            Gtk.Widget? flow_child = columns_row.get_first_child();
            while (flow_child != null) {
                Gtk.Widget? next = flow_child.get_next_sibling();
                Gtk.Widget? child = unwrap_flow_child(flow_child);

                if (child != null) {
                    child.set_size_request(-1, RSS_HERO_CARD_HEIGHT);
                    child.add_css_class("rss-hero-card");

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
        * Build (or rebuild) the Front Page category sections: one labeled,
        * horizontally-scrollable row per category (see CategorySection),
        * in fixed priority order, hidden until populated. Call at the
        * start of a Front Page fetch.
        */
        public void prepare_category_sections() {
            if (category_sections_container == null) return;

            Gtk.Widget? child = category_sections_container.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                category_sections_container.remove(child);
                child = next;
            }

            // Reassigning category_sections/card_home_section below drops
            // the *only* remaining references to the previous visit's
            // CategorySection objects and card widgets - including, after a
            // search, every pre-search card that discard_search_snapshot()/
            // restore_original_layout() already detached from the widget
            // tree but couldn't free on their own, since card_home_section
            // still held each of them as a map key. That's a much bigger
            // deallocation burst than the plain container-clear above, so
            // trim after dropping these old maps, not before - trimming
            // only here (once, after both) covers both bursts in one call.
            category_sections = new Gee.HashMap<string, CategorySection>();
            card_home_section = new Gee.HashMap<Gtk.Widget, CategorySection>();
            section_target_depth = new Gee.HashMap<string, int>();
            active_section_order = new Gee.ArrayList<string>();
            foreach (string cat in FRONTPAGE_SECTION_CATEGORIES) active_section_order.add(cat);
            malloc_trim(0);

            foreach (string cat in FRONTPAGE_SECTION_CATEGORIES) {
                // Written as if/else rather than a nested ternary: mixing an
                // owned string (category_display_name_for's return) with a
                // literal in a ternary triggered a Vala codegen bug where the
                // owned temp was freed immediately after assignment, before
                // use - producing garbage/invalid-UTF8 label text at runtime.
                string display_name;
                if (cat == MISC_SECTION_KEY) {
                    display_name = "More Stories";
                } else if (window != null) {
                    display_name = window.category_display_name_for(cat);
                } else {
                    display_name = cat;
                }

                // ArticleManager's overflow queue tags uncategorized
                // articles with the literal category_id "frontpage" (it
                // only has a real category to extract when a
                // "##category::" tag is present) - it has no notion of
                // MISC_SECTION_KEY, which is purely a LayoutManager/UI
                // grouping concept. Translate here so the "More Stories"
                // section's load-more button queries the value that's
                // actually on those queued items.
                string query_cat = (cat == MISC_SECTION_KEY) ? "frontpage" : cat;
                string? nav_target = sidebar_nav_id_for(cat);

                var section = new CategorySection(window, display_name, query_cat, false, false, null, false, null, nav_target);
                // Faint divider between Front Page category sections,
                // matching the hero/score/article dividers (see
                // .section-divider in style.css). Skipped on the first
                // section via CSS :first-child so it doesn't double up
                // with the gap under the hero above it.
                section.wrapper.add_css_class("frontpage-section-divider");
                category_sections_container.append(section.wrapper);
                category_sections.set(cat, section);
            }

            using_category_sections = true;
            category_sections_container.set_visible(true);
            if (hero_frontpage_separator != null) hero_frontpage_separator.set_visible(true);
            if (columns_row != null) columns_row.set_visible(false);
        }

        /**
        * Build (or rebuild) My Feed's row sections: rows alternate between
        * one per followed built-in source (that source's latest articles,
        * any category) and one per personalized My Feed category (that
        * topic's articles, any followed source), in source/category/
        * source/category... order. The hero carousel above these rows is
        * untouched - this only replaces the flat grid below it.
        *
        * Section key convention: category rows use the bare category_id
        * (unprefixed, exactly like Front Page) so find_category_section()
        * and the overflow/load-more machinery keep working unmodified for
        * them. Source rows use "source:<id>" (see SourceManager.
        * source_enum_to_id) so they can never collide with a category id.
        *
        * Custom RSS feeds opted into My Feed (NewsPreferences.
        * myfeed_feed_enabled, set from the My Feed Custom Feeds dialog) get
        * a source row too, keyed "customfeed:<url>" so it can never collide
        * with a built-in "source:<id>" key or a topic category id - see
        * resolve_myfeed_source_key(), which matches a custom feed article
        * (whose source_name is literally its feed URL) against this key.
        */
        public void prepare_myfeed_sections() {
            if (category_sections_container == null) return;

            if (window != null && window.article_manager != null) {
                window.article_manager.reset_myfeed_displayed_urls();
            }

            Gtk.Widget? child = category_sections_container.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                category_sections_container.remove(child);
                child = next;
            }

            // See the matching comment in prepare_category_sections() -
            // trim after dropping the old maps below, not before, since
            // that's what actually releases a search's worth of detached
            // pre-search cards that only card_home_section was still
            // referencing.
            category_sections = new Gee.HashMap<string, CategorySection>();
            card_home_section = new Gee.HashMap<Gtk.Widget, CategorySection>();
            section_target_depth = new Gee.HashMap<string, int>();
            active_section_order = new Gee.ArrayList<string>();
            malloc_trim(0);

            // Source-like rows: built-in enabled sources first, then any
            // custom RSS feeds opted into My Feed - unified into one
            // (key, display name) list so both interleave against
            // categories the same way below.
            var source_keys = new Gee.ArrayList<string>();
            var source_names = new Gee.ArrayList<string>();
            // Parallel to source_keys/source_names: a local bundled/saved
            // logo file path if one's available, else a network favicon
            // URL to fetch, else both null (plain text header, as before).
            var source_logo_files = new Gee.ArrayList<string?>();
            var source_logo_urls = new Gee.ArrayList<string?>();
            if (window != null && window.source_manager != null) {
                foreach (var src in window.source_manager.get_enabled_source_enums()) {
                    source_keys.add("source:" + SourceManager.source_enum_to_id(src));
                    source_names.add(SourceManager.get_source_name(src));
                    source_logo_files.add(SourceUtils.get_source_icon_path(src));
                    source_logo_urls.add(null);
                }
            }
            if (window != null && window.prefs != null) {
                var rss_store = Paperboy.RssSourceStore.get_instance();
                foreach (var feed in rss_store.get_all_sources()) {
                    if (window.prefs.preferred_source_enabled("custom:" + feed.url) && window.prefs.myfeed_feed_enabled(feed.url)) {
                        source_keys.add("customfeed:" + feed.url);
                        source_names.add(feed.name);

                        // Same precedence CardBuilder.build_source_badge_dynamic
                        // uses for custom sources: a previously-saved local
                        // favicon file first, network favicon_url otherwise.
                        string? local_path = null;
                        if (feed.icon_filename != null && feed.icon_filename.length > 0) {
                            var data_dir = GLib.Environment.get_user_data_dir();
                            var candidate = GLib.Path.build_filename(data_dir, "paperboy", "source_logos", feed.icon_filename);
                            if (GLib.FileUtils.test(candidate, GLib.FileTest.EXISTS)) local_path = candidate;
                        }
                        source_logo_files.add(local_path);
                        source_logo_urls.add(local_path == null ? feed.favicon_url : null);
                    }
                }
            }

            Gee.ArrayList<string> categories = (window != null && window.category_manager != null)
                ? window.category_manager.get_myfeed_categories()
                : new Gee.ArrayList<string>();

            int max_len = int.max(source_keys.size, categories.size);
            for (int i = 0; i < max_len; i++) {
                if (i < source_keys.size) {
                    string key = source_keys.get(i);
                    string display_name = source_names.get(i);
                    // Built-in sources ("source:<id>") have no single-source
                    // page to jump to yet; custom feeds do, via the same
                    // "rssfeed:<url>" id their sidebar entry already uses.
                    string? nav_target = key.has_prefix("customfeed:")
                        ? "rssfeed:" + key.substring("customfeed:".length)
                        : null;
                    var section = new CategorySection(window, display_name, key, false, false, source_logo_urls.get(i), false, source_logo_files.get(i), nav_target);
                    section.wrapper.add_css_class("frontpage-section-divider");
                    category_sections_container.append(section.wrapper);
                    category_sections.set(key, section);
                    active_section_order.add(key);
                }
                if (i < categories.size) {
                    string cat = categories.get(i);
                    string display_name = (window != null) ? window.category_display_name_for(cat) : cat;
                    string? nav_target = sidebar_nav_id_for(cat);
                    var section = new CategorySection(window, display_name, cat, false, false, null, false, null, nav_target);
                    section.wrapper.add_css_class("frontpage-section-divider");
                    category_sections_container.append(section.wrapper);
                    category_sections.set(cat, section);
                    active_section_order.add(cat);
                }
            }

            using_category_sections = true;
            category_sections_container.set_visible(true);
            if (hero_frontpage_separator != null) hero_frontpage_separator.set_visible(true);
            if (columns_row != null) columns_row.set_visible(false);
        }

        /**
        * Leave category-sections mode (any view other than Front Page).
        *
        * Unparents the Front Page section widgets immediately rather than
        * just hiding the container: each section holds a full row of
        * article cards with their own decoded thumbnail textures, and
        * leaving them merely hidden-but-parented kept every one of those
        * alive in memory for as long as the user stayed away from Front
        * Page - only the *next* visit's prepare_category_sections() call
        * would finally clear them. Switching Front Page -> another
        * category -> Front Page repeatedly compounded this, since each
        * round trip left one full stale copy resident the whole time.
        */
        public void teardown_category_sections() {
            using_category_sections = false;
            if (category_sections_container != null) {
                category_sections_container.set_visible(false);
                Gtk.Widget? child = category_sections_container.get_first_child();
                while (child != null) {
                    Gtk.Widget? next = child.get_next_sibling();
                    category_sections_container.remove(child);
                    child = next;
                }
            }
            if (hero_frontpage_separator != null) hero_frontpage_separator.set_visible(false);
            if (columns_row != null) columns_row.set_visible(true);
            category_sections = null;
            card_home_section = null;
            active_section_order = null;
            malloc_trim(0);
        }

        /**
        * Whether sections mode (Front Page or My Feed rows) is currently
        * active, as opposed to the flat grid.
        */
        public bool is_using_category_sections() {
            return using_category_sections;
        }

        /**
        * Route an article card into its category's section, revealing the
        * section on its first card. Falls back to the flat grid if sections
        * aren't active or the category isn't recognized and there's no
        * catch-all section available.
        */
        public void add_card_to_category_section(string category_id, Gtk.Widget card_root) {
            CategorySection? section = find_category_section(category_id);
            if (section == null) {
                if (columns_row != null) columns_row.append(card_root);
                return;
            }

            section.add_card(card_root);
            if (card_home_section != null) card_home_section.set(card_root, section);
        }

        /**
        * Route an article card into a specific section by its exact key,
        * with NO catch-all fallback: a key that doesn't correspond to a
        * live section (e.g. a My Feed row whose source/category the
        * article doesn't match) simply means "don't place it here",
        * silently. Used for My Feed's dual source+category placement,
        * where add_card_to_category_section's Front-Page-specific
        * "More Stories" fallback would be wrong - dumping an unmatched
        * article into a misc bucket that doesn't exist in My Feed's model.
        */
        public void add_card_to_named_section(string key, Gtk.Widget card_root) {
            if (!using_category_sections || category_sections == null) return;
            CategorySection? section = category_sections.get(key);
            if (section == null) return;

            section.add_card(card_root);
            if (card_home_section != null) card_home_section.set(card_root, section);
        }

        /**
        * Resolve a My Feed article's category_id to its section key, if
        * that category currently has a live row (i.e. it's one of the
        * user's personalized My Feed categories). Returns null otherwise
        * so the caller can skip that placement.
        */
        public string? resolve_myfeed_category_key(string category_id) {
            if (!using_category_sections || category_sections == null) return null;
            return category_sections.has_key(category_id) ? category_id : null;
        }

        /**
        * Confirm a My Feed row key (e.g. "source:guardian" or
        * "customfeed:<url>") corresponds to a currently-live row. The key is
        * resolved by the caller (ArticleManager.add_item(), from
        * source_name/category_id before SourceManager.normalize_source_name
        * rewrites source_name into a display name) rather than fuzzy-matched
        * here against the already-mutated name.
        */
        public string? resolve_myfeed_source_key(string? row_key_hint) {
            if (!using_category_sections || category_sections == null) return null;
            if (row_key_hint == null || row_key_hint.length == 0) return null;
            return category_sections.has_key(row_key_hint) ? row_key_hint : null;
        }

        /**
        * Look up a category's section, falling back to the "More Stories"
        * catch-all for an unrecognized category - the same resolution
        * add_card_to_category_section uses, so a lookup here always matches
        * where a given category_id's cards actually landed.
        */
        private CategorySection? find_category_section(string category_id) {
            if (!using_category_sections || category_sections == null) return null;
            return category_sections.has_key(category_id)
                ? category_sections.get(category_id)
                : category_sections.get(MISC_SECTION_KEY);
        }

        // Reveals a section that got squeezed to zero cards by the 25-article
        // cap (otherwise stuck hidden forever) and refreshes a section whose
        // load-more button got stuck once its row stopped changing on its
        // own. Gated on a minimum card count rather than hidden->visible so
        // a section with just 1 card also gets topped up.
        // Depth is kept low/randomized per section so a topped-up section
        // still reads as short (doesn't fill the row) instead of every
        // section converging on the same visible count.
        private const int MIN_TARGET_DEPTH = 2;
        private const int MAX_TARGET_DEPTH = 5;

        // Rolled once per section per fetch, cached so repeated top-ups
        // converge on the same target.
        private int get_or_roll_target_depth(string cat) {
            if (section_target_depth == null) section_target_depth = new Gee.HashMap<string, int>();
            if (!section_target_depth.has_key(cat)) {
                int target = GLib.Random.int_range(MIN_TARGET_DEPTH, MAX_TARGET_DEPTH + 1);
                section_target_depth.set(cat, target);
            }
            return section_target_depth.get(cat);
        }

        public void reveal_sections_with_pending_overflow() {
            if (!using_category_sections || category_sections == null || active_section_order == null) return;
            if (window == null || window.article_manager == null) return;

            foreach (string cat in active_section_order) {
                // My Feed source rows ("source:<id>") and custom feed rows
                // ("customfeed:<url>") have no overflow/load-more backing
                // yet - remaining_count_for_category only knows real
                // category ids, so skip them here rather than asking it a
                // question it has no answer for.
                if (cat.has_prefix("source:") || cat.has_prefix("customfeed:")) continue;

                CategorySection? section = category_sections.get(cat);
                if (section == null) continue;

                string query_cat = (cat == MISC_SECTION_KEY) ? "frontpage" : cat;
                if (window.article_manager.remaining_count_for_category(query_cat) <= 0) continue;

                section.wrapper.set_visible(true);
                section.refresh_load_more_affordance();

                int current_count = 0;
                Gtk.Widget? child = section.row.get_first_child();
                while (child != null) { current_count++; child = child.get_next_sibling(); }

                int target_depth = get_or_roll_target_depth(cat);
                if (current_count < target_depth) {
                    window.article_manager.load_more_for_category(query_cat, target_depth - current_count);
                }
            }
        }

        /**
        * The Gtk.Box row holding a category section's cards, for
        * ArticleManager to snapshot/diff child counts when animating newly
        * loaded cards into place (see load_more_for_category). Returns null
        * if sections aren't active or nothing matches even the catch-all.
        */
        public Gtk.Widget? get_category_section_row(string category_id) {
            CategorySection? section = find_category_section(category_id);
            return section != null ? section.row : null;
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
            bool is_topten,
            string? published = null
        ) {
            HeroCard hero_card;
            if (is_topten) {
                hero_card = new HeroCard.for_topten(
                    title,
                    url,
                    max_hero_height,
                    hero_chip,
                    enable_context_menu,
                    window.article_state_store,
                    window,
                    published
                );
            } else {
                hero_card = new HeroCard(
                    title,
                    url,
                    max_hero_height,
                    default_hero_h,
                    hero_chip,
                    enable_context_menu,
                    window.article_state_store,
                    window,
                    published
                );
            }

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
            Gtk.Widget chip,
            string? section_category_id = null,
            string? published = null,
            bool no_fallback_section = false
        ) {
            var article_card = new ArticleCard(
                title,
                url,
                col_w,
                img_h,
                chip,
                window.article_state_store,
                window,
                published
            );

            // ArticleCard fixes its own picture and title-area heights, so every
            // card has the same total height without needing anything set here.

            // Front Page routes into its category section; every other view
            // appends straight to the grid, which handles row/column placement
            // automatically.
            if (using_category_sections && section_category_id != null) {
                if (no_fallback_section) {
                    add_card_to_named_section(section_category_id, article_card.root);
                } else {
                    add_card_to_category_section(section_category_id, article_card.root);
                }
            } else if (columns_row != null) {
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

            if (using_category_sections) {
                if (category_sections == null || active_section_order == null) return original_cards;
                foreach (string cat in active_section_order) {
                    CategorySection? section = category_sections.get(cat);
                    if (section == null) continue;
                    Gtk.Widget? child = section.row.get_first_child();
                    while (child != null) {
                        original_cards.add(child);
                        child = child.get_next_sibling();
                    }
                }
                return original_cards;
            }

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
            if (using_category_sections) {
                if (category_sections != null) {
                    foreach (var section in category_sections.values) {
                        Gtk.Widget? child = section.row.get_first_child();
                        while (child != null) {
                            Gtk.Widget? next = child.get_next_sibling();
                            section.row.remove(child);
                            child = next;
                        }
                        section.wrapper.set_visible(false);
                    }
                }
                // Global search cards have no home section (they're built
                // fresh from cross-category results, not from any section's
                // original cards) and land in columns_row's fallback below -
                // clear it too so repeated searches don't pile up stale
                // cards from the previous keystroke's results.
                clear_columns();
                // Same reasoning as prepare_category_sections()/
                // teardown_category_sections() below: search rebuilds up to
                // MAX_RESULTS cards (with their own decoded thumbnails) on
                // every debounced keystroke while typing, and freeing that
                // many widgets in one burst is exactly the glibc
                // fragmentation pattern malloc_trim() exists to clean up
                // here - the widgets themselves are already correctly freed
                // (SearchManager.adopt_result_urls() drops the previous
                // batch's ViewStateManager entries first), this just
                // returns that freed heap to the OS instead of leaving it
                // sitting in glibc's arena looking like growing RSS.
                malloc_trim(0);
                return;
            }
            clear_columns();
            malloc_trim(0);
        }

        /**
        * Add matching cards back into the grid after search filtering.
        * Gtk.FlowBox handles row/column placement automatically.
        */
        public void redistribute_cards_across_columns(Gee.ArrayList<Gtk.Widget> card_roots) {
            if (using_category_sections) {
                bool used_columns_row_fallback = false;
                foreach (var card_root in card_roots) {
                    CategorySection? home = card_home_section != null ? card_home_section.get(card_root) : null;
                    if (home != null) {
                        home.add_card(card_root);
                    } else if (columns_row != null) {
                        columns_row.append(card_root);
                        used_columns_row_fallback = true;
                    }
                }
                // columns_row is hidden while using category sections (see
                // switch_to_category_sections) - cards with no home section
                // (global search results) need it shown to actually appear.
                if (used_columns_row_fallback && columns_row != null) {
                    columns_row.set_visible(true);
                }
                return;
            }

            if (columns_row == null) return;

            foreach (var card_root in card_roots) {
                columns_row.append(card_root);
            }
        }

        /**
        * Drop the pre-search card snapshot (see prepare_for_search_filter())
        * without replaying it - the widgets it references are about to be
        * torn down and rebuilt from scratch by a fresh fetch anyway (see
        * SearchManager.reset_query_state(), used when a search is cleared
        * as a side effect of switching category rather than by the user
        * clearing the search box directly). Without this, all_original_cards
        * only ever gets nulled inside restore_original_layout() below - skip
        * that call even once and it holds every pre-search card widget
        * (with their decoded thumbnails) alive indefinitely, since its
        * capture guard (prepare_for_search_filter()) never fires again once
        * it's non-null.
        */
        public void discard_search_snapshot() {
            all_original_cards = null;
        }

        /**
        * Restore cards to their original positions after search is cleared
        */
        public void restore_original_layout() {
            if (all_original_cards == null || all_original_cards.size == 0) return;

            if (using_category_sections) {
                clear_all_columns_for_filter();
                bool used_columns_row_fallback = false;
                foreach (var card_root in all_original_cards) {
                    CategorySection? home = card_home_section != null ? card_home_section.get(card_root) : null;
                    if (home != null) {
                        home.add_card(card_root);
                        card_root.set_visible(true);
                    } else if (columns_row != null) {
                        // Shouldn't normally happen for genuinely original
                        // cards, but better to still show a card with no
                        // recorded home section than silently drop it.
                        columns_row.append(card_root);
                        card_root.set_visible(true);
                        used_columns_row_fallback = true;
                    }
                }
                // Re-hide columns_row unless it's actually holding restored
                // cards via the fallback above.
                if (columns_row != null) columns_row.set_visible(used_columns_row_fallback);
                all_original_cards = null;
                return;
            }

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
        public void apply_search_filter(Gee.ArrayList<Gtk.Widget> matching_cards) {
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
            if (using_category_sections) {
                var store = new GLib.ListStore(typeof(Gtk.Widget));
                if (category_sections != null && active_section_order != null) {
                    foreach (string cat in active_section_order) {
                        CategorySection? section = category_sections.get(cat);
                        if (section == null) continue;
                        Gtk.Widget? child = section.row.get_first_child();
                        while (child != null) {
                            store.append(child);
                            child = child.get_next_sibling();
                        }
                    }
                }
                return store;
            }
            if (columns_row == null) return null;
            return columns_row.observe_children();
        }
    }
}
