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

/**
 * Controller for the Podcasts page. Unlike a normal news category, this
 * isn't routed through FetchNewsController/ArticleManager/LayoutManager
 * (podcast shows don't fit that pipeline's article shape) - but it
 * deliberately renders into ContentView's own shared containers
 * (hero_container, category_sections_container) rather than a separate
 * page/view, so Podcasts inherits the exact same header, margins,
 * scroll-fade chrome, and 4-wide hero-card layout that Top Ten already
 * uses via those same containers (see HeroCard.for_topten,
 * ArticleManager.TOPTEN_HERO_MAX_HEIGHT, LayoutManager.create_and_place_hero_card).
 *
 * Leaving Podcasts for a news category runs the normal fetch_news() path,
 * whose LayoutManager.prepare_for_new_fetch() already clears hero_container
 * and category_sections_container unconditionally - so no podcast-specific
 * teardown is needed (see appWindow.vala's category_selected handler).
 * Conversely, returning to Podcasts always clears and rebuilds this
 * controller's own two containers itself (prepare_containers()) before
 * re-rendering from cache, since content_view is shared with the news
 * pipeline and may have been repopulated with news content since the
 * last Podcasts visit.
 *
 * Clicking a hero or show card opens PodcastPane (a bottom sheet with the
 * show's full info, a subscribe toggle, and its episode list) rather than
 * playing anything directly - the pane itself resolves episodes via
 * PodcastIndexService.episodes_for_feed() and starts playback when the
 * user taps a specific one.
 */
namespace Managers {
    public class PodcastManager : GLib.Object {
        // Curated display names to look for among whatever
        // PodcastIndexService.get_categories() actually returns - not
        // hardcoded category IDs (the backend has no numeric category
        // concept in this contract, only names). Any name not present in
        // the backend's response is simply skipped, so this degrades
        // gracefully rather than showing an empty/broken row.
        private const string[] PREFERRED_CATEGORY_NAMES = { "Technology", "News", "Comedy", "True Crime", "Business", "Health" };

        private const int TRENDING_MAX = 40;
        private const int CATEGORY_ROW_MAX = 12;
        // How many additional category rows "Show More Categories" reveals
        // per click.
        private const int SHOW_MORE_BATCH = 6;

        private weak NewsWindow? window;
        private weak ContentView? content_view;
        private Managers.PodcastPlaybackManager playback;
        private weak PodcastPane? podcast_pane;

        // Cached across visits so navigating away to a news category and
        // back doesn't re-hit the backend or refetch - only re-render into
        // the freshly-cleared shared containers. Null until the first
        // successful fetch of each.
        private Gee.ArrayList<Paperboy.PodcastShow>? cached_hero_shows = null;

        private class CategoryRowCache : GLib.Object {
            public string name;
            public Gee.ArrayList<Paperboy.PodcastShow> shows;
        }
        private Gee.ArrayList<CategoryRowCache>? cached_rows = null;

        // Every category name the backend knows about (from
        // PodcastIndexService.get_categories(), cached 24h server-side
        // anyway) and which of them already have a row - both persist
        // across prepare_containers() calls (unlike cached_rows' rendered
        // widgets) so "Show More Categories" remembers how far the user
        // had expanded even after navigating away and back.
        private Gee.ArrayList<string>? cached_available_categories = null;
        private Gee.HashSet<string> shown_category_names = new Gee.HashSet<string>();
        private Gtk.Button? show_more_button = null;

        // PodcastIndex shows are commonly tagged with more than one
        // category (e.g. a show under both "Arts" and "Books"), so trending-
        // by-category for two related categories can return the same show
        // in both - without this, that show's card would render twice on
        // the same page. Reset per prepare_containers() call (see show()),
        // not persisted across visits like shown_category_names: whichever
        // row processes a given show first (curated rows in
        // PREFERRED_CATEGORY_NAMES order, then "Show More" batches in
        // whatever order the backend lists categories) keeps it, and later
        // rows with the same show just skip it - deterministic since row
        // build order is always the same.
        private Gee.HashSet<int64?> displayed_feed_ids = new Gee.HashSet<int64?>();

