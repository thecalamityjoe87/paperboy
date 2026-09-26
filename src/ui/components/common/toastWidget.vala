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

public class ToastWidget : GLib.Object {
    // Create a custom toast widget that looks like Adwaita toast
    public static Gtk.Box create_toast_widget(string message, bool show_close_button, owned VoidFunc? dismiss_callback = null) {
        // Reduce inter-child spacing so text and close button sit closer
        var toast_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        toast_box.add_css_class("custom-toast");
        toast_box.set_halign(Gtk.Align.CENTER);
        toast_box.set_valign(Gtk.Align.END);  // Bottom of content area
        toast_box.set_margin_bottom(24);  // Space from bottom edge
        toast_box.set_can_focus(false);  // Prevent toast from stealing focus
        
        // Message label
        var label = new Gtk.Label(message);
        //label.set_wrap(true);
        label.set_max_width_chars(50);
        label.add_css_class("custom-toast-label");
        toast_box.append(label);
        
        // Close button (X)
        if (show_close_button && dismiss_callback != null) {
            var close_button = new Gtk.Button();
            close_button.set_icon_name("window-close-symbolic");
            close_button.add_css_class("flat");
            close_button.add_css_class("circular");
            close_button.add_css_class("custom-toast-close");
            close_button.set_can_focus(false);  // Prevent focus stealing
            close_button.clicked.connect(() => {
                dismiss_callback();
            });
            toast_box.append(close_button);
        }
        
        return toast_box;
    }

    public delegate void VoidFunc();
}
