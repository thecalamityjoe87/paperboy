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
        // Hero cards lay text/picture side by side, so the picture spans the
        // card's full height - default/max must match so images and
        // placeholders size consistently.
        public const int HERO_MAX_HEIGHT = 460;
        public const int HERO_DEFAULT_HEIGHT = 460;
        public const int TOPTEN_HERO_MAX_HEIGHT = 480;
        public const int TOPTEN_HERO_DEFAULT_HEIGHT = 480;
        public const int CARD_IMAGE_HEIGHT = 220;  // Fixed, never derived from column width
        public const int CARD_HEIGHT_ESTIMATE_OFFSET = 120;
        public const int IMAGE_QUALITY_MULTIPLIER_HIGH = 6;
        public const int IMAGE_QUALITY_MULTIPLIER_MEDIUM = 3;
        public const int IMAGE_QUALITY_MULTIPLIER_LOW = 2;
        
        public Gee.ArrayList<ArticleItem> article_buffer;
        public Gee.ArrayList<ArticleItem> remaining_articles;
        // Per-category counts of remaining_articles, kept in sync on every
        // add/remove so remaining_count_for_category() is O(1).
        private Gee.HashMap<string, int> remaining_category_counts;
        // Debounces reveal_sections_with_pending_overflow() so a whole batch
        // of queued overflow articles triggers one reveal pass, not one per article.
        private bool reveal_pending = false;
        public int articles_shown = 0;

        // Per-row real-card counts for My Feed (keyed by section key, e.g.
        // "source:guardian" or a bare category id), reset each fetch. My Feed
        // has many independent rows rather than one flat grid, so each row
        // gets its own modest cap instead of sharing articles_shown/INITIAL_ARTICLE_LIMIT
        // (see add_item) - otherwise a full load could build hundreds of
        // real card widgets, each with its own image fetch, at once.
        private Gee.HashMap<string, int>? myfeed_row_card_counts = null;
        private const int MYFEED_ROW_CARD_CAP = 10;

        // URLs that actually got a real card built in the current My Feed
        // build (see place_myfeed_article_cards) - reset once per My Feed
        // fetch by LayoutManager.prepare_myfeed_sections(), not by the
        // general clear_articles() (which runs on every category switch and
        // would otherwise wipe this the moment the user leaves My Feed).
        // ArticleStateStore.get_unread_count_for_myfeed() uses this instead
        // of the full registered-article pool, which includes far more
        // articles than MYFEED_ROW_CARD_CAP ever lets onto the page.
        private Gee.HashSet<string>? myfeed_displayed_urls = null;

        // Track URLs seen in current view to prevent duplicate cards
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

        private bool is_limited_category(string category) {
            return CategoryManager.is_limited_category(category);
        }

        private bool is_regular_news_category(string category) {
            return CategoryManager.is_regular_news_category(category);
        }

        private string? normalize_source_name(string? source_name, string category_id, string url) {
            return SourceManager.normalize_source_name(source_name, category_id, url);
        }

        // Returns false if the article is a duplicate (already queued this view).
        private bool queue_overflow_article(string title, string url, string? thumbnail_url,
                                            string category_id, string? source_name, string? published = null, string? snippet = null) {
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
            queued_item.snippet = snippet;
            remaining_articles.add(queued_item);
            string display_cat = extract_display_category(queued_item);
            remaining_category_counts.set(display_cat, remaining_category_counts.get(display_cat) + 1);

            // Register for unread tracking
            string norm = url.strip();
            if (norm.length > 0 && window.article_state_store != null) {
                window.article_state_store.register_article(norm, category_id, normalized_source);
            }

            // A category with zero cards in the initial cap would otherwise
            // stay hidden with no way to reach its queued overflow - see
            // LayoutManager.reveal_sections_with_pending_overflow(). Debounced
            // via a single Idle.add latch so a batch of articles triggers one
            // reveal pass, not one per article.
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

        // On Front Page, category_id is always "frontpage" - the real
        // category travels in source_name as a "##category::<cat>" suffix.
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

        public int remaining_count_for_category(string cat) {
            if (remaining_category_counts == null) return 0;
            return remaining_category_counts.get(cat);
        }

        // Removes matched items from the shared remaining_articles pool
        // rather than tracking an index cursor, since load_more_articles()
        // also draws from the same queue.
        public void load_more_for_category(string cat, int max_to_load = LOAD_MORE_BATCH_SIZE) {
            if (remaining_articles == null) return;

            // Snapshot current card count so newly appended cards can be
            // given the same fade/slide entrance as the global "load more" flow.
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

        private bool debug_enabled() {
            string? e = Environment.get_variable("PAPERBOY_DEBUG");
            return e != null && e.length > 0;
        }

        // My Feed's row identity for one article ("source:<id>" or
        // "customfeed:<url>"). Must be resolved before normalize_source_name
        // rewrites source_name into a display name, since matching against
        // enabled sources depends on seeing the raw name/URL.
        private string? resolve_myfeed_row_key_hint(string category_id, string? source_name) {
            if (category_id == "myfeed") {
                return (source_name != null && source_name.length > 0) ? "customfeed:" + source_name : null;
            }
            if (source_name == null || source_name.length == 0 || window.source_manager == null) return null;
            foreach (var src in window.source_manager.get_enabled_source_enums()) {
                if (SourceManager.source_name_matches(src, source_name)) {
                    return "source:" + SourceManager.source_enum_to_id(src);
                }
            }
            return null;
        }

        public void add_item(string title, string url, string? thumbnail_url, string category_id, string? source_name, string? published = null, string? snippet = null) {
            bool is_myfeed = window.category_manager.is_myfeed_view();

            // My Feed doesn't use the flat article-count cap: its rows are
            // independent scrolling strips, not one shared grid, and several
            // row kinds have no "load more" path to rescue overflow (see
            // LayoutManager.reveal_sections_with_pending_overflow).
            if (!is_myfeed && is_limited_category(window.prefs.category)) {
                lock (articles_shown) {
                    if (articles_shown >= INITIAL_ARTICLE_LIMIT) {
                        if (queue_overflow_article(title, url, thumbnail_url, category_id, source_name, published, snippet)) {
                            show_load_more_button();
                        }
                        return;
                    }
                }
            }

            string? myfeed_row_key_hint = is_myfeed ? resolve_myfeed_row_key_hint(category_id, source_name) : null;

            string? final_source_name = normalize_source_name(source_name, category_id, url);

            string normalized = "";
            if (url != null) normalized = window.normalize_article_url(url);
            if (normalized == null) normalized = "";

            // Skip if already seen this view session, to avoid duplicate cards
            // when multiple async fetches race on the same URL. Top Ten allows
            // duplicates intentionally (same headline from multiple providers).
            if (window.prefs.category != "topten" && normalized.length > 0 && seen_urls != null) {
                lock (seen_urls) {
                    if (seen_urls.contains(normalized)) {
                        // Backfill the already-rendered card's time label if this
                        // duplicate call carries a published date it doesn't have yet.
                        if (published != null && published.length > 0 && window.view_state != null) {
                            var existing_widgets = window.view_state.get_cards_for_url(normalized);
                            if (existing_widgets != null) {
                                foreach (var existing_widget in existing_widgets) {
                                    Gtk.Label? existing_time_label = existing_widget.get_data<Gtk.Label>("article-time-label");
                                    if (existing_time_label != null && existing_time_label.get_text() == "") {
                                        existing_time_label.set_text(DateUtils.time_ago(published));
                                    }
                                }
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
                    // Reuse an existing Picture mapping to avoid duplicate image
                    // widgets for the same normalized URL. Skip on Top Ten, where
                    // distinct headlines can normalize to the same URL (tracking
                    // params stripped) and shouldn't collapse into one card.
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
                        if (window.loading_state != null && window.loading_state.initial_phase) window.loading_state.pending_images++;
                        window.image_manager.load_image_async(existing, thumbnail_url, target_w, target_h, true);
                        return;
                    } else {
                    }
            }

            // Saved articles should always display regardless of source
            bool is_saved_view = (window.prefs.category == "saved");

            if (!is_saved_view) {
                if (!window.category_manager.should_display_article(category_id)) {
                    if (debug_enabled()) {
                        warning("Article filtered by category: view=%s article_cat=%s title=%s",
                                window.category_manager.get_current_category(), category_id, title);
                    }
                    return;
                }

                if (!window.source_manager.should_display_article(url, category_id)) {
                    return;
                }
            }

            add_item_immediate_to_column(title, url, thumbnail_url, category_id, null, final_source_name, false, published, snippet, myfeed_row_key_hint);
        }

        public void add_item_immediate_to_column(string title, string url, string? thumbnail_url, string category_id, string? original_category = null, string? source_name = null, bool bypass_limit = false, string? published = null, string? snippet = null, string? myfeed_row_key_hint = null) {
            // Buffer this article's snippet/published date as a fallback for
            // ArticleSnippetService, which live-fetches the article page and
            // falls back to article_buffer when that fetch fails or is incomplete.
            bool has_snippet = snippet != null && snippet.length > 0;
            bool has_published = published != null && published.length > 0;
            if ((has_snippet || has_published) && article_buffer != null) {
                var buffered_item = new ArticleItem(title, url, thumbnail_url, category_id, source_name, published);
                if (has_snippet) buffered_item.snippet = snippet;
                article_buffer.add(buffered_item);
            }

            string decoded_title = stripHtmlUtils.strip_html(title);

            string check_category = original_category ?? window.prefs.category;

            // My Feed is exempt here too - see add_item() above.
            if (is_limited_category(check_category) && !bypass_limit && window.prefs.category != "myfeed") {
                lock (articles_shown) {
                    if (articles_shown >= INITIAL_ARTICLE_LIMIT) {
                        if (title == null || url == null) {
                            return;
                        }

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
                should_be_hero = false;
            } else if (window.prefs.category == "topten") {
                should_be_hero = (topten_hero_count < 2);
            } else if (window.prefs.category == "frontpage") {
                should_be_hero = !featured_used;
            } else if (window.category_manager.is_rssfeed_view()) {
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

                // Skipped for Top Ten: its stacked layout only has room for the title.
                if (window.prefs.category != "topten") {
                    ArticleSnippetService.attach_hero_snippet(hero_card, url, source_name, article_buffer);
                }

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
                    if (window.loading_state != null && window.loading_state.initial_phase) window.loading_state.pending_images++;
                    if (window.image_manager != null) window.image_manager.pending_local_placeholder.set(hero_card.image, category_id == "local_news");
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

                hero_card.source_name = source_name;
                hero_card.category_id = category_id;
                hero_card.thumbnail_url = thumbnail_url;

                // Note: source_name is already normalized by add_item() before being passed here
                if (window.article_state_store != null) {
                    window.article_state_store.register_article(_norm, category_id, source_name);
                }

                // Capture plain widget locals instead of referencing
                // hero_card.root/save_ribbon inside these callbacks - see
                // HeroCard.wire_interactions().
                var hero_root = hero_card.root;
                var hero_save_ribbon = hero_card.save_ribbon;
                HeroCard.wire_interactions(
                    hero_root,
                    url,
                    enable_hero_context_menu,
                    window.article_state_store,
                    window,
                    source_name,
                    category_id,
                    thumbnail_url,
                    hero_card.title_label,
                    hero_card.image,
                    hero_card.viewed_badge_slot,
                    hero_card.footer_box,
                    hero_card.overlay,
                    (s) => { if (window.article_pane != null) window.article_pane.show_article_preview(decoded_title, url, thumbnail_url, category_id, source_name); },
                    (article_url) => { open_article_in_app_if_online(article_url); },
                    (article_url) => { open_article_in_browser_if_online(article_url); },
                    (article_url, src_name) => {
                        request_show_toast("Searching for feed...", true);
                        window.source_manager.follow_rss_source(article_url, src_name);
                    },
                    (article_url) => {
                        if (window.article_state_store != null) {
                            bool is_saved = window.article_state_store.is_saved(article_url);
                            if (is_saved) {
                                window.article_state_store.unsave_article(article_url);
                                request_show_toast("Removed article from saved");
                                if (window.animation_manager != null) {
                                    window.animation_manager.animate_save_toggle(hero_root, hero_save_ribbon, decoded_title, false);
                                }

                                if (window.prefs.category == "saved") {
                                    if (window.animation_manager != null) {
                                        var w = hero_root;
                                        string? normalized = null;
                                        if (window.view_state != null) normalized = window.view_state.normalize_article_url(article_url);
                                        if (normalized != null && window.view_state != null) window.view_state.unregister_card_for_url(normalized);
                                        window.animation_manager.animate_card_exit_and_remove(w, 0);
                                    } else {
                                        window.fetch_news();
                                    }
                                }
                            } else {
                                window.article_state_store.save_article(article_url, decoded_title, thumbnail_url, source_name, published);
                                request_show_toast("Added article to saved");
                                if (window.animation_manager != null) {
                                    window.animation_manager.animate_save_toggle(hero_root, hero_save_ribbon, decoded_title, true);
                                }
                            }
                        }
                    },
                    (article_url) => { window.show_share_dialog(article_url); }
                );

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
                allow_slide = (category_id.has_prefix("rssfeed:") || category_id == "myfeed");
            } else {
                allow_slide = (category_id == window.prefs.category);
            }
            if (!allow_slide) {
                return;
            }

            string slide_display_cat = category_id;
            if (slide_display_cat == "frontpage" && source_name != null) {
                int idx2 = source_name.index_of("##category::");
                if (idx2 >= 0 && source_name.length > idx2 + 12) slide_display_cat = source_name.substring(idx2 + 12).strip();
            }

            if (hero_carousel == null && window.layout_manager != null && window.layout_manager.featured_box != null) {
                hero_carousel = new HeroCarousel(window.layout_manager.featured_box);
            }

            var slide_chip = window.build_category_chip(slide_display_cat);
            var components = hero_carousel.create_article_slide(
                decoded_title, url, thumbnail_url, category_id, source_name, slide_chip,
                (t, u, thumb, cat, src) => { window.article_pane.show_article_preview(t, u, thumb, cat, src); },
                published
            );

            var slide_hero = components.hero;
            if (slide_hero != null) {
                ArticleSnippetService.attach_hero_snippet(slide_hero, url, source_name, article_buffer);
                if (category_id != "local_news") {
                    var slide_source_badge = window.build_source_badge_dynamic(source_name, url, category_id);
                    slide_hero.overlay.add_overlay(slide_source_badge);
                }
            }
            var slide = components.slide;
            var slide_image = components.image;

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
                int multiplier = IMAGE_QUALITY_MULTIPLIER_HIGH;
                if (window.loading_state != null && window.loading_state.initial_phase) window.loading_state.pending_images++;
                if (window.image_manager != null) window.image_manager.pending_local_placeholder.set(slide_image, category_id == "local_news");
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

            string _norm2 = window.normalize_article_url(url);
            if (window.article_state_store != null) {
                window.article_state_store.register_article(_norm2, category_id, source_name);
            }

            return;
        }

        if (window.layout_manager == null) {
            warning("ArticleManager: layout_manager not initialized, cannot place card");
            return;
        }

        // My Feed's section rows place this article twice - once in its
        // source's row, once in its category's row (see
        // LayoutManager.prepare_myfeed_sections) - since a widget can only
        // have one parent. Every other view builds exactly one card.
        if (window.category_manager.is_myfeed_view() && window.layout_manager.is_using_category_sections()) {
            place_myfeed_article_cards(decoded_title, url, thumbnail_url, category_id, source_name, bypass_limit, published, myfeed_row_key_hint);
        } else {
            string card_display_cat = category_id;
            if (card_display_cat == "frontpage" && source_name != null) {
                int idx3 = source_name.index_of("##category::");
                if (idx3 >= 0 && source_name.length > idx3 + 12) card_display_cat = source_name.substring(idx3 + 12).strip();
            }
            place_regular_article_card(decoded_title, url, thumbnail_url, category_id, source_name, bypass_limit, published, card_display_cat, false);
        }
    }

    // Places one article into My Feed's row-based layout: 0, 1, or 2 cards,
    // depending on whether the article's category and/or source has a live
    // row (see LayoutManager.resolve_myfeed_category_key/resolve_myfeed_source_key).
    private void place_myfeed_article_cards(string decoded_title, string url, string? thumbnail_url, string category_id, string? source_name, bool bypass_limit, string? published, string? myfeed_row_key_hint) {
        string? cat_key = window.layout_manager.resolve_myfeed_category_key(category_id);
        string? src_key = window.layout_manager.resolve_myfeed_source_key(myfeed_row_key_hint);

        bool placed = false;
        // Either placement may legitimately miss a row - skip that half
        // gracefully rather than falling back to a catch-all.
        if (cat_key != null && try_take_myfeed_row_slot(cat_key)) {
            place_regular_article_card(decoded_title, url, thumbnail_url, category_id, source_name, bypass_limit, published, cat_key, true);
            placed = true;
        }
        if (src_key != null && try_take_myfeed_row_slot(src_key)) {
            place_regular_article_card(decoded_title, url, thumbnail_url, category_id, source_name, bypass_limit, published, src_key, true);
            placed = true;
        }
        if (placed) {
            if (myfeed_displayed_urls == null) myfeed_displayed_urls = new Gee.HashSet<string>();
            myfeed_displayed_urls.add(window.normalize_article_url(url));
        }
    }

    // Reset once per My Feed fetch (see LayoutManager.prepare_myfeed_sections)
    // so the badge count reflects only the current build's cards.
    public void reset_myfeed_displayed_urls() {
        if (myfeed_displayed_urls == null) myfeed_displayed_urls = new Gee.HashSet<string>();
        else myfeed_displayed_urls.clear();
    }

    public Gee.HashSet<string> get_myfeed_displayed_urls() {
        if (myfeed_displayed_urls == null) myfeed_displayed_urls = new Gee.HashSet<string>();
        return myfeed_displayed_urls;
    }

    // Claims one of MYFEED_ROW_CARD_CAP real-card slots for this row key,
    // returning false once that row is full so the caller skips building
    // a widget for it. Each row is independent - a full "Guardian" row
    // doesn't affect the "Technology" row's own budget.
    private bool try_take_myfeed_row_slot(string row_key) {
        if (myfeed_row_card_counts == null) myfeed_row_card_counts = new Gee.HashMap<string, int>();
        int count = myfeed_row_card_counts.has_key(row_key) ? myfeed_row_card_counts.get(row_key) : 0;
        if (count >= MYFEED_ROW_CARD_CAP) return false;
        myfeed_row_card_counts.set(row_key, count + 1);
        return true;
    }

    // Builds one regular (non-hero, non-carousel) article card and places it
    // into section_key's section (or the flat grid outside sections mode).
    // no_fallback_section: when true, an unrecognized section_key means skip
    // placement (My Feed rows); when false, falls back to Front Page's
    // "More Stories" catch-all.
    private void place_regular_article_card(
        string decoded_title,
        string url,
        string? thumbnail_url,
        string category_id,
        string? source_name,
        bool bypass_limit,
        string? published,
        string section_key,
        bool no_fallback_section
    ) {
        // Use the column width cached for this layout pass rather than
        // recomputing per-card, so every card gets identical dimensions even
        // if the reported content width drifts while articles stream in.
        int col_w = 400;
        if (window.layout_manager != null) {
            col_w = window.layout_manager.cached_col_w > 0
                ? window.layout_manager.cached_col_w
                : window.layout_manager.estimate_column_width(window.layout_manager.columns_count);
        }
        int img_w = col_w;
        // Fixed height, not derived from col_w, so every card's picture area
        // matches even if col_w is read at slightly different times.
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
            section_key,
            published,
            no_fallback_section
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
            bool single_source = (window.prefs.preferred_sources != null && window.prefs.preferred_sources.size == 1);
            int multiplier = single_source ? 3 : ((window.loading_state != null && window.loading_state.initial_phase) ? 2 : 3);
            if (window.loading_state != null && window.loading_state.initial_phase) window.loading_state.pending_images++;
            if (window.image_manager != null) window.image_manager.pending_local_placeholder.set(article_card.image, category_id == "local_news");
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

        article_card.source_name = source_name;
        article_card.category_id = category_id;
        article_card.thumbnail_url = thumbnail_url;

        // bypass_limit articles were already registered when queued as overflow.
        if (window.article_state_store != null && !bypass_limit) {
            window.article_state_store.register_article(_norm, category_id, source_name);
        }

        var card_root = article_card.root;
        var card_save_ribbon = article_card.save_ribbon;
        ArticleCard.wire_interactions(
            card_root,
            url,
            window.article_state_store,
            window,
            source_name,
            (s) => { if (window.article_pane != null) window.article_pane.show_article_preview(decoded_title, url, thumbnail_url, category_id, source_name); },
            (article_url) => { open_article_in_app_if_online(article_url); },
            (article_url) => { open_article_in_browser_if_online(article_url); },
            (article_url, src_name) => {
                request_show_toast("Searching for feed...", true);
                window.source_manager.follow_rss_source(article_url, src_name);
            },
            (article_url) => {
                if (window.article_state_store != null) {
                    bool is_saved = window.article_state_store.is_saved(article_url);
                    if (is_saved) {
                        window.article_state_store.unsave_article(article_url);
                        request_show_toast("Removed article from saved");
                        if (window.animation_manager != null) {
                            window.animation_manager.animate_save_toggle(card_root, card_save_ribbon, decoded_title, false);
                        }

                        if (window.prefs.category == "saved") {
                            if (window.animation_manager != null) {
                                        var w = card_root;
                                        string? normalized = null;
                                        if (window.view_state != null) normalized = window.view_state.normalize_article_url(article_url);
                                        if (normalized != null && window.view_state != null) window.view_state.unregister_card_for_url(normalized);
                                        window.animation_manager.animate_card_exit_and_remove(w, 0);
                            } else {
                                window.fetch_news();
                            }
                        }
                    } else {
                        window.article_state_store.save_article(article_url, decoded_title, thumbnail_url, source_name, published);
                        request_show_toast("Added article to saved");
                        if (window.animation_manager != null) {
                            window.animation_manager.animate_save_toggle(card_root, card_save_ribbon, decoded_title, true);
                        }
                    }
                }
            },
            (article_url) => { window.show_share_dialog(article_url); }
        );

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

            // Snapshot current card count to detect newly appended cards.
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
                // queue is a shared pool that load_more_for_category() also
                // pulls from out of order.
                var article = remaining_articles.remove_at(0);
                string display_cat = extract_display_category(article);
                remaining_category_counts.set(display_cat, remaining_category_counts.get(display_cat) - 1);
                // No need to check seen_urls - articles were already deduplicated
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
            // section's nav button instead of one global button.
            if (window.prefs.category == "frontpage") return;

            if (window.loading_state.loading_container != null && window.loading_state.loading_container.get_visible()) {
                return;
            }

            request_remove_end_feed_message();
            request_show_load_more_button();
            load_more_button_visible = true;
        }

        public void clear_load_more_button() {
            if (!load_more_button_visible) return;
            request_hide_load_more_button();
            load_more_button_visible = false;
        }

        public bool has_load_more_button() {
            return load_more_button_visible;
        }

        public void clear_articles() {
            // Article tracking (view/save state) is intentionally not cleared
            // here - unread counts persist across category switches.
            if (article_buffer != null) {
                article_buffer.clear();
            }

            if (remaining_articles != null) {
                remaining_articles.clear();
            }
            if (remaining_category_counts != null) {
                remaining_category_counts.clear();
            }
            articles_shown = 0;
            if (myfeed_row_card_counts != null) myfeed_row_card_counts.clear();

            if (seen_urls != null) {
                seen_urls.clear();
            }

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

            topten_hero_count = 0;

            if (featured_carousel_items != null) {
                featured_carousel_items.clear();
            }
            featured_carousel_category = null;
            featured_used = false;

            clear_load_more_button();

            if (window != null && window.layout_manager != null) {
                window.layout_manager.clear_columns();
            }
        }

        // Resets state for a new fetch: clears articles, stops the carousel
        // timer, and resets tracking. Call at the start of fetch_news().
        public void reset_for_new_fetch() {
            clear_articles();

            if (hero_carousel != null) {
                hero_carousel.stop_timer();
                if (hero_carousel.container != null && window.layout_manager.featured_box != null) {
                    window.layout_manager.featured_box.remove(hero_carousel.container);
                }
                hero_carousel = null;
            }

            if (featured_carousel_items != null) {
                featured_carousel_items.clear();
            }
            featured_carousel_category = null;
            featured_used = false;
            topten_hero_count = 0;

            if (buffer_flush_timeout_id > 0) {
                Source.remove(buffer_flush_timeout_id);
                buffer_flush_timeout_id = 0;
            }
        }
        
        private void show_end_of_feed_message() {
            if (window.loading_state != null) window.loading_state.show_end_of_feed_message();
        }


    private void set_smart_placeholder(Gtk.Picture image, int w, int h, string? source_name, string url) {
        if (window.category_manager.is_rssfeed_view() && source_name != null && source_name.length > 0) {
            window.set_rss_placeholder_image(image, w, h, source_name);
            return;
        }

        NewsSource resolved = window.resolve_source(source_name, url);
        NewsSource default_source = window.prefs.news_source;

        // A name that doesn't match the resolved default source's own name
        // means this is actually a custom RSS feed that fell back to the default.
        if (resolved == default_source && source_name != null && source_name.length > 0) {
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
        // Must stop the timer before dropping the reference, or its
        // GLib.Timeout source stays registered forever.
        if (hero_carousel != null) hero_carousel.stop_timer();
        hero_carousel = null;
        featured_carousel_category = null;
    }

    // Creates an ArticleCard from a hero's data and wires up handlers. Used
    // by search to convert hero cards to article cards for display. Takes
    // plain data rather than a HeroCard reference since a HeroCard isn't
    // reachable past its own construction.
    public ArticleCard create_article_card_from_hero(
        string hero_title,
        string hero_url,
        Gdk.Paintable? hero_paintable,
        string? hero_source_name,
        string? hero_category_id,
        string? hero_thumbnail_url,
        int col_w,
        int img_h,
        ArticleStateStore? state_store
    ) {
        var chip = new Gtk.Label("");
        chip.set_visible(false);

        var article_card = new ArticleCard(
            hero_title,
            hero_url,
            col_w,
            img_h,
            chip,
            state_store,
            window
        );

        // Copy image
        if (hero_paintable != null) {
            article_card.image.set_paintable(hero_paintable);
        }

        article_card.source_name = hero_source_name;
        article_card.category_id = hero_category_id;
        article_card.thumbnail_url = hero_thumbnail_url;

        wire_article_card_handlers(article_card, hero_title, hero_url, hero_thumbnail_url, hero_category_id, hero_source_name);

        return article_card;
    }

    public void wire_article_card_handlers(
        ArticleCard article_card,
        string title,
        string url,
        string? thumbnail_url,
        string? category_id,
        string? source_name
    ) {
        string norm = window.normalize_article_url(url);

        if (window.view_state != null) {
            window.view_state.register_picture_for_url(norm, article_card.image);
            window.view_state.normalized_to_url.set(norm, url);
            window.view_state.register_card_for_url(norm, article_card.root);
        }

        if (window.article_state_store != null) {
            window.article_state_store.register_article(norm, category_id != null ? category_id : "", source_name);
        }

        // Capture plain widget locals - see ArticleCard.wire_interactions().
        var card_root = article_card.root;
        var card_save_ribbon = article_card.save_ribbon;
        // Tagged here so on_save_for_later below can look it up by URL
        // instead of capturing card_root directly (would cycle with its own
        // gesture controller - see wire_interactions()).
        card_root.set_data("card-save-ribbon", card_save_ribbon);
        ArticleCard.wire_interactions(
            card_root,
            url,
            window.article_state_store,
            window,
            source_name,
            (s) => {
                if (window.article_pane != null) {
                    window.article_pane.show_article_preview(title, url, thumbnail_url, category_id, source_name);
                }
            },
            (article_url) => { open_article_in_app_if_online(article_url); },
            (article_url) => { open_article_in_browser_if_online(article_url); },
            (article_url, src_name) => {
                request_show_toast("Searching for feed...", true);
                if (window.source_manager != null) {
                    window.source_manager.follow_rss_source(article_url, src_name);
                }
            },
            (article_url) => {
                if (window.article_state_store != null) {
                    // Look up the card by URL rather than capturing it -
                    // see the comment above card_root.set_data() a few
                    // lines up.
                    string looked_up_norm = window.normalize_article_url(article_url);
                    Gtk.Widget? live_root = window.view_state != null ? window.view_state.get_card_for_url(looked_up_norm) : null;
                    Gtk.Widget? live_ribbon = live_root != null ? live_root.get_data<Gtk.Widget>("card-save-ribbon") : null;

                    bool is_saved = window.article_state_store.is_saved(article_url);
                    if (is_saved) {
                        window.article_state_store.unsave_article(article_url);
                        if (window.animation_manager != null && live_root != null && live_ribbon != null) {
                            window.animation_manager.animate_save_toggle(live_root, live_ribbon, title, false);
                        }
                        if (window.prefs.category == "saved") {
                            if (window.animation_manager != null && live_root != null) {
                                var w = live_root;
                                if (window.view_state != null) window.view_state.unregister_card_for_url(looked_up_norm);
                                window.animation_manager.animate_card_exit_and_remove(w, 0);
                            } else {
                                window.fetch_news();
                            }
                        }
                        request_show_toast("Removed article from saved");
                    } else {
                        window.article_state_store.save_article(article_url, title, thumbnail_url, source_name);
                        request_show_toast("Added article to saved");
                        if (window.animation_manager != null && live_root != null && live_ribbon != null) {
                            window.animation_manager.animate_save_toggle(live_root, live_ribbon, title, true);
                        }
                    }
                }
            },
            (article_url) => {
                if (window != null) {
                    window.show_share_dialog(article_url);
                }
            }
        );
    }
}
}