        // Podcast search state (see search()/run_search()/render_search_results()).
        private const int SEARCH_DEBOUNCE_MS = 400;
        private uint search_timeout_id = 0;
        // Incremented on every new search (and on clear) so a slow,
        // superseded network response can't clobber a newer one or the
        // restored discover view - same guard shape as PodcastPane's
        // open_request_id.
        private int64 search_request_id = 0;

        public PodcastManager(NewsWindow? window, ContentView content_view, Managers.PodcastPlaybackManager playback, PodcastPane? podcast_pane) {
            this.window = window;
            this.content_view = content_view;
            this.playback = playback;
            this.podcast_pane = podcast_pane;
        }

        // Fetches the show's episode list and plays the newest one - used
        // by the play badge (unlike a plain card click, which just opens
        // PodcastPane). Mirrors PodcastPane.open_for_show's fetch branching
        // so direct-feed shows work too.
        public void play_latest_episode(Paperboy.PodcastShow show) {
            if (show.from_direct_feed && window != null) {
                var resolver = Paperboy.PodcastFeedResolver.get_instance();
                resolver.fetch_episodes(show.feed_url, show.title, show.image_url, window.session, (episodes) => {
                    start_playing_latest(show, episodes);
                });
            } else if (show.from_direct_feed) {
                // No window/session to resolve the feed with - nothing to play.
            } else {
                var service = Paperboy.PodcastIndexService.get_instance();
                service.episodes_for_feed(show.feed_id, 20, (episodes) => {
                    start_playing_latest(show, episodes);
                });
            }
        }

        private void start_playing_latest(Paperboy.PodcastShow show, Gee.ArrayList<Paperboy.PodcastEpisode> episodes) {
            if (episodes.size == 0) return;
            playback.set_episode_queue(episodes);
            var episode = episodes[0];
            if (episode.show_title == null || episode.show_title.length == 0) episode.show_title = show.title;
            if (episode.image_url == null || episode.image_url.length == 0) episode.image_url = show.image_url;
            playback.load_and_play(episode, NewsPreferences.get_instance().podcast_playback_speed);
        }

        public void show() {
            prepare_containers();
            if (window != null) window.update_content_header_now();

            if (cached_hero_shows != null) {
                render_hero_cards(cached_hero_shows);
            } else {
                load_hero_row();
            }

            if (cached_rows != null) {
                foreach (var row in cached_rows) build_category_row(row.name, row.shows);
                render_show_more_button();
            } else {
                load_discovery_rows();
            }
        }

        // Called from appWindow.vala's search_entry.search_changed handler
        // while the user is on the Podcasts page. Unlike news search (pure
        // client-side filtering of already-rendered cards), this is a live
        // PodcastIndex network query, so it's debounced and replaces the
        // discover view entirely while active rather than filtering it in
        // place - avoids a confusing double-behavior of local filtering
        // immediately followed by the network results replacing it moments
        // later.
        public void search(string query) {
            string trimmed = query.strip();

            if (search_timeout_id != 0) {
                GLib.Source.remove(search_timeout_id);
                search_timeout_id = 0;
            }

            if (trimmed.length == 0) {
                search_request_id++; // invalidate any in-flight response
                show_discover_view();
                return;
            }

            search_timeout_id = Timeout.add(SEARCH_DEBOUNCE_MS, () => {
                search_timeout_id = 0;
                run_search(trimmed);
                return false;
            });
        }

