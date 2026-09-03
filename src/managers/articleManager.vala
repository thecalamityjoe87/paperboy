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


using Gee;

namespace Managers {
    public class ArticleManager : GLib.Object {
        private unowned NewsWindow window;
        
        // Article limits
        public const int INITIAL_ARTICLE_LIMIT = 25;
        public const int LOCAL_NEWS_IMAGE_LOAD_LIMIT = 12;
        public const int MAX_RECENT_CATEGORIES = 6;
        public const int LOAD_MORE_BATCH_SIZE = 10;
        public const int MAX_CAROUSEL_SLIDES = 5;
        
        // Layout dimensions
        // Hero cards now lay text/picture side by side instead of stacked, so
        // the picture spans the card's full height - default/max are kept
        // equal to size fetched images and placeholders at the actual
        // rendered height instead of the old (shorter) stacked-image height.
        public const int HERO_MAX_HEIGHT = 460;
        public const int HERO_DEFAULT_HEIGHT = 460;
        public const int TOPTEN_HERO_MAX_HEIGHT = 400;
        public const int TOPTEN_HERO_DEFAULT_HEIGHT = 400;
        public const int CARD_IMAGE_HEIGHT = 220;  // Fixed, never derived from column width
        public const int CARD_HEIGHT_ESTIMATE_OFFSET = 120;
        public const int IMAGE_QUALITY_MULTIPLIER_HIGH = 6;
        public const int IMAGE_QUALITY_MULTIPLIER_MEDIUM = 3;
        public const int IMAGE_QUALITY_MULTIPLIER_LOW = 2;
        
        public Gee.ArrayList<ArticleItem> article_buffer;
        public Gee.ArrayList<ArticleItem> remaining_articles;
        // PERFORMANCE: per-category count of remaining_articles, kept in
        // sync on every add/remove so remaining_count_for_category() is O(1)
        // instead of rescanning the whole (potentially large) overflow queue.
        private Gee.HashMap<string, int> remaining_category_counts;
        // Debounce latch for reveal_sections_with_pending_overflow(): a whole
        // batch of queued overflow articles (e.g. ~95 frontpage cards in one
        // Idle.add callback) should only trigger one reveal pass, not one per
        // article.
        private bool reveal_pending = false;
        public int articles_shown = 0;
        
        // Track URLs seen in current view to prevent duplicate cards (race condition fix)
        private Gee.HashSet<string> seen_urls;
        
        // Category distribution
        public Gee.HashMap<string, int> category_column_counts;
        public Gee.ArrayList<string> recent_categories;
        public Gee.HashMap<string, int> category_last_column;
        public Gee.ArrayList<string> recent_category_queue;
        
        public int topten_hero_count = 0;
        public Gee.ArrayList<ArticleItem>? featured_carousel_items;
        public HeroCarousel? hero_carousel;
        public string? featured_carousel_category = null;
        public bool featured_used = false;
        
        private bool load_more_button_visible = false;
        public uint buffer_flush_timeout_id = 0;
        
        // Signals for UI operations
        public signal void request_show_load_more_button();
        public signal void request_hide_load_more_button();
        public signal void request_remove_end_feed_message();
        public signal void request_show_toast(string message, bool persistent = false);
        
        public ArticleManager(NewsWindow w) {
            window = w;
            article_buffer = new Gee.ArrayList<ArticleItem>();
            remaining_articles = new Gee.ArrayList<ArticleItem>();
            remaining_category_counts = new Gee.HashMap<string, int>();
            category_column_counts = new Gee.HashMap<string, int>();
            recent_categories = new Gee.ArrayList<string>();
            category_last_column = new Gee.HashMap<string, int>();
            recent_category_queue = new Gee.ArrayList<string>();
            seen_urls = new Gee.HashSet<string>();
        }

        /**
         * Open article in app with offline check
         * Centralized method to handle opening articles in the article sheet
         */
        public void open_article_in_app_if_online(string article_url) {
            var network_monitor = GLib.NetworkMonitor.get_default();
            if (!network_monitor.get_network_available()) {
                request_show_toast("You're offline. Enable internet connection to view articles");
                return;
            }

            string normalized = window.normalize_article_url(article_url);
            window.mark_article_viewed(normalized);
            if (window.article_sheet != null) window.article_sheet.open(normalized);
        }

        /**
         * Open article in browser with offline check
         * Centralized method to handle opening articles in external browser
         */
        public void open_article_in_browser_if_online(string article_url) {
            var network_monitor = GLib.NetworkMonitor.get_default();
            if (!network_monitor.get_network_available()) {
                request_show_toast("You're offline. Enable internet connection to view articles");
                return;
            }

            string normalized = window.normalize_article_url(article_url);
            window.mark_article_viewed(normalized);
            if (window.article_pane != null) window.article_pane.open_article_in_browser(normalized);
        }

        /**
         * Check if a category has article limits applied (most categories do)
         */
        private bool is_limited_category(string category) {
            return CategoryManager.is_limited_category(category);
        }

        /**
         * Check if this is a regular news category (not frontpage, topten, myfeed, local_news, saved, or RSS)
         */
        private bool is_regular_news_category(string category) {
            return CategoryManager.is_regular_news_category(category);
        }
        
        /**
         * Normalize source name for consistent tracking
         */
        private string? normalize_source_name(string? source_name, string category_id, string url) {
            return SourceManager.normalize_source_name(source_name, category_id, url);
        }
        
