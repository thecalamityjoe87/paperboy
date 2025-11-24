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

using GLib;
using Gee;

/*
 * Local CSV-based ZIP -> city resolver.
 *
 * Expects a CSV at data/usZips.csv with rows:
 * ZIP,City,State
 *
 * This loader reads the CSV at startup (best-effort) and provides
 * a synchronous lookup method returning a "City, State" string or
 * null when no mapping is present.
 */

public class ZipLookup : GLib.Object {
    // Async lookup callback type (resolved string is empty when not found)
    public delegate void LookupCallback(string resolved);
    // Basic 5-digit -> city string mapping (legacy fallback)
    private Gee.HashMap<string, string> map;
    private Gee.ArrayList<string> keys;
    // Flat suggestion list used by the UI
    private Gee.ArrayList<string> cities;

    // Richer data to support nearest-major-city matching
    private class ZipRecord : GLib.Object {
        public string zip { get; set; }
        public double lat { get; set; }
        public double lng { get; set; }
        public string city { get; set; }
        public string state { get; set; }
        public long population { get; set; }
    }

    private class MajorCity : GLib.Object {
        public string name { get; set; }
        public double lat { get; set; }
        public double lng { get; set; }
        public long population { get; set; }
    }

    private Gee.HashMap<string, ZipRecord> zip_records; // keyed by 5-digit ZIP
    private Gee.ArrayList<MajorCity> major_cities;     // aggregated major cities
    private static ZipLookup? _instance = null;
    private bool loaded = false;
    private bool loading = false;
    private GLib.Mutex load_mutex = new GLib.Mutex();

    public static ZipLookup get_instance() {
        if (_instance == null) _instance = new ZipLookup();
        return (ZipLookup) _instance;
    }

    private ZipLookup() {
        map = new Gee.HashMap<string,string>(string_hash, string_equal);
        keys = new Gee.ArrayList<string>();
        cities = new Gee.ArrayList<string>();
        zip_records = new Gee.HashMap<string,ZipRecord>(string_hash, string_equal);
        major_cities = new Gee.ArrayList<MajorCity>();
        // Start background loading (best-effort) so the CSV parsing does
        // not block the main thread during application startup. If a
        // lookup is requested before loading completes, the lookup
        // will perform the load on the worker thread.
        ensure_loaded_async();
    }

    // Ensure the CSV has been loaded; called inside worker threads to
    // synchronously load if required without blocking the UI.
    private void ensure_loaded_sync() {
        load_mutex.lock();
        if (!loaded) {
            // perform the actual load while holding the mutex so only
            // one thread performs the work.
            try {
                load_csv();
                loaded = true;
            } catch (GLib.Error e) {
                // best-effort; leave loaded=false if it failed
            }
        }
        load_mutex.unlock();
    }

    // Kick off an asynchronous one-shot loader so parsing happens off
    // the main thread during startup.
    private void ensure_loaded_async() {
        if (loaded) return;
        if (loading) return;
        loading = true;
        new Thread<void*>("zip-load", () => {
            try { ensure_loaded_sync(); } catch (GLib.Error e) { }
            loading = false;
            return null;
        });
    }

    private static bool string_equal(string a, string b) { return a == b; }
    private static uint string_hash(string s) { return (uint) s.hash(); }

