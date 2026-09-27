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

// Fetches a WeatherReport for a saved Local News area. Coordinates come from
// geocoding the area's city name, so it works however the area was added.
public class WeatherService : GLib.Object {
    private const string FORECAST_URL = "https://api.open-meteo.com/v1/forecast";
    private const int64 MAX_AGE_US = 20 * 60 * 1000000LL;

    public delegate void ReportCallback(WeatherReport? report);

    // Keyed by LocalArea.key; lazily created (static Gee fields with initializers never run).
    private static Gee.HashMap<string, WeatherReport>? _reports = null;
    private static Gee.HashMap<string, WeatherReport> reports() {
        if (_reports == null) _reports = new Gee.HashMap<string, WeatherReport>();
        return _reports;
    }
    private static Gee.HashMap<string, string>? _coords = null;
    private static Gee.HashMap<string, string> coords() {
        if (_coords == null) _coords = new Gee.HashMap<string, string>();
        return _coords;
    }

    // Last report for this area, even if stale; null if never fetched.
    public static WeatherReport? cached(LocalArea area) {
        return reports().get(area.key);
    }

    // `callback` runs on the main loop; null on failure.
    public static void get_async(LocalArea area, owned ReportCallback callback) {
        var existing = reports().get(area.key);
        if (existing != null && GLib.get_monotonic_time() - existing.fetched_at_us < MAX_AGE_US) {
            callback(existing);
            return;
        }

        string key = area.key;
        string? known = coords().get(key);
        if (known != null) {
            fetch_forecast(key, known, (owned) callback);
            return;
        }
        LocationLookupService.geocode_async(area.city, (lat, lon) => {
            if (lat.is_nan() || lon.is_nan()) {
                callback(null);
                return;
            }
            string query = "latitude=%s&longitude=%s".printf(coord(lat), coord(lon));
            coords().set(key, query);
            fetch_forecast(key, query, (owned) callback);
        });
    }

    private static void fetch_forecast(string key, string coord_query, owned ReportCallback callback) {
        bool fahrenheit = locale_uses_fahrenheit();
        string url = FORECAST_URL + "?" + coord_query
            + "&current=temperature_2m,weather_code,is_day"
            + "&daily=temperature_2m_max,temperature_2m_min&forecast_days=1&timezone=auto"
            + (fahrenheit ? "&temperature_unit=fahrenheit" : "");
        Paperboy.HttpClientUtils.get_default().fetch_json(url, (response, parser, root) => {
            var report = parse(root, fahrenheit);
            if (report != null) reports().set(key, report);
            callback(report);
        });
    }

    private static WeatherReport? parse(Json.Node? root, bool fahrenheit) {
        if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return null;
        var obj = root.get_object();
        if (!obj.has_member("current") || !obj.has_member("daily")) return null;
        var current = obj.get_object_member("current");
        var daily = obj.get_object_member("daily");
        if (current == null || daily == null || !current.has_member("temperature_2m")) return null;
        var highs = daily.has_member("temperature_2m_max") ? daily.get_array_member("temperature_2m_max") : null;
        var lows = daily.has_member("temperature_2m_min") ? daily.get_array_member("temperature_2m_min") : null;
        if (highs == null || lows == null || highs.get_length() == 0 || lows.get_length() == 0) return null;

        var report = new WeatherReport();
        report.temperature = current.get_double_member("temperature_2m");
        report.code = (int) current.get_int_member_with_default("weather_code", 3);
        report.is_day = current.get_int_member_with_default("is_day", 1) == 1;
        report.high = highs.get_double_element(0);
        report.low = lows.get_double_element(0);
        report.fahrenheit = fahrenheit;
        report.fetched_at_us = GLib.get_monotonic_time();
        return report;
    }

    // Countries that use Fahrenheit, going by the measurement locale.
    private static bool locale_uses_fahrenheit() {
        string? locale = null;
        foreach (string variable in new string[] { "LC_ALL", "LC_MEASUREMENT", "LANG" }) {
            locale = GLib.Environment.get_variable(variable);
            if (locale != null && locale.length > 0) break;
        }
        if (locale == null) return false;
        string[] fahrenheit_regions = { "_US", "_LR", "_BS", "_BZ", "_KY", "_PW", "_FM", "_MH" };
        foreach (string region in fahrenheit_regions) {
            if (locale.contains(region)) return true;
        }
        return false;
    }

    // Locale-independent, so a "," decimal separator can't break the URL.
    private static string coord(double value) {
        char[] buf = new char[double.DTOSTR_BUF_SIZE];
        return value.format(buf, "%.4f");
    }
}
