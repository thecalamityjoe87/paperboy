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

// Controller for the "My Library" podcasts page - the user's subscribed
// shows, not discovery. An "Up Next" hero row (in-progress episodes first,
// then each show's newest unplayed one) over a "Your Shows" grid. Renders
// into the same ContentView containers as PodcastManager's Find Podcasts
// page, so it inherits that page's header, margins and hero layout.
namespace Managers {
    public class PodcastLibraryManager : GLib.Object {
        // Sidebar/prefs routing id.
        public const string CATEGORY_ID = "podcasts_library";

        private const int EPISODES_PER_SHOW = 10;
        private const int UP_NEXT_MAX = 4;
        // Episode lists are refetched on a visit once older than this -
        // returning within it re-renders instantly from cache.
        private const int64 EPISODE_CACHE_SECONDS = 15 * 60;

        private weak NewsWindow? window;
        private weak ContentView? content_view;
        private Managers.PodcastPlaybackManager playback;

        private class ShowEntry : GLib.Object {
            public Gee.ArrayList<Paperboy.PodcastEpisode> episodes = new Gee.ArrayList<Paperboy.PodcastEpisode>();
            public int64 fetched_at = 0;
        }
        // Keyed by feed_id. Explicit hash/equal funcs - see SidebarManager's
        // podcast_new_counts for why Gee needs them for boxed int64 keys.
        private Gee.HashMap<int64?, ShowEntry> episode_cache =
            new Gee.HashMap<int64?, ShowEntry>((v) => { return (uint) v; }, (a, b) => { return a == b; });

        private class UpNextItem : GLib.Object {
            public Paperboy.PodcastSubscription sub;
            public Paperboy.PodcastEpisode episode;
            public bool is_new;
            public int64 published;
        }

        // Set in show(); async callbacks check still_owns_view() before touching shared containers.
        private FetchContext? library_ctx = null;
        // De-dupes SearchEntry's clear icon firing both search-changed and stop-search for one click.
        private string last_search_query = "";

        public delegate void LoadDone();

        public PodcastLibraryManager(NewsWindow? window, ContentView content_view, Managers.PodcastPlaybackManager playback) {
            this.window = window;
            this.content_view = content_view;
            this.playback = playback;

            // Subscribing elsewhere (Find Podcasts, the sidebar's "Add a
            // Podcast") or removing a show from this page's own menus has to
            // be reflected here - re-render if the page is on screen.
            var store = Paperboy.PodcastSubscriptionStore.get_instance();
            store.subscription_added.connect(() => { rerender_if_active(); });
            store.subscription_removed.connect((feed_id) => {
                episode_cache.unset(feed_id);
                rerender_if_active();
            });
        }

        private bool is_active() {
            return window != null && window.prefs.category == CATEGORY_ID
                && library_ctx != null && library_ctx.still_owns_view();
        }

        private void rerender_if_active() {
            Idle.add(() => {
                if (is_active() && last_search_query.length == 0) show();
                return false;
            });
        }

        public void show() {
            library_ctx = FetchContext.begin_new(window);
            last_search_query = "";

            prepare_containers();
            if (window != null) window.update_content_header_now();

            var subs = Paperboy.PodcastSubscriptionStore.get_instance().get_all_subscriptions();
            if (subs.size == 0) {
                render_empty_state();
                return;
            }

            var stale = new Gee.ArrayList<Paperboy.PodcastSubscription>();
            foreach (var sub in subs) {
                if (episodes_stale(sub.feed_id) || sub.category == null) stale.add(sub);
            }

            if (stale.size == 0) {
                render();
                return;
            }

            // Only block on the spinner when nothing is cached at all - with
            // a previous render to show, refresh it in the background.
            bool any_cached = stale.size < subs.size;
            if (any_cached) {
                render();
            } else {
                show_spinner();
            }

            var ctx = library_ctx;
            int pending = stale.size;
            foreach (var sub in stale) {
                refresh_show(sub, () => {
                    pending--;
                    if (pending > 0) return;
                    if (ctx == null || !ctx.still_owns_view()) return;
                    // A search typed while this was loading owns the view now.
                    if (last_search_query.length > 0) return;
                    if (!any_cached) hide_spinner();
                    prepare_containers();
                    render();
                });
            }
        }

        private bool episodes_stale(int64 feed_id) {
            var entry = episode_cache.get(feed_id);
            return entry == null || GLib.get_real_time() / 1000000 - entry.fetched_at > EPISODE_CACHE_SECONDS;
        }

