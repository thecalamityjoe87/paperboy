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

/*
 * Location search dialog. Resolves a city name, ZIP code, or the current
 * location into a LocalArea and hands it to the caller on save.
 */

public delegate void LocalAreasChosen(Gee.ArrayList<LocalArea> areas);

public class LocationDialog : GLib.Object {

    // Adds a Local News location, or opens Manage locations when the list is full.
    public static void show(Gtk.Window parent) {
        if (NewsPreferences.get_instance().get_local_areas().size >= NewsPreferences.MAX_LOCAL_AREAS) {
            PrefsDialog.show_preferences_dialog(parent, false, false, true);
            return;
        }
        choose(parent, null, (areas) => {
            save_areas(parent, areas);
        });
    }

    // Saves `areas` (the first replacing `replace_key` if given) and makes
    // the first one active.
    public static void save_areas(Gtk.Window parent, Gee.ArrayList<LocalArea> areas, string? replace_key = null) {
        if (areas.size == 0) return;
        var prefs = NewsPreferences.get_instance();
        for (int i = 0; i < areas.size; i++) {
            if (i == 0 && replace_key != null) {
                prefs.replace_local_area(replace_key, areas[i]);
            } else {
                prefs.add_local_area(areas[i]);
            }
        }
        prefs.active_local_area_key = areas[0].key;
        prefs.save_config();
        refresh_local_news(parent);
    }

    // Updates the sidebar and Local News view after the saved areas change.
    public static void refresh_local_news(Gtk.Window parent) {
        Idle.add(() => {
            var win = parent as NewsWindow;
            if (win == null) return false;
            win.update_personalization_ui();
            win.update_local_news_ui();
            if (win.sidebar_manager != null) win.sidebar_manager.rebuild_sidebar();
            if (win.category_manager.is_local_news_view()) {
                win.update_content_header_now();
                win.fetch_news();
            }
            return false;
        });
    }

    // Opens the search. A null `current` adds new areas (offering the
    // nearby metro alongside a small town); otherwise edits that one area.
    // `parent` can be a window or another dialog to stack on.
    public static void choose(Gtk.Widget parent, LocalArea? current, owned LocalAreasChosen on_save) {
        LocalAreasChosen save_cb = (owned) on_save;
        var prefs = NewsPreferences.get_instance();
        bool adding = (current == null);
        string save_label = adding ? "Add" : "Save";

        var dialog = new Adw.AlertDialog(adding ? "Add city" : "Change location",
            "Enter a city name or a ZIP code, or use your current location.\nExamples: \"San Francisco, CA\" or \"94103\" or \"94103-1234\"");
        dialog.set_body_use_markup(false);

        var entry = new Gtk.Entry();
        entry.set_placeholder_text("City name or ZIP code (e.g. San Francisco, 94103)");
        entry.set_hexpand(true);
        entry.set_margin_top(6);
        entry.set_margin_bottom(6);

        // Inline hints / validation messages
        var hint = new Gtk.Label("");
        hint.add_css_class("dim-label");
        hint.set_halign(Gtk.Align.START);
        hint.set_valign(Gtk.Align.CENTER);
        hint.set_wrap(true);
        hint.set_xalign(0);
        hint.set_margin_top(4);

        if (!adding) {
            hint.set_use_markup(true);
            hint.set_markup("Current location: <b>" + GLib.Markup.escape_text(current.city) + "</b>");
        }

        // Town/metro checkboxes, filled in after a lookup
        var choices_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);
        choices_box.set_visible(false);

        var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
        box.append(entry);
        box.append(hint);
        box.append(choices_box);
        dialog.set_extra_child(box);

        // Lets async lookups skip UI updates once the dialog is gone.
        bool dialog_alive = true;

        dialog.destroy.connect(() => {
            dialog_alive = false;
        });

        dialog.add_response("save", save_label);
        dialog.add_response("cancel", "Cancel");
        dialog.set_default_response("save");
        dialog.set_close_response("cancel");
        dialog.set_response_appearance("save", Adw.ResponseAppearance.SUGGESTED);

        // Save only unlocks after a successful lookup.
        dialog.set_response_enabled("save", false);

        dialog.present(parent);

        // Spinner row shown while lookup is in progress
        var spinner_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
        spinner_box.set_halign(Gtk.Align.CENTER);
        spinner_box.set_valign(Gtk.Align.CENTER);
        var spinner = new Gtk.Spinner();
        var spinner_label = new Gtk.Label("Searching...");
        spinner.set_halign(Gtk.Align.CENTER);
        spinner_label.set_halign(Gtk.Align.CENTER);
        spinner_box.append(spinner);
        spinner_box.append(spinner_label);
        spinner_box.hide(); box.append(spinner_box);

        // Null these out so late async callbacks don't touch freed widgets.
        dialog.destroy.connect(() => {
            spinner = null;
            spinner_box = null;
        });

        var button_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
        button_row.set_halign(Gtk.Align.CENTER);
        var search_btn = new Gtk.Button.with_label("Search");
        search_btn.set_valign(Gtk.Align.CENTER);
        var use_location_btn = new Gtk.Button.with_label("Use my location");
        use_location_btn.set_valign(Gtk.Align.CENTER);
        button_row.append(search_btn);
        button_row.append(use_location_btn);
        box.append(button_row);

        // Areas from the last lookup, and the checkbox (if any) for each.
        string last_detected_query = "";
        var candidates = new Gee.ArrayList<LocalArea>();
        var checks = new Gee.ArrayList<Gtk.CheckButton?>();

