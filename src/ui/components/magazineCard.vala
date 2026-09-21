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

// A magazine library grid card - same shape as PodcastHeroCard: a fixed-
// size box, full-bleed cover art (ContentFit.COVER, cropped to fill - same
// as PodcastCard's own square art, no special-casing), and the title/
// subtitle overlaid on it behind a bottom-pinned dark gradient scrim
// (.hero-card-podcast/.hero-podcast-scrim). Every card shares one fixed
// size, same as every other card grid in the app.
public class MagazineCard : GLib.Object {
    public const int IMAGE_WIDTH = 220;
    public const int IMAGE_HEIGHT = 300;

    public Gtk.Box root;
    public Gtk.DrawingArea image;
    public Gtk.Label title_label;
    public Gtk.Label subtitle_label;

    public int64 entry_id;

    public delegate void EntryActivatedCallback(int64 entry_id);
    public delegate void EntryRemoveRequestedCallback(int64 entry_id);
    public delegate void EntrySetCategoryRequestedCallback(int64 entry_id);
    // dragged_entry_id was dropped onto target_entry_id (this card) -
    // the caller decides what "dropped onto" means for ordering.
    public delegate void EntryReorderRequestedCallback(int64 dragged_entry_id, int64 target_entry_id);
    // Fires true when a drag starts on this card, false when it ends -
    // lets the caller show the trash drop zone only while a drag is
    // actually in progress.
    public delegate void DragStateChangedCallback(bool dragging);

    public MagazineCard.for_entry(Paperboy.MagazineEntry entry) {
        GLib.Object();
        this.entry_id = entry.id;
        string domain = UrlUtils.extract_host_from_url(entry.source_url) ?? "";
        build(entry.title, domain);

        if (entry.thumbnail_path != null) {
            try {
                var pix = new Gdk.Pixbuf.from_file(entry.thumbnail_path);
                image.set_data<Gdk.Pixbuf>("cover-pixbuf", pix);
                image.queue_draw();
            } catch (GLib.Error e) {
                // Falls back to the placeholder set in build() below.
            }
        }
    }

