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

// Full-size image pop-out, opened from the expand button on Reader View's
// hero/inline images. Decodes a full-resolution, aspect-correct copy of the
// image before presenting, so Adw.Dialog's follows_content_size (which only
// measures once, at present() time) sizes itself correctly from the start
// instead of around a placeholder.
public class ImageViewerDialog : GLib.Object {
    // Weak field (not a `weak`/`unowned` local) so descendant closures can
    // reference the dialog without a ref cycle keeping it alive after close().
    private class DialogHandle : GLib.Object {
        public weak Adw.Dialog? target;
    }

    // Large enough to cover basically any screen without upscaling, capped
    // by ImageManager's own MAX_DECODE_DIM anyway.
    private const int FULL_RES_DIM = 2000;

    public static void show(Gtk.Window parent_window, Gdk.Paintable placeholder, string? image_url = null) {
        if (image_url == null || image_url.length == 0) {
            present_dialog(parent_window, placeholder);
            return;
        }

        var nav_window = parent_window as NewsWindow;
        string? disk_path = (nav_window != null && nav_window.meta_cache != null)
            ? nav_window.meta_cache.get_cached_path(image_url) : null;

        new GLib.Thread<void>("image-viewer-decode", () => {
            Gdk.Pixbuf? pix = null;

            if (disk_path != null) {
                try { pix = new Gdk.Pixbuf.from_file_at_scale(disk_path, FULL_RES_DIM, FULL_RES_DIM, true); } catch (GLib.Error e) { }
            }

            // No raw file on disk (e.g. the original download's Content-Type
            // wasn't one MetaCache recognizes, so it never wrote an image
            // file) - fetch it directly instead of giving up on full-res.
            if (pix == null) {
                try {
                    var client = Paperboy.HttpClientUtils.get_default();
                    var options = new Paperboy.HttpClientUtils.RequestOptions().with_image_headers();
                    var response = client.fetch_sync(image_url, options);
                    if (response.status_code == Soup.Status.OK && response.body != null) {
                        var loader = new Gdk.PixbufLoader();
                        loader.write(response.get_body_data());
                        loader.close();
                        var full_pix = loader.get_pixbuf();
                        if (full_pix != null) pix = scale_down_preserving_aspect(full_pix, FULL_RES_DIM);
                    }
                } catch (GLib.Error e) { }
            }

            if (pix != null) {
                GLib.debug("ImageViewerDialog: decoded %s -> %d x %d (%s)", image_url, pix.get_width(), pix.get_height(),
                    disk_path != null ? "disk cache" : "network");
            } else {
                GLib.debug("ImageViewerDialog: decode failed for %s, using reader placeholder", image_url);
            }

            Gdk.Paintable result = pix != null ? Gdk.Texture.for_pixbuf(pix) : placeholder;
            GLib.Idle.add(() => {
                present_dialog(parent_window, result);
                return false;
            });
        });
    }

    // Pinch / button zoom for the pop-out. Only holds weak widget refs and is
    // owned by the scroller (via set_data), and signal handlers are instance
    // methods (connected without a strong ref), so no gesture/button closure
    // forms a ref cycle that would keep the dialog's widgets alive.
    private class ZoomController : GLib.Object {
        private const double MIN_ZOOM = 1.0;
        private const double MAX_ZOOM = 5.0;
        private const double ZOOM_STEP = 1.25;

        private weak Gtk.ScrolledWindow? scroller;
        private weak Gtk.Picture? picture;
        private weak Gtk.Button? zoom_out_button;
        private weak Gtk.Button? zoom_in_button;
        // Fitted copy looks best at 1x; the full-res original stays sharp when zoomed.
        private Gdk.Paintable fitted_paintable;
        private Gdk.Paintable full_paintable;
        private int base_w;
        private int base_h;
        private double zoom = MIN_ZOOM;
        private double pinch_start_zoom = MIN_ZOOM;
        private double drag_start_h;
        private double drag_start_v;

