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
 * Persistent mini-player pinned to the bottom edge of the sidebar (attached
 * via Adw.ToolbarView.add_bottom_bar() in SidebarView.build_navigation_page),
 * independent of the main content pane. Slides up (Gtk.Revealer, SLIDE_UP -
 * matching the app's existing revealer-based show/hide idiom, e.g.
 * SidebarView's own sidebar_revealer) the first time an episode plays, and
 * stays visible for the rest of the session once anything has played.
 *
 * Binds to Managers.PodcastPlaybackManager's signals rather than owning
 * playback itself - the manager lives on NewsWindow so audio keeps playing
 * regardless of which page (news or podcasts) is currently shown.
 */
public class PodcastPlayerBar : GLib.Object {
    public Gtk.Revealer revealer;

    private Gtk.Picture cover;
    private Gtk.Label title_label;
    private Gtk.Scale scrubber;
    private Gtk.Adjustment scrubber_adjustment;
    private Gtk.Label elapsed_label;
    private Gtk.Label duration_label;
    private Gtk.Button play_pause_button;
    private Gtk.Image play_pause_icon;
    private Gtk.Button speed_button;

    // Guards against the scrubber's own value-changed handler re-issuing a
    // seek while we're only updating its position to reflect a
    // position_updated tick from the manager, not a user drag.
    private bool updating_from_playback = false;
    private weak NewsWindow? window;

    public PodcastPlayerBar(Managers.PodcastPlaybackManager playback, NewsPreferences prefs, NewsWindow? window) {
        GLib.Object();
        this.window = window;

        revealer = new Gtk.Revealer();
        revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_UP);
        revealer.set_transition_duration(200);
        revealer.set_reveal_child(false);

        // Flush against the sidebar's left/right/bottom edges (no margins
        // here - see PodcastPane for the same reasoning), so its border/
        // shadow actually reach them. Padding for the actual controls lives
        // on the inner content_box below instead.
        var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        box.add_css_class("podcast-player-bar");
        box.set_hexpand(true);
        box.set_halign(Gtk.Align.FILL);

        var content_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
        content_box.set_margin_start(12);
        content_box.set_margin_end(12);
        content_box.set_margin_top(10);
        content_box.set_margin_bottom(10);
        box.append(content_box);

        // Row 1: cover thumbnail + title
        var title_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);

        cover = new Gtk.Picture();
        cover.set_size_request(36, 36);
        cover.set_content_fit(Gtk.ContentFit.COVER);
        // See PodcastCard/PodcastHeroCard for why - both dimensions are
        // already fixed, so the aspect-ratio-driven natural size isn't
        // needed and would otherwise let a loaded texture with an unusual
        // aspect ratio distort this row's height.
        cover.set_keep_aspect_ratio(false);
        cover.add_css_class("podcast-player-cover");
        title_row.append(cover);

        title_label = new Gtk.Label("");
        title_label.set_ellipsize(Pango.EllipsizeMode.END);
        title_label.set_xalign(0);
        title_label.set_hexpand(true);
        title_label.add_css_class("podcast-player-title");
        title_row.append(title_label);

        var close_button = new Gtk.Button.from_icon_name("window-close-symbolic");
        close_button.add_css_class("flat");
        close_button.add_css_class("circular");
        close_button.set_tooltip_text("Close");
        title_row.append(close_button);

        content_box.append(title_row);

        // Row 2: seek scrubber + elapsed/duration labels
        var scrub_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);

        elapsed_label = new Gtk.Label("0:00");
        elapsed_label.add_css_class("podcast-player-time");
        scrub_row.append(elapsed_label);

        scrubber_adjustment = new Gtk.Adjustment(0, 0, 1, 1, 10, 0);
        scrubber = new Gtk.Scale(Gtk.Orientation.HORIZONTAL, scrubber_adjustment);
        scrubber.set_draw_value(false);
        scrubber.set_hexpand(true);
        scrub_row.append(scrubber);

        duration_label = new Gtk.Label("0:00");
        duration_label.add_css_class("podcast-player-time");
        scrub_row.append(duration_label);

        content_box.append(scrub_row);

        // Row 3: skip-back, play/pause, skip-forward, speed
        var controls_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
        controls_row.set_halign(Gtk.Align.CENTER);

        // Skip-to-previous/next-episode (not seek-within-episode) icons and
        // labels - see PodcastPlaybackManager.play_previous_episode/
        // play_next_episode.
        var skip_back_button = new Gtk.Button.from_icon_name("media-skip-backward-symbolic");
        skip_back_button.add_css_class("flat");
        skip_back_button.set_tooltip_text("Previous episode");
        controls_row.append(skip_back_button);

        play_pause_icon = new Gtk.Image.from_icon_name("media-playback-start-symbolic");
        play_pause_button = new Gtk.Button();
        play_pause_button.set_child(play_pause_icon);
        play_pause_button.add_css_class("flat");
        play_pause_button.add_css_class("circular");
        controls_row.append(play_pause_button);

        var skip_forward_button = new Gtk.Button.from_icon_name("media-skip-forward-symbolic");
        skip_forward_button.add_css_class("flat");
        skip_forward_button.set_tooltip_text("Next episode");
        controls_row.append(skip_forward_button);

        speed_button = new Gtk.Button.with_label(format_speed(prefs.podcast_playback_speed));
        speed_button.add_css_class("flat");
        speed_button.set_tooltip_text("Playback speed");
        controls_row.append(speed_button);

        content_box.append(controls_row);

        revealer.set_child(box);

        wire_interactions(playback, prefs, skip_back_button, skip_forward_button, play_pause_button, speed_button, scrubber, scrubber_adjustment, close_button);
    }

    // Push a newly-playing episode's title/cover into the bar and reveal it.
    // Called from the manager's episode_changed handler (see wire_interactions).
    public void set_episode(Paperboy.PodcastEpisode episode) {
        title_label.set_text(episode.title);
        if (window != null) {
            string? art_url = episode.image_url;
            if (art_url != null && art_url.length > 0) {
                window.image_manager.load_image_async(cover, art_url, 36, 36);
            }
        }
        revealer.set_reveal_child(true);
    }

    private static string format_speed(double rate) {
        if (rate == (int) rate) return "%dx".printf((int) rate);
        return "%.2fx".printf(rate).replace(".00x", "x");
    }

    private static string format_time(uint64 ns) {
        int64 total_seconds = (int64) (ns / 1000000000);
        int64 mins = total_seconds / 60;
        int64 secs = total_seconds % 60;
        return "%lld:%02lld".printf(mins, secs);
    }

    // Most of this wiring uses plain self-capturing closures rather than
    // HeroCard/ArticleCard/PodcastCard's static-function/set_data()
    // pattern. That pattern exists to avoid a root -> controller -> closure
    // -> self -> root cycle on objects created and torn down repeatedly
    // (a new HeroCard/ArticleCard per card, every category switch), where a
    // leaked cycle compounds across many instances. PodcastPlayerBar is
    // constructed exactly once for the app's whole lifetime (owned by
    // NewsWindow, never recreated), so the one closure below that does
    // capture self on a self-owned widget (`scrubber.change_value`, via the
    // `updating_from_playback` field) costs nothing in practice: NewsWindow
    // already keeps this object alive until the process exits either way.
    private void wire_interactions(Managers.PodcastPlaybackManager playback, NewsPreferences prefs, Gtk.Button skip_back_button, Gtk.Button skip_forward_button, Gtk.Button play_pause_button, Gtk.Button speed_button, Gtk.Scale scrubber, Gtk.Adjustment scrubber_adjustment, Gtk.Button close_button) {
        skip_back_button.clicked.connect(() => { playback.play_previous_episode(); });
        skip_forward_button.clicked.connect(() => { playback.play_next_episode(); });
        play_pause_button.clicked.connect(() => { playback.toggle_play_pause(); });

        close_button.clicked.connect(() => {
            playback.stop();
            revealer.set_reveal_child(false);
        });

        speed_button.clicked.connect(() => {
            double[] speeds = { 1.0, 1.25, 1.5, 2.0 };
            double current = prefs.podcast_playback_speed;
            int idx = 0;
            for (int i = 0; i < speeds.length; i++) {
                if (speeds[i] == current) { idx = i; break; }
            }
            double next_speed = speeds[(idx + 1) % speeds.length];
            prefs.podcast_playback_speed = next_speed;
            playback.set_rate(next_speed);
            speed_button.set_label(format_speed(next_speed));
        });

        scrubber.change_value.connect((scroll_type, value) => {
            updating_from_playback = true;
            playback.seek_to((uint64) value);
            updating_from_playback = false;
            return false;
        });

        playback.episode_changed.connect((episode) => {
            set_episode(episode);
        });

        playback.playback_state_changed.connect((is_playing) => {
            play_pause_icon.set_from_icon_name(is_playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic");
        });

        playback.position_updated.connect((position_ns, duration_ns) => {
            if (updating_from_playback) return;
            if (duration_ns > 0) {
                scrubber_adjustment.set_upper((double) duration_ns);
            }
            scrubber_adjustment.set_value((double) position_ns);
            elapsed_label.set_text(format_time(position_ns));
            duration_label.set_text(format_time(duration_ns));
        });

        playback.playback_error.connect((message) => {
            GLib.warning("Podcast playback error: %s", message);
        });
    }
}
