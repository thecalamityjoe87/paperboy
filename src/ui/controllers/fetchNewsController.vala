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

public class FetchNewsController {

    // Non-capturing label forwarder used for passing a stable callback
    // into worker fetchers. It does not close over any stack state so
    // it is safe to pass across thread boundaries. It uses
    // Global label forwarder: looks up the current FetchContext and the
    // active window and update the header accordingly.
    public static void global_forward_label(string? text) {
        Idle.add(() => {
            var ctx = FetchContext.current_context();
            if (ctx == null) return false;
            var win = ctx.window;
            if (win == null) return false;

            // Detect errors in the label text and immediately show error message
            try {
                if (text != null) {
                    string lower = text.down();
                    if (lower.index_of("error") >= 0 || lower.index_of("failed") >= 0) {
                        if (win.loading_state != null) win.loading_state.network_failure_detected = true;
                        // Immediately show error message and hide spinner to prevent UI dead-end
                        win.hide_loading_spinner();
                        win.show_error_message(text);
                        // Cancel the timeout since we're showing error now (defensive check)
                        if (win.loading_state != null) {
                            var timeout_id = win.loading_state.initial_reveal_timeout_id;
                            if (timeout_id > 0) {
                                try {
                                    Source.remove(timeout_id);
                                    win.loading_state.initial_reveal_timeout_id = 0;
                                } catch (GLib.Error e) {
                                    warning("Failed to remove timeout: %s", e.message);
                                }
                            }
                        }
                        return false;
                    }
                }
            } catch (GLib.Error e) { }
            try { win.update_content_header(); } catch (GLib.Error e) { }
            return false;
        });
    }

    // Non-capturing global add_item used for background fetchers to
    // safely post article additions to the main loop. This avoids
    // passing per-fetch capturing delegates into worker threads which
    // can be freed while the worker still holds a reference.
    public static void global_add_item(string title, string url, string? thumbnail, string category_id, string? source_name) {
        Idle.add(() => {
            var cur = FetchContext.current_context();
            if (cur == null || !cur.is_valid()) return false;
            var w = cur.window;
            if (w == null) return false;

            try {
                // Safely access managers through local variables
                var cat_mgr = w.category_manager;
                var layout_mgr = w.layout_manager;
                var article_mgr = w.article_manager;

                // Track articles for adaptive layout (regular categories only, not RSS feeds)
                if (cat_mgr != null && layout_mgr != null && !cat_mgr.is_rssfeed_view()) {
                    bool is_regular_cat = !cat_mgr.is_frontpage_view() && !cat_mgr.is_topten_view() &&
                                         !cat_mgr.is_myfeed_category() && !cat_mgr.is_local_news_view() &&
                                         w.prefs != null && w.prefs.category != "saved";
                    if (is_regular_cat) {
                        try { layout_mgr.track_category_article(cur.seq); } catch (GLib.Error e) { }
                    }
                }
                if (article_mgr != null) {
                    try { article_mgr.add_item(title, url, thumbnail, category_id, source_name); } catch (GLib.Error e) { }
                }
            } catch (GLib.Error e) { }
            return false;
        });
    }

    // Non-capturing no-op clear used when we already cleared UI before
    // scheduling individual fetches. This avoids passing per-fetch
    // capturing clear callbacks into worker threads.
    public static void global_no_op_clear() {
        // intentionally empty
    }


