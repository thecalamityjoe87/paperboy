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
using Gdk;

public class AboutDialog : GLib.Object {

    // Renders the small markdown subset used in release_notes.md ("# " headings
    // and "- " bullets) as Pango markup for a Gtk.Label.
    private static string format_release_notes(string markdown) {
        var sb = new StringBuilder();
        string[] lines = markdown.split("\n");
        bool first_line = true;
        bool prev_was_heading = false;
        foreach (unowned string raw_line in lines) {
            string line = raw_line.strip();
            if (line.length == 0) continue;
            if (!first_line) sb.append((line.has_prefix("# ") || prev_was_heading) ? "\n\n" : "\n");
            first_line = false;
            prev_was_heading = line.has_prefix("# ");
            if (line.has_prefix("# ")) {
                sb.append("<b>").append(Markup.escape_text(line.substring(2))).append("</b>");
            } else if (line.has_prefix("- ")) {
                sb.append("• ").append(Markup.escape_text(line.substring(2)));
            } else {
                sb.append(Markup.escape_text(line));
            }
        }
        return sb.str;
    }

    public static void show(Gtk.Window parent) {
        var dialog = new Adw.Window();
        dialog.set_transient_for(parent);
        dialog.set_modal(true);
        dialog.set_title("About Paperboy");
        dialog.set_default_size(500, 650);

        var nav = new Adw.NavigationView();

        // Pre-create both pages so signals can reference them
        var notes_scroll_temp = new Gtk.ScrolledWindow();
        var notes_clamp_temp = new Adw.Clamp();
        notes_clamp_temp.set_maximum_size(420);
        var notes_box_temp = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        notes_box_temp.set_margin_start(12);
        notes_box_temp.set_margin_end(12);
        notes_box_temp.set_margin_top(12);
        notes_box_temp.set_margin_bottom(12);

        var notes_label_temp = new Gtk.Label("");
        string? notes_path_temp = DataPathsUtils.find_data_file("release_notes.md");
        if (notes_path_temp != null) {
            string release_notes_text = "";
            try {
                FileUtils.get_contents(notes_path_temp, out release_notes_text);
                notes_label_temp.set_markup(format_release_notes(release_notes_text));
            } catch (Error e) {
                warning("Failed to load release notes: %s", e.message);
                notes_label_temp.set_text("Release notes not available");
            }
        } else {
            notes_label_temp.set_text("Release notes not available");
        }
        notes_label_temp.set_wrap(true);
        notes_label_temp.set_natural_wrap_mode(Gtk.NaturalWrapMode.WORD);
        notes_label_temp.set_selectable(true);
        notes_label_temp.set_can_focus(false);
        notes_box_temp.append(notes_label_temp);
        notes_clamp_temp.set_child(notes_box_temp);
        notes_scroll_temp.set_child(notes_clamp_temp);

        var notes_toolbar_temp = new Adw.ToolbarView();
        var notes_header_temp = new Adw.HeaderBar();
        notes_toolbar_temp.add_top_bar(notes_header_temp);
        notes_toolbar_temp.set_content(notes_scroll_temp);
        var notes_page_temp = new Adw.NavigationPage.with_tag(notes_toolbar_temp, "Release notes", "notes");

        var scroll = new Gtk.ScrolledWindow();
        scroll.set_vexpand(true);

        var clamp = new Adw.Clamp();
        clamp.set_maximum_size(420);

        var page = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        page.set_margin_top(18);
        page.set_margin_bottom(12);

        string? banner_path = DataPathsUtils.find_data_file("images/paperboy-banner.png");
        if (banner_path != null) {
            try {
                var banner = new Gtk.Picture.for_filename(banner_path);
                banner.set_keep_aspect_ratio(true);
                banner.set_size_request(300, 80);
                banner.set_halign(Gtk.Align.CENTER);
                banner.set_margin_bottom(10);
                page.append(banner);
            } catch (Error e) {
                warning("Failed to load banner: %s", e.message);
            }
        }

        var version = new Gtk.Label("0.11.2a");
        version.add_css_class("monospace");
        version.add_css_class("dim-label");
        version.set_halign(Gtk.Align.CENTER);
        version.set_margin_top(8);
        page.append(version);

        var desc = new Gtk.Label("A simple news app written in Vala, built with GTK4 and Libadwaita.");
        desc.set_wrap(true);
        desc.set_justify(Gtk.Justification.CENTER);
        desc.add_css_class("dim-label");
        desc.set_margin_top(12);
        page.append(desc);

        var info = new Gtk.ListBox();
        info.add_css_class("boxed-list");
        info.set_selection_mode(Gtk.SelectionMode.NONE);
        info.set_margin_top(20);

        var notes_row = new Adw.ActionRow();
        notes_row.set_title("Release notes");
        notes_row.set_activatable(true);
        var notes_arrow = new Gtk.Image.from_icon_name("go-next-symbolic");
        notes_row.add_suffix(notes_arrow);
        notes_row.activated.connect(() => nav.push_by_tag("notes"));
        info.append(notes_row);

        page.append(info);

        var links_title = new Gtk.Label("Links");
        links_title.add_css_class("heading");
        links_title.set_halign(Gtk.Align.START);
        links_title.set_margin_top(20);
        links_title.set_margin_bottom(6);
        page.append(links_title);

        var links = new Gtk.ListBox();
        links.add_css_class("boxed-list");
        links.set_selection_mode(Gtk.SelectionMode.NONE);

        void add_link(string title, string url) {
            var row = new Adw.ActionRow();
            row.set_title(title);
            row.set_activatable(true);
            row.set_tooltip_text(url);
            var arrow = new Gtk.Image.from_icon_name("adw-external-link-symbolic");
            row.add_suffix(arrow);
            var u = url;
            row.activated.connect(() => {
                try {
                    Gtk.show_uri(parent, u, Gdk.CURRENT_TIME);
                } catch (Error e) {
                    warning("Failed to open URL: %s", e.message);
                }
            });
            links.append(row);
        }

        add_link("GitHub Repository", "https://github.com/thecalamityjoe87/paperboy");
        add_link("Releases", "https://github.com/thecalamityjoe87/paperboy/releases");
        add_link("Report an issue", "https://github.com/thecalamityjoe87/paperboy/issues");

        page.append(links);

        var footer = new Gtk.Label("© 2025 thecalamityjoe87 (Isaac Joseph)");
        footer.add_css_class("dim-label");
        footer.add_css_class("caption");
        footer.set_wrap(true);
        footer.set_justify(Gtk.Justification.CENTER);
        footer.set_margin_top(20);
        page.append(footer);

        clamp.set_child(page);
        scroll.set_child(clamp);

        var toolbar = new Adw.ToolbarView();
        var header = new Adw.HeaderBar();
        header.add_css_class("flat");
        toolbar.add_top_bar(header);
        toolbar.set_content(scroll);

        nav.add(new Adw.NavigationPage.with_tag(toolbar, "About Paperboy", "main"));
        nav.add(notes_page_temp);

        dialog.set_content(nav);
        dialog.present();
    }
}
