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

// Lets the user assign every magazine's category from one screen:
// Uncategorized is a fixed column on the left, real categories stack as
// rows to its right. Drops persist immediately via
// MagazineLibraryStore.update_category, which re-renders the Magazines
// page on its own; only the grid/row toggle and row reordering need an
// explicit Managers.MagazineLibraryManager.request_render() call.
public class MagazineOrganizeDialog : GLib.Object {
    // Blank/null category - kept in sync with MagazineLibraryManager's own
    // UNCATEGORIZED sentinel by value, not a shared constant.
    private const string UNCATEGORIZED = "Uncategorized";

    // Wide enough that a typical magazine title shows in full next to its
    // (now much bigger) thumbnail instead of ellipsizing.
    private const int UNCATEGORIZED_COLUMN_WIDTH = 320;

    // Chip thumbnail size - large enough to actually read as a cover,
    // not a tiny square icon.
    private const int CHIP_THUMB_WIDTH = 90;
    private const int CHIP_THUMB_HEIGHT = 122;

    private delegate void VoidFunc();

    public static void show(NewsWindow window, Managers.MagazineLibraryManager manager) {
        var dialog = new Adw.Dialog();
        // Wider/taller than the dialog's original 820x560 to give the
        // bigger thumbnails/column below room to breathe.
        dialog.set_content_width(1100);
        dialog.set_content_height(760);
        dialog.set_title("Organize Rack");

        var header = new Adw.HeaderBar();

        var uncategorized_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        uncategorized_box.set_margin_start(16);
        uncategorized_box.set_vexpand(true);
        // Explicit, not left unset - a chip title label inside sets
        // hexpand true, which would otherwise propagate up and stretch
        // this column past its fixed width.
        uncategorized_box.set_hexpand(false);

        // Rows stack vertically rather than scrolling sideways, so a
        // category you're dragging toward can't end up off-screen mid-drag
        // (GTK doesn't auto-scroll for you).
        var rows_list = new Gtk.ListBox();
        rows_list.set_selection_mode(Gtk.SelectionMode.NONE);
        rows_list.add_css_class("boxed-list");
        rows_list.set_vexpand(true);

        var rows_scroller = new Gtk.ScrolledWindow();
        rows_scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        rows_scroller.set_hexpand(true);
        rows_scroller.set_vexpand(true);
        rows_scroller.set_child(rows_list);

        var main_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 16);
        main_row.set_margin_top(12);
        main_row.set_margin_end(16);
        main_row.set_margin_bottom(16);
        main_row.set_hexpand(true);
        main_row.set_vexpand(true);
        main_row.append(uncategorized_box);
        main_row.append(rows_scroller);

        // Also controls how the Magazines page itself renders uncategorized
        // magazines - see Prefs.magazine_uncategorized_as_grid.
        var bottom_bar = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
        bottom_bar.set_margin_start(16);
        bottom_bar.set_margin_end(16);
        bottom_bar.set_margin_top(10);
        bottom_bar.set_margin_bottom(10);

        // Undoes all organizing - category order, grid/row choice, and
        // every magazine's category. Click handler wired below, after
        // refresh() exists.
        var reset_button = new Gtk.Button.with_label("Reset View");
        reset_button.set_valign(Gtk.Align.CENTER);
        reset_button.add_css_class("destructive-action");
        bottom_bar.append(reset_button);

        // Grouped and pushed right as a unit, rather than the label
        // hugging the left edge with the switch stranded on the far right.
        var grid_toggle_group = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
        grid_toggle_group.set_halign(Gtk.Align.END);
        grid_toggle_group.set_hexpand(true);

        var grid_toggle_label = new Gtk.Label("Show uncategorized magazines as a grid");
        var grid_toggle_switch = new Gtk.Switch();
        grid_toggle_switch.set_valign(Gtk.Align.CENTER);
        grid_toggle_switch.set_active(window.prefs.magazine_uncategorized_as_grid);
        grid_toggle_switch.notify["active"].connect(() => {
            window.prefs.magazine_uncategorized_as_grid = grid_toggle_switch.get_active();
            manager.request_render();
        });
        grid_toggle_group.append(grid_toggle_label);
        grid_toggle_group.append(grid_toggle_switch);
        bottom_bar.append(grid_toggle_group);

