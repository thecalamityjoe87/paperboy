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
 * - Bookmark "pop" animations: feedback icons appear centered, scale up subtly, and fade out
 *   when a user saves an article.
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

        public AnimationManager(NewsWindow win) {
            GLib.Object();
            this.window = win;
        }

        private Gtk.Widget? create_feedback_icon(int icon_size) {
            Gtk.Widget? try_bundled_feedback(int size) {
                string? fb = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "symbolic", "saved-feedback.svg"));
                if (fb == null) return null;

                var cache = ImageCache.get_global();
                int hi = size * 2;
                string key_hi = "pixbuf::file:%s::%dx%d".printf(fb, hi, hi);
                if (cache.get_or_load_file(key_hi, fb, hi, hi) != null) {
                    var tex = cache.get_texture(key_hi);
                    if (tex != null) {
                        var img = new Gtk.Image();
                        img.set_from_paintable(tex);
                        img.set_pixel_size(size);
                        return img;
                    }
                }
                string key_sz = "pixbuf::file:%s::%dx%d".printf(fb, size, size);
                if (cache.get_or_load_file(key_sz, fb, size, size) != null) {
                    var tex = cache.get_texture(key_sz);
                    if (tex != null) {
                        var img = new Gtk.Image();
                        img.set_from_paintable(tex);
                        img.set_pixel_size(size);
                        return img;
                    }
                }
                return null;
            }

            Gtk.Widget? widget = try_bundled_feedback(icon_size);
            if (widget != null) return widget;

            var theme = Gtk.IconTheme.get_for_display(Gdk.Display.get_default());
            if (theme != null && theme.has_icon("saved-feedback")) {
                return new Gtk.Image.from_icon_name("saved-feedback") { pixel_size = icon_size };
            }

            widget = CategoryIconsUtils.create_category_header_icon("saved", icon_size);
            if (widget != null) return widget;

            return new Gtk.Image.from_icon_name("user-bookmarks-symbolic") { pixel_size = icon_size };
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

        public void animate_bookmark_pop(Gtk.Widget card) {
            if (card == null || window == null) return;

            double sx = 0.0, sy = 0.0;
            if (!card.translate_coordinates(window.root_overlay, 0, 0, out sx, out sy)) return;

            int card_w = card.get_allocated_width();
            int card_h = card.get_allocated_height();
            int icon_size = 48;

            int center_x = (int) Math.round(sx + card_w / 2.0);
            int center_y = (int) Math.round(sy + card_h / 2.0);

            Gtk.Widget? pop = create_feedback_icon(icon_size);
            if (pop == null) return;

            pop.set_halign(Gtk.Align.START);
            pop.set_valign(Gtk.Align.START);
            pop.set_hexpand(false);
            pop.set_vexpand(false);

            // Set fixed base size at icon_size
            pop.set_size_request(icon_size, icon_size);

            // Set margin so center is aligned
            pop.set_margin_start(center_x - icon_size/2);
            pop.set_margin_top(center_y - icon_size/2);
            pop.set_opacity(0.0);

            window.root_overlay.add_overlay(pop);

            var opacity_target = new Adw.PropertyAnimationTarget((GLib.Object) pop, "opacity");

            // Animate scale using Gtk.Widget.set_scale() (if available) or via a custom transform
            // Start at 0.8, pop to 1.0 for subtle effect
            double start_scale = 0.8;
            double end_scale = 1.0;

            var scale_anim = new Adw.TimedAnimation(pop, start_scale, end_scale, 400u, null);
            scale_anim.set_easing(Adw.Easing.EASE_OUT);
            scale_anim.play();

            var fade_in_anim = new Adw.TimedAnimation(pop, 0.0, 1.0, 200u, opacity_target);
            fade_in_anim.set_easing(Adw.Easing.EASE_IN);
            fade_in_anim.play();

            GLib.Timeout.add(650u, () => {
                var fade_out_anim = new Adw.TimedAnimation(pop, 1.0, 0.0, 300u, opacity_target);
                fade_out_anim.set_easing(Adw.Easing.EASE_OUT);
                fade_out_anim.play();
                return false;
            });

            GLib.Timeout.add(1000u, () => {
                if (window.root_overlay != null) window.root_overlay.remove_overlay(pop);
                else pop.unparent();
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

