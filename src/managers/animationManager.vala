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
using Adw;
using Gdk;

/*
 * AnimationManager handles lightweight, non-intrusive animations for UI widgets.
 *
 * Current features:
 * - Card entrance animations: widgets fade and slide in when added to the UI.
 * - Save/unsave feedback (animate_save_toggle): the card's persistent save
 *   ribbon slides down/retracts, and saving flies a small ghost to the
 *   Saved sidebar entry, which pops once it lands.
 *
 */

namespace Managers {

    private class MarginAdapter : GLib.Object {
        public double offset { get; set; }
        private weak Gtk.Widget? widget;
        private bool horizontal = false;

        public MarginAdapter(Gtk.Widget w, double initial, bool horizontal = false) {
            GLib.Object();
            widget = w;
            this.offset = initial;
            this.horizontal = horizontal;

            int m = (int) Math.round(this.offset);
            if (widget != null) {
                if (this.horizontal) widget.set_margin_start(m); else widget.set_margin_top(m);
            }

            this.notify.connect((o, pspec) => {
                if (pspec.get_name() == "offset") {
                    int mi = (int) Math.round(this.offset);
                    if (widget != null) {
                        if (this.horizontal) widget.set_margin_start(mi); else widget.set_margin_top(mi);
                    }
                }
            });
        }
    }

    private class ScaleAdapter : GLib.Object {
        public double scale { get; set; }
        private weak Gtk.Widget? widget;
        private int base_size;

        public ScaleAdapter(Gtk.Widget w, int base_size, double initial) {
            GLib.Object();
            widget = w;
            this.base_size = base_size;
            this.scale = initial;
            if (widget != null) widget.set_size_request((int) Math.round(this.base_size * this.scale), (int) Math.round(this.base_size * this.scale));
            this.notify.connect((o, pspec) => {
                if (pspec.get_name() == "scale") {
                    if (widget != null) widget.set_size_request((int) Math.round(this.base_size * this.scale), (int) Math.round(this.base_size * this.scale));
                }
            });
        }
    }

    // Drives the "fly to shelf" ghost: one progress value maps to both
    // position and size, so they stay in lockstep on a single curve.
    private class FlyShrinkAdapter : GLib.Object {
        public double progress { get; set; }
        private weak Gtk.Widget? widget;
        private double start_x; private double start_y;
        private double end_x; private double end_y;
        private int start_w; private int start_h;
        private int end_w; private int end_h;

        public FlyShrinkAdapter(Gtk.Widget w, double start_x, double start_y, double end_x, double end_y,
                                 int start_w, int start_h, int end_w, int end_h) {
            GLib.Object();
            widget = w;
            this.start_x = start_x; this.start_y = start_y;
            this.end_x = end_x; this.end_y = end_y;
            this.start_w = start_w; this.start_h = start_h;
            this.end_w = end_w; this.end_h = end_h;
            this.progress = 0.0;
            apply();
            this.notify.connect((o, pspec) => {
                if (pspec.get_name() == "progress") apply();
            });
        }

        private void apply() {
            if (widget == null) return;
            double t = this.progress;
            double x = start_x + (end_x - start_x) * t;
            double y = start_y + (end_y - start_y) * t;
            int w = (int) Math.round(start_w + (end_w - start_w) * t);
            int h = (int) Math.round(start_h + (end_h - start_h) * t);
            if (w < 1) w = 1;
            if (h < 1) h = 1;
            widget.set_size_request(w, h);
            widget.set_margin_start((int) Math.round(x));
            widget.set_margin_top((int) Math.round(y));
        }
    }

    // Per-card save-animation bookkeeping, so a rapid re-click cancels
    // whatever that card was already mid-way through instead of leaving an
    // orphaned ghost widget flying.
    private class SaveAnimState : GLib.Object {
        public uint generation = 0;
        public Gtk.Widget? ghost;
        public Adw.TimedAnimation? ribbon_anim;
    }

    /* PopScaleAdapter keeps the widget centered at a fixed overlay coordinate
     * while its size_request is animated. This prevents lateral movement when
     * scaling the widget by adjusting margins to keep the visual center fixed.
     */
    private class PopScaleAdapter : GLib.Object {
        public double scale { get; set; }
        private weak Gtk.Widget? widget;
        private int base_size;
        private int center_x;
        private int center_y;