        var toolbar_view = new Adw.ToolbarView();
        toolbar_view.add_top_bar(header);
        toolbar_view.set_content(main_row);
        toolbar_view.add_bottom_bar(bottom_bar);
        dialog.set_child(toolbar_view);

        // Categories typed into "New category" before any magazine has
        // been dropped into them - client-side only, since a category
        // isn't real until a magazine actually has it.
        var pending_categories = new Gee.ArrayList<string>();

        // Persists rows_list's current order back to prefs, reading each
        // row's category off its stashed name - skips the "New category"
        // row (it never gets a name) wherever it happens to be.
        VoidFunc persist_row_order = () => {
            var new_order = new Gee.ArrayList<string>();
            var row = rows_list.get_row_at_index(0);
            int i = 0;
            while (row != null) {
                if (row.get_name() != null) new_order.add(row.get_name());
                i++;
                row = rows_list.get_row_at_index(i);
            }
            window.prefs.magazine_category_order = new_order;
            manager.request_render();
        };

        VoidFunc refresh = null;
        refresh = () => {
            Gtk.Widget? existing_bucket = uncategorized_box.get_first_child();
            if (existing_bucket != null) uncategorized_box.remove(existing_bucket);
            Gtk.Widget? existing_row = rows_list.get_row_at_index(0);
            while (existing_row != null) {
                rows_list.remove(existing_row);
                existing_row = rows_list.get_row_at_index(0);
            }

            var current_entries = Paperboy.MagazineLibraryStore.get_instance().get_all_entries();
            var by_category = new Gee.HashMap<string, Gee.ArrayList<Paperboy.MagazineEntry>>();
            by_category.set(UNCATEGORIZED, new Gee.ArrayList<Paperboy.MagazineEntry>());
            foreach (var entry in current_entries) {
                string category = (entry.category != null && entry.category.strip().length > 0) ? entry.category.strip() : UNCATEGORIZED;
                if (!by_category.has_key(category)) by_category.set(category, new Gee.ArrayList<Paperboy.MagazineEntry>());
                by_category.get(category).add(entry);
            }

            var real_category_names = new Gee.ArrayList<string>();
            foreach (var name in by_category.keys) {
                if (name != UNCATEGORIZED) real_category_names.add(name);
            }
            foreach (var pending in pending_categories) {
                if (!real_category_names.contains(pending)) real_category_names.add(pending);
            }
            var category_names = window.prefs.ordered_magazine_categories(real_category_names);

            var uncategorized_entries = by_category.get(UNCATEGORIZED);
            uncategorized_entries.sort((a, b) => { return SortUtils.compare_titles(a.title, b.title); });
            uncategorized_box.append(build_bucket(UNCATEGORIZED, uncategorized_entries, refresh));

            // "New category" and the hint row stay pinned first.
            rows_list.append(build_add_row(pending_categories, category_names, refresh));
            rows_list.append(build_hint_row());

            foreach (var category_name in category_names) {
                var row_entries = by_category.has_key(category_name) ? by_category.get(category_name) : new Gee.ArrayList<Paperboy.MagazineEntry>();
                row_entries.sort((a, b) => { return SortUtils.compare_titles(a.title, b.title); });
                rows_list.append(build_category_row(window, category_name, row_entries, rows_list, pending_categories, refresh, persist_row_order));
            }
        };

        reset_button.clicked.connect(() => {
            var confirm_dialog = new Adw.AlertDialog(
                "Reset view?",
                "Moves every magazine back to Uncategorized, clears your custom category order, and switches back to the grid view. This can't be undone, though no magazines themselves are removed from your library."
            );
            confirm_dialog.add_response("cancel", "Cancel");
            confirm_dialog.add_response("reset", "Reset View");
            confirm_dialog.set_response_appearance("reset", Adw.ResponseAppearance.DESTRUCTIVE);
            confirm_dialog.set_default_response("cancel");
            confirm_dialog.set_close_response("cancel");

            confirm_dialog.response.connect((response_id) => {
                if (response_id == "reset") {
                    var store = Paperboy.MagazineLibraryStore.get_instance();
                    foreach (var entry in store.get_all_entries()) {
                        if (entry.category != null) store.update_category(entry.id, null);
                    }
                    window.prefs.magazine_category_order = new Gee.ArrayList<string>();
                    window.prefs.magazine_uncategorized_as_grid = true;
                    grid_toggle_switch.set_active(true);
                    manager.request_render();
                    refresh();
                }
            });

            confirm_dialog.present(dialog);
        });

