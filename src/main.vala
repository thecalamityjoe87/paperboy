/* Paperboy - A simple news reader and RSS application
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

public class PaperboyApp : Adw.Application {
    public PaperboyApp() {
        GLib.Object(application_id: "io.github.thecalamityjoe87.Paperboy", flags: ApplicationFlags.FLAGS_NONE);
    }

    protected override void activate() {
        // Ensure global HttpClient is constructed on the main thread
        // before any other subsystem can spawn worker threads.
        Paperboy.HttpClientUtils.ensure_initialized();

        // Apply the user's saved color scheme before the window is built
        // so it opens with the right theme instead of flashing the
        // libadwaita default and then switching.
        var prefs = NewsPreferences.get_instance();
        prefs.apply_color_scheme();

        var win = new NewsWindow(this);
        win.present();
        // On first run, show the welcome/onboarding dialog so users can
        // get an introduction and immediately pick a few sources.
        if (!prefs.onboarding_completed) OnboardingDialog.show(win);

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

        var onboarding_action = new SimpleAction("show-onboarding", null);
        onboarding_action.activate.connect(() => {
            OnboardingDialog.show(win);
        });
        this.add_action(onboarding_action);
    }

}

public static int main(string[] args) {

    var app = new PaperboyApp();
    return app.run(args);
}