        private void run_search(string query) {
            if (content_view == null) return;
            search_request_id++;
            int64 this_request = search_request_id;

            // Enter "search mode": hide the hero row and discovery rows,
            // show podcast_search_flow (its own dedicated grid, not the
            // shared article columns_row - see ContentView) in their place.
            if (content_view.podcasts_hero_title != null) content_view.podcasts_hero_title.set_visible(false);
            clear_children(content_view.hero_container);
            content_view.hero_container.set_visible(false);
            clear_children(content_view.category_sections_container);
            content_view.category_sections_container.set_visible(false);
            if (content_view.hero_frontpage_separator != null) content_view.hero_frontpage_separator.set_visible(false);
            show_more_button = null; // already removed by the clear above

            if (content_view.podcast_search_flow != null) {
                clear_flowbox_children(content_view.podcast_search_flow);
                content_view.podcast_search_flow.set_visible(true);
            }

            if (content_view.category_subtitle != null) {
                content_view.category_subtitle.set_label("Searching for \"%s\"...".printf(query));
                content_view.category_subtitle.set_visible(true);
            }

            var service = Paperboy.PodcastIndexService.get_instance();

            // If the query exactly matches a known category name, browse
            // that category via trending-by-category instead of the
            // free-text title search - PodcastIndex's search endpoint
            // matches show titles/descriptions, not category tags, so
            // typing e.g. "Comedy" wouldn't otherwise reliably surface
            // comedy shows.
            string? matched_category = cached_available_categories != null
                ? find_matching_category(cached_available_categories, query)
                : null;

            if (matched_category != null) {
                service.trending_podcasts(TRENDING_MAX, matched_category, (shows) => {
                    render_search_results(this_request, query, shows);
                });
            } else {
                service.search_podcasts(query, (shows) => {
                    render_search_results(this_request, query, shows);
                });
            }
        }

        private void render_search_results(int64 request_id, string query, Gee.ArrayList<Paperboy.PodcastShow> shows) {
            if (request_id != search_request_id) return; // superseded by a newer search or a clear
            if (content_view == null || content_view.podcast_search_flow == null) return;

            clear_flowbox_children(content_view.podcast_search_flow);

            var seen = new Gee.HashSet<int64?>();
            foreach (var show in shows) {
                if (seen.contains(show.feed_id)) continue;
                seen.add(show.feed_id);

                var card = new PodcastCard.for_show(show);
                if (show.image_url != null && show.image_url.length > 0) {
                    // Search surfaces far more publishers than discover, so
                    // some cover art needs trimming - see PodcastImageUtils.
                    Paperboy.PodcastImageUtils.load_trimmed_async(card.image, show.image_url, PodcastCard.IMAGE_WIDTH, PodcastCard.IMAGE_HEIGHT);
                }
                PodcastCard.wire_interactions(card.root, card, false, show.feed_id, 0, playback, (feed_id) => {
                    if (podcast_pane != null) podcast_pane.open_for_show(show);
                }, null, (feed_id) => { play_latest_episode(show); });
                content_view.podcast_search_flow.append(card.root);
            }

            if (window != null && window.animation_manager != null) {
                var anim_mgr = window.animation_manager;
                var flow = content_view.podcast_search_flow;
                GLib.Idle.add(() => {
                    uint index = 0;
                    Gtk.Widget? cell = flow.get_first_child();
                    while (cell != null) {
                        anim_mgr.animate_card_entrance_stagger(cell, index, 24);
                        index++;
                        cell = cell.get_next_sibling();
                    }
                    return false;
                });
            }

            if (content_view.category_subtitle != null) {
                string label_text = shows.size == 0
                    ? "No podcasts found matching \"%s\"".printf(query)
                    : "Search results: found %d %s matching \"%s\"".printf(shows.size, shows.size == 1 ? "podcast" : "podcasts", query);
                content_view.category_subtitle.set_label(label_text);
                content_view.category_subtitle.set_visible(true);
            }
        }

        // Restores the normal discover view (hero + discovery rows) when
        // the search box is cleared - re-renders from cache via show(), so
        // this doesn't re-hit the network unless the very first visit's
        // fetches never completed.
        private void show_discover_view() {
            if (content_view != null && content_view.podcast_search_flow != null) {
                clear_flowbox_children(content_view.podcast_search_flow);
                content_view.podcast_search_flow.set_visible(false);
            }
            if (content_view != null && content_view.category_subtitle != null) {
                content_view.category_subtitle.set_visible(false);
            }
            show();
        }