    public static void fetch_news(NewsWindow win) {
        if (win == null) return;

        // === PHASE 1: Cleanup and preparation ===
        try { if (win.image_manager != null) win.image_manager.cleanup_stale_downloads(); } catch (GLib.Error e) { }

        // Reset article manager state (clears articles, stops carousel, cancels pending timeouts)
        try { if (win.article_manager != null) win.article_manager.reset_for_new_fetch(); } catch (GLib.Error e) { }

        // Clear old article tracking before fetching to prevent count accumulation
        // Skip clearing during initial_phase (startup) so unreadFetchService counts are preserved
        // Also skip for myfeed, local_news, and saved (which aggregate from multiple sources)
        bool is_initial = (win.loading_state != null && win.loading_state.initial_phase);
        if (!is_initial && win.article_state_store != null && win.prefs.category != null && win.prefs.category.length > 0) {
            string cat = win.prefs.category;
            bool skip_clear = (cat == "myfeed" || cat == "local_news" || cat == "saved");
            if (!skip_clear) {
                win.article_state_store.clear_category_articles(win.prefs.category);
            }
        }

        // Prepare layout (clears hero/featured containers, rebuilds columns)
        win.update_sidebar_for_source();
        bool is_topten = win.category_manager.is_topten_view();
        try { win.layout_manager.prepare_for_new_fetch(is_topten); } catch (GLib.Error e) { }

        // Reset adaptive layout tracking for new fetch
        try { win.layout_manager.reset_adaptive_tracking(); } catch (GLib.Error e) { }

        // For regular categories that may use adaptive layout, mark that we're awaiting
        // the adaptive layout check so the spinner stays visible until layout is finalized
        bool is_regular_category = !win.category_manager.is_frontpage_view() &&
                                   !win.category_manager.is_topten_view() &&
                                   !win.category_manager.is_myfeed_category() &&
                                   !win.category_manager.is_local_news_view() &&
                                   !win.category_manager.is_rssfeed_view() &&
                                   win.prefs.category != "saved";
        if (is_regular_category && win.loading_state != null) {
            win.loading_state.awaiting_adaptive_layout = true;
        }

        // Clean up memory
        win.cleanup_old_content();
        win.article_manager.article_buffer.clear();
        win.article_manager.articles_shown = 0;

        // Adjust preview cache size for Local News
        try {
            int cache_size = win.category_manager.is_local_news_view() ? 6 : 12;
            PreviewCacheManager.get_cache().set_capacity(cache_size);
        } catch (GLib.Error e) { }

        // === PHASE 2: Early exit checks ===
        bool is_myfeed_category = win.category_manager.is_myfeed_category();
        if (is_myfeed_category && !win.prefs.personalized_feed_enabled) {
            try { win.update_content_header(); } catch (GLib.Error e) { }
            try { win.update_personalization_ui(); } catch (GLib.Error e) { }
            win.hide_loading_spinner();
            return;
        }

        // === PHASE 3: Begin loading state ===
        try {
            var loading_state = win.loading_state;
            if (loading_state != null) {
                loading_state.begin_fetch();
                // Explicitly hide any previous error messages to ensure clean state
                // This is critical when switching categories after a timeout error
                loading_state.hide_error_message();
            }
        } catch (GLib.Error e) { }
        try { win.update_content_header_now(); } catch (GLib.Error e) { }

        // Create a new FetchContext early so early timeouts can use it.
        // This invalidates any previous context and holds a weak reference
        // to the window for safe async access. All window access must go
        // through FetchContext validation to avoid use-after-free.
        var ctx = FetchContext.begin_new(win);
        uint my_seq = ctx.seq;

        // Safety timeout: reveal after a reasonable maximum to avoid blocking forever
        var loading_state = win.loading_state;
        if (loading_state != null) {
            loading_state.initial_reveal_timeout_id = Timeout.add(NewsWindow.INITIAL_MAX_WAIT_MS, () => {
                if (!FetchContext.is_current(my_seq)) return false;
                var cur = FetchContext.current_context();
                if (cur == null) return false;
                var w = cur.window;
                if (w == null) return false;

                // Safely access loading_state through local variable
                var ls = w.loading_state;
                if (ls == null) return false;

                if (!ls.initial_items_populated) {
                    try {
                        if (ls.network_failure_detected) {
                            w.show_error_message("No network connection detected. Check your connection and try again.");
                        } else {
                            w.show_error_message();
                        }
                    } catch (GLib.Error e) { }
                } else {
                    // CRITICAL: Don't use reveal_initial_content() - it exits early if initial_phase is false
                    // After RSS timeout, initial_phase is already false, so directly show the container
                    try {
                        if (w.loading_state != null) {
                            w.loading_state.initial_phase = false;
                            w.loading_state.hero_image_loaded = false;
                        }
                        w.hide_loading_spinner();
                        if (w.main_content_container != null) {
                            w.main_content_container.set_visible(true);
                        }
                    } catch (GLib.Error e) { }
                }
                ls.initial_reveal_timeout_id = 0;
                return false;
            });
        }
        
        // NOTE: previously we took and later unreffed extra strong refs
        // to `self_ref` and `ctx` via timeouts. That pattern caused
        // use-after-free races when Vala-generated closure data was
        // freed while other callbacks still attempted to reference it.
        // We now rely on `FetchContext.is_current()` and
        // `FetchContext.current_context()` to validate access instead
        // of manipulating refcounts here.

        // Wrapped set_label: only update if this fetch is still current
        SetLabelFunc wrapped_set_label = (text) => {
            // Schedule UI updates on the main loop to avoid touching
            // window fields from worker threads. The Idle callback will
            // check the context validity before applying changes.
            Idle.add(() => {
                if (!FetchContext.is_current(my_seq)) return false;
                var cur = FetchContext.current_context();
                if (cur == null) return false;
                var w = cur.window;
                if (w == null) return false;
                // Detect error-like labels emitted by fetchers and mark a
                // network failure flag so the timeout can present a more
                // specific offline message. Many fetchers call set_label
                // with "... Error loading ..." when network issues occur.
                try {
                    if (text != null) {
                        string lower = text.down();
                        if (lower.index_of("error") >= 0 || lower.index_of("failed") >= 0) {
                            var ls = w.loading_state;
                            if (ls != null) {
                                ls.network_failure_detected = true;
                            }
                        }
                    }
                } catch (GLib.Error e) { }

                // Use the centralized header updater which enforces the exact
                // UI contract (icon + category, or Search Results when active).
                try { w.update_content_header(); } catch (GLib.Error e) { }
                return false;
            });
        };

        // Wrapped clear_items: only clear if this fetch is still current
        // Ensure we only clear once per fetch: some fetchers may call the
        // provided clear callback multiple times during retries/fallbacks.
        bool wrapped_clear_ran = false;
        ClearItemsFunc wrapped_clear = () => {
            // Schedule the clear on the main loop to avoid worker-thread UI access
            Idle.add(() => {
                if (!FetchContext.is_current(my_seq)) return false;
                var cur = FetchContext.current_context();
                if (cur == null) return false;
                var w = cur.window;
                if (w == null) return false;
                // Guard: make this clear idempotent per-fetch
                if (wrapped_clear_ran) {
                    return false;
                }
                wrapped_clear_ran = true;

                // Log execution of wrapped_clear so we can correlate clears with fetch sequences and view
                long _ts = (long) GLib.get_monotonic_time();
                
                // Clear UI via delegated managers
                // Safely access all managers through local variables to avoid TOCTOU
                var layout_mgr = w.layout_manager;
                var article_mgr = w.article_manager;
                var view_state_mgr = w.view_state;
                var image_mgr = w.image_manager;

                // 1. Clear Featured/Hero content
                if (layout_mgr != null) {
                    layout_mgr.clear_featured_box();
                }
                if (article_mgr != null) {
                    article_mgr.reset_featured_state();
                }

                // 2. Clear Article Columns
                if (layout_mgr != null) {
                    layout_mgr.clear_columns();
                }

                // 3. Reset Load More state
                if (article_mgr != null) {
                    article_mgr.clear_article_buffer();
                }

                // 4. Remove "No more articles" message
                if (layout_mgr != null) {
                    layout_mgr.remove_end_feed_message();
                }

                // 5. Ensure any load-more button managed by ArticleManager is removed
                if (article_mgr != null) {
                    article_mgr.clear_load_more_button();
                }

                // 6. Clear image bookkeeping
                try {
                    if (view_state_mgr != null && view_state_mgr.url_to_picture != null) {
                        view_state_mgr.url_to_picture.clear();
                    }
                } catch (GLib.Error e) { }
                try {
                    if (image_mgr != null && image_mgr.hero_requests != null) {
                        image_mgr.hero_requests.clear();
                    }
                } catch (GLib.Error e) { }

                // 7. Reset remaining articles state
                if (article_mgr != null) {
                    if (article_mgr.remaining_articles != null) {
                        article_mgr.remaining_articles.clear();
                    }
                    article_mgr.remaining_articles_index = 0;
                    article_mgr.articles_shown = 0;
                }
                
                return false;
            });
        };

        // Wrapped add_item: ignore items from stale fetches
        // Throttled add for Local News: queue incoming items and process in small batches
        var local_news_queue = new Gee.ArrayList<ArticleItem>();
        bool local_news_flush_scheduled = false;
        int local_news_items_enqueued = 0; // debug counter
        bool local_news_stats_scheduled = false;
        // General UI add queue to batch worker->main-thread article additions.
        // Using a single Idle to drain this queue avoids per-item refs on the
        // window/object and reduces thread churn that previously caused races
        // during heavy fetches.
        var ui_add_queue = new Gee.ArrayList<ArticleItem>();
        bool ui_add_idle_scheduled = false;

        AddItemFunc wrapped_add = (title, url, thumbnail, category_id, source_name) => {
            var cur_start = FetchContext.current_context();
            if (cur_start == null || cur_start.seq != my_seq) return;
            var w = cur_start.window;
            if (w == null) return;

            // Check article limit ONLY for limited categories, NOT frontpage/topten/all
            bool viewing_limited_category = (
                w.prefs.category == "general" ||
                w.prefs.category == "us" ||
                w.prefs.category == "sports" ||
                w.prefs.category == "science" ||
                w.prefs.category == "health" ||
                w.prefs.category == "technology" ||
                w.prefs.category == "business" ||
                w.prefs.category == "entertainment" ||
                w.prefs.category == "politics" ||
                w.prefs.category == "lifestyle" ||
                w.prefs.category == "markets" ||
                w.prefs.category == "industries" ||
                w.prefs.category == "economics" ||
                w.prefs.category == "wealth" ||
                w.prefs.category == "green"
                || w.prefs.category == "local_news"
                || w.prefs.category == "myfeed"
            );
                        
            // Don't check limit here - let add_item_immediate_to_column() handle it after filtering
            
            // If we're in Local News mode, enqueue and process in small batches to avoid UI lockups
            try {
                var prefs_local = NewsPreferences.get_instance();
                if (prefs_local != null && prefs_local.category == "local_news") {
                    local_news_queue.add(new ArticleItem(title, url, thumbnail, category_id, source_name));
                    local_news_items_enqueued++;
                    if (!local_news_flush_scheduled) {
                        local_news_flush_scheduled = true;
                        // Process up to 6 items per tick to keep UI responsive
                        Timeout.add(60, () => {
                            int processed = 0;
                            int batch = 6;
                            while (local_news_queue.size > 0 && processed < batch) {
                                var ai = local_news_queue.get(0);
                                local_news_queue.remove_at(0);
                                // Ensure still current before adding
                                if (!FetchContext.is_current(my_seq)) {
                                    // stale fetch; drop item
                                } else {
                                    var cur2 = FetchContext.current_context();
                                    if (cur2 != null) {
                                        var w2 = cur2.window;
                                        if (w2 != null) w2.article_manager.add_item(ai.title, ai.url, ai.thumbnail_url, ai.category_id, ai.source_name);
                                    }
                                }
                                processed++;
                            }
                            if (local_news_queue.size > 0) {
                                // Keep the timeout running until the queue is drained
                                return true;
                            } else {
                                local_news_flush_scheduled = false;

                                // Local News queue fully drained: refresh its badge now
                                try {
                                    if (w.sidebar_manager != null) {
                                        w.sidebar_manager.update_badge_for_category("local_news");
                                    }
                                } catch (GLib.Error e) { }

                                return false;
                            }
                        });
                    }
                    return;
                }
            } catch (GLib.Error e) { /* best-effort */ }
            
            // Add the article (handles deduplication)
            w.article_manager.add_item(title, url, thumbnail, category_id, source_name);
        };

        // Support fetching from multiple preferred sources when the user
        // has enabled more than one in preferences. The preferences store
        // string ids (e.g. "guardian", "reddit"). Map those to the
        // NewsSource enum and invoke NewsService.fetch for each. Ensure
        // we only clear the UI once (for the first fetch) so subsequent
        // fetches append their results.
        bool used_multi = false;
        // Use CategoryManager for My Feed logic
        bool is_myfeed_mode = win.category_manager.is_myfeed_view();
        string[] myfeed_cats = new string[0];

        // Load custom RSS sources if in My Feed mode
        Gee.ArrayList<Paperboy.RssSource>? custom_rss_sources = null;
        if (is_myfeed_mode) {
            var rss_store = Paperboy.RssSourceStore.get_instance();
            var all_custom = rss_store.get_all_sources();
            custom_rss_sources = new Gee.ArrayList<Paperboy.RssSource>();

            // Filter to only enabled custom sources
            foreach (var src in all_custom) {
                if (win.prefs.preferred_source_enabled("custom:" + src.url)) {
                    custom_rss_sources.add(src);
                }
            }
        }
        
        // Grab search query via getter
        string current_search_query = win.get_current_search_query();

        if (is_myfeed_mode) {
            // Load personalized categories if configured (applies only to built-in sources)
            if (win.category_manager.is_myfeed_configured()) {
                var cats = win.category_manager.get_myfeed_categories();
                myfeed_cats = new string[cats.size];
                for (int i = 0; i < cats.size; i++) myfeed_cats[i] = cats.get(i);
            }

            // Check if we have ANY content to show (personalized categories OR custom RSS sources)
            bool has_personalized_cats = (myfeed_cats != null && myfeed_cats.length > 0);
            bool has_custom_rss = (custom_rss_sources != null && custom_rss_sources.size > 0);

            if (!has_personalized_cats && !has_custom_rss) {
                // No personalized categories AND no custom RSS sources - nothing to show
                try { wrapped_clear(); } catch (GLib.Error e) { }
                try { wrapped_set_label("My Feed — No personalized categories or custom RSS feeds configured"); } catch (GLib.Error e) { }
                win.hide_loading_spinner();
                return;
            }
        }

        // Saved Articles: delegate to FetchNewsController helper
        if (win.prefs.category == "saved") {
            if (FetchNewsController.handle_saved_articles(win, ctx, current_search_query, wrapped_set_label, wrapped_clear, wrapped_add)) return;
        }

        if (win.category_manager.is_local_news_view()) {
            if (FetchNewsController.handle_local_news(win, ctx, wrapped_set_label, wrapped_clear, wrapped_add, win.session, current_search_query)) return;
        }

        // RSS Feed: if the user selected an individual RSS feed from the sidebar,
        // fetch articles from that specific feed URL using the RSS parser.
        if (win.category_manager.is_rssfeed_view()) {
            if (FetchNewsController.handle_rss_feed(win, wrapped_set_label, wrapped_clear, wrapped_add, win.session, current_search_query, my_seq))
                return;
        }
        // If the user selected "Front Page", always request the backend
        // frontpage endpoint regardless of preferred_sources. Place this
        // before the multi-source branch so frontpage works even when the
        // user has zero or one preferred source selected.
        if (win.category_manager.is_frontpage_view()) {
            // Present the multi-source label/logo in the header
            try {
                var header_mgr = win.header_manager;
                if (header_mgr != null) {
                    header_mgr.setup_multi_source_header();
                }
            } catch (GLib.Error e) { }
            used_multi = true;

            try { wrapped_clear(); } catch (GLib.Error e) { }
            // Debug marker: set a distinct label so we can confirm this branch runs
            try { wrapped_set_label("Frontpage — Loading from backend (branch 1)"); } catch (GLib.Error e) { }
            NewsService.fetch(win.prefs.news_source, "frontpage", current_search_query, win.session, FetchNewsController.global_forward_label, FetchNewsController.global_no_op_clear, FetchNewsController.global_add_item);

            // Schedule badge refresh for frontpage
            var sidebar_mgr = win.sidebar_manager;
            if (sidebar_mgr != null) {
                sidebar_mgr.schedule_badge_refresh("frontpage", my_seq);
            }
            return;
        }

        // If the user selected "Top Ten", request the backend headlines endpoint
        // regardless of preferred_sources. Same early-return logic as frontpage.
        if (win.category_manager.is_topten_view()) {
            // Present the multi-source label/logo in the header
            try {
                var header_mgr = win.header_manager;
                if (header_mgr != null) {
                    header_mgr.setup_multi_source_header();
                }
            } catch (GLib.Error e) { }
            used_multi = true;

            try { wrapped_clear(); } catch (GLib.Error e) { }
            try { wrapped_set_label("Top Ten — Loading from backend"); } catch (GLib.Error e) { }
            NewsService.fetch(win.prefs.news_source, "topten", current_search_query, win.session, FetchNewsController.global_forward_label, FetchNewsController.global_no_op_clear, FetchNewsController.global_add_item);

            // Schedule badge refresh for topten
            var sidebar_mgr = win.sidebar_manager;
            if (sidebar_mgr != null) {
                sidebar_mgr.schedule_badge_refresh("topten", my_seq);
            }
            return;
        }

        // Check if we should use multi-source mode (multiple built-in sources OR custom RSS sources in My Feed)
        // Skip multi-source mode for saved articles, local news, and individual RSS feeds - they have their own header setup
        bool is_saved_view = (win.prefs.category == "saved");
        int total_sources = (win.prefs.preferred_sources != null ? win.prefs.preferred_sources.size : 0);
        if (is_myfeed_mode && custom_rss_sources != null) {
            total_sources += custom_rss_sources.size;
        }

        if (!is_saved_view && (total_sources > 1 || (is_myfeed_mode && custom_rss_sources != null && custom_rss_sources.size > 0))) {
            // Treat The Frontpage as a multi-source view visually, but do NOT
            // let the user's preferred_sources list influence which providers
            // are queried. Instead, when viewing the special "frontpage"
            // category, simply request the backend frontpage once and present
            // the combined/multi-source UI.
            if (win.category_manager.is_frontpage_view()) {
                try {
                var header_mgr = win.header_manager;
                if (header_mgr != null) header_mgr.setup_multi_source_header();
            } catch (GLib.Error e) { }
                used_multi = true;

                // Clear UI and ask the backend frontpage fetcher once. NewsService
                // will route a request with current_category == "frontpage" to
                // the Paperboy backend fetcher regardless of the NewsSource value.
                try { wrapped_clear(); } catch (GLib.Error e) { }
                NewsService.fetch(win.prefs.news_source, "frontpage", current_search_query, win.session, FetchNewsController.global_forward_label, FetchNewsController.global_no_op_clear, FetchNewsController.global_add_item);
                
                // Schedule badge refresh for frontpage
                var sidebar_mgr = win.sidebar_manager;
                if (sidebar_mgr != null) {
                    sidebar_mgr.schedule_badge_refresh("frontpage", my_seq);
                }
                return;
            }

            // Same logic for Top Ten: request backend headlines endpoint
            if (win.category_manager.is_topten_view()) {
                try {
                var header_mgr = win.header_manager;
                if (header_mgr != null) header_mgr.setup_multi_source_header();
            } catch (GLib.Error e) { }
                used_multi = true;

                try { wrapped_clear(); } catch (GLib.Error e) { }
                NewsService.fetch(win.prefs.news_source, "topten", current_search_query, win.session, FetchNewsController.global_forward_label, FetchNewsController.global_no_op_clear, FetchNewsController.global_add_item);
                
                // Schedule badge refresh for topten
                var sidebar_mgr = win.sidebar_manager;
                if (sidebar_mgr != null) {
                    sidebar_mgr.schedule_badge_refresh("topten", my_seq);
                }
                return;
            }

            // Display a combined label and bundled monochrome logo for multi-source mode
            try {
                var header_mgr = win.header_manager;
                if (header_mgr != null) header_mgr.setup_multi_source_header();
            } catch (GLib.Error e) { }
            used_multi = true;

            //Use SourceManager to get enabled sources as enums
            Gee.ArrayList<NewsSource> srcs = win.source_manager.get_enabled_source_enums();

            // If mapping failed or produced no sources, fall back to single source
            if (srcs.size == 0) {
                NewsService.fetch(
                    win.prefs.news_source,
                    win.prefs.category,
                    current_search_query,
                    win.session,
                    FetchNewsController.global_forward_label,
                    FetchNewsController.global_no_op_clear,
                    FetchNewsController.global_add_item
                );
            } else {
                // Filter the selected sources to those that actually support
                // the requested category. Special-case the personalized
                // My Feed mode: prefs.category == "myfeed" is not a real
                // provider category, so check per-personalized-category
                // support (e.g., Bloomberg supports markets/industries but
                // not a generic "myfeed"). This ensures Bloomberg isn't
                // excluded from the combined fetch when the user has
                // selected Bloomberg-specific personalized categories.
                var filtered = new Gee.ArrayList<NewsSource>();
                foreach (var s in srcs) {
                    try {
                        bool include = false;
                        if (is_myfeed_mode) {
                            // If no personalized categories selected, be permissive
                            if (myfeed_cats == null || myfeed_cats.length == 0) {
                                include = true;
                            } else {
                                foreach (var cat in myfeed_cats) {
                                    if (NewsService.supports_category(s, cat)) { include = true; break; }
                                }
                            }
                        } else {
                            if (NewsService.supports_category(s, win.prefs.category)) include = true;
                        }
                        if (include) filtered.add(s);
                    } catch (GLib.Error e) {
                        // If something goes wrong querying support, include the source
                        filtered.add(s);
                    }
                }

                // If filtering removed all sources (unlikely), fall back to original
                // list so we at least attempt to fetch something.
                var use_srcs = filtered.size > 0 ? filtered : srcs;

                // Clear the UI once up-front so we don't race with asynchronous
                // fetch completions (a later-completing fetch shouldn't be able
                // to wipe results added by an earlier one).
                try { wrapped_clear(); } catch (GLib.Error e) { }

                // Use a no-op clear for all individual fetches since we've
                // already cleared above. Keep a combined label while in multi
                // source mode. If we're in My Feed personalized mode, request
                // each personalized category separately and combine results.
                ClearItemsFunc no_op_clear = () => { };
                SetLabelFunc label_fn = (text) => {
                        Idle.add(() => {
                            if (!FetchContext.is_current(my_seq)) return false;
                            var cur = FetchContext.current_context();
                            if (cur == null) return false;
                            var w = cur.window;
                            if (w == null) return false;
                            try { w.update_content_header(); } catch (GLib.Error e) { }
                            return false;
                        });
                };

                // Fetch from built-in sources (unless in My Feed with custom_only mode enabled)
                bool skip_builtin = is_myfeed_mode && win.prefs.myfeed_custom_only;
                if (!skip_builtin) {
                    foreach (var s in use_srcs) {
                        if (is_myfeed_mode) {
                            foreach (var cat in myfeed_cats) {
                                NewsService.fetch(s, cat, current_search_query, win.session, FetchNewsController.global_forward_label, FetchNewsController.global_no_op_clear, FetchNewsController.global_add_item);
                            }
                        } else {
                            NewsService.fetch(s, win.prefs.category, current_search_query, win.session, FetchNewsController.global_forward_label, FetchNewsController.global_no_op_clear, FetchNewsController.global_add_item);
                        }
                    }
                }

                // Schedule badge refresh for non-myfeed categories after articles register
                if (!is_myfeed_mode) {
                    var sidebar_mgr = win.sidebar_manager;
                    if (sidebar_mgr != null) {
                        sidebar_mgr.schedule_badge_refresh(win.prefs.category, my_seq);
                    }
                    // Adaptive layout is now handled by track_category_article() for regular categories
                }

                // Fetch from custom RSS sources if in My Feed mode and sources are enabled
                if (is_myfeed_mode && custom_rss_sources != null && custom_rss_sources.size > 0) {
                    // Don't set featured_used - allow first article to become hero/carousel
                    foreach (var rss_src in custom_rss_sources) {
                        RssFeedProcessor.fetch_rss_url(
                            rss_src.url,
                            rss_src.name,
                            "My Feed",
                            "myfeed",
                            current_search_query,
                            win.session,
                            FetchNewsController.global_forward_label,
                            no_op_clear,
                            FetchNewsController.global_add_item
                        );
                    }
                }
            }
        } else {
            // Single-source path: keep existing behavior. Use the
            // effective source so a single selected preferred_source is
            // respected without requiring prefs.news_source to be changed.
            // Special-case: when viewing The Frontpage in single-source
            // mode, make sure we still request the backend frontpage API.
            if (win.category_manager.is_frontpage_view()) {
                try { wrapped_clear(); } catch (GLib.Error e) { }
                try { wrapped_set_label("Frontpage — Loading from backend (single-source)"); } catch (GLib.Error e) { }
                NewsService.fetch(win.prefs.news_source, "frontpage", current_search_query, win.session, FetchNewsController.global_forward_label, FetchNewsController.global_no_op_clear, FetchNewsController.global_add_item);
                
                // Schedule badge refresh for frontpage
                var sidebar_mgr = win.sidebar_manager;
                if (sidebar_mgr != null) {
                    sidebar_mgr.schedule_badge_refresh("frontpage", my_seq);
                }
                return;
            }

            // Same for Top Ten in single-source mode
            if (win.category_manager.is_topten_view()) {
                try { wrapped_clear(); } catch (GLib.Error e) { }
                try { wrapped_set_label("Top Ten — Loading from backend (single-source)"); } catch (GLib.Error e) { }
                NewsService.fetch(win.prefs.news_source, "topten", current_search_query, win.session, FetchNewsController.global_forward_label, FetchNewsController.global_no_op_clear, FetchNewsController.global_add_item);
                
                // Schedule badge refresh for topten
                var sidebar_mgr = win.sidebar_manager;
                if (sidebar_mgr != null) {
                    sidebar_mgr.schedule_badge_refresh("topten", my_seq);
                }
                return;
            }

            if (is_myfeed_mode) {
                // Fetch each personalized category for the single effective source
                try { wrapped_clear(); } catch (GLib.Error e) { }
                ClearItemsFunc no_op_clear = () => { };
                SetLabelFunc label_fn = (text) => {
                    Idle.add(() => {
                        if (!FetchContext.is_current(my_seq)) return false;
                        var cur = FetchContext.current_context();
                        if (cur == null) return false;
                        var w = cur.window;
                        if (w == null) return false;
                        try { w.update_content_header(); } catch (GLib.Error e) { }
                        return false;
                    });
                };

                // Fetch from built-in source (unless custom_only mode is enabled in My Feed)
                if (!win.prefs.myfeed_custom_only) {
                    foreach (var cat in myfeed_cats) {
                        NewsService.fetch(win.effective_news_source(), cat, current_search_query, win.session, FetchNewsController.global_forward_label, FetchNewsController.global_no_op_clear, FetchNewsController.global_add_item);
                    }
                }

                // Fetch from custom RSS sources if sources are enabled
                if (custom_rss_sources != null && custom_rss_sources.size > 0) {
                    win.article_manager.featured_used = true;
                    foreach (var rss_src in custom_rss_sources) {
                        RssFeedProcessor.fetch_rss_url(
                            rss_src.url,
                            rss_src.name,
                            "My Feed",
                            "myfeed",
                            current_search_query,
                            win.session,
                            (text) => {
                                Idle.add(() => {
                                    if (!FetchContext.is_current(my_seq)) return false;
                                    var cur = FetchContext.current_context();
                                    if (cur == null) return false;
                                    var w = cur.window;
                                    if (w == null) return false;
                                    try { w.update_content_header(); } catch (GLib.Error e) { }
                                    return false;
                                });
                            },
                            no_op_clear,
                            wrapped_add
                        );
                    }
                }

                // Schedule a one-shot badge refresh for My Feed after initial
                // results have had a chance to register in ArticleStateStore.
                var sidebar_mgr = win.sidebar_manager;
                if (sidebar_mgr != null) {
                    sidebar_mgr.schedule_badge_refresh("myfeed", my_seq);
                }
            } else {
                try { wrapped_clear(); } catch (GLib.Error e) { }
                NewsService.fetch(
                    win.effective_news_source(),
                    win.prefs.category,
                    current_search_query,
                    win.session,
                    FetchNewsController.global_forward_label,
                    FetchNewsController.global_no_op_clear,
                    FetchNewsController.global_add_item
                );

                // Schedule badge refresh for this category after articles register
                var sidebar_mgr = win.sidebar_manager;
                if (sidebar_mgr != null) {
                    sidebar_mgr.schedule_badge_refresh(win.prefs.category, my_seq);
                }
                // Adaptive layout is now handled by track_category_article() for regular categories
            }
        }
    }

