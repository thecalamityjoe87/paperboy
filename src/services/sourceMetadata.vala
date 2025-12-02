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

public class SourceMetadata : GLib.Object {
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
            // Remove .png extension from meta filename to make it cleaner
            string base_filename = filename;
            if (base_filename.has_suffix("-logo.png")) {
                base_filename = base_filename.substring(0, base_filename.length - 9);
            } else if (base_filename.has_suffix(".png")) {
                base_filename = base_filename.substring(0, base_filename.length - 4);
            }
            string meta_path = GLib.Path.build_filename(info_dir, base_filename + ".json");

            // Minimal JSON escaping for common characters
            string escape(string s) {
                string r = s.replace("\\", "\\\\");
                r = r.replace("\"", "\\\"");
                r = r.replace("\n", "\\n");
                r = r.replace("\r", "\\r");
                return r;
            }

            // If a meta file already exists, load it and decide whether to
            // update the display_name. We want to prefer human-friendly names
            // (e.g., "The Verge") over domain-style fallbacks (e.g., "theverge.com").
            string write_display_name = display_name;
            try {
                if (GLib.FileUtils.test(meta_path, GLib.FileTest.EXISTS)) {
                    string existing_contents;
                    if (GLib.FileUtils.get_contents(meta_path, out existing_contents)) {
                        var parser = new Json.Parser();
                        try {
                            parser.load_from_data(existing_contents);
                            var root = parser.get_root();
                            if (root != null && root.get_node_type() == Json.NodeType.OBJECT) {
                                var obj = root.get_object();
                                if (obj.has_member("display_name")) {
                                    string existing_name = obj.get_string_member("display_name");
                                    // Heuristic: if existing name looks like a hostname
                                    // (contains a dot and no spaces) and the new name is
                                    // more human (contains a space or uppercase letters),
                                    // prefer the new name.
                                    bool existing_is_domain = existing_name.index_of(".") >= 0 && existing_name.index_of(" ") < 0;
                                    bool new_is_more_human = (display_name.index_of(" ") >= 0) || (display_name != display_name.down());
                                    if (existing_is_domain && new_is_more_human) {
                                        write_display_name = display_name;
                                    } else {
                                        // Otherwise, keep existing name to avoid overwriting
                                        // a manually curated display name.
                                        write_display_name = existing_name;
                                    }
                                }
                            }
                        } catch (GLib.Error e) { /* ignore parse errors and overwrite */ }
                    }
                }
            } catch (GLib.Error e) { /* best-effort */ }

            long now_s = (long)(GLib.get_real_time() / 1000000);
            string src_field = "";
            if (source_url != null) src_field = "  \"source_url\": \"" + escape((string)source_url) + "\",\n";
            string js = "{\n" +
                "  \"display_name\": \"" + escape(write_display_name) + "\",\n" +
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
    public static string sanitize_filename(string input) {
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
    public static void update_index_and_fetch(string provider_key, string display_name, string? logo_url, string? source_url, Soup.Session? session = null, string? rss_feed_url = null) {
        if (logo_url == null || logo_url.length == 0) return;
        try {
            string key = provider_key != null && provider_key.length > 0 ? provider_key : display_name;
            // Use the provider display name (rather than the opaque key) to
            // produce human-friendly filenames like "NewYorkTimes-logo.png".
            string base_name = sanitize_filename(display_name);
            string filename = base_name + "-logo.png";

            // If the canonical file already exists, do NOT re-download or overwrite
            string? dir = get_user_logos_dir();
            if (dir == null) return;
            string target = GLib.Path.build_filename(dir, filename);
            bool logo_exists = false;
            try { logo_exists = GLib.FileUtils.test(target, GLib.FileTest.EXISTS); } catch (GLib.Error e) { }

            if (logo_exists) {
                // Logo file already exists - NEVER overwrite or re-download
                return;
            }

            // Logo doesn't exist yet - write metadata and download
            try { write_provider_meta(filename, display_name, logo_url, source_url); } catch (GLib.Error e) { }

            new Thread<void*>("source-logo-fetch", () => {
                try {
                    string? ldir = get_user_logos_dir();
                    if (ldir == null) return null;
                    string tpath = GLib.Path.build_filename(ldir, filename);

                    var client = Paperboy.HttpClient.get_default();
                    var http_response = client.fetch_sync(logo_url, null);

                    if (!http_response.is_success() || http_response.body == null) return null;

                    bool saved = false;
                    try {
                        unowned uint8[] body_data = http_response.body.get_data();
                        uint8[] data = new uint8[body_data.length];
                        Memory.copy(data, body_data, body_data.length);

                        var loader = new PixbufLoader();
                        loader.write(data);
                        loader.close();
                        var pb = loader.get_pixbuf();
                        if (pb != null) {
                            try {
                                pb.savev(tpath, "png", null, null);
                                saved = true;
                            } catch (GLib.Error e) { }
                        } else {
                            try {
                                GLib.FileUtils.set_contents(tpath, (string)body_data);
                                saved = true;
                            } catch (GLib.Error e) { }
                        }
                    } catch (GLib.Error e) { }

                    // Update database with icon filename after successful save
                    if (saved && rss_feed_url != null) {
                        try {
                            var store = Paperboy.RssSourceStore.get_instance();
                            store.update_source_icon(rss_feed_url, filename);
                        } catch (GLib.Error e) {
                            GLib.warning("Failed to update icon filename in database: %s", e.message);
                        }
                    }
                } catch (GLib.Error e) { }
                return null;
            });
        } catch (GLib.Error e) { /* don't let index writes break parsing */ }
    }

    // Read logo information from meta files for a given source name.
    // Returns a tuple of (logo_url, saved_filename) if found, null otherwise.
    public static string? get_logo_url_for_source(string source_name) {
        try {
            string? info_dir = get_user_source_info_dir();
            if (info_dir == null) return null;

            // Try to find a meta file matching the source name
            string sanitized = sanitize_filename(source_name);
            string meta_path = GLib.Path.build_filename(info_dir, sanitized + ".json");

            if (!GLib.FileUtils.test(meta_path, GLib.FileTest.EXISTS)) {
                return null;
            }

            string contents;
            if (!GLib.FileUtils.get_contents(meta_path, out contents)) {
                return null;
            }

            // Parse JSON to extract original_logo_url
            var parser = new Json.Parser();
            parser.load_from_data(contents);
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) {
                return null;
            }

            var obj = root.get_object();
            if (obj.has_member("original_logo_url")) {
                return obj.get_string_member("original_logo_url");
            }
        } catch (GLib.Error e) { }
        return null;
    }