    private void load_csv() {
        // Try a few likely locations: bundled data/ directory (development)
        // and the installed user data dir for the application.
        string[] dev_paths = { "data/us_zips.csv", "../data/us_zips.csv" };
        string? csv_path = null;
        foreach (var p in dev_paths) {
            if (GLib.FileUtils.test(p, GLib.FileTest.EXISTS)) { csv_path = p; break; }
        }

        if (csv_path == null) {
            var user_data = GLib.Environment.get_user_data_dir();
            if (user_data != null && user_data.length > 0) {
                string candidate = GLib.Path.build_filename(user_data, "paperboy", "us_zips.csv");
                if (GLib.FileUtils.test(candidate, GLib.FileTest.EXISTS)) csv_path = candidate;
            }
        }

        // Also look through system data directories (e.g. /usr/local/share or /usr/share)
        // in case the application was installed system-wide by Meson. The dev
        // `data/` paths above are used during development; keep them first so
        // local worktrees can be used without installing.
        if (csv_path == null) {
            try {
                string[] sys_dirs = GLib.Environment.get_system_data_dirs();
                foreach (var s in sys_dirs) {
                    string candidate = GLib.Path.build_filename(s, "paperboy", "us_zips.csv");
                    if (GLib.FileUtils.test(candidate, GLib.FileTest.EXISTS)) { csv_path = candidate; break; }
                }
            } catch (GLib.Error e) {
                // best-effort
            }
        }

        if (csv_path == null) return; // no CSV available

        try {
            string contents;
            try { GLib.FileUtils.get_contents(csv_path, out contents); } catch (GLib.Error e) { return; }
            string[] lines = contents.split("\n");

            // Header-aware CSV parsing: the comprehensive CSV uses quoted
            // header names like "zip","lat","lng","city","state_name".
            // We'll detect header indices for zip, city and state_name (fall
            // back to state_id when state_name is absent). If there's no
            // header we'll fall back to the old 3-column assumption.
            bool seen_header = false;
            int zip_idx = 0;
            int city_idx = 1;
            int state_idx = 2;
            int lat_idx = -1;
            int lng_idx = -1;
            int pop_idx = -1;

            foreach (var l in lines) {
                string line = l.strip();
                if (line.length == 0) continue;
                if (line[0] == '#') continue;

                // Parse CSV line into fields handling quoted commas and escaped quotes
                Gee.ArrayList<string> parts = parse_csv_line(line);
                if (!seen_header) {
                    // If header contains the word "zip" assume it's a header row
                    if (parts.size > 0) {
                        string first = parts.get(0).strip();
                        if (ascii_equal_ci(first, "zip") || ascii_equal_ci(first, "zipcode") || ascii_equal_ci(first, "postal_code")) {
                            seen_header = true;
                            // find indices
                            for (int i = 0; i < (int) parts.size; i++) {
                                string h_raw = parts.get(i).strip();
                                if (ascii_equal_ci(h_raw, "zip") || ascii_equal_ci(h_raw, "zipcode") || ascii_equal_ci(h_raw, "postal_code")) zip_idx = i;
                                if (ascii_equal_ci(h_raw, "city") || ascii_equal_ci(h_raw, "place_name") || ascii_equal_ci(h_raw, "primary_city")) city_idx = i;
                                if (ascii_equal_ci(h_raw, "state_name") || ascii_equal_ci(h_raw, "state") || ascii_equal_ci(h_raw, "state_full")) state_idx = i;
                                if (ascii_equal_ci(h_raw, "state_id") || ascii_equal_ci(h_raw, "state_abbr") || ascii_equal_ci(h_raw, "state_code")) {
                                    if (state_idx == 2) state_idx = i;
                                }
                                if (ascii_equal_ci(h_raw, "lat") || ascii_equal_ci(h_raw, "latitude")) lat_idx = i;
                                if (ascii_equal_ci(h_raw, "lng") || ascii_equal_ci(h_raw, "lon") || ascii_equal_ci(h_raw, "longitude")) lng_idx = i;
                                if (ascii_equal_ci(h_raw, "population") || ascii_equal_ci(h_raw, "pop")) pop_idx = i;
                            }
                            continue; // header row consumed
                        }
                    }
                    // Not a header; fall through to treat as data row using defaults
                    seen_header = true;
                }

                int m = zip_idx;
                if (city_idx > m) m = city_idx;
                if (state_idx > m) m = state_idx;
                if (parts.size <= m) continue;

                string zip = parts.get(zip_idx).strip();
                string city = parts.get(city_idx).strip();
                string state = parts.get(state_idx).strip();

                double lat = 0.0; double lng = 0.0; long population = 0;
                try {
                    if (lat_idx >= 0 && (uint) lat_idx < parts.size) lat = double.parse(parts.get(lat_idx).strip());
                } catch (GLib.Error e) { lat = 0.0; }
                try {
                    if (lng_idx >= 0 && (uint) lng_idx < parts.size) lng = double.parse(parts.get(lng_idx).strip());
                } catch (GLib.Error e) { lng = 0.0; }
                try {
                    if (pop_idx >= 0 && (uint) pop_idx < parts.size) population = (long) long.parse(parts.get(pop_idx).strip());
                } catch (GLib.Error e) { population = 0; }

                if (zip.length >= 5) {
                    string key = zip.substring(0, 5);
                    string value = city;
                    if (state != null && state.length > 0) value = value + ", " + state;

                    map.set(key, value);
                    try {
                        if (!keys.contains(key)) keys.add(key);
                        // Maintain a unique list of city strings for suggestions
                        if (value.length > 0 && !cities.contains(value)) cities.add(value);
                    } catch (GLib.Error e) { }

                    // Build a richer zip record for spatial lookup
                    try {
                        var zr = new ZipRecord();
                        zr.zip = key;
                        zr.lat = lat;
                        zr.lng = lng;
                        zr.city = city;
                        zr.state = state;
                        zr.population = population;
                        zip_records.set(key, zr);
                    } catch (GLib.Error e) { }
                }
            }

            // After ingesting all rows, build aggregated major city list
            try {
                var city_groups = new Gee.HashMap<string, Gee.ArrayList<ZipRecord>>(string_hash, string_equal);
                // iterate the list of known ZIP keys (populated while reading CSV)
                // also keep a list of discovered city names to avoid calling
                // city_groups.keys() (invocations in foreach cause Vala compile issues).
                var city_names = new Gee.ArrayList<string>();
                foreach (string zkey in keys) {
                    ZipRecord? zr = zip_records.get(zkey);
                    if (zr == null) continue;
                    string city_name = zr.city;
                    if (zr.state != null && zr.state.length > 0) city_name = city_name + ", " + zr.state;
                    Gee.ArrayList<ZipRecord> group = null;
                    if (city_groups.has_key(city_name)) group = city_groups.get(city_name);
                    if (group == null) { group = new Gee.ArrayList<ZipRecord>(); city_names.add(city_name); }
                    group.add(zr);
                    city_groups.set(city_name, group);
                }

                // Aggregate: compute total population and population-weighted centroid
                // iterate the collected city group names
                foreach (string cname in city_names) {
                    Gee.ArrayList<ZipRecord> grp = city_groups.get(cname);
                    long total_pop = 0;
                    double lat_sum = 0.0;
                    double lng_sum = 0.0;
                    for (int i = 0; i < grp.size; i++) {
                        ZipRecord r = grp.get(i);
                        long p = r.population;
                        if (p <= 0) p = 0;
                        total_pop += p;
                        lat_sum += r.lat * (double) p;
                        lng_sum += r.lng * (double) p;
                    }
                    // Fallback: if no population data, fallback to average of zips
                    double cen_lat = 0.0;
                    double cen_lng = 0.0;
                    if (total_pop > 0) {
                        cen_lat = lat_sum / (double) total_pop;
                        cen_lng = lng_sum / (double) total_pop;
                    } else {
                        // average unweighted
                        double s_lat = 0.0; double s_lng = 0.0;
                        for (int j = 0; j < grp.size; j++) { s_lat += grp.get(j).lat; s_lng += grp.get(j).lng; }
                        if (grp.size > 0) { cen_lat = s_lat / (double) grp.size; cen_lng = s_lng / (double) grp.size; }
                    }

                    var mc = new MajorCity();
                    mc.name = cname;
                    mc.lat = cen_lat;
                    mc.lng = cen_lng;
                    mc.population = total_pop;
                    major_cities.add(mc);
                }

                // Keep only larger cities (heuristic): population >= 50k, or top 200 by population
                major_cities.sort((a, b) => (int) (b.population - a.population));
                var filtered = new Gee.ArrayList<MajorCity>();
                for (int i = 0; i < major_cities.size; i++) {
                    if (major_cities.get(i).population >= 50000) filtered.add(major_cities.get(i));
                    if (filtered.size >= 200) break;
                }
                if (filtered.size == 0) {
                    // no population thresholds matched; take top 200 by population
                    for (int i = 0; i < major_cities.size && i < 200; i++) filtered.add(major_cities.get(i));
                }
                major_cities = filtered;
            } catch (GLib.Error e) { }
        } catch (GLib.Error e) {
            // best-effort only
        }
    }

