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
    public class ArticleManager : GLib.Object {
        private NewsWindow window;
        
        public const int INITIAL_ARTICLE_LIMIT = 25;
        public const int LOCAL_NEWS_IMAGE_LOAD_LIMIT = 12;
        public const int MAX_RECENT_CATEGORIES = 6;
        
        public Gee.ArrayList<ArticleItem> article_buffer;
        public ArticleItem[]? remaining_articles = null;
        public int remaining_articles_index = 0;
        public int articles_shown = 0;
        
        // Category distribution
        public Gee.HashMap<string, int> category_column_counts;
        public Gee.ArrayList<string> recent_categories;
        public int next_column_index;
        public Gee.HashMap<string, int> category_last_column;
        public Gee.ArrayList<string> recent_category_queue;
        
        public int topten_hero_count = 0;
        public Gee.ArrayList<ArticleItem>? featured_carousel_items;
        public HeroCarousel? hero_carousel;
        public string? featured_carousel_category = null;
        public bool featured_used = false;
        
        private Gtk.Button? load_more_button = null;
        public uint buffer_flush_timeout_id = 0;
        
        public ArticleManager(NewsWindow w) {
            window = w;
            article_buffer = new Gee.ArrayList<ArticleItem>();
            category_column_counts = new Gee.HashMap<string, int>();
            recent_categories = new Gee.ArrayList<string>();
            category_last_column = new Gee.HashMap<string, int>();
            recent_category_queue = new Gee.ArrayList<string>();
            next_column_index = 0;
        }
        
        public void add_item(string title, string url, string? thumbnail_url, string category_id, string? source_name) {
            // Trace entry for debugging UI regressions (always printed)
            
            bool viewing_limited_category = (
                window.prefs.category == "general" || 
                window.prefs.category == "us" || 
                window.prefs.category == "sports" || 
                window.prefs.category == "science" || 
                window.prefs.category == "health" || 
                window.prefs.category == "technology" || 
                window.prefs.category == "business" || 
                window.prefs.category == "entertainment" || 
                window.prefs.category == "politics" ||
                window.prefs.category == "lifestyle" || 
                window.prefs.category == "markets" ||
                window.prefs.category == "industries" ||
                window.prefs.category == "economics" ||
                window.prefs.category == "wealth" || 
                window.prefs.category == "green"
                || window.prefs.category == "local_news"
            );
            
            if (viewing_limited_category) {
                lock (articles_shown) {
                    try {
                        string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                        if (dbg != null && dbg.length > 0) {
                        }
                    } catch (GLib.Error e) { }
                    
                    if (articles_shown >= INITIAL_ARTICLE_LIMIT && load_more_button == null) {
                        try {
                            string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                            if (dbg != null && dbg.length > 0) {
                            }
                        } catch (GLib.Error e) { }
                        if (remaining_articles == null) {
                            remaining_articles = new ArticleItem[1];
                            remaining_articles[0] = new ArticleItem(title, url, thumbnail_url, category_id, source_name);
                        } else {
                            var new_arr = new ArticleItem[remaining_articles.length + 1];
                            for (int i = 0; i < remaining_articles.length; i++) {
                                new_arr[i] = remaining_articles[i];
                            }
                            new_arr[remaining_articles.length] = new ArticleItem(title, url, thumbnail_url, category_id, source_name);
                            remaining_articles = new_arr;
                        }
                        show_load_more_button();
                        return;
                    }
                }
            }
            
            string? final_source_name = source_name;
            try {
                var prefs_local = NewsPreferences.get_instance();
                if (final_source_name == null || final_source_name.length == 0) {
                    if (category_id == "local_news") {
                        if (prefs_local.user_location_city != null && prefs_local.user_location_city.length > 0)
                            final_source_name = prefs_local.user_location_city;
                        else
                            final_source_name = "Local News";
                    } else {
                        NewsSource inferred = window.infer_source_from_url(url);
                        final_source_name = window.get_source_name(inferred);
                    }
                }
            } catch (GLib.Error e) {
                final_source_name = source_name;
            }

            bool debug_enabled() {
                string? e = Environment.get_variable("PAPERBOY_DEBUG");
                return e != null && e.length > 0;
            }

            if (debug_enabled()) {
                warning("add_item called: current_view=%s article_cat=%s title=%s", window.prefs.category, category_id, title);
            }
            try {
                string? _dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                if (_dbg != null && _dbg.length > 0) {
                    window.append_debug_log("add_item: view=" + window.prefs.category + " article_cat=" + category_id + " title=" + title);
                }
            } catch (GLib.Error e) { }
            
            string normalized = "";
            try {
                if (url != null) normalized = window.normalize_article_url(url);
            } catch (GLib.Error e) {
                normalized = url != null ? url : "";
            }

            if (normalized == null) normalized = "";

            Gtk.Picture? existing = null;
            if (window.view_state != null) {
                try { existing = window.view_state.url_to_picture.get(normalized); } catch (GLib.Error e) { existing = null; }
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
                        var info = window.hero_requests.get(existing);
                        int target_w = info != null ? info.last_requested_w : window.layout_manager.estimate_column_width(window.layout_manager.columns_count);
                        int target_h = info != null ? info.last_requested_h : (int)(target_w * 0.5);
                        if (window.loading_state != null && window.loading_state.initial_phase) window.loading_state.pending_images++;
                        try { window.pending_local_placeholder.set(existing, category_id == "local_news"); } catch (GLib.Error e) { }
                        window.image_handler.load_image_async(existing, thumbnail_url, target_w, target_h);
                        return;
                    } else {
                    }
            }

            string view_category = window.prefs.category;
            if (view_category == "myfeed") {
                if (window.prefs.personalized_feed_enabled) {
                    bool has_personalized = window.prefs.personalized_categories != null && window.prefs.personalized_categories.size > 0;
                    if (has_personalized) {
                        bool match = false;
                        foreach (var pc in window.prefs.personalized_categories) if (pc == category_id) { match = true; break; }
                        if (!match) {
                            return;
                        }
                    }
                } else {
                    if (debug_enabled()) warning("Dropping article because My Feed personalization is disabled: article_cat=%s title=%s", category_id, title);
                    return;
                }
            } else {
                if (view_category != "all" && view_category != "frontpage" && view_category != "topten" && view_category != category_id) {
                    return;
                }
            }

            if (window.prefs.category != "frontpage" && window.prefs.category != "topten" && window.prefs.preferred_sources != null && window.prefs.preferred_sources.size > 0) {
                NewsSource article_src = window.infer_source_from_url(url);
                string article_src_id = "";
                switch (article_src) {
                    case NewsSource.GUARDIAN: article_src_id = "guardian"; break;
                    case NewsSource.REDDIT: article_src_id = "reddit"; break;
                    case NewsSource.BBC: article_src_id = "bbc"; break;
                    case NewsSource.NEW_YORK_TIMES: article_src_id = "nytimes"; break;
                    case NewsSource.WALL_STREET_JOURNAL: article_src_id = "wsj"; break;
                    case NewsSource.BLOOMBERG: article_src_id = "bloomberg"; break;
                    case NewsSource.REUTERS: article_src_id = "reuters"; break;
                    case NewsSource.NPR: article_src_id = "npr"; break;
                    case NewsSource.FOX: article_src_id = "fox"; break;
                    default: article_src_id = ""; break;
                }

                if (article_src_id.length > 0) {
                    bool allowed_src = false;
                    foreach (var ps in window.prefs.preferred_sources) {
                        if (ps == article_src_id) { allowed_src = true; break; }
                    }
                    if (!allowed_src) {
                        debug("Article filtered out: url=%s, inferred_src=%s, preferred=%s",
                              url.length > 80 ? url.substring(0, 80) : url,
                              article_src_id,
                              window.prefs.preferred_sources != null ? string.joinv(",", (string[])window.prefs.preferred_sources.to_array()) : "null");
                        return;
                    }
                }
            }

            if (window.prefs.preferred_sources != null && window.prefs.preferred_sources.size > 1) {
                string[] bloomberg_only = { "markets", "industries", "economics", "wealth", "green" };
                bool is_bloomberg_cat = false;
                foreach (var bc in bloomberg_only) if (bc == category_id) { is_bloomberg_cat = true; break; }
                if (is_bloomberg_cat) {
                    NewsSource article_src = window.infer_source_from_url(url);
                    if (article_src != NewsSource.BLOOMBERG) {
                        try {
                            string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                            if (dbg != null && dbg.length > 0) {
                                if (window.prefs.category == "topten") {
                                }
                            }
                        } catch (GLib.Error e) { }
                        return;
                    }
                }
            }
            
            if (window.prefs.category == "all") {
                NewsSource eff = window.effective_news_source();
                if (eff == NewsSource.BLOOMBERG && (window.prefs.preferred_sources == null || window.prefs.preferred_sources.size <= 1)) {
                    string[] bloomberg_cats = { "markets", "industries", "economics", "wealth", "green", "politics", "technology" };
                    bool allowed = false;
                    foreach (string bc in bloomberg_cats) {
                        if (bc == category_id) { allowed = true; break; }
                    }
                    if (!allowed) {
                        if (debug_enabled()) {
                            warning("Dropping article for Bloomberg (single-source): view=all source=Bloomberg article_cat=%s title=%s", category_id, title);
                        }
                        return;
                    }
                }
                
                if (category_id == "lifestyle") {
                    NewsSource article_src = window.infer_source_from_url(url);
                    if (article_src == NewsSource.REDDIT || article_src == NewsSource.BBC || article_src == NewsSource.REUTERS) {
                        if (debug_enabled()) {
                            warning("Dropping lifestyle article from source that doesn't provide lifestyle: source=%s title=%s", window.get_source_name(article_src), title);
                        }
                        return;
                    }
                }

                var item = new ArticleItem(title, url, thumbnail_url, category_id, final_source_name);
                article_buffer.add(item);
                
                if (buffer_flush_timeout_id > 0) {
                    Source.remove(buffer_flush_timeout_id);
                }
                buffer_flush_timeout_id = Timeout.add(500, () => {
                    flush_article_buffer();
                    buffer_flush_timeout_id = 0;
                    return false;
                });
            } else {
                var item = new ArticleItem(title, url, thumbnail_url, category_id, final_source_name);
                article_buffer.add(item);
                
                try {
                    string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                    if (dbg != null && dbg.length > 0 && window.prefs.category == "topten") {
                        window.append_debug_log("TOPTEN: About to call add_item_immediate_to_column for: " + title);
                    }
                } catch (GLib.Error e) { }
                add_item_immediate_to_column(title, url, thumbnail_url, category_id, -1, null, final_source_name);
            }
        }
        
        public void flush_article_buffer() {
            if (window.prefs.category != "all" || article_buffer.size == 0) {
                return;
            }
            
            if (window.loading_state == null || !window.loading_state.initial_phase) {
                window.hide_loading_spinner();
            }
            
            var articles = new ArticleItem[article_buffer.size];
            for (int i = 0; i < article_buffer.size; i++) {
                articles[i] = article_buffer[i];
            }
            
            for (int i = articles.length - 1; i > 0; i--) {
                int j = window.rng.int_range(0, i + 1);
                var temp = articles[i];
                articles[i] = articles[j];
                articles[j] = temp;
            }
            
            int articles_added = 0;
            for (int i = 0; i < articles.length; i++) {
                var article = articles[i];
                add_item_shuffled(article.title, article.url, article.thumbnail_url, article.category_id, article.source_name);
                articles_added++;
            }
            
            article_buffer.clear();

            try { window.mark_initial_items_populated(); } catch (GLib.Error e) { }
        }
        
        private void add_item_shuffled(string title, string url, string? thumbnail_url, string category_id, string? source_name) {
            int target_col = next_column_index;
            next_column_index = (next_column_index + 1) % window.layout_manager.columns.length;
            
            string saved_category = window.prefs.category;
            window.prefs.category = category_id;
            add_item_immediate_to_column(title, url, thumbnail_url, category_id, target_col, saved_category, source_name);
            window.prefs.category = saved_category;
        }
        
        public void add_item_immediate_to_column(string title, string url, string? thumbnail_url, string category_id, int forced_column = -1, string? original_category = null, string? source_name = null, bool bypass_limit = false) {
            try {
                string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                if (dbg != null && dbg.length > 0 && window.prefs.category == "topten") {
                    window.append_debug_log("add_item_immediate_to_column called for TOPTEN: category_id=" + category_id + " title=" + title);
                }
            } catch (GLib.Error e) { }
            
            try {
                string? _dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                if (_dbg != null && _dbg.length > 0) {
                    string in_src = source_name != null ? source_name : "<null>";
                    window.append_debug_log("add_item_immediate_to_column: incoming_source_name=" + in_src + " url=" + (url != null ? url : "<null>") + " category=" + category_id + " title=" + title);
                }
            } catch (GLib.Error e) { }
            
            string check_category = original_category ?? window.prefs.category;
            
            try {
                string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                if (dbg != null && dbg.length > 0) {
                    window.append_debug_log("add_item_immediate_to_column: prefs.category=" + window.prefs.category + " original_category=" + (original_category != null ? original_category : "null") + " check_category=" + check_category + " article_cat=" + category_id);
                }
            } catch (GLib.Error e) { }
            
            bool is_limited_category = (
                check_category == "general" || 
                check_category == "us" || 
                check_category == "sports" || 
                check_category == "science" || 
                check_category == "health" || 
                check_category == "technology" || 
                check_category == "business" || 
                check_category == "entertainment" || 
                check_category == "politics" ||
                check_category == "lifestyle" || 
                check_category == "markets" ||
                check_category == "industries" ||
                check_category == "economics" ||
                check_category == "wealth" ||
                check_category == "green"
                || check_category == "local_news"
            );
            
            try {
                string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                if (dbg != null && dbg.length > 0) {
                    window.append_debug_log("add_item_immediate_to_column: check_category=" + check_category + " is_limited=" + (is_limited_category ? "YES" : "NO") + " title=" + title);
                }
            } catch (GLib.Error e) { }
            
            if (is_limited_category && !bypass_limit) {
                lock (articles_shown) {
                    try {
                        string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                        if (dbg != null && dbg.length > 0) {
                        }
                    } catch (GLib.Error e) { }
                    
                    if (articles_shown >= INITIAL_ARTICLE_LIMIT) {
                        try {
                            string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                            if (dbg != null && dbg.length > 0) {
                            }
                        } catch (GLib.Error e) { }
                        
                        if (title == null || url == null) {
                            return;
                        }
                        
                        if (remaining_articles == null) {
                            remaining_articles = new ArticleItem[1];
                            remaining_articles[0] = new ArticleItem(title, url, thumbnail_url, category_id, source_name);
                        } else {
                            var new_arr = new ArticleItem[remaining_articles.length + 1];
                            for (int i = 0; i < remaining_articles.length; i++) {
                                new_arr[i] = remaining_articles[i];
                            }
                            new_arr[remaining_articles.length] = new ArticleItem(title, url, thumbnail_url, category_id, source_name);
                            remaining_articles = new_arr;
                        }
                        
                        if (load_more_button == null) {
                            show_load_more_button();
                        }
                        return;
                    }
                    
                    articles_shown++;
                    
                    try {
                        string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                        if (dbg != null && dbg.length > 0) {
                            window.append_debug_log("add_item_immediate_to_column INCREMENTED to " + articles_shown.to_string() + " category=" + check_category + " title=" + title);
                        }
                    } catch (GLib.Error e) { }
                }
            }
            
            int target_col = -1;
            if (window.prefs.category == "all" && forced_column == -1) {
                int consecutive_count = 0;
                
                for (int i = recent_category_queue.size - 1; i >= 0; i--) {
                    if (recent_category_queue.get(i) == category_id) {
                        consecutive_count++;
                    } else {
                        break;
                    }
                }
                
                if (consecutive_count >= 4) {
                    return;
                }
                
                recent_category_queue.add(category_id);
                if (recent_category_queue.size > MAX_RECENT_CATEGORIES) {
                    recent_category_queue.remove_at(0);
                }
                
                target_col = next_column_index;
                next_column_index = (next_column_index + 1) % window.layout_manager.columns.length;
            } else if (forced_column != -1) {
                target_col = forced_column;
            } else {
                target_col = next_column_index;
                next_column_index = (next_column_index + 1) % window.layout_manager.columns.length;
            }
            
            bool should_be_hero = false;
            if (window.prefs.category == "topten") {
                should_be_hero = (topten_hero_count < 2);
            } else if (window.prefs.category == "frontpage") {
                // For frontpage, only make the first article a hero (same as other categories)
                should_be_hero = !featured_used;
            } else if (!featured_used) {
                if (window.prefs.category == "all") {
                    should_be_hero = window.rng.int_range(0, 10) < 6;
                } else {
                    should_be_hero = true;
                }

                if (window.prefs.news_source == NewsSource.REDDIT && url != null) {
                    string u_low = url.down();
                    if (u_low.index_of("/live/") >= 0 || u_low.has_suffix("/live") || u_low.index_of("reddit.com/live") >= 0) {
                        should_be_hero = false;
                    }
                }
            }
            
            if (should_be_hero) {
                int max_hero_height = (window.prefs.category == "topten") ? 280 : 350;
                int default_hero_w = window.estimate_content_width();
                int default_hero_h = (window.prefs.category == "topten") ? 210 : 250;

                string hero_display_cat = category_id;
                try {
                    if (hero_display_cat == "frontpage" && source_name != null) {
                        int idx = source_name.index_of("##category::");
                        if (idx >= 0) hero_display_cat = source_name.substring(idx + 11).strip();
                    }
                } catch (GLib.Error e) { }

                var hero_chip = window.build_category_chip(hero_display_cat);
                var hero_card = new HeroCard(title, url, max_hero_height, default_hero_h, hero_chip);

                bool hero_will_load = thumbnail_url != null && thumbnail_url.length > 0 &&
                    (thumbnail_url.has_prefix("http://") || thumbnail_url.has_prefix("https://"));

                if (!hero_will_load) {
                    if (category_id == "local_news")
                        window.set_local_placeholder_image(hero_card.image, default_hero_w, default_hero_h);
                    else
                        window.set_placeholder_image_for_source(hero_card.image, default_hero_w, default_hero_h, window.resolve_source(source_name, url));
                }

                    if (hero_will_load) {
                    // Hero images are the most prominent feature - always use maximum quality
                    int multiplier = 6;
                    if (window.loading_state != null && window.loading_state.initial_phase) window.loading_state.pending_images++;
                    try { window.pending_local_placeholder.set(hero_card.image, category_id == "local_news"); } catch (GLib.Error e) { }
                    window.image_handler.load_image_async(hero_card.image, thumbnail_url, default_hero_w * multiplier, default_hero_h * multiplier);
                    window.hero_requests.set(hero_card.image, new HeroRequest(thumbnail_url, default_hero_w * multiplier, default_hero_h * multiplier, multiplier));
                    string _norm = window.normalize_article_url(url);
                    try { if (window.view_state != null) window.view_state.register_picture_for_url(_norm, hero_card.image); } catch (GLib.Error e) { }
                    try { if (window.view_state != null) window.view_state.normalized_to_url.set(_norm, url); } catch (GLib.Error e) { }
                    try { if (window.view_state != null) window.view_state.register_card_for_url(_norm, hero_card.root); } catch (GLib.Error e) { }
                    try {
                        if (window.article_state_store != null) {
                            bool was = false;
                            try { was = window.article_state_store.is_viewed(_norm); } catch (GLib.Error e) { was = false; }
                            try { window.append_debug_log("meta_check: hero url=" + _norm + " was=" + (was ? "true" : "false")); } catch (GLib.Error e) { }
                            if (was) { try { window.mark_article_viewed(_norm); } catch (GLib.Error e) { } }
                        }
                    } catch (GLib.Error e) { }
                    Timeout.add(300, () => { var info = window.hero_requests.get(hero_card.image); if (info != null) window.maybe_refetch_hero_for(hero_card.image, info); return false; });
                }

                hero_card.activated.connect((s) => { try { window.article_pane.show_article_preview(title, url, thumbnail_url, category_id); } catch (GLib.Error e) { } });

                if (window.prefs.category == "topten") {
                    if (topten_hero_count < 2) {
                        window.layout_manager.hero_container.append(hero_card.root);
                        topten_hero_count++;
                        featured_used = true;
                        if (window.loading_state != null && window.loading_state.initial_phase) window.mark_initial_items_populated();
                        return;
                    }
                } else {
                    if (featured_carousel_items == null) featured_carousel_items = new Gee.ArrayList<ArticleItem>();
                    if (hero_carousel == null) hero_carousel = new HeroCarousel(window.layout_manager.featured_box);
                    featured_carousel_items.add(new ArticleItem(title, url, thumbnail_url, category_id, source_name));
                    featured_carousel_category = category_id;

                    hero_carousel.add_initial_slide(hero_card.root);
                    hero_carousel.start_timer(5);

                    featured_used = true;
                    if (window.loading_state != null && window.loading_state.initial_phase) window.mark_initial_items_populated();
                    return;
                }
            }

            if (window.prefs.category != "topten" && hero_carousel != null && featured_carousel_items != null &&
            featured_carousel_items.size < 5) {
            bool allow_slide = false;
            if (window.prefs.category == "all") {
                allow_slide = (featured_carousel_category != null && featured_carousel_category == category_id);
            } else if (window.prefs.category == "myfeed" && window.prefs.personalized_feed_enabled) {
                if (featured_carousel_category != null && featured_carousel_category == category_id) {
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
            } else {
                allow_slide = (category_id == window.prefs.category);
            }
            if (!allow_slide) {
                return;
            }

            var slide = new Gtk.Box(Orientation.VERTICAL, 0);

            int max_hero_height = 350;
            slide.set_size_request(-1, max_hero_height);
            slide.set_hexpand(true);
            slide.set_vexpand(false);
            slide.set_halign(Gtk.Align.FILL);
            slide.set_valign(Gtk.Align.START);
            slide.set_margin_start(0);
            slide.set_margin_end(0);

            var slide_image = new Gtk.Picture();
            slide_image.set_halign(Gtk.Align.FILL);
            slide_image.set_hexpand(true);
            slide_image.set_size_request(-1, 250);
            slide_image.set_content_fit(Gtk.ContentFit.COVER);
            slide_image.set_can_shrink(true);

            var slide_overlay = new Gtk.Overlay();
            slide_overlay.set_child(slide_image);
            string slide_display_cat = category_id;
            try {
                if (slide_display_cat == "frontpage" && source_name != null) {
                    int idx2 = source_name.index_of("##category::");
                    if (idx2 >= 0) slide_display_cat = source_name.substring(idx2 + 11).strip();
                }
            } catch (GLib.Error e) { }
            var slide_chip = window.build_category_chip(slide_display_cat);
            slide_overlay.add_overlay(slide_chip);

            int default_w = window.estimate_content_width();
            int default_h = 250;
            bool slide_will_load = thumbnail_url != null && thumbnail_url.length > 0 &&
                (thumbnail_url.has_prefix("http://") || thumbnail_url.has_prefix("https://"));
            if (!slide_will_load) {
                if (category_id == "local_news") {
                    window.set_local_placeholder_image(slide_image, default_w, default_h);
                } else {
                    window.set_placeholder_image_for_source(slide_image, default_w, default_h, window.resolve_source(source_name, url));
                }
            }
            if (slide_will_load) {
                // Carousel slides are prominent features - always use maximum quality
                int multiplier = 6;
                if (window.loading_state != null && window.loading_state.initial_phase) window.loading_state.pending_images++;
                try { window.pending_local_placeholder.set(slide_image, category_id == "local_news"); } catch (GLib.Error e) { }
                window.image_handler.load_image_async(slide_image, thumbnail_url, default_w * multiplier, default_h * multiplier);
                window.hero_requests.set(slide_image, new HeroRequest(thumbnail_url, default_w * multiplier, default_h * multiplier, multiplier));
                string _norm = window.normalize_article_url(url);
                try { if (window.view_state != null) window.view_state.register_picture_for_url(_norm, slide_image); } catch (GLib.Error e) { }
                try { if (window.view_state != null) window.view_state.normalized_to_url.set(_norm, url); } catch (GLib.Error e) { }
                try { if (window.view_state != null) window.view_state.register_card_for_url(_norm, slide); } catch (GLib.Error e) { }
                try {
                    if (window.article_state_store != null) {
                        bool was = false;
                        try { was = window.article_state_store.is_viewed(_norm); } catch (GLib.Error e) { was = false; }
                        try { window.append_debug_log("meta_check: slide url=" + _norm + " was=" + (was ? "true" : "false")); } catch (GLib.Error e) { }
                        if (was) { try { window.mark_article_viewed(_norm); } catch (GLib.Error e) { } }
                    }
                } catch (GLib.Error e) { }
            }
            slide.append(slide_overlay);

            var slide_title_box = new Gtk.Box(Orientation.VERTICAL, 8);
            slide_title_box.set_margin_start(16);
            slide_title_box.set_margin_end(16);
            slide_title_box.set_margin_top(16);
            slide_title_box.set_margin_bottom(16);
            slide_title_box.set_vexpand(true);

            var slide_label = new Gtk.Label(title);
            slide_label.set_ellipsize(Pango.EllipsizeMode.END);
            slide_label.set_xalign(0);
            slide_label.set_wrap(true);
            slide_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
            slide_label.set_lines(8);
            slide_label.set_max_width_chars(88);
            slide_title_box.append(slide_label);
            slide.append(slide_title_box);

            var slide_click = new Gtk.GestureClick();
            slide_click.released.connect(() => {
                window.article_pane.show_article_preview(title, url, thumbnail_url, category_id);
            });
            slide.add_controller(slide_click);

            int new_index = featured_carousel_items.size;
            if (hero_carousel == null) hero_carousel = new HeroCarousel(window.layout_manager.featured_box);
            hero_carousel.add_slide(slide);
            featured_carousel_items.add(new ArticleItem(title, url, thumbnail_url, category_id, source_name));

            try {
                string? _dbg2 = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                if (_dbg2 != null && _dbg2.length > 0) {
                    print("DEBUG: added slide idx=%d category=%s title=%s\n", new_index, category_id, title);
                    window.append_debug_log("slide_added: idx=" + new_index.to_string() + " category=" + category_id + " title=" + title);
                }
            } catch (GLib.Error e) { }

            if (hero_carousel != null) hero_carousel.update_dots();

            return;
        }

        int variant = window.rng.int_range(0, 3);
        int col_w = window.layout_manager.estimate_column_width(window.layout_manager.columns_count);
        int img_w = col_w;
        int img_h = 0;
        switch (variant) {
            case 0:
                img_h = (int)(col_w * 0.42);
                if (img_h < 80) img_h = 80;
                break;
            case 1:
                img_h = (int)(col_w * 0.5);
                if (img_h < 100) img_h = 100;
                break;
            default:
                img_h = (int)(col_w * 0.58);
                if (img_h < 120) img_h = 120;
                break;
        }
        
        img_h = (int)(img_h * 1.2);

        string card_display_cat = category_id;
        try {
            if (card_display_cat == "frontpage" && source_name != null) {
                int idx3 = source_name.index_of("##category::");
                if (idx3 >= 0) card_display_cat = source_name.substring(idx3 + 11).strip();
            }
        } catch (GLib.Error e) { }

        var chip = window.build_category_chip(card_display_cat);

        var article_card = new ArticleCard(title, url, col_w, img_h, chip, variant);

        if (category_id != "local_news") {
            var card_badge = window.build_source_badge_dynamic(source_name, url, category_id);
            try { article_card.overlay.add_overlay(card_badge); } catch (GLib.Error e) { }
        }

        bool card_will_load = thumbnail_url != null && thumbnail_url.length > 0 &&
            (thumbnail_url.has_prefix("http://") || thumbnail_url.has_prefix("https://"));

        string _norm = window.normalize_article_url(url);

            if (card_will_load) {
            if (category_id == "local_news" && !bypass_limit) {
                try {
                        if (articles_shown >= LOCAL_NEWS_IMAGE_LOAD_LIMIT) {
                        window.set_local_placeholder_image(article_card.image, img_w, img_h);
                        try { if (window.view_state != null) window.view_state.register_picture_for_url(_norm, article_card.image); } catch (GLib.Error e) { }
                        try {
                            string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                            if (dbg != null && dbg.length > 0) {
                                window.append_debug_log("Local News: skipped image load for item index=" + articles_shown.to_string() + " url=" + _norm);
                            }
                        } catch (GLib.Error e) { }
                        card_will_load = false;
                    }
                } catch (GLib.Error e) { }
            }
            // In single-source mode, use higher 3x multiplier for crisp quality; in multi-source mode, use 2x initially then 3x
            bool single_source = (window.prefs.preferred_sources != null && window.prefs.preferred_sources.size == 1);
            int multiplier = single_source ? 3 : ((window.loading_state != null && window.loading_state.initial_phase) ? 2 : 3);
            if (window.loading_state != null && window.loading_state.initial_phase) window.loading_state.pending_images++;
            try { window.pending_local_placeholder.set(article_card.image, category_id == "local_news"); } catch (GLib.Error e) { }
            window.image_handler.load_image_async(article_card.image, thumbnail_url, img_w * multiplier, img_h * multiplier);
            try { if (window.view_state != null) window.view_state.register_picture_for_url(_norm, article_card.image); } catch (GLib.Error e) { }
        } else {
            if (category_id == "local_news") {
                window.set_local_placeholder_image(article_card.image, img_w, img_h);
            } else {
                window.set_placeholder_image_for_source(article_card.image, img_w, img_h, window.resolve_source(source_name, url));
            }
        }

        try { if (window.view_state != null) window.view_state.normalized_to_url.set(_norm, url); } catch (GLib.Error e) { }
        try { if (window.view_state != null) window.view_state.register_card_for_url(_norm, article_card.root); } catch (GLib.Error e) { }
        try {
            if (window.article_state_store != null) {
                bool was = false;
                try { was = window.article_state_store.is_viewed(_norm); } catch (GLib.Error e) { was = false; }
                try { window.append_debug_log("meta_check: card url=" + _norm + " was=" + (was ? "true" : "false")); } catch (GLib.Error e) { }
                stderr.printf("[VIEWED_CHECK] URL: %s | Viewed: %s\n", _norm, was ? "YES" : "NO");
                if (was) { try { window.mark_article_viewed(_norm); } catch (GLib.Error e) { } }
            }
        } catch (GLib.Error e) { }

        article_card.activated.connect((s) => {
            try { window.article_pane.show_article_preview(title, url, thumbnail_url, category_id); } catch (GLib.Error e) { }
        });

        if (target_col == -1) {
            if (window.prefs.category == "topten") {
                target_col = next_column_index;
                next_column_index = (next_column_index + 1) % window.layout_manager.columns.length;
            } else {
                target_col = 0;
                int random_noise = window.rng.int_range(0, 11);
                int best_score = window.layout_manager.column_heights[0] + random_noise;
                for (int i = 1; i < window.layout_manager.columns.length; i++) {
                    random_noise = window.rng.int_range(0, 11);
                    int score = window.layout_manager.column_heights[i] + random_noise;
                    if (score < best_score) { best_score = score; target_col = i; }
                }
            }
        }
        
        try {
            string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
            if (dbg != null && dbg.length > 0) {
                window.append_debug_log("APPENDING CARD: target_col=" + target_col.to_string() + " title=" + title);
            }
        } catch (GLib.Error e) { }
        long _ts = (long) GLib.get_monotonic_time();
        // Attach debug hooks to the created widget so we can observe parent changes and disposals
        try {
            article_card.root.notify.connect((obj, pspec) => {
            });
        } catch (GLib.Error e) { }
        // Note: cannot reliably connect to dispose; rely on notify("parent") to track unparenting

        window.layout_manager.columns[target_col].append(article_card.root);

        // Debug: log number of children in target column after append
        try {
            int child_count = 0;
            var c = window.layout_manager.columns[target_col].get_first_child();
            while (c != null) {
                child_count += 1;
                c = c.get_next_sibling();
            }
        } catch (GLib.Error e) { }

        int estimated_card_h = img_h + 120;
        window.layout_manager.column_heights[target_col] += estimated_card_h + 12;

        if (window.loading_state != null && window.loading_state.initial_phase) window.mark_initial_items_populated();
    }
        
        public void load_more_articles() {
            if (remaining_articles == null || remaining_articles_index >= remaining_articles.length) {
                if (load_more_button != null) {
                    load_more_button.add_css_class("fade-out");
                    Timeout.add(300, () => {
                        if (load_more_button != null) {
                            var parent = load_more_button.get_parent() as Gtk.Box;
                            if (parent != null) {
                                parent.remove(load_more_button);
                            }
                            load_more_button = null;
                            
                            if (window.loading_state.loading_container == null || !window.loading_state.loading_container.get_visible()) {
                                show_end_of_feed_message();
                            }
                        }
                        return false;
                    });
                }
                return;
            }
            
            int articles_to_load = int.min(10, remaining_articles.length - remaining_articles_index);
            
            for (int i = 0; i < articles_to_load; i++) {
                var article = remaining_articles[remaining_articles_index + i];
                article_buffer.add(article);
                add_item_immediate_to_column(article.title, article.url, article.thumbnail_url, article.category_id, -1, null, article.source_name, true);
            }
            
            remaining_articles_index += articles_to_load;
            
            if (load_more_button != null) {
                load_more_button.add_css_class("fade-out");
                Timeout.add(300, () => {
                    if (load_more_button != null) {
                        var parent = load_more_button.get_parent() as Gtk.Box;
                        if (parent != null) {
                            parent.remove(load_more_button);
                        }
                        load_more_button = null;
                    }
                    
                    if (remaining_articles_index < remaining_articles.length) {
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
            if (load_more_button != null) return;
            
            if (window.loading_state.loading_container != null && window.loading_state.loading_container.get_visible()) {
                return;
            }
            
            load_more_button = new Gtk.Button.with_label("Load more articles");
            load_more_button.add_css_class("suggested-action");
            load_more_button.add_css_class("pill");
            load_more_button.set_margin_top(20);
            load_more_button.set_margin_bottom(20);
            load_more_button.set_halign(Gtk.Align.CENTER);
            
            load_more_button.clicked.connect(() => {
            load_more_button.set_label("Loading...");
                load_more_button.set_sensitive(false);
                load_more_button.remove_css_class("suggested-action");
                load_more_button.add_css_class("loading");
                
                Timeout.add(150, () => {
                    load_more_articles();
                    return false;
                });
            });
            
            var children = window.content_box.observe_children();
            for (uint i = 0; i < children.get_n_items(); i++) {
                var child = children.get_item(i) as Gtk.Widget;
                if (child is Gtk.Label) {
                    var lbl = child as Gtk.Label;
                    var txt = lbl.get_label();
                    if (txt == "<b>No more articles</b>" || txt == "No more articles") {
                        window.content_box.remove(lbl);
                        break;
                    }
                }
            }

            load_more_button.add_css_class("fade-out");
            window.content_box.append(load_more_button);
            
            Timeout.add(50, () => {
                load_more_button.remove_css_class("fade-out");
                load_more_button.add_css_class("fade-in");
                return false;
            });
        }

        // Ensure any existing load-more button is removed and cleared.
        public void clear_load_more_button() {
            if (load_more_button == null) return;
            try {
                var parent = load_more_button.get_parent() as Gtk.Box;
                if (parent != null) {
                    parent.remove(load_more_button);
                }
            } catch (GLib.Error e) { }
            load_more_button = null;
        }

        // Public query so other managers can know whether a load-more
        // button is currently present. This avoids races where two
        // managers append conflicting UI elements (button vs end label).
        public bool has_load_more_button() {
            return load_more_button != null;
        }

        // Public helper to clear all article state and destroy article widgets
        public void clear_articles() {
            // Clear article buffer
            if (article_buffer != null) {
                article_buffer.clear();
            }

            // Clear remaining articles array
            remaining_articles = null;
            remaining_articles_index = 0;
            articles_shown = 0;

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
            next_column_index = 0;
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
            try {
                if (window != null && window.layout_manager != null && window.layout_manager.columns != null) {
                    for (int col = 0; col < window.layout_manager.columns.length; col++) {
                        var column = window.layout_manager.columns[col];
                        if (column != null) {
                            Gtk.Widget? child = column.get_first_child();
                            int removed_count = 0;
                            while (child != null) {
                                Gtk.Widget? next = child.get_next_sibling();
                                try { column.remove(child); } catch (GLib.Error e) { }
                                try { child.unparent(); } catch (GLib.Error e) { }
                                removed_count++;
                                child = next;
                            }
                            try {
                                if (removed_count > 0) {
                                    stderr.printf("DEBUG: clear_articles() removed %d widgets from column %d\n", removed_count, col);
                                }
                            } catch (GLib.Error e) { }
                        }
                    }

                    // Reset column heights to keep layout state consistent
                    try {
                        if (window.layout_manager.column_heights != null) {
                            for (int i = 0; i < window.layout_manager.column_heights.length; i++) {
                                window.layout_manager.column_heights[i] = 0;
                            }
                        }
                    } catch (GLib.Error e) { }
                }
            } catch (GLib.Error e) { }
        }
        
        private void show_end_of_feed_message() {
            try { if (window.loading_state != null) window.loading_state.show_end_of_feed_message(); } catch (GLib.Error e) { }
        }
    }
}
