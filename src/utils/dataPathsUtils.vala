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
    private static string? exe_dir_cached = null;
    private static bool exe_dir_looked_up = false;

    // Directory containing the running executable (e.g. .../build), resolved
    // via /proc/self/exe rather than argv[0] or the process's current working
    // directory. Used to anchor the dev-tree candidates in find_data_file()
    // below so they resolve consistently regardless of the directory the
    // binary happens to be launched from - previously those candidates were
    // built relative to the cwd, so launching the same binary from outside
    // the repo/build dir would silently skip straight past the dev copy of a
    // data file to a stale installed one. Returns null if unavailable (e.g.
    // not running on Linux, or /proc is inaccessible).
    private static string? get_exe_dir() {
        if (!exe_dir_looked_up) {
            exe_dir_looked_up = true;
            try {
                var exe_path = GLib.FileUtils.read_link("/proc/self/exe");
                if (exe_path != null) exe_dir_cached = GLib.Path.get_dirname(exe_path);
            } catch (GLib.Error e) {
                exe_dir_cached = null;
            }
        }
        return exe_dir_cached;
    }

    // Return the user's data dir (e.g., ~/.local/share) and cache it.
    public static string? get_user_data_dir() {
        if (user_data_dir_cached == null) user_data_dir_cached = GLib.Environment.get_user_data_dir();
        return user_data_dir_cached;
    }

    // Return system data dirs (e.g., /usr/share and friends) and cache them.
    public static string[] get_system_data_dirs() {
        if (system_data_dirs_cached == null) system_data_dirs_cached = GLib.Environment.get_system_data_dirs();
        return system_data_dirs_cached != null ? system_data_dirs_cached : new string[] { };
    }

    // Locate a data file either in the development tree (data/...), the
    // per-user data dir under 'paperboy/', or in the system data dirs.
    // Returns null when not found.
    public static string? find_data_file(string relative) {
        // Development-time paths (running from project or build dir).
        // "data/resources" and "../data/resources" are checked too because
        // files like style.css live under data/resources/ in the repo but
        // get installed flattened directly into the system paperboy/ data
        // dir (see meson.build) - without this, a dev build silently falls
        // through to a stale system-installed copy instead of the one being
        // edited.
        // Anchored to the running executable's own directory (not the
        // process's cwd) so these resolve the same way no matter where the
        // binary was launched from - see get_exe_dir() above.
        string[] dev_prefixes = { "data", "../data", "data/resources", "../data/resources" };
        var exe_dir = get_exe_dir();
        var search_roots = exe_dir != null ? new string[] { exe_dir, "." } : new string[] { "." };
        foreach (var root in search_roots) {
            foreach (var prefix in dev_prefixes) {
                var path = GLib.Path.build_filename(root, prefix, relative);
                if (GLib.FileUtils.test(path, GLib.FileTest.EXISTS)) return path; 
            }
        }

        // User data dir (e.g., ~/.local/share/paperboy/...)
        var user_data = get_user_data_dir();
        if (user_data != null && user_data.length > 0) {
            var user_path = GLib.Path.build_filename(user_data, "paperboy", relative);
            if (GLib.FileUtils.test(user_path, GLib.FileTest.EXISTS)) return user_path; 
        }

        // System data dirs (e.g., /usr/share or /usr/local/share)
        var sys_dirs = get_system_data_dirs();
        foreach (var dir in sys_dirs) {
            var sys_path = GLib.Path.build_filename(dir, "paperboy", relative);
            if (GLib.FileUtils.test(sys_path, GLib.FileTest.EXISTS)) return sys_path; 
        }
        return null;
    }
}
