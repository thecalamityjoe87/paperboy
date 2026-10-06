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

public enum NewsSource {
    BBC,
    GUARDIAN,
    NEW_YORK_TIMES,
    WALL_STREET_JOURNAL,
    BLOOMBERG,
    ABC_NEWS,
    NPR,
    FOX,
    PBS,
    UNKNOWN
}

public class NewsService {
    public static void fetch(
        NewsSource source,
        string current_category,
        string current_search_query,
        Soup.Session session,
        FetchSink sink
    ) {
        // Special handling for Paperboy API (frontpage and topten)
        if (current_category == "frontpage" || current_category == "topten") {
            var paperboy_fetcher = new PaperboyFetcher(sink);
            paperboy_fetcher.fetch(current_category, current_search_query, session);
            return;
        }

        // Outside the US the "us" category is national news, fetched once by
        // the caller via fetch_google_news() rather than once per outlet.
        if (current_category == "us" && !GoogleNewsUtils.is_us_edition()) return;

        // Each fetcher fetches nothing for a category it has no feed for
        BaseFetcher? fetcher = null;

        switch (source) {
            case NewsSource.GUARDIAN:
                fetcher = new GuardianFetcher(sink);
                break;
            case NewsSource.WALL_STREET_JOURNAL:
                fetcher = new WsjFetcher(sink);
                break;
            case NewsSource.BBC:
                fetcher = new BbcFetcher(sink);
                break;
            case NewsSource.NEW_YORK_TIMES:
                fetcher = new NytFetcher(sink);
                break;
            case NewsSource.BLOOMBERG:
                fetcher = new BloombergFetcher(sink);
                break;
            case NewsSource.ABC_NEWS:
                fetcher = new AbcNewsFetcher(sink);
                break;
            case NewsSource.NPR:
                fetcher = new NprFetcher(sink);
                break;
            case NewsSource.FOX:
                fetcher = new FoxFetcher(sink);
                break;
            case NewsSource.PBS:
                fetcher = new PbsFetcher(sink);
                break;
        }

        if (fetcher != null) {
            fetcher.fetch(current_category, current_search_query, session);
        }
    }

    // Outside US English the built-in outlets only have English, mostly
    // American and British feeds, so a category also gets the edition's
    // Google News section for it - for a non-US edition's "us" category,
    // its national headlines, which the per-source fetch() calls skip.
    public static bool has_google_news(string category) {
        return !GoogleNewsUtils.is_us_english() && GoogleNewsUtils.category_feed_url(category) != null;
    }

    // Call once per category fetch, alongside the per-source fetch() calls.
    // Fetches nothing where has_google_news() is false.
    public static void fetch_google_news(string category, string current_search_query, Soup.Session session, FetchSink sink) {
        if (!has_google_news(category)) return;
        RssFeedProcessor.fetch_rss_url(GoogleNewsUtils.category_feed_url(category), GoogleNewsUtils.AGGREGATOR_NAME,
            FetcherUtils.category_display_name(category), category, current_search_query, session, sink);
    }
}
