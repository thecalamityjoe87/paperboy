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

// Bound directly to the C symbol since GTK4 minor versions ship
// Gtk.DragIcon.get_for_drag's vapi binding in incompatible shapes.
[CCode (cname = "gtk_drag_icon_get_for_drag")]
private static extern unowned Gtk.Widget prefs_rows_drag_icon_get_for_drag(Gdk.Drag drag);

// State shared by the Preferences pages: the dialog and window they act
// on, and whether sources changed - read by the dialog's close handler to
// decide whether to offer a refresh.
public class PrefsContext : GLib.Object {
    public Adw.PreferencesDialog dialog;
    public NewsWindow win;
    public NewsPreferences prefs;
    public bool sources_changed = false;

    public PrefsContext(Adw.PreferencesDialog dialog, NewsWindow win) {
        this.dialog = dialog;
        this.win = win;
        this.prefs = NewsPreferences.get_instance();
    }
}

// Row-building helpers shared by the Preferences pages (and onboarding).
public class PrefsRows : GLib.Object {

    // One size for every row's leading icon (category glyphs, source
    // favicons, league/team logos) so they line up. Matches the sidebar's
    // category icons; both renderers draw at higher resolution, so they
    // stay sharp at this size.
    public const int ROW_ICON_SIZE = CategoryIconsUtils.SIDEBAR_ICON_SIZE;

    public delegate Adw.NavigationPage SubpageBuilderFunc();
    public delegate Gdk.ContentProvider DragContentFunc();
    public delegate void FileChosenFunc(string path) throws GLib.Error;
    public delegate void ClickedFunc();

    // The Country row (Preferences and onboarding): "Automatic (<country>)"
    // first, then every Google News edition by name, searchable. Saves the
    // choice to prefs.news_edition and then calls `on_changed`, if given.
    public static Adw.ComboRow country_row(NewsPreferences prefs, owned ClickedFunc? on_changed = null) {
        // ceids[i] is row i's edition id; "" means automatic
        string[] ceids = { "" };
        var names = new Gtk.StringList(null);
        names.append("Automatic (%s)".printf(GoogleNewsUtils.automatic_edition().name));
        var editions = new Gee.ArrayList<GoogleNewsEdition?>();
        foreach (var e in GoogleNewsUtils.EDITIONS) editions.add(e);
        editions.sort((a, b) => a.name.collate(b.name));
        uint selected = 0;
        foreach (var e in editions) {
            if (e.ceid == prefs.news_edition) selected = ceids.length;
            ceids += e.ceid;
            names.append(e.name);
        }

        var row = new Adw.ComboRow();
        row.set_title("Country");
        // Show the choice as the subtitle - full width, so long names like
        // "Automatic (United Kingdom)" aren't truncated beside the arrow
        row.set_use_subtitle(true);
        row.set_model(names);
        row.set_expression(new Gtk.PropertyExpression(typeof(Gtk.StringObject), null, "string"));
        row.set_enable_search(true);
        row.set_selected(selected);
        row.notify["selected"].connect(() => {
            uint i = row.get_selected();
            if (i >= ceids.length || ceids[i] == prefs.news_edition) return;
            prefs.news_edition = ceids[i];
            if (on_changed != null) on_changed();
        });
        return row;
    }

    // Wraps preferences content for push_subpage(). Adw.HeaderBar shows its
    // own contextual back chevron inside pushed-subpage content, so no
    // manual back button is added (it would double up).
    public static Adw.NavigationPage build_subpage(Adw.PreferencesPage content, string title) {
        var toolbar_view = new Adw.ToolbarView();
        toolbar_view.add_top_bar(new Adw.HeaderBar());
        toolbar_view.set_content(content);
        return new Adw.NavigationPage(toolbar_view, title);
    }

    // Makes `row` a drill-down row: a trailing chevron, and activating it
    // pushes the page from build_page. Ignored while that page is still
    // open, so a double-click doesn't push it twice.
    public static void make_nav_row(Adw.PreferencesDialog dialog, Adw.ActionRow row, owned SubpageBuilderFunc build_page) {
        row.add_suffix(new Gtk.Image.from_icon_name("go-next-symbolic"));
        row.set_activatable(true);
        Adw.NavigationPage? shown = null;
        row.activated.connect(() => {
            if (shown != null && shown.get_parent() != null) return;
            shown = build_page();
            dialog.push_subpage(shown);
        });
    }

    // Adds a trailing switch to `row` and makes clicking anywhere on the
    // row toggle it. For rows that also carry buttons, where Adw.SwitchRow
    // can't be used.
    public static Gtk.Switch add_switch_suffix(Adw.ActionRow row, bool active) {
        var sw = new Gtk.Switch();
        sw.set_active(active);
        sw.set_valign(Gtk.Align.CENTER);
        row.add_suffix(sw);
        row.set_activatable(true);
        row.activated.connect(() => { sw.set_active(!sw.get_active()); });
        return sw;
    }

    // Frameless icon button for a row's suffix (edit, delete, settings).
    public static Gtk.Button flat_icon_button(string icon_name, string tooltip, bool destructive = false) {
        var btn = new Gtk.Button.from_icon_name(icon_name);
        btn.set_valign(Gtk.Align.CENTER);
        btn.set_has_frame(false);
        btn.set_tooltip_text(tooltip);
        if (destructive) btn.add_css_class("destructive-action");
        return btn;
    }

