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
 * A podcast card for CategorySection's horizontally-scrolling rows.
 * Square cover art (podcast artwork is conventionally 1:1, unlike
 * ArticleCard's 16:9-ish thumbnails), title, and a secondary caption line.
 * Two named constructors share one widget tree since the only difference
 * is which id activates on click and what the secondary line shows:
 *  - for_show(): discovery/category rows - cover + show title + author.
 *    Click plays the show's most recent episode.
 *  - for_episode(): the "Your Shows" row - cover + episode title + show
 *    name/duration. Click plays that specific episode.
 */
public class PodcastCard : GLib.Object {
    // Card width and cover-art height are deliberately separate (unlike a
    // strict 1:1 square): a shorter image plus a fixed-height text area
    // below (same idea as ArticleCard.TITLE_AREA_HEIGHT) keeps the card's
    // total height predictable instead of growing with the title's natural
    // wrap, which was overflowing CategorySection's row and getting
    // clipped at the bottom.
    public const int IMAGE_WIDTH = 210;
    // Grown (rather than shrinking TITLE_AREA_HEIGHT back down, which would
    // reintroduce clipping on 2-line titles) so the card reads as
    // image-forward instead of giving the text area a near-equal share.
    public const int IMAGE_HEIGHT = 190;
    // Title is capped at 1 line (see title_label.set_lines below), not 2 -
    // that's what let this need to be as tall as 84px. Sized for the worst
    // case (1-line title + the subtitle line + top/bottom margins), same
    // fixed-budget reasoning as ArticleCard.TITLE_AREA_HEIGHT: it must
    // never depend on CategorySection's row growing to fit taller content,
    // since that row is sized once via ScrolledWindow.propagate_natural_
    // height and wasn't reliably re-measured once cards load in
    // asynchronously, clipping anything taller than this budget.
    public const int TITLE_AREA_HEIGHT = 56;
    // Kept for external callers (PodcastManager) that only need one size
    // for image-download requests - the width, since it's the larger/more
    // visually significant dimension for cover art.
    public const int IMAGE_SIZE = IMAGE_WIDTH;

    public Gtk.Box root;
    public Gtk.Overlay overlay;
    public Gtk.Picture image;
    public Gtk.Box title_box;
    public Gtk.Label title_label;
    public Gtk.Label subtitle_label;
    // Only populated for_show() (see build()) - for_episode() cards (the
    // "Your Shows" row) already play on click and have no separate show to
    // subscribe to, so they get neither badge.
    public Gtk.Button? play_button;
    public Gtk.Button? subscribe_button;

    public bool is_episode;
    public int64 feed_id;
    public int64 episode_id;
    // Full show, kept for_show() cards only - needed by the play/subscribe
    // badges and the right-click menu (PodcastSubscriptionStore.subscribe()
    // needs more than just feed_id: title/author/image_url/feed_url).
    public Paperboy.PodcastShow? show;

    public delegate void ShowActivatedCallback(int64 feed_id);
    public delegate void EpisodeActivatedCallback(int64 episode_id);

    public PodcastCard.for_show(Paperboy.PodcastShow show) {
        GLib.Object();
        this.is_episode = false;
        this.feed_id = show.feed_id;
        this.episode_id = 0;
        this.show = show;
        build(show.title, show.author ?? "");
    }

    public PodcastCard.for_episode(string title, string show_title, int64 duration_seconds, int64 episode_id) {
        GLib.Object();
        this.is_episode = true;
        this.episode_id = episode_id;
        this.feed_id = 0;
        this.show = null;
        build(title, "%s · %s".printf(show_title, format_duration(duration_seconds)));
    }

    private static string format_duration(int64 seconds) {
        if (seconds <= 0) return "";
        int64 mins = seconds / 60;
        int64 hrs = mins / 60;
        mins = mins % 60;
        if (hrs > 0) return "%lldh %lldm".printf(hrs, mins);
        return "%lldm".printf(mins);
    }

    private void build(string title, string subtitle) {
        root = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        root.add_css_class("card");
        // FILL + hexpand so root stretches to fill its search-grid cell.
        root.set_hexpand(true);
        root.set_halign(Gtk.Align.FILL);
        root.set_size_request(IMAGE_WIDTH, -1);

        image = new Gtk.Picture();
        image.set_halign(Gtk.Align.FILL);
        image.set_valign(Gtk.Align.FILL);
        image.set_hexpand(true);
        image.set_vexpand(true);
        image.set_content_fit(Gtk.ContentFit.COVER);
        image.set_keep_aspect_ratio(false);
        image.set_can_shrink(true);

        overlay = new Gtk.Overlay();
        overlay.set_child(image);
        overlay.set_halign(Gtk.Align.FILL);
        overlay.set_valign(Gtk.Align.START);
        overlay.set_hexpand(true);
        overlay.set_vexpand(false);
        overlay.set_size_request(IMAGE_WIDTH, IMAGE_HEIGHT);

        // Keeps the cover art's aspect ratio locked as root stretches
        // wider - a Gtk.AspectFrame was tried first but left visible gaps
        // on some cards' art, so this just tracks width->height directly.
        double target_ratio = (double) IMAGE_WIDTH / (double) IMAGE_HEIGHT;
        overlay.add_tick_callback((widget, frame_clock) => {
            int w = widget.get_width();
            if (w <= 0) return true;
            int wanted_h = (int) (w / target_ratio);
            if (wanted_h < 1) wanted_h = 1;
            int cur_w, cur_h;
            widget.get_size_request(out cur_w, out cur_h);
            if (cur_h != wanted_h) {
                widget.set_size_request(-1, wanted_h);
            }
            return true;
        });

        // Play/subscribe badges - for_show() cards only, bottom-right
        // corner. Click handlers are wired in wire_interactions() below.
        if (!is_episode) {
            var badge_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
            badge_row.add_css_class("card-corner-badges");
            badge_row.set_halign(Gtk.Align.END);
            badge_row.set_valign(Gtk.Align.END);
            badge_row.set_margin_end(8);
            badge_row.set_margin_bottom(8);

            play_button = new Gtk.Button.from_icon_name("media-playback-start-symbolic");
            play_button.add_css_class("podcast-card-badge-btn");
            play_button.set_tooltip_text("Play");
            badge_row.append(play_button);

            subscribe_button = new Gtk.Button();
            subscribe_button.add_css_class("podcast-card-badge-btn");
            update_subscribe_button_state();
            badge_row.append(subscribe_button);

            overlay.add_overlay(badge_row);

            // Hover-only "click for info" hint - fades in via CSS keyed
            // off the "card-hover" class wire_interactions() toggles below.
            var info_hint = new Gtk.Image.from_icon_name("dialog-information-symbolic");
            info_hint.add_css_class("podcast-card-info-hint");
            info_hint.set_halign(Gtk.Align.START);
            info_hint.set_valign(Gtk.Align.START);
            info_hint.set_margin_start(8);
            info_hint.set_margin_top(8);
            info_hint.set_tooltip_text("Click for details");
            overlay.add_overlay(info_hint);
        }

        root.append(overlay);

        // Fixed height (not natural sizing) so a long title's 2-line wrap
        // can never push the card's total height past what
        // CategorySection's row expects - same fixed-title-area approach
        // ArticleCard uses, for the same reason.
        title_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);
        title_box.set_margin_start(10);
        title_box.set_margin_end(10);
        title_box.set_margin_top(10);
        title_box.set_margin_bottom(10);
        title_box.set_size_request(IMAGE_WIDTH - 20, TITLE_AREA_HEIGHT);
        title_box.set_vexpand(false);
        title_box.set_valign(Gtk.Align.START);

        title_label = new Gtk.Label(title);
        title_label.add_css_class("article-card-title");
        title_label.set_ellipsize(Pango.EllipsizeMode.END);
        title_label.set_xalign(0);
        title_label.set_valign(Gtk.Align.START);
        // No wrap: set_wrap(true) makes Pango report the unwrapped text
        // width as natural size, overriding max_width_chars and stretching
        // the card for long titles. Plain ellipsize + max_width_chars
        // keeps every card at exactly IMAGE_WIDTH regardless of title length.
        title_label.set_max_width_chars(1);
        title_box.append(title_label);

        subtitle_label = new Gtk.Label(subtitle);
        subtitle_label.add_css_class("article-card-time");
        subtitle_label.set_ellipsize(Pango.EllipsizeMode.END);
        subtitle_label.set_xalign(0);
        subtitle_label.set_valign(Gtk.Align.START);
        subtitle_label.set_max_width_chars(1);
        title_box.append(subtitle_label);

        root.append(title_box);
    }

    // Reflects the current subscription state on subscribe_button's icon
    // and CSS - called once at build() and again after every successful
    // toggle in wire_interactions()/the context menu, so the badge never
    // goes stale after the user acts on it.
    private void update_subscribe_button_state() {
        if (subscribe_button == null) return;
        bool subscribed = Paperboy.PodcastSubscriptionStore.get_instance().is_subscribed(feed_id);
        subscribe_button.set_icon_name(subscribed ? "object-select-symbolic" : "list-add-symbolic");
        subscribe_button.set_tooltip_text(subscribed ? "Subscribed" : "Subscribe");
        if (subscribed) {
            subscribe_button.add_css_class("subscribed");
        } else {
            subscribe_button.remove_css_class("subscribed");
        }
    }

    // Static to avoid a root -> controller -> closure -> self -> root
    // cycle (see ArticleCard.wire_interactions). `card` is passed so
    // closures can call back into its own update_subscribe_button_state().
    public static void wire_interactions(Gtk.Box root_widget, PodcastCard card, bool is_episode, int64 feed_id, int64 episode_id, Managers.PodcastPlaybackManager? playback, owned ShowActivatedCallback? on_show_activated, owned EpisodeActivatedCallback? on_episode_activated, owned ShowActivatedCallback? on_play_requested = null) {
        if (!is_episode && card.play_button != null) {
            card.play_button.clicked.connect(() => {
                if (playback != null) {
                    var current = playback.get_current_episode();
                    if (current != null && current.feed_id == feed_id) {
                        // Already this show's episode loaded - toggle
                        // instead of restarting it.
                        playback.toggle_play_pause();
                        return;
                    }
                }
                // Distinct from on_show_activated (a plain card click,
                // which just opens PodcastPane without playing anything) -
                // the play badge should actually start playback.
                if (on_play_requested != null) on_play_requested(feed_id);
            });

            // Tick callback instead of connecting to playback's signals
            // directly - a direct connection would outlive the card once
            // it's cleared from the grid. A tick callback stops on its own
            // once play_button is unmapped.
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
        }

        if (!is_episode && card.subscribe_button != null && card.show != null) {
            var show = card.show;
            card.subscribe_button.clicked.connect(() => {
                var store = Paperboy.PodcastSubscriptionStore.get_instance();
                if (store.is_subscribed(feed_id)) {
                    store.unsubscribe(feed_id);
                } else {
                    store.subscribe(show);
                }
                card.update_subscribe_button_state();
            });
        }

        if (!is_episode && card.show != null) {
            var show = card.show;
            var right_click = new Gtk.GestureClick();
            right_click.set_button(3);
            right_click.pressed.connect((n_press, x, y) => {
                show_context_menu(root_widget, card, show, feed_id, x, y, on_play_requested);
            });
            root_widget.add_controller(right_click);
        }

        var gesture = new Gtk.GestureClick();
        gesture.set_button(1);
        gesture.released.connect(() => {
            if (is_episode) {
                if (on_episode_activated != null) on_episode_activated(episode_id);
            } else {
                if (on_show_activated != null) on_show_activated(feed_id);
            }
        });
        root_widget.add_controller(gesture);

        var motion = new Gtk.EventControllerMotion();
        motion.enter.connect(() => { root_widget.add_css_class("card-hover"); });
        motion.leave.connect(() => { root_widget.remove_css_class("card-hover"); });
        root_widget.add_controller(motion);
    }

    // Static for the same self-reference-cycle reason as wire_interactions()
    // itself (see ArticleCard.show_context_menu, the template this follows).
    private static void show_context_menu(Gtk.Box root_widget, PodcastCard card, Paperboy.PodcastShow show, int64 feed_id, double x, double y, owned ShowActivatedCallback? on_play_requested) {
        var store = Paperboy.PodcastSubscriptionStore.get_instance();
        var menu = new PodcastMenu(store.is_subscribed(feed_id));

        menu.play_requested.connect(() => {
            if (on_play_requested != null) on_play_requested(feed_id);
        });
        menu.subscribe_requested.connect(() => {
            store.subscribe(show);
            card.update_subscribe_button_state();
        });
        menu.unsubscribe_requested.connect(() => {
            store.unsubscribe(feed_id);
            card.update_subscribe_button_state();
        });

        var popover = menu.create_popover(root_widget, x, y);
        // Keep menu/popover alive on root_widget until it closes, same
        // lifetime convention ArticleCard.show_context_menu uses.
        root_widget.set_data("podcast-current-menu", menu);
        root_widget.set_data("podcast-current-popover", popover);
        popover.popup();
    }
}
