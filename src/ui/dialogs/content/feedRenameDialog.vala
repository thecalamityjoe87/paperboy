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


using Gtk;
using Adw;

/**
 * FeedRenameDialog - Prompt for a custom display name for a followed feed
 */
public class FeedRenameDialog : GLib.Object {
    public delegate void RenamedCallback(Paperboy.RssSource updated);

    // Leaving the entry empty resets the feed back to its default name.
    public static void present(Gtk.Widget parent, NewsWindow? window, string source_url, owned RenamedCallback? on_renamed = null) {
        var store = Paperboy.RssSourceStore.get_instance();
        var source = store.get_source_by_url(source_url);
        if (source == null) return;

        var dialog = new Adw.AlertDialog("Rename feed", "Leave empty to use the default name.");

        var entry = new Gtk.Entry();
        entry.set_text(source.get_display_name());
        entry.set_placeholder_text(source.name);
        entry.set_activates_default(true);
        dialog.set_extra_child(entry);

        dialog.add_response("cancel", "Cancel");
        dialog.add_response("rename", "Rename");
        dialog.set_response_appearance("rename", Adw.ResponseAppearance.SUGGESTED);
        dialog.set_default_response("rename");
        dialog.set_close_response("cancel");

        dialog.response.connect((response_id) => {
            if (response_id != "rename") return;

            string new_name = entry.get_text().strip();
            // Typing the default name back in is the same as resetting it.
            string? default_name = SourceMetadata.get_display_name_for_source(source.name);
            if (new_name == source.name || (default_name != null && new_name == default_name)) {
                new_name = "";
            }

            if (!store.set_custom_name(source_url, new_name)) return;

            if (window != null) {
                if (window.sidebar_manager != null) window.sidebar_manager.rebuild_sidebar();
                window.update_content_header();
            }

            var updated = store.get_source_by_url(source_url);
            if (updated != null && on_renamed != null) on_renamed(updated);
        });

        dialog.present(parent);
        entry.grab_focus();
    }
}