        public PopScaleAdapter(Gtk.Widget w, int base_size, int center_x, int center_y, double initial) {
            GLib.Object();
            widget = w;
            this.base_size = base_size;
            this.center_x = center_x;
            this.center_y = center_y;
            this.scale = initial;

            update_all();

            this.notify.connect((o, pspec) => {
                if (pspec.get_name() == "scale") update_all();
            });
        }

        private void update_all() {
            if (widget == null) return;
            double raw_size = (double) this.base_size * this.scale;
            int size = (int) Math.round(raw_size);
            if (size < 0) size = 0;
            widget.set_size_request(size, size);

            // Use floating math and round to avoid integer truncation jitter
            double half = raw_size / 2.0;
            int margin_start = (int) Math.round((double) this.center_x - half);
            int margin_top = (int) Math.round((double) this.center_y - half);
            widget.set_margin_start(margin_start);
            widget.set_margin_top(margin_top);
        }
    }

    public class AnimationManager : GLib.Object {
        private weak NewsWindow window;

        // Keeps entrance animations alive for their full run - otherwise
        // only referenced by local variables, which Vala unrefs as soon as
        // animate_card_entrance() returns, risking a card frozen mid-
        // transition with a lingering margin. Entries remove themselves on
        // the animation's "done" signal.
        private Gee.ArrayList<GLib.Object> active_entrance_animations = new Gee.ArrayList<GLib.Object>();

        // Keyed by each card's save ribbon, so repeated toggling of the
        // same card reuses (and cancels) its own in-flight state rather
        // than any other card's.
        private Gee.HashMap<Gtk.Widget, SaveAnimState> save_anim_states = new Gee.HashMap<Gtk.Widget, SaveAnimState>();

        // Same reasoning as active_entrance_animations, for the save
        // ribbon/ghost/arrival-pulse animations below.
        private Gee.ArrayList<GLib.Object> active_save_animations = new Gee.ArrayList<GLib.Object>();

        public AnimationManager(NewsWindow win) {
            GLib.Object();
            this.window = win;
        }

        private SaveAnimState get_save_anim_state(Gtk.Widget key) {
            var s = save_anim_states.get(key);
            if (s == null) {
                s = new SaveAnimState();
                save_anim_states.set(key, s);
            }
            return s;
        }

        public void animate_card_entrance(Gtk.Widget widget, uint delay_ms) {
            if (widget == null) return;

            widget.set_visible(true);
            widget.set_opacity(0.0);
            int initial_margin = 18;
            widget.set_margin_top(initial_margin);

            var opacity_target = new Adw.PropertyAnimationTarget((GLib.Object) widget, "opacity");
            var margin_adapter = new MarginAdapter(widget, (double) initial_margin);
            var margin_target = new Adw.PropertyAnimationTarget((GLib.Object) margin_adapter, "offset");

            uint duration = 320u;
            Adw.Easing easing = Adw.Easing.EASE_OUT;

            var anim_opacity = new Adw.TimedAnimation(widget, 0.0, 1.0, duration, opacity_target);
            anim_opacity.set_easing(easing);
            var anim_margin = new Adw.TimedAnimation(widget, initial_margin, 0.0, duration, margin_target);
            anim_margin.set_easing(easing);

            // See active_entrance_animations above.
            active_entrance_animations.add(margin_adapter);
            active_entrance_animations.add(opacity_target);
            active_entrance_animations.add(margin_target);
            active_entrance_animations.add(anim_opacity);
            active_entrance_animations.add(anim_margin);
            anim_opacity.done.connect(() => {
                active_entrance_animations.remove(anim_opacity);
                active_entrance_animations.remove(opacity_target);
            });
            anim_margin.done.connect(() => {
                active_entrance_animations.remove(anim_margin);
                active_entrance_animations.remove(margin_target);
                active_entrance_animations.remove(margin_adapter);
                // Belt-and-suspenders: force the margin to its final value
                // in case the animation was ever interrupted (widget torn
                // down mid-flight, etc.) before reaching it on its own.
                if (widget != null) widget.set_margin_top(0);
            });

            if (delay_ms == 0) {
                anim_opacity.play();
                anim_margin.play();
            } else {
                GLib.Timeout.add(delay_ms, () => { anim_opacity.play(); anim_margin.play(); return false; });
            }
        }

