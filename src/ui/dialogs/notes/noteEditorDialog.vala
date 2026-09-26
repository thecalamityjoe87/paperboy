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

// Rich-text note editor: a title entry, a small formatting toolbar that
// drives a contenteditable WebView via document.execCommand, and Save/Cancel
// actions. Creates a new note or edits an existing one depending on whether
// `existing` is passed. Built fresh per show() call, mirroring
// PodcastDetailDialog's static-show pattern.
public class NoteEditorDialog : GLib.Object {
    private const string EDITOR_CSS = """
        :root { color-scheme: light dark; }
        body {
            margin: 0;
            padding: 4px 16px 16px 16px;
            font-family: -apple-system, "Cantarell", "Segoe UI", sans-serif;
            font-size: 15px;
            line-height: 1.5;
            background: transparent;
            color: #1a1a1a;
        }
        @media (prefers-color-scheme: dark) {
            body { color: #eeeeee; }
        }
        #editor { outline: none; min-height: 260px; }
        #editor ul, #editor ol { padding-left: 1.4em; }
    """;

    public static void show(Gtk.Window parent, string article_url, Paperboy.ArticleNote? existing, string? quote = null) {
        var dialog = new Adw.Dialog();
        dialog.set_content_width(640);
        dialog.set_content_height(560);
        dialog.set_title(existing != null ? "Edit note" : "New note");

        var header = new Adw.HeaderBar();
        var save_btn = new Gtk.Button.with_label("Save");
        save_btn.add_css_class("suggested-action");
        header.pack_end(save_btn);

        if (existing != null) {
            var delete_btn = new Gtk.Button.from_icon_name("user-trash-symbolic");
            delete_btn.set_tooltip_text("Delete note");
            delete_btn.add_css_class("destructive-action");
            delete_btn.add_css_class("flat");
            delete_btn.clicked.connect(() => {
                Paperboy.NotesStore.get_instance().delete_note(existing.id);
                dialog.close();
            });
            header.pack_start(delete_btn);
        }

        var title_entry = new Gtk.Entry();
        title_entry.set_placeholder_text("Title (optional)");
        title_entry.add_css_class("title-4");
        title_entry.set_margin_start(16);
        title_entry.set_margin_end(16);
        title_entry.set_margin_top(4);
        title_entry.set_margin_bottom(4);
        if (existing != null) title_entry.set_text(existing.title);

        // Shows what text this note is anchored to - the selection at
        // creation time for a new note, or the note's saved anchor when
        // editing. Not editable; a note isn't re-anchored after creation.
        string? anchor_quote = existing != null ? existing.quote : quote;
        Gtk.Widget? quote_label = null;
        if (anchor_quote != null && anchor_quote.strip().length > 0) {
            var lbl = new Gtk.Label("“" + anchor_quote.strip() + "”");
            lbl.add_css_class("dim-label");
            lbl.add_css_class("caption");
            lbl.set_wrap(true);
            lbl.set_lines(2);
            lbl.set_ellipsize(Pango.EllipsizeMode.END);
            lbl.set_halign(Gtk.Align.START);
            lbl.set_margin_start(16);
            lbl.set_margin_end(16);
            lbl.set_margin_bottom(4);
            quote_label = lbl;
        }

        var format_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 4);
        format_row.set_margin_start(12);
        format_row.set_margin_end(12);
        format_row.set_margin_bottom(4);

        var webview = WebViewUtils.create();
        webview.set_hexpand(true);
        webview.set_vexpand(true);

        void run_js(string js) {
            webview.evaluate_javascript.begin(js, -1, null, null, null, (obj, res) => {
                try { webview.evaluate_javascript.end(res); } catch (GLib.Error e) { }
            });
        }

        // set_can_focus(false) keeps the toolbar buttons from stealing
        // keyboard focus away from the WebView, so the current text
        // selection survives the click and execCommand applies to it.
        Gtk.Button make_format_button(string icon_name, string tooltip, string js) {
            var btn = new Gtk.Button.from_icon_name(icon_name);
            btn.set_tooltip_text(tooltip);
            btn.add_css_class("flat");
            btn.set_can_focus(false);
            btn.clicked.connect(() => { run_js(js); });
            return btn;
        }

        Gtk.Button make_command_button(string icon_name, string tooltip, string command) {
            return make_format_button(icon_name, tooltip, "document.execCommand('%s')".printf(command));
        }

        // hiliteColor doesn't toggle off like bold/italic/etc. do natively -
        // compare the selection's current color (normalized through a
        // detached element, since queryCommandValue and a literal rgba()
        // string don't always serialize the same way) and clear it back to
        // transparent if this color is already applied, else apply it.
        string toggle_highlight_js(string color) {
            return """(function(){
                var probe = document.createElement('span');
                probe.style.backgroundColor = '%s';
                var target = probe.style.backgroundColor;
                var current = document.queryCommandValue('hiliteColor');
                document.execCommand('hiliteColor', false, current === target ? 'transparent' : '%s');
            })();""".printf(color, color);
        }

