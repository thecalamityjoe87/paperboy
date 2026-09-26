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
 * A small bundled list of standalone major US metro anchor cities (large
 * satellite suburbs of an already-listed metro, e.g. Garland/Irving/Plano
 * relative to Dallas, are deliberately excluded so they don't outrank the
 * metro's actual namesake city), plus a handful of state capitals/regional
 * hubs added to fill in sparsely-populated states, with approximate
 * coordinates. Used to find the nearest big metropolitan area to a
 * resolved ZIP/city location — Local News gets a better search term than
 * a small town's name, which Google News' RSS search often has little or
 * no dedicated coverage for.
 *
 * Intentionally tiny (a few hundred entries) rather than an exhaustive
 * gazetteer — "nearest major metro within reason" is enough for this
 * purpose and keeps the list cheap to bundle and search linearly.
 */
public class MajorCitiesUtils {
    // Populated lazily by ensure_loaded() on first use rather than as
    // field initializers: Vala only runs class-level static field
    // initializers inside class_init, which requires the class to be
    // instantiated — this class is only ever used via static methods and
    // is never instantiated, so field initializers here would silently
    // never run, leaving these arrays permanently empty.
    private static string[]? CITY_NAMES = null;
    private static double[]? CITY_LATS = null;
    private static double[]? CITY_LONS = null;

    private static void ensure_loaded() {
        if (CITY_NAMES != null) return;

        CITY_NAMES = {
        "New York, NY", "Los Angeles, CA", "Chicago, IL", "Houston, TX", "Phoenix, AZ",
        "Philadelphia, PA", "San Antonio, TX", "San Diego, CA", "Dallas, TX", "Austin, TX",
        "Jacksonville, FL", "Fort Worth, TX", "San Jose, CA", "Columbus, OH", "Charlotte, NC",
        "Indianapolis, IN", "San Francisco, CA", "Seattle, WA", "Denver, CO", "Oklahoma City, OK",
        "Nashville, TN", "El Paso, TX", "Washington, DC", "Boston, MA", "Las Vegas, NV",
        "Portland, OR", "Detroit, MI", "Louisville, KY", "Memphis, TN", "Baltimore, MD",
        "Milwaukee, WI", "Albuquerque, NM", "Tucson, AZ", "Fresno, CA", "Sacramento, CA",
        "Kansas City, MO", "Atlanta, GA", "Omaha, NE", "Colorado Springs, CO", "Raleigh, NC",
        "Miami, FL", "Virginia Beach, VA", "Minneapolis, MN", "Tulsa, OK", "Tampa, FL",
        "New Orleans, LA", "Wichita, KS", "Cleveland, OH", "Bakersfield, CA", "Honolulu, HI",
        "Riverside, CA", "Corpus Christi, TX", "Lexington, KY", "Saint Paul, MN", "St. Louis, MO",
        "Cincinnati, OH", "Pittsburgh, PA", "Greensboro, NC", "Anchorage, AK", "Lincoln, NE",
        "Orlando, FL", "Toledo, OH", "Durham, NC", "Fort Wayne, IN", "Laredo, TX",
        "Madison, WI", "Buffalo, NY", "Lubbock, TX", "Reno, NV", "Winston-Salem, NC",
        "Norfolk, VA", "Chesapeake, VA", "Hialeah, FL", "Boise, ID", "Richmond, VA",
        "Baton Rouge, LA", "Spokane, WA", "Des Moines, IA", "Tacoma, WA", "Fayetteville, NC",
        "Rochester, NY", "Little Rock, AR", "Grand Rapids, MI", "Salt Lake City, UT", "Huntsville, AL",
        "Providence, RI", "Knoxville, TN", "Worcester, MA", "Newport News, VA", "Brownsville, TX",
        "Overland Park, KS", "Tempe, AZ",
        // State capitals / regional hubs added to fill in sparsely-populated states
        "Charleston, WV", "Cheyenne, WY", "Helena, MT", "Billings, MT", "Bismarck, ND",
        "Fargo, ND", "Sioux Falls, SD", "Pierre, SD", "Jackson, MS", "Montgomery, AL",
        "Columbia, SC", "Hartford, CT", "Burlington, VT", "Portland, ME", "Manchester, NH",
        "Wilmington, DE", "Fairbanks, AK"
        };

        CITY_LATS = {
        40.7128, 34.0522, 41.8781, 29.7604, 33.4484,
        39.9526, 29.4241, 32.7157, 32.7767, 30.2672,
        30.3322, 32.7555, 37.3382, 39.9612, 35.2271,
        39.7684, 37.7749, 47.6062, 39.7392, 35.4676,
        36.1627, 31.7619, 38.9072, 42.3601, 36.1699,
        45.5051, 42.3314, 38.2527, 35.1495, 39.2904,
        43.0389, 35.0844, 32.2226, 36.7378, 38.5816,
        39.0997, 33.749, 41.2565, 38.8339, 35.7796,
        25.7617, 36.8529, 44.9778, 36.154, 27.9506,
        29.9511, 37.6872, 41.4993, 35.3733, 21.3069,
        33.9533, 27.8006, 38.0406, 44.9537, 38.627,
        39.1031, 40.4406, 36.0726, 61.2181, 40.8136,
        28.5383, 41.6528, 35.994, 41.0793, 27.5064,
        43.0731, 42.8864, 33.5779, 39.5296, 36.0999,
        36.8508, 36.7682, 25.8576, 43.615, 37.5407,
        30.4515, 47.6588, 41.5868, 47.2529, 35.0527,
        43.1566, 34.7465, 42.9634, 40.7608, 34.7304,
        41.824, 35.9606, 42.2626, 37.0871, 25.9017,
        38.9822, 33.4255,
        38.3498, 41.14, 46.5891, 45.7833, 46.8083,
        46.8772, 43.5446, 44.3683, 32.2988, 32.3792,
        34.0007, 41.7658, 44.4759, 43.6591, 42.9956,
        39.7391, 64.8378
        };

        CITY_LONS = {
        -74.006, -118.2437, -87.6298, -95.3698, -112.074,
        -75.1652, -98.4936, -117.1611, -96.797, -97.7431,
        -81.6557, -97.3308, -121.8863, -82.9988, -80.8431,
        -86.1581, -122.4194, -122.3321, -104.9903, -97.5164,
        -86.7816, -106.485, -77.0369, -71.0589, -115.1398,
        -122.675, -83.0458, -85.7585, -90.049, -76.6122,
        -87.9065, -106.6504, -110.9747, -119.7871, -121.4944,
        -94.5786, -84.388, -95.9345, -104.8214, -78.6382,
        -80.1918, -75.978, -93.265, -95.9928, -82.4572,
        -90.0715, -97.3301, -81.6944, -119.0187, -157.8583,
        -117.3962, -97.3964, -84.5037, -93.09, -90.1994,
        -84.512, -79.9959, -79.792, -149.9003, -96.7026,
        -81.3792, -83.5379, -78.8986, -85.1394, -99.5075,
        -89.4012, -78.8784, -101.8552, -119.8138, -80.2442,
        -76.2859, -76.2875, -80.2781, -116.2023, -77.436,
        -91.1871, -117.426, -93.625, -122.4443, -78.8784,
        -77.6088, -92.2896, -85.6681, -111.891, -86.5861,
        -71.4128, -83.9207, -71.8023, -76.473, -97.4975,
        -94.6708, -111.94,
        -81.6326, -104.8202, -112.0391, -108.5007, -100.7837,
        -96.7898, -96.7311, -100.351, -90.1848, -86.3077,
        -81.0348, -72.6734, -73.2121, -70.2568, -71.4548,
        -75.5398, -147.7164
        };
    }

    // Great-circle distance between two lat/lon points, in kilometers.
    private static double haversine_km(double lat1, double lon1, double lat2, double lon2) {
        const double earth_radius_km = 6371.0;
        double dlat = (lat2 - lat1) * Math.PI / 180.0;
        double dlon = (lon2 - lon1) * Math.PI / 180.0;
        double a = Math.sin(dlat / 2) * Math.sin(dlat / 2) +
            Math.cos(lat1 * Math.PI / 180.0) * Math.cos(lat2 * Math.PI / 180.0) *
            Math.sin(dlon / 2) * Math.sin(dlon / 2);
        double c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
        return earth_radius_km * c;
    }

    // Find the nearest bundled major city to (lat, lon). Returns "" if the
    // list is somehow empty (should not happen); `distance_km` receives
    // the distance to that city.
    public static string nearest(double lat, double lon, out double distance_km) {
        ensure_loaded();

        int best_idx = -1;
        double best_dist = double.MAX;
        for (int i = 0; i < CITY_NAMES.length; i++) {
            double d = haversine_km(lat, lon, CITY_LATS[i], CITY_LONS[i]);
            if (d < best_dist) {
                best_dist = d;
                best_idx = i;
            }
        }
        distance_km = best_idx >= 0 ? best_dist : 0.0;
        return best_idx >= 0 ? CITY_NAMES[best_idx] : "";
    }
}
