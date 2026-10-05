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

public struct GoogleNewsEdition {
    public string ceid;    // "BR:pt-419" - country, then Google's language tag
    public string hl;      // "pt-BR"
    public string name;    // "Brazil", or "Canada (French)" where a country has several
}

// The Google News edition every Google News request uses, picked from the
// user's region (see RegionUtils). Single place to change it - each request
// used to hardcode en-US/US.
public class GoogleNewsUtils {
    public const string SEARCH_URL = "https://news.google.com/rss/search";
    public const string TOPIC_URL = "https://news.google.com/rss/headlines/section/topic/";
    // Source name for Google's own aggregated feeds; their items each carry
    // a <source>, which RssFeedProcessor uses instead.
    public const string AGGREGATOR_NAME = "Google News";

    // Editions Google actually serves - anything else silently redirects to
    // the US one. Each country's main edition comes first: it's used when
    // the user's language has no edition there.
    public const GoogleNewsEdition[] EDITIONS = {
        { "US:en", "en-US", "United States" }, { "US:es-419", "es-419", "United States (Spanish)" },
        { "GB:en", "en-GB", "United Kingdom" }, { "IE:en", "en-IE", "Ireland" },
        { "CA:en", "en-CA", "Canada (English)" }, { "CA:fr", "fr-CA", "Canada (French)" },
        { "AU:en", "en-AU", "Australia" }, { "NZ:en", "en-NZ", "New Zealand" },
        { "IN:en", "en-IN", "India (English)" }, { "IN:hi", "hi", "India (Hindi)" }, { "IN:bn", "bn", "India (Bengali)" }, { "IN:mr", "mr", "India (Marathi)" },
        { "IN:ta", "ta", "India (Tamil)" }, { "IN:te", "te", "India (Telugu)" }, { "IN:ml", "ml", "India (Malayalam)" }, { "IN:gu", "gu-IN", "India (Gujarati)" },
        { "PK:en", "en-PK", "Pakistan" }, { "BD:bn", "bn", "Bangladesh" },
        { "SG:en", "en-SG", "Singapore" }, { "MY:en", "en-MY", "Malaysia (English)" }, { "MY:ms", "ms-MY", "Malaysia (Malay)" },
        { "PH:en", "en-PH", "Philippines" }, { "ID:id", "id", "Indonesia (Indonesian)" }, { "ID:en", "en-ID", "Indonesia (English)" },
        { "ZA:en", "en-ZA", "South Africa" }, { "NG:en", "en-NG", "Nigeria" }, { "KE:en", "en-KE", "Kenya" }, { "GH:en", "en-GH", "Ghana" },
        { "UG:en", "en-UG", "Uganda" }, { "TZ:en", "en-TZ", "Tanzania" }, { "ET:en", "en-ET", "Ethiopia" }, { "ZW:en", "en-ZW", "Zimbabwe" },
        { "NA:en", "en-NA", "Namibia" }, { "BW:en", "en-BW", "Botswana" },
        { "IL:he", "he", "Israel (Hebrew)" }, { "IL:en", "en-IL", "Israel (English)" },
        { "EG:ar", "ar", "Egypt" }, { "SA:ar", "ar", "Saudi Arabia" }, { "AE:ar", "ar", "United Arab Emirates" }, { "LB:ar", "ar", "Lebanon" },
        { "MA:fr", "fr", "Morocco" }, { "SN:fr", "fr", "Senegal" },
        { "BR:pt-419", "pt-BR", "Brazil" }, { "PT:pt-150", "pt-PT", "Portugal" },
        { "MX:es-419", "es-419", "Mexico" }, { "AR:es-419", "es-419", "Argentina" }, { "CL:es-419", "es-419", "Chile" },
        { "CO:es-419", "es-419", "Colombia" }, { "PE:es-419", "es-419", "Peru" }, { "VE:es-419", "es-419", "Venezuela" },
        { "CU:es-419", "es-419", "Cuba" },
        { "ES:es", "es", "Spain" }, { "FR:fr", "fr", "France" }, { "IT:it", "it", "Italy" },
        { "DE:de", "de", "Germany" }, { "AT:de", "de", "Austria" }, { "CH:de", "de", "Switzerland (German)" }, { "CH:fr", "fr", "Switzerland (French)" },
        { "NL:nl", "nl", "Netherlands" }, { "BE:nl", "nl", "Belgium (Dutch)" }, { "BE:fr", "fr", "Belgium (French)" },
        { "SE:sv", "sv", "Sweden" }, { "NO:no", "no", "Norway" }, { "FI:fi", "fi-FI", "Finland" },
        { "PL:pl", "pl", "Poland" }, { "CZ:cs", "cs", "Czechia" }, { "SK:sk", "sk", "Slovakia" }, { "HU:hu", "hu", "Hungary" },
        { "RO:ro", "ro", "Romania" }, { "BG:bg", "bg", "Bulgaria" }, { "GR:el", "el", "Greece" }, { "SI:sl", "sl", "Slovenia" },
        { "RS:sr", "sr", "Serbia" }, { "LT:lt", "lt", "Lithuania" }, { "LV:lv", "lv", "Latvia" }, { "EE:et", "et-EE", "Estonia" },
        { "UA:uk", "uk", "Ukraine (Ukrainian)" }, { "UA:ru", "ru", "Ukraine (Russian)" }, { "RU:ru", "ru", "Russia" }, { "TR:tr", "tr", "Turkey" },
        { "CN:zh-Hans", "zh-CN", "China" }, { "TW:zh-Hant", "zh-TW", "Taiwan" }, { "HK:zh-Hant", "zh-HK", "Hong Kong" },
        { "JP:ja", "ja", "Japan" }, { "KR:ko", "ko", "South Korea" }, { "TH:th", "th", "Thailand" }, { "VN:vi", "vi", "Vietnam" }
    };