        /**
         * Queue an article for the "Load More" overflow
         * Returns true if article was queued, false if it was a duplicate
         */
        private bool queue_overflow_article(string title, string url, string? thumbnail_url,
                                            string category_id, string? source_name, string? published = null) {
            // Normalize and check for duplicates
            string normalized_url = "";
            normalized_url = window.normalize_article_url(url); 
            
            if (normalized_url.length > 0 && seen_urls.contains(normalized_url)) {
                return false;  // Duplicate
            }
            if (normalized_url.length > 0) {
                seen_urls.add(normalized_url);
            }

            // Normalize source name
            string? normalized_source = normalize_source_name(source_name, category_id, url);

            // Add to overflow queue
            var queued_item = new ArticleItem(title, url, thumbnail_url, category_id, normalized_source, published);
            remaining_articles.add(queued_item);
            string display_cat = extract_display_category(queued_item);
            remaining_category_counts.set(display_cat, remaining_category_counts.get(display_cat) + 1);

            // Register for unread tracking
            string norm = url.strip();
            if (norm.length > 0 && window.article_state_store != null) {
                window.article_state_store.register_article(norm, category_id, normalized_source);
            }

            // A category that got zero cards into the initial 25-article
            // cap would otherwise stay permanently hidden with no way to
            // reach its queued overflow - see
            // LayoutManager.reveal_sections_with_pending_overflow().
            //
            // PERFORMANCE: debounced via a single Idle.add latch so a whole
            // batch of queued articles (all added synchronously from one
            // fetcher callback) triggers exactly one reveal pass instead of
            // one per article.
            if (window.layout_manager != null && !reveal_pending) {
                reveal_pending = true;
                GLib.Idle.add(() => {
                    reveal_pending = false;
                    if (window.layout_manager != null) {
                        window.layout_manager.reveal_sections_with_pending_overflow();
                    }
                    return false;
                });
            }

            return true;
        }

        /**
         * The real category for a queued overflow article. On Front Page,
         * category_id is always the literal string "frontpage" - the actual
         * category travels in source_name as a "##category::<cat>" suffix
         * (same convention used when building each card's category chip).
         */
        private string extract_display_category(ArticleItem item) {
            string cat = item.category_id;
            if (cat == "frontpage" && item.source_name != null) {
                int idx = item.source_name.index_of("##category::");
                if (idx >= 0 && item.source_name.length > idx + 12) {
                    cat = item.source_name.substring(idx + 12).strip();
                }
            }
            return cat;
        }

        /**
         * How many overflow articles for one category are still queued -
         * used by the category-section nav button to decide whether to show
         * a "load more" affordance once that row is scrolled to its end.
         */
        public int remaining_count_for_category(string cat) {
            if (remaining_category_counts == null) return 0;
            return remaining_category_counts.get(cat);
        }

        /**
         * Load the next batch of queued overflow articles for one category
         * only, appending them to that category's section (existing card
         * placement already routes by category via the same
         * "##category::" parsing, so no extra wiring is needed there).
         * Removes matched items from the shared remaining_articles pool -
         * see load_more_articles() for why removal (not an index cursor) is
         * required now that two flows draw from the same queue.
         */
        public void load_more_for_category(string cat, int max_to_load = LOAD_MORE_BATCH_SIZE) {
            if (remaining_articles == null) return;

            // Snapshot the section's current card count so newly appended
            // cards can be told apart afterward and given the same
            // fade/slide entrance as the global "Load more articles" flow.
            Gtk.Widget? row = (window != null && window.layout_manager != null)
                ? window.layout_manager.get_category_section_row(cat)
                : null;
            int prev_count = 0;
            if (row != null) {
                var c = row.get_first_child();
                while (c != null) { prev_count++; c = c.get_next_sibling(); }
            }
            int loaded = 0;
            int i = 0;
            while (i < remaining_articles.size && loaded < max_to_load) {
                var item = remaining_articles.get(i);
                if (extract_display_category(item) == cat) {
                    remaining_articles.remove_at(i);
                    remaining_category_counts.set(cat, remaining_category_counts.get(cat) - 1);
                    article_buffer.add(item);
                    add_item_immediate_to_column(item.title, item.url, item.thumbnail_url, item.category_id, null, item.source_name, true, item.published);
                    loaded++;
                } else {
                    i++;
                }
            }

            if (row != null && window != null && window.animation_manager != null) {
                var anim_mgr = window.animation_manager;
                // Delay until idle so widgets are realized/parented.
                GLib.Idle.add(() => {
                    uint animate_index = 0;
                    uint per_item_ms = 28;
                    int idx = 0;
                    var child = row.get_first_child();
                    while (child != null) {
                        if (idx >= prev_count) {
                            anim_mgr.animate_card_entrance_stagger(child, animate_index, per_item_ms);
                            animate_index++;
                        }
                        idx++;
                        child = child.get_next_sibling();
                    }
                    return false;
                });
            }
        }

        /**
         * Check if debug mode is enabled
         */
        private bool debug_enabled() {
            string? e = Environment.get_variable("PAPERBOY_DEBUG");
            return e != null && e.length > 0;
        }

