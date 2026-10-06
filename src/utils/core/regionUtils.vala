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

// The user's country and language, read from the system. Time zone
// detection based on djairjr's PR #65.
//
// Country comes from the time zone first: plenty of non-US users keep an
// en_US locale, but their zone ("Europe/Berlin") still says where they are.
// Read once and cached; safe to call from worker threads.
public class RegionUtils {
    private const string FALLBACK_COUNTRY = "US";
    private const string FALLBACK_LANGUAGE = "en";

    private static GLib.Mutex mutex;
    private static bool loaded;
    private static string? country_code;
    private static string? language_code;

    // Two-letter country code, upper-case (e.g. "DE"). Never empty.
    public static string country() {
        ensure_loaded();
        return country_code ?? FALLBACK_COUNTRY;
    }

    // Two- or three-letter language code, lower-case (e.g. "de"). Never empty.
    public static string language() {
        ensure_loaded();
        return language_code ?? FALLBACK_LANGUAGE;
    }

    private static void ensure_loaded() {
        mutex.lock();
        if (!loaded) {
            country_code = country_from_zone(new GLib.TimeZone.local().get_identifier())
                ?? locale_part(new string[] { "LC_ALL", "LC_TIME", "LC_MEASUREMENT", "LANG" }, true);
            language_code = locale_part(new string[] { "LC_ALL", "LC_MESSAGES", "LANG" }, false);
            loaded = true;
        }
        mutex.unlock();
    }

    // tzdata's zone.tab maps each zone id (3rd column) to its country
    // (1st column). Null for zones with no country, like "UTC".
    private static string? country_from_zone(string? zone) {
        if (zone == null || zone.length == 0) return null;
        string contents;
        try {
            if (!GLib.FileUtils.get_contents("/usr/share/zoneinfo/zone.tab", out contents)) return null;
        } catch (GLib.Error e) {
            return null;
        }
        foreach (string line in contents.split("\n")) {
            if (line.has_prefix("#")) continue;
            string[] fields = line.split("\t");
            if (fields.length >= 3 && fields[2].strip() == zone && fields[0].length == 2) {
                return fields[0].up();
            }
        }
        return null;
    }

    // The language ("pt") or country ("BR") part of the first of `variables`
    // that names one - "pt_BR.UTF-8@euro". Skips "C"/"POSIX", which LC_ALL
    // often is while LANG still holds the real locale.
    private static string? locale_part(string[] variables, bool want_country) {
        foreach (string variable in variables) {
            string? value = GLib.Environment.get_variable(variable);
            if (value == null) continue;
            string name = value.split(".")[0].split("@")[0];
            if (name.length == 0 || name == "C" || name == "POSIX") continue;
            string[] parts = name.split("_");
            if (!want_country) return parts[0].down();
            if (parts.length >= 2 && parts[1].length == 2) return parts[1].up();
        }
        return null;
    }
}
