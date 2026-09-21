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

// Imports a PDF into the local magazine library, either downloaded from a
// user-supplied https:// URL or copied in from a local file the user
// already has (see import_from_url()/import_from_path()). Both paths
// enforce the same hard size cap, check the real file bytes look like a
// PDF, save the result under MagazineLibraryStore's pdf dir, and render a
// first-page thumbnail via the out-of-process paperboy-magazine-thumbnailer
// helper (see tools/magazineThumbnailer.vala) rather than parsing the
// untrusted file with Poppler in this process.
namespace Paperboy {
    public class MagazinePdfImportService : GLib.Object {
        public delegate void ImportCallback(bool success, Paperboy.MagazineEntry? entry, string? error_message);

        public const int64 MAX_PDF_BYTES = 150 * 1024 * 1024;
        private const int THUMBNAIL_TIMEOUT_SECONDS = 20;
        private const int THUMBNAIL_MAX_DIM = 500;

        private static MagazinePdfImportService? instance = null;
        public static MagazinePdfImportService get_instance() {
            if (instance == null) instance = new MagazinePdfImportService();
            return instance;
        }

        // source_id is 0 for a PDF added directly (not discovered via a
        // MagazineSource website scan).
        public void import_from_url(string pdf_url, string? title_override, int64 source_id, Soup.Session session, owned ImportCallback callback) {
            if (!pdf_url.has_prefix("https://")) {
                callback(false, null, "Only https:// links are supported");
                return;
            }

            if (Paperboy.MagazineLibraryStore.get_instance().entry_exists_for_url(pdf_url)) {
                callback(false, null, "Already in your library");
                return;
            }

            new GLib.Thread<void*>("magazine-pdf-import", () => {
                Paperboy.MagazineEntry? entry = null;
                string? error = null;
                try {
                    entry = do_import_from_url(pdf_url, title_override, source_id, session);
                    if (entry == null) error = "Failed to save that magazine";
                } catch (GLib.Error e) {
                    error = e.message;
                }

                GLib.Idle.add(() => {
                    callback(entry != null, entry, entry != null ? null : error);
                    return false;
                });
                return null;
            });
        }

        // Imports a PDF the user already has on disk (via the file picker
        // in the Add Magazines dialog) - same validation/thumbnail/title
        // pipeline as a URL import, just skipping the download step. The
        // file is copied into the library's own pdf dir, not moved, so the
        // user's original file is left untouched. Its path (as a file://
        // URI) stands in for source_url, the same role a real download URL
        // plays for dedup/id purposes - two different local files can't
        // collide, and re-adding the same path is recognized as already
        // in the library exactly like re-adding the same download link is.
        public void import_from_path(string local_source_path, string? title_override, int64 source_id, owned ImportCallback callback) {
            string source_url = "file://" + local_source_path;
            if (Paperboy.MagazineLibraryStore.get_instance().entry_exists_for_url(source_url)) {
                callback(false, null, "Already in your library");
                return;
            }

            new GLib.Thread<void*>("magazine-pdf-import-local", () => {
                Paperboy.MagazineEntry? entry = null;
                string? error = null;
                try {
                    entry = do_import_from_path(local_source_path, source_url, title_override, source_id);
                    if (entry == null) error = "Failed to save that magazine";
                } catch (GLib.Error e) {
                    error = e.message;
                }

                GLib.Idle.add(() => {
                    callback(entry != null, entry, entry != null ? null : error);
                    return false;
                });
                return null;
            });
        }