        public void add_item(string title, string url, string? thumbnail_url, string category_id, string? source_name, string? published = null) {
            // Check if we're viewing a category with article limits
            if (is_limited_category(window.prefs.category)) {
                lock (articles_shown) {
                    // If we've reached the limit, queue remaining articles for "Load More"
                    if (articles_shown >= INITIAL_ARTICLE_LIMIT) {
                        if (queue_overflow_article(title, url, thumbnail_url, category_id, source_name, published)) {
                            show_load_more_button();
                        }
                        return;
                    }
                }
            }

            // Normalize source name for consistent tracking
            string? final_source_name = normalize_source_name(source_name, category_id, url);
            
            // Normalize URL for deduplication
            string normalized = "";
            if (url != null) normalized = window.normalize_article_url(url);
            if (normalized == null) normalized = "";

            // Early dedup check: Skip if we've already seen this URL in this view session.
            // This prevents race conditions where multiple async fetches add the same article
            // before the first one registers its picture in url_to_picture.
            // Note: Top Ten allows duplicates intentionally to show headlines from multiple providers.
            if (window.prefs.category != "topten" && normalized.length > 0 && seen_urls != null) {
                lock (seen_urls) {
                    if (seen_urls.contains(normalized)) {
                        // Already added this article - but if this duplicate call
                        // carries a published date the card doesn't have yet (e.g.
                        // it was first shown from an on-disk cache entry that
                        // predates this field, and a fresh fetch just resolved
                        // one), backfill the already-rendered card's time label in
                        // place instead of silently dropping the newer data.
                        if (published != null && published.length > 0 && window.view_state != null) {
                            Gtk.Widget? existing_widget = window.view_state.url_to_card.get(normalized);
                            var existing_card = existing_widget != null ? existing_widget.get_data<ArticleCard>("article-card") : null;
                            if (existing_card != null && existing_card.time_label != null && existing_card.time_label.get_text() == "") {
                                existing_card.time_label.set_text(DateUtils.time_ago(published));
                            }
                        }
                        return;
                    }
                    seen_urls.add(normalized);
                }
            }

            Gtk.Picture? existing = null;
            if (window.view_state != null) {
                existing = window.view_state.url_to_picture.get(normalized);
            }

            if (existing == null && window.view_state != null && normalized.length > 0) {
                foreach (var kv in window.view_state.url_to_picture.entries) {
                    string k = kv.key;
                    if (k == null) continue;
                    if (k.length > 0 && (k.has_suffix(normalized) || normalized.has_suffix(k))) {
                        existing = kv.value;
                        break;
                    }
                }
            }
            if (existing != null && thumbnail_url != null && thumbnail_url.length > 0) {
                    // Normally reuse an existing Picture mapping to avoid duplicate
                    // image widgets for the same normalized URL. However, the
                    // Top Ten view intentionally displays many headlines from
                    // multiple providers and we should not dedupe by the
                    // normalized image key there — doing so can collapse
                    // distinct headlines that happen to normalize to the same
                    // URL (tracking/query params removed). Allow Top Ten to
                    // create separate cards even when an image mapping exists.
                    if (window.prefs.category != "topten") {
                        var info = window.image_manager.hero_requests.get(existing);
                        int target_w = 400;
                        if (info != null) {
                            target_w = info.last_requested_w;
                        } else if (window.layout_manager != null) {
                            target_w = window.layout_manager.cached_col_w > 0
                                ? window.layout_manager.cached_col_w
                                : window.layout_manager.estimate_column_width(window.layout_manager.columns_count);
                        }
                        int target_h = info != null ? info.last_requested_h : (int)(target_w * 0.5);
                        if (window.image_manager != null) window.image_manager.pending_local_placeholder.set(existing, category_id == "local_news");
                        // Track image loading during initial phase
                        if (window.loading_state != null && window.loading_state.initial_phase) window.loading_state.pending_images++;
                        // Force immediate loading for reused images (don't defer) since they're already visible
                        window.image_manager.load_image_async(existing, thumbnail_url, target_w, target_h, true);
                        return;
                    } else {
                    }
            }

            // Skip filtering for saved articles - they should always be displayed regardless of source
            bool is_saved_view = (window.prefs.category == "saved");

            if (!is_saved_view) {
                // Use CategoryManager for category filtering
                if (!window.category_manager.should_display_article(category_id)) {
                    if (debug_enabled()) {
                        warning("Article filtered by category: view=%s article_cat=%s title=%s",
                                window.category_manager.get_current_category(), category_id, title);
                    }
                    return;
                }

                // Use SourceManager for source filtering
                if (!window.source_manager.should_display_article(url, category_id)) {
                    return;
                }
            }

            // Add articles immediately
            add_item_immediate_to_column(title, url, thumbnail_url, category_id, null, final_source_name, false, published);
        }

