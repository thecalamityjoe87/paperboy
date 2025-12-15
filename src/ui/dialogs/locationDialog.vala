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
            "Enter a city name or a ZIP code (used for localized content).\nExamples: \"San Francisco, CA\" or \"94103\" or \"94103-1234\"");
        dialog.set_body_use_markup(false);

        var entry = new Gtk.Entry();
        // Keep the input blank by default (user must type a value).
        entry.set_text("");
        entry.set_placeholder_text("City name or ZIP code (e.g. San Francisco, 94103)");
        entry.set_hexpand(true);
        entry.set_margin_top(6);
        entry.set_margin_bottom(6);

        // Suggestions area: an inline list that appears below the entry
        var suggestions_scroller = new Gtk.ScrolledWindow();
        suggestions_scroller.set_min_content_height(0);
        suggestions_scroller.set_max_content_height(200);
        suggestions_scroller.set_vexpand(false);
        var suggestions_list = new Gtk.ListBox();
        suggestions_list.set_selection_mode(Gtk.SelectionMode.NONE);
        suggestions_scroller.set_child(suggestions_list);
        suggestions_scroller.hide();

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
        box.append(suggestions_scroller);
        box.append(hint);
        dialog.set_extra_child(box);

        // Track whether the dialog is still alive; if the user closes
        // the prefs dialog before an async ZIP lookup completes we
        // should avoid showing the inline detected row or a late
        // confirmation dialog (which is confusing). We set a flag on
        // destroy and check it from the async callback. Later, after
        // creating the spinner/detected widgets we also nullify those
        // references on destroy so async callbacks don't call methods
        // on freed GTK objects (which can cause SIGSEGV).
        bool dialog_alive = true;
        uint lookup_timeout_id = 0;

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
            // Also cancel any pending lookup timeout to avoid leaving a
            // stray source referencing now-freed widgets.
            if (lookup_timeout_id != 0) {
                GLib.Source.remove(lookup_timeout_id);
                lookup_timeout_id = 0;
            }
        });

        // Search button: user explicitly starts a ZIP lookup. This allows
        // repeated searches when the result isn't satisfactory.
        var search_btn = new Gtk.Button.with_label("Search");
        search_btn.set_valign(Gtk.Align.CENTER);
        box.append(search_btn);

        // Track the last detected values so the Save button can use them
        // if the user performed a ZIP lookup.
        string last_detected_zip = "";
        string last_detected_city = "";

        // Helper function to enable/disable Save button based on validation
        void update_save_button_state() {
            // Enable Save if:
            // 1. User has performed a successful ZIP search (last_detected_city is set), OR
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

                // Determine what to save: if we have a detected city from a ZIP lookup,
                // use that; otherwise use the raw input as a city name.
                string location_to_save;
                string city_to_save;
                string query_for_rssfinder;

                if (last_detected_city.length > 0) {
                    // User performed a ZIP lookup - use the detected city
                    location_to_save = last_detected_zip;
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

        // Debounced live suggestions: when the user types, wait 250ms after
        // the last keystroke before computing suggestions. This avoids
        // heavy repeated work while the user is typing quickly.
        uint suggest_timeout_id = 0;
        entry.changed.connect(() => {
            // Cancel any pending scheduled suggestion work
            if (suggest_timeout_id != 0) {
                GLib.Source.remove(suggest_timeout_id);
                suggest_timeout_id = 0;
            }

            // Schedule suggestion computation after 250ms of inactivity
            suggest_timeout_id = GLib.Timeout.add(250, () => {
                suggest_timeout_id = 0;
                string txt = entry.get_text().strip();
                // Only show suggestions for text input (not pure numeric ZIPs)
                bool looks_numeric = true;
                for (uint i = 0; i < (uint) txt.length; i++) {
                    char c = txt[i];
                    if (!(c >= '0' && c <= '9') && c != '-' && c != ' ') { looks_numeric = false; break; }
                }

                if (txt.length < 2 || looks_numeric) {
                    suggestions_scroller.hide();
                    return false; // don't repeat
                }

                // Query ZipLookup for city suggestions
                var sugg = ZipLookup.get_instance().suggest_cities(txt, 8);

                // Clear existing rows
                Gtk.Widget? child = suggestions_list.get_first_child();
                while (child != null) {
                    Gtk.Widget? next = child.get_next_sibling();
                    suggestions_list.remove(child);
                    child = next;
                }

                for (int i = 0; i < sugg.size; i++) {
                    string label_text = sugg.get(i);
                    var row = new Gtk.ListBoxRow();
                    var btn = new Gtk.Button();
                    btn.set_hexpand(true);
                    btn.set_valign(Gtk.Align.CENTER);
                    var lbl = new Gtk.Label(label_text);
                    lbl.set_halign(Gtk.Align.START);
                    lbl.set_valign(Gtk.Align.CENTER);
                    lbl.set_margin_start(6);
                    btn.set_child(lbl);
                    // When clicked, set the entry text and hide suggestions
                    btn.clicked.connect(() => {
                        entry.set_text(label_text);
                        suggestions_scroller.hide();
                    });
                    row.set_child(btn);
                    suggestions_list.append(row);
                }

                if (sugg.size > 0) {
                    suggestions_scroller.show();
                } else {
                    suggestions_scroller.hide();
                }

                return false; // one-shot
            });
        });

        // Search button behavior: start a ZIP lookup when the user clicks
        // the explicit Search button. This supports repeated searches.
        search_btn.clicked.connect(() => {
            string txt = entry.get_text().strip();
            bool looks_numeric_local = true;
            for (uint i = 0; i < (uint) txt.length; i++) {
                char c = txt[i];
                if (!(c >= '0' && c <= '9') && c != '-' && c != ' ') { looks_numeric_local = false; break; }
            }
            if (!looks_numeric_local || txt.length == 0) {
                hint.set_use_markup(false);
                hint.set_text("Enter a ZIP code and press Search.");
                return;
            }

            // Prepare UI for lookup
            // Clear hint text - the spinner provides sufficient feedback
            hint.set_use_markup(false);
            hint.set_text("");
            // Reset previous detection state
            last_detected_zip = txt;
            last_detected_city = "";
            // Show spinner
            if (spinner != null) spinner.start();
            if (spinner_box != null) spinner_box.show();
            // Cancel any previous timeout just in case
            if (lookup_timeout_id != 0) {
                GLib.Source.remove(lookup_timeout_id);
                lookup_timeout_id = 0;
            }
            // Add a fallback timeout so the UI gives feedback if the
            // main loop is busy. Instead of stopping the spinner or
            // abandoning the lookup, show a gentler hint and keep
            // waiting — the async result will still update the UI
            // when it arrives.
            lookup_timeout_id = GLib.Timeout.add(8000, () => {
                lookup_timeout_id = 0;
                if (!dialog_alive) return false;
                hint.set_use_markup(false);
                hint.set_text("Lookup is taking longer than expected — still waiting...");
                // Keep spinner visible so the user knows work is ongoing.
                update_save_button_state();
                return false; // one-shot
            });
            // Ensure dialog is visible
            dialog_alive = true;
            dialog.present(parent);
            ZipLookup.get_instance().lookup_async(txt, (resolved) => {
                if (!dialog_alive) return;

                // Cancel the timeout if it's still pending
                if (lookup_timeout_id != 0) {
                    GLib.Source.remove(lookup_timeout_id);
                    lookup_timeout_id = 0;
                }

                if (spinner != null) spinner.stop();
                if (spinner_box != null) spinner_box.hide();

                if (resolved.length > 0) {
                    last_detected_city = resolved;
                    hint.set_use_markup(true);
                    hint.set_markup("Detected: <b>" + GLib.Markup.escape_text(resolved) + "</b> — click Save to use this location");
                    // Enable Save button now that we have a valid detected city
                    update_save_button_state();
                } else {
                    hint.set_use_markup(false);
                    hint.set_text("No local mapping found for this ZIP code.");
                    // Keep Save button disabled if search failed
                    last_detected_city = "";
                    update_save_button_state();
                }
            });
        });
    }
}

