/* Paperboy - A simple news reader application
 * 
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
using Soup;
using Gdk;
 
public class PaperboyApp : Adw.Application {
    public PaperboyApp() {
        GLib.Object(application_id: "io.github.thecalamityjoe87.Paperboy", flags: ApplicationFlags.FLAGS_NONE);
    }

    protected override void activate() {
        var win = new NewsWindow(this);
        win.present();
        // Eagerly instantiate ZipLookup so it starts loading the CSV in
        // the background during app startup. This helps ensure the ZIP
        // database is ready by the time the user opens the Set Location
        // dialog.
        try { ZipLookup.get_instance(); } catch (GLib.Error e) { }
        // If this is the user's first time running the app, show the
        // preferences dialog so they can adjust sources immediately.
        try {
            var prefs = NewsPreferences.get_instance();
            // On first run, show the preferences dialog so users can immediately
            // enable/disable individual providers and configure the app.
            if (prefs.first_run) PrefsDialog.show_preferences_dialog(win);
        } catch (GLib.Error e) { }
        
        var change_source_action = new SimpleAction("change-source", null);
        change_source_action.activate.connect(() => {
            PrefsDialog.show_source_dialog(win);
        });
        this.add_action(change_source_action);
        
        var about_action = new SimpleAction("about", null);
        about_action.activate.connect(() => {
            PrefsDialog.show_about_dialog(win);
        });
        this.add_action(about_action);

        var set_location_action = new SimpleAction("set-location", null);
        set_location_action.activate.connect(() => {
            LocationDialog.show(win);
        });
        this.add_action(set_location_action);
    }

}

public static int main(string[] args) {
    var app = new PaperboyApp();
    return app.run(args);
}
