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

public class ArticleCard : GLib.Object {
    public Gtk.Box root;
    public Gtk.Overlay overlay;
    public Gtk.Picture image;
    public Gtk.Box title_box;
    public Gtk.Label title_label;
    public string url;
    public string? source_name;
    public string? category_id;
    public string? thumbnail_url;

    // Signal emitted when the card is activated (clicked/tapped)
    public signal void activated(string url);

    // Signal emitted when context menu action is requested
    public signal void open_in_app_requested(string url);
    public signal void open_in_browser_requested(string url);
    public signal void follow_source_requested(string url, string? source_name);

    public ArticleCard(string title, string url, int col_w, int img_h, Gtk.Widget chip, int variant) {
        GLib.Object();
        this.url = url;

        root = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        root.add_css_class("card");
        root.set_hexpand(true);
        root.set_halign(Gtk.Align.FILL);
        root.set_size_request(col_w, -1);

        image = new Gtk.Picture();
        image.set_halign(Gtk.Align.FILL);
        image.set_hexpand(true);
        image.set_size_request(col_w, img_h);
        image.set_content_fit(Gtk.ContentFit.COVER);
        image.set_can_shrink(true);

        overlay = new Gtk.Overlay();
        overlay.set_child(image);

        // Add the provided category chip overlay (owner computes chip)
        if (chip != null) overlay.add_overlay(chip);

        root.append(overlay);

        // Title container
        title_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
        title_box.set_margin_start(12);
        title_box.set_margin_end(12);
        title_box.set_margin_top(12);
        title_box.set_margin_bottom(12);
        title_box.set_vexpand(true);

        title_label = new Gtk.Label(title);
        title_label.set_ellipsize(Pango.EllipsizeMode.END);
        title_label.set_xalign(0);
        title_label.set_wrap(true);
        title_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        // Size request tuned by caller
        title_label.set_size_request(col_w - 24, -1);
        switch (variant) {
            case 0: title_label.set_lines(3); break;
            case 1: title_label.set_lines(4); break;
            default: title_label.set_lines(6); break;
        }
        title_box.append(title_label);
        root.append(title_box);

        // Click gesture emits activated signal with the URL
        var gesture = new Gtk.GestureClick();
        // Accept primary button clicks (1) and handle release with full signature
        try { gesture.set_button(1); } catch (GLib.Error e) { }
        // Use a simple no-argument handler (original pattern) to avoid
        // signature mismatches; emit the declared signal so connected
        // handlers receive the article URL.
        gesture.released.connect(() => {
            try {
                // Small runtime trace to help debugging whether the handler runs
                try { warning("ArticleCard clicked: %s", this.url); } catch (GLib.Error e) { }
                activated(url);
            } catch (GLib.Error e) { }
        });
        root.add_controller(gesture);

        // Hover effects
        var motion = new Gtk.EventControllerMotion();
        motion.enter.connect(() => { root.add_css_class("card-hover"); });
        motion.leave.connect(() => { root.remove_css_class("card-hover"); });
        root.add_controller(motion);

        // Right-click context menu
        var right_click = new Gtk.GestureClick();
        try { right_click.set_button(3); } catch (GLib.Error e) { }
        right_click.pressed.connect((n_press, x, y) => {
            try { show_context_menu(x, y); } catch (GLib.Error e) { }
        });
        root.add_controller(right_click);
    }

    private void show_context_menu(double x, double y) {
        var menu = new GLib.Menu();
        menu.append("View in app", "card.open-in-app");
        menu.append("Open in browser", "card.open-in-browser");
        menu.append("Follow this source", "card.follow-source");

        var open_in_app_action = new GLib.SimpleAction("open-in-app", null);
        open_in_app_action.activate.connect(() => {
            try { open_in_app_requested(url); } catch (GLib.Error e) { }
        });

        var open_in_browser_action = new GLib.SimpleAction("open-in-browser", null);
        open_in_browser_action.activate.connect(() => {
            try { open_in_browser_requested(url); } catch (GLib.Error e) { }
        });

        var follow_action = new GLib.SimpleAction("follow-source", null);
        follow_action.activate.connect(() => {
            try { follow_source_requested(url, source_name); } catch (GLib.Error e) { }
        });

        var action_group = new GLib.SimpleActionGroup();
        action_group.add_action(open_in_app_action);
        action_group.add_action(open_in_browser_action);
        action_group.add_action(follow_action);

        var popover = new Gtk.PopoverMenu.from_model(menu);
        popover.set_parent(root);
        popover.set_has_arrow(false);
        popover.set_pointing_to({ (int)x, (int)y, 1, 1 });

        root.insert_action_group("card", action_group);
        popover.popup();
    }
}