    private void build(string title, string subtitle) {
        root = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        // Both classes, like PodcastHeroCard - "card" supplies the root
        // box's own border-radius (rounded corners on the overall card
        // silhouette), "hero-card-podcast" overrides its border/shadow and
        // rounds the nested picture node to match.
        root.add_css_class("card");
        root.add_css_class("hero-card-podcast");
        // hexpand/halign deliberately left to the caller - the flat grid
        // (a homogeneous FlowBox) and a category row (a horizontal Box in
        // a ScrolledWindow, which never over-allocates past a child's
        // natural size) want different sizing behavior, and there's no
        // single default here that suits both. See render_flat_grid() and
        // build_category_row() in MagazineLibraryManager.
        root.set_size_request(IMAGE_WIDTH, IMAGE_HEIGHT);

        // Placeholder document icon sits underneath the picture - visible
        // whenever there's no thumbnail at all, since a Gtk.Picture with no
        // paintable set is transparent rather than blank white.
        var placeholder_icon = new Gtk.Image.from_icon_name("x-office-document-symbolic");
        placeholder_icon.set_pixel_size(48);
        placeholder_icon.add_css_class("dim-label");

        image = new Gtk.DrawingArea();
        image.add_css_class("magazine-cover-canvas");
        image.set_overflow(Gtk.Overflow.HIDDEN);
        image.set_halign(Gtk.Align.FILL);
        image.set_valign(Gtk.Align.FILL);
        image.set_hexpand(true);
        image.set_vexpand(true);

        // Full-bleed cover fill, top-anchored (crop comes off the bottom)
        // instead of Picture's centered COVER crop. Reads the pixbuf off
        // the widget itself rather than capturing `this`, so the closure
        // doesn't pin this MagazineCard wrapper alive forever.
        image.set_draw_func((area, cr, width, height) => {
            Gdk.Pixbuf? pix = area.get_data<Gdk.Pixbuf>("cover-pixbuf");
            if (pix == null) return;
            int src_w = pix.get_width();
            int src_h = pix.get_height();
            if (src_w <= 0 || src_h <= 0) return;

            double scale = double.max((double) width / src_w, (double) height / src_h);
            double draw_w = src_w * scale;
            double x_offset = (width - draw_w) / 2.0;

            cr.save();
            cr.rectangle(0, 0, width, height);
            cr.clip();
            cr.translate(x_offset, 0);
            cr.scale(scale, scale);
            Gdk.cairo_set_source_pixbuf(cr, pix, 0, 0);
            cr.get_source().set_filter(Cairo.Filter.GOOD);
            cr.paint();
            cr.restore();
        });

        var overlay = new Gtk.Overlay();
        overlay.set_child(placeholder_icon);
        overlay.add_overlay(image);
        overlay.set_hexpand(true);
        overlay.set_vexpand(true);
        overlay.set_size_request(IMAGE_WIDTH, IMAGE_HEIGHT);

        // Bottom-pinned dark gradient scrim with the title/subtitle on top
        // of the cover art itself, same idea as PodcastHeroCard's own
        // title_box - see its comment for why the scrim is flush to the
        // edges while the text padding lives on the inner text_box instead.
        int scrim_height = (int) (IMAGE_HEIGHT * 0.45);
        var title_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        title_box.add_css_class("hero-podcast-scrim");
        title_box.set_hexpand(true);
        title_box.set_vexpand(false);
        title_box.set_halign(Gtk.Align.FILL);
        title_box.set_valign(Gtk.Align.END);
        title_box.set_size_request(-1, scrim_height);

        var text_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
        text_box.set_margin_start(10);
        text_box.set_margin_end(10);
        text_box.set_margin_bottom(10);
        text_box.set_valign(Gtk.Align.END);
        text_box.set_vexpand(true);
        title_box.append(text_box);

        // Pinned to an explicit width, unlike PodcastHeroCard.title_label -
        // that card only ever sits in hero_container's homogeneous row,
        // where every child gets an equal share regardless of its own
        // natural width. This one sits in magazine_library_flow, a plain
        // Gtk.FlowBox, where an unconstrained wrapping label's natural
        // (unwrapped) width can stretch its own column past the content
        // view's bounds for a long, space-sparse title - exactly what
        // archive.org's identifier-shaped PDF filenames produce.
        title_label = new Gtk.Label(title);
        title_label.add_css_class("magazine-hero-title");
        title_label.set_ellipsize(Pango.EllipsizeMode.END);
        title_label.set_xalign(0);
        title_label.set_wrap(true);
        title_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        title_label.set_lines(2);
        title_label.set_size_request(IMAGE_WIDTH - 20, -1);
        text_box.append(title_label);

        subtitle_label = new Gtk.Label(subtitle);
        subtitle_label.add_css_class("hero-podcast-author");
        subtitle_label.set_xalign(0);
        subtitle_label.set_ellipsize(Pango.EllipsizeMode.END);
        text_box.append(subtitle_label);

        overlay.add_overlay(title_box);
        root.append(overlay);
    }