    // Circular favicon placeholder that fills in once favicon_url loads.
    public static Gtk.Image favicon_image(string? favicon_url) {
        var image = PixbufUtils.make_circular_logo_placeholder(ROW_ICON_SIZE);
        if (favicon_url != null && favicon_url.length > 0) {
            PixbufUtils.load_circular_logo_async(image, favicon_url, ROW_ICON_SIZE);
        }
        return image;
    }

    // Followed-feed icon: its saved local logo if there is one,
    // otherwise SourceMetadata.pick_logo_url()'s network fallback.
    public static Gtk.Image rss_source_icon(Paperboy.RssSource rss_source) {
        string? icon_filename = SourceMetadata.get_saved_filename_for_source(rss_source.name);
        string? logos_dir = SourceMetadata.get_user_logos_dir();
        if (icon_filename != null && icon_filename.length > 0 && logos_dir != null) {
            var icon_path = GLib.Path.build_filename(logos_dir, icon_filename);
            if (GLib.FileUtils.test(icon_path, GLib.FileTest.EXISTS)) {
                var image = PixbufUtils.make_circular_logo_placeholder(ROW_ICON_SIZE);
                PixbufUtils.load_circular_logo_from_file(image, icon_path, ROW_ICON_SIZE);
                return image;
            }
        }

        return favicon_image(SourceMetadata.pick_logo_url(
            SourceMetadata.get_logo_url_for_source(rss_source.name), rss_source.url, rss_source.favicon_url));
    }

    public static string elide(string s, int max) {
        if (max < 1 || s.length <= max) return s;
        return s.substring(0, max - 1) + "…";
    }

    // Prepends a drag handle to `row` and makes it the drag source for
    // reordering. The drag is scoped to the handle (not the whole row) so
    // the row's switch and buttons stay clickable. Call after adding the
    // row's other prefixes: add_prefix prepends, so the handle ends up
    // leftmost. The drop side is the caller's, since it differs per list.
    public static void add_drag_handle(Adw.ActionRow row, string drag_label, owned DragContentFunc content) {
        var drag_handle = new Gtk.Image.from_icon_name("list-drag-handle-symbolic");
        drag_handle.add_css_class("dim-label");
        drag_handle.set_tooltip_text(_("Drag to reorder"));
        row.add_prefix(drag_handle);

        var drag_source = new Gtk.DragSource();
        drag_source.set_actions(Gdk.DragAction.MOVE);
        drag_source.prepare.connect((source, x, y) => {
            return content();
        });
        drag_source.drag_begin.connect((source, drag) => {
            var drag_icon = (Gtk.DragIcon) prefs_rows_drag_icon_get_for_drag(drag);
            var icon_label = new Gtk.Label(drag_label);
            icon_label.add_css_class("card");
            icon_label.set_margin_top(6);
            icon_label.set_margin_bottom(6);
            icon_label.set_margin_start(12);
            icon_label.set_margin_end(12);
            drag_icon.set_child(icon_label);
        });
        drag_handle.add_controller(drag_source);
    }

    // Row with "Export" and "Import" buttons, for the Backup & Restore group.
    public static Adw.ActionRow backup_row(string title, string subtitle, owned ClickedFunc on_export, owned ClickedFunc on_import) {
        var row = new Adw.ActionRow();
        row.set_title(title);
        row.set_subtitle(subtitle);

        var export_btn = new Gtk.Button.with_label(_("Export"));
        export_btn.set_valign(Gtk.Align.CENTER);
        export_btn.clicked.connect(() => on_export());

        var import_btn = new Gtk.Button.with_label(_("Import"));
        import_btn.set_valign(Gtk.Align.CENTER);
        import_btn.clicked.connect(() => on_import());

        var btn_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        btn_box.append(export_btn);
        btn_box.append(import_btn);
        row.add_suffix(btn_box);
        return row;
    }

    public static Gtk.FileFilter file_filter(string name, string suffix, string? extra_pattern = null) {
        var filter = new Gtk.FileFilter();
        filter.set_filter_name(name);
        filter.add_suffix(suffix);
        if (extra_pattern != null) filter.add_pattern(extra_pattern);
        return filter;
    }

    // Runs a save dialog and hands the chosen path to on_chosen. Dismissing
    // the dialog is silent; other failures (including on_chosen's) are
    // logged as "Failed to <what>".
    public static void choose_save_path(Gtk.Window parent, string title, string initial_name, Gtk.FileFilter filter,
                                        string what, owned FileChosenFunc on_chosen) {
        var file_dialog = new Gtk.FileDialog();
        file_dialog.set_title(title);
        file_dialog.set_initial_name(initial_name);
        file_dialog.set_default_filter(filter);
        file_dialog.save.begin(parent, null, (obj, res) => {
            try {
                var file = file_dialog.save.end(res);
                if (file == null || file.get_path() == null) return;
                on_chosen(file.get_path());
            } catch (GLib.Error e) {
                if (!(e is Gtk.DialogError.DISMISSED)) warning("Failed to %s: %s", what, e.message);
            }
        });
    }

    // Open-dialog counterpart of choose_save_path().
    public static void choose_open_path(Gtk.Window parent, string title, Gtk.FileFilter filter,
                                        string what, owned FileChosenFunc on_chosen) {
        var file_dialog = new Gtk.FileDialog();
        file_dialog.set_title(title);
        file_dialog.set_default_filter(filter);
        file_dialog.open.begin(parent, null, (obj, res) => {
            try {
                var file = file_dialog.open.end(res);
                if (file == null || file.get_path() == null) return;
                on_chosen(file.get_path());
            } catch (GLib.Error e) {
                if (!(e is Gtk.DialogError.DISMISSED)) warning("Failed to %s: %s", what, e.message);
            }
        });
    }
}