        public void add_item_immediate_to_column(string title, string url, string? thumbnail_url, string category_id, string? original_category = null, string? source_name = null, bool bypass_limit = false, string? published = null) {

            // Decode HTML entities in title (e.g., &mdash; → —, &amp; → &)
            string decoded_title = stripHtmlUtils.strip_html(title);

            string check_category = original_category ?? window.prefs.category;

            // Use helper to check if category has article limits
            if (is_limited_category(check_category) && !bypass_limit) {
                lock (articles_shown) {
                    if (articles_shown >= INITIAL_ARTICLE_LIMIT) {
                        if (title == null || url == null) {
                            return;
                        }

                        // Queue overflow article using helper
                        string normalized_src = normalize_source_name(source_name, category_id, url);
                        if (queue_overflow_article(title, url, thumbnail_url, category_id, normalized_src, published)) {
                            if (!load_more_button_visible) {
                                show_load_more_button();
                            }
                        }
                        return;
                    }
                    
                    articles_shown++;
                }
            }
            
            bool should_be_hero = false;
            if (window.prefs.category == "saved") {
                // Saved articles: skip hero, display as regular cards
                should_be_hero = false;
            } else if (window.prefs.category == "topten") {
                should_be_hero = (topten_hero_count < 2);
            } else if (window.prefs.category == "frontpage") {
                // For frontpage, only make the first article a hero (same as other categories)
                should_be_hero = !featured_used;
            } else if (window.category_manager.is_rssfeed_view()) {
                // Individual RSS feeds: skip hero, go straight to carousel/columns for adaptive layout
                should_be_hero = false;
            } else if (!featured_used) {
                should_be_hero = true;

                if (window.prefs.news_source == NewsSource.REDDIT && url != null && url.length > 0) {
                    string u_low = url.down();
                    if (u_low != null && (u_low.index_of("/live/") >= 0 || u_low.has_suffix("/live") || u_low.index_of("reddit.com/live") >= 0)) {
                        should_be_hero = false;
                    }
                }
            }
            
            if (should_be_hero) {
                // Top Ten uses slightly scaled hero cards
                double hero_scale = (window.prefs.category == "topten") ? 1.30 : 1.0;
                int max_hero_height = (window.prefs.category == "topten") ? TOPTEN_HERO_MAX_HEIGHT : HERO_MAX_HEIGHT;
                int default_hero_w = window.estimate_content_width();
                int default_hero_h = (window.prefs.category == "topten") ? TOPTEN_HERO_DEFAULT_HEIGHT : HERO_DEFAULT_HEIGHT;

                string hero_display_cat = category_id;
                if (hero_display_cat == "frontpage" && source_name != null) {
                    int idx = source_name.index_of("##category::");
                    if (idx >= 0 && source_name.length > idx + 12) hero_display_cat = source_name.substring(idx + 12).strip();
                }

                var hero_chip = window.build_category_chip(hero_display_cat);

                // Enable context menu for: 1) Top Ten hero cards, 2) RSS feeds with < 15 articles
                bool enable_hero_context_menu = false;
                if (window.prefs.category == "topten") {
                    enable_hero_context_menu = true;
                } else if (window.category_manager.is_rssfeed_view() && articles_shown < 15) {
                    enable_hero_context_menu = true;
                }

                var hero_card = window.layout_manager.create_and_place_hero_card(
                    decoded_title,
                    url,
                    max_hero_height,
                    default_hero_h,
                    hero_chip,
                    enable_hero_context_menu,
                    window.prefs.category == "topten",
                    published
                );

                // Populate the hero's snippet line via the existing on-demand
                // preview service (same one articlePane uses), rather than
                // parsing feed/API responses again ourselves. Skipped for Top
                // Ten: its stacked picture-over-text layout only has room
                // for the title.
                if (window.prefs.category != "topten") {
                    ArticleSnippetService.attach_hero_snippet(hero_card, url, source_name, article_buffer);
                }

                // Source badge (logo + name), same as regular article cards.
                if (category_id != "local_news") {
                    var hero_source_badge = window.build_source_badge_dynamic(source_name, url, category_id);
                    hero_card.overlay.add_overlay(hero_source_badge);
                }

                string _norm = window.normalize_article_url(url);

                bool hero_will_load = thumbnail_url != null && thumbnail_url.length > 0 &&
                    (thumbnail_url.has_prefix("http://") || thumbnail_url.has_prefix("https://"));

                if (!hero_will_load) {
                    if (category_id == "local_news")
                        window.set_local_placeholder_image(hero_card.image, default_hero_w, default_hero_h);
                    else
                        set_smart_placeholder(hero_card.image, default_hero_w, default_hero_h, source_name, url);
                }

                    if (hero_will_load) {
                    // Hero images are the most prominent feature - always use maximum quality
                    int multiplier = 6;
                    // Track hero image loading to gate initial content reveal
                    if (window.loading_state != null && window.loading_state.initial_phase) window.loading_state.pending_images++;
                    if (window.image_manager != null) window.image_manager.pending_local_placeholder.set(hero_card.image, category_id == "local_news");
                    // Force immediate loading for hero images (don't defer) to ensure they load quickly
                    window.image_manager.load_image_async(hero_card.image, thumbnail_url, default_hero_w * multiplier, default_hero_h * multiplier, true);
                    window.image_manager.hero_requests.set(hero_card.image, new HeroRequest(thumbnail_url, default_hero_w * multiplier, default_hero_h * multiplier, multiplier));
                    if (window.view_state != null) {
                        window.view_state.register_picture_for_url(_norm, hero_card.image);
                        window.view_state.normalized_to_url.set(_norm, url);
                        window.view_state.register_card_for_url(_norm, hero_card.root);
                    }
                    if (window.article_state_store != null) {
                        bool was = window.article_state_store.is_viewed(_norm);
                        window.append_debug_log("meta_check: hero url=" + _norm + " was=" + (was ? "true" : "false"));
                        if (was) window.mark_article_viewed(_norm);
                    }
                    Timeout.add(300, () => { var info = window.image_manager.hero_requests.get(hero_card.image); if (info != null) window.maybe_refetch_hero_for(hero_card.image, info); return false; });
                }

                // Set metadata for context menu
                hero_card.source_name = source_name;
                hero_card.category_id = category_id;
                hero_card.thumbnail_url = thumbnail_url;

                // Register article for unread count tracking
                // Note: source_name is already normalized by add_item() before being passed here
                if (window.article_state_store != null) {
                    window.article_state_store.register_article(_norm, category_id, source_name);
                }

                hero_card.activated.connect((s) => { if (window.article_pane != null) window.article_pane.show_article_preview(decoded_title, url, thumbnail_url, category_id, source_name); });

                // Connect context menu signals
                hero_card.open_in_app_requested.connect((article_url) => {
                    open_article_in_app_if_online(article_url);
                });

                hero_card.open_in_browser_requested.connect((article_url) => {
                    open_article_in_browser_if_online(article_url);
                });

                hero_card.follow_source_requested.connect((article_url, src_name) => {
                    request_show_toast("Searching for feed...", true);
                    window.source_manager.follow_rss_source(article_url, src_name);
                });

                hero_card.save_for_later_requested.connect((article_url) => {
                    if (window.article_state_store != null) {
                        bool is_saved = window.article_state_store.is_saved(article_url);
                        if (is_saved) {
                            window.article_state_store.unsave_article(article_url);
                            request_show_toast("Removed article from saved");
                            if (window.sidebar_manager != null) window.sidebar_manager.update_badge_for_category("saved");

                            if (window.prefs.category == "saved") {
                                if (window.animation_manager != null) {
                                    var w = hero_card.root;
                                    string? normalized = null;
                                    if (window.view_state != null) normalized = window.view_state.normalize_article_url(article_url);
                                    if (normalized != null && window.view_state != null) window.view_state.unregister_card_for_url(normalized);
                                    window.animation_manager.animate_card_exit_and_remove(w, 0);
                                } else {
                                    window.fetch_news();
                                }
                            }
                        } else {
                            window.article_state_store.save_article(article_url, decoded_title, thumbnail_url, source_name);
                            request_show_toast("Added article to saved");
                            if (window.sidebar_manager != null) window.sidebar_manager.update_badge_for_category("saved");
                            // Visual vacuum effect: shrink the card and pulse the Saved badge
                            if (window.animation_manager != null) {
                                window.animation_manager.animate_bookmark_pop(hero_card.root);
                            }
                        }
                    }
                });

                hero_card.share_requested.connect((article_url) => { window.show_share_dialog(article_url); });

                if (window.prefs.category == "topten") {
                    if (topten_hero_count < 2) {
                        topten_hero_count++;
                        featured_used = true;
                        if (window.loading_state != null && window.loading_state.initial_phase) window.mark_initial_items_populated();
                        return;
                    }
                } else {
                    if (featured_carousel_items == null) featured_carousel_items = new Gee.ArrayList<ArticleItem>();
                    if (hero_carousel == null && window.layout_manager != null && window.layout_manager.featured_box != null) {
                        hero_carousel = new HeroCarousel(window.layout_manager.featured_box);
                        hero_carousel.slide_activated.connect((t, u, thumb, cat, src) => {
                            window.article_pane.show_article_preview(t, u, thumb, cat, src);
                        });
                    }
                    featured_carousel_items.add(new ArticleItem(decoded_title, url, thumbnail_url, category_id, source_name));
                    featured_carousel_category = category_id;

                    hero_carousel.add_initial_slide(hero_card.root);
                    hero_carousel.start_timer(25);

                    featured_used = true;
                    if (window.loading_state != null && window.loading_state.initial_phase) window.mark_initial_items_populated();
                    return;
                }
            }

            if (window.prefs.category != "topten" && hero_carousel != null && featured_carousel_items != null &&
            featured_carousel_items.size < 5) {
            bool allow_slide = false;
            if (window.prefs.category == "myfeed" && window.prefs.personalized_feed_enabled) {
                // Custom RSS sources in My Feed come with category_id="myfeed"
                if (category_id == "myfeed") {
                    allow_slide = true;
                } else if (featured_carousel_category != null && featured_carousel_category == category_id) {
                    allow_slide = true;
                } else {
                    bool has_personalized = window.prefs.personalized_categories != null && window.prefs.personalized_categories.size > 0;
                    if (!has_personalized) {
                        allow_slide = true;
                    } else {
                        foreach (var pc in window.prefs.personalized_categories) {
                            if (pc == category_id) { allow_slide = true; break; }
                        }
                    }
                }
            } else if (window.category_manager.is_rssfeed_view()) {
                // RSS feed views: allow articles for carousel (for adaptive layout)
                // Individual RSS feeds have category_id="rssfeed:<feed_url>"
                // My Feed RSS sources have category_id="myfeed"
                allow_slide = (category_id.has_prefix("rssfeed:") || category_id == "myfeed");
            } else {
                allow_slide = (category_id == window.prefs.category);
            }
            if (!allow_slide) {
                return;
            }

            // Extract display category from source_name if available
            string slide_display_cat = category_id;
            if (slide_display_cat == "frontpage" && source_name != null) {
                int idx2 = source_name.index_of("##category::");
                if (idx2 >= 0 && source_name.length > idx2 + 12) slide_display_cat = source_name.substring(idx2 + 12).strip();
            }

            // Ensure carousel exists
            if (hero_carousel == null && window.layout_manager != null && window.layout_manager.featured_box != null) {
                hero_carousel = new HeroCarousel(window.layout_manager.featured_box);
                // Connect slide activation signal
                hero_carousel.slide_activated.connect((t, u, thumb, cat, src) => {
                    window.article_pane.show_article_preview(t, u, thumb, cat, src);
                });
            }

            // Build category chip and create slide via HeroCarousel
            var slide_chip = window.build_category_chip(slide_display_cat);
            var components = hero_carousel.create_article_slide(decoded_title, url, thumbnail_url, category_id, source_name, slide_chip, published);

            // Populate this slide's snippet and source badge the same way as
            // the primary hero.
            var slide_hero = components.slide.get_data<HeroCard>("hero-card");
            if (slide_hero != null) {
                ArticleSnippetService.attach_hero_snippet(slide_hero, url, source_name, article_buffer);
                if (category_id != "local_news") {
                    var slide_source_badge = window.build_source_badge_dynamic(source_name, url, category_id);
                    slide_hero.overlay.add_overlay(slide_source_badge);
                }
            }
            var slide = components.slide;
            var slide_image = components.image;

            // Handle image loading (this logic stays in ArticleManager as it coordinates with ImageManager)
            int default_w = window.estimate_content_width();
            int default_h = HeroCarousel.SLIDE_IMAGE_HEIGHT;
            bool slide_will_load = thumbnail_url != null && thumbnail_url.length > 0 &&
                (thumbnail_url.has_prefix("http://") || thumbnail_url.has_prefix("https://"));
            
            if (!slide_will_load) {
                if (category_id == "local_news") {
                    window.set_local_placeholder_image(slide_image, default_w, default_h);
                } else {
                    set_smart_placeholder(slide_image, default_w, default_h, source_name, url);
                }
            } else {
                // Carousel slides are prominent features - always use maximum quality
                int multiplier = IMAGE_QUALITY_MULTIPLIER_HIGH;
                // Track carousel image loading to gate initial content reveal
                if (window.loading_state != null && window.loading_state.initial_phase) window.loading_state.pending_images++;
                if (window.image_manager != null) window.image_manager.pending_local_placeholder.set(slide_image, category_id == "local_news");
                // Force immediate loading for carousel images (don't defer) to ensure they load quickly
                window.image_manager.load_image_async(slide_image, thumbnail_url, default_w * multiplier, default_h * multiplier, true);
                window.image_manager.hero_requests.set(slide_image, new HeroRequest(thumbnail_url, default_w * multiplier, default_h * multiplier, multiplier));
                string _norm = window.normalize_article_url(url);
                if (window.view_state != null) {
                    window.view_state.register_picture_for_url(_norm, slide_image);
                    window.view_state.normalized_to_url.set(_norm, url);
                    window.view_state.register_card_for_url(_norm, slide);
                }
                if (window.article_state_store != null) {
                    bool was = window.article_state_store.is_viewed(_norm);
                    if (was) window.mark_article_viewed(_norm);
                }
            }

            featured_carousel_items.add(new ArticleItem(decoded_title, url, thumbnail_url, category_id, source_name));

            // Register article for unread count tracking
            // Carousel slides 2-5 need to be registered just like the first hero card
            string _norm2 = window.normalize_article_url(url);
            if (window.article_state_store != null) {
                window.article_state_store.register_article(_norm2, category_id, source_name);
            }

            return;
        }

        // All cards use uniform sizing so columns stay evenly spaced.
        // Use the column width cached for this layout pass (set once in
        // LayoutManager.rebuild_columns) rather than recomputing it per-card,
        // so every card gets identical dimensions even if the reported content
        // width drifts slightly while articles are still streaming in.
        int col_w = 400;
        if (window.layout_manager != null) {
            col_w = window.layout_manager.cached_col_w > 0
                ? window.layout_manager.cached_col_w
                : window.layout_manager.estimate_column_width(window.layout_manager.columns_count);
        }
        int img_w = col_w;
        // Fixed pixel height, not derived from col_w: any computed value is a
        // vector for cards to end up with different picture heights if col_w
        // is read at slightly different times as articles stream in. A hard
        // constant makes the picture area identical on every card, always.
        int img_h = CARD_IMAGE_HEIGHT;

        string card_display_cat = category_id;
        if (card_display_cat == "frontpage" && source_name != null) {
            int idx3 = source_name.index_of("##category::");
            if (idx3 >= 0 && source_name.length > idx3 + 12) card_display_cat = source_name.substring(idx3 + 12).strip();
        }

        var chip = window.build_category_chip(card_display_cat);

        if (window.layout_manager == null) {
            warning("ArticleManager: layout_manager not initialized, cannot place card");
            return;
        }

        var article_card = window.layout_manager.create_and_place_article_card(
            decoded_title,
            url,
            col_w,
            img_h,
            chip,
            card_display_cat,
            published
        );

        if (category_id != "local_news") {
            var card_badge = window.build_source_badge_dynamic(source_name, url, category_id);
            window.layout_manager.add_card_overlay(article_card, card_badge);
        }

        bool card_will_load = thumbnail_url != null && thumbnail_url.length > 0 &&
            (thumbnail_url.has_prefix("http://") || thumbnail_url.has_prefix("https://"));

        string _norm = window.normalize_article_url(url);

            if (card_will_load) {
            if (category_id == "local_news" && !bypass_limit) {
                if (articles_shown >= LOCAL_NEWS_IMAGE_LOAD_LIMIT) {
                        window.set_local_placeholder_image(article_card.image, img_w, img_h);
                        if (window.view_state != null) window.view_state.register_picture_for_url(_norm, article_card.image);
                        card_will_load = false;
                    }
                
            }
            // In single-source mode, use higher 3x multiplier for crisp quality; in multi-source mode, use 2x initially then 3x
            bool single_source = (window.prefs.preferred_sources != null && window.prefs.preferred_sources.size == 1);
            int multiplier = single_source ? 3 : ((window.loading_state != null && window.loading_state.initial_phase) ? 2 : 3);
            // Track regular card images in pending_images counter during initial phase
            if (window.loading_state != null && window.loading_state.initial_phase) window.loading_state.pending_images++;
            if (window.image_manager != null) window.image_manager.pending_local_placeholder.set(article_card.image, category_id == "local_news");
            // Always force image load so animations or initial-phase state
            // never prevent images from being fetched and shown.
            bool force_load = true;
            window.image_manager.load_image_async(article_card.image, thumbnail_url, img_w * multiplier, img_h * multiplier, force_load);
            if (window.view_state != null) window.view_state.register_picture_for_url(_norm, article_card.image);
        } else {
            if (category_id == "local_news") {
                window.set_local_placeholder_image(article_card.image, img_w, img_h);
            } else {
                set_smart_placeholder(article_card.image, img_w, img_h, source_name, url);
            }
        }

        if (window.view_state != null) window.view_state.normalized_to_url.set(_norm, url);
        if (window.view_state != null) window.view_state.register_card_for_url(_norm, article_card.root);
        if (window.article_state_store != null) {
            bool was = window.article_state_store.is_viewed(_norm);
            if (was) window.mark_article_viewed(_norm);
        }

        // Set metadata for context menu
        article_card.source_name = source_name;
        article_card.category_id = category_id;
        article_card.thumbnail_url = thumbnail_url;

        // Register article for unread count tracking
        // Skip registration if bypass_limit is true - these articles were already
        // registered when added to the overflow queue (lines 131 & 314)
        // Note: source_name is already normalized by add_item() before being passed here
        if (window.article_state_store != null && !bypass_limit) {
            window.article_state_store.register_article(_norm, category_id, source_name);
        }

        article_card.activated.connect((s) => { if (window.article_pane != null) window.article_pane.show_article_preview(decoded_title, url, thumbnail_url, category_id, source_name); });

        // Connect context menu signals
        article_card.open_in_app_requested.connect((article_url) => {
            open_article_in_app_if_online(article_url);
        });

        article_card.open_in_browser_requested.connect((article_url) => {
            open_article_in_browser_if_online(article_url);
        });

        article_card.follow_source_requested.connect((article_url, src_name) => {
            request_show_toast("Searching for feed...", true);
            window.source_manager.follow_rss_source(article_url, src_name);
        });

                article_card.save_for_later_requested.connect((article_url) => {
            if (window.article_state_store != null) {
                bool is_saved = window.article_state_store.is_saved(article_url);
                if (is_saved) {
                    window.article_state_store.unsave_article(article_url);
                    request_show_toast("Removed article from saved");
                    if (window.sidebar_manager != null) window.sidebar_manager.update_badge_for_category("saved");

                    if (window.prefs.category == "saved") {
                        // Animate removal of this single card instead of a full reload
                        if (window.animation_manager != null) {
                                    var w = article_card.root;
                                    string? normalized = null;
                                    if (window.view_state != null) normalized = window.view_state.normalize_article_url(article_url);
                                    if (normalized != null && window.view_state != null) window.view_state.unregister_card_for_url(normalized);
                                    window.animation_manager.animate_card_exit_and_remove(w, 0);
                        } else {
                            window.fetch_news();
                        }
                    }
                } else {
                    window.article_state_store.save_article(article_url, decoded_title, thumbnail_url, source_name);
                    request_show_toast("Added article to saved");
                    // Visual vacuum effect: shrink the card and pulse the Saved badge
                    if (window.animation_manager != null) {
                        window.animation_manager.animate_bookmark_pop(article_card.root);
                    }
                }
            }
        });

        article_card.share_requested.connect((article_url) => {
            window.show_share_dialog(article_url);
        });

        // Attach debug hooks to the created widget so we can observe parent changes and disposals
        article_card.root.notify.connect((obj, pspec) => {
        });
        // Note: cannot reliably connect to dispose; rely on notify("parent") to track unparenting

        if (window.loading_state != null && window.loading_state.initial_phase) window.mark_initial_items_populated();
    }
        
