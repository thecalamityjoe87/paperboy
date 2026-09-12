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

/**
 * Podcast show detail pane: cover art, title/author, description, a
 * subscribe toggle, and the show's episode list - tapping an episode plays
 * it via Managers.PodcastPlaybackManager. Slides up from the bottom edge of
 * the CONTENT view specifically (not the whole window, not the sidebar),
 * full width of that content column and capped to roughly a third of its
 * height (see resize_sheet()) so it reads as a peek/detail sheet rather
 * than a full-screen takeover.
 *
 * Built as a plain Gtk.Revealer (SLIDE_UP) mounted into root_overlay (see
 * appWindow.vala), the same hand-rolled "slide up from the bottom" idiom
 * ArticleSheet already uses - not Adw.BottomSheet. BottomSheet rounds the
 * sheet's top corners by default with no documented way to disable it, and
 * fighting that via a CSS override risked targeting the wrong internal
 * node; a plain Gtk.Box (styled here exactly like ArticlePane's own
 * .article-preview-panel - flat background + shadow, no rounding at all)
 * inside a Revealer sidesteps the problem entirely instead of overriding it.
 *
 * Unlike HeroCard/PodcastCard's per-instance widget classes, this is a
 * controller constructed exactly once for the app's whole lifetime (owned
 * by NewsWindow, mirrors PodcastPlayerBar) and reused across every
 * open_for_show() call by clearing and rebuilding its episode list each
 * time - so the static-function/set_data() closure-cycle discipline those
 * per-card classes use doesn't apply here for the same reason it doesn't
 * apply to PodcastPlayerBar: any closure below that captures `this` is
 * attached either to a widget this object permanently owns (harmless -
 * NewsWindow keeps this object alive until the process exits regardless)
 * or to PodcastPlaybackManager/PodcastSubscriptionStore, neither of which
 * this object holds a reference into a widget tree it also owns.
 */
// Holds what update_playing_episode_progress() needs to live-refresh one
// episode row - the meta label's non-duration portion (when_text) so it can
// rebuild the full "<when> · <time left>" string, and the episode's own
// listed duration as a fallback for when the live GStreamer duration isn't
// known yet.
private class EpisodeProgressRow : GLib.Object {
    public Gtk.ProgressBar bar;
    public Gtk.Label meta_label;
    public string when_text;
    public int64 fallback_duration_seconds;
}

public class PodcastPane : GLib.Object {
    // The revealer is what appWindow.vala adds as a root_overlay child -
    // root itself is just its content.
    public Gtk.Revealer revealer;
    public Gtk.Box root;

    private weak NewsWindow? window;
    private Managers.PodcastPlaybackManager playback;

    private Gtk.Picture cover_image;
    private Gtk.Label title_label;
    private Gtk.Label author_label;
    private Gtk.Label description_label;
    private Gtk.Button subscribe_button;
    private Gtk.Box episode_list_box;
    private Gtk.Spinner episode_spinner;
    private Gtk.Label episode_empty_label;

    private Paperboy.PodcastShow? current_show = null;
    // Guards against a slow episodes_for_feed() response from an earlier
    // open_for_show() call landing after the user has since opened a
    // different show (or closed the pane) and populating the wrong rows.
    private int64 open_request_id = 0;

    // Tracks each visible episode row's play/pause button by episode_id,
    // so update_episode_play_buttons() can refresh them all from one
    // playback-manager signal instead of each row holding its own
    // long-lived (leaky) connection.
    private Gee.HashMap<int64?, Gtk.Button> episode_play_buttons = new Gee.HashMap<int64?, Gtk.Button>();
    // Mirror maps for the "played" dimming / "New" badge on each row - see
    // PodcastDetailDialog's identical setup for why (live per-row updates
    // without rebuilding the whole list). Explicit hash/equal funcs:
    // Gee.HashMap<int64?, V> without them defaults to pointer identity on
    // the boxed key, not value equality, so has_key()/get() would never
    // match a freshly-boxed int64 with the same value as an existing key.
    private Gee.HashMap<int64?, Gtk.Widget> episode_rows =
        new Gee.HashMap<int64?, Gtk.Widget>((v) => { return (uint) v; }, (a, b) => { return a == b; });
    private Gee.HashMap<int64?, Gtk.Widget> episode_new_badges =
        new Gee.HashMap<int64?, Gtk.Widget>((v) => { return (uint) v; }, (a, b) => { return a == b; });
    // Tracks each row's progress bar + meta label so
    // update_playing_episode_progress() can live-update whichever row is
    // currently playing on every position_updated tick, instead of the
    // progress display only ever reflecting whatever was persisted the last
    // time the pane was opened.
    private Gee.HashMap<int64?, EpisodeProgressRow> episode_progress_rows =
        new Gee.HashMap<int64?, EpisodeProgressRow>((v) => { return (uint) v; }, (a, b) => { return a == b; });