    // Schedule a post-fetch check for adaptive layout based on actual article count
    // This approach works regardless of source count since it uses deduplicated ArticleStateStore data
    public static void schedule_adaptive_layout_check(NewsWindow win, uint my_seq) {
        // Check immediately when articles are populated, then again after a delay
        // This ensures we catch the layout decision before the spinner tries to hide
        Idle.add(() => {
            if (!FetchContext.is_current(my_seq)) return false;
            perform_adaptive_check(win, my_seq);
            return false;
        });

        // Also schedule a delayed check in case articles are still being registered
        Timeout.add(600, () => {
            if (!FetchContext.is_current(my_seq)) return false;
            perform_adaptive_check(win, my_seq);
            return false;
        });
    }

    private static void perform_adaptive_check(NewsWindow win, uint my_seq) {
        if (!FetchContext.is_current(my_seq)) return;
        var cur = FetchContext.current_context();
        if (cur == null) return;
        var w = cur.window;
        if (w == null) return;

        try {
            var cat_mgr = w.category_manager;
            var store = w.article_state_store;
            var layout_mgr = w.layout_manager;

            // Only check for regular categories, not special ones
            if (cat_mgr != null && store != null && layout_mgr != null) {
                if (!cat_mgr.is_frontpage_view() && !cat_mgr.is_topten_view() &&
                    !cat_mgr.is_myfeed_category() && !cat_mgr.is_local_news_view() &&
                    !cat_mgr.is_rssfeed_view() && w.prefs != null && w.prefs.category != "saved") {

                    // Get actual deduplicated count from ArticleStateStore
                    int actual_count = store.get_total_count_for_category(w.prefs.category);
                    stderr.printf("DEBUG: adaptive layout check - category=%s, actual_count=%d\n",
                                 w.prefs.category, actual_count);

                    if (actual_count < 15 && actual_count > 0) {
                        stderr.printf("DEBUG: triggering adaptive 2-hero layout (count=%d < 15)\n", actual_count);
                        Idle.add(() => {
                            if (!FetchContext.is_current(my_seq)) return false;
                            try {
                                var c = FetchContext.current_context();
                                if (c != null && c.window != null && c.window.layout_manager != null) {
                                    // rebuild_as_category_heroes() will handle revealing content
                                    c.window.layout_manager.rebuild_as_category_heroes();
                                }
                            } catch (GLib.Error e) { }
                            return false;
                        });
                    } else if (actual_count >= 15) {
                        // No adaptive layout needed (>= 15 articles), allow normal spinner hiding
                        try {
                            if (w.loading_state != null) {
                                w.loading_state.awaiting_adaptive_layout = false;
                                // Trigger reveal if items are already populated
                                if (w.loading_state.initial_items_populated) {
                                    // CRITICAL: Don't use reveal_initial_content() - it exits early if initial_phase is false
                                    try {
                                        if (w.loading_state != null) {
                                            w.loading_state.initial_phase = false;
                                            w.loading_state.hero_image_loaded = false;
                                        }
                                        w.hide_loading_spinner();
                                        if (w.main_content_container != null) {
                                            w.main_content_container.set_visible(true);
                                        }
                                    } catch (GLib.Error e) { }
                                }
                            }
                        } catch (GLib.Error e) { }
                    }
                    // If actual_count == 0, keep waiting (don't clear flag yet)
                }
            }
        } catch (GLib.Error e) { }
    }

