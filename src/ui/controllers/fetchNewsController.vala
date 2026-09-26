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

    // Multi-source fetches buffer incoming articles on their FetchContext and flush
    // newest-first once things go quiet (or MULTI_SOURCE_MAX_WAIT_MS elapses), instead
    // of ordering by whichever source responds first. Late arrivals after a flush stream
    // straight through unbuffered.
    private const uint MULTI_SOURCE_DEBOUNCE_MS = 350;
    private const uint MULTI_SOURCE_MAX_WAIT_MS = 2500;
    // Per-Idle-callback time budget in flush_multi_source_buffer(), in microseconds.
    // Budgeting by wall-clock time (not item count) keeps each callback about one
    // frame's worth of work even though per-item build cost varies a lot.
    private const int64 DISPATCH_BATCH_BUDGET_US = 8000;
    // Hard cap on articles buffered/sorted/dispatched per flush. My Feed's source x
    // category fan-out can return 1000+ raw candidates with no display cap to fall
    // back on, so this is the only thing bounding per-flush cost.
    private const int MULTI_SOURCE_BUFFER_CAP = 400;

    // shared tail of route_item(): both buffered and direct paths funnel through here
    private static void dispatch_item(FetchContext cur, ArticleItem it) {
        if (!cur.still_owns_view()) return;
        var w = cur.window;

        var cat_mgr = w.category_manager;
        var layout_mgr = w.layout_manager;
        var article_mgr = w.article_manager;

        if (cat_mgr != null && layout_mgr != null && !cat_mgr.is_rssfeed_view()) {
            bool is_regular_cat = !cat_mgr.is_frontpage_view() &&
            !cat_mgr.is_myfeed_category() && !cat_mgr.is_local_news_view() &&
            w.prefs != null && w.prefs.category != "saved";
            if (is_regular_cat) {
                layout_mgr.track_category_article();
            }
        }
        if (article_mgr != null) {
            article_mgr.add_item(it.title, it.url, it.thumbnail_url, it.category_id, it.source_name, it.published, it.snippet);
        }
    }

    // Queue one article for a multi-source fetch and (re)schedule its
    // debounced flush. The debounce window resets on every new arrival so a
    // burst of near-simultaneous responses gets sorted together, but is
    // capped by MULTI_SOURCE_MAX_WAIT_MS from the first item so one
    // unusually slow source can't hold up the whole view.
    private static void buffer_multi_source_item(FetchContext ctx, ArticleItem item) {
        if (ctx.multi_source_buffer == null) {
            ctx.multi_source_buffer = new Gee.ArrayList<ArticleItem>();
            ctx.multi_source_started_at = GLib.get_monotonic_time();
        }
        var buffered = ctx.multi_source_buffer;
        buffered.add(item);
        if (buffered.size > MULTI_SOURCE_BUFFER_CAP) evict_oldest_buffered_item(buffered);

        ViewSession.remove_source(ref ctx.multi_source_flush_id);

        int64 elapsed_ms = (GLib.get_monotonic_time() - ctx.multi_source_started_at) / 1000;
        int64 remaining_ms = MULTI_SOURCE_MAX_WAIT_MS - elapsed_ms;
        uint delay = (remaining_ms > MULTI_SOURCE_DEBOUNCE_MS) ? MULTI_SOURCE_DEBOUNCE_MS : (remaining_ms > 0 ? (uint) remaining_ms : 0);

        ctx.multi_source_flush_id = ctx.session.timeout(delay, () => {
            ctx.multi_source_flush_id = 0;
            flush_multi_source_buffer(ctx);
            return false;
        });
    }

    // Evict the oldest item from whichever pool (myfeed vs. built-in) currently holds
    // more than its fair share, so a large custom-feed pool can't push built-in
    // articles out of the buffer entirely (or vice versa).
    private static void evict_oldest_buffered_item(Gee.ArrayList<ArticleItem> items) {
        int myfeed_count = 0;
        foreach (var it in items) if (it.category_id == "myfeed") myfeed_count++;
        bool evict_myfeed = myfeed_count > (items.size - myfeed_count);

        int oldest_index = -1;
        GLib.DateTime? oldest_dt = null;
        for (int i = 0; i < items.size; i++) {
            if ((items.get(i).category_id == "myfeed") != evict_myfeed) continue;
            var dt = DateUtils.parse_published_datetime(items.get(i).published);
            bool this_is_older = (oldest_index == -1) || (dt == null) ? (oldest_index == -1 || oldest_dt != null) : (oldest_dt != null && dt.compare(oldest_dt) < 0);
            if (this_is_older) {
                oldest_index = i;
                oldest_dt = dt;
            }
        }
        if (oldest_index == -1) return;
        items.remove_at(oldest_index);
    }

    // sort newest-first (undated articles sort last, keeping arrival order among themselves)
    private static void flush_multi_source_buffer(FetchContext ctx) {
        var items = ctx.multi_source_buffer;
        ctx.multi_source_buffer = null;
        ctx.multi_source_flushed = true;
        if (items == null || !ctx.still_owns_view()) return;

        items.sort((a, b) => {
            var da = DateUtils.parse_published_datetime(a.published);
            var db = DateUtils.parse_published_datetime(b.published);
            if (da == null && db == null) return 0;
            if (da == null) return 1;
            if (db == null) return -1;
            return db.compare(da);
        });

        // dispatch in small batches via Idle so building many cards doesn't block the main loop
        int index = 0;
        ctx.session.idle(() => {
            int64 batch_start = GLib.get_monotonic_time();
            while (index < items.size && (GLib.get_monotonic_time() - batch_start) < DISPATCH_BATCH_BUDGET_US) {
                dispatch_item(ctx, items.get(index));
                index++;
            }
            return index < items.size;
        });
    }

    // Sink for a view's regular fetches. Bound to ctx, so a late result from
    // a view the user already left is dropped by the sink rather than landing here.
    private static FetchSink news_sink(FetchContext ctx, owned SinkVoidHandler? on_done = null) {
        return new FetchSink(ctx.session, (it) => route_item(ctx, it), (text) => forward_label(ctx, text), null, (owned) on_done);
    }

    // My Feed's custom RSS sources: straight into ArticleManager, header-only labels.
    // Built here rather than inline so its handlers never capture fetch_news()'s locals.
    private static FetchSink myfeed_rss_sink(FetchContext ctx) {
        return new FetchSink(ctx.session, (it) => {
            if (!ctx.still_owns_view()) return;
            ctx.window.article_manager.add_item(it.title, it.url, it.thumbnail_url, it.category_id, it.source_name, it.published);
        }, (text) => { if (ctx.still_owns_view()) ctx.window.update_content_header(); });
    }

    // Front Page's Trending section: a second fetch layered onto the same view that
    // skips section routing/buffering and goes straight in as trending items.
    private static FetchSink trending_sink(FetchContext ctx) {
        return new FetchSink(ctx.session, (it) => {
            if (!ctx.still_owns_view()) return;
            var w = ctx.window;
            if (w.article_manager != null) {
                w.article_manager.add_item(it.title, it.url, it.thumbnail_url, it.category_id, it.source_name, it.published, it.snippet, true);
            }
        }, (text) => forward_label(ctx, text), null, () => { mark_frontpage_endpoint_done(ctx); });
    }

    private static void forward_label(FetchContext ctx, string? text) {
        if (ctx.is_local_only_view() || !ctx.still_owns_view()) return;
        var win = ctx.window;

        if (text != null) {
            string lower = text.down();
            if (lower.index_of("error") >= 0 || lower.index_of("failed") >= 0) {
                if (win.loading_state != null) win.loading_state.network_failure_detected = true;
                win.hide_loading_spinner();
                win.show_error_message(text);
                if (win.loading_state != null) ViewSession.remove_source(ref win.loading_state.initial_reveal_timeout_id);
                return;
            }
        }
        win.update_content_header();
    }

    private static void route_item(FetchContext cur, ArticleItem it) {
        if (!cur.still_owns_view()) return;

        if (cur.is_multi_source && !cur.multi_source_flushed) {
            buffer_multi_source_item(cur, it);
            return;
        }

        dispatch_item(cur, it);
    }

    // Front Page fires the frontpage list and Trending as two independent
    // backend fetches (see the frontpage branch in fetch_news_impl below);
    // this counts down as each one's on_done fires and only lets the
    // initial reveal through once both have reported in, so the two
    // sections stop popping in at visibly different times.
    private static void mark_frontpage_endpoint_done(FetchContext ctx) {
        if (!ctx.still_owns_view()) return;
        ctx.frontpage_endpoints_done++;
        if (ctx.frontpage_endpoints_done < 2) return;

        var ls = ctx.window.loading_state;
        if (ls != null) {
            ls.awaiting_frontpage_endpoints = false;
            if (ls.initial_items_populated && ls.initial_phase) ls.reveal_initial_content();
        }
    }

    public static void fetch_news(NewsWindow win) {
        if (win == null) return;

        // Close the previous view's session before any setup below schedules per-view work.
        // All window access in async callbacks must go through this context.
        var ctx = FetchContext.begin_new(win);

        if (win.image_manager != null) win.image_manager.cleanup_stale_downloads();

        if (win.article_manager != null) win.article_manager.reset_for_new_fetch();

        // skip during startup (preserves unreadFetchService counts) and for categories
        // that aggregate from multiple sources
        bool is_initial = (win.loading_state != null && win.loading_state.initial_phase);
        if (!is_initial && win.article_state_store != null && win.prefs.category != null && win.prefs.category.length > 0) {
            string cat = win.prefs.category;
            bool skip_clear = (cat == "myfeed" || cat == "local_news" || cat == "saved");
            if (!skip_clear) {
                win.article_state_store.clear_category_articles(win.prefs.category);
            }
        }

        win.layout_manager.prepare_for_new_fetch();

        win.layout_manager.reset_adaptive_tracking();

        // keep spinner visible until adaptive layout finalizes for regular categories
        bool is_regular_category = !win.category_manager.is_frontpage_view() &&
        !win.category_manager.is_myfeed_category() &&
        !win.category_manager.is_local_news_view() &&
        !win.category_manager.is_rssfeed_view() &&
        win.prefs.category != "saved" &&
        win.prefs.category != "history";
        if (is_regular_category && win.loading_state != null) {
            win.loading_state.awaiting_adaptive_layout = true;
        }
        
        // Clean up memory
        win.cleanup_old_content();
        win.article_manager.article_buffer.clear();
        win.article_manager.articles_shown = 0;


        // === PHASE 2: Early exit checks ===
        bool is_myfeed_category = win.category_manager.is_myfeed_category();
        if (is_myfeed_category && !win.prefs.personalized_feed_enabled) {
            MyFeedExtrasController.hide(win);
            if (win.layout_manager != null) win.layout_manager.remove_end_feed_message();
            win.update_content_header();
            win.update_personalization_ui();
            win.hide_loading_spinner();
            return;
        }

        // === PHASE 3: Begin loading state ===
        var loading_state = win.loading_state;
        if (loading_state != null) {
            loading_state.begin_fetch();
            // Explicitly hide any previous error messages to ensure clean state
            // This is critical when switching categories after a timeout error
            loading_state.hide_error_message();
        }
        win.update_content_header_now();

        if (loading_state != null) {
            loading_state.initial_reveal_timeout_id = ctx.session.timeout(NewsWindow.INITIAL_MAX_WAIT_MS, () => {
                var w = ctx.window;
                if (w == null) return false;

                var ls = w.loading_state;
                if (ls == null) return false;

                if (!ls.initial_items_populated) {
                    var network_monitor = GLib.NetworkMonitor.get_default();
                    if (!network_monitor.get_network_available()) {
                        w.show_error_message("No network connection detected. Check your connection and try again.");
                    } else {
                        w.show_error_message();
                    }
                } else {
                    // don't use reveal_initial_content() here - it exits early once initial_phase is false
                    if (w.loading_state != null) {
                        w.loading_state.initial_phase = false;
                        w.loading_state.hero_image_loaded = false;
                    }
                    w.hide_loading_spinner();
                    if (w.main_content_container != null) {
                        w.main_content_container.set_visible(true);
                    }

                    var network_monitor = GLib.NetworkMonitor.get_default();
                    if (!network_monitor.get_network_available()) {
                        w.show_toast("Offline - showing cached articles");
                    }
                }
                ls.initial_reveal_timeout_id = 0;
                return false;
            });
        }
        
        SetLabelFunc wrapped_set_label = (text) => {
            ctx.session.idle(() => {
                var w = ctx.window;
                if (w == null) return false;
                if (text != null) {
                    string lower = text.down();
                    if (lower.index_of("error") >= 0 || lower.index_of("failed") >= 0) {
                        var ls = w.loading_state;
                        if (ls != null) {
                            ls.network_failure_detected = true;
                        }
                    }
                }

                w.update_content_header();
                return false;
            });
        };

        // some fetchers call the clear callback multiple times during retries/fallbacks;
        // keep this idempotent per fetch
        bool wrapped_clear_ran = false;
        ClearItemsFunc wrapped_clear = () => {
            ctx.session.idle(() => {
                var w = ctx.window;
                if (w == null) return false;
                if (wrapped_clear_ran) {
                    return false;
                }
                wrapped_clear_ran = true;

                long _ts = (long) GLib.get_monotonic_time();

                var layout_mgr = w.layout_manager;
                var article_mgr = w.article_manager;
                var view_state_mgr = w.view_state;
                var image_mgr = w.image_manager;

                if (layout_mgr != null) {
                    layout_mgr.clear_featured_box();
                }
                if (article_mgr != null) {
                    article_mgr.reset_featured_state();
                }

                if (layout_mgr != null) {
                    layout_mgr.clear_columns();
                }

                if (article_mgr != null) {
                    article_mgr.clear_article_buffer();
                }

                if (layout_mgr != null) {
                    layout_mgr.remove_end_feed_message();
                }

                if (article_mgr != null) {
                    article_mgr.clear_load_more_button();
                }

                if (view_state_mgr != null && view_state_mgr.url_to_picture != null) {
                    view_state_mgr.url_to_picture.clear();
                }
                if (image_mgr != null && image_mgr.hero_requests != null) {
                    image_mgr.hero_requests.clear();
                }

                if (article_mgr != null) {
                    if (article_mgr.remaining_articles != null) {
                        article_mgr.remaining_articles.clear();
                    }
                    article_mgr.articles_shown = 0;
                }
                
                return false;
            });
        };

        var local_news_queue = new Gee.ArrayList<ArticleItem>();
        bool local_news_flush_scheduled = false;
        int local_news_items_enqueued = 0; // debug counter
        bool local_news_stats_scheduled = false;
        var ui_add_queue = new Gee.ArrayList<ArticleItem>();
        bool ui_add_idle_scheduled = false;

        AddItemFunc wrapped_add = (title, url, thumbnail, category_id, source_name, published) => {
            if (!ctx.still_owns_view()) return;
            var w = ctx.window;

            // limited categories only, not frontpage/topten/all
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
                w.prefs.category == "lifestyle"
                || w.prefs.category == "local_news"
                || w.prefs.category == "myfeed"
            );

            // limit is enforced later by add_item_immediate_to_column() after filtering

            var prefs_local = NewsPreferences.get_instance();
            if (prefs_local != null && prefs_local.category == "local_news") {
                    local_news_queue.add(new ArticleItem(title, url, thumbnail, category_id, source_name, published));
                    local_news_items_enqueued++;
                    if (!local_news_flush_scheduled) {
                        local_news_flush_scheduled = true;
                        ctx.session.timeout(60, () => {
                            int processed = 0;
                            int batch = 6;
                            while (local_news_queue.size > 0 && processed < batch) {
                                var ai = local_news_queue.get(0);
                                local_news_queue.remove_at(0);
                                w.article_manager.add_item(ai.title, ai.url, ai.thumbnail_url, ai.category_id, ai.source_name, ai.published);
                                processed++;
                            }
                            if (local_news_queue.size > 0) {
                                return true;
                            } else {
                                local_news_flush_scheduled = false;

                                if (w.sidebar_manager != null) {
                                    w.sidebar_manager.update_badge_for_category("local_news");
                                }

                                return false;
                            }
                        });
                    }
                    return;
                }
            
            w.article_manager.add_item(title, url, thumbnail, category_id, source_name, published);
        };

        bool used_multi = false;
        bool is_myfeed_mode = win.category_manager.is_myfeed_view();
        string[] myfeed_cats = new string[0];

        // a source needs both its own "enabled" switch and the separate My Feed opt-in to be fetched here
        Gee.ArrayList<Paperboy.RssSource>? custom_rss_sources = null;
        if (is_myfeed_mode) {
            var rss_store = Paperboy.RssSourceStore.get_instance();
            var all_custom = rss_store.get_all_sources();
            custom_rss_sources = new Gee.ArrayList<Paperboy.RssSource>();

            foreach (var src in all_custom) {
                if (win.prefs.preferred_source_enabled("custom:" + src.url) && win.prefs.myfeed_feed_enabled(src.url)) {
                    custom_rss_sources.add(src);
                }
            }
        }
        
        string current_search_query = win.get_current_search_query();

        // must be set before any fetch starts streaming back, or whichever source's HTTP
        // response lands first wins the hero slot even if its article is oldest
        bool is_saved_view = (win.prefs.category == "saved" || win.prefs.category == "history");
        int total_sources = (win.prefs.preferred_sources != null ? win.prefs.preferred_sources.size : 0);
        if (is_myfeed_mode && custom_rss_sources != null) {
            total_sources += custom_rss_sources.size;
        }
        // frontpage always issues one backend request regardless of source count
        bool is_frontpage = win.category_manager.is_frontpage_view();
        ctx.is_multi_source = !is_frontpage && ((win.prefs.category == "sports") ||
            (!is_saved_view && (total_sources > 1 || (is_myfeed_mode && custom_rss_sources != null && custom_rss_sources.size > 0))));

        // always query the sports endpoint too, so users whose enabled sources have no
        // sports desk (e.g. PBS) still see content; runs alongside the normal fetch below
        if (win.prefs.category == "sports") {
            var paperboy_sports_fetcher = new PaperboyFetcher(news_sink(ctx));
            paperboy_sports_fetcher.fetch("sports", current_search_query, win.session);
        }

