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

public class ToastManager : GLib.Object {
    private Gtk.Overlay content_overlay;
    private Gtk.Box? current_toast_widget;
    private uint? timeout_id;

    public ToastManager(Gtk.Overlay overlay) {
        this.content_overlay = overlay;
        this.current_toast_widget = null;
        this.timeout_id = null;
    }

    // Create a custom toast widget that looks like Adwaita toast
    private Gtk.Box create_toast_widget(string message, bool show_close_button) {
        var toast_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 12);
        toast_box.add_css_class("custom-toast");
        toast_box.set_halign(Gtk.Align.CENTER);
        toast_box.set_valign(Gtk.Align.END);  // Bottom of content area
        toast_box.set_margin_bottom(24);  // Space from bottom edge
        
        // Message label
        var label = new Gtk.Label(message);
        //label.set_wrap(true);
        label.set_max_width_chars(50);
        label.add_css_class("custom-toast-label");
        toast_box.append(label);
        
        // Close button (X)
        if (show_close_button) {
            var close_button = new Gtk.Button();
            close_button.set_icon_name("window-close-symbolic");
            close_button.add_css_class("flat");
            close_button.add_css_class("circular");
            close_button.add_css_class("custom-toast-close");
            close_button.clicked.connect(() => {
                dismiss_toast();
            });
            toast_box.append(close_button);
        }
        
        return toast_box;
    }

    // Dismiss the current toast
    private void dismiss_toast() {
        if (current_toast_widget != null) {
            content_overlay.remove_overlay(current_toast_widget);
            current_toast_widget = null;
        }
        
        if (timeout_id != null) {
            Source.remove(timeout_id);
            timeout_id = null;
        }
    }

    // Show a transient toast with a 3-second timeout
    public void show_toast(string message) {
        // Dismiss any existing toast
        dismiss_toast();
        
        // Create and show new toast
        current_toast_widget = create_toast_widget(message, true);
        content_overlay.add_overlay(current_toast_widget);
        
        // Auto-dismiss after 3 seconds
        timeout_id = Timeout.add_seconds(3, () => {
            dismiss_toast();
            timeout_id = null;
            return false;
        });
    }

    // Show a persistent toast (no timeout, stays until dismissed)
    public void show_persistent_toast(string message) {
        // Dismiss any existing toast
        dismiss_toast();
        
        // Create and show persistent toast
        current_toast_widget = create_toast_widget(message, true);
        content_overlay.add_overlay(current_toast_widget);
    }

    // Explicitly clear the current toast
    public void clear_persistent_toast() {
        dismiss_toast();
    }
}