        Gtk.Button build_highlight_swatch(string name, string color) {
            var swatch = new Gtk.Button();
            swatch.add_css_class("note-highlight-swatch");
            swatch.set_tooltip_text(name);
            swatch.set_can_focus(false);
            // Without an explicit size request, the button stretches to
            // match the row's tallest sibling (valign defaults to FILL),
            // leaving a fixed width but a taller height - an oval instead
            // of a circle.
            swatch.set_size_request(24, 24);
            swatch.set_valign(Gtk.Align.CENTER);
            swatch.set_halign(Gtk.Align.CENTER);
            var provider = new Gtk.CssProvider();
            provider.load_from_string(".note-highlight-swatch { min-width: 24px; min-height: 24px; border-radius: 50%%; padding: 0; border: 1px solid alpha(currentColor, 0.35); background-color: %s; }".printf(color));
            swatch.get_style_context().add_provider(provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            return swatch;
        }

        format_row.append(make_command_button("format-text-bold-symbolic", "Bold", "bold"));
        format_row.append(make_command_button("format-text-italic-symbolic", "Italic", "italic"));
        format_row.append(make_command_button("format-text-underline-symbolic", "Underline", "underline"));
        format_row.append(make_command_button("format-text-strikethrough-symbolic", "Strikethrough", "strikeThrough"));

        var highlight_btn = new Gtk.MenuButton();
        highlight_btn.set_icon_name("color-select-symbolic");
        highlight_btn.set_tooltip_text("Highlight");
        highlight_btn.add_css_class("flat");
        highlight_btn.set_can_focus(false);

        var swatches_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        swatches_row.set_margin_start(8);
        swatches_row.set_margin_end(8);
        swatches_row.set_margin_top(8);
        swatches_row.set_margin_bottom(8);

        var highlight_popover = new Gtk.Popover();
        highlight_popover.set_child(swatches_row);
        highlight_btn.set_popover(highlight_popover);

        string[,] highlight_colors = {
            { "Yellow", "rgba(255, 235, 59, 0.6)" },
            { "Green", "rgba(139, 195, 74, 0.55)" },
            { "Blue", "rgba(3, 169, 244, 0.4)" },
            { "Pink", "rgba(233, 30, 99, 0.35)" },
            { "Orange", "rgba(255, 152, 0, 0.5)" }
        };
        for (int i = 0; i < highlight_colors.length[0]; i++) {
            string name = highlight_colors[i, 0];
            string color = highlight_colors[i, 1];
            var swatch = build_highlight_swatch(name, color);
            swatch.clicked.connect(() => {
                run_js(toggle_highlight_js(color));
                highlight_popover.popdown();
            });
            swatches_row.append(swatch);
        }

        var remove_highlight_btn = new Gtk.Button.from_icon_name("edit-clear-symbolic");
        remove_highlight_btn.add_css_class("flat");
        remove_highlight_btn.add_css_class("circular");
        remove_highlight_btn.set_tooltip_text("Remove highlight");
        remove_highlight_btn.set_can_focus(false);
        remove_highlight_btn.set_valign(Gtk.Align.CENTER);
        remove_highlight_btn.clicked.connect(() => {
            run_js("document.execCommand('hiliteColor', false, 'transparent')");
            highlight_popover.popdown();
        });
        swatches_row.append(remove_highlight_btn);

        format_row.append(highlight_btn);
        format_row.append(make_command_button("view-list-bullet-symbolic", "Bulleted list", "insertUnorderedList"));
        format_row.append(make_command_button("view-list-ordered-symbolic", "Numbered list", "insertOrderedList"));
        format_row.append(make_format_button("edit-clear-symbolic", "Clear formatting", "document.execCommand('removeFormat'); document.execCommand('hiliteColor', false, 'transparent')"));

        string initial_content = existing != null ? existing.content_html : "";
        webview.load_html(
            "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>" + EDITOR_CSS + "</style></head>" +
            "<body><div id=\"editor\" contenteditable=\"true\">" + initial_content + "</div></body></html>",
            null);

        var editor_frame = new Gtk.Frame(null);
        editor_frame.add_css_class("view");
        editor_frame.set_margin_start(12);
        editor_frame.set_margin_end(12);
        editor_frame.set_margin_bottom(12);
        editor_frame.set_vexpand(true);
        editor_frame.set_child(webview);

        var root = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        if (quote_label != null) root.append(quote_label);
        root.append(title_entry);
        root.append(format_row);
        root.append(editor_frame);

        var toolbar_view = new Adw.ToolbarView();
        toolbar_view.add_top_bar(header);
        toolbar_view.set_content(root);
        dialog.set_child(toolbar_view);

        save_btn.clicked.connect(() => {
            webview.evaluate_javascript.begin("document.getElementById('editor').innerHTML", -1, null, null, null, (obj, res) => {
                string html = "";
                try {
                    var value = webview.evaluate_javascript.end(res);
                    html = value.to_string() ?? "";
                } catch (GLib.Error e) { }

                string plain = stripHtmlUtils.strip_html(html).strip();
                if (plain.length == 0) {
                    dialog.close();
                    return;
                }

                string title = title_entry.get_text().strip();
                if (title.length == 0) {
                    title = plain.length > 60 ? plain.substring(0, 60) + "…" : plain;
                }

                var store = Paperboy.NotesStore.get_instance();
                if (existing != null) {
                    store.update_note(existing.id, title, html);
                } else {
                    store.add_note(article_url, title, html, quote);
                }
                dialog.close();
            });
        });

        dialog.closed.connect(() => {
            WebViewUtils.terminate_process(webview);
        });

        dialog.present(parent);
        title_entry.grab_focus();
    }
}