        // Checked candidates that aren't saved yet (or the lone candidate).
        Gee.ArrayList<LocalArea> selected_areas() {
            var picked = new Gee.ArrayList<LocalArea>();
            for (int i = 0; i < candidates.size; i++) {
                var check = checks[i];
                if (check == null || (check.get_active() && check.get_sensitive())) {
                    picked.add(candidates[i]);
                }
            }
            return picked;
        }

        dialog.choose.begin(parent, null, (obj, res) => {
            string response = dialog.choose.end(res);
            dialog.close();
            if (response == "save") {
                var picked = selected_areas();
                if (picked.size > 0) save_cb(picked);
            }
        });

        bool is_saved(LocalArea area) {
            foreach (var saved in prefs.get_local_areas()) {
                if (saved.key == area.key) return true;
            }
            return false;
        }

        void clear_choices() {
            Gtk.Widget? child = choices_box.get_first_child();
            while (child != null) {
                var next = child.get_next_sibling();
                choices_box.remove(child);
                child = next;
            }
            choices_box.set_visible(false);
            candidates.clear();
            checks.clear();
        }

        // Keeps the checked count within the remaining slots.
        void on_check_toggled(Gtk.CheckButton toggled) {
            int remaining = NewsPreferences.MAX_LOCAL_AREAS - prefs.get_local_areas().size;
            if (toggled.get_active() && selected_areas().size > remaining) {
                toggled.set_active(false);
                hint.set_use_markup(false);
                hint.set_text("You can save up to %d locations.".printf(NewsPreferences.MAX_LOCAL_AREAS));
            }
            dialog.set_response_enabled("save", selected_areas().size > 0);
        }

        Gtk.CheckButton add_choice(LocalArea area, string? note) {
            bool saved = is_saved(area);
            var check = new Gtk.CheckButton.with_label(saved ? area.city + " (already added)" : area.city);
            check.set_active(true);
            check.set_sensitive(!saved);
            choices_box.append(check);
            if (note != null) {
                var note_label = new Gtk.Label(note);
                note_label.add_css_class("dim-label");
                note_label.add_css_class("caption");
                note_label.set_xalign(0);
                note_label.set_margin_start(28);
                choices_box.append(note_label);
            }
            candidates.add(area);
            checks.add(check);
            return check;
        }

        // Applies a search or "use my location" result to the hint and Save state.
        void on_lookup_resolved(string resolved, string news_query_city) {
            if (!dialog_alive) return;

            if (spinner != null) spinner.stop();
            if (spinner_box != null) spinner_box.hide();
            clear_choices();

            if (resolved.length == 0) {
                hint.set_use_markup(false);
                hint.set_text("Couldn't resolve a location for that. Try a different city name or ZIP code.");
                dialog.set_response_enabled("save", false);
                return;
            }

            entry.set_text(resolved);
            hint.set_use_markup(true);

            bool is_metro = news_query_city.length == 0
                || LocalArea.short_name(news_query_city).down() == LocalArea.short_name(resolved).down();

            if (is_metro || !adding) {
                // Store a major city in its metro form so it matches the
                // "nearby metro" checkbox and can't be added twice.
                var area = is_metro && news_query_city.length > 0
                    ? new LocalArea(last_detected_query, news_query_city)
                    : new LocalArea(last_detected_query, resolved);
                candidates.add(area);
                checks.add(null);
                hint.set_markup("Detected: <b>" + GLib.Markup.escape_text(area.city) + "</b> — click " + save_label + " to use this location");
                dialog.set_response_enabled("save", true);
                return;
            }

            hint.set_markup("Detected: <b>" + GLib.Markup.escape_text(resolved) + "</b> — choose which news to add:");
            var town_check = add_choice(new LocalArea(last_detected_query, resolved), "Smaller towns may have limited coverage.");
            var metro_check = add_choice(new LocalArea(news_query_city, news_query_city), "Nearby metro area");

            // Leave the metro unchecked if both won't fit.
            int remaining = NewsPreferences.MAX_LOCAL_AREAS - prefs.get_local_areas().size;
            if (selected_areas().size > remaining && metro_check.get_sensitive()) {
                metro_check.set_active(false);
            }
            if (remaining == 1 && town_check.get_sensitive() && metro_check.get_sensitive()) {
                var slots_label = new Gtk.Label("1 location slot left — pick one, or remove a location to add both.");
                slots_label.add_css_class("dim-label");
                slots_label.add_css_class("caption");
                slots_label.set_wrap(true);
                slots_label.set_xalign(0);
                slots_label.set_margin_top(4);
                choices_box.append(slots_label);
            }
            town_check.toggled.connect(() => on_check_toggled(town_check));
            metro_check.toggled.connect(() => on_check_toggled(metro_check));

            choices_box.set_visible(true);
            dialog.set_response_enabled("save", selected_areas().size > 0);
        }

        // Shared setup before either lookup kicks off.
        void begin_lookup(string query) {
            hint.set_use_markup(false);
            hint.set_text("");
            last_detected_query = query;
            clear_choices();
            dialog.set_response_enabled("save", false);
            if (spinner != null) spinner.start();
            if (spinner_box != null) spinner_box.show();
            dialog_alive = true;
            dialog.present(parent);
        }

        search_btn.clicked.connect(() => {
            string txt = entry.get_text().strip();
            if (txt.length == 0) {
                hint.set_use_markup(false);
                hint.set_text("Enter a city name or ZIP code and press Search.");
                return;
            }
            begin_lookup(txt);
            LocationLookupService.resolve_text_async(txt, on_lookup_resolved);
        });

        use_location_btn.clicked.connect(() => {
            begin_lookup(entry.get_text().strip());
            LocationLookupService.detect_current_location_async(on_lookup_resolved);
        });
    }
}