    // Static to avoid a root -> closure -> self reference cycle, same
    // reasoning as PodcastCard.wire_interactions.
    public static void wire_interactions(Gtk.Box root_widget, int64 entry_id, owned EntryActivatedCallback on_activated, owned EntryRemoveRequestedCallback on_remove_requested, owned EntrySetCategoryRequestedCallback on_set_category_requested, owned EntryReorderRequestedCallback on_reorder_requested, owned DragStateChangedCallback on_drag_state_changed) {
        var gesture = new Gtk.GestureClick();
        gesture.set_button(1);
        gesture.released.connect(() => { on_activated(entry_id); });
        root_widget.add_controller(gesture);

        // Drag-and-drop reordering - GtkDragSource only actually starts a
        // drag once the pointer moves past its own threshold, so this
        // coexists fine with the plain click gesture above (a click with
        // no movement still just activates the card).
        var drag_source = new Gtk.DragSource();
        drag_source.set_actions(Gdk.DragAction.MOVE);
        drag_source.prepare.connect((source, x, y) => {
            var val = GLib.Value(typeof(string));
            val.set_string(entry_id.to_string());

            // A mini (40%-scale) live snapshot of the card itself, not
            // GTK's default drag icon - with a plain string content
            // provider, GTK's built-in fallback renders the dragged
            // string's literal text ("482910385...") as the drag icon,
            // which is exactly what this replaces. Rendered via
            // Gtk.WidgetPaintable + Gtk.Snapshot at the target size
            // (same technique ImageViewerDialog uses), not a Gtk.Picture
            // wrapping the full-size paintable - that approach couldn't
            // set a scaled hotspot, so the icon always tracked from its
            // own top-left corner instead of wherever the card was
            // actually grabbed. Scaling (x, y) by the same 0.4 factor as
            // the preview keeps the icon under the cursor at the same
            // relative point it was picked up from.
            int mini_w = (int) (IMAGE_WIDTH * 0.4);
            int mini_h = (int) (IMAGE_HEIGHT * 0.4);
            var widget_paintable = new Gtk.WidgetPaintable(root_widget);
            var snapshot = new Gtk.Snapshot();
            // Semi-transparent so the trash zone (or whatever's under the
            // cursor) stays visible through the dragged card instead of
            // being fully hidden by it.
            snapshot.push_opacity(0.6);
            widget_paintable.snapshot(snapshot, mini_w, mini_h);
            snapshot.pop();
            var node = snapshot.to_node();
            var native = root_widget.get_native();
            if (node != null && native != null) {
                var texture = native.get_renderer().render_texture(node, null);
                drag_source.set_icon(texture, (int) (x * 0.4), (int) (y * 0.4));
            }

            return new Gdk.ContentProvider.for_value(val);
        });
        drag_source.drag_begin.connect((source, drag) => {
            root_widget.add_css_class("magazine-dragging");
            on_drag_state_changed(true);
        });
        drag_source.drag_end.connect((source, drag, delete_data) => {
            root_widget.remove_css_class("magazine-dragging");
            on_drag_state_changed(false);
        });
        root_widget.add_controller(drag_source);

        var drop_target = new Gtk.DropTarget(typeof(string), Gdk.DragAction.MOVE);
        drop_target.enter.connect((x, y) => {
            root_widget.add_css_class("magazine-drop-target");
            return Gdk.DragAction.MOVE;
        });
        drop_target.leave.connect(() => { root_widget.remove_css_class("magazine-drop-target"); });
        drop_target.drop.connect((value, x, y) => {
            root_widget.remove_css_class("magazine-drop-target");
            string? dragged_id_str = value.get_string();
            if (dragged_id_str == null) return false;
            int64 dragged_id = int64.parse(dragged_id_str);
            if (dragged_id == entry_id) return false;
            on_reorder_requested(dragged_id, entry_id);
            return true;
        });
        root_widget.add_controller(drop_target);

        var right_click = new Gtk.GestureClick();
        right_click.set_button(3);
        right_click.pressed.connect((n_press, x, y) => {
            var menu = new GLib.Menu();
            menu.append("Set Category…", "magazine.set-category");
            menu.append("Remove from Library", "magazine.remove");
            var popover = new Gtk.PopoverMenu.from_model(menu);
            popover.set_parent(root_widget);
            Gdk.Rectangle rect = { (int) x, (int) y, 1, 1 };
            popover.set_pointing_to(rect);

            var action_group = new GLib.SimpleActionGroup();
            var remove_action = new GLib.SimpleAction("remove", null);
            remove_action.activate.connect(() => { on_remove_requested(entry_id); });
            action_group.add_action(remove_action);
            var set_category_action = new GLib.SimpleAction("set-category", null);
            set_category_action.activate.connect(() => { on_set_category_requested(entry_id); });
            action_group.add_action(set_category_action);
            root_widget.insert_action_group("magazine", action_group);

            root_widget.set_data("magazine-current-popover", popover);
            popover.popup();
        });
        root_widget.add_controller(right_click);

        var motion = new Gtk.EventControllerMotion();
        motion.enter.connect(() => { root_widget.add_css_class("card-hover"); });
        motion.leave.connect(() => { root_widget.remove_css_class("card-hover"); });
        root_widget.add_controller(motion);
    }
}