    // Simple CSV parser that returns fields with quotes handled.
    // Handles fields enclosed in double-quotes where double-quotes inside
    // a field are escaped by doubling them ("" -> ").
    private Gee.ArrayList<string> parse_csv_line(string line) {
        Gee.ArrayList<string> out = new Gee.ArrayList<string>();
        StringBuilder cur = new StringBuilder();
        bool in_quotes = false;
        for (uint i = 0; i < (uint) line.length; i++) {
            char c = line[i];
            if (in_quotes) {
                if (c == '"') {
                    // Peek next char: if another quote, it's an escaped quote
                    if (i + 1 < (uint) line.length && line[i+1] == '"') {
                        cur.append_c('"');
                        i++; // skip the escaped quote
                    } else {
                        in_quotes = false;
                    }
                } else {
                    cur.append_c(c);
                }
            } else {
                if (c == '"') {
                    in_quotes = true;
                } else if (c == ',') {
                    out.add(cur.str);
                    cur = new StringBuilder();
                } else {
                    cur.append_c(c);
                }
            }
        }
        out.add(cur.str);
        return out;
    }

    // Case-insensitive ASCII equality (used for header detection).
    private bool ascii_equal_ci(string a, string b) {
        if (a == null || b == null) return false;
        string sa = a.strip();
        string sb = b.strip();
        if (sa.length != sb.length) return false;
        for (uint i = 0; i < (uint) sa.length; i++) {
            char ca = sa[i];
            char cb = sb[i];
            if (ca == cb) continue;
            if (ca >= 'A' && ca <= 'Z') ca = (char) (ca + 32);
            if (cb >= 'A' && cb <= 'Z') cb = (char) (cb + 32);
            if (ca != cb) return false;
        }
        return true;
    }