        private Paperboy.MagazineEntry? do_import_from_url(string pdf_url, string? title_override, int64 source_id, Soup.Session session) throws GLib.Error {
            var msg = new Soup.Message("GET", pdf_url);
            msg.get_request_headers().append("User-Agent", "paperboy/0.11");

            var input_stream = session.send(msg, null);
            if (msg.get_status() != Soup.Status.OK || input_stream == null) {
                throw new GLib.IOError.FAILED("Server returned status %u".printf(msg.get_status()));
            }

            string? content_type = msg.get_response_headers().get_one("Content-Type");
            if (!PdfValidatorUtils.content_type_looks_like_pdf(content_type)) {
                throw new GLib.IOError.FAILED("That link doesn't point to a PDF (got %s)".printf(content_type ?? "an unknown content type"));
            }

            string? content_length_str = msg.get_response_headers().get_one("Content-Length");
            if (content_length_str != null) {
                int64 declared_length = int64.parse(content_length_str);
                if (declared_length > MAX_PDF_BYTES) {
                    throw new GLib.IOError.FAILED("File is too large (%s, limit is 150MB)".printf(GLib.format_size((uint64) declared_length)));
                }
            }

            // Enforced independently of the header above - a server can lie
            // about (or omit) Content-Length, so the cap is applied to the
            // bytes actually received as they stream in.
            var buffer = new GLib.ByteArray();
            uint8[] chunk = new uint8[65536];
            while (true) {
                size_t bytes_read;
                bool ok = input_stream.read_all(chunk, out bytes_read, null);
                if (!ok || bytes_read == 0) break;
                buffer.append(chunk[0:(int) bytes_read]);
                if (buffer.len > MAX_PDF_BYTES) {
                    input_stream.close(null);
                    throw new GLib.IOError.FAILED("File exceeded the 150MB size limit");
                }
            }
            input_stream.close(null);

            return finish_import(buffer.data, pdf_url, title_override, source_id);
        }

        private Paperboy.MagazineEntry? do_import_from_path(string local_source_path, string source_url, string? title_override, int64 source_id) throws GLib.Error {
            var source_file = GLib.File.new_for_path(local_source_path);
            uint8[] data;
            source_file.load_contents(null, out data, null);

            if (data.length > MAX_PDF_BYTES) {
                throw new GLib.IOError.FAILED("File is too large (%s, limit is 150MB)".printf(GLib.format_size((uint64) data.length)));
            }

            return finish_import(data, source_url, title_override, source_id);
        }

        // Shared by both import paths - magic-byte validation, saving into
        // the library's own pdf dir, thumbnail + title extraction (via the
        // sandboxed subprocess), and the store insert.
        private Paperboy.MagazineEntry? finish_import(uint8[] data, string source_url, string? title_override, int64 source_id) throws GLib.Error {
            if (!PdfValidatorUtils.looks_like_pdf(data)) {
                throw new GLib.IOError.FAILED("That doesn't look like a valid PDF file");
            }

            var store = Paperboy.MagazineLibraryStore.get_instance();
            int64 entry_id = Paperboy.MagazineEntry.compute_id(source_url);
            string local_path = GLib.Path.build_filename(store.get_pdf_dir(), entry_id.to_string() + ".pdf");

            var out_file = GLib.File.new_for_path(local_path);
            var out_stream = out_file.replace(null, false, GLib.FileCreateFlags.NONE, null);
            out_stream.write(data, null);
            out_stream.close(null);

            string? pdf_title;
            string? thumbnail_path = generate_thumbnail(local_path, entry_id, out pdf_title);

            // Prefer, in order: a title the user typed in the Add dialog,
            // the PDF's own embedded title (far more reliable than one
            // guessed from the URL/filename - archive.org links in
            // particular are bare identifiers like
            // "sim_popular-science_1975-03_206_3.pdf"), then finally the
            // URL/filename-derived guess.
            string title = (title_override != null && title_override.strip().length > 0)
                ? title_override.strip()
                : (pdf_title != null && pdf_title.strip().length > 0)
                    ? pdf_title.strip()
                    : derive_title(source_url);

            var entry = new Paperboy.MagazineEntry();
            entry.id = entry_id;
            entry.source_id = source_id;
            entry.title = title;
            entry.source_url = source_url;
            entry.local_path = local_path;
            entry.thumbnail_path = thumbnail_path;
            entry.added_at = GLib.get_real_time() / 1000000;

            if (!store.add_entry(entry)) {
                try { out_file.delete(); } catch (GLib.Error e) { }
                return null;
            }

            return entry;
        }