        refresh();

        dialog.present((Gtk.Window) window);
    }

    // The fixed Uncategorized column - a droppable list of chips, never
    // reordered or renamed.
    private static Gtk.Widget build_bucket(string category_name, Gee.ArrayList<Paperboy.MagazineEntry> bucket_entries, owned VoidFunc on_changed) {
        var bucket = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
        bucket.add_css_class("magazine-organize-bucket");
        bucket.set_size_request(UNCATEGORIZED_COLUMN_WIDTH, -1);
        bucket.set_hexpand(false);

        var header = new Gtk.Label(category_name);
        header.add_css_class("heading");
        header.set_xalign(0);
        header.set_ellipsize(Pango.EllipsizeMode.END);
        bucket.append(header);

        var count_label = new Gtk.Label(bucket_entries.size.to_string() + (bucket_entries.size == 1 ? " magazine" : " magazines"));
        count_label.add_css_class("dim-label");
        count_label.add_css_class("caption");
        count_label.set_xalign(0);
        bucket.append(count_label);

        var chips_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);
        chips_box.set_vexpand(true);
        chips_box.set_hexpand(false);
        foreach (var entry in bucket_entries) {
            chips_box.append(build_chip(entry));
        }

        var chips_scroller = new Gtk.ScrolledWindow();
        chips_scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        chips_scroller.set_min_content_height(360);
        chips_scroller.set_vexpand(true);
        chips_scroller.set_hexpand(false);
        chips_scroller.set_child(chips_box);
        bucket.append(chips_scroller);

        string target_category = category_name;
        var drop_target = new Gtk.DropTarget(typeof(string), Gdk.DragAction.MOVE);
        drop_target.enter.connect((x, y) => {
            bucket.add_css_class("magazine-drop-target");
            return Gdk.DragAction.MOVE;
        });
        drop_target.leave.connect(() => { bucket.remove_css_class("magazine-drop-target"); });
        drop_target.drop.connect((value, x, y) => {
            bucket.remove_css_class("magazine-drop-target");
            string? dragged_id_str = value.get_string();
            if (dragged_id_str == null) return false;
            int64 dragged_id = int64.parse(dragged_id_str);
            string? new_category = (target_category == UNCATEGORIZED) ? null : target_category;
            Paperboy.MagazineLibraryStore.get_instance().update_category(dragged_id, new_category);
            on_changed();
            return true;
        });
        bucket.add_controller(drop_target);

        return bucket;
    }

    // One draggable/reorderable category row - also a drop target for
    // magazine chips. Row reordering follows PrefsDialog's sports-league
    // pattern: a DragSource scoped to the handle icon (so chips stay
    // draggable) carrying the ListBoxRow itself, dropped via a DropTarget
    // on the row.
    private static Gtk.ListBoxRow build_category_row(NewsWindow window, string category_name, Gee.ArrayList<Paperboy.MagazineEntry> row_entries, Gtk.ListBox rows_list, Gee.ArrayList<string> pending_categories, owned VoidFunc on_changed, owned VoidFunc persist_row_order) {
        var list_row = new Gtk.ListBoxRow();
        list_row.set_name(category_name);

        var content = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
        content.set_margin_top(10);
        content.set_margin_bottom(10);
        content.set_margin_start(10);
        content.set_margin_end(10);

        var header_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);

        var drag_handle = new Gtk.Image.from_icon_name("list-drag-handle-symbolic");
        drag_handle.add_css_class("dim-label");
        drag_handle.set_tooltip_text("Drag to reorder");
        drag_handle.set_pixel_size(22);
        // Taller than the icon needs - a bigger hit target, not just a
        // bigger glyph.
        drag_handle.set_size_request(-1, 36);
        drag_handle.set_valign(Gtk.Align.CENTER);
        header_row.append(drag_handle);

        var title_label = new Gtk.Label(category_name);
        title_label.add_css_class("heading");
        title_label.set_xalign(0);
        title_label.set_hexpand(true);
        title_label.set_ellipsize(Pango.EllipsizeMode.END);
        header_row.append(title_label);

        var count_label = new Gtk.Label(row_entries.size.to_string() + (row_entries.size == 1 ? " magazine" : " magazines"));
        count_label.add_css_class("dim-label");
        count_label.add_css_class("caption");
        header_row.append(count_label);

        var rename_button = new Gtk.Button.from_icon_name("document-edit-symbolic");
        rename_button.add_css_class("flat");
        rename_button.set_tooltip_text("Rename category");
        rename_button.set_valign(Gtk.Align.CENTER);
        header_row.append(rename_button);

        var delete_button = new Gtk.Button.from_icon_name("user-trash-symbolic");
        delete_button.add_css_class("flat");
        delete_button.set_tooltip_text("Delete category");
        delete_button.set_valign(Gtk.Align.CENTER);
        header_row.append(delete_button);

        content.append(header_row);

        // Both close over the name as built, not list_row.get_name() -
        // renaming doesn't touch that (on_changed() rebuilds the row).
        string current_category_name = category_name;
        rename_button.clicked.connect(() => {
            var rename_dialog = new Adw.MessageDialog((Gtk.Window) window, "Rename Category",
                "Choose a new name for \"%s\".".printf(current_category_name));

            var name_entry = new Gtk.Entry();
            name_entry.set_text(current_category_name);
            name_entry.set_margin_top(12);
            name_entry.set_margin_bottom(12);
            rename_dialog.set_extra_child(name_entry);

            rename_dialog.add_response("cancel", "Cancel");
            rename_dialog.add_response("rename", "Rename");
            rename_dialog.set_response_appearance("rename", Adw.ResponseAppearance.SUGGESTED);
            rename_dialog.set_default_response("rename");
            rename_dialog.set_close_response("cancel");

            rename_dialog.response.connect((response_id) => {
                if (response_id == "rename") {
                    string new_name = name_entry.get_text().strip();
                    if (new_name.length > 0 && new_name != current_category_name) {
                        var store = Paperboy.MagazineLibraryStore.get_instance();
                        foreach (var entry in store.get_all_entries()) {
                            if (entry.category != null && entry.category.strip() == current_category_name) {
                                store.update_category(entry.id, new_name);
                            }
                        }
                        // Covers a category typed but never dropped into
                        // yet - it only exists in this list, not on any entry.
                        for (int i = 0; i < pending_categories.size; i++) {
                            if (pending_categories.get(i) == current_category_name) pending_categories.set(i, new_name);
                        }
                        on_changed();
                    }
                }
                rename_dialog.close();
            });

            rename_dialog.present();
        });

        delete_button.clicked.connect(() => {
            var confirm_dialog = new Adw.AlertDialog(
                "Delete \"%s\"?".printf(current_category_name),
                "Moves its magazines back to Uncategorized. This can't be undone, though no magazines themselves are removed from your library."
            );
            confirm_dialog.add_response("cancel", "Cancel");
            confirm_dialog.add_response("delete", "Delete");
            confirm_dialog.set_response_appearance("delete", Adw.ResponseAppearance.DESTRUCTIVE);
            confirm_dialog.set_default_response("cancel");
            confirm_dialog.set_close_response("cancel");

            confirm_dialog.response.connect((response_id) => {
                if (response_id == "delete") {
                    var store = Paperboy.MagazineLibraryStore.get_instance();
                    foreach (var entry in store.get_all_entries()) {
                        if (entry.category != null && entry.category.strip() == current_category_name) {
                            store.update_category(entry.id, null);
                        }
                    }
                    pending_categories.remove(current_category_name);
                    on_changed();
                }
            });

            confirm_dialog.present((Gtk.Window) window);
        });

        // Fills the row's width so several chips pack left-to-right before
        // wrapping (halign START would starve it to one narrow column
        // instead). Not homogeneous and each chip left-aligned, so a line
        // with only a couple magazines doesn't stretch them to fill it.
        var chips_flow = new Gtk.FlowBox();
        // Overrides GtkFlowBoxChild's own theme padding/margin - the only
        // way to reach that node.
        chips_flow.add_css_class("magazine-organize-chips-flow");
        chips_flow.set_selection_mode(Gtk.SelectionMode.NONE);
        chips_flow.set_homogeneous(false);
        chips_flow.set_row_spacing(1);
        chips_flow.set_column_spacing(1);
        chips_flow.set_halign(Gtk.Align.FILL);
        chips_flow.set_hexpand(true);
        chips_flow.set_max_children_per_line(16);
        foreach (var entry in row_entries) {
            var chip = build_chip(entry, false);
            chip.set_halign(Gtk.Align.START);
            chip.set_hexpand(false);
            chips_flow.append(chip);
        }
        content.append(chips_flow);

        list_row.set_child(content);

        string target_category = category_name;
        var chip_drop_target = new Gtk.DropTarget(typeof(string), Gdk.DragAction.MOVE);
        chip_drop_target.enter.connect((x, y) => {
            list_row.add_css_class("magazine-drop-target");
            return Gdk.DragAction.MOVE;
        });
        chip_drop_target.leave.connect(() => { list_row.remove_css_class("magazine-drop-target"); });
        chip_drop_target.drop.connect((value, x, y) => {
            list_row.remove_css_class("magazine-drop-target");
            string? dragged_id_str = value.get_string();
            if (dragged_id_str == null) return false;
            int64 dragged_id = int64.parse(dragged_id_str);
            Paperboy.MagazineLibraryStore.get_instance().update_category(dragged_id, target_category);
            on_changed();
            return true;
        });
        list_row.add_controller(chip_drop_target);

        var row_drag_source = new Gtk.DragSource();
        row_drag_source.set_actions(Gdk.DragAction.MOVE);
        row_drag_source.prepare.connect((source, x, y) => {
            var val = GLib.Value(typeof(Gtk.ListBoxRow));
            val.set_object(list_row);
            return new Gdk.ContentProvider.for_value(val);
        });
        drag_handle.add_controller(row_drag_source);

        var row_drop_target = new Gtk.DropTarget(typeof(Gtk.ListBoxRow), Gdk.DragAction.MOVE);
        row_drop_target.drop.connect((value, x, y) => {
            Gtk.ListBoxRow? src_row = (Gtk.ListBoxRow) value.get_object();
            if (src_row == null || src_row == list_row) return false;
            int target_index = list_row.get_index();
            rows_list.remove(src_row);
            rows_list.insert(src_row, target_index);
            persist_row_order();
            return true;
        });
        list_row.add_controller(row_drop_target);

        return list_row;
    }

    // Leading row - types a name to spin up an empty category row to drag
    // magazines into. Never gets a name, so it's excluded from reordering.
    private static Gtk.ListBoxRow build_add_row(Gee.ArrayList<string> pending_categories, Gee.ArrayList<string> known_categories, owned VoidFunc on_changed) {
        var list_row = new Gtk.ListBoxRow();
        list_row.set_activatable(false);
        list_row.set_selectable(false);

        var content = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
        content.set_margin_top(8);
        content.set_margin_bottom(8);
        content.set_margin_start(10);
        content.set_margin_end(10);

        var entry_field = new Gtk.Entry();
        entry_field.set_placeholder_text("New category name");
        entry_field.set_hexpand(true);
        content.append(entry_field);

        var add_button = new Gtk.Button.with_label("Add");
        add_button.add_css_class("suggested-action");
        content.append(add_button);

        list_row.set_child(content);

        VoidFunc do_add = () => {
            string name = entry_field.get_text().strip();
            if (name.length == 0) return;
            foreach (var existing in known_categories) {
                if (existing.down() == name.down()) return;
            }
            pending_categories.add(name);
            on_changed();
        };
        add_button.clicked.connect(() => { do_add(); });
        entry_field.activate.connect(() => { do_add(); });

        return list_row;
    }

    // Pinned right under the "New category" row - never gets a name (see
    // persist_row_order()), so it's excluded from reordering the same way.
    private static Gtk.ListBoxRow build_hint_row() {
        var list_row = new Gtk.ListBoxRow();
        list_row.set_activatable(false);
        list_row.set_selectable(false);

        var hint_label = new Gtk.Label("Type a name above and tap Add to create a category row first, then drag magazines into it. Drag a row's handle to reorder categories.");
        hint_label.add_css_class("dim-label");
        hint_label.add_css_class("caption");
        hint_label.set_halign(Gtk.Align.START);
        hint_label.set_xalign(0);
        hint_label.set_margin_top(2);
        hint_label.set_margin_bottom(8);
        hint_label.set_margin_start(10);
        hint_label.set_margin_end(10);

        list_row.set_child(hint_label);
        return list_row;
    }

    // A single draggable magazine - carries its entry_id as a plain
    // string, dropped onto a bucket/row. show_title is false for category
    // rows, where the row's own label already identifies it; the title is
    // always kept as a tooltip.
    private static Gtk.Widget build_chip(Paperboy.MagazineEntry entry, bool show_title = true) {
        var row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
        row.add_css_class(show_title ? "magazine-organize-chip" : "magazine-organize-chip-compact");
        row.set_tooltip_text(entry.title);

        // Gtk.Picture's natural size is always the source image's real
        // pixel dimensions regardless of size_request, so pre-scale the
        // pixbuf here instead of relying on layout to shrink it.
        Gtk.Widget thumb;
        if (entry.thumbnail_path != null) {
            Gdk.Texture? texture = null;
            try {
                var scaled = new Gdk.Pixbuf.from_file_at_scale(entry.thumbnail_path, -1, CHIP_THUMB_HEIGHT, true);
                texture = Gdk.Texture.for_pixbuf(scaled);
            } catch (GLib.Error e) { }

            if (texture != null) {
                var picture = new Gtk.Picture.for_paintable(texture);
                picture.set_content_fit(Gtk.ContentFit.COVER);
                picture.set_size_request(CHIP_THUMB_WIDTH, CHIP_THUMB_HEIGHT);
                thumb = picture;
            } else {
                var icon = new Gtk.Image.from_icon_name("x-office-document-symbolic");
                icon.set_pixel_size(22);
                thumb = icon;
            }
        } else {
            var icon = new Gtk.Image.from_icon_name("x-office-document-symbolic");
            icon.set_pixel_size(22);
            thumb = icon;
        }
        thumb.add_css_class("magazine-organize-chip-thumb");
        // Explicit CENTER/no-expand keeps the thumbnail fixed-size in
        // either layout, rather than FILL letting it grow.
        thumb.set_hexpand(false);
        thumb.set_vexpand(false);
        thumb.set_halign(Gtk.Align.CENTER);
        thumb.set_valign(Gtk.Align.START);
        row.append(thumb);

        if (show_title) {
            // Wrapped, not ellipsized - the column's wide enough that the
            // full title on 2-3 lines reads better than "...".
            var title_label = new Gtk.Label(entry.title);
            title_label.set_xalign(0);
            title_label.set_valign(Gtk.Align.START);
            title_label.set_wrap(true);
            title_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
            title_label.set_hexpand(true);
            title_label.set_max_width_chars(1);
            row.append(title_label);
        }

        int64 entry_id = entry.id;
        var drag_source = new Gtk.DragSource();
        drag_source.set_actions(Gdk.DragAction.MOVE);
        drag_source.prepare.connect((source, x, y) => {
            var val = GLib.Value(typeof(string));
            val.set_string(entry_id.to_string());
            return new Gdk.ContentProvider.for_value(val);
        });
        drag_source.drag_begin.connect((source, drag) => { row.add_css_class("magazine-dragging"); });
        drag_source.drag_end.connect((source, drag, delete_data) => { row.remove_css_class("magazine-dragging"); });
        row.add_controller(drag_source);

        return row;
    }
}
