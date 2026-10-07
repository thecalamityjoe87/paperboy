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
using GLib;

/**
 * One of the Podcasts page's 4 top hero cards. Unlike HeroCard.for_topten
 * (a 70/30 picture-over-text split), the cover art here fills the entire
 * card - title/author sit in a bottom-pinned overlay on top of the image,
 * behind a dark scrim gradient (see .hero-podcast-scrim in style.css) so
 * they stay legible regardless of the artwork's own colors. Kept as its
 * own class rather than a new HeroCard constructor since podcasts have no
 * article-save ribbon, no relative-time footer, and no split grid at all.
 */
public class PodcastHeroCard : GLib.Object {
    public Gtk.Box root;
    public Gtk.Overlay overlay;
    public Gtk.Picture image;
    public Gtk.Box title_box;
    public Gtk.Label title_label;
    public Gtk.Label? author_label;
    public Gtk.Button play_button;
    public Gtk.Button subscribe_button;
    public int64 feed_id;
    public string? feed_url;
    public Paperboy.PodcastShow show;
    // for_episode() (My Library's Up Next row) only - that variant has no
    // play_button/subscribe_button badges; time_pill plays instead.
    public Paperboy.PodcastEpisode? episode = null;
    public Gtk.Button? time_pill = null;
    private Gtk.Image? time_pill_icon = null;
    private Gtk.Label? time_pill_label = null;
    private Gtk.ProgressBar? time_pill_progress = null;
    private Gtk.Revealer? time_pill_reveal = null;

    // Plain callback type, mirroring HeroCard/ArticleCard's own delegate -
    // avoids a GObject signal owned by this object's own root widget.
    public delegate void ActivatedCallback(int64 feed_id);

    public PodcastHeroCard(Paperboy.PodcastShow show, int max_total_height) {
        GLib.Object();
        this.feed_id = show.feed_id;
        this.feed_url = show.feed_url;
        this.show = show;
        string title = show.title;
        string? author = show.author;

        var text_box = build_frame(max_total_height, 0.45);

        title_label = new Gtk.Label(title);
        title_label.add_css_class("hero-title");
        title_label.set_ellipsize(Pango.EllipsizeMode.END);
        title_label.set_xalign(0);
        title_label.set_wrap(true);
        title_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        title_label.set_lines(2);
        text_box.append(title_label);

        if (author != null && author.strip().length > 0) {
            author_label = new Gtk.Label(author);
            author_label.add_css_class("hero-podcast-author");
            author_label.set_xalign(0);
            author_label.set_ellipsize(Pango.EllipsizeMode.END);
            text_box.append(author_label);
        }

        overlay.add_overlay(title_box);

        // Play/subscribe badges, bottom-right corner - added after
        // title_box so it layers on top of the scrim there, matching
        // PodcastCard's own bottom-right badge placement.
        var badge_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        badge_row.add_css_class("card-corner-badges");
        badge_row.set_halign(Gtk.Align.END);
        badge_row.set_valign(Gtk.Align.END);
        badge_row.set_margin_bottom(8);
        badge_row.set_margin_end(8);

        play_button = new Gtk.Button.from_icon_name("media-playback-start-symbolic");
        play_button.add_css_class("podcast-card-badge-btn");
        play_button.set_tooltip_text(_("Play"));
        badge_row.append(play_button);

        subscribe_button = new Gtk.Button();
        subscribe_button.add_css_class("podcast-card-badge-btn");
        update_subscribe_button_state();
        badge_row.append(subscribe_button);

        overlay.add_overlay(badge_row);

        root.append(overlay);
    }

