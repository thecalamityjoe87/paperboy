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
    REDDIT,
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
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        // Special handling for Paperboy API (frontpage and topten)
        if (current_category == "frontpage" || current_category == "topten") {
            var paperboy_fetcher = new PaperboyFetcher(set_label, clear_items, add_item);
            paperboy_fetcher.fetch(current_category, current_search_query, session);
            return;
        }

        // Don't let a source fetch (and mistag) content for a category it
        // doesn't actually cover, e.g. PBS falling back to World News for
        // "sports" - callers that already pre-filter via supports_category()
        // (the multi-source path) just get a redundant true here.
        if (!supports_category(source, current_category)) {
            return;
        }

        BaseFetcher? fetcher = null;

        switch (source) {
            case NewsSource.GUARDIAN:
                fetcher = new GuardianFetcher(set_label, clear_items, add_item);
                break;
            case NewsSource.WALL_STREET_JOURNAL:
                fetcher = new WsjFetcher(set_label, clear_items, add_item);
                break;
            case NewsSource.REDDIT:
                fetcher = new RedditFetcher(set_label, clear_items, add_item);
                break;
            case NewsSource.BBC:
                fetcher = new BbcFetcher(set_label, clear_items, add_item);
                break;
            case NewsSource.NEW_YORK_TIMES:
                fetcher = new NytFetcher(set_label, clear_items, add_item);
                break;
            case NewsSource.BLOOMBERG:
                fetcher = new BloombergFetcher(set_label, clear_items, add_item);
                break;
            case NewsSource.ABC_NEWS:
                fetcher = new AbcNewsFetcher(set_label, clear_items, add_item);
                break;
            case NewsSource.NPR:
                fetcher = new NprFetcher(set_label, clear_items, add_item);
                break;
            case NewsSource.FOX:
                fetcher = new FoxFetcher(set_label, clear_items, add_item);
                break;
            case NewsSource.PBS:
                fetcher = new PbsFetcher(set_label, clear_items, add_item);
                break;
        }

        if (fetcher != null) {
            fetcher.fetch(current_category, current_search_query, session);
        }
    }

    public static string get_source_name(NewsSource source) {
        switch (source) {
            case NewsSource.GUARDIAN:
                return "The Guardian";
            case NewsSource.WALL_STREET_JOURNAL:
                return "Wall Street Journal";
            case NewsSource.BBC:
                return "BBC News";
            case NewsSource.REDDIT:
                return "Reddit";
            case NewsSource.NEW_YORK_TIMES:
                return "New York Times";
            case NewsSource.BLOOMBERG:
                return "Bloomberg";
            case NewsSource.ABC_NEWS:
                return "ABC News";
            case NewsSource.NPR:
                return "NPR";
            case NewsSource.FOX:
                return "Fox News";
            case NewsSource.PBS:
                return "PBS NewsHour";
            default:
                return "News";
        }
    }

    public static bool supports_category(NewsSource source, string category) {
        // BBC, Reddit, and ABC News do not provide dedicated "lifestyle" content
        if (source == NewsSource.BBC || source == NewsSource.REDDIT || source == NewsSource.ABC_NEWS) {
            if (category == "lifestyle") return false;
        }

        // Bloomberg only supports specific categories
        if (source == NewsSource.BLOOMBERG) {
            switch (category) {
                case "markets":
                case "industries":
                case "economics":
                case "politics":
                case "technology":
                    return true;
                default:
                    return false;
            }
        }

        // PBS NewsHour has no technology, sports, or lifestyle desk -
        // PbsFetcher falls back to World News for those, which would be
        // confusing to show under those category labels specifically.
        if (source == NewsSource.PBS) {
            switch (category) {
                case "technology":
                case "sports":
                case "lifestyle":
                    return false;
                default:
                    return true;
            }
        }
        return true;
    }
}