        // Fetches whichever of a show's recent episodes (if the cached list
        // is stale) and its category (if it was subscribed before categories
        // were stored) it needs. `done` fires once both have landed,
        // success or not.
        private void refresh_show(Paperboy.PodcastSubscription sub, owned LoadDone done) {
            int64 feed_id = sub.feed_id;
            string show_title = sub.title;
            string? show_image = sub.image_url;
            bool needs_episodes = episodes_stale(feed_id);
            bool needs_category = sub.category == null;
            int pending = (needs_episodes ? 1 : 0) + (needs_category ? 1 : 0);
            if (pending == 0) {
                done();
                return;
            }

            Paperboy.PodcastIndexService.EpisodeListCallback on_episodes = (episodes) => {
                var entry = new ShowEntry();
                foreach (var ep in episodes) {
                    if (ep.show_title == null || ep.show_title.length == 0) ep.show_title = show_title;
                    if (ep.image_url == null || ep.image_url.length == 0) ep.image_url = show_image;
                    entry.episodes.add(ep);
                }
                entry.episodes.sort((a, b) => {
                    int64 pa = published_unix(a), pb = published_unix(b);
                    return pa > pb ? -1 : (pa < pb ? 1 : 0);
                });
                entry.fetched_at = GLib.get_real_time() / 1000000;
                episode_cache.set(feed_id, entry);
                pending--;
                if (pending == 0) done();
            };

            if (!needs_episodes) {
                // Cached list is fresh - only the category is missing.
            } else if (feed_id > 0) {
                Paperboy.PodcastIndexService.get_instance().episodes_for_feed(feed_id, EPISODES_PER_SHOW, (owned) on_episodes);
            } else if (window != null && window.session != null) {
                // Added by direct feed URL - no PodcastIndex id to query.
                Paperboy.PodcastFeedResolver.get_instance().fetch_episodes(sub.feed_url, show_title, show_image, window.session, (episodes) => {
                    on_episodes(episodes);
                });
            } else {
                on_episodes(new Gee.ArrayList<Paperboy.PodcastEpisode>());
            }

            if (!needs_category) return;
            if (window == null || window.session == null || sub.feed_url.length == 0) {
                pending--;
                if (pending == 0) done();
                return;
            }
            // The feed's own <itunes:category> - works the same for
            // PodcastIndex-discovered and direct-feed shows.
            Paperboy.PodcastFeedResolver.get_instance().resolve_show(sub.feed_url, window.session, (success, show, error_message) => {
                // A failed fetch stays NULL so it's retried next visit; a
                // feed that simply has no category is stored as "".
                if (success && show != null) {
                    Paperboy.PodcastSubscriptionStore.get_instance().update_category(feed_id, show.category ?? "");
                }
                pending--;
                if (pending == 0) done();
            });
        }

        private static int64 published_unix(Paperboy.PodcastEpisode episode) {
            var dt = DateUtils.parse_published_datetime(episode.published);
            return dt != null ? dt.to_unix() : 0;
        }

        // Same "started" thresholds as PodcastPane's episode rows.
        private static bool is_in_progress(int64 episode_id) {
            var progress = Paperboy.PodcastPlaybackStateStore.get_instance().get_episode_progress(episode_id);
            return progress != null && progress.duration_ns > 0
                && progress.position_ns > 5000000000
                && progress.position_ns + 10000000000 < progress.duration_ns;
        }

        private ShowEntry? entry_for(int64 feed_id) {
            return episode_cache.get(feed_id);
        }

        private void render() {
            if (content_view == null) return;
            var subs = Paperboy.PodcastSubscriptionStore.get_instance().get_all_subscriptions();
            render_up_next(subs);
            render_shows_grid(subs);
        }

        // ---- Up Next hero row ----

