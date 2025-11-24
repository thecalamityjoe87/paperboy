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


/* 
 * Small centralized app debugger helper so logging can be reused across
 * modules without duplicating file IO logic.
 */

using GLib;

public class AppDebugger : GLib.Object {
    private const int64 MAX_LOG_SIZE = 10 * 1024 * 1024; // 10MB max

    // Append a debug line to the provided path. Best-effort; swallow errors.
    // Uses proper file append instead of read-concatenate-write to avoid memory leaks.
    public static void append_debug_log(string path, string line) {
        try {
            var file = File.new_for_path(path);

            // Check if file needs rotation (> 10MB)
            try {
                var info = file.query_info(FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
                if (info.get_size() > MAX_LOG_SIZE) {
                    // Rotate: move current log to .old and start fresh
                    try {
                        var old_file = File.new_for_path(path + ".old");
                        if (old_file.query_exists()) {
                            old_file.delete();
                        }
                        file.move(old_file, FileCopyFlags.NONE);
                    } catch (GLib.Error e) {
                        // If rotation fails, just truncate
                        file.delete();
                    }
                }
            } catch (GLib.Error e) {
                // File doesn't exist yet, that's fine
            }

            // Append the line efficiently without reading the whole file
            var stream = file.append_to(FileCreateFlags.NONE);
            var data_stream = new DataOutputStream(stream);
            data_stream.put_string(line + "\n");
            data_stream.close();
        } catch (GLib.Error e) {
            // best-effort logging only
        }
    }

    // Return true when PAPERBOY_DEBUG is enabled in the environment.
    public static bool debug_enabled() {
        try {
            string? v = GLib.Environment.get_variable("PAPERBOY_DEBUG");
            return v != null && v.length > 0;
        } catch (GLib.Error e) {
            return false;
        }
    }

    // Log a line only when debug is enabled. Swallows errors.
    public static void log_if_enabled(string path, string line) {
        try {
            if (debug_enabled()) append_debug_log(path, line);
        } catch (GLib.Error e) {
            // best-effort
        }
    }

    // Small helper to join a Gee.ArrayList<string> for debug output
    public static string array_join(Gee.ArrayList<string>? list) {
        if (list == null) return "(null)";
        string out = "";
        try {
            foreach (var s in list) {
                if (out.length > 0) out += ",";
                out += s;
            }
        } catch (GLib.Error e) { return "(error)"; }
        return out;
    }
}