    public PodcastPane(NewsWindow? window, Managers.PodcastPlaybackManager playback) {
        this.window = window;
        this.playback = playback;
        build();

        playback.playback_state_changed.connect(() => { update_episode_play_buttons(); });
        playback.episode_changed.connect(() => { update_episode_play_buttons(); });
        playback.position_updated.connect((position_ns, duration_ns) => {
            update_playing_episode_progress(position_ns, duration_ns);
        });

        Paperboy.PodcastPlaybackStateStore.get_instance().episode_played_changed.connect((episode_id) => {
            mark_row_played(episode_id);
        });
    }

    // Live-updates one already-built row when its episode gets marked
    // played elsewhere (e.g. its own play button was just clicked) -
    // avoids re-rendering the whole episode list for a single row change.
    private void mark_row_played(int64 episode_id) {
        Gtk.Widget? row = episode_rows.has_key(episode_id) ? episode_rows.get(episode_id) : null;
        if (row != null) row.add_css_class("podcast-episode-played");

        Gtk.Widget? badge = episode_new_badges.has_key(episode_id) ? episode_new_badges.get(episode_id) : null;
        if (badge != null) badge.set_visible(false);
    }

    // Live-refreshes whichever episode row is currently playing on every
    // PodcastPlaybackManager.position_updated tick - unlike the rest of a
    // row's contents (built once from persisted state when the pane opens),
    // this needs to move continuously while playing, the same way the mini
    // player's own scrubber does. Only the actively-playing row updates;
    // every other row keeps showing whatever was true when the list was
    // built, consistent with this pane's existing "static except where a
    // signal explicitly says otherwise" approach (mark_row_played, etc.).
    private void update_playing_episode_progress(uint64 position_ns, uint64 duration_ns) {
        var current = playback.get_current_episode();
        if (current == null) return;

        EpisodeProgressRow? row = episode_progress_rows.has_key(current.episode_id) ? episode_progress_rows.get(current.episode_id) : null;
        if (row == null) return; // not in the currently-open show's list

        uint64 effective_duration_ns = duration_ns > 0 ? duration_ns : (uint64) row.fallback_duration_seconds * 1000000000;
        if (effective_duration_ns == 0) return; // duration not known yet

        double fraction = (double) position_ns / (double) effective_duration_ns;
        if (fraction < 0) fraction = 0;
        if (fraction > 1) fraction = 1;
        row.bar.set_fraction(fraction);
        row.bar.set_visible(true);

        int64 remaining_seconds = (int64) ((effective_duration_ns - position_ns) / 1000000000);
        if (remaining_seconds < 0) remaining_seconds = 0;
        string duration_text = format_duration(remaining_seconds) + " left";
        row.meta_label.set_text(duration_text.length > 0 ? "%s · %s".printf(row.when_text, duration_text) : row.when_text);
    }