    // Get the saved filename for a source from meta files
    public static string? get_saved_filename_for_source(string source_name) {
        try {
            string? info_dir = get_user_source_info_dir();
            if (info_dir == null) return null;

            string sanitized = sanitize_filename(source_name);
            string meta_path = GLib.Path.build_filename(info_dir, sanitized + ".json");

            if (!GLib.FileUtils.test(meta_path, GLib.FileTest.EXISTS)) {
                return null;
            }

            string contents;
            if (!GLib.FileUtils.get_contents(meta_path, out contents)) {
                return null;
            }

            var parser = new Json.Parser();
            parser.load_from_data(contents);
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) {
                return null;
            }

            var obj = root.get_object();
            if (obj.has_member("saved_filename")) {
                return obj.get_string_member("saved_filename");
            }
        } catch (GLib.Error e) { }
        return null;
    }

    // Get the display name for a source from meta files
    // This returns the original display_name that was saved, which may differ
    // from the source_name passed in (e.g., "Tom's Guide" vs sanitized version)
    public static string? get_display_name_for_source(string source_name) {
        try {
            string? info_dir = get_user_source_info_dir();
            if (info_dir == null) return null;

            string sanitized = sanitize_filename(source_name);
            string meta_path = GLib.Path.build_filename(info_dir, sanitized + ".json");

            if (!GLib.FileUtils.test(meta_path, GLib.FileTest.EXISTS)) {
                return null;
            }

            string contents;
            if (!GLib.FileUtils.get_contents(meta_path, out contents)) {
                return null;
            }

            var parser = new Json.Parser();
            parser.load_from_data(contents);
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) {
                return null;
            }

            var obj = root.get_object();
            if (obj.has_member("display_name")) {
                return obj.get_string_member("display_name");
            }
        } catch (GLib.Error e) { }
        return null;
    }

    // Try to find source info by matching URL domain
    // Returns a tuple: (display_name, logo_url, saved_filename)
    public static void get_source_info_by_url(string? article_url, out string? display_name, out string? logo_url, out string? saved_filename) {
        display_name = null;
        logo_url = null;
        saved_filename = null;

        if (article_url == null || article_url.length == 0) return;

        try {
            string? info_dir = get_user_source_info_dir();
            if (info_dir == null) return;

            // Extract domain from article URL
            string article_domain = extract_domain_from_url(article_url);
            if (article_domain == null || article_domain.length == 0) return;

            // Scan all JSON files in source_info directory
            var dir = GLib.Dir.open(info_dir, 0);
            string? filename = null;
            while ((filename = dir.read_name()) != null) {
                if (!filename.has_suffix(".json")) continue;

                string meta_path = GLib.Path.build_filename(info_dir, filename);
                string contents;
                if (!GLib.FileUtils.get_contents(meta_path, out contents)) continue;

                var parser = new Json.Parser();
                parser.load_from_data(contents);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) continue;

                var obj = root.get_object();

                // Check if source_url matches the article domain
                if (obj.has_member("source_url")) {
                    string? source_url = obj.get_string_member("source_url");
                    if (source_url != null) {
                        string source_domain = extract_domain_from_url(source_url);
                        if (source_domain != null && source_domain == article_domain) {
                            // Found a match!
                            if (obj.has_member("display_name")) {
                                display_name = obj.get_string_member("display_name");
                            }
                            if (obj.has_member("original_logo_url")) {
                                logo_url = obj.get_string_member("original_logo_url");
                            }
                            if (obj.has_member("saved_filename")) {
                                saved_filename = obj.get_string_member("saved_filename");
                            }
                            return;
                        }
                    }
                }
            }
        } catch (GLib.Error e) { }
    }

    // Helper to extract domain from URL (e.g., "https://www.tomsguide.com/news" -> "tomsguide.com")
    private static string? extract_domain_from_url(string? url) {
        if (url == null) return null;
        string u = url.strip();

        // Remove scheme
        int pos = u.index_of("://");
        if (pos >= 0) u = u.substring(pos + 3);

        // Remove path
        int slash = u.index_of("/");
        if (slash >= 0) u = u.substring(0, slash);

        // Remove port
        int colon = u.index_of(":");
        if (colon >= 0) u = u.substring(0, colon);

        // Strip www prefix
        if (u.has_prefix("www.")) u = u.substring(4);

        return u.length > 0 ? u : null;
    }
}