        public void load_more_articles() {
            if (remaining_articles == null || remaining_articles.size == 0) {
                if (load_more_button_visible) {
                    request_hide_load_more_button();
                    load_more_button_visible = false;
                    
                    Timeout.add(300, () => {
                        if (window.loading_state.loading_container == null || !window.loading_state.loading_container.get_visible()) {
                            show_end_of_feed_message();
                        }
                        return false;
                    });
                }
                return;
            }
            
            int articles_to_load = int.min(10, remaining_articles.size);
            
            // Snapshot current card count so we can detect newly appended cards
            int prev_card_count = 0;
            int featured_count = 0;
            if (window != null && window.layout_manager != null) {
                var lm = window.layout_manager;
                if (lm.columns_row != null) {
                    var child = lm.columns_row.get_first_child();
                    while (child != null) { prev_card_count++; child = child.get_next_sibling(); }
                }
                if (lm.featured_box != null) {
                    var f = lm.featured_box;
                    var fc = f.get_first_child();
                    while (fc != null) { featured_count++; fc = fc.get_next_sibling(); }
                }
            }

            for (int i = 0; i < articles_to_load; i++) {
                // Remove from the front rather than indexing in place: this
                // queue is now a shared pool that per-category "load more"
                // (load_more_for_category) can also pull from out of order,
                // so consumption has to be removal-based everywhere to keep
                // both flows from stepping on each other.
                var article = remaining_articles.remove_at(0);
                string display_cat = extract_display_category(article);
                remaining_category_counts.set(display_cat, remaining_category_counts.get(display_cat) - 1);
                // No need to check seen_urls here - articles were already deduplicated
                // when they were added to remaining_articles queue
                article_buffer.add(article);
                add_item_immediate_to_column(article.title, article.url, article.thumbnail_url, article.category_id, null, article.source_name, true, article.published);
            }

            // Animate any newly appended cards after they have been inserted
            if (window != null && window.animation_manager != null && window.layout_manager != null) {
                var lm2 = window.layout_manager;
                // Delay until idle so widgets are realized/parented
                GLib.Idle.add(() => {
                    uint animate_index = 0;
                    uint per_item_ms = 28;

                    // Featured box new children
                    if (lm2.featured_box != null) {
                        int idx = 0;
                        var child = lm2.featured_box.get_first_child();
                        while (child != null) {
                            if (idx >= featured_count) {
                                window.animation_manager.animate_card_entrance_stagger(child, animate_index, per_item_ms);
                                animate_index++;
                            }
                            idx++;
                            child = child.get_next_sibling();
                        }
                    }

                    // New cards in the grid — animate in row-major order (left-to-right,
                    // top-to-bottom), which is simply insertion order for a Gtk.FlowBox.
                    if (lm2.columns_row != null) {
                        var child = lm2.columns_row.get_first_child();
                        int idx = 0;
                        while (child != null) {
                            if (idx >= prev_card_count) {
                                window.animation_manager.animate_card_entrance_stagger(child, animate_index, per_item_ms);
                                animate_index++;
                            }
                            idx++;
                            child = child.get_next_sibling();
                        }
                    }

                    return false;
                });
            }
            
            if (load_more_button_visible) {
                request_hide_load_more_button();
                load_more_button_visible = false;

                Timeout.add(300, () => {
                    if (remaining_articles.size > 0) {
                        Timeout.add(500, () => {
                            show_load_more_button();
                            return false;
                        });
                    } else {
                        Timeout.add(500, () => {
                            if (window.loading_state.loading_container == null || !window.loading_state.loading_container.get_visible()) {
                                show_end_of_feed_message();
                            }
                            return false;
                        });
                    }
                    return false;
                });
            }
        }