    // Extracted helper: handle the RSS-feed branch of fetch_news.
    // Returns true if the RSS branch was handled and the caller should return.
    public static bool handle_rss_feed(
        NewsWindow win,
        SetLabelFunc wrapped_set_label,
        ClearItemsFunc wrapped_clear,
        AddItemFunc wrapped_add,
        Soup.Session session,
        string current_search_query,
        uint my_seq
    ) {
        if (!win.category_manager.is_rssfeed_view()) return false;

        string? feed_url = win.category_manager.get_rssfeed_url();
        if (feed_url == null || feed_url.length == 0) {
            try { wrapped_set_label("RSS Feed — Invalid feed URL"); } catch (GLib.Error e) { }
            try { win.hide_loading_spinner(); } catch (GLib.Error e) { }
            return true;
        }

        // Get the RSS source details from the database
        var rss_store = Paperboy.RssSourceStore.get_instance();
        var rss_source = rss_store.get_source_by_url(feed_url);
        string feed_name = rss_source != null ? rss_source.name : "RSS Feed";

        // Clear UI and schedule feed fetch
        try { wrapped_clear(); } catch (GLib.Error e) { }
        ClearItemsFunc no_op_clear = () => { };
        // Forward labels from the fetcher into the centralized header updater
        // Use an Idle-based handler that performs the fetch-validity check
        // itself to avoid calling back into other closures which may have
        // been freed or invalidated by concurrent fetches.
        SetLabelFunc label_fn = (text) => {
            Idle.add(() => {
                if (!FetchContext.is_current(my_seq)) return false;
                var cur = FetchContext.current_context();
                if (cur == null) return false;
                var w = cur.window;
                if (w == null) return false;
                try {
                    if (text != null) {
                        string lower = text.down();
                        if (lower.index_of("error") >= 0 || lower.index_of("failed") >= 0) {
                            if (w.loading_state != null) w.loading_state.network_failure_detected = true;
                            // Immediately show error message and hide spinner to prevent UI dead-end
                            // This ensures the user can navigate to other categories after a timeout
                            w.hide_loading_spinner();
                            w.show_error_message(text);
                            // Cancel the timeout since we're showing error now
                            if (w.loading_state != null && w.loading_state.initial_reveal_timeout_id > 0) {
                                Source.remove(w.loading_state.initial_reveal_timeout_id);
                                w.loading_state.initial_reveal_timeout_id = 0;
                            }
                            return false;
                        }
                    }
                } catch (GLib.Error e) { }

                try { w.update_content_header(); } catch (GLib.Error e) { }
                return false;
            });
        };

        // Set badge to placeholder before clearing article tracking
        try {
            if (win.sidebar_manager != null) {
                win.sidebar_manager.set_badge_placeholder_for_source(feed_name);
            }
        } catch (GLib.Error e) { }

        // Clear old article tracking for this source so unread counts reflect current feed content
        try {
            if (win.article_state_store != null) {
                win.article_state_store.clear_article_tracking_for_source(feed_name);
            }
        } catch (GLib.Error e) { }

        // Load articles from cache first for instant display
        var cache = Paperboy.RssArticleCache.get_instance();
        var cached_articles = cache.get_cached_articles(feed_url);

        if (cached_articles.size > 0) {
            // Display cached articles immediately
            foreach (var article in cached_articles) {
                try {
                    FetchNewsController.global_add_item(
                        article.title,
                        article.url,
                        article.thumbnail_url,
                        "rssfeed:" + feed_url,
                        feed_name
                    );
                } catch (GLib.Error e) {
                    GLib.warning("Failed to add cached article: %s", e.message);
                }
            }

            // Update label to show we're displaying cached content
            try {
                label_fn("%s — Loaded %d articles from cache".printf(feed_name, cached_articles.size));
            } catch (GLib.Error e) { }
        }

        // Fetch fresh articles from the RSS feed in the background to update cache
        // This happens async, so cached articles display instantly while fresh ones load
        RssFeedProcessor.fetch_rss_url(
            feed_url,
            feed_name,
            feed_name,
            "rssfeed:" + feed_url,
            current_search_query,
            session,
            FetchNewsController.global_forward_label,
            no_op_clear,
            FetchNewsController.global_add_item
        );

        // Update badge after articles finish loading
        try {
            if (win.sidebar_manager != null) {
                win.sidebar_manager.schedule_source_badge_refresh(feed_name, my_seq);
            }
        } catch (GLib.Error e) { }

        return true;
    }

