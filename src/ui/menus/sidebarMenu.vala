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
using Adw;

/**
 * SidebarMenu - Context menu for RSS sources in the sidebar
 */
public class SidebarMenu : GLib.Object {
    private NewsWindow window;
    
    private string current_source_url = "";
    private string current_source_name = "";
    
    public SidebarMenu(NewsWindow window) {
        this.window = window;
    }
    
    public void show_for_source(Gtk.Widget widget, string source_url, string source_name) {
        current_source_url = source_url;
        current_source_name = source_name;
        
        // Create popover with custom menu
        var popover = new Gtk.Popover();
        popover.set_parent(widget);
        popover.set_has_arrow(true);
        
        var menu_box = create_menu_box(popover);
        popover.set_child(menu_box);
        popover.popup();
    }
    
    private Gtk.Box create_menu_box(Gtk.Popover popover) {
        var menu_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        menu_box.add_css_class("menu");
        
        // Mark all as read
        var mark_read_btn = create_menu_item("emblem-ok-symbolic", "Mark All as Read");
        mark_read_btn.clicked.connect(() => {
            on_mark_all_read();
            popover.popdown();
        });
        menu_box.append(mark_read_btn);
        
        // Mark all as unread
        var mark_unread_btn = create_menu_item("edit-undo-symbolic", "Mark All as Unread");
        mark_unread_btn.clicked.connect(() => {
            on_mark_all_unread();
            popover.popdown();
        });
        menu_box.append(mark_unread_btn);
        
        // Remove this source
        var remove_btn = create_menu_item("user-trash-symbolic", "Remove This Source");
        remove_btn.add_css_class("destructive-action");
        remove_btn.clicked.connect(() => {
            on_remove_source();
            popover.popdown();
        });
        menu_box.append(remove_btn);
        
        return menu_box;
    }
    
    private Gtk.Button create_menu_item(string icon_name, string label_text) {
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
    
    private void on_mark_all_read() {
        if (current_source_name.length == 0) {
            return;
        }
        
        if (window.sidebar_manager != null) {
            window.sidebar_manager.mark_all_read_for_source(current_source_name);
        }
        
        if (window.toast_manager != null) {
            window.toast_manager.show_toast("Marked all articles as read");
        }
    }
    
    private void on_mark_all_unread() {
        if (current_source_name.length == 0) {
            return;
        }
        
        if (window.sidebar_manager != null) {
            window.sidebar_manager.mark_all_unread_for_source(current_source_name);
        }
        
        if (window.toast_manager != null) {
            window.toast_manager.show_toast("Marked all articles as unread");
        }
    }
    
    private void on_remove_source() {
        if (current_source_url.length == 0) {
            return;
        }
        
        // Show confirmation dialog
        var dialog = new Adw.MessageDialog(
            (Gtk.Window)window,
            "Remove RSS Source?",
            "Are you sure you want to remove \"%s\"?".printf(current_source_name)
        );
        dialog.set_body("This action cannot be undone.");
        dialog.add_response("cancel", "Cancel");
        dialog.add_response("remove", "Remove");
        dialog.set_response_appearance("remove", Adw.ResponseAppearance.DESTRUCTIVE);
        
        dialog.response.connect((response) => {
            if (response == "remove") {
                if (window.sidebar_manager != null) {
                    window.sidebar_manager.remove_rss_source(current_source_url);
                }
                
                if (window.toast_manager != null) {
                    window.toast_manager.show_toast("RSS source removed");
                }
            }
            dialog.close();
        });
        
        dialog.present();
    }
}
