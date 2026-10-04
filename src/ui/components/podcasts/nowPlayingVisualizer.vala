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
 * Small bouncing-bars "now playing" indicator for the sidebar footer's
 * Now Playing row (see SidebarView.build_footer). Shown only while a
 * podcast is actually playing.
 *
 * Decorative, not a real level meter: each bar follows its own pair of
 * out-of-phase sine waves, which reads as audio activity without tapping
 * Gst.Player's pipeline for spectrum data. Bars are drawn in the widget's
 * CSS color (.now-playing-visualizer), so they follow the theme like the
 * unread-count badges they line up with.
 *
 * Animates on the frame clock only while `playing` is set and mapped; with
 * GTK animations disabled (reduced-motion setting) it draws still bars.
 */
public class NowPlayingVisualizer : Gtk.Widget {
    private const int BAR_COUNT = 3;
    private const float BAR_WIDTH = 3.0f;
    private const float BAR_GAP = 2.0f;
    private const int HEIGHT = 12;
    // Per-bar wave speeds (radians/sec) and phase offsets, deliberately
    // unrelated so the bars never visibly sync up.
    private const double[] SPEEDS_A = { 7.1, 9.3, 6.2 };
    private const double[] SPEEDS_B = { 3.3, 4.7, 5.9 };
    private const double[] PHASES = { 0.0, 1.9, 4.1 };
    private const double[] STILL_LEVELS = { 0.55, 1.0, 0.75 };

    private uint tick_id = 0;
    private bool _playing = false;

    construct {
        add_css_class("now-playing-visualizer");
        set_valign(Gtk.Align.CENTER);
        set_halign(Gtk.Align.END);
        set_visible(false);
    }

    public bool playing {
        get { return _playing; }
        set {
            if (_playing == value) return;
            _playing = value;
            set_visible(value);
            if (value && animations_enabled()) {
                if (tick_id == 0) {
                    tick_id = add_tick_callback(() => {
                        queue_draw();
                        return GLib.Source.CONTINUE;
                    });
                }
            } else if (tick_id != 0) {
                remove_tick_callback(tick_id);
                tick_id = 0;
            }
            queue_draw();
        }
    }

    private bool animations_enabled() {
        var settings = Gtk.Settings.get_default();
        return settings == null || settings.gtk_enable_animations;
    }

    public override void measure(Gtk.Orientation orientation, int for_size,
            out int minimum, out int natural, out int minimum_baseline, out int natural_baseline) {
        minimum_baseline = -1;
        natural_baseline = -1;
        if (orientation == Gtk.Orientation.HORIZONTAL) {
            minimum = natural = (int) Math.ceil(BAR_COUNT * BAR_WIDTH + (BAR_COUNT - 1) * BAR_GAP);
        } else {
            minimum = natural = HEIGHT;
        }
    }

    public override void snapshot(Gtk.Snapshot snapshot) {
        int h = get_height();
        if (h <= 0) return;

        double t = 0.0;
        var clock = get_frame_clock();
        bool animate = tick_id != 0 && clock != null;
        if (animate) t = clock.get_frame_time() / 1000000.0;

        var color = get_color();
        for (int i = 0; i < BAR_COUNT; i++) {
            double level;
            if (animate) {
                // Two summed sines -> 0..1, floored so a bar never vanishes.
                double wave = (Math.sin(t * SPEEDS_A[i] + PHASES[i]) + Math.sin(t * SPEEDS_B[i] + PHASES[i] * 0.5)) / 2.0;
                level = 0.25 + 0.75 * ((wave + 1.0) / 2.0);
            } else {
                level = STILL_LEVELS[i];
            }
            float bar_h = (float) Math.fmax(BAR_WIDTH, h * level);
            float x = i * (BAR_WIDTH + BAR_GAP);
            // Bottom-anchored, like a level meter.
            var rect = Graphene.Rect().init(x, h - bar_h, BAR_WIDTH, bar_h);
            var rounded = Gsk.RoundedRect();
            rounded.init_from_rect(rect, BAR_WIDTH / 2.0f);
            snapshot.push_rounded_clip(rounded);
            snapshot.append_color(color, rect);
            snapshot.pop();
        }
    }
}