    // Extracted helper: handle the Saved Articles branch of fetch_news.
    // Returns true if the saved-articles branch was handled and the caller should return.
    public static bool handle_saved_articles(
        NewsWindow win,
        FetchContext ctx,
        string current_search_query,
        SetLabelFunc wrapped_set_label,
        ClearItemsFunc wrapped_clear,
        AddItemFunc wrapped_add
    ) {
        if (win == null) return false;
        try { if (win.prefs == null) return false; } catch (GLib.Error e) { }

        if (win.prefs.category != "saved") return false;

        try { win.header_manager.update_for_saved_articles(); } catch (GLib.Error e) { }

        if (win.article_state_store == null) {
            try { wrapped_set_label("Saved Articles — Unable to load saved articles"); } catch (GLib.Error e) { }
            try { win.hide_loading_spinner(); } catch (GLib.Error e) { }
            return true;
        }

        var saved_articles = win.article_state_store.get_saved_articles();

        // Filter by search query if provided
        if (current_search_query.length > 0) {
            var filtered_articles = new Gee.ArrayList<ArticleStateStore.SavedArticle?>();
            string query_lower = current_search_query.down();
            foreach (var article in saved_articles) {
                if (article != null) {
                    string title_lower = article.title != null ? article.title.down() : "";
                    string url_lower = article.url != null ? article.url.down() : "";
                    if (title_lower.contains(query_lower) || url_lower.contains(query_lower)) {
                        filtered_articles.add(article);
                    }
                }
            }
            saved_articles = filtered_articles;
        }

        if (saved_articles.size == 0) {
            if (current_search_query.length > 0) {
                try { wrapped_set_label("Saved Articles — No results for " + current_search_query); } catch (GLib.Error e) { }
            } else {
                try { wrapped_set_label("Saved Articles — No saved articles yet"); } catch (GLib.Error e) { }
            }
            try { win.hide_loading_spinner(); } catch (GLib.Error e) { }
            return true;
        }

        // Clear and repopulate in a single idle callback to ensure proper ordering
        uint _saved_seq = ctx.seq;
        Idle.add(() => {
            if (!FetchContext.is_current(_saved_seq)) return false;
            var cur_saved = FetchContext.current_context();
            if (cur_saved == null) return false;
            var w = cur_saved.window;
            if (w == null) return false;

            // Set label based on search query
            if (current_search_query.length > 0) {
                try { wrapped_set_label("Search Results: " + current_search_query + " in Saved Articles"); } catch (GLib.Error e) { }
            } else {
                try { wrapped_set_label("Saved Articles"); } catch (GLib.Error e) { }
            }

            // Clear columns
            w.layout_manager.clear_columns();

            w.article_manager.article_buffer.clear();
            w.article_manager.articles_shown = 0;

            // Add saved articles immediately after clearing
                foreach (var article in saved_articles) {
                if (article != null && FetchContext.is_current(_saved_seq)) {
                    var cur4 = FetchContext.current_context();
                    if (cur4 != null) {
                        var w4 = cur4.window;
                        if (w4 != null) {
                            try {
                                wrapped_add(article.title, article.url, article.thumbnail, "saved", article.source ?? "Saved");
                            } catch (GLib.Error e) { }
                        }
                    }
                }
            }

            // Force queue draw to ensure UI updates
            if (w.layout_manager != null) {
                w.layout_manager.refresh_columns();
            }

            // Update sidebar badge for Saved now that articles are registered
            try {
                if (w.sidebar_manager != null) {
                    w.sidebar_manager.update_badge_for_category("saved");
                }
            } catch (GLib.Error e) { }

            // Reveal content immediately - saved articles are local, no network wait needed
            // CRITICAL: Don't use reveal_initial_content() here because it exits early if initial_phase is false
            // After an RSS timeout error, initial_phase is already false, so we must directly show the container
            try { w.hide_loading_spinner(); } catch (GLib.Error e) { }
            try {
                if (w.main_content_container != null) {
                    w.main_content_container.set_visible(true);
                }
            } catch (GLib.Error e) { }
            return false;
        });

        return true;
    }