    // Synchronous lookup. Returns e.g. "San Francisco, California" or null.
    public string? lookup(string zip) {
        if (zip == null) return null;
        string s = zip.strip();
        // Extract first 5 digits by scanning (avoid relying on Regex API)
        StringBuilder digits_sb = new StringBuilder();
        for (uint i = 0; i < (uint) s.length; i++) {
            char c = s[i];
            if (c >= '0' && c <= '9') {
                digits_sb.append_c(c);
                if (digits_sb.len == 5) break;
            }
        }
        string digits = digits_sb.str;

        if (digits.length == 0) return null;

        // If we collected more than 5 digits (ZIP+4), normalize to 5-digit key
        if (digits.length > 5) digits = digits.substring(0, 5);

        try {
            // If we have a rich zip record for the requested ZIP, prefer
            // returning the nearest "major city" computed from the CSV
            // (population-weighted centroids). This matches rural ZIPs to
            // the closest large city rather than returning a small town.
            if (digits.length == 5 && zip_records.has_key(digits)) {
                ZipRecord? zr = zip_records.get(digits);
                if (zr != null && major_cities.size > 0) {
                    // Prefer larger metropolitan centers even when they are
                    // slightly farther away. Compute a simple score that
                    // divides distance by (1 + population_in_millions). This
                    // favors big cities (Dallas) over smaller nearby cities
                    // (e.g., Garland) when the population difference is large.
                    double best_score = -1.0;
                    MajorCity? best = null;
                    for (int i = 0; i < major_cities.size; i++) {
                        MajorCity mc = major_cities.get(i);
                        double d = haversine_km(zr.lat, zr.lng, mc.lat, mc.lng);
                        double pop_m = (double) mc.population / 1000000.0;
                        double score = d / (1.0 + pop_m);
                        if (best == null || score < best_score || (score == best_score && mc.population > best.population)) {
                            best = mc;
                            best_score = score;
                        }
                    }
                    if (best != null) return best.name;
                }
                // If we couldn't pick a major city, fall back to the simple map
                if (map.has_key(digits)) return map.get(digits);
            }

            // Fallback heuristic: try to find any mapping that shares a
            // common prefix with the requested ZIP. We try 3-digit,
            // then 2-digit, then 1-digit prefixes. This provides a
            // reasonable nearby-city heuristic when an exact ZIP isn't
            // available in the local CSV.
            for (int prefix_len = 3; prefix_len >= 1; prefix_len--) {
                if ((uint) prefix_len > digits.length) continue;
                string prefix = digits.substring(0, prefix_len);
                foreach (string key in keys) {
                    if ((uint) key.length >= (uint) prefix_len) {
                        if (key.substring(0, prefix_len) == prefix) return map.get(key);
                    }
                }
            }
        } catch (GLib.Error e) { }

        return null;
    }

