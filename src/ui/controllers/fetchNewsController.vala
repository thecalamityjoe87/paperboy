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

    // Multi-source fetches buffer incoming articles per FetchContext.seq and flush
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
    // static Gee fields need lazy init in Vala - a field initializer here never runs
    // since this class is never instantiated
    private static Gee.HashMap<uint, Gee.ArrayList<ArticleItem>>? _multi_source_buffers = null;
    private static Gee.HashMap<uint, uint>? _multi_source_timeouts = null;
    private static Gee.HashMap<uint, int64?>? _multi_source_started_at = null;
    private static Gee.HashSet<uint>? _multi_source_flushed = null;

    private static Gee.HashMap<uint, Gee.ArrayList<ArticleItem>> multi_source_buffers() {
        if (_multi_source_buffers == null) _multi_source_buffers = new Gee.HashMap<uint, Gee.ArrayList<ArticleItem>>();
        return _multi_source_buffers;
    }
    private static Gee.HashMap<uint, uint> multi_source_timeouts() {
        if (_multi_source_timeouts == null) _multi_source_timeouts = new Gee.HashMap<uint, uint>();
        return _multi_source_timeouts;
    }
    private static Gee.HashMap<uint, int64?> multi_source_started_at() {
        if (_multi_source_started_at == null) _multi_source_started_at = new Gee.HashMap<uint, int64?>();
        return _multi_source_started_at;
    }
    private static Gee.HashSet<uint> multi_source_flushed() {
        if (_multi_source_flushed == null) _multi_source_flushed = new Gee.HashSet<uint>();
        return _multi_source_flushed;
    }

    // shared tail of global_add_item(): both buffered and direct paths funnel through here
    private static void dispatch_item(NewsWindow w, FetchContext cur, string title, string url, string? thumbnail, string category_id, string? source_name, string? published, string? snippet) {
        // Single shared check (see FetchContext.still_owns_view): the
        // category this fetch started for may no longer be on screen, or a
        // global search may since have taken over the shared containers
        // this would render into (ContentView.filter_by_query) - either way
        // this item no longer belongs to the view currently on screen.
        if (!cur.still_owns_view()) return;

        var cat_mgr = w.category_manager;
        var layout_mgr = w.layout_manager;
        var article_mgr = w.article_manager;

        if (cat_mgr != null && layout_mgr != null && !cat_mgr.is_rssfeed_view()) {
            bool is_regular_cat = !cat_mgr.is_frontpage_view() && !cat_mgr.is_topten_view() &&
            !cat_mgr.is_myfeed_category() && !cat_mgr.is_local_news_view() &&
            w.prefs != null && w.prefs.category != "saved";
            if (is_regular_cat) {
                layout_mgr.track_category_article(cur.seq);
            }
        }
        if (article_mgr != null) {
            article_mgr.add_item(title, url, thumbnail, category_id, source_name, published, snippet);
        }
    }

    // Queue one article for a multi-source fetch and (re)schedule its
    // debounced flush. The debounce window resets on every new arrival so a
    // burst of near-simultaneous responses gets sorted together, but is
    // capped by MULTI_SOURCE_MAX_WAIT_MS from the first item so one
    // unusually slow source can't hold up the whole view.
    private static void buffer_multi_source_item(uint seq, string title, string url, string? thumbnail, string category_id, string? source_name, string? published, string? snippet) {
        if (!multi_source_buffers().has_key(seq)) {
            multi_source_buffers().set(seq, new Gee.ArrayList<ArticleItem>());
            multi_source_started_at().set(seq, GLib.get_monotonic_time());
        }
        var item = new ArticleItem(title, url, thumbnail, category_id, source_name, published);
        item.snippet = snippet;
        var buffered = multi_source_buffers().get(seq);
        buffered.add(item);
        if (buffered.size > MULTI_SOURCE_BUFFER_CAP) evict_oldest_buffered_item(buffered);

        if (multi_source_timeouts().has_key(seq)) {
            GLib.Source.remove(multi_source_timeouts().get(seq));
            multi_source_timeouts().unset(seq);
        }

        int64 elapsed_ms = (GLib.get_monotonic_time() - multi_source_started_at().get(seq)) / 1000;
        int64 remaining_ms = MULTI_SOURCE_MAX_WAIT_MS - elapsed_ms;
        uint delay = (remaining_ms > MULTI_SOURCE_DEBOUNCE_MS) ? MULTI_SOURCE_DEBOUNCE_MS : (remaining_ms > 0 ? (uint) remaining_ms : 0);

        uint tid = Timeout.add(delay, () => {
            multi_source_timeouts().unset(seq);
            flush_multi_source_buffer(seq);
            return false;
        });
        multi_source_timeouts().set(seq, tid);
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
    private static void flush_multi_source_buffer(uint seq) {
        if (!multi_source_buffers().has_key(seq)) return;
        var items = multi_source_buffers().get(seq);
        multi_source_buffers().unset(seq);
        multi_source_started_at().unset(seq);
        multi_source_flushed().add(seq);

        if (!FetchContext.is_current(seq)) return;
        var cur = FetchContext.current_context();
        if (cur == null || !cur.is_valid() || cur.seq != seq) return;
        var w = cur.window;
        if (w == null) return;
        if (w.prefs != null && cur.expected_category != null && w.prefs.category != cur.expected_category) return;

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
        Idle.add(() => {
            if (!FetchContext.is_current(seq)) return false;
            var cur2 = FetchContext.current_context();
            if (cur2 == null || !cur2.is_valid() || cur2.seq != seq) return false;
            var w2 = cur2.window;
            if (w2 == null) return false;
            if (w2.prefs != null && cur2.expected_category != null && w2.prefs.category != cur2.expected_category) return false;

            int64 batch_start = GLib.get_monotonic_time();
            while (index < items.size && (GLib.get_monotonic_time() - batch_start) < DISPATCH_BATCH_BUDGET_US) {
                var item = items.get(index);
                dispatch_item(w2, cur2, item.title, item.url, item.thumbnail_url, item.category_id, item.source_name, item.published, item.snippet);
                index++;
            }
            return index < items.size;
        });
    }

    // non-capturing so it's safe to pass across thread boundaries into worker fetchers
    public static void global_forward_label(string? text) {
        Idle.add(() => {
            var ctx = FetchContext.current_context();
            if (ctx == null) return false;
            var win = ctx.window;
            if (win == null) return false;

            if (text != null) {
                string lower = text.down();
                if (lower.index_of("error") >= 0 || lower.index_of("failed") >= 0) {
                    if (win.loading_state != null) win.loading_state.network_failure_detected = true;
                    win.hide_loading_spinner();
                    win.show_error_message(text);
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
            win.update_content_header();
            return false;
        });
    }

    // Non-capturing so it's safe to post from background-fetcher threads onto the main
    // loop. Don't replace this with a per-request closure carrying captured state (e.g.
    // My Feed row identity) - closures captured on one thread and invoked later from a
    // fetch's worker thread can arrive with garbage memory. Resolve such state from
    // source_name/category_id in ArticleManager.add_item() instead.
    public static void global_add_item(string title, string url, string? thumbnail, string category_id, string? source_name, string? published = null, string? snippet = null) {
        Idle.add(() => {
            var cur = FetchContext.current_context();
            if (cur == null || !cur.is_valid()) return false;
            var w = cur.window;
            if (w == null) return false;

            // discard if the user switched categories before this fetch completed
            if (w.prefs != null && cur.expected_category != null) {
                if (w.prefs.category != cur.expected_category) {
                    return false;
                }
            }

            if (cur.is_multi_source && !multi_source_flushed().contains(cur.seq)) {
                buffer_multi_source_item(cur.seq, title, url, thumbnail, category_id, source_name, published, snippet);
                return false;
            }

            dispatch_item(w, cur, title, url, thumbnail, category_id, source_name, published, snippet);
            return false;
        });
    }

    public static void global_no_op_clear() {
    }


    public static void fetch_news(NewsWindow win) {
        if (win == null) return;

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

        // sidebar rebuild only needed when sources change in prefs, not on every fetch
        bool is_topten = win.category_manager.is_topten_view();
        win.layout_manager.prepare_for_new_fetch(is_topten);

        win.layout_manager.reset_adaptive_tracking();

        // keep spinner visible until adaptive layout finalizes for regular categories
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


        // === PHASE 2: Early exit checks ===
        bool is_myfeed_category = win.category_manager.is_myfeed_category();
        if (is_myfeed_category && !win.prefs.personalized_feed_enabled) {
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

        // all window access below must go through FetchContext validation to avoid use-after-free
        var ctx = FetchContext.begin_new(win);
        uint my_seq = ctx.seq;

        if (loading_state != null) {
            loading_state.initial_reveal_timeout_id = Timeout.add(NewsWindow.INITIAL_MAX_WAIT_MS, () => {
                if (!FetchContext.is_current(my_seq)) return false;
                var cur = FetchContext.current_context();
                if (cur == null) return false;
                var w = cur.window;
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
            Idle.add(() => {
                if (!FetchContext.is_current(my_seq)) return false;
                var cur = FetchContext.current_context();
                if (cur == null) return false;
                var w = cur.window;
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
            Idle.add(() => {
                if (!FetchContext.is_current(my_seq)) return false;
                var cur = FetchContext.current_context();
                if (cur == null) return false;
                var w = cur.window;
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
            var cur_start = FetchContext.current_context();
            if (cur_start == null || cur_start.seq != my_seq) return;
            var w = cur_start.window;
            if (w == null) return;

            if (w.prefs != null && cur_start.expected_category != null) {
                if (w.prefs.category != cur_start.expected_category) {
                    return;
                }
            }

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
                w.prefs.category == "lifestyle" ||
                w.prefs.category == "markets" ||
                w.prefs.category == "industries" ||
                w.prefs.category == "economics"
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
                        Timeout.add(60, () => {
                            int processed = 0;
                            int batch = 6;
                            while (local_news_queue.size > 0 && processed < batch) {
                                var ai = local_news_queue.get(0);
                                local_news_queue.remove_at(0);
                                if (!FetchContext.is_current(my_seq)) {
                                    // stale fetch; drop item
                                } else {
                                    var cur2 = FetchContext.current_context();
                                    if (cur2 != null) {
                                        var w2 = cur2.window;
                                        if (w2 != null && w2.prefs != null && cur2.expected_category != null) {
                                            if (w2.prefs.category == cur2.expected_category) {
                                                w2.article_manager.add_item(ai.title, ai.url, ai.thumbnail_url, ai.category_id, ai.source_name, ai.published);
                                            }
                                        } else if (w2 != null) {
                                            w2.article_manager.add_item(ai.title, ai.url, ai.thumbnail_url, ai.category_id, ai.source_name, ai.published);
                                        }
                                    }
                                }
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
        bool is_saved_view = (win.prefs.category == "saved");
        int total_sources = (win.prefs.preferred_sources != null ? win.prefs.preferred_sources.size : 0);
        if (is_myfeed_mode && custom_rss_sources != null) {
            total_sources += custom_rss_sources.size;
        }
        // frontpage/topten always issue one backend request regardless of source count
        bool is_frontpage_or_topten = win.category_manager.is_frontpage_view() || win.category_manager.is_topten_view();
        ctx.is_multi_source = !is_frontpage_or_topten && ((win.prefs.category == "sports") ||
            (!is_saved_view && (total_sources > 1 || (is_myfeed_mode && custom_rss_sources != null && custom_rss_sources.size > 0))));

        // always query the sports endpoint too, so users whose enabled sources have no
        // sports desk (e.g. PBS) still see content; runs alongside the normal fetch below
        if (win.prefs.category == "sports") {
            var paperboy_sports_fetcher = new PaperboyFetcher(FetchNewsController.global_forward_label, FetchNewsController.global_no_op_clear, FetchNewsController.global_add_item);
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

        if (win.category_manager.is_local_news_view()) {
            if (FetchNewsController.handle_local_news(win, ctx, wrapped_set_label, wrapped_clear, wrapped_add, win.session, current_search_query)) return;
        }

        if (win.category_manager.is_rssfeed_view()) {
            if (FetchNewsController.handle_rss_feed(win, wrapped_set_label, wrapped_clear, wrapped_add, win.session, current_search_query, my_seq))
                return;
        }
        // handled before the multi-source branch so it works with zero/one preferred sources
        if (win.category_manager.is_frontpage_view()) {
            used_multi = true;

                wrapped_clear();
                wrapped_set_label("Frontpage — Loading from backend (branch 1)");
            AppDebugger.log_rss("fetch_news: frontpage floor");
            NewsService.fetch(win.prefs.news_source, "frontpage", current_search_query, win.session, FetchNewsController.global_forward_label, FetchNewsController.global_no_op_clear, FetchNewsController.global_add_item);

            var sidebar_mgr = win.sidebar_manager;
            if (sidebar_mgr != null) {
                sidebar_mgr.schedule_badge_refresh("frontpage", my_seq);
            }
            return;
        }

        if (win.category_manager.is_topten_view()) {
            used_multi = true;

                wrapped_clear();
                wrapped_set_label("Top Ten — Loading from backend");
            NewsService.fetch(win.prefs.news_source, "topten", current_search_query, win.session, FetchNewsController.global_forward_label, FetchNewsController.global_no_op_clear, FetchNewsController.global_add_item);

            var sidebar_mgr = win.sidebar_manager;
            if (sidebar_mgr != null) {
                sidebar_mgr.schedule_badge_refresh("topten", my_seq);
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
                NewsService.fetch(win.prefs.news_source, "frontpage", current_search_query, win.session, FetchNewsController.global_forward_label, FetchNewsController.global_no_op_clear, FetchNewsController.global_add_item);
                
                // Schedule badge refresh for frontpage
                var sidebar_mgr = win.sidebar_manager;
                if (sidebar_mgr != null) {
                    sidebar_mgr.schedule_badge_refresh("frontpage", my_seq);
                }
                return;
            }

            if (win.category_manager.is_topten_view()) {
                used_multi = true;

                wrapped_clear();
                NewsService.fetch(win.prefs.news_source, "topten", current_search_query, win.session, FetchNewsController.global_forward_label, FetchNewsController.global_no_op_clear, FetchNewsController.global_add_item);

                var sidebar_mgr = win.sidebar_manager;
                if (sidebar_mgr != null) {
                    sidebar_mgr.schedule_badge_refresh("topten", my_seq);
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
                    FetchNewsController.global_forward_label,
                    FetchNewsController.global_no_op_clear,
                    FetchNewsController.global_add_item
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

                ClearItemsFunc no_op_clear = () => { };
                SetLabelFunc label_fn = (text) => {
                        Idle.add(() => {
                            if (!FetchContext.is_current(my_seq)) return false;
                            var cur = FetchContext.current_context();
                            if (cur == null) return false;
                            var w = cur.window;
                            if (w == null) return false;
                            w.update_content_header();
                            return false;
                        });
                };

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

                if (!is_myfeed_mode) {
                    var sidebar_mgr = win.sidebar_manager;
                    if (sidebar_mgr != null) {
                        sidebar_mgr.schedule_badge_refresh(win.prefs.category, my_seq);
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
                            FetchNewsController.global_forward_label,
                            no_op_clear,
                            FetchNewsController.global_add_item,
                            cache_key
                        );
                    }
                }
            }
        } else {
            if (win.category_manager.is_frontpage_view()) {
                wrapped_clear();
                wrapped_set_label("Frontpage — Loading from backend (single-source)");
                NewsService.fetch(win.prefs.news_source, "frontpage", current_search_query, win.session, FetchNewsController.global_forward_label, FetchNewsController.global_no_op_clear, FetchNewsController.global_add_item);

                var sidebar_mgr = win.sidebar_manager;
                if (sidebar_mgr != null) {
                    sidebar_mgr.schedule_badge_refresh("frontpage", my_seq);
                }
                return;
            }

            if (win.category_manager.is_topten_view()) {
                wrapped_clear();
                wrapped_set_label("Top Ten — Loading from backend (single-source)");
                NewsService.fetch(win.prefs.news_source, "topten", current_search_query, win.session, FetchNewsController.global_forward_label, FetchNewsController.global_no_op_clear, FetchNewsController.global_add_item);

                var sidebar_mgr = win.sidebar_manager;
                if (sidebar_mgr != null) {
                    sidebar_mgr.schedule_badge_refresh("topten", my_seq);
                }
                return;
            }

            if (is_myfeed_mode) {
                wrapped_clear();
                ClearItemsFunc no_op_clear = () => { };
                SetLabelFunc label_fn = (text) => {
                    Idle.add(() => {
                        if (!FetchContext.is_current(my_seq)) return false;
                        var cur = FetchContext.current_context();
                        if (cur == null) return false;
                        var w = cur.window;
                        if (w == null) return false;
                        w.update_content_header();
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
                        string? cache_key = (rss_src.url.has_prefix("file://") && rss_src.original_url != null) ? rss_src.original_url : null;
                        RssFeedProcessor.fetch_rss_url(
                            rss_src.url,
                            rss_src.url,  // use URL, not name, for source filtering
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
                                    w.update_content_header();
                                    return false;
                                });
                            },
                            no_op_clear,
                            wrapped_add,
                            cache_key
                        );
                    }
                }

                var sidebar_mgr = win.sidebar_manager;
                if (sidebar_mgr != null) {
                    sidebar_mgr.schedule_badge_refresh("myfeed", my_seq);
                }
            } else {
                wrapped_clear();
                NewsService.fetch(
                    win.effective_news_source(),
                    win.prefs.category,
                    current_search_query,
                    win.session,
                    FetchNewsController.global_forward_label,
                    FetchNewsController.global_no_op_clear,
                    FetchNewsController.global_add_item
                );

                var sidebar_mgr = win.sidebar_manager;
                if (sidebar_mgr != null) {
                    sidebar_mgr.schedule_badge_refresh(win.prefs.category, my_seq);
                }
            }
        }
    }

    public static void schedule_adaptive_layout_check(NewsWindow win, uint my_seq) {
        // check immediately, then again after a delay in case articles are still registering
        Idle.add(() => {
            if (!FetchContext.is_current(my_seq)) return false;
            perform_adaptive_check(win, my_seq);
            return false;
        });

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
                        var c = FetchContext.current_context();
                        if (c != null && c.window != null && c.window.layout_manager != null) {
                            // rebuild_as_category_heroes() will handle revealing content
                            c.window.layout_manager.rebuild_as_category_heroes();
                        }
                        return false;
                    });
                } else if (actual_count >= 15) {
                    // No adaptive layout needed (>= 15 articles), allow normal spinner hiding
                    if (w.loading_state != null) {
                        w.loading_state.awaiting_adaptive_layout = false;
                        // Trigger reveal if items are already populated
                        if (w.loading_state.initial_items_populated) {
                            // CRITICAL: Don't use reveal_initial_content() - it exits early if initial_phase is false
                            if (w.loading_state != null) {
                                w.loading_state.initial_phase = false;
                                w.loading_state.hero_image_loaded = false;
                            }
                            w.hide_loading_spinner();
                            if (w.main_content_container != null) {
                                w.main_content_container.set_visible(true);
                            }
                        }
                    }
                }
                // If actual_count == 0, keep waiting (don't clear flag yet)
            }
        }
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

                w.update_content_header();
                return false;
            });
        };

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
                FetchNewsController.global_add_item(
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
                label_fn("%s — Offline, showing %d cached articles".printf(feed_name_plain, cached_articles.size));
                win.show_toast("Offline - showing cached articles");
            } else {
                label_fn("%s — Loaded %d articles from cache".printf(feed_name_plain, cached_articles.size));
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
        SetLabelFunc fetch_label_fn;
        if (cached_articles.size > 0) {
            fetch_label_fn = (s) => {}; // No-op to prevent error messages when cached content is shown
        } else {
            fetch_label_fn = FetchNewsController.global_forward_label;
        }

        RssFeedProcessor.fetch_rss_url(
            feed_url,
            feed_name,
            feed_name,
            "rssfeed:" + feed_url,
            current_search_query,
            session,
            fetch_label_fn,
            no_op_clear,
            FetchNewsController.global_add_item,
            cache_key
        );

        // Update badge after articles finish loading
        if (win.sidebar_manager != null) {
            win.sidebar_manager.schedule_source_badge_refresh(feed_name, my_seq);
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
            win.hide_loading_spinner();
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
                wrapped_set_label("Search Results: " + current_search_query + " in Saved Articles");
            } else {
                wrapped_set_label("Saved Articles");
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
                            wrapped_add(article.title, article.url, article.thumbnail, "saved", article.source ?? "Saved", article.published);
                        }
                    }
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

            // Reveal content immediately - saved articles are local, no network wait needed
            // CRITICAL: Don't use reveal_initial_content() here because it exits early if initial_phase is false
            // After an RSS timeout error, initial_phase is already false, so we must directly show the container
            w.hide_loading_spinner();
            if (w.main_content_container != null) {
                w.main_content_container.set_visible(true);
            }
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

        var prefs = NewsPreferences.get_instance();
        string display_city = (prefs.user_location_city != null && prefs.user_location_city.length > 0)
            ? prefs.user_location_city
            : prefs.user_location;

        if (display_city == null || display_city.strip().length == 0) {
            wrapped_set_label("Local News — No location configured");
            win.hide_loading_spinner();
            return true;
        }

        // Prefer the nearest-major-city search term (falls back to the
        // exact resolved city for locations already near/in a major city,
        // or for locations saved without running the geocode lookup).
        string news_query_city = (prefs.user_location_news_query != null && prefs.user_location_news_query.length > 0)
            ? prefs.user_location_news_query
            : display_city;

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

        // Fetch both the exact resolved town and the nearest major metro
        // (when they differ) so users near a small town get that town's
        // own coverage plus the metro's, rather than just one or the
        // other. ArticleManager already dedupes by normalized URL, so any
        // story both searches turn up is only shown once.
        fetch_local_news_query(display_city, "local_news", current_search_query, session);
        if (news_query_city != display_city) {
            fetch_local_news_query(news_query_city, "local_news", current_search_query, session);
        }

        return true;
    }

    private static void fetch_local_news_query(string city, string category_id, string current_search_query, Soup.Session session) {
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
            FetchNewsController.global_add_item(
                article.title,
                article.url,
                article.thumbnail_url,
                category_id,
                city,
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
            FetchNewsController.global_forward_label,
            FetchNewsController.global_no_op_clear,
            FetchNewsController.global_add_item
        );
    }
}
