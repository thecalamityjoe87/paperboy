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

// The app's one check mark. Use this for every check instead of a stock icon name.
public class CheckIconUtils : GLib.Object {
    private const string THIN = "io.github.thecalamityjoe87.Paperboy-check-symbolic";
    private const string BOLD = "io.github.thecalamityjoe87.Paperboy-check-bold-symbolic";

    // `bold` is a heavier stroke for tiny badges, where the thin one blurs into the background.
    public static string icon_name(bool bold = false) {
        string bundled = bold ? BOLD : THIN;
        var theme = Gtk.IconTheme.get_for_display(Gdk.Display.get_default());
        if (theme.has_icon(bundled)) return bundled;
        // Uninstalled dev build: pick it up straight from data/icons.
        string? hicolor = DataPathsUtils.find_data_file("icons/hicolor");
        if (hicolor != null) {
            theme.add_search_path(GLib.Path.get_dirname(hicolor));
            if (theme.has_icon(bundled)) return bundled;
        }
        return "object-select-symbolic";
    }

    public static Gtk.Image new_image(int pixel_size, bool bold = false) {
        var img = new Gtk.Image.from_icon_name(icon_name(bold));
        img.set_pixel_size(pixel_size);
        return img;
    }
}
