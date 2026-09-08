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

// Right-click menu for a podcast show - shared by PodcastCard/PodcastHeroCard
// (in the Podcasts view) and podcast sidebar subscription rows. Built the
// same way as ArticleMenu/SidebarMenu (a plain Gtk.Popover + Gtk.Box.menu of
// Gtk.Button rows, not Gio.Menu/Gio.SimpleAction) so it matches every other
// right-click menu's look exactly; the create_menu_item() helper below is
// intentionally a near copy of ArticleMenu's/SidebarMenu's, following this
// codebase's existing convention of duplicating that small helper per-menu
// rather than sharing it.
public class PodcastMenu : GLib.Object {
    public signal void play_requested();
    public signal void subscribe_requested();
    public signal void unsubscribe_requested();

    // Whether the show this menu is for is already subscribed - governs
    // whether "Subscribe" or "Remove podcast" is shown, same one-menu-two-
    // states shape as ArticleMenu's save/remove-from-saved item.
    private bool is_subscribed;

    public PodcastMenu(bool subscribed) {
        is_subscribed = subscribed;
    }

    public Gtk.Box create_menu_box(Gtk.Popover? popover) {
        var menu_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        menu_box.add_css_class("menu");

        var play_btn = create_menu_item("media-playback-start-symbolic", "Play");
        play_btn.clicked.connect(() => {
            play_requested();
            if (popover != null) popover.popdown();
        });
        menu_box.append(play_btn);

        if (is_subscribed) {
            var remove_btn = create_menu_item("user-trash-symbolic", "Remove podcast");
            // Matches SidebarMenu's own "Remove this source" button exactly
            // - GTK's built-in destructive-action style class, which colors
            // both the icon and label red.
            remove_btn.add_css_class("destructive-action");
            remove_btn.clicked.connect(() => {
                unsubscribe_requested();
                if (popover != null) popover.popdown();
            });
            menu_box.append(remove_btn);
        } else {
            var sub_btn = create_menu_item("list-add-symbolic", "Subscribe");
            sub_btn.clicked.connect(() => {
                subscribe_requested();
                if (popover != null) popover.popdown();
            });
            menu_box.append(sub_btn);
        }

        return menu_box;
    }

    // has_arrow/pointing_to differ by where this menu is used: cards (see
    // PodcastCard/PodcastHeroCard) point an arrow-less popover at the exact
    // click position, matching ArticleMenu's own card-context-menu style.
    // Sidebar rows instead match SidebarMenu's own popover exactly - an
    // arrow pointing at the row widget itself, no pointing_to - since that
    // (not ArticleMenu) is "the other right-click menus" a sidebar row's
    // menu needs to look consistent with.
    public Gtk.Popover create_popover(Gtk.Widget parent, double x = -1, double y = -1, bool has_arrow = false) {
        var popover = new Gtk.Popover();
        popover.set_parent(parent);
        popover.set_has_arrow(has_arrow);
        if (!has_arrow && x >= 0 && y >= 0) {
            popover.set_pointing_to({ (int)x, (int)y, 1, 1 });
        }

        var menu_box = create_menu_box(popover);
        popover.set_child(menu_box);
        return popover;
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
}
