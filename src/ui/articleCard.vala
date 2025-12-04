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
    private ArticleStateStore? article_state_store;

    // Signal emitted when the card is activated (clicked/tapped)
    public signal void activated(string url);

    // Signal emitted when context menu action is requested
    public signal void open_in_app_requested(string url);
    public signal void open_in_browser_requested(string url);
    public signal void follow_source_requested(string url, string? source_name);
    public signal void save_for_later_requested(string url);
    public signal void share_requested(string url);

    public ArticleCard(string title, string url, int col_w, int img_h, Gtk.Widget chip, int variant, ArticleStateStore? state_store = null) {
        GLib.Object();
        this.url = url;
        this.article_state_store = state_store;

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
        // Check if article is already saved
        bool is_saved = false;
        if (article_state_store != null) {
            try { is_saved = article_state_store.is_saved(url); } catch (GLib.Error e) { }
        }

        // Create custom popover with buttons that have icons
        var popover = new Gtk.Popover();
        popover.set_parent(root);
        popover.set_has_arrow(false);
        popover.set_pointing_to({ (int)x, (int)y, 1, 1 });

        var menu_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        menu_box.add_css_class("menu");

        // View in app
        var view_btn = new Gtk.Button();
        view_btn.set_halign(Gtk.Align.START);
        var view_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        var view_icon = new Gtk.Image.from_icon_name("view-reveal-symbolic");
        var view_label = new Gtk.Label("View article in app");
        view_label.set_xalign(0);
        view_box.append(view_icon);
        view_box.append(view_label);
        view_btn.set_child(view_box);
        view_btn.add_css_class("flat");
        view_btn.add_css_class("menu-item");
        view_btn.clicked.connect(() => {
            try { open_in_app_requested(url); popover.popdown(); } catch (GLib.Error e) { }
        });
        menu_box.append(view_btn);

        // Open in browser
        var browser_btn = new Gtk.Button();
        browser_btn.set_halign(Gtk.Align.START);
        var browser_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        var browser_icon = new Gtk.Image.from_icon_name("web-browser-symbolic");
        var browser_label = new Gtk.Label("Open article in browser");
        browser_label.set_xalign(0);
        browser_box.append(browser_icon);
        browser_box.append(browser_label);
        browser_btn.set_child(browser_box);
        browser_btn.add_css_class("flat");
        browser_btn.add_css_class("menu-item");
        browser_btn.clicked.connect(() => {
            try { open_in_browser_requested(url); popover.popdown(); } catch (GLib.Error e) { }
        });
        menu_box.append(browser_btn);

        // Follow this source
        var follow_btn = new Gtk.Button();
        follow_btn.set_halign(Gtk.Align.START);
        var follow_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        var follow_icon = new Gtk.Image.from_icon_name("list-add-symbolic");
        var follow_label = new Gtk.Label("Follow this source");
        follow_label.set_xalign(0);
        follow_box.append(follow_icon);
        follow_box.append(follow_label);
        follow_btn.set_child(follow_box);
        follow_btn.add_css_class("flat");
        follow_btn.add_css_class("menu-item");
        follow_btn.clicked.connect(() => {
            try { follow_source_requested(url, source_name); popover.popdown(); } catch (GLib.Error e) { }
        });
        menu_box.append(follow_btn);

        // Save/Remove from saved
        var save_btn = new Gtk.Button();
        save_btn.set_halign(Gtk.Align.START);
        var save_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        var save_icon = new Gtk.Image.from_icon_name(is_saved ? "user-trash-symbolic" : "user-bookmarks-symbolic");
        var save_label = new Gtk.Label(is_saved ? "Remove from saved" : "Save this article");
        save_label.set_xalign(0);
        save_box.append(save_icon);
        save_box.append(save_label);
        save_btn.set_child(save_box);
        save_btn.add_css_class("flat");
        save_btn.add_css_class("menu-item");
        save_btn.clicked.connect(() => {
            try { save_for_later_requested(url); popover.popdown(); } catch (GLib.Error e) { }
        });
        menu_box.append(save_btn);

        // Share
        var share_btn = new Gtk.Button();
        share_btn.set_halign(Gtk.Align.START);
        var share_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        var share_icon = new Gtk.Image.from_icon_name("share-symbolic");
        var share_label = new Gtk.Label("Share this article");
        share_label.set_xalign(0);
        share_box.append(share_icon);
        share_box.append(share_label);
        share_btn.set_child(share_box);
        share_btn.add_css_class("flat");
        share_btn.add_css_class("menu-item");
        share_btn.clicked.connect(() => {
            try { share_requested(url); popover.popdown(); } catch (GLib.Error e) { }
        });
        menu_box.append(share_btn);

        popover.set_child(menu_box);
        popover.popup();
    }
}