        private Gee.ArrayList<UpNextItem> pick_up_next(Gee.ArrayList<Paperboy.PodcastSubscription> subs) {
            var state_store = Paperboy.PodcastPlaybackStateStore.get_instance();
            var last_session = state_store.get_last_session();
            int64 last_session_id = last_session != null ? last_session.episode.episode_id : 0;

            var in_progress = new Gee.ArrayList<UpNextItem>();
            var unplayed = new Gee.ArrayList<UpNextItem>();
            foreach (var sub in subs) {
                var entry = entry_for(sub.feed_id);
                if (entry == null) continue;
                int64 last_viewed = state_store.get_last_viewed(sub.feed_id);

                UpNextItem? started = null;
                UpNextItem? newest_unplayed = null;
                foreach (var ep in entry.episodes) {
                    // load_and_play() marks an episode played the moment it
                    // starts, so in-progress ones have to be found first.
                    if (started == null && is_in_progress(ep.episode_id)) {
                        started = make_item(sub, ep, false);
                    } else if (newest_unplayed == null && !state_store.is_episode_played(ep.episode_id)) {
                        var item = make_item(sub, ep, false);
                        item.is_new = item.published > last_viewed;
                        newest_unplayed = item;
                    }
                }
                // One card per show, like Apple's Up Next - an episode
                // already underway beats a newer one not yet started.
                if (started != null) {
                    in_progress.add(started);
                } else if (newest_unplayed != null) {
                    unplayed.add(newest_unplayed);
                }
            }

            // Most recently listened first (the last session is the only
            // recency we store), then newest release.
            in_progress.sort((a, b) => {
                if (a.episode.episode_id == last_session_id) return -1;
                if (b.episode.episode_id == last_session_id) return 1;
                return a.published > b.published ? -1 : (a.published < b.published ? 1 : 0);
            });
            unplayed.sort((a, b) => { return a.published > b.published ? -1 : (a.published < b.published ? 1 : 0); });

            var picked = new Gee.ArrayList<UpNextItem>();
            foreach (var item in in_progress) {
                if (picked.size >= UP_NEXT_MAX) break;
                picked.add(item);
            }
            foreach (var item in unplayed) {
                if (picked.size >= UP_NEXT_MAX) break;
                picked.add(item);
            }
            return picked;
        }

        private UpNextItem make_item(Paperboy.PodcastSubscription sub, Paperboy.PodcastEpisode ep, bool is_new) {
            var item = new UpNextItem();
            item.sub = sub;
            item.episode = ep;
            item.is_new = is_new;
            item.published = published_unix(ep);
            return item;
        }

        private void render_up_next(Gee.ArrayList<Paperboy.PodcastSubscription> subs) {
            clear_children(content_view.hero_container);
            var items = pick_up_next(subs);

            // Nothing to listen to (all caught up, or episodes still
            // loading) - drop the section rather than show an empty row.
            bool has_items = items.size > 0;
            content_view.podcasts_hero_title.set_visible(has_items);
            content_view.hero_container.set_visible(has_items);
            content_view.hero_frontpage_separator.set_visible(has_items);
            if (!has_items) return;

            // Same sizing as PodcastManager.render_hero_cards().
            int content_w = window != null ? window.estimate_content_width() : 1200;
            int base_size = (content_w - 3 * Managers.LayoutManager.COL_SPACING) / 4;
            int hero_size = (int)(base_size * 1.1);
            if (hero_size < 220) hero_size = 220;
            if (hero_size > 420) hero_size = 420;

            foreach (var item in items) {
                var show = item.sub.to_show();
                var episode = item.episode;
                var hero = new PodcastHeroCard.for_episode(show, episode, hero_size, item.is_new);
                hero.root.set_size_request(-1, hero_size);
                string? art = episode.image_url != null && episode.image_url.length > 0 ? episode.image_url : show.image_url;
                if (window != null && art != null && art.length > 0) {
                    window.image_manager.load_image_async(hero.image, art, hero_size, hero_size);
                }
                int64 feed_id = show.feed_id;
                PodcastHeroCard.wire_episode_interactions(hero.root, hero, playback,
                    (id) => { play_episode(feed_id, episode); },
                    (id) => { if (window != null) PodcastDetailDialog.show(window, playback, show, window); });
                content_view.hero_container.append(hero.root);
            }

            // hero_container is homogeneous - pad a short row with empty
            // columns so one or two cards keep a quarter-width each instead
            // of stretching across the whole page.
            for (int i = items.size; i < UP_NEXT_MAX; i++) {
                var spacer = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
                spacer.set_hexpand(true);
                content_view.hero_container.append(spacer);
            }

            animate_children(content_view.hero_container);
        }

        private void play_episode(int64 feed_id, Paperboy.PodcastEpisode episode) {
            if (episode.audio_url == null || episode.audio_url.length == 0) return;
            var entry = entry_for(feed_id);
            playback.load_and_play(episode, NewsPreferences.get_instance().podcast_playback_speed, entry != null ? entry.episodes : null);
        }

        // ---- Your Shows grid ----

