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

using GLib;
using Gtk;

/*
 * Robustly open a URL in the user's configured browser. Try the
 * platform Gio.AppInfo API first; on failure fall back to executing
 * xdg-open as a last resort.
*/

public class BrowserUtils : GLib.Object {
    // Open URL in default browser; returns true on success, false on error
    public static bool open_url_in_browser(string uri) {
        if (uri == null || uri.strip().length == 0) return false;

        string normalized = uri.strip();
        if (!(normalized.has_prefix("http://") || normalized.has_prefix("https://") || normalized.has_prefix("mailto:") || normalized.has_prefix("file:") || normalized.has_prefix("ftp:"))) {
            normalized = "https://" + normalized;
        }

        try {
            AppInfo.launch_default_for_uri(normalized, null);
            return true;
        } catch (GLib.Error e) {
            try {
                string[] argv = { "xdg-open", normalized };
                var proc = new GLib.Subprocess.newv(argv, GLib.SubprocessFlags.NONE);
                return true;
            } catch (GLib.Error e) {
                return false;
            }
        }
    }
}
