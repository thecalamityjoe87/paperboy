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

namespace Paperboy {
    // Exports/imports article notes as a JSON array. There's no standard
    // interchange format for notes, so this is a plain Paperboy-specific
    // structure keyed by the article URL each note is attached to.
    public class NotesExportService : GLib.Object {
        public static bool export_to_file(string path) throws GLib.Error {
            var notes = NotesStore.get_instance().get_all_notes();

            var builder = new Json.Builder();
            builder.begin_array();
            foreach (var note in notes) {
                builder.begin_object();
                builder.set_member_name("url");
                builder.add_string_value(note.url);
                builder.set_member_name("title");
                builder.add_string_value(note.title);
                builder.set_member_name("content_html");
                builder.add_string_value(note.content_html);
                builder.set_member_name("created_at");
                builder.add_int_value(note.created_at);
                builder.set_member_name("updated_at");
                builder.add_int_value(note.updated_at);
                builder.set_member_name("quote");
                if (note.quote != null) {
                    builder.add_string_value(note.quote);
                } else {
                    builder.add_null_value();
                }
                builder.end_object();
            }
            builder.end_array();

            var generator = new Json.Generator();
            generator.set_root(builder.get_root());
            generator.pretty = true;
            return generator.to_file(path);
        }

        // Returns the number of notes successfully imported.
        public static int import_from_file(string path) throws GLib.Error {
            var parser = new Json.Parser();
            parser.load_from_file(path);

            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.ARRAY) {
                throw new GLib.IOError.INVALID_DATA("Not a valid Paperboy notes export");
            }

            var notes_store = NotesStore.get_instance();
            int imported = 0;

            foreach (var element in root.get_array().get_elements()) {
                if (element.get_node_type() != Json.NodeType.OBJECT) continue;
                var obj = element.get_object();
                if (!obj.has_member("url") || !obj.has_member("content_html")) continue;

                string url = obj.get_string_member("url");
                string title = obj.has_member("title") ? obj.get_string_member("title") : "";
                string content_html = obj.get_string_member("content_html");
                string? quote = (obj.has_member("quote") && !obj.get_null_member("quote"))
                    ? obj.get_string_member("quote") : null;

                if (notes_store.add_note(url, title, content_html, quote) != null) {
                    imported++;
                }
            }

            return imported;
        }
    }
}