    // Cover art + bottom scrim shared by both variants - returns the
    // scrim's inner text column for the caller to fill.
    private Gtk.Box build_frame(int max_total_height, double scrim_fraction) {
        root = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        root.add_css_class("card");
        root.add_css_class("hero-card-podcast");
        root.set_size_request(-1, max_total_height);
        root.set_hexpand(true);
        root.set_vexpand(true);
        root.set_halign(Gtk.Align.FILL);
        root.set_valign(Gtk.Align.FILL);

        image = new Gtk.Picture();
        image.set_halign(Gtk.Align.FILL);
        image.set_valign(Gtk.Align.FILL);
        image.set_hexpand(true);
        image.set_vexpand(true);
        image.set_content_fit(Gtk.ContentFit.COVER);
        image.set_can_shrink(true);
        image.set_size_request(-1, max_total_height);
        // NOT disabling keep-aspect-ratio here, unlike PodcastCard/
        // PodcastPlayerBar/PodcastPane: this card only fixes height via
        // size_request above - width comes from hero_container's own
        // homogeneous distribution, not from this Picture directly. See
        // HeroCard.vala's own build_image_overlay_and_title() comment:
        // disabling keep-aspect-ratio in that same one-dimension-fixed
        // situation broke ContentFit.COVER's crop math and stretched/
        // squished the image instead of cropping it. The brief "loads
        // tall, then constricts" flash while an async texture's real
        // aspect ratio lands is a cosmetic, self-correcting side effect of
        // hero_container's homogeneous layout re-asserting equal widths -
        // not worth trading a correctly-cropped image for.

        overlay = new Gtk.Overlay();
        overlay.set_child(image);
        overlay.set_hexpand(true);
        overlay.set_vexpand(true);
        overlay.set_size_request(-1, max_total_height);

        // The scrim itself is flush to the card's bottom/left/right edges
        // (no margins) so its dark gradient background actually reaches
        // those corners - text stayed legible only in the middle before,
        // since the gap left by margins here exposed raw (unshaded) cover
        // art right where the title/author sat closest to the edges.
        // Bottom-anchored at a fixed fraction of the card's height (not the
        // full card - that would push the gradient's fade-to-transparent
        // point all the way to the top) so there's still a smooth gradient
        // runway above the text. Padding for the text itself lives on the
        // inner text_box below instead of on this box, so the background
        // isn't inset from the edges too.
        int scrim_height = (int) (max_total_height * scrim_fraction);
        title_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        title_box.add_css_class("hero-podcast-scrim");
        title_box.set_hexpand(true);
        title_box.set_vexpand(false);
        title_box.set_halign(Gtk.Align.FILL);
        title_box.set_valign(Gtk.Align.END);
        title_box.set_size_request(-1, scrim_height);

        var text_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);
        text_box.set_margin_start(16);
        text_box.set_margin_end(16);
        text_box.set_margin_bottom(16);
        text_box.set_valign(Gtk.Align.END);
        text_box.set_vexpand(true);
        title_box.append(text_box);
        return text_box;
    }

    // Up Next card: one episode, not a show. Eyebrow ("New" pill + when it
    // came out) and episode title, then a bottom line pairing the show name
    // (left) with an Apple-style play pill (right) carrying the time
    // left as "#m", with a thin progress bar sliding out beside it while
    // it's actually playing. The whole card plays it too.
    public PodcastHeroCard.for_episode(Paperboy.PodcastShow show, Paperboy.PodcastEpisode episode, int max_total_height, bool is_new) {
        GLib.Object();
        this.feed_id = show.feed_id;
        this.feed_url = show.feed_url;
        this.show = show;
        this.episode = episode;

        // Taller scrim than the show variant - four lines of text, not two.
        var text_box = build_frame(max_total_height, 0.62);
        text_box.set_spacing(6);

        var eyebrow = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        if (is_new) {
            var new_badge = new Gtk.Label(_("New"));
            new_badge.add_css_class("podcast-episode-new-badge");
            new_badge.set_valign(Gtk.Align.CENTER);
            eyebrow.append(new_badge);
        }
        string when = DateUtils.time_ago(episode.published);
        if (when.length > 0) {
            var when_label = new Gtk.Label(when.up());
            when_label.add_css_class("hero-podcast-eyebrow");
            when_label.set_valign(Gtk.Align.CENTER);
            eyebrow.append(when_label);
        }
        if (eyebrow.get_first_child() != null) text_box.append(eyebrow);

        title_label = new Gtk.Label(episode.title);
        title_label.add_css_class("hero-title");
        title_label.add_css_class("hero-podcast-episode-title");
        title_label.set_ellipsize(Pango.EllipsizeMode.END);
        title_label.set_xalign(0);
        title_label.set_wrap(true);
        title_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        title_label.set_lines(2);
        text_box.append(title_label);

        // Show name and play pill share the card's bottom line, the name
        // vertically centered on the pill so the two read as one row.
        var bottom_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);

        author_label = new Gtk.Label(show.title);
        author_label.add_css_class("hero-podcast-author");
        author_label.set_xalign(0);
        author_label.set_hexpand(true);
        author_label.set_valign(Gtk.Align.CENTER);
        author_label.set_ellipsize(Pango.EllipsizeMode.END);
        bottom_row.append(author_label);

        var pill_content = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        time_pill_icon = new Gtk.Image.from_icon_name("media-playback-start-symbolic");
        pill_content.append(time_pill_icon);
        time_pill_progress = new Gtk.ProgressBar();
        time_pill_progress.add_css_class("hero-podcast-time-progress");
        time_pill_progress.set_valign(Gtk.Align.CENTER);
        time_pill_progress.set_size_request(20, -1);
        // Slides out only while this episode is actually playing - same
        // reveal as the source badge's hover follow button
        // (CardBuilder.make_badge_followable).
        time_pill_reveal = new Gtk.Revealer();
        time_pill_reveal.set_transition_type(Gtk.RevealerTransitionType.SLIDE_LEFT);
        time_pill_reveal.set_transition_duration(200);
        time_pill_reveal.set_child(time_pill_progress);
        // Hidden once collapsed, so the pill's spacing doesn't leave a gap.
        time_pill_reveal.set_visible(false);
        time_pill_reveal.notify["child-revealed"].connect((obj, pspec) => {
            var rv = (Gtk.Revealer) obj;
            if (!rv.get_reveal_child() && !rv.get_child_revealed()) rv.set_visible(false);
        });
        pill_content.append(time_pill_reveal);
        time_pill_label = new Gtk.Label("");
        pill_content.append(time_pill_label);

        time_pill = new Gtk.Button();
        time_pill.set_child(pill_content);
        time_pill.add_css_class("hero-podcast-time-pill");
        time_pill.set_halign(Gtk.Align.END);
        time_pill.set_valign(Gtk.Align.CENTER);
        time_pill.set_tooltip_text(_("Play"));
        bottom_row.append(time_pill);

        bottom_row.set_margin_top(2);
        text_box.append(bottom_row);

        refresh_time_pill(time_pill_label, time_pill_reveal, time_pill_progress, episode, false, false, 0, 0);

        overlay.add_overlay(title_box);
        root.append(overlay);
    }

    // Time left as "#m" - the full length until it's been started. The
    // progress bar slides out once there's progress to show: while this
    // episode is actually playing (is_playing), or paused/unloaded partway
    // through. A fresh or finished episode is just the time.
    // is_current: this card's episode is the one loaded in the player, and
    // position_ns/duration_ns are the player's live values; otherwise its
    // persisted progress is used.
    // Static over the pill's own widgets (not the card) - see
    // wire_episode_interactions() for why the card can't be relied on.
    private static void refresh_time_pill(Gtk.Label label, Gtk.Revealer reveal, Gtk.ProgressBar bar, Paperboy.PodcastEpisode episode, bool is_current, bool is_playing, uint64 position_ns, uint64 duration_ns) {
        var progress = Paperboy.PodcastPlaybackStateStore.get_instance().get_episode_progress(episode.episode_id);
        if (!is_current) {
            position_ns = progress != null ? progress.position_ns : 0;
            duration_ns = progress != null ? progress.duration_ns : 0;
        } else if (position_ns == 0 && progress != null) {
            // load_and_play() starts at 0 until its resume seek lands -
            // hold the saved spot meanwhile instead of flashing back to 0.
            position_ns = progress.position_ns;
        }
        if (duration_ns == 0 && episode.duration_seconds > 0) {
            duration_ns = (uint64) episode.duration_seconds * 1000000000;
        }
        if (position_ns > duration_ns) position_ns = duration_ns;

        string text = PodcastCategoryUtils.format_time_estimate((int64) ((duration_ns - position_ns) / 1000000000));
        label.set_visible(text.length > 0);
        if (label.get_text() != text) label.set_text(text);

        // Same "started" thresholds as PodcastPane's episode rows: past the
        // first 5s and not within 10s of the end.
        bool started = position_ns > 5000000000 && position_ns + 10000000000 < duration_ns;
        bool show_bar = duration_ns > 0 && (is_playing || started);
        if (show_bar) bar.set_fraction((double) position_ns / (double) duration_ns);
        if (reveal.get_reveal_child() != show_bar) {
            if (show_bar) reveal.set_visible(true);
            reveal.set_reveal_child(show_bar);
        }
    }

    // Episode-card counterpart of wire_interactions(). Static, same reason.
    // on_play only has to start the episode - toggling it once it's the
    // current one is handled here.
    public static void wire_episode_interactions(Gtk.Box root_widget, PodcastHeroCard card, Managers.PodcastPlaybackManager playback, owned ActivatedCallback on_play, owned ActivatedCallback on_info) {
        unowned Gtk.Box r = root_widget;
        int64 feed_id = card.feed_id;
        int64 episode_id = card.episode.episode_id;

        // One shared handler for the pill and the card body.
        ActivatedCallback activate = (id) => {
            var current = playback.get_current_episode();
            if (current != null && current.episode_id == episode_id) {
                playback.toggle_play_pause();
            } else {
                on_play(id);
            }
        };

        card.time_pill.clicked.connect(() => { activate(episode_id); });

        // Tick callback rather than playback signals, same as
        // wire_interactions(): it stops on its own once the card is gone.
        // Captures the pill's own children (unowned - the pill owning this
        // callback keeps them alive), never `card`: callers drop the
        // PodcastHeroCard object right after building it.
        unowned Gtk.Image icon = card.time_pill_icon;
        unowned Gtk.Label label = card.time_pill_label;
        unowned Gtk.ProgressBar bar = card.time_pill_progress;
        unowned Gtk.Revealer reveal = card.time_pill_reveal;
        var episode = card.episode;
        bool was_current = false;
        card.time_pill.add_tick_callback((widget, frame_clock) => {
            var current = playback.get_current_episode();
            bool is_current = current != null && current.episode_id == episode_id;
            string wanted = (is_current && playback.is_playing()) ? "media-playback-pause-symbolic" : "media-playback-start-symbolic";
            if (icon.get_icon_name() != wanted) icon.set_from_icon_name(wanted);
            // Live while current, plus one last refresh as it stops being
            // current (another episode started) to fall back to saved progress.
            if (is_current || was_current) {
                refresh_time_pill(label, reveal, bar, episode, is_current, is_current && playback.is_playing(), playback.get_position_ns(), playback.get_duration_ns());
            }
            was_current = is_current;
            return true;
        });

        var right_click = new Gtk.GestureClick();
        right_click.set_button(3);
        right_click.pressed.connect((n_press, x, y) => {
            var menu = new PodcastMenu(true);
            menu.show_info_item = true;
            menu.play_requested.connect(() => { activate(episode_id); });
            menu.info_requested.connect(() => { on_info(feed_id); });
            menu.unsubscribe_requested.connect(() => {
                Paperboy.PodcastSubscriptionStore.get_instance().unsubscribe(feed_id);
            });
            var popover = menu.create_popover(r, x, y);
            r.set_data("podcast-current-menu", menu);
            r.set_data("podcast-current-popover", popover);
            popover.popup();
        });
        root_widget.add_controller(right_click);

        // Released on the card body only - the pill is a Button, which
        // claims its own clicks before this sees them.
        var gesture = new Gtk.GestureClick();
        gesture.set_button(1);
        gesture.released.connect(() => { activate(episode_id); });
        root_widget.add_controller(gesture);

        var motion = new Gtk.EventControllerMotion();
        motion.enter.connect(() => { r.add_css_class("card-hover"); });
        motion.leave.connect(() => { r.remove_css_class("card-hover"); });
        root_widget.add_controller(motion);
    }

    private void update_subscribe_button_state() {
        PodcastCard.update_subscribe_button(subscribe_button, feed_id);
    }

    // Static, and no lambda touches `card` or `root_widget` - see
    // PodcastCard.wire_interactions for why both matter.
    public static void wire_interactions(Gtk.Box root_widget, PodcastHeroCard card, int64 feed_id, Managers.PodcastPlaybackManager? playback, owned ActivatedCallback? on_activated, owned ActivatedCallback? on_play_requested = null) {
        unowned Gtk.Box r = root_widget;
        unowned Gtk.Button subscribe_btn = card.subscribe_button;
        var show = card.show;

        card.play_button.clicked.connect(() => {
            if (playback != null) {
                var current = playback.get_current_episode();
                if (current != null && current.feed_id == feed_id) {
                    playback.toggle_play_pause();
                    return;
                }
            }
            // Distinct from on_activated (a plain card click, which just
            // opens PodcastPane without playing anything) - the play badge
            // should actually start playback.
            if (on_play_requested != null) on_play_requested(feed_id);
        });

        // See PodcastCard.wire_interactions' identical tick-callback for
        // why this isn't a direct connection to playback's own signals.
        if (playback != null) {
            var btn = card.play_button;
            btn.add_tick_callback((widget, frame_clock) => {
                var current = playback.get_current_episode();
                bool is_current = current != null && current.feed_id == feed_id;
                string wanted = (is_current && playback.is_playing()) ? "media-playback-pause-symbolic" : "media-playback-start-symbolic";
                var b = (Gtk.Button) widget;
                if (b.get_icon_name() != wanted) b.set_icon_name(wanted);
                return true;
            });
        }

        subscribe_btn.clicked.connect((btn) => {
            var store = Paperboy.PodcastSubscriptionStore.get_instance();
            if (store.is_subscribed(feed_id)) {
                store.unsubscribe(feed_id);
            } else {
                store.subscribe(show);
            }
            PodcastCard.update_subscribe_button(btn, feed_id);
        });

        var right_click = new Gtk.GestureClick();
        right_click.set_button(3);
        right_click.pressed.connect((n_press, x, y) => {
            show_context_menu(r, subscribe_btn, show, feed_id, x, y, on_play_requested);
        });
        root_widget.add_controller(right_click);

        var gesture = new Gtk.GestureClick();
        gesture.set_button(1);
        gesture.released.connect(() => {
            if (on_activated != null) on_activated(feed_id);
        });
        root_widget.add_controller(gesture);

        var motion = new Gtk.EventControllerMotion();
        motion.enter.connect(() => { r.add_css_class("card-hover"); });
        motion.leave.connect(() => { r.remove_css_class("card-hover"); });
        root_widget.add_controller(motion);
    }

    // Static for the same reason wire_interactions() is - see PodcastCard's
    // own show_context_menu, the template this follows.
    private static void show_context_menu(Gtk.Box root_widget, Gtk.Button subscribe_btn, Paperboy.PodcastShow show, int64 feed_id, double x, double y, owned ActivatedCallback? on_play_requested) {
        var store = Paperboy.PodcastSubscriptionStore.get_instance();
        var menu = new PodcastMenu(store.is_subscribed(feed_id));

        menu.play_requested.connect(() => {
            if (on_play_requested != null) on_play_requested(feed_id);
        });
        menu.subscribe_requested.connect(() => {
            store.subscribe(show);
            PodcastCard.update_subscribe_button(subscribe_btn, feed_id);
        });
        menu.unsubscribe_requested.connect(() => {
            store.unsubscribe(feed_id);
            PodcastCard.update_subscribe_button(subscribe_btn, feed_id);
        });

        var popover = menu.create_popover(root_widget, x, y);
        root_widget.set_data("podcast-current-menu", menu);
        root_widget.set_data("podcast-current-popover", popover);
        popover.popup();
    }
}
