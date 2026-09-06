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
using Soup;
using Tools;

public class AbcNewsFetcher : BaseFetcher {
    public AbcNewsFetcher(SetLabelFunc set_label_func, ClearItemsFunc clear_items_func, AddItemFunc add_item_func) {
        base(set_label_func, clear_items_func, add_item_func);
    }

    public override void fetch(string category, string search_query, Soup.Session session) {
        string url = "https://abcnews.go.com/abcnews/internationalheadlines";

        switch (category) {
            case "us":
                url = "https://abcnews.go.com/abcnews/usheadlines";
                break;
            case "technology":
                url = "https://abcnews.go.com/abcnews/technologyheadlines";
                break;
            case "business":
                url = "https://abcnews.go.com/abcnews/moneyheadlines";
                break;
            case "sports":
                url = "https://abcnews.go.com/abcnews/sportsheadlines";
                break;
            case "health":
                url = "https://abcnews.go.com/abcnews/healthheadlines";
                break;
            case "entertainment":
                url = "https://abcnews.go.com/abcnews/entertainmentheadlines";
                break;
            case "politics":
                url = "https://abcnews.go.com/abcnews/politicsheadlines";
                break;
            default:
                url = "https://abcnews.go.com/abcnews/internationalheadlines";
                break;
        }

        RssFeedProcessor.fetch_rss_url(url, "ABC News", FetcherUtils.category_display_name(category), category, search_query, session, set_label, clear_items, add_item);
    }

    public override string get_source_name() {
        return "ABC News";
    }
}