        public void show_load_more_button() {
            if (load_more_button_visible) return;

            // Front Page has its own per-category "load more" on each
            // section's nav button (see LayoutManager.add_section_nav_buttons)
            // now that its sections give overflow articles somewhere to land
            // that a single page-bottom button doesn't - so skip the global
            // button there. Every other limited category still uses the old
            // flat grid and keeps this as its only "load more" affordance.
            if (window.prefs.category == "frontpage") return;

            if (window.loading_state.loading_container != null && window.loading_state.loading_container.get_visible()) {
                return;
            }
            
            // Remove any end of feed message
            request_remove_end_feed_message();
            
            // Request UI to show the load more button
            request_show_load_more_button();
            load_more_button_visible = true;
        }
                
        // Ensure any existing load-more button is removed and cleared.
        public void clear_load_more_button() {
            if (!load_more_button_visible) return;
            request_hide_load_more_button();
            load_more_button_visible = false;
        }

        // Public query so other managers can know whether a load-more
        // button is currently present. This avoids races where two
        // managers append conflicting UI elements (button vs end label).
        public bool has_load_more_button() {
            return load_more_button_visible;
        }

        // Public helper to clear all article state and destroy article widgets
        public void clear_articles() {
            // DON'T clear article tracking - we want to accumulate articles across all categories
            // for persistent unread counts that survive category switches

            // Clear article buffer
            if (article_buffer != null) {
                article_buffer.clear();
            }

            // Clear remaining articles list
            if (remaining_articles != null) {
                remaining_articles.clear();
            }
            if (remaining_category_counts != null) {
                remaining_category_counts.clear();
            }
            articles_shown = 0;

            // Clear seen_urls to allow fresh deduplication for new fetch
            if (seen_urls != null) {
                seen_urls.clear();
            }

            // Clear category tracking maps
            if (category_column_counts != null) {
                category_column_counts.clear();
            }
            if (recent_categories != null) {
                recent_categories.clear();
            }
            if (category_last_column != null) {
                category_last_column.clear();
            }
            if (recent_category_queue != null) {
                recent_category_queue.clear();
            }

            // Reset counters
            topten_hero_count = 0;

            // Clear featured carousel state
            if (featured_carousel_items != null) {
                featured_carousel_items.clear();
            }
            featured_carousel_category = null;
            featured_used = false;

            // Remove load more button if present
            clear_load_more_button();

            // CRITICAL: Remove and destroy all article card widgets from the grid
            if (window != null && window.layout_manager != null) {
                window.layout_manager.clear_columns();
            }
        }

