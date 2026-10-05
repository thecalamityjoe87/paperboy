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
    public string name;    // "Brazil", or "Canada (French)" where a country has several;
                           // untranslated - show it with _(name)
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
    // TRANSLATORS: country names in the news edition picker. Where a country
    // has several editions, keep the "Country (Language)" form - the app
    // splits the country off at the parenthesis.
    public const GoogleNewsEdition[] EDITIONS = {
        { "US:en", "en-US", N_("United States") }, { "US:es-419", "es-419", N_("United States (Spanish)") },
        { "GB:en", "en-GB", N_("United Kingdom") }, { "IE:en", "en-IE", N_("Ireland") },
        { "CA:en", "en-CA", N_("Canada (English)") }, { "CA:fr", "fr-CA", N_("Canada (French)") },
        { "AU:en", "en-AU", N_("Australia") }, { "NZ:en", "en-NZ", N_("New Zealand") },
        { "IN:en", "en-IN", N_("India (English)") }, { "IN:hi", "hi", N_("India (Hindi)") }, { "IN:bn", "bn", N_("India (Bengali)") }, { "IN:mr", "mr", N_("India (Marathi)") },
        { "IN:ta", "ta", N_("India (Tamil)") }, { "IN:te", "te", N_("India (Telugu)") }, { "IN:ml", "ml", N_("India (Malayalam)") }, { "IN:gu", "gu-IN", N_("India (Gujarati)") },
        { "PK:en", "en-PK", N_("Pakistan") }, { "BD:bn", "bn", N_("Bangladesh") },
        { "SG:en", "en-SG", N_("Singapore") }, { "MY:en", "en-MY", N_("Malaysia (English)") }, { "MY:ms", "ms-MY", N_("Malaysia (Malay)") },
        { "PH:en", "en-PH", N_("Philippines") }, { "ID:id", "id", N_("Indonesia (Indonesian)") }, { "ID:en", "en-ID", N_("Indonesia (English)") },
        { "ZA:en", "en-ZA", N_("South Africa") }, { "NG:en", "en-NG", N_("Nigeria") }, { "KE:en", "en-KE", N_("Kenya") }, { "GH:en", "en-GH", N_("Ghana") },
        { "UG:en", "en-UG", N_("Uganda") }, { "TZ:en", "en-TZ", N_("Tanzania") }, { "ET:en", "en-ET", N_("Ethiopia") }, { "ZW:en", "en-ZW", N_("Zimbabwe") },
        { "NA:en", "en-NA", N_("Namibia") }, { "BW:en", "en-BW", N_("Botswana") },
        { "IL:he", "he", N_("Israel (Hebrew)") }, { "IL:en", "en-IL", N_("Israel (English)") },
        { "EG:ar", "ar", N_("Egypt") }, { "SA:ar", "ar", N_("Saudi Arabia") }, { "AE:ar", "ar", N_("United Arab Emirates") }, { "LB:ar", "ar", N_("Lebanon") },
        { "MA:fr", "fr", N_("Morocco") }, { "SN:fr", "fr", N_("Senegal") },
        { "BR:pt-419", "pt-BR", N_("Brazil") }, { "PT:pt-150", "pt-PT", N_("Portugal") },
        { "MX:es-419", "es-419", N_("Mexico") }, { "AR:es-419", "es-419", N_("Argentina") }, { "CL:es-419", "es-419", N_("Chile") },
        { "CO:es-419", "es-419", N_("Colombia") }, { "PE:es-419", "es-419", N_("Peru") }, { "VE:es-419", "es-419", N_("Venezuela") },
        { "CU:es-419", "es-419", N_("Cuba") },
        { "ES:es", "es", N_("Spain") }, { "FR:fr", "fr", N_("France") }, { "IT:it", "it", N_("Italy") },
        { "DE:de", "de", N_("Germany") }, { "AT:de", "de", N_("Austria") }, { "CH:de", "de", N_("Switzerland (German)") }, { "CH:fr", "fr", N_("Switzerland (French)") },
        { "NL:nl", "nl", N_("Netherlands") }, { "BE:nl", "nl", N_("Belgium (Dutch)") }, { "BE:fr", "fr", N_("Belgium (French)") },
        { "SE:sv", "sv", N_("Sweden") }, { "NO:no", "no", N_("Norway") }, { "FI:fi", "fi-FI", N_("Finland") },
        { "PL:pl", "pl", N_("Poland") }, { "CZ:cs", "cs", N_("Czechia") }, { "SK:sk", "sk", N_("Slovakia") }, { "HU:hu", "hu", N_("Hungary") },
        { "RO:ro", "ro", N_("Romania") }, { "BG:bg", "bg", N_("Bulgaria") }, { "GR:el", "el", N_("Greece") }, { "SI:sl", "sl", N_("Slovenia") },
        { "RS:sr", "sr", N_("Serbia") }, { "LT:lt", "lt", N_("Lithuania") }, { "LV:lv", "lv", N_("Latvia") }, { "EE:et", "et-EE", N_("Estonia") },
        { "UA:uk", "uk", N_("Ukraine (Ukrainian)") }, { "UA:ru", "ru", N_("Ukraine (Russian)") }, { "RU:ru", "ru", N_("Russia") }, { "TR:tr", "tr", N_("Turkey") },
        { "CN:zh-Hans", "zh-CN", N_("China") }, { "TW:zh-Hant", "zh-TW", N_("Taiwan") }, { "HK:zh-Hant", "zh-HK", N_("Hong Kong") },
        { "JP:ja", "ja", N_("Japan") }, { "KR:ko", "ko", N_("South Korea") }, { "TH:th", "th", N_("Thailand") }, { "VN:vi", "vi", N_("Vietnam") }
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
        return params_of(edition());
    }

    // RSS search URL for `query` (unescaped) in the current edition.
    public static string search_url(string query) {
        return search_url_in(query, edition());
    }

    // RSS search URL for `query` in a fixed edition, whatever the user picked -
    // e.g. a US outlet's site: search, which other editions mostly drop.
    public static string search_url_in(string query, GoogleNewsEdition e) {
        return SEARCH_URL + "?q=" + Uri.escape_string(query, null, false) + "&" + params_of(e);
    }

    // The US English edition, Google News' default.
    public static GoogleNewsEdition us_edition() {
        return EDITIONS[0];
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

    // The edition's Google News section for an app category ("us" is the
    // national one), or null for a category Google has no section for
    // (politics, lifestyle, markets, ...).
    public static string? category_feed_url(string category) {
        switch (category) {
            case "us": return national_url();
            case "general": return topic_url("WORLD");
            case "business": return topic_url("BUSINESS");
            case "technology": return topic_url("TECHNOLOGY");
            case "science": return topic_url("SCIENCE");
            case "health": return topic_url("HEALTH");
            case "sports": return topic_url("SPORTS");
            case "entertainment": return topic_url("ENTERTAINMENT");
            default: return null;
        }
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

    // "US News", "Germany News", "Canada News".
    public static string national_label() {
        // TRANSLATORS: %s is a country or a city, e.g. "Germany News", "Dallas News"
        return is_us_edition() ? _("US News") : _("%s News").printf(country_name());
    }

    // The edition's country without its language, translated: "Canada",
    // not "Canada (French)".
    public static string country_name() {
        string name = _(edition().name);
        // Chinese and Japanese translations may use a full-width parenthesis
        int paren = name.index_of("(");
        int wide = name.index_of("（");
        if (wide > 0 && (paren < 0 || wide < paren)) paren = wide;
        return paren > 0 ? name.substring(0, paren).strip() : name;
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

    private static string params_of(GoogleNewsEdition e) {
        return "hl=%s&gl=%s&ceid=%s".printf(e.hl, country_of(e), e.ceid);
    }

    private static string country_of(GoogleNewsEdition e) {
        return e.ceid.substring(0, e.ceid.index_of(":"));
    }
}
