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
        public const int TRENDING_HERO_MAX_HEIGHT = 480;
        public const int TRENDING_HERO_DEFAULT_HEIGHT = 480;
        // Two rows of four under Trending's two hero cards.
        public const int TRENDING_GRID_MAX = 8;
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

        // Per-row real-card counts for My Feed and Front Page rows (keyed by section key), reset each fetch.
        // Each row gets its own cap instead of sharing articles_shown/INITIAL_ARTICLE_LIMIT.
        private Gee.HashMap<string, int>? row_card_counts = null;
        private const int MYFEED_ROW_CARD_CAP = 10;

        // Track URLs seen in current view to prevent duplicate cards
        private Gee.HashSet<string> seen_urls;

        // Trending gets its own dedup set, separate from seen_urls - it's a
        // second fetch layered onto the Front Page and its top stories
        // commonly overlap URL-wise with what the primary Front Page stream
        // (Headlines, World, etc.) already put in seen_urls; sharing that
        // set would silently drop most of Trending's own grid cards.
        private Gee.HashSet<string> trending_seen_urls;

        // Returns true (already seen) if normalized_url is already in the
        // relevant per-stream set, otherwise marks it seen and returns
        // false. This only prevents the exact same URL from appearing
        // twice within its own stream (Trending vs. everything else) - it
        // does not try to cross-dedup Trending against Headlines, since
        // that turned into a hard stop that could withhold real, distinct
        // articles when URL matching wasn't reliable. Vala's lock statement
        // requires a member access, not a local variable, hence this
        // switches on is_trending internally rather than the caller
        // picking a set to lock.
        private bool already_seen_and_mark(string normalized_url, bool is_trending) {
            if (is_trending) {
                lock (trending_seen_urls) {
                    if (trending_seen_urls.contains(normalized_url)) return true;
                    trending_seen_urls.add(normalized_url);
                }
            } else {
                lock (seen_urls) {
                    if (seen_urls.contains(normalized_url)) return true;
                    seen_urls.add(normalized_url);
                }
            }
            return false;
        }

        // Category distribution
        public Gee.HashMap<string, int> category_column_counts;
        public Gee.ArrayList<string> recent_categories;
        public Gee.HashMap<string, int> category_last_column;
        public Gee.ArrayList<string> recent_category_queue;
        
        public int trending_hero_count = 0;
        public int trending_grid_count = 0;
        public Gee.ArrayList<ArticleItem>? featured_carousel_items;
        public HeroCarousel? hero_carousel;
        public string? featured_carousel_category = null;
        public bool featured_used = false;
        
        private bool load_more_button_visible = false;
        public uint buffer_flush_timeout_id = 0;

        // Front Page "Recommended for you" picks are held until the batch settles, then ranked into the panel.
        private const int RECOMMENDED_MAX_PICKS = 8;
        private const int RECOMMENDED_MAX_PER_CATEGORY = 2;
        // Looser cap used only to top up a short panel.
        private const int RECOMMENDED_FILL_PER_CATEGORY = 4;
        private const uint RECOMMENDED_SETTLE_MS = 500;
        private class RecommendedPick {
            public ArticleItem item;
            public double score;
            public RecommendedPick(ArticleItem item, double score) { this.item = item; this.score = score; }
        }
        private Gee.ArrayList<RecommendedPick> recommended_picks = new Gee.ArrayList<RecommendedPick>();
        private bool recommendations_finalized = false;
        private uint recommendations_settle_id = 0;
        // What the panel shows (in slot order), and the next-best picks to fill in for a dislike.
        private Gee.ArrayList<RecommendedPick> panel_picks = new Gee.ArrayList<RecommendedPick>();
        private Gee.ArrayList<RecommendedPick> panel_reserve = new Gee.ArrayList<RecommendedPick>();
        private int panel_rail_rows = 0;
        private bool feedback_connected = false;
        
        // Signals for UI operations
        public signal void request_show_load_more_button();
        public signal void request_hide_load_more_button();
        public signal void request_reset_load_more_button();
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
            trending_seen_urls = new Gee.HashSet<string>();
        }

        public void open_article_in_app_if_online(string article_url, bool? force_reader_view = null, string? source_name_encoded = null, string? title = null, string? thumbnail_url = null, string? published = null, string? category_id = null) {
            var network_monitor = GLib.NetworkMonitor.get_default();
            if (!network_monitor.get_network_available()) {
                request_show_toast("You're offline. Enable internet connection to view articles");
                return;
            }

            // Open the real URL: normalizing strips query strings some sites need (ABC's story?id=).
            window.mark_article_viewed(window.normalize_article_url(article_url));
            if (window.article_state_store != null) {
                window.article_state_store.record_history(article_url, title, thumbnail_url, source_name_encoded, published, category_id);
            }
            if (window.article_sheet != null) window.article_sheet.open(article_url, force_reader_view, source_name_encoded);
        }

        public void open_article_in_browser_if_online(string article_url, string? source_name = null, string? title = null, string? thumbnail_url = null, string? published = null, string? category_id = null) {
            var network_monitor = GLib.NetworkMonitor.get_default();
            if (!network_monitor.get_network_available()) {
                request_show_toast("You're offline. Enable internet connection to view articles");
                return;
            }

            window.mark_article_viewed(window.normalize_article_url(article_url));
            if (window.article_state_store != null) {
                window.article_state_store.record_history(article_url, title, thumbnail_url, source_name, published, category_id);
            }
            if (window.article_pane != null) window.article_pane.open_article_in_browser(article_url);
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
        // already_marked: the caller has already claimed this URL in seen_urls.
        private bool queue_overflow_article(string title, string url, string? thumbnail_url,
                                            string category_id, string? source_name, string? published = null, string? snippet = null, bool already_marked = false) {
            string normalized_url = "";
            normalized_url = window.normalize_article_url(url); 
            
            if (!already_marked && normalized_url.length > 0 && seen_urls.contains(normalized_url)) {
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
            string display_cat = overflow_key_for(queued_item);
            remaining_category_counts.set(display_cat, remaining_category_counts.get(display_cat) + 1);

            // Register for unread tracking
            string norm = url.strip();
            if (norm.length > 0 && window.article_state_store != null) {
                window.article_state_store.register_article(norm, category_id, normalized_source);
            }

            // A category with zero cards in the initial cap would otherwise
            // stay hidden with no way to reach its queued overflow - see
            // LayoutManager.reveal_sections_with_pending_overflow(). Debounced
            // via a single idle latch so a batch of articles triggers one
            // reveal pass, not one per article.
            if (window.layout_manager != null && !reveal_pending) {
                reveal_pending = true;
                ViewSession.view_idle(() => {
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
        // category travels in source_name's SourceLabel.
        private string resolve_display_category(string category_id, string? source_name) {
            if (category_id != "frontpage") return category_id;
            // Bound to a local first: Vala frees a temporary struct's fields
            // before a ?? on them is used
            var label = SourceLabel.parse(source_name);
            return label.category ?? category_id;
        }

        private string extract_display_category(ArticleItem item) {
            return resolve_display_category(item.category_id, item.source_name);
        }

        // Front Page overflow is grouped by row, so each row's arrow finds its own queued articles.
        private string overflow_key_for(ArticleItem item) {
            string cat = extract_display_category(item);
            return window.prefs.category == "frontpage" ? LayoutManager.frontpage_row_for(cat) : cat;
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
            // Hold this batch's entrance animation until any backfill
            // extractions triggered by placing it have resolved (or a
            // bounded grace period passes) - see BackfillBatchGate.
            var backfill_gate = new BackfillBatchGate();
            ThumbnailBackfillService.current_batch = backfill_gate;
            var session = ViewSession.current();

            int loaded = 0;
            int i = 0;
            while (i < remaining_articles.size && loaded < max_to_load) {
                var item = remaining_articles.get(i);
                if (overflow_key_for(item) == cat) {
                    remaining_articles.remove_at(i);
                    remaining_category_counts.set(cat, remaining_category_counts.get(cat) - 1);
                    article_buffer.add(item);
                    add_item_immediate_to_column(item.title, item.url, item.thumbnail_url, item.category_id, null, item.source_name, true, item.published);
                    loaded++;
                } else {
                    i++;
                }
            }

            ThumbnailBackfillService.current_batch = null;

            // Hide the newly placed cards immediately (rather than letting
            // them sit at full opacity until animate_cards_entrance_batch
            // gets around to them) so the hold above actually keeps
            // placeholders off-screen instead of just delaying their fade-in.
            if (row != null && window != null && window.animation_manager != null) {
                int idx0 = 0;
                var c0 = row.get_first_child();
                while (c0 != null) {
                    if (idx0 >= prev_count) c0.set_visible(false);
                    idx0++;
                    c0 = c0.get_next_sibling();
                }
            }

            if (row != null && window != null && window.animation_manager != null) {
                var anim_mgr = window.animation_manager;
                backfill_gate.ready.connect(() => {
                    // Delay until idle so widgets are realized/parented.
                    session.idle(() => {
                        var cards = new Gee.ArrayList<Gtk.Widget>();
                        int idx = 0;
                        var child = row.get_first_child();
                        while (child != null) {
                            if (idx >= prev_count) cards.add(child);
                            idx++;
                            child = child.get_next_sibling();
                        }
                        anim_mgr.animate_cards_entrance_batch(cards);
                        return false;
                    });
                });
            }
            backfill_gate.begin();
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
            NewsSource named = BuiltinSources.from_name(source_name);
            if (named != NewsSource.UNKNOWN && window.source_manager.get_enabled_source_enums().contains(named)) {
                return "source:" + BuiltinSources.for_source(named).id;
            }
            return null;
        }

        // Single gate for every card. Keyed on the on-screen category so it also covers the gap before the new fetch starts.
        private bool view_allows_item(string category_id) {
            string? cat = window.prefs != null ? window.prefs.category : null;
            bool local_only = cat == "saved" || cat == "history";
            return !local_only || category_id == cat;
        }

        public void add_item(string title, string url, string? thumbnail_url, string category_id, string? source_name, string? published = null, string? snippet = null, bool is_trending = false) {
            if (!view_allows_item(category_id)) return;
            if (is_trending && (trending_full() || in_hero_carousel(url))) return;
            bool is_myfeed = window.category_manager.is_myfeed_view();
            // "Recommended for you" picks get their own budget instead of the Front Page cap.
            double recommended_score = is_trending ? -1 : score_recommendation(title, url, category_id, source_name);
            bool recommended = recommended_score >= InterestProfile.MATCH_THRESHOLD;
            if (recommended) recommended_score = rank_recommendation(recommended_score, title, published);

            // My Feed doesn't use the flat article-count cap: its rows are
            // independent scrolling strips, not one shared grid, and several
            // row kinds have no "load more" path to rescue overflow (see
            // LayoutManager.reveal_sections_with_pending_overflow).
            // Trending is exempt too - it's a second, independently-capped
            // fetch layered onto the Front Page and must not share (or
            // exhaust) the Front Page's own INITIAL_ARTICLE_LIMIT counter.
            if (!is_trending && !recommended && window.prefs.category == "frontpage") {
                if (frontpage_featured_full() && frontpage_row_full(frontpage_row_key(category_id, source_name))) {
                    if (queue_overflow_article(title, url, thumbnail_url, category_id, source_name, published, snippet)) {
                        show_load_more_button();
                    }
                    return;
                }
            } else if (!is_myfeed && !is_trending && !recommended && is_limited_category(window.prefs.category)) {
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
            // when multiple async fetches race on the same URL. Different
            // providers covering the same headline naturally have different
            // URLs, so this never blocked that case - it was only letting
            // exact same-provider duplicates through in Top Ten. Trending
            // uses its own set (see trending_seen_urls) instead of sharing
            // seen_urls with the Front Page's own concurrent stream.
            if (normalized.length > 0 && already_seen_and_mark(normalized, is_trending)) {
                // Backfill the already-rendered card's time caption: a published
                // date it doesn't have yet, or a reading time recorded since
                // (e.g. a cached card re-sent by a fresh API fetch).
                if (window.view_state != null) {
                    var existing_widgets = window.view_state.get_cards_for_url(normalized);
                    if (existing_widgets != null) {
                        foreach (var existing_widget in existing_widgets) {
                            string? existing_base = existing_widget.get_data<string>("article-time-base");
                            if (existing_base != null && existing_base == "" && published != null && published.length > 0) {
                                existing_widget.set_data("article-time-base", DateUtils.time_ago(published));
                            }
                            CardBuilder.refresh_card_time(existing_widget);
                        }
                    }
                }
                return;
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
                    // widgets for the same normalized URL. Skip for Trending, where
                    // distinct headlines can normalize to the same URL (tracking
                    // params stripped) and shouldn't collapse into one card.
                    if (!is_trending) {
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
                        if (window.loading_state != null) window.loading_state.track_pending_image(existing);
                        window.image_manager.load_image_async(existing, thumbnail_url, target_w, target_h, true);
                        return;
                    } else {
                    }
            }

            // Saved/History articles should always display regardless of source
            bool is_saved_view = (window.prefs.category == "saved" || window.prefs.category == "history");

            if (!is_saved_view) {
                if (!window.category_manager.should_display_article(category_id)) {
                    if (debug_enabled()) {
                        warning("Article filtered by category: view=%s article_cat=%s title=%s",
                                window.category_manager.get_current_category(), category_id, title);
                    }
                    return;
                }

                // Built-in outlets the user turned off are hidden everywhere -
                // except in their own followed RSS feeds (a feed's page, or its
                // "myfeed"-tagged articles in My Feed), which they chose directly.
                bool from_followed_feed = window.category_manager.is_rssfeed_view() || category_id == "myfeed";
                if (!from_followed_feed && window.source_manager != null && window.source_manager.is_from_disabled_source(url)) {
                    return;
                }
            }

            if (recommended) {
                var held = new ArticleItem(title, url, thumbnail_url, category_id, final_source_name, published);
                held.snippet = snippet;
                hold_recommended_pick(new RecommendedPick(held, recommended_score));
                return;
            }

            add_item_immediate_to_column(title, url, thumbnail_url, category_id, null, final_source_name, false, published, snippet, myfeed_row_key_hint, is_trending);
        }

        // Trending's fetcher sends Front Page backfill after its headlines, so
        // it can over-supply; the cap here keeps the grid at two full rows.
        private bool trending_full() {
            return trending_hero_count >= 2 && trending_grid_count >= TRENDING_GRID_MAX;
        }

        // Backfill comes from the same feed as the hero carousel, so skip
        // anything already showing up there.
        private bool in_hero_carousel(string? url) {
            if (url == null || featured_carousel_items == null) return false;
            string norm = window.normalize_article_url(url);
            foreach (var item in featured_carousel_items) {
                if (item.url != null && window.normalize_article_url(item.url) == norm) return true;
            }
            return false;
        }

        // -1 when this article can't be a "Recommended for you" pick right now.
        private double score_recommendation(string title, string url, string category_id, string? source_name) {
            if (recommendations_finalized || window.prefs.category != "frontpage" || window.layout_manager == null) return -1;
            var profile = window.layout_manager.recommendation_profile;
            if (profile == null) return -1;
            if (window.article_state_store != null) {
                string norm = window.normalize_article_url(url);
                if (window.article_state_store.is_viewed(norm) || window.article_state_store.get_feedback(norm) != 0) return -1;
            }
            return profile.score(title, url, category_id, source_name);
        }

        // Ordering only, so a qualifying pick is never dropped just for being shown before.
        private double rank_recommendation(double score, string title, string? published) {
            var profile = window.layout_manager.recommendation_profile;
            int impressions = window.article_state_store != null ? window.article_state_store.get_recommendation_impressions(story_key(title)) : 0;
            return profile.adjust(score, published, impressions);
        }

        // The same story can arrive under several URLs.
        private static string story_key(string title) {
            return title.strip().down();
        }

        private void hold_recommended_pick(RecommendedPick pick) {
            recommended_picks.add(pick);
            ViewSession.remove_source(ref recommendations_settle_id);
            recommendations_settle_id = ViewSession.view_timeout(RECOMMENDED_SETTLE_MS, () => {
                recommendations_settle_id = 0;
                finalize_recommendations();
                return false;
            });
        }

        // Ranks the held picks into the "Recommended for you" panel; the rest go back to their category rows.
        // Runs once per fetch: when picks stop arriving, or when the Front Page list finishes.
        public void finalize_recommendations() {
            if (recommendations_finalized) return;
            recommendations_finalized = true;
            ViewSession.remove_source(ref recommendations_settle_id);

            var picks = recommended_picks;
            recommended_picks = new Gee.ArrayList<RecommendedPick>();
            if (picks.size == 0) return;
            picks.sort((a, b) => a.score < b.score ? 1 : (a.score > b.score ? -1 : 0));

            var chosen = new Gee.ArrayList<RecommendedPick>();
            var per_category = new Gee.HashMap<string, int>();
            var chosen_titles = new Gee.HashSet<string>();
            foreach (int cap in new int[] { RECOMMENDED_MAX_PER_CATEGORY, RECOMMENDED_FILL_PER_CATEGORY }) {
                foreach (var pick in picks) {
                    string cat = extract_display_category(pick.item);
                    string title_key = story_key(pick.item.title);
                    if (chosen.size < RECOMMENDED_MAX_PICKS && !chosen.contains(pick) && !chosen_titles.contains(title_key) && per_category.get(cat) < cap) {
                        chosen.add(pick);
                        chosen_titles.add(title_key);
                        per_category.set(cat, per_category.get(cat) + 1);
                    }
                }
            }
            chosen.sort((a, b) => a.score < b.score ? 1 : (a.score > b.score ? -1 : 0));
            // Trim to a size that fills the layout; the rest wait as dislike replacements.
            while (chosen.size > RecommendedSection.panel_size_for(chosen.size)) chosen.remove_at(chosen.size - 1);

            var leftovers = new Gee.ArrayList<ArticleItem>();
            var reserve = new Gee.ArrayList<RecommendedPick>();
            foreach (var pick in picks) {
                if (chosen.contains(pick)) continue;
                leftovers.add(pick.item);
                reserve.add(pick);
            }

            RecommendedSection? section = window.layout_manager != null ? window.layout_manager.recommended_section : null;
            if (section != null && chosen.size >= RecommendedSection.MIN_PICKS && window.prefs.category == "frontpage") {
                panel_reserve = reserve;
                build_recommended_panel(section, chosen);
                record_impressions(chosen);
                if (!feedback_connected && window.article_state_store != null) {
                    window.article_state_store.feedback_changed.connect(on_feedback_changed);
                    feedback_connected = true;
                }
            } else {
                for (int i = 0; i < chosen.size; i++) leftovers.insert(i, chosen.get(i).item);
            }

            foreach (var item in leftovers) {
                add_item_immediate_to_column(item.title, item.url, item.thumbnail_url, item.category_id, null, item.source_name, false, item.published, item.snippet);
            }
        }

        private void record_impressions(Gee.List<RecommendedPick> shown) {
            if (window.article_state_store == null) return;
            var keys = new Gee.ArrayList<string>();
            foreach (var pick in shown) keys.add(story_key(pick.item.title));
            window.article_state_store.record_recommendation_impressions(keys);
        }

        // Lead hero, then rail rows, then grid cards, in score order (see RecommendedSection.rail_rows_for).
        private void build_recommended_panel(RecommendedSection section, Gee.ArrayList<RecommendedPick> chosen) {
            panel_picks = chosen;
            panel_rail_rows = RecommendedSection.rail_rows_for(chosen.size);
            for (int i = 0; i < chosen.size; i++) place_recommended_pick(section, chosen.get(i).item, i);
        }

        // Slot i's card: the lead, a rail row, or a grid card.
        private void place_recommended_pick(RecommendedSection section, ArticleItem item, int i) {
            int rail_rows = panel_rail_rows;
            int lead_h = section.lead_height(rail_rows);
            string decoded_title = stripHtmlUtils.strip_html(item.title);
            string category_text = window.category_chip_text(extract_display_category(item));
            // Snippet/published fallback for the preview pane, as add_item_immediate_to_column does.
            article_buffer.add(item);

            if (i == 0) {
                var hero = new HeroCard.for_topten(decoded_title, item.url, lead_h, category_text, true, window.article_state_store, window, item.published);
                hero.title_label.set_lines(3);
                // Fixed text area instead of for_topten's 70/30 split, so the lead stays exactly lead_h tall.
                int lead_image_h = lead_h - RecommendedSection.LEAD_TEXT_HEIGHT;
                hero.image.set_size_request(-1, lead_image_h);
                hero.title_box.set_size_request(-1, RecommendedSection.LEAD_TEXT_HEIGHT - hero.title_box.get_margin_top() - hero.title_box.get_margin_bottom());
                section.set_lead(hero.root);
                wire_hero_card(hero, decoded_title, item.url, item.thumbnail_url, item.category_id, item.source_name, item.published, true, false, section.lead_width, lead_image_h);
            } else if (i <= rail_rows) {
                var row = new HistoryCard(decoded_title, item.url, item.source_name, 0, category_text, section.rail_min_width, DateUtils.time_ago(item.published), RecommendedSection.RAIL_ROW_HEIGHT);
                row.enable_hover_actions(window);
                section.add_rail(row.root);
                wire_history_card(row, decoded_title, item.url, item.thumbnail_url, item.source_name, item.published, item.category_id);
            } else {
                place_regular_article_card(decoded_title, item.url, item.thumbnail_url, item.category_id, item.source_name, false, item.published, LayoutManager.RECOMMENDED_SECTION_KEY, true, false, section.grid_card_min_width);
            }
        }

        // A dislike on a panel card fades it out, then the next-best reserve pick takes its slot.
        private void on_feedback_changed(string url, int vote) {
            if (vote >= 0 || window.prefs.category != "frontpage" || panel_index_of(url) < 0) return;
            var old = window.view_state != null ? window.view_state.get_card_for_url(url) : null;
            if (old != null) Managers.AnimationManager.fade_opacity(old, 0.0);
            ViewSession.view_timeout(180, () => {
                // Un-disliked during the fade.
                if (window.article_state_store.get_feedback(url) >= 0) {
                    var card = window.view_state != null ? window.view_state.get_card_for_url(url) : null;
                    if (card != null) Managers.AnimationManager.fade_opacity(card, 1.0);
                    return false;
                }
                replace_panel_pick(url);
                return false;
            });
        }

        private int panel_index_of(string normalized) {
            for (int i = 0; i < panel_picks.size; i++) {
                if (window.normalize_article_url(panel_picks.get(i).item.url) == normalized) return i;
            }
            return -1;
        }

        private void replace_panel_pick(string normalized) {
            RecommendedSection? section = window.layout_manager != null ? window.layout_manager.recommended_section : null;
            int idx = panel_index_of(normalized);
            if (section == null || idx < 0 || window.view_state == null) return;

            var old = window.view_state.get_card_for_url(normalized);
            window.view_state.unregister_card_for_url(normalized);
            window.view_state.url_to_picture.unset(normalized);

            var next = take_reserve_pick(idx);
            if (next != null && old != null) {
                panel_picks.set(idx, next);
                section.begin_swap(old);
                place_recommended_pick(section, next.item, idx);
                var swapped_in = new Gee.ArrayList<RecommendedPick>();
                swapped_in.add(next);
                record_impressions(swapped_in);
                var added = window.view_state.get_card_for_url(window.normalize_article_url(next.item.url));
                if (added != null && window.animation_manager != null) window.animation_manager.animate_card_entrance(added, 0);
                return;
            }

            // Nothing to fill in with: rebuild from what's left; picks that don't fit go back to the category rows.
            panel_picks.remove_at(idx);
            foreach (var pick in panel_picks) window.view_state.unregister_card_for_url(window.normalize_article_url(pick.item.url));
            section.clear();
            var rest = new Gee.ArrayList<RecommendedPick>();
            int keep = RecommendedSection.panel_size_for(panel_picks.size);
            while (panel_picks.size > keep) rest.insert(0, panel_picks.remove_at(panel_picks.size - 1));
            if (keep > 0) build_recommended_panel(section, panel_picks);
            foreach (var pick in rest) {
                var item = pick.item;
                add_item_immediate_to_column(item.title, item.url, item.thumbnail_url, item.category_id, null, item.source_name, true, item.published, item.snippet);
            }
        }

        // Best reserve pick that fits slot idx's category cap; its plain card leaves its category row.
        private RecommendedPick? take_reserve_pick(int idx) {
            var rows_container = window.layout_manager.category_sections_container;
            if (rows_container == null) return null;
            var per_category = new Gee.HashMap<string, int>();
            for (int i = 0; i < panel_picks.size; i++) {
                if (i == idx) continue;
                string cat = extract_display_category(panel_picks.get(i).item);
                per_category.set(cat, per_category.get(cat) + 1);
            }

            for (int r = 0; r < panel_reserve.size; r++) {
                var pick = panel_reserve.get(r);
                string norm = window.normalize_article_url(pick.item.url);
                if (per_category.get(extract_display_category(pick.item)) >= RECOMMENDED_MAX_PER_CATEGORY) continue;
                panel_reserve.remove_at(r--);
                if (window.article_state_store != null && window.article_state_store.get_feedback(norm) < 0) continue;

                // Only cards showing in a category row; heroes, carousel slides and queued overflow stay put.
                var cards = window.view_state.get_cards_for_url(norm);
                if (cards == null || cards.size == 0) continue;
                bool movable = true;
                foreach (var card in cards) {
                    if (card.get_data<string>("hero-url") != null || !card.is_ancestor(rows_container)) movable = false;
                }
                if (!movable) continue;

                var row_cards = new Gee.ArrayList<Gtk.Widget>();
                row_cards.add_all(cards);
                window.view_state.unregister_card_for_url(norm);
                foreach (var card in row_cards) {
                    if (window.animation_manager != null) window.animation_manager.animate_card_exit_and_remove(card, 0);
                }
                return pick;
            }
            return null;
        }

        public void add_item_immediate_to_column(string title, string url, string? thumbnail_url, string category_id, string? original_category = null, string? source_name = null, bool bypass_limit = false, string? published = null, string? snippet = null, string? myfeed_row_key_hint = null, bool is_trending = false) {
            if (!view_allows_item(category_id)) return;
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

            if (window.prefs.category == "frontpage" && !is_trending) {
                if (frontpage_featured_full()) {
                    string row_key = frontpage_row_key(category_id, source_name);
                    if (!bypass_limit && frontpage_row_full(row_key)) {
                        string normalized_src = normalize_source_name(source_name, category_id, url);
                        if (queue_overflow_article(title, url, thumbnail_url, category_id, normalized_src, published, snippet, true)) {
                            show_load_more_button();
                        }
                        return;
                    }
                    count_frontpage_row_card(row_key);
                }
            // My Feed is exempt here too - see add_item() above.
            } else if (is_limited_category(check_category) && !bypass_limit && !is_trending && window.prefs.category != "myfeed") {
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
            if (window.prefs.category == "saved" || window.prefs.category == "history") {
                should_be_hero = false;
            } else if (is_trending) {
                should_be_hero = (trending_hero_count < 2);
            } else if (window.prefs.category == "frontpage") {
                should_be_hero = !featured_used;
            } else if (window.category_manager.is_rssfeed_view()) {
                should_be_hero = false;
            } else if (!featured_used) {
                should_be_hero = true;
            }
            
            if (should_be_hero) {
                // Trending uses slightly scaled hero cards
                double hero_scale = is_trending ? 1.30 : 1.0;
                int max_hero_height = is_trending ? TRENDING_HERO_MAX_HEIGHT : HERO_MAX_HEIGHT;
                int default_hero_w = window.estimate_content_width();
                int default_hero_h = is_trending ? TRENDING_HERO_DEFAULT_HEIGHT : HERO_DEFAULT_HEIGHT;

                string hero_display_cat = resolve_display_category(category_id, source_name);

                string hero_category_text = window.category_chip_text(hero_display_cat);

                // Enable context menu for: 1) Trending hero cards, 2) RSS feeds with < 15 articles
                bool enable_hero_context_menu = false;
                if (is_trending) {
                    enable_hero_context_menu = true;
                } else if (window.category_manager.is_rssfeed_view() && articles_shown < 15) {
                    enable_hero_context_menu = true;
                }

                var hero_card = window.layout_manager.create_and_place_hero_card(
                    decoded_title,
                    url,
                    max_hero_height,
                    default_hero_h,
                    hero_category_text,
                    enable_hero_context_menu,
                    is_trending,
                    published
                );

                // Skipped for Trending: its stacked layout only has room for the title.
                wire_hero_card(hero_card, decoded_title, url, thumbnail_url, category_id, source_name, published, enable_hero_context_menu, !is_trending, default_hero_w, default_hero_h);

                if (is_trending) {
                    if (trending_hero_count < 2) {
                        trending_hero_count++;
                        // Not featured_used: that's the Front Page's own hero
                        // carousel. Setting it here meant a Trending item that
                        // arrived first (no cached Front Page yet, e.g. a newly
                        // picked country) stopped the carousel being created.
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

            if (!is_trending && hero_carousel != null && featured_carousel_items != null &&
            featured_carousel_items.size < 5) {
            bool allow_slide = false;
            if (window.prefs.category == "myfeed" && window.prefs.personalized_feed_enabled) {
                if (category_id == "myfeed") {
                    allow_slide = true;
                } else if (featured_carousel_category != null && featured_carousel_category == category_id) {
                    allow_slide = true;
                } else {
                    bool has_personalized = window.prefs.categories != null && window.prefs.categories.size > 0;
                    if (!has_personalized) {
                        allow_slide = true;
                    } else {
                        foreach (var pc in window.prefs.categories) {
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

            string slide_display_cat = resolve_display_category(category_id, source_name);

            if (hero_carousel == null && window.layout_manager != null && window.layout_manager.featured_box != null) {
                hero_carousel = new HeroCarousel(window.layout_manager.featured_box);
            }

            string slide_category_text = window.category_chip_text(slide_display_cat);
            var components = hero_carousel.create_article_slide(
                decoded_title, url, thumbnail_url, category_id, source_name, slide_category_text,
                (t, u, thumb, cat, src) => { window.article_pane.show_article_preview(t, u, thumb, cat, src); },
                published,
                (article_url) => { open_article_in_app_if_online(article_url, true, source_name, decoded_title, thumbnail_url, published, category_id); }
            );

            var slide_hero = components.hero;
            if (slide_hero != null) {
                ArticleSnippetService.attach_hero_snippet(slide_hero, url, source_name, article_buffer);
                var slide_source_badge = window.build_source_badge_dynamic(source_name, url, category_id);
                CardBuilder.attach_source_badge(window, slide_hero.root, slide_hero.overlay, slide_source_badge, url, source_name, window.prefs.category == "frontpage");
                CardBuilder.attach_feedback_buttons(window, slide_hero.root, slide_hero.overlay, url, decoded_title, source_name, category_id);
            }
            var slide = components.slide;
            var slide_image = components.image;

            int default_w = window.estimate_content_width();
            int default_h = HeroCarousel.SLIDE_IMAGE_HEIGHT;
            bool slide_will_load = thumbnail_url != null && thumbnail_url.length > 0 &&
                (thumbnail_url.has_prefix("http://") || thumbnail_url.has_prefix("https://"));
            string _norm = window.normalize_article_url(url);

            if (!slide_will_load) {
                if (category_id == "local_news") {
                    window.set_local_placeholder_image(slide_image, default_w, default_h);
                } else {
                    set_smart_placeholder(slide_image, default_w, default_h, source_name, url);
                }
            } else {
                int multiplier = IMAGE_QUALITY_MULTIPLIER_HIGH;
                if (window.loading_state != null) window.loading_state.track_pending_image(slide_image);
                if (window.image_manager != null) window.image_manager.pending_local_placeholder.set(slide_image, category_id == "local_news");
                window.image_manager.load_image_async(slide_image, thumbnail_url, default_w * multiplier, default_h * multiplier, true);
                window.image_manager.hero_requests.set(slide_image, new HeroRequest(thumbnail_url, default_w * multiplier, default_h * multiplier, multiplier));
                if (window.article_state_store != null) {
                    bool was = window.article_state_store.is_viewed(_norm);
                    if (was) window.mark_article_viewed(_norm);
                }
            }

            slide_image.set_data<bool>("has-real-thumbnail", slide_will_load);
            // Same -1-width sizing issue as the hero card above - pass the
            // intended size explicitly rather than relying on get_size_request().
            if (!slide_will_load) ThumbnailBackfillService.enqueue(window, url, slide_image, default_w, default_h);
            if (window.view_state != null) {
                window.view_state.register_picture_for_url(_norm, slide_image);
                window.view_state.normalized_to_url.set(_norm, url);
                window.view_state.register_card_for_url(_norm, slide);
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
            string card_display_cat = resolve_display_category(category_id, source_name);
            if (is_trending) {
                if (trending_grid_count >= TRENDING_GRID_MAX) return;
                trending_grid_count++;
            }
            place_regular_article_card(decoded_title, url, thumbnail_url, category_id, source_name, bypass_limit, published, card_display_cat, false, is_trending);
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
        if (placed && window.article_state_store != null) {
            window.article_state_store.add_myfeed_displayed_url(window.normalize_article_url(url));
        }
    }

    // Reset once per My Feed fetch (see LayoutManager.prepare_myfeed_sections)
    // so the badge count reflects only the current build's cards.
    public void reset_myfeed_displayed_urls() {
        if (window.article_state_store != null) window.article_state_store.reset_myfeed_displayed_urls();
    }

    // Persisted in ArticleStateStore so the badge count survives restarts.
    public Gee.HashSet<string> get_myfeed_displayed_urls() {
        if (window.article_state_store == null) return new Gee.HashSet<string>();
        return window.article_state_store.get_myfeed_displayed_urls();
    }

    // Claims one of MYFEED_ROW_CARD_CAP real-card slots for this row key,
    // returning false once that row is full so the caller skips building
    // a widget for it. Each row is independent - a full "Guardian" row
    // doesn't affect the "Technology" row's own budget.
    private bool try_take_myfeed_row_slot(string row_key) {
        if (row_card_counts == null) row_card_counts = new Gee.HashMap<string, int>();
        int count = row_card_counts.has_key(row_key) ? row_card_counts.get(row_key) : 0;
        if (count >= MYFEED_ROW_CARD_CAP) return false;
        row_card_counts.set(row_key, count + 1);
        return true;
    }

    // Front Page row key for an article, e.g. "football" -> "sports".
    private string frontpage_row_key(string category_id, string? source_name) {
        return LayoutManager.frontpage_row_for(resolve_display_category(category_id, source_name));
    }

    // True once the hero and carousel are filled, so further Front Page articles become row cards.
    private bool frontpage_featured_full() {
        return featured_used && (hero_carousel == null || featured_carousel_items == null || featured_carousel_items.size >= MAX_CAROUSEL_SLIDES);
    }

    private bool frontpage_row_full(string row_key) {
        int count = (row_card_counts != null && row_card_counts.has_key(row_key)) ? row_card_counts.get(row_key) : 0;
        return count >= window.layout_manager.frontpage_row_initial_cards();
    }

    private void count_frontpage_row_card(string row_key) {
        if (row_card_counts == null) row_card_counts = new Gee.HashMap<string, int>();
        row_card_counts.set(row_key, (row_card_counts.has_key(row_key) ? row_card_counts.get(row_key) : 0) + 1);
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
        bool no_fallback_section,
        bool is_trending = false,
        int forced_col_w = 0
    ) {
        // History gets its own compact row card, not the full image-grid
        // card every other view uses - see HistoryCard.
        if (category_id == "history") {
            place_history_card(decoded_title, url, thumbnail_url, source_name, published);
            return;
        }

        // Use the column width cached for this layout pass rather than
        // recomputing per-card, so every card gets identical dimensions even
        // if the reported content width drifts while articles stream in.
        // Trending computes its own 4-column width directly instead, since
        // it shares LayoutManager with Front Page's own concurrently
        // streaming (3-column-cached) category sections.
        int col_w = 400;
        if (forced_col_w > 0) {
            col_w = forced_col_w;
        } else if (window.layout_manager != null) {
            col_w = is_trending
                ? window.layout_manager.estimate_column_width(4)
                : (window.layout_manager.cached_col_w > 0
                    ? window.layout_manager.cached_col_w
                    : window.layout_manager.estimate_column_width(window.layout_manager.columns_count));
        }
        int img_w = col_w;
        // Fixed height, not derived from col_w, so every card's picture area
        // matches even if col_w is read at slightly different times.
        int img_h = CARD_IMAGE_HEIGHT;

        string card_display_cat = resolve_display_category(category_id, source_name);

        string category_label_text = window.category_chip_text(card_display_cat);

        if (window.layout_manager == null) {
            warning("ArticleManager: layout_manager not initialized, cannot place card");
            return;
        }

        var article_card = window.layout_manager.create_and_place_article_card(
            decoded_title,
            url,
            col_w,
            img_h,
            category_label_text,
            section_key,
            published,
            no_fallback_section,
            is_trending
        );

        var card_badge = window.build_source_badge_dynamic(source_name, url, category_id);
        CardBuilder.attach_source_badge(window, article_card.root, article_card.overlay, card_badge, url, source_name, window.prefs.category == "frontpage");
        CardBuilder.attach_feedback_buttons(window, article_card.root, article_card.overlay, url, decoded_title, source_name, category_id);

        bool card_will_load = thumbnail_url != null && thumbnail_url.length > 0 &&
            (thumbnail_url.has_prefix("http://") || thumbnail_url.has_prefix("https://"));

        string _norm = window.normalize_article_url(url);

        bool has_real_thumbnail = card_will_load;
            if (card_will_load) {
            if (category_id == "local_news" && !bypass_limit) {
                if (articles_shown >= LOCAL_NEWS_IMAGE_LOAD_LIMIT) {
                        window.set_local_placeholder_image(article_card.image, img_w, img_h);
                        card_will_load = false;
                    }

            }
            bool single_source = (window.prefs.preferred_sources != null && window.prefs.preferred_sources.size == 1);
            int multiplier = single_source ? 3 : ((window.loading_state != null && window.loading_state.initial_phase) ? 2 : 3);
            if (window.loading_state != null) window.loading_state.track_pending_image(article_card.image);
            if (window.image_manager != null) window.image_manager.pending_local_placeholder.set(article_card.image, category_id == "local_news");
            bool force_load = true;
            window.image_manager.load_image_async(article_card.image, thumbnail_url, img_w * multiplier, img_h * multiplier, force_load);
        } else {
            if (category_id == "local_news") {
                window.set_local_placeholder_image(article_card.image, img_w, img_h);
            } else {
                set_smart_placeholder(article_card.image, img_w, img_h, source_name, url);
            }
        }

        // Tracks whether this card is showing a real thumbnail vs. a
        // placeholder, so a backfilled hero image never overwrites a
        // thumbnail that's already real.
        article_card.image.set_data<bool>("has-real-thumbnail", has_real_thumbnail);
        if (!has_real_thumbnail) ThumbnailBackfillService.enqueue(window, url, article_card.image);
        if (window.view_state != null) window.view_state.register_picture_for_url(_norm, article_card.image);
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
        // Unowned in the callbacks - see the matching comment in the hero path above.
        unowned Gtk.Widget root_ref = card_root;
        unowned Gtk.Widget ribbon_ref = card_save_ribbon;
        ArticleCard.wire_interactions(
            card_root,
            url,
            window.article_state_store,
            window,
            source_name,
            (s) => {
                if (window.prefs != null && window.prefs.article_click_opens_reader) {
                    open_article_in_app_if_online(s, true, source_name, decoded_title, thumbnail_url, published, category_id);
                } else if (window.article_pane != null) {
                    window.article_pane.show_article_preview(decoded_title, url, thumbnail_url, category_id, source_name);
                }
            },
            (article_url) => { open_article_in_app_if_online(article_url, null, source_name, decoded_title, thumbnail_url, published, category_id); },
            (article_url) => { open_article_in_browser_if_online(article_url, source_name, decoded_title, thumbnail_url, published, category_id); },
            (article_url, src_name) => {
                request_show_toast(_("Searching for feed..."), true);
                window.source_manager.follow_rss_source(article_url, src_name);
            },
            (article_url) => {
                if (window.article_state_store != null) {
                    bool is_saved = window.article_state_store.is_saved(article_url);
                    if (is_saved) {
                        window.article_state_store.unsave_article(article_url);
                        request_show_toast(_("Removed article from saved"));
                        if (window.animation_manager != null) {
                            window.animation_manager.animate_save_toggle(root_ref, ribbon_ref, decoded_title, false);
                        }

                        if (window.prefs.category == "saved") {
                            if (window.animation_manager != null) {
                                        var w = root_ref;
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
                        request_show_toast(_("Added article to saved"));
                        if (window.animation_manager != null) {
                            window.animation_manager.animate_save_toggle(root_ref, ribbon_ref, decoded_title, true);
                        }
                    }
                }
            },
            (article_url) => { window.show_share_dialog(article_url); },
            (article_url) => { open_article_in_app_if_online(article_url, true, source_name, decoded_title, thumbnail_url, published, category_id); }
        );

        if (window.loading_state != null && window.loading_state.initial_phase) window.mark_initial_items_populated();
    }

    // Builds and places a compact HistoryCard row - same click/context-menu
    // wiring as a regular card, just without the hero/section/column-width
    // machinery place_regular_article_card needs for the traditional grid.
    private void place_history_card(string decoded_title, string url, string? thumbnail_url, string? source_name, string? published) {
        if (window.layout_manager == null) {
            warning("ArticleManager: layout_manager not initialized, cannot place card");
            return;
        }

        string _norm = window.normalize_article_url(url);

        // The card needs two things History alone knows that a regular
        // article doesn't carry: when the user actually read this (not
        // when it was published) and which real category it belongs to
        // (shown as plain text above the title) - both come from the
        // stored HistoryArticle rather than being threaded through
        // AddItemFunc's fixed signature.
        var history_entry = window.article_state_store != null ? window.article_state_store.get_history_article(_norm) : null;
        int64 viewed_timestamp = history_entry != null ? history_entry.viewed_timestamp : (GLib.get_real_time() / 1000000);
        string? original_category = history_entry != null ? history_entry.category_id : null;
        string? category_display_name = (original_category != null && original_category.length > 0)
            ? window.category_chip_text(original_category)
            : null;

        var history_card = window.layout_manager.create_and_place_history_card(decoded_title, url, source_name, viewed_timestamp, category_display_name);
        history_card.enable_hover_actions(window);

        wire_history_card(history_card, decoded_title, url, thumbnail_url, source_name, published, original_category);

        if (window.loading_state != null && window.loading_state.initial_phase) window.mark_initial_items_populated();
    }

    // Badge, image, tracking and click/save/menu wiring shared by every hero placement.
    private void wire_hero_card(HeroCard hero_card, string decoded_title, string url, string? thumbnail_url, string category_id, string? source_name, string? published, bool enable_hero_context_menu, bool with_snippet, int default_hero_w, int default_hero_h) {
        if (with_snippet) {
            ArticleSnippetService.attach_hero_snippet(hero_card, url, source_name, article_buffer);
        }

        var hero_source_badge = window.build_source_badge_dynamic(source_name, url, category_id);
        CardBuilder.attach_source_badge(window, hero_card.root, hero_card.overlay, hero_source_badge, url, source_name, window.prefs.category == "frontpage");
        CardBuilder.attach_feedback_buttons(window, hero_card.root, hero_card.overlay, url, decoded_title, source_name, category_id);

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
            if (window.loading_state != null) window.loading_state.track_pending_image(hero_card.image);
            if (window.image_manager != null) window.image_manager.pending_local_placeholder.set(hero_card.image, category_id == "local_news");
            window.image_manager.load_image_async(hero_card.image, thumbnail_url, default_hero_w * multiplier, default_hero_h * multiplier, true);
            window.image_manager.hero_requests.set(hero_card.image, new HeroRequest(thumbnail_url, default_hero_w * multiplier, default_hero_h * multiplier, multiplier));
            if (window.article_state_store != null) {
                bool was = window.article_state_store.is_viewed(_norm);
                window.append_debug_log("meta_check: hero url=" + _norm + " was=" + (was ? "true" : "false"));
                if (was) window.mark_article_viewed(_norm);
            }
            schedule_hero_refetch(window, hero_card.image);
        }

        hero_card.image.set_data<bool>("has-real-thumbnail", hero_will_load);
        // hero_card.image is sized (-1, height) - its width is
        // "natural", so get_size_request() alone can't be trusted as
        // a fallback size (see the article-pane fix earlier this
        // session); pass the intended width explicitly.
        if (!hero_will_load) ThumbnailBackfillService.enqueue(window, url, hero_card.image, default_hero_w, default_hero_h);
        if (window.view_state != null) {
            window.view_state.register_picture_for_url(_norm, hero_card.image);
            window.view_state.normalized_to_url.set(_norm, url);
            window.view_state.register_card_for_url(_norm, hero_card.root);
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
        // Unowned in the callbacks: they live on the hero's own widgets, and a strong
        // capture of its root is a reference cycle that kept every hero alive.
        unowned Gtk.Widget hero_root_ref = hero_root;
        unowned Gtk.Widget hero_ribbon_ref = hero_save_ribbon;
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
            (article_url) => { open_article_in_app_if_online(article_url, null, source_name, decoded_title, thumbnail_url, published, category_id); },
            (article_url) => { open_article_in_browser_if_online(article_url, source_name, decoded_title, thumbnail_url, published, category_id); },
            (article_url, src_name) => {
                request_show_toast(_("Searching for feed..."), true);
                window.source_manager.follow_rss_source(article_url, src_name);
            },
            (article_url) => {
                if (window.article_state_store != null) {
                    bool is_saved = window.article_state_store.is_saved(article_url);
                    if (is_saved) {
                        window.article_state_store.unsave_article(article_url);
                        request_show_toast(_("Removed article from saved"));
                        if (window.animation_manager != null) {
                            window.animation_manager.animate_save_toggle(hero_root_ref, hero_ribbon_ref, decoded_title, false);
                        }

                        if (window.prefs.category == "saved") {
                            if (window.animation_manager != null) {
                                var w = hero_root_ref;
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
                        request_show_toast(_("Added article to saved"));
                        if (window.animation_manager != null) {
                            window.animation_manager.animate_save_toggle(hero_root_ref, hero_ribbon_ref, decoded_title, true);
                        }
                    }
                }
            },
            (article_url) => { window.show_share_dialog(article_url); },
            (article_url) => { open_article_in_app_if_online(article_url, true, source_name, decoded_title, thumbnail_url, published, category_id); }
        );
    }

    // Badge, image, tracking and click wiring for a compact row card.
    private void wire_history_card(HistoryCard history_card, string decoded_title, string url, string? thumbnail_url, string? source_name, string? published, string? original_category) {
        string _norm = window.normalize_article_url(url);
        var card_badge = window.build_source_badge_dynamic(source_name, url, "history");
        // build_source_badge_dynamic() styles it to sit as an overlay
        // (margin_bottom/margin_end 8, valign/halign END) so it hugs a
        // card image's corner - badge_slot is a normal flow layout instead,
        // where those same margins/aligns just add stray offset.
        card_badge.set_margin_bottom(0);
        card_badge.set_margin_end(0);
        card_badge.set_valign(Gtk.Align.CENTER);
        card_badge.set_halign(Gtk.Align.CENTER);
        history_card.badge_slot.append(card_badge);
        if (window.prefs.category == "frontpage") {
            CardBuilder.make_badge_followable(window, history_card.root, card_badge, url, source_name);
        }
        CardBuilder.attach_feedback_buttons(window, history_card.root, history_card.overlay, url, decoded_title, source_name, original_category);

        int img_w = history_card.image_width;
        bool card_will_load = thumbnail_url != null && thumbnail_url.length > 0 &&
            (thumbnail_url.has_prefix("http://") || thumbnail_url.has_prefix("https://"));

        if (card_will_load) {
            if (window.loading_state != null) window.loading_state.track_pending_image(history_card.image);
            if (window.image_manager != null) window.image_manager.load_image_async(history_card.image, thumbnail_url, img_w * 2, img_w * 2, true);
        } else {
            set_smart_placeholder(history_card.image, img_w, img_w, source_name, url);
        }

        history_card.image.set_data<bool>("has-real-thumbnail", card_will_load);
        if (!card_will_load) ThumbnailBackfillService.enqueue(window, url, history_card.image);
        if (window.view_state != null) {
            window.view_state.register_picture_for_url(_norm, history_card.image);
            window.view_state.normalized_to_url.set(_norm, url);
            window.view_state.register_card_for_url(_norm, history_card.root);
        }

        history_card.source_name = source_name;
        history_card.category_id = original_category;
        history_card.thumbnail_url = thumbnail_url;

        var card_root = history_card.root;
        ArticleCard.wire_interactions(
            card_root,
            url,
            window.article_state_store,
            window,
            source_name,
            (s) => {
                if (window.prefs != null && window.prefs.article_click_opens_reader) {
                    open_article_in_app_if_online(s, true, source_name, decoded_title, thumbnail_url, published, original_category);
                } else if (window.article_pane != null) {
                    window.article_pane.show_article_preview(decoded_title, url, thumbnail_url, original_category, source_name);
                }
            },
            (article_url) => { open_article_in_app_if_online(article_url, null, source_name, decoded_title, thumbnail_url, published, original_category); },
            (article_url) => { open_article_in_browser_if_online(article_url, source_name, decoded_title, thumbnail_url, published, original_category); },
            (article_url, src_name) => {
                request_show_toast(_("Searching for feed..."), true);
                window.source_manager.follow_rss_source(article_url, src_name);
            },
            (article_url) => {
                if (window.article_state_store != null) {
                    bool is_saved = window.article_state_store.is_saved(article_url);
                    if (is_saved) {
                        window.article_state_store.unsave_article(article_url);
                        request_show_toast(_("Removed article from saved"));
                    } else {
                        window.article_state_store.save_article(article_url, decoded_title, thumbnail_url, source_name, published);
                        request_show_toast(_("Added article to saved"));
                    }
                }
            },
            (article_url) => { window.show_share_dialog(article_url); },
            (article_url) => { open_article_in_app_if_online(article_url, true, source_name, decoded_title, thumbnail_url, published, original_category); }
        );
    }

        public void load_more_articles() {
            if (remaining_articles == null || remaining_articles.size == 0) {
                if (load_more_button_visible) {
                    request_hide_load_more_button();
                    load_more_button_visible = false;
                    
                    ViewSession.view_timeout(300, () => {
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

            // Hold this batch's entrance animation until any backfill
            // extractions triggered by placing it have resolved (or a
            // bounded grace period passes) - see BackfillBatchGate.
            var backfill_gate = new BackfillBatchGate();
            ThumbnailBackfillService.current_batch = backfill_gate;
            var session = ViewSession.current();

            for (int i = 0; i < articles_to_load; i++) {
                // Remove from the front rather than indexing in place: this
                // queue is a shared pool that load_more_for_category() also
                // pulls from out of order.
                var article = remaining_articles.remove_at(0);
                string display_cat = overflow_key_for(article);
                remaining_category_counts.set(display_cat, remaining_category_counts.get(display_cat) - 1);
                // No need to check seen_urls - articles were already deduplicated
                // when they were added to remaining_articles queue
                article_buffer.add(article);
                add_item_immediate_to_column(article.title, article.url, article.thumbnail_url, article.category_id, null, article.source_name, true, article.published);
            }

            ThumbnailBackfillService.current_batch = null;

            // Hide the newly placed cards immediately (rather than letting
            // them sit at full opacity until animate_cards_entrance_batch
            // gets around to them) so the hold above actually keeps
            // placeholders off-screen instead of just delaying their fade-in.
            if (window != null && window.animation_manager != null && window.layout_manager != null) {
                var lm0 = window.layout_manager;
                if (lm0.featured_box != null) {
                    int idx = 0;
                    var c = lm0.featured_box.get_first_child();
                    while (c != null) {
                        if (idx >= featured_count) c.set_visible(false);
                        idx++;
                        c = c.get_next_sibling();
                    }
                }
                if (lm0.columns_row != null) {
                    int idx = 0;
                    var c = lm0.columns_row.get_first_child();
                    while (c != null) {
                        if (idx >= prev_card_count) c.set_visible(false);
                        idx++;
                        c = c.get_next_sibling();
                    }
                }
            }

            // Animate any newly appended cards after they have been inserted
            if (window != null && window.animation_manager != null && window.layout_manager != null) {
                var lm2 = window.layout_manager;
                backfill_gate.ready.connect(() => {
                    // Delay until idle so widgets are realized/parented
                    session.idle(() => {
                        var cards = new Gee.ArrayList<Gtk.Widget>();

                        // Featured box new children
                        if (lm2.featured_box != null) {
                            int idx = 0;
                            var child = lm2.featured_box.get_first_child();
                            while (child != null) {
                                if (idx >= featured_count) cards.add(child);
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
                                if (idx >= prev_card_count) cards.add(child);
                                idx++;
                                child = child.get_next_sibling();
                            }
                        }

                        window.animation_manager.animate_cards_entrance_batch(cards);
                        return false;
                    });
                });
            }

            // Resolve the button's loading state (spinner -> normal, or
            // hidden once the feed is exhausted) once the new cards are
            // actually about to be revealed, instead of on a fixed timer.
            backfill_gate.ready.connect(() => {
                if (!load_more_button_visible) return;
                if (remaining_articles.size > 0) {
                    request_reset_load_more_button();
                } else {
                    request_hide_load_more_button();
                    load_more_button_visible = false;
                    if (window.loading_state.loading_container == null || !window.loading_state.loading_container.get_visible()) {
                        show_end_of_feed_message();
                    }
                }
            });
            backfill_gate.begin();
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
            // The button belongs to this view: removed at once (no fade) when it ends.
            ViewSession.current().on_close("load-more-button", () => {
                if (window.content_view != null) window.content_view.remove_load_more_button_now();
                load_more_button_visible = false;
            });
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
            if (row_card_counts != null) row_card_counts.clear();

            if (seen_urls != null) {
                seen_urls.clear();
            }
            if (trending_seen_urls != null) {
                trending_seen_urls.clear();
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

            trending_hero_count = 0;
            trending_grid_count = 0;

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
        // Static so the closure captures only the picture: capturing the HeroCard wrapper
        // (which holds its root widget) from add_item_immediate_to_column kept every hero alive.
        private static void schedule_hero_refetch(NewsWindow window, Gtk.Picture image) {
            ViewSession.view_timeout(300, () => {
                var info = window.image_manager.hero_requests.get(image);
                if (info != null) window.maybe_refetch_hero_for(image, info);
                return false;
            });
        }

        public void reset_for_new_fetch() {
            clear_articles();

            if (hero_carousel != null) {
                hero_carousel.stop_timer();
                hero_carousel = null;
            }
            // Clear the whole box - HeroCarousel's "FEATURED" label is a sibling of its container.
            if (window.layout_manager != null) window.layout_manager.clear_featured_box();

            if (featured_carousel_items != null) {
                featured_carousel_items.clear();
            }
            featured_carousel_category = null;
            featured_used = false;
            trending_hero_count = 0;
            trending_grid_count = 0;
            // The latch's idle may have been dropped with the previous view's session.
            reveal_pending = false;
            recommended_picks.clear();
            recommendations_finalized = false;
            panel_picks = new Gee.ArrayList<RecommendedPick>();
            panel_reserve = new Gee.ArrayList<RecommendedPick>();
            ViewSession.remove_source(ref recommendations_settle_id);

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

        // A built-in outlet's URL under a name that isn't that outlet's means
        // a custom RSS feed hosted on its site - brand it as the feed.
        if (resolved != NewsSource.UNKNOWN && source_name != null && source_name.length > 0
            && BuiltinSources.from_name(source_name) != resolved) {
            window.set_rss_placeholder_image(image, w, h, source_name);
            return;
        }

        window.set_placeholder_image_for_source(image, w, h, resolved);
    }

    public void clear_article_buffer() {
        article_buffer.clear();
    }

    public void reset_featured_state() {
        featured_used = false;
        trending_hero_count = 0;
        trending_grid_count = 0;
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
        string? category_label_text = (hero_category_id != null && hero_category_id.length > 0)
            ? window.category_chip_text(hero_category_id)
            : null;

        var article_card = new ArticleCard(
            hero_title,
            hero_url,
            col_w,
            img_h,
            category_label_text,
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

        var card_badge = window.build_source_badge_dynamic(hero_source_name, hero_url, hero_category_id);
        CardBuilder.attach_source_badge(window, article_card.root, article_card.overlay, card_badge, hero_url, hero_source_name, true);

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

        bool has_real_thumbnail = thumbnail_url != null && thumbnail_url.length > 0 &&
            (thumbnail_url.has_prefix("http://") || thumbnail_url.has_prefix("https://"));
        article_card.image.set_data<bool>("has-real-thumbnail", has_real_thumbnail);
        if (!has_real_thumbnail) ThumbnailBackfillService.enqueue(window, url, article_card.image);

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
                if (window.prefs != null && window.prefs.article_click_opens_reader) {
                    open_article_in_app_if_online(s, true, source_name, title, thumbnail_url, null, category_id);
                } else if (window.article_pane != null) {
                    window.article_pane.show_article_preview(title, url, thumbnail_url, category_id, source_name);
                }
            },
            (article_url) => { open_article_in_app_if_online(article_url, null, source_name, title, thumbnail_url, null, category_id); },
            (article_url) => { open_article_in_browser_if_online(article_url, source_name, title, thumbnail_url, null, category_id); },
            (article_url, src_name) => {
                request_show_toast(_("Searching for feed..."), true);
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
                        request_show_toast(_("Removed article from saved"));
                    } else {
                        window.article_state_store.save_article(article_url, title, thumbnail_url, source_name);
                        request_show_toast(_("Added article to saved"));
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
            },
            (article_url) => { open_article_in_app_if_online(article_url, true, source_name, title, thumbnail_url, null, category_id); }
        );
    }
}
}
