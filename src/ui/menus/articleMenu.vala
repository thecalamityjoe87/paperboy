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

public class ArticleMenu : GLib.Object {
    public signal void open_in_app_requested(string url);
    public signal void open_in_browser_requested(string url);
    public signal void follow_source_requested(string url, string? source_name);
    public signal void save_for_later_requested(string url);
    public signal void share_requested(string url);

    private string article_url;
    private string? article_source_name;
    private bool is_saved;
    private NewsWindow? parent_window;

    public ArticleMenu(string url, string? source_name, bool saved, NewsWindow? window) {
        article_url = url;
        article_source_name = source_name;
        is_saved = saved;
        parent_window = window;
    }

    public Gtk.Box create_menu_box(Gtk.Popover? popover) {
        var menu_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        menu_box.add_css_class("menu");

        // View in app
        var view_btn = create_menu_item("view-reveal-symbolic", "View article in app");
        view_btn.clicked.connect(() => {
            open_in_app_requested(article_url);
            if (popover != null) popover.popdown();
        });
        menu_box.append(view_btn);

        // Open in browser
        var browser_btn = create_menu_item("web-browser-symbolic", "Open article in browser");
        browser_btn.clicked.connect(() => {
            open_in_browser_requested(article_url);
            if (popover != null) popover.popdown();
        });
        menu_box.append(browser_btn);

        // Follow this source
        var follow_btn = create_menu_item("list-add-symbolic", "Follow this source");
        bool is_builtin = SourceManager.is_article_from_builtin(article_url);
        follow_btn.set_sensitive(!is_builtin);
        follow_btn.clicked.connect(() => {
            follow_source_requested(article_url, article_source_name);
            if (popover != null) popover.popdown();
        });
        menu_box.append(follow_btn);

        // Save/Remove from saved
        var save_btn = create_menu_item(
            is_saved ? "user-trash-symbolic" : "user-bookmarks-symbolic",
            is_saved ? "Remove from saved" : "Save this article"
        );
        save_btn.clicked.connect(() => {
            save_for_later_requested(article_url);
            if (popover != null) popover.popdown();
        });
        menu_box.append(save_btn);

        // Share
        var share_btn = create_menu_item("share-symbolic", "Share this article");
        share_btn.clicked.connect(() => {
            share_requested(article_url);
            if (popover != null) popover.popdown();
        });
        menu_box.append(share_btn);

        return menu_box;
    }

    public Gtk.Popover create_popover(Gtk.Widget parent, double x, double y) {
        var popover = new Gtk.Popover();
        popover.set_parent(parent);
        popover.set_has_arrow(false);
        popover.set_pointing_to({ (int)x, (int)y, 1, 1 });

        var menu_box = create_menu_box(popover);
        popover.set_child(menu_box);
        return popover;
    }

    private Gtk.Button create_menu_item(string icon_name, string label_text) {
        // Create a menu button that extends
        // from edge-to-edge of the popover menu
        var btn = new Gtk.Button();
        btn.set_halign(Gtk.Align.FILL);
        btn.set_hexpand(true);

        var box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        box.set_halign(Gtk.Align.FILL);
        box.set_hexpand(true);
        
        var icon = new Gtk.Image.from_icon_name(icon_name);
        var label = new Gtk.Label(label_text);
        label.set_xalign(0);
        label.set_halign(Gtk.Align.START);

        box.append(icon);
        box.append(label);

        btn.set_child(box);

        btn.add_css_class("flat");
        btn.add_css_class("menu-item");

        return btn;
    }
}