    // Extracted helper: handle the Local News branch of fetch_news.
    // Returns true if the local-news branch was handled and the caller should return.
    public static bool handle_local_news(
        NewsWindow win,
        FetchContext ctx,
        SetLabelFunc wrapped_set_label,
        ClearItemsFunc wrapped_clear,
        AddItemFunc wrapped_add,
        Soup.Session session,
        string current_search_query
    ) {
        if (win == null) return false;
        try { if (!win.category_manager.is_local_news_view()) return false; } catch (GLib.Error e) { return false; }

        string config_dir = GLib.Environment.get_user_config_dir() + "/paperboy";
        string file_path = config_dir + "/local_feeds";

        if (!GLib.FileUtils.test(file_path, GLib.FileTest.EXISTS)) {
            try { wrapped_set_label("Local News — No local feeds configured"); } catch (GLib.Error e) { }
            try { win.hide_loading_spinner(); } catch (GLib.Error e) { }
            return true;
        }

        string contents = "";
        try { GLib.FileUtils.get_contents(file_path, out contents); } catch (GLib.Error e) { contents = ""; }
        if (contents == null || contents.strip() == "") {
            try { wrapped_set_label("Local News — No local feeds configured"); } catch (GLib.Error e) { }
            try { win.hide_loading_spinner(); } catch (GLib.Error e) { }
            return true;
        }

        // Clear UI and schedule per-feed fetches
        try { wrapped_clear(); } catch (GLib.Error e) { }
        ClearItemsFunc no_op_clear = () => { };
        uint my_seq = ctx.seq;
        SetLabelFunc label_fn = (text) => {
            Idle.add(() => {
                if (!FetchContext.is_current(my_seq)) return false;
                var cur = FetchContext.current_context();
                if (cur == null) return false;
                var w = cur.window;
                if (w == null) return false;
                try { w.update_content_header_now(); } catch (GLib.Error e) { }
                return false;
            });
        };

        // Ensure the top-right source badge / header reflects Local News
        try { win.update_content_header_now(); } catch (GLib.Error e) { }

        string[] lines = contents.split("\n");
        bool found_feed = false;
        for (int i = 0; i < lines.length; i++) {
            string u = lines[i].strip();
            if (u.length == 0) continue;
            found_feed = true;
            try {
                var article_mgr = win.article_manager;
                if (article_mgr != null) {
                    article_mgr.featured_used = true;
                }
            } catch (GLib.Error e) { }
            RssFeedProcessor.fetch_rss_url(
                u,
                "Local Feed",
                "Local News",
                "local_news",
                current_search_query,
                session,
                FetchNewsController.global_forward_label,
                no_op_clear,
                FetchNewsController.global_add_item
            );
        }
        if (!found_feed) {
            try { wrapped_set_label("Local News — No local feeds configured"); } catch (GLib.Error e) { }
        }

        return true;
    }
}
