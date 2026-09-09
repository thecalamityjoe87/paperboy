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

// Podcast show detail dialog: same content/layout as PodcastPane (cover,
// title/author/description, subscribe toggle, scrollable episode list) but
// as a modal Adw.Dialog instead of a docked sheet. Used on the Find Podcasts
// page, where users are actively comparing search results rather than doing
// something else alongside a persistent mini-pane.
//
// Built fresh per show() call (mirrors ShareDialog's static-show pattern)
// rather than reused like PodcastPane, so there's no cycle risk in any
// closure below capturing `show`/`playback`/`parent_window`.
public class PodcastDetailDialog : GLib.Object {
    private delegate void VoidFunc();

    public static void show(NewsWindow? window, Managers.PodcastPlaybackManager playback, Paperboy.PodcastShow show, Gtk.Window parent_window) {
        var dialog = new Adw.Dialog();
        dialog.set_content_width(720);
        dialog.set_content_height(560);
        dialog.set_title(show.title);

        // "See more" pushes a second page onto this with a slide transition
        // and its own automatic back button (via Adw.HeaderBar), instead of
        // a tooltip or growing the main page's scroll region.
        var nav_view = new Adw.NavigationView();

        var episode_play_buttons = new Gee.HashMap<int64?, Gtk.Button>();
        // Explicit hash/equal funcs: Gee.HashMap<int64?, V> without them
        // defaults to pointer identity on the boxed key, not value
        // equality, so has_key()/get() would never match a freshly-boxed
        // int64 with the same value as an existing key.
        var episode_rows = new Gee.HashMap<int64?, Gtk.Widget>((v) => { return (uint) v; }, (a, b) => { return a == b; });
        var episode_new_badges = new Gee.HashMap<int64?, Gtk.Widget>((v) => { return (uint) v; }, (a, b) => { return a == b; });

        // Cover/title/author/description/subscribe stay fixed at the top -
        // only the episode list below scrolls. The description is capped
        // at 4 lines with its own "See more" page, so the header never
        // grows tall enough to need scrolling itself.
        var root = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
        root.set_margin_start(24);
        root.set_margin_end(24);
        root.set_margin_top(20);
        root.set_margin_bottom(16);

        var header_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 16);

        var cover_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        cover_box.set_hexpand(false);
        cover_box.set_vexpand(false);
        cover_box.set_halign(Gtk.Align.START);
        cover_box.set_valign(Gtk.Align.START);
        cover_box.add_css_class("podcast-pane-cover");
        cover_box.set_overflow(Gtk.Overflow.HIDDEN);
        // Pins cover_box at exactly 96x96 regardless of what the loaded
        // cover image's own natural size turns out to be - see
        // FixedSizeLayoutUtils for why set_size_request() alone isn't
        // enough.
        Paperboy.FixedSizeLayoutUtils.apply(cover_box, 96, 96);

        var cover_image = new Gtk.Picture();
        cover_image.set_hexpand(true);
        cover_image.set_vexpand(true);
        cover_image.set_halign(Gtk.Align.FILL);
        cover_image.set_valign(Gtk.Align.FILL);
        cover_image.set_size_request(96, 96);
        cover_image.set_content_fit(Gtk.ContentFit.COVER);
        cover_image.set_keep_aspect_ratio(false);
        cover_image.set_can_shrink(true);
        cover_image.add_css_class("podcast-pane-cover");
        cover_box.append(cover_image);
        header_row.append(cover_box);

        if (window != null && show.image_url != null && show.image_url.length > 0) {
            window.image_manager.load_image_async(cover_image, show.image_url, 96, 96);
        }