if (is_myfeed_mode) {
            if (win.category_manager.is_myfeed_configured()) {
                var cats = win.category_manager.get_myfeed_categories();
                myfeed_cats = new string[cats.size];
                for (int i = 0; i < cats.size; i++) myfeed_cats[i] = cats.get(i);
            }

            bool has_personalized_cats = (myfeed_cats != null && myfeed_cats.length > 0);
            bool has_custom_rss = (custom_rss_sources != null && custom_rss_sources.size > 0);

            if (!has_personalized_cats && !has_custom_rss) {
                wrapped_clear();
                wrapped_set_label("My Feed — No personalized categories or custom RSS feeds configured");
                win.hide_loading_spinner();
                return;
            }
        }

        if (win.prefs.category == "saved") {
            if (FetchNewsController.handle_saved_articles(win, ctx, current_search_query, wrapped_set_label, wrapped_clear, wrapped_add)) return;
        }

        if (win.prefs.category == "history") {
            if (FetchNewsController.handle_history_articles(win, ctx, current_search_query, wrapped_set_label, wrapped_clear, wrapped_add)) return;
        }

        if (win.category_manager.is_local_news_view()) {
            if (FetchNewsController.handle_local_news(win, ctx, wrapped_set_label, wrapped_clear, wrapped_add, win.session, current_search_query)) return;
        }

        if (win.category_manager.is_rssfeed_view()) {
            if (FetchNewsController.handle_rss_feed(win, ctx, wrapped_set_label, wrapped_clear, wrapped_add, win.session, current_search_query))
                return;
        }
        // handled before the multi-source branch so it works with zero/one preferred sources
        if (win.category_manager.is_frontpage_view()) {
            used_multi = true;

                wrapped_clear();
                wrapped_set_label("Frontpage — Loading from backend (branch 1)");
            AppDebugger.log_rss("fetch_news: frontpage floor");
            // Hold the initial reveal until both the frontpage list and
            // Trending have reported in (see mark_frontpage_endpoint_done),
            // so they always appear together instead of Trending lagging
            // in visibly after the frontpage list.
            if (win.loading_state != null) win.loading_state.awaiting_frontpage_endpoints = true;
            NewsService.fetch(win.prefs.news_source, "frontpage", current_search_query, win.session, news_sink(ctx, () => { FetchNewsController.mark_frontpage_endpoint_done(ctx); }));

            // Trending section: a second, independent fetch layered onto the
            // Front Page (see trending_sink()) - same
            // backend data Top Ten used to show on its own page, now inline
            // between the Hero Carousel and Headlines.
            win.layout_manager.configure_trending_section();
            var trending_fetcher = new PaperboyFetcher(trending_sink(ctx));
            trending_fetcher.fetch("topten", current_search_query, win.session);

            var sidebar_mgr = win.sidebar_manager;
            if (sidebar_mgr != null) {
                sidebar_mgr.schedule_badge_refresh("frontpage");
            }
            return;
        }

        // saved articles, local news, and individual RSS feeds have their own header setup above
        if (!is_saved_view && (total_sources > 1 || (is_myfeed_mode && custom_rss_sources != null && custom_rss_sources.size > 0))) {
            // frontpage is visually a multi-source view, but preferred_sources shouldn't
            // influence which providers get queried - just hit the backend frontpage endpoint once
            if (win.category_manager.is_frontpage_view()) {
                used_multi = true;

                // Clear UI and ask the backend frontpage fetcher once. NewsService
                // will route a request with current_category == "frontpage" to
                // the Paperboy backend fetcher regardless of the NewsSource value.
                wrapped_clear();
                NewsService.fetch(win.prefs.news_source, "frontpage", current_search_query, win.session, news_sink(ctx));
                
                // Schedule badge refresh for frontpage
                var sidebar_mgr = win.sidebar_manager;
                if (sidebar_mgr != null) {
                    sidebar_mgr.schedule_badge_refresh("frontpage");
                }
                return;
            }

            used_multi = true;

            Gee.ArrayList<NewsSource> srcs = win.source_manager.get_enabled_source_enums();

            if (srcs.size == 0) {
                NewsService.fetch(
                    win.prefs.news_source,
                    win.prefs.category,
                    current_search_query,
                    win.session,
                    news_sink(ctx)
                );
            } else {
                // "myfeed" isn't a real provider category, so check support per personalized
                // category instead (e.g. Bloomberg supports markets/industries but not "myfeed")
                var filtered = new Gee.ArrayList<NewsSource>();
                foreach (var s in srcs) {
                    bool include = false;
                    if (is_myfeed_mode) {
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
                }

                var use_srcs = filtered.size > 0 ? filtered : srcs;

                // clear once up front so a later-completing fetch can't wipe an earlier one's results
                wrapped_clear();

                bool skip_builtin = is_myfeed_mode && win.prefs.myfeed_custom_only;
                if (!skip_builtin) {
                    foreach (var s in use_srcs) {
                        if (is_myfeed_mode) {
                            foreach (var cat in myfeed_cats) {
                                NewsService.fetch(s, cat, current_search_query, win.session, news_sink(ctx));
                            }
                        } else {
                            NewsService.fetch(s, win.prefs.category, current_search_query, win.session, news_sink(ctx));
                        }
                    }
                }

                if (!is_myfeed_mode) {
                    var sidebar_mgr = win.sidebar_manager;
                    if (sidebar_mgr != null) {
                        sidebar_mgr.schedule_badge_refresh(win.prefs.category);
                    }
                }

                if (is_myfeed_mode && custom_rss_sources != null && custom_rss_sources.size > 0) {
                    foreach (var rss_src in custom_rss_sources) {
                        // generated feeds (file:// URLs) use original_url as cache key so it survives regeneration
                        string? cache_key = (rss_src.url.has_prefix("file://") && rss_src.original_url != null) ? rss_src.original_url : null;
                        RssFeedProcessor.fetch_rss_url(
                            rss_src.url,
                            rss_src.url,  // use URL, not name, for source filtering
                            "My Feed",
                            "myfeed",
                            current_search_query,
                            win.session,
                            news_sink(ctx),
                            cache_key
                        );
                    }
                }
            }
        } else {
            if (win.category_manager.is_frontpage_view()) {
                wrapped_clear();
                wrapped_set_label("Frontpage — Loading from backend (single-source)");
                NewsService.fetch(win.prefs.news_source, "frontpage", current_search_query, win.session, news_sink(ctx));

                var sidebar_mgr = win.sidebar_manager;
                if (sidebar_mgr != null) {
                    sidebar_mgr.schedule_badge_refresh("frontpage");
                }
                return;
            }

            if (is_myfeed_mode) {
                wrapped_clear();

                // Fetch from built-in source (unless custom_only mode is enabled in My Feed)
                if (!win.prefs.myfeed_custom_only) {
                    foreach (var cat in myfeed_cats) {
                        NewsService.fetch(win.effective_news_source(), cat, current_search_query, win.session, news_sink(ctx));
                    }
                }

                // Fetch from custom RSS sources if sources are enabled
                if (custom_rss_sources != null && custom_rss_sources.size > 0) {
                    win.article_manager.featured_used = true;
                    foreach (var rss_src in custom_rss_sources) {
                        string? cache_key = (rss_src.url.has_prefix("file://") && rss_src.original_url != null) ? rss_src.original_url : null;
                        RssFeedProcessor.fetch_rss_url(
                            rss_src.url,
                            rss_src.url,  // use URL, not name, for source filtering
                            "My Feed",
                            "myfeed",
                            current_search_query,
                            win.session,
                            myfeed_rss_sink(ctx),
                            cache_key
                        );
                    }
                }

                var sidebar_mgr = win.sidebar_manager;
                if (sidebar_mgr != null) {
                    sidebar_mgr.schedule_badge_refresh("myfeed");
                }
            } else {
                wrapped_clear();
                NewsService.fetch(
                    win.effective_news_source(),
                    win.prefs.category,
                    current_search_query,
                    win.session,
                    news_sink(ctx)
                );

                var sidebar_mgr = win.sidebar_manager;
                if (sidebar_mgr != null) {
                    sidebar_mgr.schedule_badge_refresh(win.prefs.category);
                }
            }
        }
    }

    // Extracted helper: handle the RSS-feed branch of fetch_news.
    // Returns true if the RSS branch was handled and the caller should return.
    public static bool handle_rss_feed(
        NewsWindow win,
        FetchContext ctx,
        SetLabelFunc wrapped_set_label,
        ClearItemsFunc wrapped_clear,
        AddItemFunc wrapped_add,
        Soup.Session session,
        string current_search_query
    ) {
        if (!win.category_manager.is_rssfeed_view()) return false;

        string? feed_url = win.category_manager.get_rssfeed_url();
        if (feed_url == null || feed_url.length == 0) {
            wrapped_set_label("RSS Feed — Invalid feed URL");
            win.hide_loading_spinner();
            return true;
        }

        // Get the RSS source details from the database
        var rss_store = Paperboy.RssSourceStore.get_instance();
        var rss_source = rss_store.get_source_by_url(feed_url);
        string feed_name_plain = rss_source != null ? rss_source.name : "RSS Feed";

        // Manually viewing/refreshing this feed never goes through
        // FeedUpdateManager.update_single_feed() (that's only the periodic
        // background path) - piggyback the same podcast-discovery check
        // here too, so an explicit refresh can also surface the button
        // without waiting for the next scheduled background pass.
        if (rss_source != null && win.feed_updater != null) {
            win.feed_updater.maybe_check_for_podcast_feed(rss_source);
        }

        // Build display name with logo URL for article cards (format: "Name||logo_url")
        string feed_name = feed_name_plain;
        string? logo_url = SourceMetadata.get_logo_url_for_source(feed_name_plain);
        if (logo_url != null && logo_url.length > 0) {
            feed_name = feed_name_plain + "||" + logo_url;
        }

        // Clear UI and schedule feed fetch
        wrapped_clear();
        var sink = news_sink(ctx);

        // Set badge to placeholder before clearing article tracking
        if (win.sidebar_manager != null) {
            win.sidebar_manager.set_badge_placeholder_for_source(feed_name_plain);
        }

        // Clear old article tracking for this source so unread counts reflect current feed content
        if (win.article_state_store != null) {
            win.article_state_store.clear_article_tracking_for_source(feed_name_plain);
        }

        // Load articles from cache first for instant display
        var cache = Paperboy.RssArticleCache.get_instance();
        // For generated feeds (file:// URLs), use original_url as cache key for lookup
        string cache_lookup_key = feed_url;
        if (rss_source != null && feed_url.has_prefix("file://") && rss_source.original_url != null) {
            cache_lookup_key = rss_source.original_url;
        }
        var cached_articles = cache.get_cached_articles(cache_lookup_key);

        if (cached_articles.size > 0) {
            // Display cached articles immediately
            foreach (var article in cached_articles) {
                sink.add_item(
                    article.title,
                    article.url,
                    article.thumbnail_url,
                    "rssfeed:" + feed_url,
                    feed_name,
                    article.published_date
                );
            }

            // Update label to show we're displaying cached content
            var network_monitor = GLib.NetworkMonitor.get_default();
            if (!network_monitor.get_network_available()) {
                sink.set_label("%s — Offline, showing %d cached articles".printf(feed_name_plain, cached_articles.size));
                win.show_toast("Offline - showing cached articles");
            } else {
                sink.set_label("%s — Loaded %d articles from cache".printf(feed_name_plain, cached_articles.size));
            }
        }

        // Fetch fresh articles from the RSS feed in the background to update cache
        // This happens async, so cached articles display instantly while fresh ones load
        // For generated feeds (file:// URLs), use original_url as cache key for persistence across regenerations
        string? cache_key = null;
        if (rss_source != null && feed_url.has_prefix("file://") && rss_source.original_url != null) {
            cache_key = rss_source.original_url;
        }

        // If we have cached articles, use a no-op label function to prevent network errors from overwriting the cache message
        var fetch_sink = cached_articles.size > 0
            ? new FetchSink(ctx.session, (it) => route_item(ctx, it))
            : sink;

        RssFeedProcessor.fetch_rss_url(
            feed_url,
            feed_name,
            feed_name,
            "rssfeed:" + feed_url,
            current_search_query,
            session,
            fetch_sink,
            cache_key
        );

        // Update badge after articles finish loading
        if (win.sidebar_manager != null) {
            win.sidebar_manager.schedule_source_badge_refresh(feed_name);
        }

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
        if (win.prefs == null) return false;

        if (win.prefs.category != "saved") return false;

        if (win.article_state_store == null) {
            wrapped_set_label("Saved Articles — Unable to load saved articles");
            win.hide_loading_spinner();
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
                wrapped_set_label("Saved Articles — No results for " + current_search_query);
            } else {
                wrapped_set_label("Saved Articles — No saved articles yet");
            }
            if (win.loading_state != null) {
                if (current_search_query.length > 0) win.loading_state.show_empty_message("search-mono.svg", "No results");
                else win.loading_state.show_empty_message("saved-mono.svg");
            }
            return true;
        }

        // Clear and repopulate in a single idle callback to ensure proper ordering
        var session = ctx.session;
        session.idle(() => {
            var w = ctx.window;
            if (w == null) return false;

            // Set label based on search query
            w.update_content_header();

            // Drop any hero carousel left over from the previous view.
            w.layout_manager.clear_featured_box();
            w.article_manager.reset_featured_state();

            w.layout_manager.clear_columns();

            w.article_manager.article_buffer.clear();
            w.article_manager.articles_shown = 0;

            // Clear initial_phase before adding cards - otherwise
            // add_item_immediate_to_column's mark_initial_items_populated()
            // schedules the normal trigger_initial_reveals() path too, which
            // snaps these already-visible cards invisible and fades them
            // back in a moment later (the flash).
            if (w.loading_state != null) {
                w.loading_state.initial_phase = false;
                ViewSession.remove_source(ref w.loading_state.initial_reveal_timeout_id);
            }

            // Add saved articles immediately after clearing
                foreach (var article in saved_articles) {
                    if (article != null) w.article_manager.add_item(article.title, article.url, article.thumbnail, "saved", article.source ?? "Saved", article.published);
                }

            // Give the new cards the same hidden/offset starting state
            // LoadingStateManager.trigger_initial_reveals() uses for every
            // other category, since clearing initial_phase above means that
            // path never runs for Saved - the staggered fade-in below
            // plays instead of relying on it.
            if (w.layout_manager != null && w.layout_manager.columns_row != null) {
                var entrance_child = w.layout_manager.columns_row.get_first_child();
                while (entrance_child != null) {
                    entrance_child.set_visible(true);
                    entrance_child.set_opacity(0.0);
                    entrance_child.set_margin_top(18);
                    entrance_child = entrance_child.get_next_sibling();
                }
            }

            // Force queue draw to ensure UI updates
            if (w.layout_manager != null) {
                w.layout_manager.refresh_columns();
            }

            // Update sidebar badge for Saved now that articles are registered
            if (w.sidebar_manager != null) {
                w.sidebar_manager.update_badge_for_category("saved");
            }

            // Reveal on the NEXT loop iteration, not this one - saved
            // articles are local so there's no network wait to hide behind,
            // and revealing in the same tick that just added all the cards
            // let GTK's first layout guess (before it finished measuring
            // the new widgets) become visible for a frame, seen as a quick
            // flash/reflow right after the cards appeared.
            session.idle(() => {
                // CRITICAL: Don't use reveal_initial_content() here because it exits early if initial_phase is false
                // After an RSS timeout error, initial_phase is already false, so we must directly show the container
                w.hide_loading_spinner();
                if (w.main_content_container != null) {
                    w.main_content_container.set_visible(true);
                }

                // Same entrance animation other categories get.
                if (w.animation_manager != null && w.layout_manager != null && w.layout_manager.columns_row != null) {
                    var cards = new Gee.ArrayList<Gtk.Widget>();
                    var anim_child = w.layout_manager.columns_row.get_first_child();
                    while (anim_child != null) {
                        cards.add(anim_child);
                        anim_child = anim_child.get_next_sibling();
                    }
                    w.animation_manager.animate_cards_entrance_batch(cards);
                }
                return false;
            });
            return false;
        });

        return true;
    }

    // Extracted helper: handle the History branch of fetch_news. Mirrors
    // handle_saved_articles() above, reading from ArticleStateStore's
    // reading-history table instead of its saved-articles table.
    // Returns true if the history branch was handled and the caller should return.
    public static bool handle_history_articles(
        NewsWindow win,
        FetchContext ctx,
        string current_search_query,
        SetLabelFunc wrapped_set_label,
        ClearItemsFunc wrapped_clear,
        AddItemFunc wrapped_add
    ) {
        if (win == null) return false;
        if (win.prefs == null) return false;

        if (win.prefs.category != "history") return false;

        // LayoutManager.prepare_for_new_fetch() (called earlier in fetch_news())
        // hides this via ContentView.hide_all_pages() on every fetch, same as
        // Magazines'/Podcasts' own header buttons - re-show it now that we know
        // History is actually the page being rendered.
        if (win.content_view != null && win.content_view.clear_history_button != null) {
            win.content_view.clear_history_button.set_visible(true);
        }

        if (win.article_state_store == null) {
            wrapped_set_label("History — Unable to load history");
            win.hide_loading_spinner();
            return true;
        }

        var history_articles = win.article_state_store.get_history_articles();

        if (current_search_query.length > 0) {
            var filtered_articles = new Gee.ArrayList<ArticleStateStore.HistoryArticle?>();
            string query_lower = current_search_query.down();
            foreach (var article in history_articles) {
                if (article != null) {
                    string title_lower = article.title != null ? article.title.down() : "";
                    string url_lower = article.url != null ? article.url.down() : "";
                    if (title_lower.contains(query_lower) || url_lower.contains(query_lower)) {
                        filtered_articles.add(article);
                    }
                }
            }
            history_articles = filtered_articles;
        }

        if (history_articles.size == 0) {
            if (current_search_query.length > 0) {
                wrapped_set_label("History — No results for " + current_search_query);
            } else {
                wrapped_set_label("History — No articles read yet");
            }
            if (win.loading_state != null) {
                if (current_search_query.length > 0) win.loading_state.show_empty_message("search-mono.svg", "No results");
                else win.loading_state.show_empty_message("history-mono.svg");
            }
            return true;
        }

        var session = ctx.session;
        session.idle(() => {
            var w = ctx.window;
            if (w == null) return false;

            w.update_content_header();

            // History isn't a traditional feed page - clear any leftover
            // hero carousel ("FEATURED") from whatever category was viewed
            // before this, since it lives in featured_box (a hero_container
            // child) which prepare_for_new_fetch() doesn't clear on its own.
            w.layout_manager.clear_featured_box();
            w.article_manager.reset_featured_state();

            w.layout_manager.clear_columns();

            w.article_manager.article_buffer.clear();
            w.article_manager.articles_shown = 0;

            if (w.loading_state != null) {
                w.loading_state.initial_phase = false;
                ViewSession.remove_source(ref w.loading_state.initial_reveal_timeout_id);
            }

            foreach (var article in history_articles) {
                if (article != null) w.article_manager.add_item(article.title, article.url, article.thumbnail, "history", article.source, article.published);
            }

            if (w.layout_manager != null && w.layout_manager.columns_row != null) {
                var entrance_child = w.layout_manager.columns_row.get_first_child();
                while (entrance_child != null) {
                    entrance_child.set_visible(true);
                    entrance_child.set_opacity(0.0);
                    entrance_child.set_margin_top(18);
                    entrance_child = entrance_child.get_next_sibling();
                }
            }

            if (w.layout_manager != null) {
                w.layout_manager.refresh_columns();
            }

            session.idle(() => {
                w.hide_loading_spinner();
                if (w.main_content_container != null) {
                    w.main_content_container.set_visible(true);
                }

                if (w.animation_manager != null && w.layout_manager != null && w.layout_manager.columns_row != null) {
                    var cards = new Gee.ArrayList<Gtk.Widget>();
                    var anim_child = w.layout_manager.columns_row.get_first_child();
                    while (anim_child != null) {
                        cards.add(anim_child);
                        anim_child = anim_child.get_next_sibling();
                    }
                    w.animation_manager.animate_cards_entrance_batch(cards);
                }
                return false;
            });
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
        if (!win.category_manager.is_local_news_view()) return false; 

        var area = NewsPreferences.get_instance().get_active_local_area();
        if (area == null || area.city.strip().length == 0) {
            wrapped_set_label("Local News — No location configured");
            win.hide_loading_spinner();
            return true;
        }
        string display_city = area.city;
        if (win.article_state_store != null) win.article_state_store.set_local_news_area(area.key);

        // Clear UI and fetch via Google News' RSS search endpoint, scoped to
        // the user's resolved location. This replaced a feedspot.com HTML
        // scrape (see rssFinder tool, now removed) that broke whenever
        // feedspot changed its page markup; Google News' RSS output is a
        // stable, first-party feed so it can go straight through the same
        // generic RSS pipeline every other source uses.
        wrapped_clear();
        var article_mgr = win.article_manager;
        if (article_mgr != null) article_mgr.featured_used = true;

        // Ensure the top-right source badge / header reflects Local News
        win.update_content_header_now();

        fetch_local_news_query(ctx, display_city, "local_news", current_search_query, session);

        return true;
    }

    private static void fetch_local_news_query(FetchContext ctx, string city, string category_id, string current_search_query, Soup.Session session) {
        var sink = news_sink(ctx);
        string query = GLib.Uri.escape_string(city.strip(), null, false);
        string url = "https://news.google.com/rss/search?q=" + query + "&hl=en-US&gl=US&ceid=US:en";

        // Local news articles are already cached under this exact URL by
        // RssFeedProcessor (it caches unconditionally whenever a feed_url is
        // given, which fetch_rss_url always does). Show that cache first so
        // a slow, rate-limited, or genuinely empty live Google News response
        // doesn't leave the view with nothing to show - the same "instant
        // display, then update in the background" pattern followed RSS feeds
        // already use (see handle_rss_feed above).
        var cache = Paperboy.RssArticleCache.get_instance();
        var cached_articles = cache.get_cached_articles(url);
        foreach (var article in cached_articles) {
            string cached_source = article.source_name ?? city;
            if (article.source_name != null && article.logo_url != null) cached_source += "||" + article.logo_url;
            sink.add_item(
                article.title,
                article.url,
                article.thumbnail_url,
                category_id,
                cached_source,
                article.published_date
            );
        }

        RssFeedProcessor.fetch_rss_url(
            url,
            city,
            "Local News",
            category_id,
            current_search_query,
            session,
            sink
        );
    }
}