        public void animate_card_entrance_stagger(Gtk.Widget widget, uint index, uint per_item_ms) {
            animate_card_entrance(widget, index * per_item_ms);
        }

        // Fade-in for the "Read" badge the first time it appears on a
        // card (see ViewStateManager.add_viewed_badge_to).
        public void animate_viewed_badge_pop(Gtk.Widget badge) {
            if (badge == null) return;
            badge.set_opacity(0.0);

            // Usually fires from preview_closed(), which restores scroll
            // position around the same time - starting immediately meant
            // this played out while the view was still settling, easy to
            // miss. Wait for that to finish first.
            GLib.Timeout.add(150, () => {
                if (badge.get_root() == null) return false; // torn down in the meantime

                var opacity_target = new Adw.PropertyAnimationTarget((GLib.Object) badge, "opacity");
                var fade_anim = new Adw.TimedAnimation(badge, 0.0, 1.0, 260u, opacity_target);
                fade_anim.set_easing(Adw.Easing.EASE_OUT);

                active_save_animations.add(opacity_target);
                active_save_animations.add(fade_anim);
                fade_anim.done.connect(() => {
                    active_save_animations.remove(fade_anim);
                    active_save_animations.remove(opacity_target);
                });
                fade_anim.play();
                return false;
            });
        }

        // Save/unsave feedback: slides the card's save ribbon down/back up,
        // and - only when saving - flies a ghost to the Saved sidebar
        // entry, which pops once it lands and only then bumps its count.
        // `is_saved` is the state the article is IN after this toggle.
        public void animate_save_toggle(Gtk.Widget card, Gtk.Widget save_ribbon, string title, bool is_saved) {
            if (card == null || save_ribbon == null || window == null) return;

            var state = get_save_anim_state(save_ribbon);
            uint my_gen = ++state.generation;

            // A rapid re-click drops any in-flight ghost rather than
            // leaving it orphaned mid-flight.
            if (state.ghost != null) {
                if (window.root_overlay != null) window.root_overlay.remove_overlay(state.ghost);
                state.ghost = null;
            }
            if (state.ribbon_anim != null) state.ribbon_anim.skip();

            // Slide the whole ribbon as one rigid piece between fully
            // hidden and its resting position - driven manually since
            // Gtk.Revealer's transitions grow/clip the shape open instead
            // of translating it.
            int rest = CardBuilder.SAVE_RIBBON_REST_MARGIN;
            int hidden = CardBuilder.SAVE_RIBBON_HIDDEN_MARGIN;
            var margin_adapter = new MarginAdapter(save_ribbon, (double) save_ribbon.get_margin_top());
            var margin_target = new Adw.PropertyAnimationTarget((GLib.Object) margin_adapter, "offset");

            if (is_saved) {
                save_ribbon.set_visible(true);
                var anim = new Adw.TimedAnimation(save_ribbon, save_ribbon.get_margin_top(), rest, 450u, margin_target);
                anim.set_easing(Adw.Easing.EASE_OUT_BACK);
                state.ribbon_anim = anim;
                active_save_animations.add(margin_adapter);
                active_save_animations.add(margin_target);
                active_save_animations.add(anim);
                anim.done.connect(() => {
                    active_save_animations.remove(anim);
                    active_save_animations.remove(margin_target);
                    active_save_animations.remove(margin_adapter);
                    if (state.ribbon_anim == anim) state.ribbon_anim = null;
                    save_ribbon.set_margin_top(rest);
                });
                anim.play();
            } else {
                var anim = new Adw.TimedAnimation(save_ribbon, save_ribbon.get_margin_top(), hidden, 250u, margin_target);
                anim.set_easing(Adw.Easing.EASE_IN);
                state.ribbon_anim = anim;
                active_save_animations.add(margin_adapter);
                active_save_animations.add(margin_target);
                active_save_animations.add(anim);
                anim.done.connect(() => {
                    active_save_animations.remove(anim);
                    active_save_animations.remove(margin_target);
                    active_save_animations.remove(margin_adapter);
                    if (state.ribbon_anim == anim) state.ribbon_anim = null;
                    save_ribbon.set_margin_top(hidden);
                    // Only now remove it from the corner row's layout, so
                    // the "Viewed" badge doesn't jump left mid-slide.
                    save_ribbon.set_visible(false);
                });
                anim.play();
            }

            if (!is_saved) {
                // Unsaving: no fly-back, nothing to travel - decrement now.
                if (window.sidebar_manager != null) window.sidebar_manager.update_badge_for_category("saved");
                return;
            }

            // Saving: send the ghost on its way. The Saved count only bumps
            // once it actually lands (see spawn_save_ghost) rather than up front.
            spawn_save_ghost(card, title, state, my_gen);
        }

