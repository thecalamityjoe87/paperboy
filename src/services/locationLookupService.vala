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

/*
 * Resolves a user's location to a "City, State"-style display string,
 * either from typed text (a ZIP code or city name, via geocode-glib's
 * Nominatim-backed forward geocoding) or from the OS location service
 * (via GeoClue2, reverse-geocoded with geocode-glib). Replaces the old
 * bundled-CSV ZipLookup, which parsed a 6MB/34,000-row file on every
 * startup.
 */
public class LocationLookupService : GLib.Object {
    private const string DESKTOP_ID = "io.github.thecalamityjoe87.Paperboy";

    public delegate void ResolvedCallback(string resolved);

    // Forward-geocode free text (a ZIP code or a city name) to a display
    // string. `callback` always runs on the main loop; `resolved` is ""
    // when nothing could be found.
    public static void resolve_text_async(string query, owned ResolvedCallback callback) {
        resolve_text.begin(query, (obj, res) => {
            string resolved = resolve_text.end(res);
            callback(resolved);
        });
    }

    private static async string resolve_text(string query) {
        try {
            var forward = new Geocode.Forward.for_string(query);
            forward.set_answer_count(1);
            var results = yield forward.search_async();
            if (results == null || results.length() == 0) return "";
            return format_place(results.nth_data(0));
        } catch (GLib.Error e) {
            return "";
        }
    }

    // Detect the user's current location via GeoClue2 and reverse-geocode
    // it to a display string. `callback` always runs on the main loop;
    // `resolved` is "" if location detection or reverse geocoding fails
    // (e.g. permission denied, no location fix available).
    public static void detect_current_location_async(owned ResolvedCallback callback) {
        detect_current_location.begin((obj, res) => {
            string resolved = detect_current_location.end(res);
            callback(resolved);
        });
    }

    private static async string detect_current_location() {
        try {
            var simple = yield new GClue.Simple(DESKTOP_ID, GClue.AccuracyLevel.CITY, null);
            var loc = simple.get_location();
            if (loc == null) return "";

            var geocode_loc = new Geocode.Location(loc.latitude, loc.longitude);
            var reverse = new Geocode.Reverse.for_location(geocode_loc);
            var place = yield reverse.resolve_async();
            return format_place(place);
        } catch (GLib.Error e) {
            return "";
        }
    }

    private static string format_place(Geocode.Place? place) {
        if (place == null) return "";

        string city = place.get_town();
        if (city == null || city.length == 0) city = place.get_name();
        if (city == null) city = "";

        string state = place.get_state();
        if (state != null && state.length > 0) {
            return city + ", " + state;
        }
        return city;
    }
}
