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
    private static Adw.Dialog? current_instance = null;

    public static void show(NewsWindow window) {
        if (current_instance != null) {
            current_instance.present(window);
            return;
        }

        // Adw.Dialog shares the main window's toplevel, so when it closes
        // GTK has no independent focus chain to fall back to and instead
        // grabs the first focusable widget in tab order - an article card
        // button near the top of the feed - which drags main_scrolled's
        // scroll position back to the top. Restore focus explicitly instead.
        Gtk.Widget? previously_focused = window.get_focus();

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

            // Thread notes under their article: group by url, preserving
            // the get_all_notes() recency order for which group comes first.
            var order = new Gee.ArrayList<string>();
            var groups = new Gee.HashMap<string, Gee.ArrayList<Paperboy.ArticleNote>>();
            foreach (var note in notes) {
                var bucket = groups.get(note.url);
                if (bucket == null) {
                    bucket = new Gee.ArrayList<Paperboy.ArticleNote>();
                    groups.set(note.url, bucket);
                    order.add(note.url);
                }
                bucket.add(note);
            }

            foreach (var url in order) {
                list_box.append(build_article_group(window, url, groups.get(url), refresh));
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
            current_instance = null;
            if (previously_focused != null) {
                previously_focused.grab_focus();
            } else {
                window.main_scrolled.grab_focus();
            }
        });

        current_instance = dialog;
        dialog.present(window);
    }

    private delegate void VoidFunc();

    // Threads notes under a slim article header (real headline, not a
    // note's own title) - each note stays its own distinct card, just
    // indented beneath the header, so multiple notes on one article read
    // as a group rather than merging into one undivided block.
    private static Gtk.Widget build_article_group(NewsWindow window, string url, Gee.ArrayList<Paperboy.ArticleNote> notes, VoidFunc refresh_cb) {
        var group = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);
        group.add_css_class("comment-card");
        group.set_margin_bottom(10);

        string? real_title = Paperboy.RssArticleCache.get_instance().get_title_for_url(url);
        string header_title = (real_title != null && real_title.length > 0) ? real_title : notes.get(0).title;

        var title_source_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
        title_source_box.set_hexpand(true);

        var title_label = new Gtk.Label(header_title);
        title_label.add_css_class("heading");
        title_label.set_halign(Gtk.Align.START);
        title_label.set_ellipsize(Pango.EllipsizeMode.END);
        title_source_box.append(title_label);

        var source_label = new Gtk.Label(source_label_for_url(url));
        source_label.add_css_class("dim-label");
        source_label.add_css_class("caption");
        source_label.set_halign(Gtk.Align.START);
        source_label.set_ellipsize(Pango.EllipsizeMode.END);
        title_source_box.append(source_label);

        var meta_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        meta_row.append(title_source_box);

        var open_article_btn = new Gtk.Button.with_label("Open article");
        open_article_btn.add_css_class("flat");
        open_article_btn.add_css_class("note-open-article-btn");
        open_article_btn.set_valign(Gtk.Align.START);
        open_article_btn.clicked.connect(() => {
            if (window.article_manager != null) window.article_manager.open_article_in_app_if_online(url);
        });
        meta_row.append(open_article_btn);
        group.append(meta_row);

        // Matches ReaderView.highlight_notes()'s ordering (ascending by
        // note.id) so a note's badge number here is the same one shown on
        // its in-text marker and in the per-article notes panel.
        var numbered_notes = new Gee.ArrayList<Paperboy.ArticleNote>();
        numbered_notes.add_all(notes);
        numbered_notes.sort((a, b) => (int) (a.id - b.id));

        var notes_list = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        notes_list.set_margin_top(2);
        notes_list.append(build_thread_stem());
        for (int i = 0; i < notes.size; i++) {
            var thread_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            thread_row.append(build_thread_connector(i == notes.size - 1));
            var note_row = build_note_row(window, notes.get(i), numbered_notes.index_of(notes.get(i)) + 1);
            note_row.set_hexpand(true);
            // No box spacing between rows - the connector has no margin
            // of its own, so it fills this gap too and the line stays
            // unbroken between items instead of stopping short.
            if (i < notes.size - 1) note_row.set_margin_bottom(6);
            thread_row.append(note_row);
            notes_list.append(thread_row);
        }
        group.append(notes_list);

        return group;
    }

    // Short vertical segment linking the header down to the first note's
    // connector, so the thread visibly starts at the article title.
    private static Gtk.Widget build_thread_stem() {
        var da = new Gtk.DrawingArea();
        da.set_content_width(THREAD_LINE_X + 2);
        da.set_content_height(8);
        da.set_draw_func((area, cr, width, height) => {
            var color = area.get_color();
            cr.set_source_rgba(color.red, color.green, color.blue, 0.35);
            cr.set_line_width(2);
            cr.move_to(THREAD_LINE_X, 0);
            cr.line_to(THREAD_LINE_X, height);
            cr.stroke();
        });
        return da;
    }

    private const int THREAD_LINE_X = 9;

    // Vertical spine + a perpendicular elbow into each note, like a
    // threaded comment list. The spine continues past the elbow to the
    // next note unless this is the last one in the group.
    private static Gtk.Widget build_thread_connector(bool is_last) {
        var da = new Gtk.DrawingArea();
        da.set_content_width(THREAD_LINE_X + 10);
        da.set_draw_func((area, cr, width, height) => {
            var color = area.get_color();
            cr.set_source_rgba(color.red, color.green, color.blue, 0.35);
            cr.set_line_width(2);
            double mid_y = height / 2.0;

            cr.move_to(THREAD_LINE_X, 0);
            cr.line_to(THREAD_LINE_X, is_last ? mid_y : height);
            cr.stroke();

            cr.move_to(THREAD_LINE_X, mid_y);
            cr.line_to(width, mid_y);
            cr.stroke();
        });
        return da;
    }

    private static Gtk.Widget build_note_row(NewsWindow window, Paperboy.ArticleNote note, int display_number) {
        var row = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
        row.add_css_class("note-thread-item");

        var meta_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        var note_title_label = new Gtk.Label(note.title);
        note_title_label.add_css_class("caption-heading");
        note_title_label.set_halign(Gtk.Align.START);
        note_title_label.set_hexpand(true);
        note_title_label.set_ellipsize(Pango.EllipsizeMode.END);
        meta_row.append(note_title_label);

        var date_label = new Gtk.Label(DateUtils.time_ago(note.updated_at.to_string()));
        date_label.add_css_class("dim-label");
        date_label.add_css_class("caption");
        date_label.set_halign(Gtk.Align.END);
        meta_row.append(date_label);
        row.append(meta_row);

        string snippet = stripHtmlUtils.strip_html(note.content_html).strip();
        var body_label = new Gtk.Label(snippet);
        body_label.add_css_class("caption");
        body_label.set_wrap(true);
        body_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        body_label.set_halign(Gtk.Align.START);
        body_label.set_justify(Gtk.Justification.LEFT);
        body_label.set_lines(1);
        body_label.set_ellipsize(Pango.EllipsizeMode.END);
        row.append(body_label);

        if (display_number > 0) {
            var badge_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            badge_row.set_halign(Gtk.Align.END);
            var badge_label = new Gtk.Label(display_number.to_string());
            badge_label.add_css_class("note-list-badge");
            badge_row.append(badge_label);
            row.append(badge_row);
        }

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
