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

// Controller for the Podcasts page - renders into ContentView's shared
// hero_container/category_sections_container rather than a separate view.
namespace Managers {
    public class PodcastManager : GLib.Object {
        // Curated display names matched case-insensitively against whatever get_categories() returns.
        private const string[] PREFERRED_CATEGORY_NAMES = { "Technology", "News", "Comedy", "True Crime", "Business", "Health" };

        private const int TRENDING_MAX = 40;
        private const int CATEGORY_ROW_MAX = 12;
        // Category rows revealed per "Show More Categories" click.
        private const int SHOW_MORE_BATCH = 6;

        private weak NewsWindow? window;
        private weak ContentView? content_view;
        private Managers.PodcastPlaybackManager playback;
        private weak PodcastPane? podcast_pane;

        // Cached across visits so returning to Podcasts re-renders instead of refetching.
        private Gee.ArrayList<Paperboy.PodcastShow>? cached_hero_shows = null;

        private class CategoryRowCache : GLib.Object {
            public string name;
            public Gee.ArrayList<Paperboy.PodcastShow> shows;
        }
        private Gee.ArrayList<CategoryRowCache>? cached_rows = null;

        // All known category names, and which already have a row - persists across visits.
        private Gee.ArrayList<string>? cached_available_categories = null;
        private Gee.HashSet<string> shown_category_names = new Gee.HashSet<string>();
        private Gtk.Button? show_more_button = null;
        private Gtk.Spinner? show_more_button_spinner = null;
        private Gtk.Label? show_more_button_label = null;

        // Dedupes shows that appear in more than one category row; reset per prepare_containers() call.
        private Gee.HashSet<int64?> displayed_feed_ids = new Gee.HashSet<int64?>();

        // Podcast search state (see search()/run_search()/render_search_results()).
        private const int SEARCH_DEBOUNCE_MS = 400;
        private uint search_timeout_id = 0;
        // Guards against a slow, superseded search response clobbering a newer one.
        private int64 search_request_id = 0;
        // De-dupes SearchEntry's clear icon firing both search-changed and stop-search for one click.
        private string last_search_query = "";

        // Set in show(); async callbacks check still_owns_view() before touching shared containers.
        private FetchContext? podcast_ctx = null;

        // Whether the current show() call's hero/discovery fetch is still outstanding.
        private bool pending_hero_load = false;
        private bool pending_rows_load = false;

        public PodcastManager(NewsWindow? window, ContentView content_view, Managers.PodcastPlaybackManager playback, PodcastPane? podcast_pane) {
            this.window = window;
            this.content_view = content_view;
            this.playback = playback;
            this.podcast_pane = podcast_pane;
        }

        // Fetches the show's episode list and plays the newest one - used by the play badge.
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
            // Invalidates any fetch still in flight from the news pipeline or a previous visit.
            podcast_ctx = FetchContext.begin_new(window);

            prepare_containers();
            if (window != null) window.update_content_header_now();

            pending_hero_load = cached_hero_shows == null;
            pending_rows_load = cached_rows == null;
            if (pending_hero_load || pending_rows_load) show_podcast_spinner();

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

        private void show_podcast_spinner() {
            if (content_view == null || content_view.loading_container == null
                || content_view.loading_spinner == null || content_view.loading_label == null) return;
            content_view.loading_label.set_text("Loading podcasts...");
            content_view.loading_container.set_visible(true);
            content_view.loading_spinner.start();
            // Hide the podcast-specific containers directly, not just main_content_container.
            if (content_view.podcasts_hero_title != null) content_view.podcasts_hero_title.set_visible(false);
            content_view.hero_container.set_visible(false);
            content_view.category_sections_container.set_visible(false);
        }

        private void hide_podcast_spinner() {
            if (content_view == null || content_view.loading_container == null || content_view.loading_spinner == null) return;
            content_view.loading_container.set_visible(false);
            content_view.loading_spinner.stop();
            if (content_view.podcasts_hero_title != null) content_view.podcasts_hero_title.set_visible(true);
            content_view.hero_container.set_visible(true);
            content_view.category_sections_container.set_visible(true);
        }

        private void maybe_hide_podcast_spinner() {
            if (!pending_hero_load && !pending_rows_load) hide_podcast_spinner();
        }

        // Debounced live PodcastIndex search - replaces the discover view while active.
        public void search(string query) {
            string trimmed = query.strip();
            if (trimmed == last_search_query) return;
            last_search_query = trimmed;

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
            var ctx = podcast_ctx;

            // Enter "search mode": hide hero/discovery rows, show podcast_search_flow instead.
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

            // A query matching a known category name browses that category instead of text search.
            string? matched_category = cached_available_categories != null
                ? find_matching_category(cached_available_categories, query)
                : null;

            if (matched_category != null) {
                service.trending_podcasts(TRENDING_MAX, matched_category, (shows) => {
                    render_search_results(ctx, this_request, query, shows);
                });
            } else {
                service.search_podcasts(query, (shows) => {
                    render_search_results(ctx, this_request, query, shows);
                });
            }
        }