        public ZoomController(Gtk.ScrolledWindow scroller, Gtk.Picture picture,
                              Gtk.Button zoom_out_button, Gtk.Button zoom_in_button,
                              Gdk.Paintable fitted_paintable, Gdk.Paintable full_paintable,
                              int base_w, int base_h) {
            this.scroller = scroller;
            this.picture = picture;
            this.zoom_out_button = zoom_out_button;
            this.zoom_in_button = zoom_in_button;
            this.fitted_paintable = fitted_paintable;
            this.full_paintable = full_paintable;
            this.base_w = base_w;
            this.base_h = base_h;

            zoom_out_button.clicked.connect(on_zoom_out_clicked);
            zoom_in_button.clicked.connect(on_zoom_in_clicked);

            // Handles both touchscreen and touchpad pinches.
            var pinch = new Gtk.GestureZoom();
            pinch.begin.connect(on_pinch_begin);
            pinch.scale_changed.connect(on_pinch_scale_changed);
            scroller.add_controller(pinch);

            // Click-and-drag panning for mouse users once zoomed in (touch
            // already pans via the scroller's own kinetic scrolling).
            var drag = new Gtk.GestureDrag();
            drag.set_button(Gdk.BUTTON_PRIMARY);
            drag.drag_begin.connect(on_drag_begin);
            drag.drag_update.connect(on_drag_update);
            scroller.add_controller(drag);

            update_controls();
        }

        private void on_zoom_out_clicked(Gtk.Button button) {
            zoom_about_center(zoom / ZOOM_STEP);
        }

        private void on_zoom_in_clicked(Gtk.Button button) {
            zoom_about_center(zoom * ZOOM_STEP);
        }

        private void on_pinch_begin(Gtk.Gesture gesture, Gdk.EventSequence? sequence) {
            pinch_start_zoom = zoom;
        }

        private void on_pinch_scale_changed(Gtk.GestureZoom gesture, double scale) {
            double cx, cy;
            if (gesture.get_bounding_box_center(out cx, out cy)) {
                set_zoom(pinch_start_zoom * scale, cx, cy);
            } else {
                zoom_about_center(pinch_start_zoom * scale);
            }
        }

        private void on_drag_begin(Gtk.GestureDrag gesture, double x, double y) {
            var sc = scroller;
            var device = gesture.get_device();
            if (sc == null || zoom <= MIN_ZOOM
                || (device != null && device.get_source() == Gdk.InputSource.TOUCHSCREEN)) {
                gesture.set_state(Gtk.EventSequenceState.DENIED);
                return;
            }
            drag_start_h = sc.get_hadjustment().get_value();
            drag_start_v = sc.get_vadjustment().get_value();
        }

        private void on_drag_update(Gtk.GestureDrag gesture, double dx, double dy) {
            var sc = scroller;
            if (sc == null) return;
            sc.get_hadjustment().set_value(drag_start_h - dx);
            sc.get_vadjustment().set_value(drag_start_v - dy);
        }

        private void zoom_about_center(double target) {
            var sc = scroller;
            if (sc == null) return;
            set_zoom(target, sc.get_width() / 2.0, sc.get_height() / 2.0);
        }

        // (anchor_x, anchor_y) is in scroller coordinates; the image point
        // under it stays put while the zoom level changes.
        private void set_zoom(double target, double anchor_x, double anchor_y) {
            var sc = scroller;
            var pic = picture;
            if (sc == null || pic == null) return;

            double new_zoom = target.clamp(MIN_ZOOM, MAX_ZOOM);
            if ((new_zoom - zoom).abs() < 0.001) return;

            var hadj = sc.get_hadjustment();
            var vadj = sc.get_vadjustment();
            double image_x = (hadj.get_value() + anchor_x) / zoom;
            double image_y = (vadj.get_value() + anchor_y) / zoom;

            zoom = new_zoom;
            int w = (int) Math.round(base_w * zoom);
            int h = (int) Math.round(base_h * zoom);
            pic.set_paintable(zoom > MIN_ZOOM ? full_paintable : fitted_paintable);
            pic.set_size_request(w, h);

            // The viewport only picks up the new size on its next allocation;
            // configure the adjustments now so the anchored scroll offset
            // isn't clamped against the old bounds.
            hadj.configure(image_x * zoom - anchor_x, 0, w,
                hadj.get_step_increment(), hadj.get_page_increment(), hadj.get_page_size());
            vadj.configure(image_y * zoom - anchor_y, 0, h,
                vadj.get_step_increment(), vadj.get_page_increment(), vadj.get_page_size());

            update_controls();
        }