        var title_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);
        title_box.set_hexpand(true);
        title_box.set_valign(Gtk.Align.START);

        var title_label = new Gtk.Label(show.title);
        title_label.add_css_class("title-2");
        title_label.set_xalign(0);
        title_label.set_wrap(true);
        title_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        // Without max_width_chars, a wrapped label's natural size is its
        // *unwrapped* width, which would push the dialog wider instead of
        // actually wrapping - this forces it to wrap to whatever width
        // title_box's hexpand actually gives it. hexpand+halign(FILL) on
        // the label itself (not just title_box) keeps that width from
        // being recomputed from the label's own text - without it, the
        // gap next to the cover art visibly shifted depending on the
        // title/description text since each label's own natural-size
        // request could pull title_box's allocated width around.
        title_label.set_max_width_chars(1);
        title_label.set_hexpand(true);
        title_label.set_halign(Gtk.Align.FILL);
        title_box.append(title_label);

        var author_label = new Gtk.Label(show.author ?? "");
        author_label.add_css_class("article-card-time");
        author_label.set_xalign(0);
        author_label.set_wrap(true);
        author_label.set_max_width_chars(1);
        author_label.set_hexpand(true);
        author_label.set_halign(Gtk.Align.FILL);
        author_label.set_visible(show.author != null && show.author.length > 0);
        title_box.append(author_label);

        string? desc = show.description != null ? stripHtmlUtils.strip_html(show.description).strip() : null;
        var description_label = new Gtk.Label(desc ?? "");
        description_label.add_css_class("dim-label");
        description_label.add_css_class("caption");
        description_label.set_xalign(0);
        description_label.set_wrap(true);
        description_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        description_label.set_max_width_chars(1);
        description_label.set_hexpand(true);
        description_label.set_halign(Gtk.Align.FILL);
        description_label.set_lines(4);
        description_label.set_ellipsize(Pango.EllipsizeMode.END);
        description_label.set_margin_top(4);
        description_label.set_visible(desc != null && desc.length > 0);
        title_box.append(description_label);

        // Rough heuristic for "probably got truncated by the 4-line cap
        // above" - good enough to decide whether "See more" is worth
        // showing without measuring the actual Pango layout.
        if (desc != null && desc.length > 220) {
            var see_more_button = new Gtk.Button.with_label("See more");
            see_more_button.add_css_class("flat");
            see_more_button.add_css_class("caption");
            see_more_button.set_halign(Gtk.Align.END);
            see_more_button.clicked.connect(() => {
                nav_view.push(build_description_page(show.title, desc));
            });
            title_box.append(see_more_button);
        }

        header_row.append(title_box);

        var subscribe_button = new Gtk.Button();
        subscribe_button.set_valign(Gtk.Align.START);
        subscribe_button.add_css_class("pill");

        VoidFunc update_subscribe_state = () => {
            bool subscribed = Paperboy.PodcastSubscriptionStore.get_instance().is_subscribed(show.feed_id);
            subscribe_button.set_label(subscribed ? "Subscribed" : "Subscribe");
            if (subscribed) {
                subscribe_button.remove_css_class("suggested-action");
            } else {
                subscribe_button.add_css_class("suggested-action");
            }
        };
        header_row.append(subscribe_button);

        // "Subscribed" is wider than "Subscribe" - without a locked width,
        // toggling subscription state changes the button's own width,
        // which (since it's a non-expanding sibling of title_box in
        // header_row) eats into title_box's available width and reflows
        // the description text next to the cover art, even though the
        // button isn't anywhere near that text visually. Lock the width
        // to whichever label is widest so toggling never reflows the row.
        subscribe_button.set_label("Subscribed");
        int subscribe_min_w, subscribe_nat_w;
        subscribe_button.measure(Gtk.Orientation.HORIZONTAL, -1, out subscribe_min_w, out subscribe_nat_w, null, null);
        subscribe_button.set_size_request(subscribe_nat_w, -1);

        update_subscribe_state();

        subscribe_button.clicked.connect(() => {
            var store = Paperboy.PodcastSubscriptionStore.get_instance();
            if (store.is_subscribed(show.feed_id)) {
                store.unsubscribe(show.feed_id);
            } else {
                store.subscribe(show);
            }
            update_subscribe_state();
        });

        var close_button = new Gtk.Button.from_icon_name("window-close-symbolic");
        close_button.add_css_class("flat");
        close_button.add_css_class("circular");
        close_button.set_valign(Gtk.Align.START);
        close_button.set_tooltip_text("Close");
        close_button.clicked.connect(() => { dialog.close(); });
        header_row.append(close_button);

        root.append(header_row);

        var separator = new Gtk.Separator(Gtk.Orientation.HORIZONTAL);
        separator.add_css_class("section-divider");
        root.append(separator);

        var episode_scroller = new Gtk.ScrolledWindow();
        episode_scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        episode_scroller.set_vexpand(true);
        episode_scroller.set_overlay_scrolling(false);
        episode_scroller.set_margin_start(24);
        episode_scroller.set_margin_end(24);
        episode_scroller.set_margin_bottom(16);

        var episode_list_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        episode_scroller.set_child(episode_list_box);

        var episode_spinner = new Gtk.Spinner();
        episode_spinner.set_size_request(24, 24);
        episode_spinner.set_halign(Gtk.Align.CENTER);
        episode_spinner.set_margin_top(20);
        episode_spinner.start();

        var episode_empty_label = new Gtk.Label("No episodes found for this show.");
        episode_empty_label.add_css_class("dim-label");
        episode_empty_label.set_margin_top(20);
        episode_empty_label.set_halign(Gtk.Align.CENTER);
        episode_empty_label.set_visible(false);

        var page_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        page_box.append(root);
        page_box.append(episode_scroller);
        page_box.append(episode_spinner);
        page_box.append(episode_empty_label);

        var main_page = new Adw.NavigationPage(page_box, show.title);
        nav_view.push(main_page);

        dialog.set_child(nav_view);
        dialog.present(parent_window);

        VoidFunc update_episode_play_buttons = () => {
            var current = playback.get_current_episode();
            bool playing = playback.is_playing();
            foreach (var entry in episode_play_buttons.entries) {
                bool is_current = current != null && current.episode_id == entry.key;
                entry.value.set_icon_name(is_current && playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic");
            }
        };

        ulong state_handler = playback.playback_state_changed.connect(() => { update_episode_play_buttons(); });
        ulong changed_handler = playback.episode_changed.connect(() => { update_episode_play_buttons(); });

        var playback_state_store = Paperboy.PodcastPlaybackStateStore.get_instance();
        ulong played_handler = playback_state_store.episode_played_changed.connect((episode_id) => {
            mark_row_played(episode_id, episode_rows, episode_new_badges);
        });

        dialog.closed.connect(() => {
            playback.disconnect(state_handler);
            playback.disconnect(changed_handler);
            playback_state_store.disconnect(played_handler);
        });

        render_episodes.begin(window, playback, show, episode_list_box, episode_spinner,
            episode_empty_label, episode_play_buttons, episode_rows, episode_new_badges, update_episode_play_buttons);
    }

    private static async void render_episodes(NewsWindow? window, Managers.PodcastPlaybackManager playback,
            Paperboy.PodcastShow show, Gtk.Box episode_list_box,
            Gtk.Spinner episode_spinner, Gtk.Label episode_empty_label,
            Gee.HashMap<int64?, Gtk.Button> episode_play_buttons,
            Gee.HashMap<int64?, Gtk.Widget> episode_rows, Gee.HashMap<int64?, Gtk.Widget> episode_new_badges,
            owned VoidFunc update_episode_play_buttons) {
        Gee.ArrayList<Paperboy.PodcastEpisode> episodes;

        if (show.from_direct_feed && window != null) {
            var resolver = Paperboy.PodcastFeedResolver.get_instance();
            SourceFunc callback = render_episodes.callback;
            Gee.ArrayList<Paperboy.PodcastEpisode>? resolved = null;
            resolver.fetch_episodes(show.feed_url, show.title, show.image_url, window.session, (result) => {
                resolved = result;
                callback();
            });
            yield;
            episodes = resolved ?? new Gee.ArrayList<Paperboy.PodcastEpisode>();
        } else if (show.from_direct_feed) {
            episodes = new Gee.ArrayList<Paperboy.PodcastEpisode>();
        } else {
            var service = Paperboy.PodcastIndexService.get_instance();
            SourceFunc callback = render_episodes.callback;
            Gee.ArrayList<Paperboy.PodcastEpisode>? resolved = null;
            service.episodes_for_feed(show.feed_id, 20, (result) => {
                resolved = result;
                callback();
            });
            yield;
            episodes = resolved ?? new Gee.ArrayList<Paperboy.PodcastEpisode>();
        }

        episode_spinner.stop();
        episode_spinner.set_visible(false);

        if (episodes.size == 0) {
            episode_empty_label.set_visible(true);
            return;
        }

        playback.set_episode_queue(episodes);

        var state_store = Paperboy.PodcastPlaybackStateStore.get_instance();
        // Read the *previous* last-viewed time before this open overwrites
        // it below - that's what decides which episodes are "new".
        int64 previous_last_viewed = state_store.get_last_viewed(show.feed_id);

        foreach (var episode in episodes) {
            bool is_new = !state_store.is_episode_played(episode.episode_id) && episode_is_after(episode, previous_last_viewed);
            episode_list_box.append(build_episode_row(episode, show, playback, episode_play_buttons, episode_rows, episode_new_badges, is_new));
        }
        update_episode_play_buttons();

        state_store.mark_show_viewed(show.feed_id);
    }

    // Best-effort: episodes with an unparseable/missing published date are
    // never flagged "new" rather than guessed at.
    private static bool episode_is_after(Paperboy.PodcastEpisode episode, int64 unix_seconds) {
        var dt = DateUtils.parse_published_datetime(episode.published);
        if (dt == null) return false;
        return dt.to_unix() > unix_seconds;
    }

    private static Gtk.Widget build_episode_row(Paperboy.PodcastEpisode episode, Paperboy.PodcastShow show,
            Managers.PodcastPlaybackManager playback, Gee.HashMap<int64?, Gtk.Button> episode_play_buttons,
            Gee.HashMap<int64?, Gtk.Widget> episode_rows, Gee.HashMap<int64?, Gtk.Widget> episode_new_badges,
            bool is_new) {
        var row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 10);
        row.add_css_class("podcast-episode-row");
        row.set_margin_top(8);
        row.set_margin_bottom(8);
        row.set_margin_end(8);

        bool is_played = Paperboy.PodcastPlaybackStateStore.get_instance().is_episode_played(episode.episode_id);
        if (is_played) row.add_css_class("podcast-episode-played");

        var text_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
        text_box.set_hexpand(true);
        text_box.set_valign(Gtk.Align.CENTER);

        var title_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);

        var episode_title_label = new Gtk.Label(episode.title);
        episode_title_label.add_css_class("article-card-title");
        episode_title_label.set_xalign(0);
        episode_title_label.set_ellipsize(Pango.EllipsizeMode.END);
        title_row.append(episode_title_label);

        Gtk.Widget? new_badge = null;
        if (is_new) {
            var badge = new Gtk.Label("New");
            badge.add_css_class("podcast-episode-new-badge");
            badge.set_valign(Gtk.Align.CENTER);
            title_row.append(badge);
            new_badge = badge;
        }
        text_box.append(title_row);

        string duration_text = format_duration(episode.duration_seconds);
        string when_text = DateUtils.time_ago(episode.published);
        var meta_label = new Gtk.Label(duration_text.length > 0 ? "%s · %s".printf(when_text, duration_text) : when_text);
        meta_label.add_css_class("article-card-time");
        meta_label.set_xalign(0);
        text_box.append(meta_label);

        row.append(text_box);

        var play_button = new Gtk.Button.from_icon_name("media-playback-start-symbolic");
        play_button.add_css_class("flat");
        play_button.add_css_class("circular");
        play_button.set_valign(Gtk.Align.CENTER);
        play_button.clicked.connect(() => {
            var current = playback.get_current_episode();
            if (current != null && current.episode_id == episode.episode_id) {
                playback.toggle_play_pause();
            } else {
                if (episode.audio_url == null || episode.audio_url.length == 0) return;
                if (episode.show_title == null || episode.show_title.length == 0) episode.show_title = show.title;
                if (episode.image_url == null || episode.image_url.length == 0) episode.image_url = show.image_url;
                playback.load_and_play(episode, NewsPreferences.get_instance().podcast_playback_speed);
            }
        });
        row.append(play_button);
        episode_play_buttons.set(episode.episode_id, play_button);
        episode_rows.set(episode.episode_id, row);
        if (new_badge != null) episode_new_badges.set(episode.episode_id, new_badge);

        return row;
    }

    // Live-updates one already-built row when its episode gets marked
    // played elsewhere (e.g. its own play button was just clicked) -
    // avoids re-rendering the whole episode list for a single row change.
    private static void mark_row_played(int64 episode_id, Gee.HashMap<int64?, Gtk.Widget> episode_rows,
            Gee.HashMap<int64?, Gtk.Widget> episode_new_badges) {
        Gtk.Widget? row = episode_rows.has_key(episode_id) ? episode_rows.get(episode_id) : null;
        if (row != null) row.add_css_class("podcast-episode-played");

        Gtk.Widget? badge = episode_new_badges.has_key(episode_id) ? episode_new_badges.get(episode_id) : null;
        if (badge != null) badge.set_visible(false);
    }

    private static Adw.NavigationPage build_description_page(string title, string full_text) {
        var label = new Gtk.Label(full_text);
        label.set_xalign(0);
        label.set_valign(Gtk.Align.START);
        label.set_wrap(true);
        label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        label.set_max_width_chars(1);
        label.set_margin_start(24);
        label.set_margin_end(24);
        label.set_margin_top(16);
        label.set_margin_bottom(16);

        var scroller = new Gtk.ScrolledWindow();
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        scroller.set_vexpand(true);
        scroller.set_child(label);

        var toolbar_view = new Adw.ToolbarView();
        toolbar_view.add_top_bar(new Adw.HeaderBar());
        toolbar_view.set_content(scroller);

        return new Adw.NavigationPage(toolbar_view, title);
    }

    private static string format_duration(int64 seconds) {
        if (seconds <= 0) return "";
        int64 mins = seconds / 60;
        int64 hrs = mins / 60;
        mins = mins % 60;
        if (hrs > 0) return "%lldh %lldm".printf(hrs, mins);
        return "%lldm".printf(mins);
    }
}