    // Reflects the playback manager's current episode/play-state on every
    // visible episode row's button - the pane's own equivalent of
    // PodcastCard.update_subscribe_button_state(), just centralized since
    // there are many rows instead of one per card.
    private void update_episode_play_buttons() {
        var current = playback.get_current_episode();
        bool playing = playback.is_playing();
        foreach (var entry in episode_play_buttons.entries) {
            bool is_current = current != null && current.episode_id == entry.key;
            entry.value.set_icon_name(is_current && playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic");
        }
    }

    public void open_for_show(Paperboy.PodcastShow show) {
        current_show = show;
        open_request_id++;
        int64 this_request = open_request_id;

        title_label.set_text(show.title);
        author_label.set_text(show.author ?? "");
        author_label.set_visible(show.author != null && show.author.length > 0);

        string? desc = show.description != null ? stripHtmlUtils.strip_html(show.description).strip() : null;
        description_label.set_text(desc ?? "");
        description_label.set_visible(desc != null && desc.length > 0);

        // Shows opened from a stored subscription (see
        // PodcastSubscription.to_show()) never carry a description for
        // subscriptions made before descriptions were persisted, or ones
        // subscribed from a source that never had one at hand. Backfill by
        // re-parsing the feed directly - works the same way for both
        // PodcastIndex-discovered and direct-feed-added shows, since both
        // kinds always have a real feed_url.
        if ((desc == null || desc.length == 0) && window != null && show.feed_url != null && show.feed_url.length > 0) {
            var resolver = Paperboy.PodcastFeedResolver.get_instance();
            resolver.resolve_show(show.feed_url, window.session, (success, resolved_show, error_message) => {
                if (this_request != open_request_id) return; // superseded by a newer open
                if (!success || resolved_show == null || resolved_show.description == null) return;

                string fresh_desc = stripHtmlUtils.strip_html(resolved_show.description).strip();
                if (fresh_desc.length == 0) return;

                show.description = resolved_show.description;
                description_label.set_text(fresh_desc);
                description_label.set_visible(true);

                if (Paperboy.PodcastSubscriptionStore.get_instance().is_subscribed(show.feed_id)) {
                    Paperboy.PodcastSubscriptionStore.get_instance().update_description(show.feed_id, resolved_show.description);
                }
            });
        }

        if (window != null && show.image_url != null && show.image_url.length > 0) {
            window.image_manager.load_image_async(cover_image, show.image_url, 96, 96);
        }

        update_subscribe_button_state();
        resize_sheet();

        clear_episode_list();
        episode_spinner.set_visible(true);
        episode_spinner.start();
        episode_empty_label.set_visible(false);

        if (show.from_direct_feed && window != null) {
            // Added by feed URL, not discovered via PodcastIndex - no real
            // feed_id to query episodes_for_feed() with, so re-parse the
            // show's own feed directly (see PodcastFeedResolver).
            var resolver = Paperboy.PodcastFeedResolver.get_instance();
            resolver.fetch_episodes(show.feed_url, show.title, show.image_url, window.session, (episodes) => {
                render_episodes(this_request, episodes);
            });
        } else if (show.from_direct_feed) {
            // No window reference to get a Soup.Session from - shouldn't
            // normally happen, but resolve to "no episodes" rather than
            // leaving the spinner stuck.
            render_episodes(this_request, new Gee.ArrayList<Paperboy.PodcastEpisode>());
        } else {
            var service = Paperboy.PodcastIndexService.get_instance();
            service.episodes_for_feed(show.feed_id, 20, (episodes) => {
                render_episodes(this_request, episodes);
            });
        }

        revealer.set_reveal_child(true);
    }

    private void render_episodes(int64 request_id, Gee.ArrayList<Paperboy.PodcastEpisode> episodes) {
        if (request_id != open_request_id) return; // superseded by a newer open

        episode_spinner.stop();
        episode_spinner.set_visible(false);

        if (episodes.size == 0) {
            episode_empty_label.set_visible(true);
            return;
        }

        // So the mini-player's back/forward buttons (see PodcastPlayerBar/
        // PodcastPlaybackManager.play_next_episode/play_previous_episode)
        // have something to step through once the user plays an episode
        // from this show.
        playback.set_episode_queue(episodes);

        var state_store = Paperboy.PodcastPlaybackStateStore.get_instance();
        // Read the *previous* last-viewed time before this open overwrites
        // it below - that's what decides which episodes are "new".
        int64 previous_last_viewed = current_show != null ? state_store.get_last_viewed(current_show.feed_id) : 0;

        foreach (var episode in episodes) {
            bool is_new = !state_store.is_episode_played(episode.episode_id) && episode_is_after(episode, previous_last_viewed);
            episode_list_box.append(build_episode_row(episode, is_new));
        }
        // Sync icons immediately - e.g. reopening a show whose episode is
        // already playing in the background shouldn't show every row as
        // "play" until the next playback signal happens to fire.
        update_episode_play_buttons();

        if (current_show != null) state_store.mark_show_viewed(current_show.feed_id);
    }

    // Best-effort: episodes with an unparseable/missing published date are
    // never flagged "new" rather than guessed at.
    private static bool episode_is_after(Paperboy.PodcastEpisode episode, int64 unix_seconds) {
        var dt = DateUtils.parse_published_datetime(episode.published);
        if (dt == null) return false;
        return dt.to_unix() > unix_seconds;
    }

    public void close() {
        revealer.set_reveal_child(false);
    }

    public bool is_open() {
        return revealer.get_reveal_child();
    }

    private void build() {
        // Flush against the content view's left/right/bottom edges (no
        // margins, no rounding - see the class doc comment) and stretched
        // to the revealer's full width/height, so it reads as a docked
        // panel rather than a floating card. Padding around the actual
        // header/episode content lives on `content_box` below instead.
        root = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        root.add_css_class("podcast-pane");
        root.set_hexpand(true);
        root.set_vexpand(true);
        root.set_halign(Gtk.Align.FILL);
        root.set_valign(Gtk.Align.FILL);

        revealer = new Gtk.Revealer();
        revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_UP);
        revealer.set_transition_duration(250);
        revealer.set_valign(Gtk.Align.END);
        revealer.set_halign(Gtk.Align.FILL);
        revealer.set_reveal_child(false);
        revealer.set_child(root);

        var content_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
        content_box.set_margin_start(24);
        content_box.set_margin_end(24);
        content_box.set_margin_top(16);
        content_box.set_margin_bottom(16);
        content_box.set_vexpand(true);
        root.append(content_box);

        var header_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 14);