        /**
         * Reset article manager state for a new fetch.
         * Call this at the start of fetch_news() to prepare for new content.
         * Clears articles, stops carousel timer, and resets tracking state.
         */
        public void reset_for_new_fetch() {
            // Clear all articles and widgets
            clear_articles();

            // Stop and clear hero carousel
            if (hero_carousel != null) {
                hero_carousel.stop_timer();
                if (hero_carousel.container != null && window.layout_manager.featured_box != null) {
                    window.layout_manager.featured_box.remove(hero_carousel.container);
                }
                hero_carousel = null;
            }

            // Reset carousel state
            if (featured_carousel_items != null) {
                featured_carousel_items.clear();
            }
            featured_carousel_category = null;
            featured_used = false;
            topten_hero_count = 0;

            // Cancel any pending buffer flush timeout
            if (buffer_flush_timeout_id > 0) {
                Source.remove(buffer_flush_timeout_id);
                buffer_flush_timeout_id = 0;
            }
        }
        
        private void show_end_of_feed_message() {
            if (window.loading_state != null) window.loading_state.show_end_of_feed_message();
        }


    private void set_smart_placeholder(Gtk.Picture image, int w, int h, string? source_name, string url) {
        // If explicitly in RSS feed view, always use RSS placeholder
        if (window.category_manager.is_rssfeed_view() && source_name != null && source_name.length > 0) {
            window.set_rss_placeholder_image(image, w, h, source_name);
            return;
        }

        NewsSource resolved = window.resolve_source(source_name, url);
        NewsSource default_source = window.prefs.news_source;
        
        // Check if it resolved to the default source (fallback behavior)
        if (resolved == default_source && source_name != null && source_name.length > 0) {
            // If the name doesn't match the default source, assume it's a custom RSS feed
            if (!source_name_matches(resolved, source_name)) {
                window.set_rss_placeholder_image(image, w, h, source_name);
                return;
            }
        }

        window.set_placeholder_image_for_source(image, w, h, resolved);
    }