        private void update_controls() {
            zoom_out_button?.set_sensitive(zoom > MIN_ZOOM + 0.001);
            zoom_in_button?.set_sensitive(zoom < MAX_ZOOM - 0.001);
            scroller?.set_cursor_from_name(zoom > MIN_ZOOM ? "grab" : null);
        }
    }

    private static Gdk.Pixbuf scale_down_preserving_aspect(Gdk.Pixbuf pix, int max_dim) {
        int w = pix.get_width();
        int h = pix.get_height();
        if (w <= max_dim && h <= max_dim) return pix;
        double scale = w >= h ? (double)max_dim / w : (double)max_dim / h;
        int new_w = int.max(1, (int)(w * scale));
        int new_h = int.max(1, (int)(h * scale));
        return pix.scale_simple(new_w, new_h, Gdk.InterpType.BILINEAR);
    }

    // Adw.Dialog's follows_content_size clamps the dialog to the parent
    // window's bounds when the content is taller than available space, but
    // only adjusts height - it leaves the requested width alone. That
    // mismatches the image's aspect ratio, so Gtk.ContentFit.CONTAIN then
    // shrinks the image further to fit and pads the sides with empty space.
    // Fitting the paintable to the available area ourselves first means the
    // dialog never needs to clamp, so no mismatch is ever introduced.
    private static Gdk.Paintable fit_to_window(Gtk.Window parent_window, Gdk.Paintable paintable) {
        int iw = paintable.get_intrinsic_width();
        int ih = paintable.get_intrinsic_height();
        if (iw <= 0 || ih <= 0) return paintable;

        const int MARGIN = 48;
        int avail_w = int.max(200, parent_window.get_width() - MARGIN);
        int avail_h = int.max(200, parent_window.get_height() - MARGIN);
        double scale = double.min(1.0, double.min((double) avail_w / iw, (double) avail_h / ih));
        if (scale >= 1.0) return paintable;

        int target_w = int.max(1, (int) (iw * scale));
        int target_h = int.max(1, (int) (ih * scale));
        var native = parent_window.get_native();
        if (native == null) return paintable;

        var snapshot = new Gtk.Snapshot();
        paintable.snapshot(snapshot, target_w, target_h);
        var node = snapshot.to_node();
        if (node == null) return paintable;
        return native.get_renderer().render_texture(node, null);
    }

    private static void present_dialog(Gtk.Window parent_window, Gdk.Paintable paintable) {
        var fitted_paintable = fit_to_window(parent_window, paintable);
        int fitted_w = fitted_paintable.get_intrinsic_width();
        int fitted_h = fitted_paintable.get_intrinsic_height();

        var picture = new Gtk.Picture.for_paintable(fitted_paintable);
        picture.set_content_fit(Gtk.ContentFit.CONTAIN);
        picture.set_can_shrink(true);
        // Adw.Dialog's follows_content_size only treats the child's natural
        // size as a hint and can still settle on a mismatched aspect ratio
        // (confirmed via an isolated repro - width and height get clamped
        // independently, breaking CONTAIN's fit). Pinning the picture to an
        // exact, centered size and telling the dialog that exact content
        // size directly leaves nothing for either to renegotiate.
        picture.set_size_request(fitted_w, fitted_h);
        picture.set_halign(Gtk.Align.CENTER);
        picture.set_valign(Gtk.Align.CENTER);

        // Fixed-size viewport onto the picture; zooming grows the picture's
        // size request and the scroller pans over it.
        var scroller = new Gtk.ScrolledWindow();
        scroller.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC);
        scroller.set_size_request(fitted_w, fitted_h);
        scroller.set_child(picture);

        var dialog = new Adw.Dialog();
        var handle = new DialogHandle();
        handle.target = dialog;