        // Every subscribed show in one 4-column grid, most recently updated
        // first. A grid rather than per-category rows: a typical library is
        // small enough that most categories held a single show, and a lone
        // card stretched to fill its whole row.
        private void render_shows_grid(Gee.ArrayList<Paperboy.PodcastSubscription> subs) {
            clear_children(content_view.category_sections_container);

            var shows = new Gee.ArrayList<Paperboy.PodcastSubscription>();
            shows.add_all(subs);
            shows.sort((a, b) => {
                int64 la = latest_published(a.feed_id), lb = latest_published(b.feed_id);
                if (la != lb) return la > lb ? -1 : 1;
                return SortUtils.compare_titles(a.title, b.title);
            });

            // Same header look and spacing as CategorySection's rows.
            var wrapper = new Gtk.Box(Gtk.Orientation.VERTICAL, 20);
            wrapper.set_hexpand(true);

            var title = new Gtk.Label("");
            title.set_xalign(0);
            title.add_css_class("caption");
            title.set_markup("<span size='18000'><b>%s</b></span>".printf(GLib.Markup.escape_text(_("Your Shows").up())));
            wrapper.append(title);

            var flow = build_grid();
            var state_store = Paperboy.PodcastPlaybackStateStore.get_instance();
            foreach (var sub in shows) flow.append(build_show_card(sub, state_store, true));
            wrapper.append(flow);

            content_view.category_sections_container.append(wrapper);
            animate_children(flow);
        }

        // Configured like ContentView.podcast_search_flow: pinned at exactly
        // 4 homogeneous columns, so even one or two shows keep a normal
        // quarter-width card.
        private Gtk.FlowBox build_grid() {
            var flow = new Gtk.FlowBox();
            flow.set_halign(Gtk.Align.FILL);
            flow.set_valign(Gtk.Align.START);
            flow.set_hexpand(true);
            flow.set_vexpand(false);
            flow.set_homogeneous(true);
            flow.set_row_spacing(16);
            flow.set_column_spacing(16);
            flow.set_selection_mode(Gtk.SelectionMode.NONE);
            flow.set_min_children_per_line(4);
            flow.set_max_children_per_line(4);
            return flow;
        }

        private int64 latest_published(int64 feed_id) {
            var entry = entry_for(feed_id);
            if (entry == null || entry.episodes.size == 0) return 0;
            return published_unix(entry.episodes[0]);
        }

        // with_status: "<publisher> · <last updated>" subtitle and "N New"
        // badge - off for search results, which just match the library.
        private Gtk.Widget build_show_card(Paperboy.PodcastSubscription sub, Paperboy.PodcastPlaybackStateStore state_store, bool with_status) {
            var show = sub.to_show();
            var card = new PodcastCard.for_show(show);

            var entry = entry_for(sub.feed_id);
            if (with_status) {
                // Who makes it, and whether it's still active, at a glance.
                string when = entry != null && entry.episodes.size > 0 ? DateUtils.time_ago(entry.episodes[0].published) : "";
                string author = sub.author != null ? sub.author.strip() : "";
                if (author.length > 0 && when.length > 0) {
                    card.subtitle_label.set_text(_("%s · %s").printf(author, when));
                } else if (when.length > 0) {
                    card.subtitle_label.set_text(when);
                }

                if (entry != null) {
                    int64 last_viewed = state_store.get_last_viewed(sub.feed_id);
                    int new_count = 0;
                    foreach (var ep in entry.episodes) {
                        if (state_store.is_episode_played(ep.episode_id)) continue;
                        if (published_unix(ep) > last_viewed) new_count++;
                    }
                    card.show_new_count(new_count);
                }
            }

            if (window != null && show.image_url != null && show.image_url.length > 0) {
                window.image_manager.load_image_async(card.image, show.image_url, PodcastCard.IMAGE_WIDTH, PodcastCard.IMAGE_HEIGHT);
            }
            int64 feed_id = sub.feed_id;
            PodcastCard.wire_interactions(card.root, card, false, feed_id, 0, playback, (id) => {
                if (window != null) PodcastDetailDialog.show(window, playback, show, window);
            }, null, (id) => {
                var e = entry_for(feed_id);
                if (e != null && e.episodes.size > 0) play_episode(feed_id, e.episodes[0]);
            });
            return card.root;
        }

        // ---- Empty state ----

        private void render_empty_state() {
            content_view.podcasts_hero_title.set_visible(false);
            content_view.hero_container.set_visible(false);
            content_view.hero_frontpage_separator.set_visible(false);

            var status = new Adw.StatusPage();
            status.set_icon_name("audio-x-generic-symbolic");
            status.set_title(_("Your Library Is Empty"));
            status.set_description(_("Subscribe to shows and they'll appear here, with new episodes up top."));
            status.set_vexpand(true);

            var find_button = new Gtk.Button.with_label(_("Find Podcasts"));
            find_button.add_css_class("pill");
            find_button.add_css_class("suggested-action");
            find_button.set_halign(Gtk.Align.CENTER);
            // Reference cycle via the closure is harmless - this manager lives for the app's lifetime.
            find_button.clicked.connect(() => {
                if (window != null && window.sidebar_manager != null) {
                    window.sidebar_manager.handle_item_activation("podcasts", _("Find Podcasts"));
                }
            });
            status.set_child(find_button);

            content_view.category_sections_container.append(status);
        }

