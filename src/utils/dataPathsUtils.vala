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

/*
 * Centralized utility helpers for locating runtime data files (development tree
 * and installed locations). This encapsulates the cached environment
 * lookups used across the app.
 */

public class DataPathsUtils : GLib.Object {
    private static string? user_data_dir_cached = null;
    private static string[]? system_data_dirs_cached = null;

    // Return the user's data dir (e.g., ~/.local/share) and cache it.
    public static string? get_user_data_dir() {
        try {
            if (user_data_dir_cached == null) user_data_dir_cached = GLib.Environment.get_user_data_dir();
            return user_data_dir_cached;
        } catch (GLib.Error e) {
            return null;
        }
    }

    // Return system data dirs (e.g., /usr/share and friends) and cache them.
    public static string[] get_system_data_dirs() {
        try {
            if (system_data_dirs_cached == null) system_data_dirs_cached = GLib.Environment.get_system_data_dirs();
            return system_data_dirs_cached != null ? system_data_dirs_cached : new string[] { };
        } catch (GLib.Error e) {
            return new string[] { };
        }
    }

    // Locate a data file either in the development tree (data/...), the
    // per-user data dir under 'paperboy/', or in the system data dirs.
    // Returns null when not found.
    public static string? find_data_file(string relative) {
        // Development-time paths (running from project or build dir)
        string[] dev_prefixes = { "data", "../data" };
        foreach (var prefix in dev_prefixes) {
            var path = GLib.Path.build_filename(prefix, relative);
            try { if (GLib.FileUtils.test(path, GLib.FileTest.EXISTS)) return path; } catch (GLib.Error e) { }
        }

        // User data dir (e.g., ~/.local/share/paperboy/...)
        var user_data = get_user_data_dir();
        if (user_data != null && user_data.length > 0) {
            var user_path = GLib.Path.build_filename(user_data, "paperboy", relative);
            try { if (GLib.FileUtils.test(user_path, GLib.FileTest.EXISTS)) return user_path; } catch (GLib.Error e) { }
        }

        // System data dirs (e.g., /usr/share or /usr/local/share)
        var sys_dirs = get_system_data_dirs();
        foreach (var dir in sys_dirs) {
            var sys_path = GLib.Path.build_filename(dir, "paperboy", relative);
            try { if (GLib.FileUtils.test(sys_path, GLib.FileTest.EXISTS)) return sys_path; } catch (GLib.Error e) { }
        }
        return null;
    }
}