        // set_size_request() only raises a widget's *minimum* size - it
        // doesn't cap its *natural* size, which for a Gtk.Picture is driven
        // by whatever texture is actually loaded. A loaded cover image
        // could still request (and be allocated) far more than 96x96
        // despite a size_request, shoving the title text over with it.
        // FixedSizeLayoutUtils pins this box's reported size at exactly
        // 96x96 regardless of cover_image's own natural size.
        var cover_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        cover_box.set_hexpand(false);
        cover_box.set_vexpand(false);
        cover_box.set_halign(Gtk.Align.START);
        cover_box.set_valign(Gtk.Align.START);
        cover_box.add_css_class("podcast-pane-cover");
        cover_box.set_overflow(Gtk.Overflow.HIDDEN);
        Paperboy.FixedSizeLayoutUtils.apply(cover_box, 96, 96);

        cover_image = new Gtk.Picture();
        cover_image.set_hexpand(true);
        cover_image.set_vexpand(true);
        cover_image.set_halign(Gtk.Align.FILL);
        cover_image.set_valign(Gtk.Align.FILL);
        // PodcastCard/PodcastHeroCard put size_request on the image itself,
        // not just its wrapper - this was the actual missing piece here
        // (cover_box alone wasn't enough to cap it).
        cover_image.set_size_request(96, 96);
        cover_image.set_content_fit(Gtk.ContentFit.COVER);
        // See PodcastCard/PodcastHeroCard for why.
        cover_image.set_keep_aspect_ratio(false);
        cover_image.set_can_shrink(true);
        // Rounding needs to be on the picture itself, not just cover_box -
        // a container's border-radius doesn't reliably clip a child
        // widget's own rendering to match.
        cover_image.add_css_class("podcast-pane-cover");
        cover_box.append(cover_image);
        header_row.append(cover_box);