        // ---- Search: filters the library locally ----

        public void search(string query) {
            string trimmed = query.strip();
            if (trimmed == last_search_query) return;
            last_search_query = trimmed;

            if (trimmed.length == 0) {
                if (content_view != null && content_view.category_subtitle != null) {
                    content_view.category_subtitle.set_visible(false);
                }
                show();
                return;
            }
            if (content_view == null || content_view.podcast_search_flow == null) return;

            content_view.podcasts_hero_title.set_visible(false);
            clear_children(content_view.hero_container);
            content_view.hero_container.set_visible(false);
            clear_children(content_view.category_sections_container);
            content_view.category_sections_container.set_visible(false);
            content_view.hero_frontpage_separator.set_visible(false);

            var flow = content_view.podcast_search_flow;
            clear_flowbox_children(flow);
            flow.set_visible(true);

            var state_store = Paperboy.PodcastPlaybackStateStore.get_instance();
            string needle = trimmed.casefold();
            int matches = 0;
            foreach (var sub in Paperboy.PodcastSubscriptionStore.get_instance().get_all_subscriptions()) {
                bool hit = sub.title.casefold().contains(needle)
                    || (sub.author != null && sub.author.casefold().contains(needle))
                    || (sub.category != null && sub.category.casefold().contains(needle));
                if (!hit) continue;
                matches++;

                flow.append(build_show_card(sub, state_store, false));
            }
            animate_children(flow);

            if (content_view.category_subtitle != null) {
                content_view.category_subtitle.set_label(matches == 0
                    ? _("No shows in your library match \"%s\"").printf(trimmed)
                    : ngettext("%d show in your library matches \"%s\"", "%d shows in your library match \"%s\"", matches).printf(matches, trimmed));
                content_view.category_subtitle.set_visible(true);
            }
        }

        // ---- Shared container plumbing (mirrors PodcastManager) ----

        private void prepare_containers() {
            if (content_view == null) return;

            content_view.hide_all_pages();
            // Skips begin_fetch(), so clear any empty-state/error overlay from the previous view.
            if (window != null && window.loading_state != null) window.loading_state.hide_error_message();
            if (content_view.category_subtitle != null) content_view.category_subtitle.set_visible(false);

            content_view.podcasts_hero_title.set_markup(_("<span size='26000'><b>UP NEXT</b></span>"));
            content_view.podcasts_hero_title.set_visible(true);
            content_view.hero_container.set_visible(true);
            content_view.category_sections_container.set_visible(true);
            content_view.hero_frontpage_separator.set_visible(true);
        }

        private void show_spinner() {
            if (content_view == null || content_view.loading_container == null
                || content_view.loading_spinner == null || content_view.loading_label == null) return;
            content_view.loading_label.set_text(_("Loading your library..."));
            content_view.loading_container.set_visible(true);
            content_view.loading_spinner.start();
            ViewSession.current().on_close("loading-spinner", () => {
                if (window != null && window.loading_state != null) window.loading_state.close_spinner();
            });
            content_view.podcasts_hero_title.set_visible(false);
            content_view.hero_container.set_visible(false);
            content_view.category_sections_container.set_visible(false);
        }

        private void hide_spinner() {
            if (content_view == null || content_view.loading_container == null || content_view.loading_spinner == null) return;
            content_view.loading_container.set_visible(false);
            content_view.loading_spinner.stop();
        }

        private void animate_children(Gtk.Widget container) {
            if (window == null || window.animation_manager == null) return;
            var anim_mgr = window.animation_manager;
            ViewSession.view_idle(() => {
                var cards = new Gee.ArrayList<Gtk.Widget>();
                Gtk.Widget? child = container.get_first_child();
                while (child != null) {
                    cards.add(child);
                    child = child.get_next_sibling();
                }
                anim_mgr.animate_cards_entrance_batch(cards);
                return false;
            });
        }

        private void clear_children(Gtk.Box box) {
            Gtk.Widget? child = box.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                box.remove(child);
                child = next;
            }
        }

        private void clear_flowbox_children(Gtk.FlowBox box) {
            Gtk.Widget? child = box.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                box.remove(child);
                child = next;
            }
        }
    }
}