        // Builds the small "flying ghost" (icon + truncated title) at the
        // card's position and animates it toward the Saved sidebar entry,
        // shrinking and fading out, popping the sidebar and updating the
        // Saved count only once it lands.
        private void spawn_save_ghost(Gtk.Widget card, string title, SaveAnimState state, uint my_gen) {
            if (window == null || window.root_overlay == null) return;
            if (card.get_root() == null) return; // card was torn down before this fired

            double sx = 0.0, sy = 0.0;
            if (!card.translate_coordinates(window.root_overlay, 0, 0, out sx, out sy)) return;
            int card_h = card.get_allocated_height();

            var ghost = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
            ghost.add_css_class("save-ghost");
            var icon = new Gtk.Image.from_icon_name("user-bookmarks-symbolic");
            icon.set_pixel_size(14);
            ghost.append(icon);
            string truncated = title != null ? title : "";
            if (truncated.char_count() > 28) truncated = truncated.substring(0, 26) + "…";
            var label = new Gtk.Label(truncated);
            label.set_ellipsize(Pango.EllipsizeMode.END);
            ghost.append(label);
            ghost.set_halign(Gtk.Align.START);
            ghost.set_valign(Gtk.Align.START);

            int start_x = (int) Math.round(sx + 14);
            int start_y = (int) Math.round(sy + card_h / 2.0 - 16);
            ghost.set_margin_start(start_x);
            ghost.set_margin_top(start_y);

            window.root_overlay.add_overlay(ghost);
            state.ghost = ghost;

            // Wait a frame so the ghost has a real allocated size before
            // computing where its own center (and thus the fly target) is.
            GLib.Idle.add(() => {
                if (state.generation != my_gen || state.ghost != ghost) {
                    // Superseded mid-setup - this ghost never got to fly.
                    if (window.root_overlay != null) window.root_overlay.remove_overlay(ghost);
                    return false;
                }

                int ghost_w = ghost.get_allocated_width();
                int ghost_h = ghost.get_allocated_height();
                if (ghost_w <= 0) ghost_w = 160;
                if (ghost_h <= 0) ghost_h = 32;

                // Target the row's icon, not the row itself (mostly empty
                // space) or its count badge (hidden until nonzero).
                Gtk.Widget? shelf = window.sidebar_view != null ? window.sidebar_view.get_icon_widget("saved") : null;
                if (shelf == null || !shelf.get_mapped()) {
                    shelf = window.sidebar_view != null ? window.sidebar_view.get_item_widget("saved") : null;
                }
                double dx = 0.0, dy = 0.0;
                bool have_target = shelf != null && shelf.get_mapped()
                    && shelf.translate_coordinates(window.root_overlay, 0, 0, out dx, out dy);
                double target_cx = have_target ? dx + shelf.get_allocated_width() / 2.0 : start_x + ghost_w / 2.0;
                double target_cy = have_target ? dy + shelf.get_allocated_height() / 2.0 : start_y - 40;

                int end_w = int.max(1, (int) Math.round(ghost_w * 0.25));
                int end_h = int.max(1, (int) Math.round(ghost_h * 0.25));
                double end_x = target_cx - end_w / 2.0;
                double end_y = target_cy - end_h / 2.0;

                var fly_adapter = new FlyShrinkAdapter(ghost, start_x, start_y, end_x, end_y, ghost_w, ghost_h, end_w, end_h);
                var fly_target = new Adw.PropertyAnimationTarget((GLib.Object) fly_adapter, "progress");
                var fly_anim = new Adw.TimedAnimation(ghost, 0.0, 1.0, 550u, fly_target);
                fly_anim.set_easing(Adw.Easing.EASE_IN_OUT_CUBIC);

                var fade_target = new Adw.PropertyAnimationTarget((GLib.Object) ghost, "opacity");
                var fade_anim = new Adw.TimedAnimation(ghost, 1.0, 0.0, 550u, fade_target);
                fade_anim.set_easing(Adw.Easing.EASE_IN);

                // See active_entrance_animations above - without this the
                // ghost previously stopped short instead of completing.
                active_save_animations.add(fly_adapter);
                active_save_animations.add(fly_target);
                active_save_animations.add(fade_target);
                active_save_animations.add(fly_anim);
                active_save_animations.add(fade_anim);

                fly_anim.done.connect(() => {
                    active_save_animations.remove(fly_anim);
                    active_save_animations.remove(fly_target);
                    active_save_animations.remove(fly_adapter);
                    if (state.ghost == ghost) {
                        if (window.root_overlay != null) window.root_overlay.remove_overlay(ghost);
                        state.ghost = null;
                    }
                    if (state.generation != my_gen) return; // superseded meanwhile

                    if (window.sidebar_manager != null) window.sidebar_manager.update_badge_for_category("saved");
                    pop_sidebar_saved_row();
                });
                fade_anim.done.connect(() => {
                    active_save_animations.remove(fade_anim);
                    active_save_animations.remove(fade_target);
                });

                fly_anim.play();
                fade_anim.play();
                return false;
            });
        }