        // Clears and re-shows the two shared ContentView containers this
        // page uses - mirrors what LayoutManager.prepare_for_new_fetch()/
        // teardown_category_sections() do for news categories, since this
        // controller owns rendering into the same widgets independently of
        // that pipeline.
        private void prepare_containers() {
            if (content_view == null) return;

            if (content_view.podcasts_hero_title != null) content_view.podcasts_hero_title.set_visible(true);

            clear_children(content_view.hero_container);
            content_view.hero_container.set_visible(true);
            if (content_view.podcast_search_flow != null) {
                clear_flowbox_children(content_view.podcast_search_flow);
                content_view.podcast_search_flow.set_visible(false);
            }

            clear_children(content_view.category_sections_container);
            content_view.category_sections_container.set_visible(true);
            if (content_view.hero_frontpage_separator != null) content_view.hero_frontpage_separator.set_visible(true);

            // columns_row is the shared flat article grid (Front Page, My
            // Feed, Top Ten, category browsing) - this controller never
            // populates it, so leftover articles from before switching to
            // Podcasts stayed visible underneath if not cleared here too.
            if (content_view.columns_row != null) {
                clear_flowbox_children(content_view.columns_row);
                content_view.columns_row.set_visible(false);
            }

            // Sports populates its own container entirely outside
            // LayoutManager's normal clearing (see SportsScoresController),
            // so leaving Sports for Podcasts otherwise left its score cards
            // and separators sitting visible underneath the podcasts hero
            // row - clear/hide them the same way SportsScoresController's
            // own hide_sports_scores() does.
            if (content_view.sports_scores_container != null) {
                clear_children(content_view.sports_scores_container);
                content_view.sports_scores_container.set_visible(false);
            }
            if (content_view.hero_scores_separator != null) content_view.hero_scores_separator.set_visible(false);
            if (content_view.scores_articles_separator != null) content_view.scores_articles_separator.set_visible(false);

            // "Load more articles" (see ArticleManager/ContentView) is a
            // news-pagination concept appended into content_box, a
            // container this controller otherwise never touches - if it
            // was showing right before the user switched to Podcasts, it
            // leaked here too (same class of bug as the Sports leak
            // above), and its click handler does nothing meaningful
            // outside the news pipeline anyway.
            content_view.hide_load_more_button();
            // The widget itself already got removed by clear_children()
            // above (it's a child of category_sections_container); drop
            // the stale reference too so render_show_more_button() always
            // creates a fresh one instead of touching a destroyed widget.
            show_more_button = null;

            displayed_feed_ids.clear();
        }

        private void clear_children(Gtk.Box box) {
            Gtk.Widget? child = box.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                box.remove(child);
                child = next;
            }
        }