        var title_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);
        title_box.set_hexpand(true);
        title_box.set_valign(Gtk.Align.START);

        title_label = new Gtk.Label("");
        title_label.add_css_class("title-2");
        title_label.set_xalign(0);
        title_label.set_ellipsize(Pango.EllipsizeMode.END);
        title_box.append(title_label);

        author_label = new Gtk.Label("");
        author_label.add_css_class("article-card-time");
        author_label.set_xalign(0);
        author_label.set_ellipsize(Pango.EllipsizeMode.END);
        title_box.append(author_label);

        description_label = new Gtk.Label("");
        description_label.add_css_class("dim-label");
        description_label.add_css_class("caption");
        description_label.set_xalign(0);
        description_label.set_wrap(true);
        description_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        description_label.set_lines(2);
        description_label.set_ellipsize(Pango.EllipsizeMode.END);
        description_label.set_margin_top(4);
        title_box.append(description_label);

        header_row.append(title_box);

        subscribe_button = new Gtk.Button();
        subscribe_button.set_valign(Gtk.Align.START);
        subscribe_button.add_css_class("pill");
        subscribe_button.clicked.connect(() => {
            if (current_show == null) return;
            var store = Paperboy.PodcastSubscriptionStore.get_instance();
            if (store.is_subscribed(current_show.feed_id)) {
                store.unsubscribe(current_show.feed_id);
            } else {
                store.subscribe(current_show);
            }
            update_subscribe_button_state();
        });
        header_row.append(subscribe_button);

        var close_button = new Gtk.Button.from_icon_name("window-close-symbolic");
        close_button.add_css_class("flat");
        close_button.add_css_class("circular");
        close_button.set_valign(Gtk.Align.START);
        close_button.clicked.connect(() => { close(); });
        header_row.append(close_button);

        content_box.append(header_row);

        var separator = new Gtk.Separator(Gtk.Orientation.HORIZONTAL);
        separator.add_css_class("section-divider");
        content_box.append(separator);

        var episode_scroller = new Gtk.ScrolledWindow();
        episode_scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        episode_scroller.set_vexpand(true);
        // Reserve the scrollbar its own column instead of floating it over
        // content - each row's play button sits flush at the right edge,
        // and an overlay scrollbar was covering/eating clicks on it.
        episode_scroller.set_overlay_scrolling(false);

        episode_list_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        episode_scroller.set_child(episode_list_box);
        content_box.append(episode_scroller);

        episode_spinner = new Gtk.Spinner();
        episode_spinner.set_size_request(24, 24);
        episode_spinner.set_halign(Gtk.Align.CENTER);
        episode_spinner.set_margin_top(20);
        episode_spinner.set_visible(false);
        content_box.append(episode_spinner);

        episode_empty_label = new Gtk.Label("No episodes found for this show.");
        episode_empty_label.add_css_class("dim-label");
        episode_empty_label.set_margin_top(20);
        episode_empty_label.set_halign(Gtk.Align.CENTER);
        episode_empty_label.set_visible(false);
        content_box.append(episode_empty_label);
    }

    private void update_subscribe_button_state() {
        if (current_show == null) return;
        bool subscribed = Paperboy.PodcastSubscriptionStore.get_instance().is_subscribed(current_show.feed_id);
        subscribe_button.set_label(subscribed ? "Subscribed" : "Subscribe");
        if (subscribed) {
            subscribe_button.remove_css_class("suggested-action");
        } else {
            subscribe_button.add_css_class("suggested-action");
        }
    }

    private void clear_episode_list() {
        Gtk.Widget? child = episode_list_box.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            episode_list_box.remove(child);
            child = next;
        }
        episode_play_buttons.clear();
        episode_rows.clear();
        episode_new_badges.clear();
        episode_progress_rows.clear();
    }

    private Gtk.Widget build_episode_row(Paperboy.PodcastEpisode episode, bool is_new) {
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

        var progress = Paperboy.PodcastPlaybackStateStore.get_instance().get_episode_progress(episode.episode_id);
        bool has_progress = progress != null && progress.duration_ns > 0
            && progress.position_ns > 5000000000
            && progress.position_ns < progress.duration_ns - 10000000000;

        string duration_text = has_progress
            ? format_duration((int64) ((progress.duration_ns - progress.position_ns) / 1000000000)) + " left"
            : format_duration(episode.duration_seconds);
        string when_text = DateUtils.time_ago(episode.published);
        var meta_label = new Gtk.Label(duration_text.length > 0 ? "%s · %s".printf(when_text, duration_text) : when_text);
        meta_label.add_css_class("article-card-time");
        meta_label.set_xalign(0);

        // meta_box (not text_box directly) so the progress bar below can be
        // hexpand=true within a container sized to meta_label's own natural
        // width, rather than stretching to text_box's full (whole-row) width.
        var meta_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);
        meta_box.set_halign(Gtk.Align.START);
        meta_box.append(meta_label);

        // Always created (not just when has_progress) so
        // update_playing_episode_progress() has a widget ready to reveal
        // the moment this episode starts playing, even if it had no prior
        // persisted progress at all - initial visibility still reflects
        // has_progress, same as before.
        var progress_bar = new Gtk.ProgressBar();
        progress_bar.add_css_class("podcast-episode-progress");
        progress_bar.set_hexpand(true);
        progress_bar.set_visible(has_progress);
        if (has_progress) {
            progress_bar.set_fraction((double) progress.position_ns / (double) progress.duration_ns);
        }
        meta_box.append(progress_bar);

        var progress_row = new EpisodeProgressRow();
        progress_row.bar = progress_bar;
        progress_row.meta_label = meta_label;
        progress_row.when_text = when_text;
        progress_row.fallback_duration_seconds = episode.duration_seconds;
        episode_progress_rows.set(episode.episode_id, progress_row);

        text_box.append(meta_box);

        row.append(text_box);

        var play_button = new Gtk.Button.from_icon_name("media-playback-start-symbolic");
        play_button.add_css_class("flat");
        play_button.add_css_class("circular");
        play_button.set_valign(Gtk.Align.CENTER);
        play_button.clicked.connect(() => {
            var current = playback.get_current_episode();
            if (current != null && current.episode_id == episode.episode_id) {
                // Already loaded - toggle play/pause instead of restarting
                // it from load_and_play().
                playback.toggle_play_pause();
            } else {
                play_episode(episode);
            }
        });
        row.append(play_button);
        episode_play_buttons.set(episode.episode_id, play_button);
        episode_rows.set(episode.episode_id, row);
        if (new_badge != null) episode_new_badges.set(episode.episode_id, new_badge);

        // Only play_button is clickable, not the whole row.

        return row;
    }

    private void play_episode(Paperboy.PodcastEpisode episode) {
        if (episode.audio_url == null || episode.audio_url.length == 0) return;
        if (current_show != null) {
            if (episode.show_title == null || episode.show_title.length == 0) episode.show_title = current_show.title;
            if (episode.image_url == null || episode.image_url.length == 0) episode.image_url = current_show.image_url;
        }
        playback.load_and_play(episode, NewsPreferences.get_instance().podcast_playback_speed);
    }

    private static string format_duration(int64 seconds) {
        if (seconds <= 0) return "";
        int64 mins = seconds / 60;
        int64 hrs = mins / 60;
        mins = mins % 60;
        if (hrs > 0) return "%lldh %lldm".printf(hrs, mins);
        return "%lldm".printf(mins);
    }

    // Gtk.Revealer sizes to its child's natural size, which would
    // otherwise grow with however many episodes load. Cap root's height
    // explicitly to roughly a third of the content view's current height
    // (falling back to a fixed value before the window has been measured)
    // so the pane reads as a peek/detail sheet, with the episode list's
    // own ScrolledWindow absorbing any overflow instead of the whole pane
    // growing to fit every episode.
    private void resize_sheet() {
        int content_h = (window != null && window.content_view != null && window.content_view.main_scrolled.get_height() > 0)
            ? window.content_view.main_scrolled.get_height()
            : (window != null ? window.get_height() : 800);
        int target_h = (int)(content_h * 0.3985); // ~33% + 5% + 15%
        if (target_h < 420) target_h = 420;
        root.set_size_request(-1, target_h);
    }
}