        // Arrival feedback once the ghost lands: a soft background pulse
        // on the real sidebar row, not a scale pop or a floating copy.
        private void pop_sidebar_saved_row() {
            if (window == null || window.sidebar_view == null) return;

            Gtk.Widget? row = window.sidebar_view.get_item_widget("saved");
            if (row == null) return;

            // The actual fade in/out is a CSS transition on this class (see
            // .save-arrival-pulse in style.css) - just hold it long enough
            // for that transition to play both ways before removing it.
            row.add_css_class("save-arrival-pulse");
            GLib.Timeout.add(350, () => {
                row.remove_css_class("save-arrival-pulse");
                return false;
            });
        }

        private uint get_exit_duration_ms() { return 180u; }

        private void animate_fade(Gtk.Widget widget, double start_opacity, double end_opacity, uint duration, Adw.Easing easing) {
            var target = new Adw.PropertyAnimationTarget((GLib.Object) widget, "opacity");
            var anim = new Adw.TimedAnimation(widget, start_opacity, end_opacity, duration, target);
            anim.set_easing(easing);
            anim.play();
        }

        public void animate_card_exit_and_remove(Gtk.Widget widget, uint delay_ms) {
            if (widget == null) return;

            widget.set_visible(true);
            var opacity_target = new Adw.PropertyAnimationTarget((GLib.Object) widget, "opacity");
            var margin_adapter = new MarginAdapter(widget, 0.0);
            var margin_target = new Adw.PropertyAnimationTarget((GLib.Object) margin_adapter, "offset");

            int end_margin = -12;
            uint duration = get_exit_duration_ms();
            Adw.Easing easing = Adw.Easing.EASE_OUT;

            var anim_opacity = new Adw.TimedAnimation(widget, 1.0, 0.0, duration, opacity_target);
            anim_opacity.set_easing(easing);
            var anim_margin = new Adw.TimedAnimation(widget, 0.0, end_margin, duration, margin_target);
            anim_margin.set_easing(easing);

            if (delay_ms == 0) {
                anim_opacity.play();
                anim_margin.play();
            } else {
                GLib.Timeout.add(delay_ms, () => { anim_opacity.play(); anim_margin.play(); return false; });
            }

            uint total_delay = delay_ms + duration + 30u;
            GLib.Timeout.add(total_delay, () => {
                var parent = widget.get_parent();
                if (parent != null && parent is Gtk.Box) ((Gtk.Box) parent).remove(widget);
                else widget.unparent();
                return false;
            });
        }
    }
}

