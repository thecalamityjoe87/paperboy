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

/*
 * Derives the user's region (country + language) from the system so that
 * region-dependent behaviour - the Google News edition, location lookup -
 * is a parameter instead of a hard-coded country. The country comes from
 * the system time zone via tzdata's zone.tab; the language comes from the
 * locale. Nothing here is tied to a specific country: "br" is the result
 * of the lookup on a Brazil-configured machine, not a constant.
 */
public class RegionUtils : GLib.Object {
    // Used when the zone or locale can't be resolved (the previous,
    // US-centric behaviour) - explicit and testable rather than a crash.
    private const string FALLBACK_LANG = "en";
    private const string FALLBACK_COUNTRY = "us";

    private static bool loaded = false;
    // Left null on purpose: a Vala field initialiser on a `string` does not
    // survive into the generated C (it becomes `static gchar* x = NULL`), so
    // ensure_loaded() is the single place that assigns them, and every
    // public getter falls back rather than trusting them.
    private static string? country_code = null;
    private static string? language_code = null;
    private static string? zone_id = null;

    private static void ensure_loaded() {
        if (loaded) return;
        loaded = true;

        zone_id = new GLib.TimeZone.local().get_identifier();

        string? cc = country_from_zone(zone_id);
        if (cc != null && cc.length == 2) country_code = cc.down();

        string? lang = language_from_locale();
        if (lang != null && lang.length > 0) language_code = lang.down();
        // else: the getters fall back to FALLBACK_*.
    }

    // ISO-3166 alpha-2 country code, lower-case (e.g. "br"). Never empty:
    // falls back to "us" when the zone yields no country, so a query built
    // from it is never malformed.
    public static string country() {
        ensure_loaded();
        if (country_code == null || country_code.length != 2) return FALLBACK_COUNTRY;
        return country_code;
    }

    // ISO-639 language code, lower-case (e.g. "pt"). Never empty: a locale
    // that names no language (unset, "C") falls back to "en", because an
    // empty code would produce a malformed Google News query.
    public static string language() {
        ensure_loaded();
        if (language_code == null || language_code.length == 0) return FALLBACK_LANG;
        return language_code;
    }

    // The system time-zone identifier (e.g. "America/Sao_Paulo"), or null.
    public static string? zone() {
        ensure_loaded();
        return zone_id;
    }

    // The hl/gl/ceid query suffix for Google News, built from the region -
    // e.g. language "pt" + country "br" -> "hl=pt-BR&gl=BR&ceid=BR:pt".
    public static string google_news_query_suffix() {
        return "hl=" + language() + "-" + country().up()
            + "&gl=" + country().up() + "&ceid=" + country().up() + ":" + language();
    }

    // Country from tzdata's zone.tab: the row whose zone id (3rd field)
    // matches; the 1st field is the ISO-3166 alpha-2 code. Null if absent.
    internal static string? country_from_zone(string? zone) {
        if (zone == null || zone.length == 0) return null;

        string contents;
        try {
            if (!GLib.FileUtils.get_contents("/usr/share/zoneinfo/zone.tab", out contents)) return null;
        } catch (GLib.Error e) {
            return null;
        }

        foreach (var raw in contents.split("\n")) {
            string line = raw.strip();
            if (line.length == 0 || line.has_prefix("#")) continue;
            string[] fields = line.split("\t");
            if (fields.length >= 3 && fields[2] == zone) return fields[0].strip();
        }
        return null;
    }

    // Language from the locale (LC_ALL/LC_MESSAGES/LANG), without the region
    // suffix - "pt_BR.UTF-8" -> "pt". Null when unset or in the C locale.
    internal static string? language_from_locale() {
        foreach (string variable in new string[] { "LC_ALL", "LC_MESSAGES", "LANG" }) {
            string? lang = language_from_locale_name(GLib.Environment.get_variable(variable));
            // Keep looking: LC_ALL is often "C" or "POSIX" while LANG still
            // carries a real language, and stopping at the first non-empty
            // value would drop it.
            if (lang != null) return lang;
        }
        return null;
    }

    // The ISO-639 part of one locale name, or null when it names no
    // language: unset, "C", "POSIX", or empty. "pt_BR.UTF-8" -> "pt".
    private static string? language_from_locale_name(string? locale) {
        if (locale == null || locale.length == 0) return null;

        string loc = locale.split(".")[0];    // strip ".UTF-8"
        loc = loc.split("@")[0];              // strip "@modifier"
        string lang = loc.split("_")[0];      // strip "_BR"
        if (lang.length == 0 || lang == "C" || lang == "POSIX") return null;
        return lang;
    }
}
