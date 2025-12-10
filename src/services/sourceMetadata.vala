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
    // Thread safety: mutex for file operations and tracking in-progress downloads
    private static GLib.Mutex download_mutex;
    private static Gee.HashSet<string>? downloads_in_progress = null;
    
    // Maximum file size for downloads (5MB)
    private const int64 MAX_DOWNLOAD_SIZE = 5 * 1024 * 1024;
    
    // Maximum filename length (filesystem safe)
    private const int MAX_FILENAME_LENGTH = 200;
    
    static construct {
        downloads_in_progress = new Gee.HashSet<string>();
    }
    
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
            if (info_dir == null) {
                warning("SourceMetadata: cannot write metadata, info_dir is null");
                return;
            }
            // Remove .png extension from meta filename to make it cleaner
            string base_filename = filename;
            if (base_filename.has_suffix("-logo.png")) {
                if (base_filename.length > 9)
                    base_filename = base_filename.substring(0, base_filename.length - 9);
            } else if (base_filename.has_suffix(".png")) {
                if (base_filename.length > 4)
                    base_filename = base_filename.substring(0, base_filename.length - 4);
            }
            string meta_path = GLib.Path.build_filename(info_dir, base_filename + ".json");

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
                                    // Improved heuristic: prefer names with better characteristics
                                    write_display_name = choose_better_display_name(existing_name, display_name);
                                }
                            }
                        } catch (GLib.Error e) {
                            warning("SourceMetadata: failed to parse existing metadata at %s: %s", meta_path, e.message);
                        }
                    }
                }
            } catch (GLib.Error e) {
                warning("SourceMetadata: error reading existing metadata: %s", e.message);
            }

            // Use Json.Builder for proper JSON generation
            var builder = new Json.Builder();
            builder.begin_object();
            
            builder.set_member_name("display_name");
            builder.add_string_value(write_display_name);
            
            builder.set_member_name("original_logo_url");
            builder.add_string_value(logo_url);
            
            if (source_url != null) {
                builder.set_member_name("source_url");
                builder.add_string_value(source_url);
            }
            
            builder.set_member_name("saved_filename");
            builder.add_string_value(filename);
            
            builder.set_member_name("saved_at");
            long now_s = (long)(GLib.get_real_time() / 1000000);
            builder.add_int_value(now_s);
            
            builder.end_object();
            
            var generator = new Json.Generator();
            generator.set_root(builder.get_root());
            generator.set_pretty(true);
            
            try {
                generator.to_file(meta_path);
            } catch (GLib.Error e) {
                warning("SourceMetadata: failed to write metadata to %s: %s", meta_path, e.message);
            }
        } catch (GLib.Error e) {
            warning("SourceMetadata: unexpected error in write_provider_meta: %s", e.message);
        }
    }
    
    // Choose the better display name between two options using improved heuristics
    private static string choose_better_display_name(string existing, string new_name) {
        // If names are identical, keep existing
        if (existing == new_name) return existing;
        
        // Count quality indicators
        int existing_score = 0;
        int new_score = 0;
        
        // Prefer names with spaces (multi-word names like "New York Times")
        if (existing.index_of(" ") >= 0) existing_score += 3;
        if (new_name.index_of(" ") >= 0) new_score += 3;
        
        // Penalize names with dots (likely domains)
        if (existing.index_of(".") >= 0) existing_score -= 2;
        if (new_name.index_of(".") >= 0) new_score -= 2;
        
        // Prefer names with mixed case (proper capitalization)
        bool existing_has_mixed = existing != existing.up() && existing != existing.down();
        bool new_has_mixed = new_name != new_name.up() && new_name != new_name.down();
        if (existing_has_mixed) existing_score += 2;
        if (new_has_mixed) new_score += 2;
        
        // Prefer shorter names (less likely to be URLs or long domains)
        if (existing.length < 30) existing_score += 1;
        if (new_name.length < 30) new_score += 1;
        
        // Special case: if existing looks like a domain and new doesn't, prefer new
        bool existing_is_domain = existing.index_of(".") >= 0 && existing.index_of(" ") < 0;
        bool new_is_domain = new_name.index_of(".") >= 0 && new_name.index_of(" ") < 0;
        if (existing_is_domain && !new_is_domain) return new_name;
        if (!existing_is_domain && new_is_domain) return existing;
        
        // Return the name with higher score, or existing if tied (preserve existing)
        return new_score > existing_score ? new_name : existing;
    }

    // Produce a friendly capitalized concatenation of display name parts.
    // Example: "New York Times" -> "NewYorkTimes"
    // Handles length limits and ensures filesystem-safe filenames
    public static string sanitize_filename(string input) {
        if (input == null || input.strip().length == 0) return "source";
        
        string s = input.strip();
        
        // Normalize unicode to avoid issues with different representations
        s = s.normalize(-1, GLib.NormalizeMode.NFC);
        
        // Split on any non-alphanumeric character and capitalize each token
        var parts = new Gee.ArrayList<string>();
        string token = "";
        for (int i = 0; i < s.length; i++) {
            unichar c = s.get_char(i);
            // Use unichar methods for proper unicode handling
            if (c.isalnum()) {
                token += c.to_string();
            } else {
                if (token.length > 0) { 
                    parts.add(token); 
                    token = ""; 
                }
            }
        }
        if (token.length > 0) parts.add(token);

        string out = "";
        foreach (var p in parts) {
            if (p.length == 0) continue;
            // Capitalize first char, keep rest as-is (preserve case for acronyms)
            unichar first_char = p.get_char(0);
            string first = first_char.toupper().to_string();
            string rest = "";
            int idx = 0;
            p.get_next_char(ref idx, out first_char); // Skip first char
            if (idx < p.length) {
                rest = p.substring(idx);
            }
            out += first + rest;
        }
        
        // Fallback if sanitization resulted in empty string
        if (out.length == 0) out = "source";
        
        // Truncate to maximum length, ensuring we don't break in the middle of a character
        if (out.length > MAX_FILENAME_LENGTH) {
            // Find a safe truncation point
            int truncate_at = MAX_FILENAME_LENGTH;
            while (truncate_at > 0 && !out.get_char(truncate_at).isalnum()) {
                truncate_at--;
            }
            if (truncate_at > 0) {
                out = out.substring(0, truncate_at);
            } else {
                out = out.substring(0, MAX_FILENAME_LENGTH);
            }
        }
        
        return out;
    }
    
    // Check if a filename already exists and generate a unique variant if needed
    private static string ensure_unique_filename(string base_filename, string dir) {
        string candidate = base_filename;
        int counter = 1;
        
        // Check if file exists, if so append a number
        while (GLib.FileUtils.test(GLib.Path.build_filename(dir, candidate), GLib.FileTest.EXISTS)) {
            // Extract base name without extension
            string name_part = base_filename;
            if (base_filename.has_suffix("-logo.png")) {
                name_part = base_filename.substring(0, base_filename.length - 9);
            }
            candidate = "%s-%d-logo.png".printf(name_part, counter);
            counter++;
            
            // Safety: don't loop forever
            if (counter > 1000) {
                warning("SourceMetadata: too many filename collisions for %s", base_filename);
                break;
            }
        }
        
        return candidate;
    }


    // Public entry: record mapping and attempt to download the logo into
    // a canonical filename. This is best-effort and runs the network work
    // in a background thread so it won't block the UI.
    public static void update_index_and_fetch(string provider_key, string display_name, string? logo_url, string? source_url, Soup.Session? session = null, string? rss_feed_url = null) {
        if (logo_url == null || logo_url.length == 0) {
            warning("SourceMetadata: skipping fetch, logo_url is null or empty");
            return;
        }
        
        try {
            string key = provider_key != null && provider_key.length > 0 ? provider_key : display_name;
            // Use the provider display name (rather than the opaque key) to
            // produce human-friendly filenames like "NewYorkTimes-logo.png".
            string base_name = sanitize_filename(display_name);
            string filename = base_name + "-logo.png";

            // Thread-safe check: acquire mutex before checking file existence
            download_mutex.lock();
            
            string? dir = get_user_logos_dir();
            if (dir == null) {
                warning("SourceMetadata: cannot fetch logo, logos_dir is null");
                download_mutex.unlock();
                return;
            }
            
            string target = GLib.Path.build_filename(dir, filename);
            
            // Check if file already exists
            bool logo_exists = false;
            try { 
                logo_exists = GLib.FileUtils.test(target, GLib.FileTest.EXISTS); 
            } catch (GLib.Error e) {
                warning("SourceMetadata: error checking file existence for %s: %s", target, e.message);
            }

            if (logo_exists) {
                // Logo file already exists - NEVER overwrite or re-download
                download_mutex.unlock();
                return;
            }
            
            // Check if download is already in progress for this URL
            // Ensure collection is initialized (race condition protection)
            if (downloads_in_progress == null) {
                downloads_in_progress = new Gee.HashSet<string>();
            }
            if (downloads_in_progress.contains(logo_url)) {
                download_mutex.unlock();
                message("SourceMetadata: download already in progress for %s", logo_url);
                return;
            }

            // Mark this download as in progress
            downloads_in_progress.add(logo_url);
            download_mutex.unlock();

            // Logo doesn't exist yet - download in background thread
            new Thread<void*>("source-logo-fetch", () => {
                bool download_completed = false;
                
                try {
                    string? ldir = get_user_logos_dir();
                    if (ldir == null) {
                        warning("SourceMetadata: logos_dir is null in download thread");
                        return null;
                    }
                    string tpath = GLib.Path.build_filename(ldir, filename);

                    message("SourceMetadata: fetching logo from %s", logo_url);
                    var client = Paperboy.HttpClient.get_default();
                    var http_response = client.fetch_sync(logo_url, null);

                    if (!http_response.is_success()) {
                        warning("SourceMetadata: HTTP request failed for %s (status: %u)", logo_url, http_response.status_code);
                        return null;
                    }
                    
                    if (http_response.body == null) {
                        warning("SourceMetadata: HTTP response body is null for %s", logo_url);
                        return null;
                    }
                    
                    // Validate content size
                    int64 content_length = (int64)http_response.body.get_size();
                    if (content_length > MAX_DOWNLOAD_SIZE) {
                        warning("SourceMetadata: content too large for %s (%lld bytes, max %lld)", 
                                logo_url, content_length, MAX_DOWNLOAD_SIZE);
                        return null;
                    }
                    
                    if (content_length == 0) {
                        warning("SourceMetadata: empty response body for %s", logo_url);
                        return null;
                    }
                    
                    // Validate Content-Type if available
                    string? content_type = http_response.get_header("content-type");
                    if (content_type != null) {
                        string ct_lower = content_type.down();
                        bool is_image = ct_lower.has_prefix("image/");
                        if (!is_image) {
                            warning("SourceMetadata: invalid Content-Type for %s: %s (expected image/*)", 
                                    logo_url, content_type);
                            return null;
                        }
                    }

                    bool saved = false;
                    try {
                        unowned uint8[] body_data = http_response.body.get_data();
                        uint8[] data = new uint8[body_data.length];
                        Memory.copy(data, body_data, body_data.length);
                        
                        // Validate image magic numbers (basic check)
                        if (!is_valid_image_data(data)) {
                            warning("SourceMetadata: data does not appear to be a valid image for %s", logo_url);
                            return null;
                        }

                        var loader = new PixbufLoader();
                        loader.write(data);
                        loader.close();
                        var pb = loader.get_pixbuf();
                        
                        if (pb != null) {
                            try {
                                // If the decoded pixbuf is very small (e.g., a 16x16
                                // favicon), skip saving it — prefer higher-resolution
                                // logos. This prevents low-res favicons from overwriting
                                // proper metadata images.
                                int pw = 0; int ph = 0;
                                try { pw = pb.get_width(); } catch (GLib.Error _) { pw = 0; }
                                try { ph = pb.get_height(); } catch (GLib.Error _) { ph = 0; }
                                const int MIN_SAVE_DIM = 32;
                                if (pw < MIN_SAVE_DIM || ph < MIN_SAVE_DIM) {
                                    message("SourceMetadata: skipping save of small logo for %s -> %s (pixbuf=%dx%d)", 
                                            logo_url, tpath, pw, ph);
                                } else {
                                    // Thread-safe file save: check again if file exists
                                    download_mutex.lock();
                                    bool exists_now = GLib.FileUtils.test(tpath, GLib.FileTest.EXISTS);
                                    if (!exists_now) {
                                        try {
                                            message("SourceMetadata: saving logo for %s -> %s (response size=%d bytes, pixbuf=%dx%d)", 
                                                    logo_url, tpath, data.length, pw, ph);
                                            pb.savev(tpath, "png", null, null);
                                            saved = true;
                                        } catch (GLib.Error e) {
                                            warning("SourceMetadata: failed to save pixbuf to %s: %s", tpath, e.message);
                                        }
                                    } else {
                                        message("SourceMetadata: file was created by another thread: %s", tpath);
                                    }
                                    download_mutex.unlock();
                                }
                            } catch (GLib.Error e) {
                                warning("SourceMetadata: error processing pixbuf for %s: %s", logo_url, e.message);
                            }
                        } else {
                            // If PixbufLoader couldn't produce a pixbuf, don't attempt
                            // to write the raw body bytes as a string (that corrupts
                            // binary data). Log and skip saving in that case.
                            warning("SourceMetadata: failed to parse image data for %s", tpath);
                        }
                    } catch (GLib.Error e) {
                        warning("SourceMetadata: error loading image data for %s: %s", logo_url, e.message);
                    }

                    // If we saved a valid image, write provider metadata (including
                    // the saved filename) and update the database record so UI can
                    // immediately use the local file. If we didn't save, avoid
                    // writing a saved_filename to metadata to prevent referencing
                    // non-existent or tiny files.
                    if (saved) {
                        try { 
                            write_provider_meta(filename, display_name, logo_url, source_url); 
                        } catch (GLib.Error e) {
                            warning("SourceMetadata: failed to write metadata: %s", e.message);
                        }
                        
                        if (rss_feed_url != null) {
                            try {
                                var store = Paperboy.RssSourceStore.get_instance();
                                store.update_source_icon(rss_feed_url, filename);
                            } catch (GLib.Error e) {
                                warning("SourceMetadata: failed to update icon filename in database: %s", e.message);
                            }
                        }
                        download_completed = true;
                    } else {
                        message("SourceMetadata: did not save logo for %s (no valid image)", logo_url);
                    }
                } catch (GLib.Error e) {
                    warning("SourceMetadata: unexpected error in download thread for %s: %s", logo_url, e.message);
                } finally {
                    // Always remove from in-progress set when done
                    download_mutex.lock();
                    if (downloads_in_progress != null) {
                        downloads_in_progress.remove(logo_url);
                    }
                    download_mutex.unlock();
                }
                
                return null;
            });
        } catch (GLib.Error e) {
            warning("SourceMetadata: error in update_index_and_fetch: %s", e.message);
        }
    }
    
    // Validate image data by checking magic numbers
    private static bool is_valid_image_data(uint8[] data) {
        if (data.length < 8) return false;
        
        // PNG magic number: 89 50 4E 47 0D 0A 1A 0A
        if (data.length >= 8 && 
            data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47 &&
            data[4] == 0x0D && data[5] == 0x0A && data[6] == 0x1A && data[7] == 0x0A) {
            return true;
        }
        
        // JPEG magic number: FF D8 FF
        if (data.length >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) {
            return true;
        }
        
        // GIF magic number: GIF87a or GIF89a
        if (data.length >= 6 && 
            data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46 &&
            data[3] == 0x38 && (data[4] == 0x37 || data[4] == 0x39) && data[5] == 0x61) {
            return true;
        }
        
        // WebP magic number: RIFF....WEBP
        if (data.length >= 12 &&
            data[0] == 0x52 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x46 &&
            data[8] == 0x57 && data[9] == 0x45 && data[10] == 0x42 && data[11] == 0x50) {
            return true;
        }
        
        // SVG (XML-based, check for <?xml or <svg)
        if (data.length >= 5) {
            string start = ((string)data).substring(0, int.min(100, (int)data.length)).down();
            if (start.has_prefix("<?xml") || start.has_prefix("<svg")) {
                return true;
            }
        }
        
        warning("SourceMetadata: unrecognized image format (first bytes: %02X %02X %02X %02X)", 
                data[0], data[1], data[2], data[3]);
        return false;
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

    // Validate the saved logo file for a given source and return the
    // saved filename only if the file loads as a usable pixbuf.
    // Less aggressive: only remove files if they're clearly corrupted, not on transient errors.
    public static string? get_valid_saved_filename_for_source(string source_name, int req_w, int req_h) {
        try {
            string? fname = get_saved_filename_for_source(source_name);
            if (fname == null || fname.length == 0) return null;
            
            string? dir = get_user_logos_dir();
            if (dir == null) {
                warning("SourceMetadata: logos_dir is null in validation");
                return null;
            }
            
            string path = GLib.Path.build_filename(dir, fname);
            bool exists = false;
            try { 
                exists = GLib.FileUtils.test(path, GLib.FileTest.EXISTS); 
            } catch (GLib.Error e) { 
                warning("SourceMetadata: error checking file existence in validation: %s", e.message);
                return null;
            }
            
            if (!exists) {
                message("SourceMetadata: saved logo file does not exist: %s", path);
                return null;
            }

            // Try to load a small pixbuf via ImageCache to validate the image.
            try {
                string key = "pixbuf::file:%s::%dx%d".printf(path, req_w, req_h);
                Gdk.Pixbuf? pb = ImageCache.get_global().get_or_load_file(key, path, req_w, req_h);
                
                if (pb == null) {
                    warning("SourceMetadata: saved logo not loadable (may be corrupted): %s", path);
                    // Don't delete - could be transient ImageCache issue
                    return null;
                }
                
                int width = 0, height = 0;
                try {
                    width = pb.get_width();
                    height = pb.get_height();
                } catch (GLib.Error e) {
                    warning("SourceMetadata: error getting pixbuf dimensions for %s: %s", path, e.message);
                    return null;
                }
                
                if (width <= 1 || height <= 1) {
                    warning("SourceMetadata: saved logo has invalid dimensions (%dx%d): %s", width, height, path);
                    // Only delete if clearly corrupted (1x1 or smaller)
                    try { GLib.FileUtils.remove(path); } catch (GLib.Error e) {
                        warning("SourceMetadata: failed to remove corrupted file %s: %s", path, e.message);
                    }
                    return null;
                }
                
                //message("SourceMetadata: validated saved logo %s (%dx%d)", path, width, height);
                return fname;
            } catch (GLib.Error e) {
                warning("SourceMetadata: error validating saved logo %s: %s", path, e.message);
                // Don't delete on validation errors - could be transient
                return null;
            }
        } catch (GLib.Error e) {
            warning("SourceMetadata: unexpected error in get_valid_saved_filename_for_source: %s", e.message);
            return null;
        }
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
            if (info_dir == null) {
                warning("SourceMetadata: info_dir is null in get_source_info_by_url");
                return;
            }

            // Extract domain from article URL
            string? article_domain = extract_domain_from_url(article_url);
            if (article_domain == null || article_domain.length == 0) {
                warning("SourceMetadata: could not extract domain from URL: %s", article_url);
                return;
            }

            // Scan all JSON files in source_info directory
            GLib.Dir? dir = null;
            try {
                dir = GLib.Dir.open(info_dir, 0);
            } catch (GLib.Error e) {
                warning("SourceMetadata: failed to open directory %s: %s", info_dir, e.message);
                return;
            }
            
            if (dir == null) {
                warning("SourceMetadata: Dir.open returned null for %s", info_dir);
                return;
            }
            
            string? filename = null;
            while ((filename = dir.read_name()) != null) {
                if (!filename.has_suffix(".json")) continue;

                string meta_path = GLib.Path.build_filename(info_dir, filename);
                string contents;
                if (!GLib.FileUtils.get_contents(meta_path, out contents)) {
                    warning("SourceMetadata: failed to read metadata file: %s", meta_path);
                    continue;
                }

                try {
                    var parser = new Json.Parser();
                    parser.load_from_data(contents);
                    var root = parser.get_root();
                    if (root == null || root.get_node_type() != Json.NodeType.OBJECT) continue;

                    var obj = root.get_object();

                    // Check if source_url matches the article domain
                    if (obj.has_member("source_url")) {
                        string? source_url = obj.get_string_member("source_url");
                        if (source_url != null) {
                            string? source_domain = extract_domain_from_url(source_url);
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
                                message("SourceMetadata: found match for domain %s in %s", article_domain, filename);
                                return;
                            }
                        }
                    }
                } catch (GLib.Error e) {
                    warning("SourceMetadata: error parsing metadata file %s: %s", meta_path, e.message);
                    continue;
                }
            }
        } catch (GLib.Error e) {
            warning("SourceMetadata: unexpected error in get_source_info_by_url: %s", e.message);
        }
    }

    // Helper to extract domain from URL (e.g., "https://www.tomsguide.com/news" -> "tomsguide.com")
    // Improved to handle edge cases and provide better logging
    private static string? extract_domain_from_url(string? url) {
        if (url == null || url.length == 0) return null;
        
        string u = url.strip();
        if (u.length == 0) return null;

        // Remove scheme (http://, https://, etc.)
        int pos = u.index_of("://");
        if (pos >= 0) {
            if (u.length <= pos + 3) {
                warning("SourceMetadata: malformed URL (no content after scheme): %s", url);
                return null;
            }
            u = u.substring(pos + 3);
        }

        // Remove path (everything after first /)
        int slash = u.index_of("/");
        if (slash >= 0) {
            u = u.substring(0, slash);
        }
        
        // Remove query parameters (everything after ?)
        int question = u.index_of("?");
        if (question >= 0) {
            u = u.substring(0, question);
        }

        // Remove port (everything after :)
        int colon = u.index_of(":");
        if (colon >= 0) {
            u = u.substring(0, colon);
        }
        
        // Remove authentication (user:pass@domain)
        int at = u.index_of("@");
        if (at >= 0 && u.length > at + 1) {
            u = u.substring(at + 1);
        }

        // Strip common prefixes (www, m, mobile)
        if (u.has_prefix("www.") && u.length > 4) {
            u = u.substring(4);
        } else if (u.has_prefix("m.") && u.length > 2) {
            u = u.substring(2);
        } else if (u.has_prefix("mobile.") && u.length > 7) {
            u = u.substring(7);
        }
        
        // Final validation
        u = u.strip();
        if (u.length == 0) {
            warning("SourceMetadata: domain extraction resulted in empty string for URL: %s", url);
            return null;
        }
        
        // Basic sanity check: domain should contain at least one dot
        if (u.index_of(".") < 0) {
            warning("SourceMetadata: extracted domain has no dot (might be invalid): %s from %s", u, url);
        }

        return u;
    }
}
