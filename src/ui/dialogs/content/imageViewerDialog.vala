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

        // Gtk.Fixed, not Gtk.Overlay - a controller on an Overlay ancestor
        // leaks that subtree on destroy (confirmed via isolated repro).
        int btn_w;
        close_button.measure(Gtk.Orientation.HORIZONTAL, -1, null, out btn_w, null, null);
        const int BTN_MARGIN = 8;

        var content = new Gtk.Fixed();
        content.put(picture, 0, 0);
        content.put(close_button, fitted_w - btn_w - BTN_MARGIN, BTN_MARGIN);

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