        private void render_search_results(FetchContext? ctx, int64 request_id, string query, Gee.ArrayList<Paperboy.PodcastShow> shows) {
            if (request_id != search_request_id) return; // superseded by a newer search or a clear
            if (ctx == null || !ctx.still_owns_view()) return; // user has since left Podcasts entirely
            if (content_view == null || content_view.podcast_search_flow == null) return;

            clear_flowbox_children(content_view.podcast_search_flow);

            var seen = new Gee.HashSet<int64?>();
            foreach (var show in shows) {
                if (seen.contains(show.feed_id)) continue;
                seen.add(show.feed_id);

                var card = new PodcastCard.for_show(show);
                if (show.image_url != null && show.image_url.length > 0) {
                    // Search surfaces more publishers than discover, so some cover art needs trimming.
                    Paperboy.PodcastImageUtils.load_trimmed_async(card.image, show.image_url, PodcastCard.IMAGE_WIDTH, PodcastCard.IMAGE_HEIGHT);
                }
                PodcastCard.wire_interactions(card.root, card, false, show.feed_id, 0, playback, (feed_id) => {
                    if (window != null) PodcastDetailDialog.show(window, playback, show, window);
                }, null, (feed_id) => { play_latest_episode(show); });
                content_view.podcast_search_flow.append(card.root);
            }

            if (window != null && window.animation_manager != null) {
                var anim_mgr = window.animation_manager;
                var flow = content_view.podcast_search_flow;
                GLib.Idle.add(() => {
                    var cards = new Gee.ArrayList<Gtk.Widget>();
                    Gtk.Widget? cell = flow.get_first_child();
                    while (cell != null) {
                        cards.add(cell);
                        cell = cell.get_next_sibling();
                    }
                    anim_mgr.animate_cards_entrance_batch(cards);
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

        // Restores the discover view when the search box is cleared - re-renders from cache via show().
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

        // Hides every other page's containers, then claims this page's own
        // two (hero_container, category_sections_container) for Podcasts.
        private void prepare_containers() {
            if (content_view == null) return;

            content_view.hide_all_pages();
            // Same as MagazineLibraryManager - Podcasts skips begin_fetch(),
            // so clear any empty-state/error overlay from the previous view.
            if (window != null && window.loading_state != null) window.loading_state.hide_error_message();

            content_view.podcasts_hero_title.set_visible(true);
            content_view.hero_container.set_visible(true);
            content_view.category_sections_container.set_visible(true);
            content_view.hero_frontpage_separator.set_visible(true);

            // Widget already removed by hide_all_pages() - drop the stale reference too.
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

        // Gtk.FlowBox doesn't share a base type with Gtk.Box, so it needs its own helper.
        private void clear_flowbox_children(Gtk.FlowBox box) {
            Gtk.Widget? child = box.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                box.remove(child);
                child = next;
            }
        }

        private void load_hero_row() {
            var ctx = podcast_ctx;
            var service = Paperboy.PodcastIndexService.get_instance();
            service.trending_podcasts(4, null, (shows) => {
                cached_hero_shows = shows;
                if (ctx == null || !ctx.still_owns_view()) return;
                render_hero_cards(shows);
                pending_hero_load = false;
                maybe_hide_podcast_spinner();
            });
        }

        private void render_hero_cards(Gee.ArrayList<Paperboy.PodcastShow> shows) {
            if (content_view == null) return;
            clear_children(content_view.hero_container);

            // hero_container is a homogeneous 4-wide box, so only height needs to be set explicitly;
            // width computed directly (not via LayoutManager.estimate_column_width()'s tighter clamp).
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
                    if (window != null) PodcastDetailDialog.show(window, playback, show, window);
                }, (feed_id) => { play_latest_episode(show); });
                content_view.hero_container.append(hero.root);
            }

            // Same fade-in ArticleCard grids use, deferred to idle so widgets are realized first.
            if (window != null && window.animation_manager != null) {
                var anim_mgr = window.animation_manager;
                GLib.Idle.add(() => {
                    var cards = new Gee.ArrayList<Gtk.Widget>();
                    Gtk.Widget? child = content_view.hero_container.get_first_child();
                    while (child != null) {
                        cards.add(child);
                        child = child.get_next_sibling();
                    }
                    anim_mgr.animate_cards_entrance_batch(cards);
                    return false;
                });
            }
        }

        // Waits for every preferred category's shows before building any rows, so the section reveals at once.
        private void load_discovery_rows() {
            var ctx = podcast_ctx;
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

                if (rows.size == 0) {
                    if (ctx != null && ctx.still_owns_view()) render_show_more_button();
                    pending_rows_load = false;
                    maybe_hide_podcast_spinner();
                    return;
                }

                int pending = rows.size;
                foreach (var row in rows) {
                    service.trending_podcasts(CATEGORY_ROW_MAX, row.name, (shows) => {
                        row.shows = shows;
                        pending--;
                        if (pending > 0) return;

                        if (ctx == null || !ctx.still_owns_view()) return;
                        foreach (var r in rows) build_category_row(r.name, r.shows);
                        render_show_more_button();
                        pending_rows_load = false;
                        maybe_hide_podcast_spinner();
                    });
                }
            });
        }