        // A plain floating close button over the image (same Overlay +
        // corner-widget shape as ReaderView's own expand button) instead of
        // Adw.HeaderBar - that always draws its own opaque bar and injects
        // its own close button regardless of styling/show_title, giving a
        // solid titlebar plus a duplicate close button.
        var close_button = new Gtk.Button.from_icon_name("window-close-symbolic");
        close_button.add_css_class("osd");
        close_button.add_css_class("circular");
        close_button.set_tooltip_text("Close");
        close_button.clicked.connect(() => { handle.target?.close(); });

        var zoom_out_button = new Gtk.Button.from_icon_name("zoom-out-symbolic");
        zoom_out_button.add_css_class("osd");
        zoom_out_button.add_css_class("circular");
        zoom_out_button.set_tooltip_text("Zoom Out");

        var zoom_in_button = new Gtk.Button.from_icon_name("zoom-in-symbolic");
        zoom_in_button.add_css_class("osd");
        zoom_in_button.add_css_class("circular");
        zoom_in_button.set_tooltip_text("Zoom In");

        var zoom_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        zoom_box.append(zoom_out_button);
        zoom_box.append(zoom_in_button);

        var zoom = new ZoomController(scroller, picture, zoom_out_button, zoom_in_button,
            fitted_paintable, paintable, fitted_w, fitted_h);
        // The scroller owns the controller; the controller only holds weak
        // widget refs, so nothing here outlives the dialog.
        scroller.set_data<ZoomController>("zoom-controller", zoom);

        // Gtk.Fixed, not Gtk.Overlay - a controller on an Overlay ancestor
        // leaks that subtree on destroy (confirmed via isolated repro).
        int btn_w;
        close_button.measure(Gtk.Orientation.HORIZONTAL, -1, null, out btn_w, null, null);
        int zoom_box_w, zoom_box_h;
        zoom_box.measure(Gtk.Orientation.HORIZONTAL, -1, null, out zoom_box_w, null, null);
        zoom_box.measure(Gtk.Orientation.VERTICAL, -1, null, out zoom_box_h, null, null);
        const int BTN_MARGIN = 8;

        var content = new Gtk.Fixed();
        content.put(scroller, 0, 0);
        content.put(close_button, fitted_w - btn_w - BTN_MARGIN, BTN_MARGIN);
        content.put(zoom_box, fitted_w - zoom_box_w - BTN_MARGIN, fitted_h - zoom_box_h - BTN_MARGIN);

        dialog.set_follows_content_size(false);
        dialog.set_content_width(fitted_w);
        dialog.set_content_height(fitted_h);
        dialog.set_child(content);
        dialog.present(parent_window);

        // Close when the app window loses focus (e.g. alt-tabbing away), not just via the close button.
        // Goes through handle too - a direct `dialog` capture here would poison the weak captures above.
        ulong focus_handler_id = parent_window.notify["is-active"].connect(() => {
            if (!parent_window.is_active) handle.target?.close();
        });

        // AdwDialog doesn't close on backdrop click by default and swallows pointer events
        // for the window while presented, so this must attach to the dialog itself.
        var click_outside = new Gtk.GestureClick();
        click_outside.set_propagation_phase(Gtk.PropagationPhase.CAPTURE);
        click_outside.pressed.connect((n_press, x, y) => {
            var target = handle.target;
            if (target == null) return;
            Graphene.Rect bounds;
            if (!content.compute_bounds(target, out bounds)) return;
            if (x < bounds.get_x() || x > bounds.get_x() + bounds.get_width()
                || y < bounds.get_y() || y > bounds.get_y() + bounds.get_height()) {
                target.close();
            }
        });
        ((Gtk.Widget) dialog).add_controller(click_outside);

        dialog.closed.connect(() => {
            parent_window.disconnect(focus_handler_id);
        });

        GLib.Timeout.add(300, () => {
            GLib.debug("ImageViewerDialog: dialog content size %d x %d, paintable %d x %d",
                dialog.get_content_width(), dialog.get_content_height(),
                paintable.get_intrinsic_width(), paintable.get_intrinsic_height());
            return false;
        });
    }
}
