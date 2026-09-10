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
        int scrim_height = (int) (max_total_height * 0.45);
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
        play_button.set_tooltip_text("Play");
        badge_row.append(play_button);

        subscribe_button = new Gtk.Button();
        subscribe_button.add_css_class("podcast-card-badge-btn");
        update_subscribe_button_state();
        badge_row.append(subscribe_button);

        overlay.add_overlay(badge_row);

        root.append(overlay);
    }

    // See PodcastCard.update_subscribe_button_state() - identical logic,
    // duplicated rather than shared since these are two separate widget
    // classes with no common base to hang it on.
    private void update_subscribe_button_state() {
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
    public static void wire_interactions(Gtk.Box root_widget, PodcastHeroCard card, int64 feed_id, Managers.PodcastPlaybackManager? playback, owned ActivatedCallback? on_activated, owned ActivatedCallback? on_play_requested = null) {
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

        var right_click = new Gtk.GestureClick();
        right_click.set_button(3);
        right_click.pressed.connect((n_press, x, y) => {
            show_context_menu(root_widget, card, show, feed_id, x, y, on_play_requested);
        });
        root_widget.add_controller(right_click);

        var gesture = new Gtk.GestureClick();
        gesture.set_button(1);
        gesture.released.connect(() => {
            if (on_activated != null) on_activated(feed_id);
        });
        root_widget.add_controller(gesture);

        var motion = new Gtk.EventControllerMotion();
        motion.enter.connect(() => { root_widget.add_css_class("card-hover"); });
        motion.leave.connect(() => { root_widget.remove_css_class("card-hover"); });
        root_widget.add_controller(motion);
    }

    // Static for the same reason wire_interactions() is - see PodcastCard's
    // own show_context_menu, the template this follows.
    private static void show_context_menu(Gtk.Box root_widget, PodcastHeroCard card, Paperboy.PodcastShow show, int64 feed_id, double x, double y, owned ActivatedCallback? on_play_requested) {
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
        root_widget.set_data("podcast-current-menu", menu);
        root_widget.set_data("podcast-current-popover", popover);
        popover.popup();
    }
}