    // Async wrapper: runs lookup in a background thread and invokes
    // the provided callback on the main loop when complete. This
    // prevents the UI from blocking if CSV loading or a large search
    // happens during a lookup.
    public void lookup_async(string zip, LookupCallback cb) {
        new Thread<void*>("zip-lookup", () => {
            // Ensure data is loaded on the worker thread; this will
            // perform the potentially-heavy CSV parse off the main
            // loop if it hasn't been run yet.
            try { ensure_loaded_sync(); } catch (GLib.Error e) { }

            string? res = null;
            try {
                res = lookup(zip);
            } catch (GLib.Error e) {
                res = null;
            }
            // Call callback on main loop; pass empty string when no result.
            string result_str = res != null ? res : "";
            Idle.add(() => {
                try { cb(result_str); } catch (GLib.Error e) { }
                return false;
            });
            return null;
        });
    }

    // Haversine distance in kilometers between two lat/lng points
    private double haversine_km(double lat1, double lon1, double lat2, double lon2) {
        const double R = 6371.0; // Earth radius km
        double to_rad = 3.14159265358979323846 / 180.0;
        double dlat = (lat2 - lat1) * to_rad;
        double dlon = (lon2 - lon1) * to_rad;
        double a = Math.sin(dlat/2.0) * Math.sin(dlat/2.0) + Math.cos(lat1*to_rad) * Math.cos(lat2*to_rad) * Math.sin(dlon/2.0) * Math.sin(dlon/2.0);
        double c = 2.0 * Math.atan2(Math.sqrt(a), Math.sqrt(1.0 - a));
        return R * c;
    }

    // Return up to `limit` city suggestions that start with `prefix` (case-insensitive ASCII).
    public Gee.ArrayList<string> suggest_cities(string prefix, int limit) {
        var out = new Gee.ArrayList<string>();
        if (prefix == null) return out;
        string p = prefix.strip();
        if (p.length == 0) return out;
        for (int i = 0; i < cities.size; i++) {
            if (out.size >= limit) break;
            string cand = cities.get(i);
            // Case-insensitive ASCII prefix compare
            if (cand.length < p.length) continue;
            bool match = true;
            for (uint j = 0; j < (uint) p.length; j++) {
                char a = cand[j];
                char b = p[j];
                if (a >= 'A' && a <= 'Z') a = (char) (a + 32);
                if (b >= 'A' && b <= 'Z') b = (char) (b + 32);
                if (a != b) { match = false; break; }
            }
            if (match) out.add(cand);
        }
        return out;
    }
}
