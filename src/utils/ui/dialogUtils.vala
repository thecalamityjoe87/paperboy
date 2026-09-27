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

// Centers Adw.Dialogs over the content column instead of the whole window.
public class DialogUtils : GLib.Object {
    // AdwDialogHost is internal to libadwaita, so it's created by name; null
    // (dialogs fall back to the window) if a future version drops it.
    public static Gtk.Widget? create_host(Gtk.Widget child) {
        var t = GLib.Type.from_name("AdwDialogHost");
        if (t == GLib.Type.INVALID || !t.is_a(typeof(Gtk.Widget))) return null;
        var host = (Gtk.Widget) GLib.Object.new(t);
        host.set("child", child);
        return host;
    }

    // Only a window parent needs redirecting; a dialog parent already sits inside the host.
    public static Gtk.Widget parent_for(Gtk.Widget parent) {
        var win = parent as NewsWindow;
        if (win == null || win.content_dialog_host == null) return parent;
        // Collapsed, the sidebar overlays the content column, so use the whole window.
        if (win.split_view != null && win.split_view.get_collapsed()) return parent;
        return win.content_dialog_host;
    }

    // The dialog's backdrop dimming layer (first child of its floating/bottom sheet).
    public static Gtk.Widget? find_dimming(Gtk.Widget w) {
        for (var c = w.get_first_child(); c != null; c = c.get_next_sibling()) {
            var type_name = c.get_type().name();
            if (type_name == "AdwFloatingSheet" || type_name == "AdwBottomSheet") return c.get_first_child();
            var found = find_dimming(c);
            if (found != null) return found;
        }
        return null;
    }

    // Size of the area a dialog presented on `parent` will be centered over.
    public static void available_size(Gtk.Widget parent, out int width, out int height) {
        var target = parent_for(parent);
        width = target.get_width();
        height = target.get_height();
    }
}
