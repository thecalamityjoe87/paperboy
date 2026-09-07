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
 *
 * Also resolves a separate "news query" city: Google News' RSS search
 * (used for Local News) rarely has dedicated coverage for a small town,
 * so Local News always searches around the nearest bundled major city
 * (see MajorCitiesUtils) rather than the exact resolved town — that's
 * usually still the news that's most relevant to the user. This keeps
 * the exact location for display while using something more likely to
 * return real local coverage for the actual search.
 */
public class LocationLookupService : GLib.Object {
    private const string DESKTOP_ID = "io.github.thecalamityjoe87.Paperboy";

    // `resolved` is the "City, State" display string ("" if nothing could
    // be found); `news_query_city` is the nearest major city to search
    // Local News around (may equal `resolved` when it already is one, or
    // "" alongside `resolved` on failure).
    public delegate void ResolvedCallback(string resolved, string news_query_city);

    // Forward-geocode free text (a ZIP code or a city name) to a display
    // string. `callback` always runs on the main loop.
    public static void resolve_text_async(string query, owned ResolvedCallback callback) {
        resolve_text.begin(query, (obj, res) => {
            var result = resolve_text.end(res);
            callback(result.display, result.news_query);
        });
    }

    // How many forward-search candidates to request from Nominatim so we
    // have something to filter by country (see resolve_text below). Note:
    // geocode-glib's set_bounded()/set_search_area() do NOT reliably
    // restrict geocode-glib's default backend for a free-text query (the
    // resulting "viewbox" parameter is silently dropped), so this class
    // doesn't rely on them.
    private const uint CANDIDATE_COUNT = 10;

    private static async ResolvedLocation resolve_text(string query) {
        try {
            var forward = new Geocode.Forward.for_string(query);
            forward.set_answer_count(CANDIDATE_COUNT);
            var results = yield forward.search_async();
            if (results == null || results.length() == 0) return ResolvedLocation.empty();

            // A bare ZIP/postal code is genuinely ambiguous worldwide (e.g.
            // US ZIP "10001" also matches real postal codes in Ukraine,
            // Iraq, Taiwan, Peru, ...), and Nominatim's top-ranked global
            // match is frequently not the US one. Since Paperboy is a
            // US-focused app, prefer the first result actually in the US
            // over whatever ranks highest globally.
            unowned Geocode.Place chosen = results.nth_data(0);
            foreach (unowned Geocode.Place place in results) {
                var country_code = place.get_country_code();
                if (country_code != null && country_code.ascii_down() == "us") {
                    chosen = place;
                    break;
                }
            }

            return resolve_place(chosen, double.NAN, double.NAN, query);
        } catch (GLib.Error e) {
            return ResolvedLocation.empty();
        }
    }

    // Detect the user's current location via GeoClue2 and reverse-geocode
    // it to a display string. `callback` always runs on the main loop;
    // both callback values are "" if location detection or reverse
    // geocoding fails (e.g. permission denied, no location fix available).
    public static void detect_current_location_async(owned ResolvedCallback callback) {
        detect_current_location.begin((obj, res) => {
            var result = detect_current_location.end(res);
            callback(result.display, result.news_query);
        });
    }

    private static async ResolvedLocation detect_current_location() {
        try {
            var simple = yield new GClue.Simple(DESKTOP_ID, GClue.AccuracyLevel.CITY, null);
            var loc = simple.get_location();
            if (loc == null) return ResolvedLocation.empty();

            var geocode_loc = new Geocode.Location(loc.latitude, loc.longitude);
            var reverse = new Geocode.Reverse.for_location(geocode_loc);
            var place = yield reverse.resolve_async();
            // Use GeoClue's own coordinates for the nearest-major-city
            // lookup rather than place.get_location(): geocode-glib's
            // reverse resolution has been observed to come back with a
            // Place whose location has a garbage latitude (e.g. 0.0)
            // even though the place's name/town/state are resolved
            // correctly, which would otherwise send MajorCitiesUtils.nearest()
            // wildly off course.
            return resolve_place(place, loc.latitude, loc.longitude);
        } catch (GLib.Error e) {
            return ResolvedLocation.empty();
        }
    }

    private struct ResolvedLocation {
        public string display;
        public string news_query;

        public static ResolvedLocation empty() {
            return ResolvedLocation() { display = "", news_query = "" };
        }
    }

    // `known_lat`/`known_lon` let a caller that already has an
    // authoritative coordinate (e.g. GeoClue's GPS fix) use it for the
    // nearest-major-city lookup instead of place.get_location(), which
    // for some resolved places is unreliable (see detect_current_location).
    // Pass NAN for both when no such coordinate is available. `query_text`
    // is the user's original typed search text (null when there wasn't
    // one, e.g. GPS detection); see format_place for how it's used.
    private static ResolvedLocation resolve_place(Geocode.Place? place, double known_lat = double.NAN, double known_lon = double.NAN, string? query_text = null) {
        string display = format_place(place, query_text);
        if (display.length == 0) return ResolvedLocation.empty();

        string news_query = display;
        double lat = known_lat;
        double lon = known_lon;
        if (lat.is_nan() || lon.is_nan()) {
            if (place != null) {
                var loc = place.get_location();
                if (loc != null) {
                    lat = loc.latitude;
                    lon = loc.longitude;
                }
            }
        }

        if (!lat.is_nan() && !lon.is_nan()) {
            double distance_km;
            string nearest = MajorCitiesUtils.nearest(lat, lon, out distance_km);
            if (nearest.length > 0) {
                news_query = nearest;
            }
        }

        return ResolvedLocation() { display = display, news_query = news_query };
    }

    // `query_text` is the raw text the user typed (e.g. "Chicago"), used
    // as a fallback display city when the resolved place has no usable
    // town/city detail; pass null when there was no typed query (GPS
    // detection).
    private static string format_place(Geocode.Place? place, string? query_text = null) {
        if (place == null) return "";

        // Reject matches too coarse to be a meaningful "City, State"
        // result (e.g. a bare country or continent) rather than falling
        // back to place.get_name(), which for these is just the country
        // name and would otherwise duplicate against get_state() as
        // "United States, United States".
        switch (place.get_place_type()) {
        case Geocode.PlaceType.COUNTRY:
        case Geocode.PlaceType.CONTINENT:
        case Geocode.PlaceType.STATE:
        case Geocode.PlaceType.HISTORICAL_STATE:
        case Geocode.PlaceType.OCEAN:
        case Geocode.PlaceType.SEA:
        case Geocode.PlaceType.TIME_ZONE:
            return "";
        default:
            break;
        }

        string city = place.get_town();
        if (city == null) city = "";

        // When there's no town detail, prefer the user's own typed text
        // (normally the real city name) over place.get_name(): for a
        // match that only resolved down to country-level detail,
        // get_name() is unreliable — it can come back as just the
        // country's own name, or even doubled as literally "United
        // States, United States" — which would otherwise print twice
        // once concatenated with the state below.
        if (city.length == 0) {
            if (query_text != null && query_text.length > 0) {
                city = query_text;
            } else {
                string name = place.get_name() ?? "";
                string country = place.get_country() ?? "";
                city = (country.length > 0 && name.contains(country)) ? "" : name;
            }
        }
        if (city.length == 0) return "";

        string state = place.get_state();
        if (state != null && state.length > 0 && state != city) {
            return city + ", " + state;
        }
        return city;
    }
}
