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

// Lists every note across every article, reachable from the sidebar's
// "Notes" item so users can find their notes without having to reopen the
// specific article a note was written on. Built fresh per show() call,
// mirroring PodcastDetailDialog/ShareDialog's static-show pattern.
public class NotesBrowserDialog : GLib.Object {
    public static void show(NewsWindow window) {
        var dialog = new Adw.Dialog();
        dialog.set_content_width(560);
        dialog.set_content_height(640);
        dialog.set_title("Notes");

        var header = new Adw.HeaderBar();

        var list_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        list_box.set_margin_start(16);
        list_box.set_margin_end(16);
        list_box.set_margin_top(12);
        list_box.set_margin_bottom(12);

        var scroller = new Gtk.ScrolledWindow();
        scroller.set_hexpand(true);
        scroller.set_vexpand(true);
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        scroller.set_child(list_box);

        var status_label = new Gtk.Label("No notes yet.\nOpen an article and tap the notes icon to add one.");
        status_label.add_css_class("dim-label");
        status_label.set_justify(Gtk.Justification.CENTER);
        status_label.set_halign(Gtk.Align.CENTER);
        status_label.set_valign(Gtk.Align.CENTER);
        status_label.set_vexpand(true);

        var stack = new Gtk.Stack();
        stack.set_hexpand(true);
        stack.set_vexpand(true);
        stack.add_named(status_label, "status");
        stack.add_named(scroller, "list");

        var toolbar_view = new Adw.ToolbarView();
        toolbar_view.add_top_bar(header);
        toolbar_view.set_content(stack);
        dialog.set_child(toolbar_view);

        VoidFunc refresh = null;
        refresh = () => {
            Gtk.Widget? child = list_box.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                list_box.remove(child);
                child = next;
            }

            var notes = Paperboy.NotesStore.get_instance().get_all_notes();
            if (notes.size == 0) {
                stack.set_visible_child_name("status");
                return;
            }
            foreach (var note in notes) {
                list_box.append(build_row(window, note, refresh));
            }
            stack.set_visible_child_name("list");
        };
        refresh();

        var store = Paperboy.NotesStore.get_instance();
        ulong added_handler = store.note_added.connect((note) => { refresh(); });
        ulong updated_handler = store.note_updated.connect((note) => { refresh(); });
        ulong removed_handler = store.note_removed.connect((url, id) => { refresh(); });

        dialog.closed.connect(() => {
            store.disconnect(added_handler);
            store.disconnect(updated_handler);
            store.disconnect(removed_handler);
        });

        dialog.present(window);
    }

    private delegate void VoidFunc();

    private static Gtk.Widget build_row(NewsWindow window, Paperboy.ArticleNote note, VoidFunc refresh_cb) {
        var row = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);
        row.add_css_class("comment-card");
        row.set_margin_bottom(10);

        var meta_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        var title_label = new Gtk.Label(note.title);
        title_label.add_css_class("heading");
        title_label.set_halign(Gtk.Align.START);
        title_label.set_hexpand(true);
        title_label.set_ellipsize(Pango.EllipsizeMode.END);
        meta_row.append(title_label);

        var date_label = new Gtk.Label(DateUtils.time_ago(note.updated_at.to_string()));
        date_label.add_css_class("dim-label");
        date_label.add_css_class("caption");
        date_label.set_halign(Gtk.Align.END);
        meta_row.append(date_label);
        row.append(meta_row);

        string source = source_label_for_url(note.url);
        var source_label = new Gtk.Label(source);
        source_label.add_css_class("dim-label");
        source_label.add_css_class("caption");
        source_label.set_halign(Gtk.Align.START);
        source_label.set_ellipsize(Pango.EllipsizeMode.END);
        row.append(source_label);

        string snippet = stripHtmlUtils.strip_html(note.content_html).strip();
        var body_label = new Gtk.Label(snippet);
        body_label.set_wrap(true);
        body_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        body_label.set_halign(Gtk.Align.START);
        body_label.set_justify(Gtk.Justification.LEFT);
        body_label.set_lines(3);
        body_label.set_ellipsize(Pango.EllipsizeMode.END);
        row.append(body_label);

        var action_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        action_row.set_margin_top(4);
        action_row.set_halign(Gtk.Align.END);

        var open_article_btn = new Gtk.Button.with_label("Open article");
        open_article_btn.add_css_class("flat");
        open_article_btn.add_css_class("caption");
        open_article_btn.clicked.connect(() => {
            if (window.article_manager != null) window.article_manager.open_article_in_app_if_online(note.url);
        });
        action_row.append(open_article_btn);
        row.append(action_row);

        var click = new Gtk.GestureClick();
        row.add_controller(click);
        click.pressed.connect((g, n_press, x, y) => {
            if (n_press == 2) {
                NoteEditorDialog.show(window, note.url, note);
            }
        });

        return row;
    }

    private static string source_label_for_url(string url) {
        string? display_name = null;
        string? logo_url = null;
        string? saved_filename = null;
        SourceMetadata.get_source_info_by_url(url, out display_name, out logo_url, out saved_filename);
        if (display_name != null && display_name.length > 0) return display_name;

        string host = UrlUtils.extract_host_from_url(url);
        return host.length > 0 ? UrlUtils.prettify_host(host) : url;
    }
}
