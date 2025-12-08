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

public class ToastManager : GLib.Object {
    private uint? timeout_id;

    public signal void request_show_toast(string message, bool persistent);
    public signal void request_dismiss_toast();

    public ToastManager() {
        this.timeout_id = null;
    }

    // Dismiss the current toast
    private void dismiss_toast() {
        if (timeout_id != null) {
            Source.remove(timeout_id);
            timeout_id = null;
        }
        request_dismiss_toast();
    }

    // Show a transient toast with a 3-second timeout
    public void show_toast(string message) {
        // Cancel any existing timeout
        if (timeout_id != null) {
            Source.remove(timeout_id);
            timeout_id = null;
        }
        
        // Request UI to show the toast
        request_show_toast(message, false);
        
        // Auto-dismiss after 3 seconds
        timeout_id = Timeout.add_seconds(3, () => {
            dismiss_toast();
            timeout_id = null;
            return false;
        });
    }

    // Show a persistent toast (no timeout, stays until dismissed)
    public void show_persistent_toast(string message) {
        // Cancel any existing timeout
        if (timeout_id != null) {
            Source.remove(timeout_id);
            timeout_id = null;
        }
        
        // Request UI to show the persistent toast
        request_show_toast(message, true);
    }

    // Explicitly clear the current toast
    public void clear_persistent_toast() {
        dismiss_toast();
    }
}