        private string derive_title(string url) {
            string path = url;
            int q = path.index_of_char('?');
            if (q >= 0) path = path.substring(0, q);
            string basename = GLib.Path.get_basename(path);
            if (basename.down().has_suffix(".pdf")) basename = basename.substring(0, basename.length - 4);
            basename = basename.replace("_", " ");
            // Only collapse a hyphen used as a word-joiner (e.g.
            // "my-magazine-name"), not one already set off by spaces like
            // " - " - that's a real separator in the title, not filename
            // punctuation standing in for a space.
            try {
                basename = new GLib.Regex("(?<=\\S)-(?=\\S)").replace(basename, -1, 0, " ");
            } catch (GLib.RegexError e) { }
            basename = basename.strip();
            return basename.length > 0 ? basename : "Untitled magazine";
        }

        private string? find_thumbnailer_binary() {
            string installed = GLib.Path.build_filename(BuildConstants.LIBEXECDIR, "paperboy-magazine-thumbnailer");
            if (GLib.FileUtils.test(installed, GLib.FileTest.IS_EXECUTABLE)) return installed;

            // Dev tree: built next to the main `paperboy` binary.
            try {
                string exe_path = GLib.FileUtils.read_link("/proc/self/exe");
                string dev_path = GLib.Path.build_filename(GLib.Path.get_dirname(exe_path), "paperboy-magazine-thumbnailer");
                if (GLib.FileUtils.test(dev_path, GLib.FileTest.IS_EXECUTABLE)) return dev_path;
            } catch (GLib.Error e) { }

            return null;
        }

        // Also captures the sandboxed process's stdout for the PDF's
        // embedded title (see tools/magazineThumbnailer.vala) - reading it
        // from there means do_import never has to parse the untrusted PDF
        // itself to get it.
        private string? generate_thumbnail(string pdf_path, int64 entry_id, out string? extracted_title) {
            extracted_title = null;

            string? binary = find_thumbnailer_binary();
            if (binary == null) {
                GLib.warning("Magazine thumbnailer binary not found - skipping thumbnail");
                return null;
            }

            var store = Paperboy.MagazineLibraryStore.get_instance();
            string thumb_path = GLib.Path.build_filename(store.get_thumbnail_dir(), entry_id.to_string() + ".png");

            try {
                var subprocess = new GLib.Subprocess(GLib.SubprocessFlags.STDOUT_PIPE,
                    binary, pdf_path, thumb_path, THUMBNAIL_MAX_DIM.to_string());

                // Force-exits a hung/pathological render so a malicious PDF
                // can't tie up import indefinitely - a no-op once the
                // process has already exited on its own.
                new GLib.Thread<void*>("magazine-thumb-watchdog", () => {
                    GLib.Thread.usleep(THUMBNAIL_TIMEOUT_SECONDS * 1000000);
                    try { subprocess.force_exit(); } catch (GLib.Error e) { }
                    return null;
                });

                string? stdout_text = null;
                subprocess.communicate_utf8(null, null, out stdout_text, null);

                if (stdout_text != null) {
                    foreach (var line in stdout_text.split("\n")) {
                        if (line.has_prefix("TITLE:")) {
                            extracted_title = line.substring(6).strip();
                            break;
                        }
                    }
                }

                if (subprocess.get_successful() && GLib.FileUtils.test(thumb_path, GLib.FileTest.EXISTS)) {
                    return thumb_path;
                }
            } catch (GLib.Error e) {
                GLib.warning("Failed to run magazine thumbnailer: %s", e.message);
            }
            return null;
        }
    }
}