    private bool source_name_matches(NewsSource source, string name) {
        return SourceManager.source_name_matches(source, name);
    }
    public void clear_article_buffer() {
        article_buffer.clear();
    }

    public void reset_featured_state() {
        featured_used = false;
        topten_hero_count = 0;
        if (featured_carousel_items != null) featured_carousel_items.clear();
        hero_carousel = null;
        featured_carousel_category = null;
    }

    /**
     * Create an ArticleCard from a HeroCard and wire up all handlers
     * Used by search to convert hero cards to article cards for display
     */
    public ArticleCard create_article_card_from_hero(
        HeroCard hero,
        int col_w,
        int img_h,
        ArticleStateStore? state_store
    ) {
        var chip = new Gtk.Label("");
        chip.set_visible(false);

        var article_card = new ArticleCard(
            hero.title_label.get_label(),
            hero.url,
            col_w,
            img_h,
            chip,
            state_store,
            window
        );

        // Copy image
        if (hero.image.get_paintable() != null) {
            article_card.image.set_paintable(hero.image.get_paintable());
        }

        // Preserve metadata
        article_card.source_name = hero.source_name;
        article_card.category_id = hero.category_id;
        article_card.thumbnail_url = hero.thumbnail_url;

        // Wire up application-level handlers
        wire_article_card_handlers(article_card, hero.title_label.get_label(), hero.url, hero.thumbnail_url, hero.category_id, hero.source_name);

        return article_card;
    }

    /**
     * Wire up all handlers and registration for an article card
     * Centralizes the signal connections and state registration logic
     */
    public void wire_article_card_handlers(
        ArticleCard article_card,
        string title,
        string url,
        string? thumbnail_url,
        string? category_id,
        string? source_name
    ) {
        string norm = window.normalize_article_url(url);

        // Register with ViewStateManager
        if (window.view_state != null) {
            window.view_state.register_picture_for_url(norm, article_card.image);
            window.view_state.normalized_to_url.set(norm, url);
            window.view_state.register_card_for_url(norm, article_card.root);
        }

        // Register with ArticleStateStore
        if (window.article_state_store != null) {
            window.article_state_store.register_article(norm, category_id != null ? category_id : "", source_name);
        }

        // Connect activation to show preview
        article_card.activated.connect((s) => {
            if (window.article_pane != null) {
                window.article_pane.show_article_preview(title, url, thumbnail_url, category_id, source_name);
            }
        });

        // Context menu actions
        article_card.open_in_app_requested.connect((article_url) => {
            open_article_in_app_if_online(article_url);
        });

        article_card.open_in_browser_requested.connect((article_url) => {
            open_article_in_browser_if_online(article_url);
        });

        article_card.follow_source_requested.connect((article_url, src_name) => {
            request_show_toast("Searching for feed...", true);
            if (window.source_manager != null) {
                window.source_manager.follow_rss_source(article_url, src_name);
            }
        });

        article_card.save_for_later_requested.connect((article_url) => {
            if (window.article_state_store != null) {
                bool is_saved = window.article_state_store.is_saved(article_url);
                if (is_saved) {
                    window.article_state_store.unsave_article(article_url);
                    if (window.sidebar_manager != null) {
                        window.sidebar_manager.update_badge_for_category("saved");
                    }
                    if (window.prefs.category == "saved") {
                        if (window.animation_manager != null) {
                            var w = article_card.root;
                            string normalized = norm;
                            if (window.view_state != null) window.view_state.unregister_card_for_url(normalized);
                            window.animation_manager.animate_card_exit_and_remove(w, 0);
                        } else {
                            window.fetch_news();
                        }
                    }
                    request_show_toast("Removed article from saved");
                } else {
                    window.article_state_store.save_article(article_url, title, thumbnail_url, source_name);
                    if (window.sidebar_manager != null) {
                        window.sidebar_manager.update_badge_for_category("saved");
                    }
                    request_show_toast("Added article to saved");
                }
            }
        });

        article_card.share_requested.connect((article_url) => {
            if (window != null) {
                window.show_share_dialog(article_url);
            }
        });
    }
}
}