        // Gtk.FlowBox doesn't share a base type with Gtk.Box (and Vala
        // doesn't support overloading), so columns_row (a FlowBox) needs
        // its own differently-named helper.
        private void clear_flowbox_children(Gtk.FlowBox box) {
            Gtk.Widget? child = box.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                box.remove(child);
                child = next;
            }
        }

        private void load_hero_row() {
            var service = Paperboy.PodcastIndexService.get_instance();
            service.trending_podcasts(4, null, (shows) => {
                cached_hero_shows = shows;
                render_hero_cards(shows);
            });
        }

        private void render_hero_cards(Gee.ArrayList<Paperboy.PodcastShow> shows) {
            if (content_view == null) return;
            clear_children(content_view.hero_container);

            // hero_container is a homogeneous 4-wide Gtk.Box (see
            // ContentView), so each card's actual allocated width already
            // works out to (content_width - gaps) / 4 regardless of what we
            // request here - only height needs to be set explicitly.
            // Deliberately NOT using LayoutManager.estimate_column_width():
            // its 160-280 clamp is tuned for ArticleCard's small grid
            // thumbnails and would cap these hero cards well below their
            // actual (wider) allocated cell on a normal-width window,
            // making them look flatter/smaller than the row they sit in.
            // Compute the true per-card width directly instead, with a
            // small +10% bump so the cards read as slightly larger than a
            // plain square, per request.
            int content_w = window != null ? window.estimate_content_width() : 1200;
            int base_size = (content_w - 3 * Managers.LayoutManager.COL_SPACING) / 4;
            int hero_size = (int)(base_size * 1.1);
            if (hero_size < 220) hero_size = 220;
            if (hero_size > 420) hero_size = 420;

            foreach (var show in shows) {
                var hero = new PodcastHeroCard(show, hero_size);
                hero.root.set_size_request(-1, hero_size);
                if (window != null && show.image_url != null && show.image_url.length > 0) {
                    window.image_manager.load_image_async(hero.image, show.image_url, hero_size, hero_size);
                }
                PodcastHeroCard.wire_interactions(hero.root, hero, show.feed_id, playback, (feed_id) => {
                    if (podcast_pane != null) podcast_pane.open_for_show(show);
                }, (feed_id) => { play_latest_episode(show); });
                content_view.hero_container.append(hero.root);
            }

            // Same fade/slide-up stagger ArticleCard grids use (see
            // AnimationManager.animate_card_entrance_stagger) - deferred
            // to an idle callback so widgets are realized before animating.
            if (window != null && window.animation_manager != null) {
                var anim_mgr = window.animation_manager;
                GLib.Idle.add(() => {
                    uint index = 0;
                    Gtk.Widget? child = content_view.hero_container.get_first_child();
                    while (child != null) {
                        anim_mgr.animate_card_entrance_stagger(child, index, 40);
                        index++;
                        child = child.get_next_sibling();
                    }
                    return false;
                });
            }
        }

        private void load_discovery_rows() {
            var service = Paperboy.PodcastIndexService.get_instance();
            service.get_categories((available_categories) => {
                cached_available_categories = available_categories;

                var rows = new Gee.ArrayList<CategoryRowCache>();
                foreach (var preferred_name in PREFERRED_CATEGORY_NAMES) {
                    string? matched = find_matching_category(available_categories, preferred_name);
                    if (matched == null) continue;
                    var row = new CategoryRowCache();
                    row.name = matched;
                    row.shows = new Gee.ArrayList<Paperboy.PodcastShow>();
                    rows.add(row);
                    shown_category_names.add(matched);
                }
                cached_rows = rows;

                foreach (var row in rows) {
                    build_category_row(row.name, row.shows);
                    fetch_category_shows(row);
                }

                render_show_more_button();
            });
        }

        // Adds up to SHOW_MORE_BATCH more category rows drawn from
        // whatever PodcastIndexService.get_categories() returned that
        // isn't already shown, then re-renders the button (hidden once
        // nothing remains).
        private void reveal_more_categories() {
            if (content_view == null || cached_available_categories == null || cached_rows == null) return;

            if (show_more_button != null) {
                content_view.category_sections_container.remove(show_more_button);
                show_more_button = null;
            }

            var next_batch = new Gee.ArrayList<string>();
            foreach (var name in cached_available_categories) {
                if (shown_category_names.contains(name)) continue;
                next_batch.add(name);
                if (next_batch.size >= SHOW_MORE_BATCH) break;
            }

            foreach (var name in next_batch) {
                shown_category_names.add(name);
                var row = new CategoryRowCache();
                row.name = name;
                row.shows = new Gee.ArrayList<Paperboy.PodcastShow>();
                cached_rows.add(row);
                build_category_row(row.name, row.shows);
                fetch_category_shows(row);
            }

            render_show_more_button();
        }

        private void render_show_more_button() {
            if (content_view == null || cached_available_categories == null) return;

            bool any_remaining = false;
            foreach (var name in cached_available_categories) {
                if (!shown_category_names.contains(name)) { any_remaining = true; break; }
            }
            if (!any_remaining) return;

            // self.show_more_button -> clicked closure -> self is a real
            // reference cycle, but PodcastManager is constructed once for
            // the app's whole lifetime (owned by NewsWindow, mirrors
            // PodcastPlaybackManager/PodcastPlayerBar) - same accepted
            // reasoning as PodcastPlayerBar's own doc comment: harmless
            // since NewsWindow keeps this object alive regardless.
            show_more_button = new Gtk.Button.with_label("Show More Categories");
            show_more_button.add_css_class("suggested-action");
            show_more_button.add_css_class("pill");
            show_more_button.set_margin_top(20);
            show_more_button.set_margin_bottom(20);
            show_more_button.set_halign(Gtk.Align.CENTER);
            show_more_button.clicked.connect(() => {
                reveal_more_categories();
            });
            content_view.category_sections_container.append(show_more_button);
        }

        // Case-insensitive match against whatever casing the backend
        // returns, since PodcastIndex's own category names aren't
        // guaranteed to match our curated list's casing exactly.
        private string? find_matching_category(Gee.ArrayList<string> available, string preferred_name) {
            foreach (var name in available) {
                if (name.down() == preferred_name.down()) return name;
            }
            return null;
        }

        private void fetch_category_shows(CategoryRowCache row) {
            var service = Paperboy.PodcastIndexService.get_instance();
            service.trending_podcasts(CATEGORY_ROW_MAX, row.name, (shows) => {
                row.shows = shows;
                // The section for this row may already have been torn down
                // (user navigated away before this fetch resolved, or came
                // back and prepare_containers() rebuilt a fresh one) -
                // find_category_section_by_name below re-locates it by
                // walking category_sections_container's current children
                // rather than holding a stale CategorySection reference.
                var section = find_live_section(row.name);
                if (section == null) return;
                foreach (var show in shows) add_show_card(section, show);
            });
        }

        private CategorySection? find_live_section(string category_name) {
            if (content_view == null) return null;
            Gtk.Widget? child = content_view.category_sections_container.get_first_child();
            while (child != null) {
                var section = child.get_data<CategorySection>("podcast-category-section");
                if (section != null && child.get_data<string>("podcast-category-name") == category_name) {
                    return section;
                }
                child = child.get_next_sibling();
            }
            return null;
        }

        private void build_category_row(string category_name, Gee.ArrayList<Paperboy.PodcastShow> cached_shows) {
            if (content_view == null) return;

            var section = new CategorySection(window, category_name, "podcast:" + category_name.down());
            // Faint divider between category sections, matching Front
            // Page's own rows (see .frontpage-section-divider in
            // style.css) - its :first-child rule skips the border on the
            // first section automatically.
            section.wrapper.add_css_class("frontpage-section-divider");
            section.wrapper.set_data("podcast-category-section", section);
            section.wrapper.set_data("podcast-category-name", category_name);
            content_view.category_sections_container.append(section.wrapper);

            foreach (var show in cached_shows) add_show_card(section, show);

            if (window != null && window.animation_manager != null) {
                var anim_mgr = window.animation_manager;
                var row = section.row;
                GLib.Idle.add(() => {
                    uint index = 0;
                    Gtk.Widget? child = row.get_first_child();
                    while (child != null) {
                        anim_mgr.animate_card_entrance_stagger(child, index, 30);
                        index++;
                        child = child.get_next_sibling();
                    }
                    return false;
                });
            }
        }

        private void add_show_card(CategorySection section, Paperboy.PodcastShow show) {
            if (displayed_feed_ids.contains(show.feed_id)) return;
            displayed_feed_ids.add(show.feed_id);

            var card = new PodcastCard.for_show(show);
            if (window != null && show.image_url != null && show.image_url.length > 0) {
                window.image_manager.load_image_async(card.image, show.image_url, PodcastCard.IMAGE_WIDTH, PodcastCard.IMAGE_HEIGHT);
            }
            PodcastCard.wire_interactions(card.root, card, false, show.feed_id, 0, playback, (feed_id) => {
                if (podcast_pane != null) podcast_pane.open_for_show(show);
            }, null, (feed_id) => { play_latest_episode(show); });
            section.add_card(card.root);
        }
    }
}
