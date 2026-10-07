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
    // Turns incoming articles into cards: decides hero / carousel / row card,
    // enforces per-view caps (overflow goes to "load more"), dedupes, and
    // builds the Front Page's "Recommended for you" panel.
    public class ArticleManager : GLib.Object {
        private unowned NewsWindow window;

        public const int INITIAL_ARTICLE_LIMIT = 25;
        public const int LOAD_MORE_BATCH_SIZE = 10;
        public const int MAX_CAROUSEL_SLIDES = 5;

        // A hero's picture spans the card's full height, so default and max match.
        public const int HERO_MAX_HEIGHT = 460;
        public const int HERO_DEFAULT_HEIGHT = 460;
        public const int TRENDING_HERO_MAX_HEIGHT = 480;
        public const int TRENDING_HERO_DEFAULT_HEIGHT = 480;
        public const int TRENDING_GRID_MAX = 8;    // two rows of four under Trending's two heroes
        public const int CARD_IMAGE_HEIGHT = 220;  // fixed, never derived from column width

        // Image request size as a multiple of display size.
        public const int IMAGE_QUALITY_MULTIPLIER_HIGH = 6;    // heroes and carousel slides
        public const int IMAGE_QUALITY_MULTIPLIER_MEDIUM = 3;  // cards
        public const int IMAGE_QUALITY_MULTIPLIER_LOW = 2;     // cards during the initial load, history rows

        private const int MYFEED_ROW_CARD_CAP = 10;

        // Articles shown this view, kept as a fallback for ArticleSnippetService
        // when its live fetch of an article page fails.
        public Gee.ArrayList<ArticleItem> article_buffer;
        // Overflow queue for "load more", and per-key counts of it (kept in sync).
        public Gee.ArrayList<ArticleItem> remaining_articles;
        private Gee.HashMap<string, int> remaining_category_counts;
        public int articles_shown = 0;

        // Real-card counts per My Feed / Front Page row, so each row has its own cap.
        private Gee.HashMap<string, int>? row_card_counts = null;

        // Dedup sets for this view. Trending has its own: it's a second fetch on the
        // Front Page and its stories often share URLs with the main stream.
        private Gee.HashSet<string> seen_urls;
        private Gee.HashSet<string> trending_seen_urls;

        private int trending_hero_count = 0;
        private int trending_grid_count = 0;
        public Gee.ArrayList<ArticleItem>? featured_carousel_items;
        public HeroCarousel? hero_carousel;
        private string? featured_carousel_category = null;
        public bool featured_used = false;

        private bool load_more_button_visible = false;
        // Batches overflow reveals into one pass per idle.
        private bool reveal_pending = false;

        // "Recommended for you": candidates are held until arrivals settle,
        // then ranked into the panel.
        private const int RECOMMENDED_MAX_PICKS = 8;
        private const int RECOMMENDED_MAX_PER_CATEGORY = 2;
        private const int RECOMMENDED_FILL_PER_CATEGORY = 4;   // looser cap, only to top up a short panel
        private const uint RECOMMENDED_SETTLE_MS = 500;
        // A full panel plus as many dislike replacements. Bounded so the rest of the
        // Front Page still gets its normal rows.
        private const int RECOMMENDED_SHORTLIST = RECOMMENDED_MAX_PICKS * 2;

        private class RecommendedPick {
            public ArticleItem item;
            public double score;
            // Source name before normalization, for row caps if it's evicted.
            public string? raw_source_name;
            public RecommendedPick(ArticleItem item, double score, string? raw_source_name) {
                this.item = item;
                this.score = score;
                this.raw_source_name = raw_source_name;
            }
        }
        private Gee.ArrayList<RecommendedPick> recommended_picks = new Gee.ArrayList<RecommendedPick>();
        private bool recommendations_finalized = false;
        private uint recommendations_settle_id = 0;
        // What the panel shows (in slot order), and the next-best picks for dislikes.
        private Gee.ArrayList<RecommendedPick> panel_picks = new Gee.ArrayList<RecommendedPick>();
        private Gee.ArrayList<RecommendedPick> panel_reserve = new Gee.ArrayList<RecommendedPick>();
        private int panel_rail_rows = 0;
        private bool feedback_connected = false;

        // The article behind a card, as its click/menu callbacks need it.
        // Holds only strings, so callbacks can capture it without a reference cycle.
        private class CardArticle {
            public string title;
            public string url;
            public string? thumbnail_url;
            public string? source_name;
            public string? category_id;
            public string? published;
            public CardArticle(string title, string url, string? thumbnail_url, string? source_name, string? category_id, string? published) {
                this.title = title;
                this.url = url;
                this.thumbnail_url = thumbnail_url;
                this.source_name = source_name;
                this.category_id = category_id;
                this.published = published;
            }
        }

        private delegate void PlaceBatchFunc();

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
            seen_urls = new Gee.HashSet<string>();
            trending_seen_urls = new Gee.HashSet<string>();
        }

        // ---- Small helpers ----

        private static bool has_text(string? s) {
            return s != null && s.length > 0;
        }

        private static bool has_http_url(string? url) {
            return url != null && (url.has_prefix("http://") || url.has_prefix("https://"));
        }

        private static int child_count(Gtk.Widget parent) {
            int n = 0;
            for (var c = parent.get_first_child(); c != null; c = c.get_next_sibling()) n++;
            return n;
        }

        // Children of `parent` from index `start` on.
        private static Gee.ArrayList<Gtk.Widget> children_from(Gtk.Widget parent, int start) {
            var result = new Gee.ArrayList<Gtk.Widget>();
            int i = 0;
            for (var c = parent.get_first_child(); c != null; c = c.get_next_sibling()) {
                if (i++ >= start) result.add(c);
            }
            return result;
        }

        private bool debug_enabled() {
            return has_text(Environment.get_variable("PAPERBOY_DEBUG"));
        }

        // On the Front Page category_id is always "frontpage"; the real category
        // travels in source_name's SourceLabel.
        private string resolve_display_category(string category_id, string? source_name) {
            if (category_id != "frontpage") return category_id;
            // Bound to a local first: Vala frees a temporary struct's fields
            // before a ?? on them is used.
            var label = SourceLabel.parse(source_name);
            return label.category ?? category_id;
        }

        private string extract_display_category(ArticleItem item) {
            return resolve_display_category(item.category_id, item.source_name);
        }

        // Column width cached for this layout pass, so every card matches even if
        // the content width drifts while articles stream in.
        private int cached_column_width() {
            var lm = window.layout_manager;
            return lm.cached_col_w > 0 ? lm.cached_col_w : lm.estimate_column_width(lm.columns_count);
        }

        // ---- Opening articles ----

        public void open_article_in_app_if_online(string article_url, bool? force_reader_view = null, string? source_name_encoded = null, string? title = null, string? thumbnail_url = null, string? published = null, string? category_id = null) {
            if (!record_open(article_url, source_name_encoded, title, thumbnail_url, published, category_id)) return;
            if (window.article_sheet != null) window.article_sheet.open(article_url, force_reader_view, source_name_encoded);
        }

        public void open_article_in_browser_if_online(string article_url, string? source_name = null, string? title = null, string? thumbnail_url = null, string? published = null, string? category_id = null) {
            if (!record_open(article_url, source_name, title, thumbnail_url, published, category_id)) return;
            if (window.article_pane != null) window.article_pane.open_article_in_browser(article_url);
        }

        // Marks the article viewed and adds it to History. False (with a toast)
        // when offline. Callers open the real URL, not the normalized one, since
        // normalizing strips query strings some sites need (ABC's story?id=).
        private bool record_open(string article_url, string? source_name, string? title, string? thumbnail_url, string? published, string? category_id) {
            if (!GLib.NetworkMonitor.get_default().get_network_available()) {
                request_show_toast(_("You're offline. Enable internet connection to view articles"));
                return false;
            }
            window.mark_article_viewed(window.normalize_article_url(article_url));
            if (window.article_state_store != null) {
                window.article_state_store.record_history(article_url, title, thumbnail_url, source_name, published, category_id);
            }
            return true;
        }

        // ---- Adding articles ----

        // Gate for every card, keyed on the on-screen category so it also covers
        // the gap before a new fetch starts.
        private bool view_allows_item(string category_id) {
            string? cat = window.prefs != null ? window.prefs.category : null;
            bool local_only = cat == "saved" || cat == "history";
            return !local_only || category_id == cat;
        }

        // True if the URL was already seen in its stream (Trending or the rest);
        // otherwise marks it seen. Two locks because Vala's lock needs a member.
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

        // My Feed's row for an article ("source:<id>" or "customfeed:<url>").
        // Must run before source_name is normalized into a display name.
        private string? resolve_myfeed_row_key_hint(string category_id, string? source_name) {
            if (category_id == "myfeed") return has_text(source_name) ? "customfeed:" + source_name : null;
            if (!has_text(source_name) || window.source_manager == null) return null;
            NewsSource named = BuiltinSources.from_name(source_name);
            if (named != NewsSource.UNKNOWN && window.source_manager.get_enabled_source_enums().contains(named)) {
                return "source:" + BuiltinSources.for_source(named).id;
            }
            return null;
        }

        // Entry point for fetched articles: caps, dedupe and filters, then a card
        // (or a held "Recommended for you" candidate).
        public void add_item(string title, string url, string? thumbnail_url, string category_id, string? source_name, string? published = null, string? snippet = null, bool is_trending = false) {
            if (!view_allows_item(category_id)) return;
            if (is_trending && (trending_full() || in_hero_carousel(url))) return;
            bool is_myfeed = window.category_manager.is_myfeed_view();

            // Recommended candidates have their own budget, outside the Front Page caps.
            double recommended_score = is_trending ? -1 : score_recommendation(title, url, category_id, source_name);
            bool recommended = recommended_score > 0;
            if (recommended) {
                recommended_score = rank_recommendation(recommended_score, title, published);
                recommended = shortlist_accepts(recommended_score);
            }

            // Past the cap, articles queue for "load more". Exempt: Trending (capped
            // on its own) and My Feed (each row has its own cap, and some rows have
            // no "load more").
            if (!is_trending && !recommended) {
                bool over_cap;
                if (window.prefs.category == "frontpage") {
                    over_cap = frontpage_featured_full() && frontpage_row_full(frontpage_row_key(category_id, source_name));
                } else {
                    over_cap = !is_myfeed && CategoryManager.is_limited_category(window.prefs.category) && articles_shown >= INITIAL_ARTICLE_LIMIT;
                }
                if (over_cap) {
                    queue_overflow(title, url, thumbnail_url, category_id, source_name, published, snippet, false);
                    return;
                }
            }

            string? myfeed_row_key_hint = is_myfeed ? resolve_myfeed_row_key_hint(category_id, source_name) : null;
            string? final_source_name = SourceManager.normalize_source_name(source_name, category_id, url);
            string normalized = window.normalize_article_url(url);

            // Racing fetches can send the same URL twice: no second card, but the
            // existing one may gain a published date or reading time.
            if (normalized.length > 0 && already_seen_and_mark(normalized, is_trending)) {
                refresh_existing_card_times(normalized, published);
                return;
            }

            // A picture already exists for this URL: load the thumbnail into it
            // instead of building another card. Not for Trending, where distinct
            // headlines can normalize to the same URL.
            if (!is_trending && has_text(thumbnail_url)) {
                var existing = find_existing_picture(normalized);
                if (existing != null) {
                    reload_existing_picture(existing, thumbnail_url, category_id);
                    return;
                }
            }

            // Saved and History show whatever the user kept, from any source.
            bool is_saved_view = window.prefs.category == "saved" || window.prefs.category == "history";
            if (!is_saved_view) {
                if (!window.category_manager.should_display_article(category_id)) {
                    if (debug_enabled()) {
                        warning("Article filtered by category: view=%s article_cat=%s title=%s",
                                window.category_manager.get_current_category(), category_id, title);
                    }
                    return;
                }
                // Built-in outlets the user turned off are hidden, except in RSS
                // feeds the user follows directly.
                bool from_followed_feed = window.category_manager.is_rssfeed_view() || category_id == "myfeed";
                if (!from_followed_feed && window.source_manager != null && window.source_manager.is_from_disabled_source(url)) {
                    return;
                }
            }

            if (recommended) {
                var held = new ArticleItem(title, url, thumbnail_url, category_id, final_source_name, published);
                held.snippet = snippet;
                hold_recommended_pick(new RecommendedPick(held, recommended_score, source_name));
                return;
            }

            add_item_immediate_to_column(title, url, thumbnail_url, category_id, null, final_source_name, false, published, snippet, myfeed_row_key_hint, is_trending);
        }

        private void refresh_existing_card_times(string normalized, string? published) {
            if (window.view_state == null) return;
            var cards = window.view_state.get_cards_for_url(normalized);
            if (cards == null) return;
            foreach (var card in cards) {
                string? time_base = card.get_data<string>("article-time-base");
                if (time_base == "" && has_text(published)) {
                    card.set_data("article-time-base", DateUtils.time_ago(published));
                }
                CardBuilder.refresh_card_time(card);
            }
        }

        // Exact match first, then a suffix match either way.
        private Gtk.Picture? find_existing_picture(string normalized) {
            if (window.view_state == null) return null;
            var existing = window.view_state.url_to_picture.get(normalized);
            if (existing != null || normalized.length == 0) return existing;
            foreach (var kv in window.view_state.url_to_picture.entries) {
                string k = kv.key;
                if (k != null && k.length > 0 && (k.has_suffix(normalized) || normalized.has_suffix(k))) return kv.value;
            }
            return null;
        }

        // Reloads at the size the picture was last requested at (heroes), else at column width.
        private void reload_existing_picture(Gtk.Picture existing, string thumbnail_url, string category_id) {
            var info = window.image_manager.hero_requests.get(existing);
            int target_w = 400;
            if (info != null) {
                target_w = info.last_requested_w;
            } else if (window.layout_manager != null) {
                target_w = cached_column_width();
            }
            int target_h = info != null ? info.last_requested_h : (int) (target_w * 0.5);
            load_card_image(existing, thumbnail_url, target_w, target_h, 1, category_id);
        }

        // Places one article: hero, carousel slide, or row card. bypass_limit skips
        // the caps (load-more and re-placed articles were counted already).
        public void add_item_immediate_to_column(string title, string url, string? thumbnail_url, string category_id, string? original_category = null, string? source_name = null, bool bypass_limit = false, string? published = null, string? snippet = null, string? myfeed_row_key_hint = null, bool is_trending = false) {
            if (!view_allows_item(category_id)) return;
            if (has_text(snippet) || has_text(published)) {
                var buffered_item = new ArticleItem(title, url, thumbnail_url, category_id, source_name, published);
                if (has_text(snippet)) buffered_item.snippet = snippet;
                article_buffer.add(buffered_item);
            }

            string decoded_title = stripHtmlUtils.strip_html(title);

            // Caps: Front Page rows each have their own; other limited views share
            // INITIAL_ARTICLE_LIMIT. My Feed is exempt (see add_item).
            if (window.prefs.category == "frontpage" && !is_trending) {
                if (frontpage_featured_full()) {
                    string row_key = frontpage_row_key(category_id, source_name);
                    if (!bypass_limit && frontpage_row_full(row_key)) {
                        queue_overflow(title, url, thumbnail_url, category_id, SourceManager.normalize_source_name(source_name, category_id, url), published, snippet, true);
                        return;
                    }
                    count_frontpage_row_card(row_key);
                }
            } else if (CategoryManager.is_limited_category(original_category ?? window.prefs.category) && !bypass_limit && !is_trending && window.prefs.category != "myfeed") {
                lock (articles_shown) {
                    if (articles_shown >= INITIAL_ARTICLE_LIMIT) {
                        queue_overflow(title, url, thumbnail_url, category_id, SourceManager.normalize_source_name(source_name, category_id, url), published, snippet, true);
                        return;
                    }
                    articles_shown++;
                }
            }

            if (should_be_hero(is_trending)) {
                place_hero(decoded_title, url, thumbnail_url, category_id, source_name, published, is_trending);
                return;
            }

            // While the carousel has room, articles become slides. add_item()'s category
            // filter already limits each view to articles carousel_accepts() allows.
            if (!is_trending && hero_carousel != null && featured_carousel_items != null && featured_carousel_items.size < MAX_CAROUSEL_SLIDES) {
                if (carousel_accepts(category_id)) add_carousel_slide(decoded_title, url, thumbnail_url, category_id, source_name, published);
                return;
            }

            if (window.layout_manager == null) {
                warning("ArticleManager: layout_manager not initialized, cannot place card");
                return;
            }

            if (window.category_manager.is_myfeed_view() && window.layout_manager.is_using_category_sections()) {
                place_myfeed_article_cards(decoded_title, url, thumbnail_url, category_id, source_name, bypass_limit, published, myfeed_row_key_hint);
            } else {
                if (is_trending) {
                    if (trending_grid_count >= TRENDING_GRID_MAX) return;
                    trending_grid_count++;
                }
                place_regular_article_card(decoded_title, url, thumbnail_url, category_id, source_name, bypass_limit, published, resolve_display_category(category_id, source_name), false, is_trending);
            }
        }

        // Re-places a held or queued article.
        private void place_item(ArticleItem item, bool bypass_limit) {
            add_item_immediate_to_column(item.title, item.url, item.thumbnail_url, item.category_id, null, item.source_name, bypass_limit, item.published, item.snippet);
        }

        // ---- Hero and carousel ----

        // The first article of most views is the hero; Trending has two.
        private bool should_be_hero(bool is_trending) {
            string cat = window.prefs.category;
            if (cat == "saved" || cat == "history") return false;
            if (is_trending) return trending_hero_count < 2;
            if (cat == "frontpage") return !featured_used;
            if (window.category_manager.is_rssfeed_view()) return false;
            return !featured_used;
        }

        private void place_hero(string decoded_title, string url, string? thumbnail_url, string category_id, string? source_name, string? published, bool is_trending) {
            int max_hero_height = is_trending ? TRENDING_HERO_MAX_HEIGHT : HERO_MAX_HEIGHT;
            int default_hero_w = window.estimate_content_width();
            int default_hero_h = is_trending ? TRENDING_HERO_DEFAULT_HEIGHT : HERO_DEFAULT_HEIGHT;
            string category_text = window.category_chip_text(resolve_display_category(category_id, source_name));
            // Context menu only on Trending heroes and small RSS feeds (under 15 articles).
            bool enable_menu = is_trending || (window.category_manager.is_rssfeed_view() && articles_shown < 15);

            var hero_card = window.layout_manager.create_and_place_hero_card(
                decoded_title, url, max_hero_height, default_hero_h, category_text, enable_menu, is_trending, published);
            // No snippet on Trending: its stacked layout only fits the title.
            wire_hero_card(hero_card, decoded_title, url, thumbnail_url, category_id, source_name, published, enable_menu, !is_trending, default_hero_w, default_hero_h);

            if (is_trending) {
                // Not featured_used: that belongs to the Front Page carousel, and setting
                // it here kept the carousel from being created when Trending arrived first.
                trending_hero_count++;
            } else {
                if (featured_carousel_items == null) featured_carousel_items = new Gee.ArrayList<ArticleItem>();
                if (hero_carousel == null && window.layout_manager.featured_box != null) {
                    hero_carousel = new HeroCarousel(window.layout_manager.featured_box);
                }
                featured_carousel_items.add(new ArticleItem(decoded_title, url, thumbnail_url, category_id, source_name));
                featured_carousel_category = category_id;
                if (hero_carousel != null) {
                    hero_carousel.add_initial_slide(hero_card.root);
                    hero_carousel.start_timer(25);
                }
                featured_used = true;
            }
            if (window.loading_state != null && window.loading_state.initial_phase) window.mark_initial_items_populated();
        }

        // Which articles may join the hero carousel as slides.
        private bool carousel_accepts(string category_id) {
            if (window.prefs.category == "myfeed" && window.prefs.personalized_feed_enabled) {
                if (category_id == "myfeed" || category_id == featured_carousel_category) return true;
                var followed = window.prefs.categories;
                return followed == null || followed.size == 0 || followed.contains(category_id);
            }
            if (window.category_manager.is_rssfeed_view()) return category_id.has_prefix("rssfeed:") || category_id == "myfeed";
            return category_id == window.prefs.category;
        }

        private void add_carousel_slide(string decoded_title, string url, string? thumbnail_url, string category_id, string? source_name, string? published) {
            string category_text = window.category_chip_text(resolve_display_category(category_id, source_name));
            var components = hero_carousel.create_article_slide(
                decoded_title, url, thumbnail_url, category_id, source_name, category_text,
                (t, u, thumb, cat, src) => { window.article_pane.show_article_preview(t, u, thumb, cat, src); },
                published,
                (article_url) => { open_article_in_app_if_online(article_url, true, source_name, decoded_title, thumbnail_url, published, category_id); }
            );

            var slide_hero = components.hero;
            if (slide_hero != null) {
                ArticleSnippetService.attach_hero_snippet(slide_hero, url, source_name, article_buffer);
                attach_badge_and_feedback(slide_hero.root, slide_hero.overlay, decoded_title, url, category_id, source_name);
            }

            var slide_image = components.image;
            int w = window.estimate_content_width();
            int h = HeroCarousel.SLIDE_IMAGE_HEIGHT;
            bool will_load = has_http_url(thumbnail_url);
            string norm = window.normalize_article_url(url);

            if (will_load) {
                load_hero_image(slide_image, thumbnail_url, w, h, category_id);
            } else {
                set_placeholder(slide_image, w, h, category_id, source_name, url);
            }
            slide_image.set_data<bool>("has-real-thumbnail", will_load);
            // Size passed explicitly: the picture's width request is -1.
            if (!will_load) ThumbnailBackfillService.enqueue(window, url, slide_image, w, h);
            register_card(norm, url, slide_image, components.slide);
            restore_viewed_state(norm);

            featured_carousel_items.add(new ArticleItem(decoded_title, url, thumbnail_url, category_id, source_name));
            if (window.article_state_store != null) window.article_state_store.register_article(norm, category_id, source_name);
        }

        // Trending's fetcher sends Front Page backfill after its headlines and can
        // over-supply; this keeps it to two heroes and two full rows.
        private bool trending_full() {
            return trending_hero_count >= 2 && trending_grid_count >= TRENDING_GRID_MAX;
        }

        // Trending backfill comes from the same feed as the hero carousel.
        private bool in_hero_carousel(string? url) {
            if (url == null || featured_carousel_items == null) return false;
            string norm = window.normalize_article_url(url);
            foreach (var item in featured_carousel_items) {
                if (item.url != null && window.normalize_article_url(item.url) == norm) return true;
            }
            return false;
        }

        // ---- Row caps ----

        // Claims one of a My Feed row's MYFEED_ROW_CARD_CAP slots; false once it's full.
        private bool try_take_myfeed_row_slot(string row_key) {
            if (row_card_counts == null) row_card_counts = new Gee.HashMap<string, int>();
            int count = row_card_counts.has_key(row_key) ? row_card_counts.get(row_key) : 0;
            if (count >= MYFEED_ROW_CARD_CAP) return false;
            row_card_counts.set(row_key, count + 1);
            return true;
        }

        // Front Page row for an article, e.g. "football" -> "sports".
        private string frontpage_row_key(string category_id, string? source_name) {
            return LayoutManager.frontpage_row_for(resolve_display_category(category_id, source_name));
        }

        // True once the hero and carousel are filled, so further articles become row cards.
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

        // ---- Overflow and "load more" ----

        private void queue_overflow(string title, string url, string? thumbnail_url, string category_id, string? source_name, string? published, string? snippet, bool already_marked) {
            if (queue_overflow_article(title, url, thumbnail_url, category_id, source_name, published, snippet, already_marked)) {
                show_load_more_button();
            }
        }

        // Adds an article to the "load more" queue. False if it's a duplicate.
        // already_marked: the caller has already claimed the URL in seen_urls.
        private bool queue_overflow_article(string title, string url, string? thumbnail_url,
                                            string category_id, string? source_name, string? published = null, string? snippet = null, bool already_marked = false) {
            string normalized_url = window.normalize_article_url(url);
            if (!already_marked && normalized_url.length > 0 && seen_urls.contains(normalized_url)) return false;
            if (normalized_url.length > 0) seen_urls.add(normalized_url);

            string? normalized_source = SourceManager.normalize_source_name(source_name, category_id, url);
            var queued_item = new ArticleItem(title, url, thumbnail_url, category_id, normalized_source, published);
            queued_item.snippet = snippet;
            remaining_articles.add(queued_item);
            string key = overflow_key_for(queued_item);
            remaining_category_counts.set(key, remaining_category_counts.get(key) + 1);

            // Register now so unread counts include queued articles.
            string norm = url.strip();
            if (norm.length > 0 && window.article_state_store != null) {
                window.article_state_store.register_article(norm, category_id, normalized_source);
            }

            // A section with no cards yet stays hidden, with no way to reach its
            // queue - reveal it (once per batch). See LayoutManager.reveal_sections_with_pending_overflow().
            if (window.layout_manager != null && !reveal_pending) {
                reveal_pending = true;
                ViewSession.view_idle(() => {
                    reveal_pending = false;
                    if (window.layout_manager != null) window.layout_manager.reveal_sections_with_pending_overflow();
                    return false;
                });
            }
            return true;
        }

        // Front Page overflow is grouped by row, so each row's arrow finds its own articles.
        private string overflow_key_for(ArticleItem item) {
            string cat = extract_display_category(item);
            return window.prefs.category == "frontpage" ? LayoutManager.frontpage_row_for(cat) : cat;
        }

        public int remaining_count_for_category(string cat) {
            return remaining_category_counts.get(cat);
        }

        // Moves one queued article onto the page. The caller removes it from the queue.
        private void place_queued(ArticleItem item) {
            string key = overflow_key_for(item);
            remaining_category_counts.set(key, remaining_category_counts.get(key) - 1);
            article_buffer.add(item);
            add_item_immediate_to_column(item.title, item.url, item.thumbnail_url, item.category_id, null, item.source_name, true, item.published);
        }

        // Runs `place`, then animates the cards it appended to `containers` as one
        // batch. They stay hidden until the thumbnail backfills they trigger resolve
        // (BackfillBatchGate), so placeholders don't flash first. The caller can
        // connect to the gate's ready signal, then must call begin().
        private BackfillBatchGate place_batch(Gee.List<Gtk.Widget> containers, PlaceBatchFunc place) {
            var counts_before = new Gee.ArrayList<int>();
            foreach (var c in containers) counts_before.add(child_count(c));

            var gate = new BackfillBatchGate();
            ThumbnailBackfillService.current_batch = gate;
            var session = ViewSession.current();
            place();
            ThumbnailBackfillService.current_batch = null;

            var anim = window.animation_manager;
            if (anim == null || containers.size == 0) return gate;

            for (int i = 0; i < containers.size; i++) {
                foreach (var card in children_from(containers[i], counts_before[i])) card.set_visible(false);
            }
            gate.ready.connect(() => {
                // On idle, so the new widgets are realized and parented.
                session.idle(() => {
                    var cards = new Gee.ArrayList<Gtk.Widget>();
                    for (int i = 0; i < containers.size; i++) cards.add_all(children_from(containers[i], counts_before[i]));
                    anim.animate_cards_entrance_batch(cards);
                    return false;
                });
            });
            return gate;
        }

        // A Front Page row's "load more": pulls that row's articles out of the
        // shared queue (load_more_articles() draws from it too).
        public void load_more_for_category(string cat, int max_to_load = LOAD_MORE_BATCH_SIZE) {
            Gtk.Widget? row = window.layout_manager != null ? window.layout_manager.get_category_section_row(cat) : null;
            var containers = new Gee.ArrayList<Gtk.Widget>();
            if (row != null) containers.add(row);

            var gate = place_batch(containers, () => {
                int loaded = 0;
                int i = 0;
                while (i < remaining_articles.size && loaded < max_to_load) {
                    var item = remaining_articles.get(i);
                    if (overflow_key_for(item) != cat) {
                        i++;
                        continue;
                    }
                    remaining_articles.remove_at(i);
                    place_queued(item);
                    loaded++;
                }
            });
            gate.begin();
        }

        // The global "load more" button.
        public void load_more_articles() {
            if (remaining_articles.size == 0) {
                if (load_more_button_visible) {
                    request_hide_load_more_button();
                    load_more_button_visible = false;
                    ViewSession.view_timeout(300, () => {
                        show_end_of_feed_unless_loading();
                        return false;
                    });
                }
                return;
            }

            var lm = window.layout_manager;
            var containers = new Gee.ArrayList<Gtk.Widget>();
            if (lm != null && lm.featured_box != null) containers.add(lm.featured_box);
            if (lm != null && lm.columns_row != null) containers.add(lm.columns_row);

            int to_load = int.min(LOAD_MORE_BATCH_SIZE, remaining_articles.size);
            var gate = place_batch(containers, () => {
                // From the front: load_more_for_category() takes from this queue out of order.
                for (int i = 0; i < to_load; i++) place_queued(remaining_articles.remove_at(0));
            });

            // Settle the button (spinner back to normal, or hidden at the end of the
            // feed) when the new cards are revealed.
            gate.ready.connect(() => {
                if (!load_more_button_visible) return;
                if (remaining_articles.size > 0) {
                    request_reset_load_more_button();
                    return;
                }
                request_hide_load_more_button();
                load_more_button_visible = false;
                show_end_of_feed_unless_loading();
            });
            gate.begin();
        }

        private void show_end_of_feed_unless_loading() {
            var loading = window.loading_state;
            if (loading == null) return;
            if (loading.loading_container == null || !loading.loading_container.get_visible()) loading.show_end_of_feed_message();
        }

        public void show_load_more_button() {
            if (load_more_button_visible) return;
            // The Front Page uses each row's arrow instead of one global button.
            if (window.prefs.category == "frontpage") return;
            if (window.loading_state.loading_container != null && window.loading_state.loading_container.get_visible()) return;

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

        // ---- "Recommended for you" ----

        // -1 when this article can't be a pick right now.
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

        // Ordering only: a qualifying pick is never dropped for having been shown before.
        private double rank_recommendation(double score, string title, string? published) {
            var profile = window.layout_manager.recommendation_profile;
            int impressions = window.article_state_store != null ? window.article_state_store.get_recommendation_impressions(story_key(title)) : 0;
            return profile.adjust(score, published, impressions);
        }

        // The same story can arrive under several URLs.
        private static string story_key(string title) {
            return title.strip().down();
        }

        private static int by_score_desc(RecommendedPick a, RecommendedPick b) {
            return a.score < b.score ? 1 : (a.score > b.score ? -1 : 0);
        }

        private bool shortlist_accepts(double score) {
            if (recommended_picks.size < RECOMMENDED_SHORTLIST) return true;
            return score > weakest_held_pick().score;
        }

        private RecommendedPick weakest_held_pick() {
            var weakest = recommended_picks.get(0);
            foreach (var p in recommended_picks) {
                if (p.score < weakest.score) weakest = p;
            }
            return weakest;
        }

        // Holds a candidate and restarts the settle timer.
        private void hold_recommended_pick(RecommendedPick pick) {
            recommended_picks.add(pick);
            if (recommended_picks.size > RECOMMENDED_SHORTLIST) {
                var evicted = weakest_held_pick();
                recommended_picks.remove(evicted);
                place_evicted_pick(evicted);
            }
            ViewSession.remove_source(ref recommendations_settle_id);
            recommendations_settle_id = ViewSession.view_timeout(RECOMMENDED_SETTLE_MS, () => {
                recommendations_settle_id = 0;
                finalize_recommendations();
                return false;
            });
        }

        // A candidate bumped off the shortlist goes to its row like any Front Page
        // article, row cap included. It has already passed add_item()'s dedupe and filters.
        private void place_evicted_pick(RecommendedPick pick) {
            var item = pick.item;
            if (frontpage_featured_full() && frontpage_row_full(frontpage_row_key(item.category_id, pick.raw_source_name))) {
                queue_overflow(item.title, item.url, item.thumbnail_url, item.category_id, pick.raw_source_name, item.published, item.snippet, true);
                return;
            }
            place_item(item, false);
        }

        // Ranks the held picks into the panel; the rest go to their category rows.
        // Runs once per fetch: when picks stop arriving, or when the Front Page list finishes.
        public void finalize_recommendations() {
            if (recommendations_finalized) return;
            recommendations_finalized = true;
            ViewSession.remove_source(ref recommendations_settle_id);

            var picks = recommended_picks;
            recommended_picks = new Gee.ArrayList<RecommendedPick>();
            if (picks.size == 0) return;
            picks.sort(by_score_desc);

            // Best first, at most RECOMMENDED_MAX_PER_CATEGORY per category, then
            // topped up with the looser cap. One card per story.
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
            chosen.sort(by_score_desc);
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

            foreach (var item in leftovers) place_item(item, false);
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
            article_buffer.add(item);   // snippet fallback, as add_item_immediate_to_column does

            if (i == 0) {
                var hero = new HeroCard.for_topten(decoded_title, item.url, lead_h, category_text, true, window.article_state_store, window, item.published);
                hero.title_label.set_lines(3);
                // Fixed text area instead of for_topten's 70/30 split, so the lead is exactly lead_h tall.
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

        // Disliking a panel card fades it out; then the next-best reserve pick takes its slot.
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

            // Only take a reserve pick when there's a card to swap it into:
            // taking one removes it from its category row.
            var next = old != null ? take_reserve_pick(idx) : null;
            if (next != null) {
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

            // Nothing to swap in: rebuild from what's left; picks that no longer fit
            // go back to their category rows.
            panel_picks.remove_at(idx);
            foreach (var pick in panel_picks) window.view_state.unregister_card_for_url(window.normalize_article_url(pick.item.url));
            section.clear();
            var rest = new Gee.ArrayList<RecommendedPick>();
            int keep = RecommendedSection.panel_size_for(panel_picks.size);
            while (panel_picks.size > keep) rest.insert(0, panel_picks.remove_at(panel_picks.size - 1));
            if (keep > 0) build_recommended_panel(section, panel_picks);
            foreach (var pick in rest) place_item(pick.item, true);
        }

        // Best reserve pick that fits slot idx's category cap. Its plain card is
        // removed from its category row.
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

                // Only cards sitting in a category row; heroes, carousel slides and
                // queued overflow stay where they are.
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

        // ---- Card placement ----

        // My Feed places an article in up to two rows: its category's and its
        // source's (see LayoutManager.prepare_myfeed_sections). A row that doesn't
        // exist is simply skipped.
        private void place_myfeed_article_cards(string decoded_title, string url, string? thumbnail_url, string category_id, string? source_name, bool bypass_limit, string? published, string? myfeed_row_key_hint) {
            string? cat_key = window.layout_manager.resolve_myfeed_category_key(category_id);
            string? src_key = window.layout_manager.resolve_myfeed_source_key(myfeed_row_key_hint);

            bool placed = false;
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

        // Reset once per My Feed build, so the badge counts only the current cards.
        public void reset_myfeed_displayed_urls() {
            if (window.article_state_store != null) window.article_state_store.reset_myfeed_displayed_urls();
        }

        // Persisted in ArticleStateStore so the badge count survives restarts.
        public Gee.HashSet<string> get_myfeed_displayed_urls() {
            if (window.article_state_store == null) return new Gee.HashSet<string>();
            return window.article_state_store.get_myfeed_displayed_urls();
        }

        // Builds one regular card into section_key's section (or the flat grid).
        // no_fallback_section: skip placement if section_key has no section (My Feed
        // rows) instead of falling back to the Front Page's "More Stories".
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
            // History uses its own compact row card.
            if (category_id == "history") {
                place_history_card(decoded_title, url, thumbnail_url, source_name, published);
                return;
            }
            if (window.layout_manager == null) {
                warning("ArticleManager: layout_manager not initialized, cannot place card");
                return;
            }

            // Trending (4 columns) shares LayoutManager with the Front Page's
            // 3-column rows, so it can't use the cached width.
            int col_w = forced_col_w > 0 ? forced_col_w
                : (is_trending ? window.layout_manager.estimate_column_width(4) : cached_column_width());
            int img_h = CARD_IMAGE_HEIGHT;
            string category_text = window.category_chip_text(resolve_display_category(category_id, source_name));

            var article_card = window.layout_manager.create_and_place_article_card(
                decoded_title, url, col_w, img_h, category_text, section_key, published, no_fallback_section, is_trending);
            attach_badge_and_feedback(article_card.root, article_card.overlay, decoded_title, url, category_id, source_name);

            bool has_real_thumbnail = has_http_url(thumbnail_url);
            if (has_real_thumbnail) {
                load_card_image(article_card.image, thumbnail_url, col_w, img_h, card_image_multiplier(), category_id);
            } else {
                set_placeholder(article_card.image, col_w, img_h, category_id, source_name, url);
            }
            // Lets a later hero-image backfill know not to overwrite a real thumbnail.
            article_card.image.set_data<bool>("has-real-thumbnail", has_real_thumbnail);
            if (!has_real_thumbnail) ThumbnailBackfillService.enqueue(window, url, article_card.image);

            string norm = window.normalize_article_url(url);
            register_card(norm, url, article_card.image, article_card.root);
            restore_viewed_state(norm);

            article_card.source_name = source_name;
            article_card.category_id = category_id;
            article_card.thumbnail_url = thumbnail_url;

            // Overflow articles (bypass_limit) were registered when queued.
            if (window.article_state_store != null && !bypass_limit) {
                window.article_state_store.register_article(norm, category_id, source_name);
            }

            var a = new CardArticle(decoded_title, url, thumbnail_url, source_name, category_id, published);
            var card_root = article_card.root;
            var card_save_ribbon = article_card.save_ribbon;
            // Unowned: a strong capture of the card's own widgets is a reference
            // cycle that keeps the card alive.
            unowned Gtk.Widget root_ref = card_root;
            unowned Gtk.Widget ribbon_ref = card_save_ribbon;
            ArticleCard.wire_interactions(
                card_root, url, window.article_state_store, window, source_name,
                (s) => { open_from_card(a, s); },
                (u) => { open_in_app(a, u, null); },
                (u) => { open_in_browser(a, u); },
                (u, src) => { follow_feed(u, src); },
                (u) => { toggle_saved(a, u, root_ref, ribbon_ref); },
                (u) => { window.show_share_dialog(u); },
                (u) => { open_in_app(a, u, true); }
            );

            if (window.loading_state != null && window.loading_state.initial_phase) window.mark_initial_items_populated();
        }

        // Cards load at medium quality, or low during the initial load to fill the
        // screen sooner - except single-source views, which always use medium.
        private int card_image_multiplier() {
            bool single_source = window.prefs.preferred_sources != null && window.prefs.preferred_sources.size == 1;
            bool initial = window.loading_state != null && window.loading_state.initial_phase;
            return (single_source || !initial) ? IMAGE_QUALITY_MULTIPLIER_MEDIUM : IMAGE_QUALITY_MULTIPLIER_LOW;
        }

        // A compact History row. The read time and real category come from the
        // stored history entry, not the article itself.
        private void place_history_card(string decoded_title, string url, string? thumbnail_url, string? source_name, string? published) {
            if (window.layout_manager == null) {
                warning("ArticleManager: layout_manager not initialized, cannot place card");
                return;
            }

            string norm = window.normalize_article_url(url);
            var history_entry = window.article_state_store != null ? window.article_state_store.get_history_article(norm) : null;
            int64 viewed_timestamp = history_entry != null ? history_entry.viewed_timestamp : (GLib.get_real_time() / 1000000);
            string? original_category = history_entry != null ? history_entry.category_id : null;
            string? category_display_name = has_text(original_category) ? window.category_chip_text(original_category) : null;

            var history_card = window.layout_manager.create_and_place_history_card(decoded_title, url, source_name, viewed_timestamp, category_display_name);
            history_card.enable_hover_actions(window);
            wire_history_card(history_card, decoded_title, url, thumbnail_url, source_name, published, original_category);

            if (window.loading_state != null && window.loading_state.initial_phase) window.mark_initial_items_populated();
        }

        // ---- Card wiring ----

        // Badge, image, tracking and click/save/menu wiring for every hero.
        private void wire_hero_card(HeroCard hero_card, string decoded_title, string url, string? thumbnail_url, string category_id, string? source_name, string? published, bool enable_hero_context_menu, bool with_snippet, int default_hero_w, int default_hero_h) {
            if (with_snippet) ArticleSnippetService.attach_hero_snippet(hero_card, url, source_name, article_buffer);
            attach_badge_and_feedback(hero_card.root, hero_card.overlay, decoded_title, url, category_id, source_name);

            string norm = window.normalize_article_url(url);
            bool will_load = has_http_url(thumbnail_url);
            if (will_load) {
                load_hero_image(hero_card.image, thumbnail_url, default_hero_w, default_hero_h, category_id);
                schedule_hero_refetch(window, hero_card.image);
            } else {
                set_placeholder(hero_card.image, default_hero_w, default_hero_h, category_id, source_name, url);
            }
            hero_card.image.set_data<bool>("has-real-thumbnail", will_load);
            // Size passed explicitly: the picture's width request is -1.
            if (!will_load) ThumbnailBackfillService.enqueue(window, url, hero_card.image, default_hero_w, default_hero_h);
            register_card(norm, url, hero_card.image, hero_card.root);
            restore_viewed_state(norm);

            hero_card.source_name = source_name;
            hero_card.category_id = category_id;
            hero_card.thumbnail_url = thumbnail_url;
            if (window.article_state_store != null) window.article_state_store.register_article(norm, category_id, source_name);

            var a = new CardArticle(decoded_title, url, thumbnail_url, source_name, category_id, published);
            var hero_root = hero_card.root;
            var hero_save_ribbon = hero_card.save_ribbon;
            // Unowned for the same reason as in place_regular_article_card().
            unowned Gtk.Widget root_ref = hero_root;
            unowned Gtk.Widget ribbon_ref = hero_save_ribbon;
            HeroCard.wire_interactions(
                hero_root, url, enable_hero_context_menu, window.article_state_store, window, source_name, category_id, thumbnail_url,
                hero_card.title_label, hero_card.image, hero_card.viewed_badge_slot, hero_card.footer_box, hero_card.overlay,
                (s) => { show_preview(a); },
                (u) => { open_in_app(a, u, null); },
                (u) => { open_in_browser(a, u); },
                (u, src) => { follow_feed(u, src); },
                (u) => { toggle_saved(a, u, root_ref, ribbon_ref); },
                (u) => { window.show_share_dialog(u); },
                (u) => { open_in_app(a, u, true); }
            );
        }

        // Badge, image, tracking and click wiring for a compact row card.
        private void wire_history_card(HistoryCard history_card, string decoded_title, string url, string? thumbnail_url, string? source_name, string? published, string? original_category) {
            var card_badge = window.build_source_badge_dynamic(source_name, url, "history");
            // The badge is styled to overlay an image corner; badge_slot is a plain
            // row, so undo those margins and alignments.
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
            bool will_load = has_http_url(thumbnail_url);
            if (will_load) {
                if (window.loading_state != null) window.loading_state.track_pending_image(history_card.image);
                if (window.image_manager != null) {
                    window.image_manager.load_image_async(history_card.image, thumbnail_url, img_w * IMAGE_QUALITY_MULTIPLIER_LOW, img_w * IMAGE_QUALITY_MULTIPLIER_LOW, true);
                }
            } else {
                set_smart_placeholder(history_card.image, img_w, img_w, source_name, url);
            }
            history_card.image.set_data<bool>("has-real-thumbnail", will_load);
            if (!will_load) ThumbnailBackfillService.enqueue(window, url, history_card.image);
            register_card(window.normalize_article_url(url), url, history_card.image, history_card.root);

            history_card.source_name = source_name;
            history_card.category_id = original_category;
            history_card.thumbnail_url = thumbnail_url;

            var a = new CardArticle(decoded_title, url, thumbnail_url, source_name, original_category, published);
            ArticleCard.wire_interactions(
                history_card.root, url, window.article_state_store, window, source_name,
                (s) => { open_from_card(a, s); },
                (u) => { open_in_app(a, u, null); },
                (u) => { open_in_browser(a, u); },
                (u, src) => { follow_feed(u, src); },
                (u) => { toggle_saved(a, u, null, null); },
                (u) => { window.show_share_dialog(u); },
                (u) => { open_in_app(a, u, true); }
            );
        }

        // Source badge (followable on the Front Page) and like/dislike buttons.
        private void attach_badge_and_feedback(Gtk.Widget root, Gtk.Overlay overlay, string title, string url, string? category_id, string? source_name) {
            var badge = window.build_source_badge_dynamic(source_name, url, category_id);
            CardBuilder.attach_source_badge(window, root, overlay, badge, url, source_name, window.prefs.category == "frontpage");
            CardBuilder.attach_feedback_buttons(window, root, overlay, url, title, source_name, category_id);
        }

        // Indexes a card by URL, so duplicates, image upgrades and viewed badges can find it.
        private void register_card(string norm, string url, Gtk.Picture image, Gtk.Widget root) {
            if (window.view_state == null) return;
            window.view_state.register_picture_for_url(norm, image);
            window.view_state.normalized_to_url.set(norm, url);
            window.view_state.register_card_for_url(norm, root);
        }

        // Shows the viewed badge on a card for an article read before.
        private void restore_viewed_state(string norm) {
            if (window.article_state_store != null && window.article_state_store.is_viewed(norm)) window.mark_article_viewed(norm);
        }

        // Loads a card's thumbnail at `multiplier` times its display size.
        private void load_card_image(Gtk.Picture image, string thumbnail_url, int w, int h, int multiplier, string category_id) {
            if (window.loading_state != null) window.loading_state.track_pending_image(image);
            window.image_manager.pending_local_placeholder.set(image, category_id == "local_news");
            window.image_manager.load_image_async(image, thumbnail_url, w * multiplier, h * multiplier, true);
        }

        // Heroes load at high quality and are remembered for later resolution upgrades.
        private void load_hero_image(Gtk.Picture image, string thumbnail_url, int w, int h, string category_id) {
            int m = IMAGE_QUALITY_MULTIPLIER_HIGH;
            load_card_image(image, thumbnail_url, w, h, m, category_id);
            window.image_manager.hero_requests.set(image, new HeroRequest(thumbnail_url, w * m, h * m, m));
        }

        // Static so the closure captures only the picture: capturing the HeroCard
        // (which holds its root widget) kept every hero alive.
        private static void schedule_hero_refetch(NewsWindow window, Gtk.Picture image) {
            ViewSession.view_timeout(300, () => {
                var info = window.image_manager.hero_requests.get(image);
                if (info != null) window.maybe_refetch_hero_for(image, info);
                return false;
            });
        }

        // Placeholder for a card without a usable thumbnail.
        private void set_placeholder(Gtk.Picture image, int w, int h, string category_id, string? source_name, string url) {
            if (category_id == "local_news") {
                window.set_local_placeholder_image(image, w, h);
            } else {
                set_smart_placeholder(image, w, h, source_name, url);
            }
        }

        private void set_smart_placeholder(Gtk.Picture image, int w, int h, string? source_name, string url) {
            if (window.category_manager.is_rssfeed_view() && has_text(source_name)) {
                window.set_rss_placeholder_image(image, w, h, source_name);
                return;
            }
            NewsSource resolved = window.resolve_source(source_name, url);
            // A built-in outlet's URL under a different name is a custom RSS feed
            // hosted on that site: brand it as the feed.
            if (resolved != NewsSource.UNKNOWN && has_text(source_name) && BuiltinSources.from_name(source_name) != resolved) {
                window.set_rss_placeholder_image(image, w, h, source_name);
                return;
            }
            window.set_placeholder_image_for_source(image, w, h, resolved);
        }

        // ---- Card callbacks ----

        // Card click: reader view if the user prefers it, else the preview pane.
        private void open_from_card(CardArticle a, string article_url) {
            if (window.prefs != null && window.prefs.article_click_opens_reader) {
                open_in_app(a, article_url, true);
            } else {
                show_preview(a);
            }
        }

        private void show_preview(CardArticle a) {
            if (window.article_pane != null) window.article_pane.show_article_preview(a.title, a.url, a.thumbnail_url, a.category_id, a.source_name);
        }

        private void open_in_app(CardArticle a, string article_url, bool? force_reader_view) {
            open_article_in_app_if_online(article_url, force_reader_view, a.source_name, a.title, a.thumbnail_url, a.published, a.category_id);
        }

        private void open_in_browser(CardArticle a, string article_url) {
            open_article_in_browser_if_online(article_url, a.source_name, a.title, a.thumbnail_url, a.published, a.category_id);
        }

        private void follow_feed(string article_url, string? source_name) {
            request_show_toast(_("Searching for feed..."), true);
            if (window.source_manager != null) window.source_manager.follow_rss_source(article_url, source_name);
        }

        // Saves or unsaves. root/ribbon (when given) animate the toggle. In the
        // Saved view an unsaved card is removed, or the view refetched.
        private void toggle_saved(CardArticle a, string article_url, Gtk.Widget? root, Gtk.Widget? ribbon) {
            var store = window.article_state_store;
            if (store == null) return;
            var anim = window.animation_manager;

            if (!store.is_saved(article_url)) {
                store.save_article(article_url, a.title, a.thumbnail_url, a.source_name, a.published);
                request_show_toast(_("Added article to saved"));
                if (anim != null && root != null && ribbon != null) anim.animate_save_toggle(root, ribbon, a.title, true);
                return;
            }

            store.unsave_article(article_url);
            request_show_toast(_("Removed article from saved"));
            if (anim != null && root != null && ribbon != null) anim.animate_save_toggle(root, ribbon, a.title, false);
            if (window.prefs.category != "saved") return;
            if (anim != null && root != null) {
                if (window.view_state != null) window.view_state.unregister_card_for_url(window.normalize_article_url(article_url));
                anim.animate_card_exit_and_remove(root, 0);
            } else {
                window.fetch_news();
            }
        }

        // ---- Reset ----

        // Keeps view/saved state: unread counts persist across category switches.
        public void clear_articles() {
            article_buffer.clear();
            remaining_articles.clear();
            remaining_category_counts.clear();
            articles_shown = 0;
            if (row_card_counts != null) row_card_counts.clear();
            seen_urls.clear();
            trending_seen_urls.clear();
            trending_hero_count = 0;
            trending_grid_count = 0;
            if (featured_carousel_items != null) featured_carousel_items.clear();
            featured_carousel_category = null;
            featured_used = false;
            clear_load_more_button();
            if (window.layout_manager != null) window.layout_manager.clear_columns();
        }

        // Call at the start of fetch_news().
        public void reset_for_new_fetch() {
            clear_articles();
            reset_featured_state();
            // Clears the whole box: the carousel's "FEATURED" label is a sibling of its container.
            if (window.layout_manager != null) window.layout_manager.clear_featured_box();
            // Its idle may have been dropped with the previous view's session.
            reveal_pending = false;
            recommended_picks.clear();
            recommendations_finalized = false;
            panel_picks = new Gee.ArrayList<RecommendedPick>();
            panel_reserve = new Gee.ArrayList<RecommendedPick>();
            ViewSession.remove_source(ref recommendations_settle_id);
        }

        public void clear_article_buffer() {
            article_buffer.clear();
        }

        public void reset_featured_state() {
            featured_used = false;
            trending_hero_count = 0;
            trending_grid_count = 0;
            if (featured_carousel_items != null) featured_carousel_items.clear();
            // Stop the timer before dropping the carousel, or its timeout source lives on.
            if (hero_carousel != null) hero_carousel.stop_timer();
            hero_carousel = null;
            featured_carousel_category = null;
        }

        // ---- Search result cards ----

        // Builds an ArticleCard from a hero's data, for search results. Takes plain
        // data because a HeroCard isn't reachable after it's built.
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
            string? category_label_text = has_text(hero_category_id) ? window.category_chip_text(hero_category_id) : null;
            var article_card = new ArticleCard(hero_title, hero_url, col_w, img_h, category_label_text, state_store, window);
            if (hero_paintable != null) article_card.image.set_paintable(hero_paintable);

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
            bool has_real_thumbnail = has_http_url(thumbnail_url);
            article_card.image.set_data<bool>("has-real-thumbnail", has_real_thumbnail);
            if (!has_real_thumbnail) ThumbnailBackfillService.enqueue(window, url, article_card.image);

            register_card(norm, url, article_card.image, article_card.root);
            if (window.article_state_store != null) {
                window.article_state_store.register_article(norm, category_id != null ? category_id : "", source_name);
            }

            var a = new CardArticle(title, url, thumbnail_url, source_name, category_id, null);
            var card_root = article_card.root;
            var card_save_ribbon = article_card.save_ribbon;
            // The save callback finds the card by URL instead of capturing card_root,
            // which would cycle with the card's own gesture controller.
            card_root.set_data("card-save-ribbon", card_save_ribbon);
            ArticleCard.wire_interactions(
                card_root, url, window.article_state_store, window, source_name,
                (s) => { open_from_card(a, s); },
                (u) => { open_in_app(a, u, null); },
                (u) => { open_in_browser(a, u); },
                (u, src) => { follow_feed(u, src); },
                (u) => {
                    Gtk.Widget? live_root = window.view_state != null ? window.view_state.get_card_for_url(window.normalize_article_url(u)) : null;
                    Gtk.Widget? live_ribbon = live_root != null ? live_root.get_data<Gtk.Widget>("card-save-ribbon") : null;
                    toggle_saved(a, u, live_root, live_ribbon);
                },
                (u) => { window.show_share_dialog(u); },
                (u) => { open_in_app(a, u, true); }
            );
        }
    }
}
