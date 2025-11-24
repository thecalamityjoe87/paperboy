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
using Json;
using Soup;
using Gdk;

/*
 * Helpers for persisting frontpage provider logos into the user's
 * XDG data dir under paperboy/source_logos and maintaining a small
 * index.json mapping provider keys -> saved filenames and metadata.
 */

public class SourceLogos : GLib.Object {
    // Return the user data dir for saved source logos, creating it when needed.
    public static string? get_user_logos_dir() {
        try {
            string? ud = DataPaths.get_user_data_dir();
            if (ud == null) return null;
            string path = GLib.Path.build_filename(ud, "paperboy", "source_logos");
            try {
                if (!GLib.FileUtils.test(path, GLib.FileTest.EXISTS))
                    GLib.DirUtils.create_with_parents(path, 0755);
            } catch (GLib.Error e) { /* best-effort */ }
            return path;
        } catch (GLib.Error e) { return null; }
    }

    // Per-provider metadata files are stored in the user's data dir under
    // paperboy/source_info (so metadata is separated from the image files).
    // This keeps metadata in a single place and makes it easier to inspect
    // or rotate without touching the saved images.
    public static string? get_user_source_info_dir() {
        try {
            string? ud = DataPaths.get_user_data_dir();
            if (ud == null) return null;
            string path = GLib.Path.build_filename(ud, "paperboy", "source_info");
            try {
                if (!GLib.FileUtils.test(path, GLib.FileTest.EXISTS))
                    GLib.DirUtils.create_with_parents(path, 0755);
            } catch (GLib.Error e) { /* best-effort */ }
            return path;
        } catch (GLib.Error e) { return null; }
    }

    // Write a small per-provider JSON file into the `source_info` dir. The
    // filename parameter is used as the base (caller may pass the saved image
    // filename or a shorter key). This is best-effort and will not throw.
    private static void write_provider_meta(string filename, string display_name, string logo_url, string? source_url) {
        try {
            string? info_dir = get_user_source_info_dir();
            if (info_dir == null) return;
            string meta_path = GLib.Path.build_filename(info_dir, filename + ".json");

            // Minimal JSON escaping for common characters
            string escape(string s) {
                string r = s.replace("\\", "\\\\");
                r = r.replace("\"", "\\\"");
                r = r.replace("\n", "\\n");
                r = r.replace("\r", "\\r");
                return r;
            }
            long now_s = (long)(GLib.get_real_time() / 1000000);
            string src_field = "";
            if (source_url != null) src_field = "  \"source_url\": \"" + escape((string)source_url) + "\",\n";
            string js = "{\n" +
                "  \"display_name\": \"" + escape(display_name) + "\",\n" +
                "  \"original_logo_url\": \"" + escape(logo_url) + "\",\n" +
                src_field +
                "  \"saved_filename\": \"" + escape(filename) + "\",\n" +
                "  \"saved_at\": \"" + "%d".printf((int)now_s) + "\"\n" +
                "}\n";
            GLib.FileUtils.set_contents(meta_path, js);
        } catch (GLib.Error e) { }
    }

    // Produce a friendly capitalized concatenation of display name parts.
    // Example: "New York Times" -> "NewYorkTimes"
    private static string sanitize_filename(string input) {
        if (input == null) return "source";
        string s = input.strip();
        if (s.length == 0) return "source";

        // Split on any non-alphanumeric character and capitalize each token
        var parts = new Gee.ArrayList<string>();
        string token = "";
        for (int i = 0; i < s.length; i++) {
            char c = s[i];
            bool is_alnum = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
            if (is_alnum) token += c.to_string();
            else {
                if (token.length > 0) { parts.add(token); token = ""; }
            }
        }
        if (token.length > 0) parts.add(token);

        string out = "";
        foreach (var p in parts) {
            if (p.length == 0) continue;
            // Capitalize first char, keep rest as-is (preserve case for acronyms)
            string first = p.substring(0, 1).up();
            string rest = p.length > 1 ? p.substring(1) : "";
            out += first + rest;
        }
        if (out.length == 0) out = "source";
        return out;
    }

    // Public entry: record mapping and attempt to download the logo into
    // a canonical filename. This is best-effort and runs the network work
    // in a background thread so it won't block the UI.
    public static void update_index_and_fetch(string provider_key, string display_name, string? logo_url, string? source_url, Soup.Session session) {
        if (logo_url == null || logo_url.length == 0) return;
        try {
            string key = provider_key != null && provider_key.length > 0 ? provider_key : display_name;
            // Use the provider display name (rather than the opaque key) to
            // produce human-friendly filenames like "NewYorkTimes-logo.png".
            string base_name = sanitize_filename(display_name);
            string filename = base_name + "-logo.png";

            // If the canonical file already exists, nothing to do
            string? dir = get_user_logos_dir();
            if (dir == null) return;
            string target = GLib.Path.build_filename(dir, filename);
            try { if (GLib.FileUtils.test(target, GLib.FileTest.EXISTS)) return; } catch (GLib.Error e) { }

            // Write lightweight per-provider metadata into the `source_info`
            // directory and fetch the image in background. The metadata file
            // is a small JSON record and is stored separately from the image.
            try { write_provider_meta(filename, display_name, logo_url, source_url); } catch (GLib.Error e) { }

            new Thread<void*>("source-logo-fetch", () => {
                try {
                    string? ldir = get_user_logos_dir();
                    if (ldir == null) return null;
                    string tpath = GLib.Path.build_filename(ldir, filename);

                    var msg = new Soup.Message("GET", logo_url);
                    msg.request_headers.append("User-Agent", "paperboy/0.1");
                    session.send_message(msg);
                    if (msg.status_code != 200) return null;
                    try {
                        uint8[] data = new uint8[msg.response_body.length];
                        Memory.copy(data, msg.response_body.data, (size_t)msg.response_body.length);
                        var loader = new PixbufLoader();
                        loader.write(data);
                        loader.close();
                        var pb = loader.get_pixbuf();
                        if (pb != null) {
                            try { pb.savev(tpath, "png", null, null); } catch (GLib.Error e) { }
                        } else {
                            try { GLib.FileUtils.set_contents(tpath, (string)msg.response_body.flatten().data); } catch (GLib.Error e) { }
                        }
                    } catch (GLib.Error e) { }
                } catch (GLib.Error e) { }
                return null;
            });
        } catch (GLib.Error e) { /* don't let index writes break parsing */ }
    }
}
