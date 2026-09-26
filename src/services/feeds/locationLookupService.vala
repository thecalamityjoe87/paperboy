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
 * Resolves a user's location to a "City, State" display string, either
 * from typed text (a ZIP code or city name) or from the OS location
 * service (GeoClue2), using Nominatim's JSON API directly.
 *
 * Also resolves a "news query" city: the nearest bundled major city (see
 * MajorCitiesUtils), offered alongside small towns since Google News
 * often has little coverage for them.
 */
public class LocationLookupService : GLib.Object {
    private const string DESKTOP_ID = "io.github.thecalamityjoe87.Paperboy";
    private const string NOMINATIM = "https://nominatim.openstreetmap.org";
    // Farther than this, the "nearest" metro isn't really local news.
    private const double MAX_METRO_DISTANCE_KM = 200.0;

    // Nominatim address fields that name a place, most specific first.
    private const string[] TOWN_FIELDS = { "city", "town", "village", "hamlet", "municipality" };

    // `resolved` is the "City, State" display string ("" if nothing could
    // be found); `news_query_city` is the nearest major city (may equal
    // `resolved`, or "" alongside it on failure).
    public delegate void ResolvedCallback(string resolved, string news_query_city);

    // Looks up free text (a ZIP code or a city name). `callback`
    // always runs on the main loop.
    public static void resolve_text_async(string query, owned ResolvedCallback callback) {
        string url = NOMINATIM + "/search?format=jsonv2&addressdetails=1&limit=10&q="
            + GLib.Uri.escape_string(query, null, false);
        Paperboy.HttpClientUtils.get_default().fetch_json(url, (response, parser, root) => {
            if (root == null || root.get_node_type() != Json.NodeType.ARRAY) {
                callback("", "");
                return;
            }
            var results = root.get_array();
            if (results.get_length() == 0) {
                callback("", "");
                return;
            }

            // Bare ZIP codes match postal codes worldwide; prefer a US result.
            Json.Object chosen = results.get_object_element(0);
            for (uint i = 0; i < results.get_length(); i++) {
                var candidate = results.get_object_element(i);
                if (get_address_field(candidate, "country_code") == "us") {
                    chosen = candidate;
                    break;
                }
            }

            double lat = double.parse(chosen.get_string_member_with_default("lat", "nan"));
            double lon = double.parse(chosen.get_string_member_with_default("lon", "nan"));

            string display = format_place(chosen);
            if (display.length > 0 || is_coarse(chosen)) {
                finish(display, lat, lon, (owned) callback);
                return;
            }
            // No town in the match itself (some ZIP codes); ask what's at its point.
            reverse(lat, lon, (owned) callback);
        });
    }

    // Detect the user's current location via GeoClue2. `callback` always
    // runs on the main loop; both values are "" on failure (e.g.
    // permission denied, no location fix available).
    public static void detect_current_location_async(owned ResolvedCallback callback) {
        detect_current_location.begin((obj, res) => {
            double lat, lon;
            if (!detect_current_location.end(res, out lat, out lon)) {
                callback("", "");
                return;
            }
            reverse(lat, lon, (owned) callback);
        });
    }

    private static async bool detect_current_location(out double lat, out double lon) {
        lat = double.NAN;
        lon = double.NAN;
        try {
            var simple = yield new GClue.Simple(DESKTOP_ID, GClue.AccuracyLevel.CITY, null);
            var loc = simple.get_location();
            if (loc == null) return false;
            lat = loc.latitude;
            lon = loc.longitude;
            return true;
        } catch (GLib.Error e) {
            return false;
        }
    }

    // Looks up the city at a point.
    private static void reverse(double lat, double lon, owned ResolvedCallback callback) {
        if (lat.is_nan() || lon.is_nan()) {
            callback("", "");
            return;
        }
        string url = NOMINATIM + "/reverse?format=jsonv2&addressdetails=1&zoom=10&lat=%s&lon=%s".printf(
            coord_to_string(lat), coord_to_string(lon));
        Paperboy.HttpClientUtils.get_default().fetch_json(url, (response, parser, root) => {
            string display = "";
            if (root != null && root.get_node_type() == Json.NodeType.OBJECT) {
                display = format_place(root.get_object());
            }
            finish(display, lat, lon, (owned) callback);
        });
    }

    private static void finish(string display, double lat, double lon, owned ResolvedCallback callback) {
        if (display.length == 0) {
            callback("", "");
            return;
        }
        string news_query = display;
        if (!lat.is_nan() && !lon.is_nan()) {
            double distance_km;
            string nearest = MajorCitiesUtils.nearest(lat, lon, out distance_km);
            if (nearest.length > 0 && distance_km <= MAX_METRO_DISTANCE_KM) news_query = nearest;
        }
        callback(display, news_query);
    }

    // Locale-independent, so a "," decimal separator can't break the URL.
    private static string coord_to_string(double value) {
        char[] buf = new char[double.DTOSTR_BUF_SIZE];
        return value.format(buf, "%.6f");
    }

    private static string get_address_field(Json.Object place, string field) {
        if (!place.has_member("address")) return "";
        var address = place.get_object_member("address");
        return address != null ? address.get_string_member_with_default(field, "") : "";
    }

    // Matches too broad to be a city (a country, state, ...).
    private static bool is_coarse(Json.Object place) {
        string type = place.get_string_member_with_default("addresstype", "");
        return type == "country" || type == "state" || type == "continent" || type == "region";
    }

    // "City, State", or "" when the place has no town-level detail.
    private static string format_place(Json.Object place) {
        if (is_coarse(place)) return "";

        string city = "";
        foreach (string field in TOWN_FIELDS) {
            city = get_address_field(place, field);
            if (city.length > 0) break;
        }
        if (city.length == 0) return "";

        string state = get_address_field(place, "state");
        return (state.length > 0 && state != city) ? city + ", " + state : city;
    }
}