    private static GLib.Mutex mutex;
    private static string? chosen_ceid;

    // The edition picked in Preferences ("DE:de"), or "" to follow the
    // system. Set by NewsPreferences; requests read it from any thread.
    public static void set_chosen(string ceid) {
        mutex.lock();
        chosen_ceid = ceid;
        mutex.unlock();
    }

    // Two-letter country code, e.g. "US", "IN", "DE".
    public static string country() {
        return country_of(edition());
    }

    // Language code as Google spells it in hl=, e.g. "en-US", "de".
    public static string language() {
        return edition().hl;
    }

    // The edition id, e.g. "US:en" - used as ceid= and by the URL resolver.
    public static string ceid() {
        return edition().ceid;
    }

    // "hl=en-US&gl=US&ceid=US:en"
    public static string edition_params() {
        var e = edition();
        return "hl=%s&gl=%s&ceid=%s".printf(e.hl, country_of(e), e.ceid);
    }

    // RSS search URL for `query` (unescaped) in the current edition.
    public static string search_url(string query) {
        return SEARCH_URL + "?q=" + Uri.escape_string(query, null, false) + "&" + edition_params();
    }

    // National headlines for the edition's country.
    public static string national_url() {
        return topic_url("NATION");
    }

    // One Google News section for the edition: "WORLD", "NATION", "BUSINESS",
    // "TECHNOLOGY", "SCIENCE", "HEALTH", "SPORTS" or "ENTERTAINMENT".
    public static string topic_url(string topic) {
        return TOPIC_URL + topic + "?" + edition_params();
    }

    // Google News' top stories for the edition (news.google.com's own front page).
    public static string top_stories_url() {
        return "https://news.google.com/rss?" + edition_params();
    }

    // The original edition, which the Paperboy backend serves as it always has.
    public static bool is_us_english() {
        return ceid() == "US:en";
    }

    // Query for the backend's country-aware endpoints (/news/frontpage,
    // /news/headlines): "?location=br&lang=pt", or "" for US English so its
    // URLs stay exactly as they were.
    public static string backend_region_query() {
        if (is_us_english()) return "";
        string id = ceid();
        int colon = id.index_of(":");
        string lang = id.substring(colon + 1).split("-")[0];
        return "?location=%s&lang=%s".printf(id.substring(0, colon).down(), lang);
    }

    // The "us" category comes from the built-in outlets' US sections in a
    // US edition, and from Google's national feed (national_url) elsewhere.
    public static bool is_us_edition() {
        return country() == "US";
    }

    // "US News", "Germany News", "Canada News" (the suffix is translated).
    public static string national_label() {
        if (is_us_edition()) return _("US News");
        return _("%s News").printf(localized_country_name());
    }

    // The country named in the user's language, from the system's iso-codes
    // catalogs (domain "iso_3166-1", msgid = the English name -> the localized
    // one). Falls back to the English name if iso-codes is not installed.
    public static string localized_country_name() {
        string english = country_name();
        string localized = GLib.dgettext("iso_3166-1", english);
        return (localized != null && localized.length > 0) ? localized : english;
    }

    // The edition's country without its language: "Canada", not "Canada (French)".
    public static string country_name() {
        string name = edition().name;
        int paren = name.index_of(" (");
        return paren > 0 ? name.substring(0, paren) : name;
    }

    // The chosen edition, or the automatic one if none was chosen.
    public static GoogleNewsEdition edition() {
        mutex.lock();
        string? chosen = chosen_ceid;
        mutex.unlock();
        if (chosen != null && chosen.length > 0) {
            foreach (unowned GoogleNewsEdition e in EDITIONS) {
                if (e.ceid == chosen) return e;
            }
        }
        return automatic_edition();
    }

    // The user's country in their language if Google has that edition,
    // else the country's main edition, else US English.
    public static GoogleNewsEdition automatic_edition() {
        string prefix = RegionUtils.country() + ":";
        string lang = RegionUtils.language();
        if (lang == "nb" || lang == "nn") lang = "no";

        GoogleNewsEdition? main_edition = null;
        foreach (unowned GoogleNewsEdition e in EDITIONS) {
            if (!e.ceid.has_prefix(prefix)) continue;
            string edition_lang = e.ceid.substring(prefix.length).split("-")[0];
            if (edition_lang == lang) return e;
            if (main_edition == null) main_edition = e;
        }
        return main_edition ?? EDITIONS[0];
    }

    private static string country_of(GoogleNewsEdition e) {
        return e.ceid.substring(0, e.ceid.index_of(":"));
    }
}
