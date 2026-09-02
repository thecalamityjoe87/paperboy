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
 * Simple dialog to set a user inputted location string. This is a UI
 * shell that sends information to a local binary helper 'rssFinder'
 * to help discover local feeds
 */

public class LocationDialog : GLib.Object {

    public static void show(Gtk.Window parent) {
        var prefs = NewsPreferences.get_instance();

        // Guidance text updated to explicitly mention city name or US ZIP code.
        var dialog = new Adw.AlertDialog("Set User Location",
            "Enter a city name or a ZIP code (used for localized content), or use your current location.\nExamples: \"San Francisco, CA\" or \"94103\" or \"94103-1234\"");
        dialog.set_body_use_markup(false);

        var entry = new Gtk.Entry();
        // Keep the input blank by default (user must type a value).
        entry.set_text("");
        entry.set_placeholder_text("City name or ZIP code (e.g. San Francisco, 94103)");
        entry.set_hexpand(true);
        entry.set_margin_top(6);
        entry.set_margin_bottom(6);

        // Small helper label for inline hints / validation messages
        var hint = new Gtk.Label("");
        hint.add_css_class("dim-label");
        hint.set_halign(Gtk.Align.START);
        hint.set_valign(Gtk.Align.CENTER);
        hint.set_margin_top(4);

        // If a user location is already set in preferences, show it here
        // as an informational message while keeping the entry blank.
        string cur_city = "";
        if (prefs.user_location_city != null && prefs.user_location_city.length > 0) {
            cur_city = prefs.user_location_city;
        } else if (prefs.user_location != null && prefs.user_location.length > 0) {
            // Fallback to raw stored location if no resolved city is present
            cur_city = prefs.user_location;
        }
        if (cur_city.length > 0) {
            // Use markup to emphasize the current setting
            hint.set_use_markup(true);
            hint.set_markup("Current location: <b>" + GLib.Markup.escape_text(cur_city) + "</b>");
        }

        var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
        box.append(entry);
        box.append(hint);
        dialog.set_extra_child(box);

        // Track whether the dialog is still alive; if the user closes
        // the prefs dialog before an async lookup completes we should
        // avoid showing the inline detected row or a late confirmation
        // dialog (which is confusing). We set a flag on destroy and
        // check it from the async callback. Later, after creating the
        // spinner/detected widgets we also nullify those references on
        // destroy so async callbacks don't call methods on freed GTK
        // objects (which can cause SIGSEGV).
        bool dialog_alive = true;

        dialog.destroy.connect(() => {
            dialog_alive = false;
        });

        dialog.add_response("save", "Save");
        dialog.add_response("cancel", "Cancel");
        dialog.set_default_response("save");
        dialog.set_close_response("cancel");
        dialog.set_response_appearance("save", Adw.ResponseAppearance.SUGGESTED);

        // Disable Save button initially if no location is set yet
        // (first-time users must perform a search to enable it)
        bool has_existing_location = false;
        if ((prefs.user_location_city != null && prefs.user_location_city.length > 0) ||
            (prefs.user_location != null && prefs.user_location.length > 0)) {
            has_existing_location = true;
        }

        if (!has_existing_location) {
            dialog.set_response_enabled("save", false);
        }

        // Ensure the prefs dialog is presented so inline UI (spinner,
        // detected row, hints) can be shown immediately while a
        // background lookup runs.
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

        // When the dialog is destroyed, null out local widget references
        // so any outstanding async callbacks that capture these locals
        // will see `null` and skip calling methods on freed objects.
        dialog.destroy.connect(() => {
            spinner = null;
            spinner_box = null;
        });

        // Buttons: an explicit text search, and a one-click "use my
        // location" option backed by GeoClue2. Both support repeated
        // attempts if the result isn't satisfactory.
        var button_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
        var search_btn = new Gtk.Button.with_label("Search");
        search_btn.set_valign(Gtk.Align.CENTER);
        var use_location_btn = new Gtk.Button.with_label("Use My Location");
        use_location_btn.set_valign(Gtk.Align.CENTER);
        button_row.append(search_btn);
        button_row.append(use_location_btn);
        box.append(button_row);

        // Track the last resolved location so the Save button can use it.
        string last_detected_query = "";
        string last_detected_city = "";

        // Helper function to enable/disable Save button based on validation
        void update_save_button_state() {
            // Enable Save if:
            // 1. User has performed a successful lookup (last_detected_city is set), OR
            // 2. User already has a location configured
            bool should_enable = false;
            if (last_detected_city.length > 0) {
                should_enable = true;
            } else if (has_existing_location) {
                should_enable = true;
            }
            dialog.set_response_enabled("save", should_enable);
        }

        dialog.choose.begin(parent, null, (obj, res) => {
            string response = dialog.choose.end(res);
            if (response == "save") {
                string val = entry.get_text().strip();
                // Empty value clears the preference
                if (val.length == 0) {
                    prefs.user_location = "";
                    prefs.save_config();
                    dialog.close();
                    return;
                }

                // Determine what to save: if we have a resolved city from
                // a lookup, use that; otherwise use the raw input as a
                // city name.
                string location_to_save;
                string city_to_save;
                string query_for_rssfinder;

                if (last_detected_city.length > 0) {
                    // User performed a lookup - use the resolved city
                    location_to_save = last_detected_query;
                    city_to_save = last_detected_city;
                    query_for_rssfinder = last_detected_city;
                } else {
                    // User entered a city name directly
                    location_to_save = val;
                    city_to_save = "";
                    query_for_rssfinder = val;
                }

                prefs.user_location = location_to_save;
                prefs.user_location_city = city_to_save;
                prefs.save_config();

                // Close the dialog immediately
                dialog.close();

                // After dialog closes, update UI and run rssFinder
                Idle.add(() => {
                    var parent_win2 = parent as NewsWindow;
                    if (parent_win2 != null) {
                        parent_win2.update_personalization_ui();
                        parent_win2.update_local_news_ui();
                        // Run rssFinder with the appropriate query
                        RssFinderService.spawn_async(parent, query_for_rssfinder, true);
                    }
                    return false;
                });
                return;
            } else {
                // For any non-save response (cancel/close), close the dialog.
                dialog.close();
                return;
            }
        });

        // Shared completion handler: applies a lookup's result (from
        // either the text search or "use my location") to the hint/Save
        // button state.
        void on_lookup_resolved(string resolved) {
            if (!dialog_alive) return;

            if (spinner != null) spinner.stop();
            if (spinner_box != null) spinner_box.hide();

            if (resolved.length > 0) {
                last_detected_city = resolved;
                entry.set_text(resolved);
                hint.set_use_markup(true);
                hint.set_markup("Detected: <b>" + GLib.Markup.escape_text(resolved) + "</b> — click Save to use this location");
            } else {
                hint.set_use_markup(false);
                hint.set_text("Couldn't resolve a location for that. Try a different city name or ZIP code.");
                last_detected_city = "";
            }
            update_save_button_state();
        }

        // Shared setup before either lookup kicks off.
        void begin_lookup(string query) {
            hint.set_use_markup(false);
            hint.set_text("");
            last_detected_query = query;
            last_detected_city = "";
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