        // Keeps the button spinning until every fetch in the batch resolves, then reveals all rows at once.
        private void reveal_more_categories() {
            if (content_view == null || cached_available_categories == null || cached_rows == null) return;
            if (show_more_button == null) return;

            var next_batch = new Gee.ArrayList<string>();
            foreach (var name in cached_available_categories) {
                if (shown_category_names.contains(name)) continue;
                next_batch.add(name);
                if (next_batch.size >= SHOW_MORE_BATCH) break;
            }
            if (next_batch.size == 0) return;

            set_show_more_button_loading(true);

            var ctx = podcast_ctx;
            var service = Paperboy.PodcastIndexService.get_instance();
            var pending_rows = new Gee.ArrayList<CategoryRowCache>();
            int pending = next_batch.size;

            foreach (var name in next_batch) {
                shown_category_names.add(name);
                var row = new CategoryRowCache();
                row.name = name;
                row.shows = new Gee.ArrayList<Paperboy.PodcastShow>();
                pending_rows.add(row);

                service.trending_podcasts(CATEGORY_ROW_MAX, name, (shows) => {
                    row.shows = shows;
                    pending--;
                    if (pending > 0) return;

                    foreach (var r in pending_rows) cached_rows.add(r);
                    if (ctx == null || !ctx.still_owns_view()) return;

                    foreach (var r in pending_rows) build_category_row(r.name, r.shows);

                    if (show_more_button != null) {
                        content_view.category_sections_container.remove(show_more_button);
                        show_more_button = null;
                    }
                    render_show_more_button();
                });
            }
        }

        // Mirrors ContentView's load-more-articles button loading state.
        private void set_show_more_button_loading(bool loading) {
            if (show_more_button == null || show_more_button_label == null || show_more_button_spinner == null) return;
            if (loading) {
                show_more_button_label.set_text("Loading...");
                show_more_button_spinner.set_visible(true);
                show_more_button_spinner.start();
                show_more_button.set_sensitive(false);
                show_more_button.remove_css_class("suggested-action");
                show_more_button.add_css_class("loading");
            } else {
                show_more_button_label.set_text("Show More Categories");
                show_more_button_spinner.stop();
                show_more_button_spinner.set_visible(false);
                show_more_button.set_sensitive(true);
                show_more_button.remove_css_class("loading");
                show_more_button.add_css_class("suggested-action");
            }
        }

        private void render_show_more_button() {
            if (content_view == null || cached_available_categories == null) return;

            bool any_remaining = false;
            foreach (var name in cached_available_categories) {
                if (!shown_category_names.contains(name)) { any_remaining = true; break; }
            }
            if (!any_remaining) return;

            // Reference cycle via the clicked closure is harmless - PodcastManager lives for the app's lifetime.
            show_more_button = new Gtk.Button();
            show_more_button.add_css_class("suggested-action");
            show_more_button.add_css_class("pill");
            show_more_button.set_margin_top(20);
            show_more_button.set_margin_bottom(20);
            show_more_button.set_halign(Gtk.Align.CENTER);

            var button_content = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            button_content.set_halign(Gtk.Align.CENTER);
            show_more_button_spinner = new Gtk.Spinner();
            show_more_button_spinner.set_visible(false);
            button_content.append(show_more_button_spinner);
            show_more_button_label = new Gtk.Label("Show More Categories");
            button_content.append(show_more_button_label);
            show_more_button.set_child(button_content);

            show_more_button.clicked.connect(() => {
                reveal_more_categories();
            });
            content_view.category_sections_container.append(show_more_button);
        }

        // Case-insensitive match against the backend's own casing.
        private string? find_matching_category(Gee.ArrayList<string> available, string preferred_name) {
            foreach (var name in available) {
                if (name.down() == preferred_name.down()) return name;
            }
            return null;
        }

        private void build_category_row(string category_name, Gee.ArrayList<Paperboy.PodcastShow> cached_shows) {
            if (content_view == null) return;

            var section = new CategorySection(window, category_name, "podcast:" + category_name.down());
            // Faint divider between category sections, matching Front Page's own rows.
            section.wrapper.add_css_class("frontpage-section-divider");
            section.wrapper.set_data("podcast-category-section", section);
            section.wrapper.set_data("podcast-category-name", category_name);
            content_view.category_sections_container.append(section.wrapper);

            foreach (var show in cached_shows) add_show_card(section, show);

            if (window != null && window.animation_manager != null) {
                var anim_mgr = window.animation_manager;
                var row = section.row;
                GLib.Idle.add(() => {
                    var cards = new Gee.ArrayList<Gtk.Widget>();
                    Gtk.Widget? child = row.get_first_child();
                    while (child != null) {
                        cards.add(child);
                        child = child.get_next_sibling();
                    }
                    anim_mgr.animate_cards_entrance_batch(cards);
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
                if (window != null) PodcastDetailDialog.show(window, playback, show, window);
            }, null, (feed_id) => { play_latest_episode(show); });
            section.add_card(card.root);
        }
    }
}
