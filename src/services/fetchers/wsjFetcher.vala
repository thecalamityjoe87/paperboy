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

public class WsjFetcher : BaseFetcher {
    public WsjFetcher(SetLabelFunc set_label_func, ClearItemsFunc clear_items_func, AddItemFunc add_item_func) {
        base(set_label_func, clear_items_func, add_item_func);
    }

    public override void fetch(string category, string search_query, Soup.Session session) {
        if (search_query.length > 0) {
            fetch_google_domain(category, search_query, session, "wsj.com", "WSJ");
            return;
        }
        string url = "https://feeds.content.dowjones.io/public/rss/RSSWorldNews.xml";
        switch (category) {
            case "technology":
                url = "https://feeds.content.dowjones.io/public/rss/RSSWSJD";
                break;
            case "business":
                url = "https://feeds.content.dowjones.io/public/rss/WSJcomUSBusiness";
                break;
            case "sports":
                url = "https://feeds.content.dowjones.io/public/rss/rsssportsfeed";
                break;
            case "health":
                url = "https://feeds.content.dowjones.io/public/rss/socialhealth";
                break;
            case "us":
                url = "https://feeds.content.dowjones.io/public/rss/RSSUSnews";
                break;
            case "politics":
                url = "https://feeds.content.dowjones.io/public/rss/socialpoliticsfeed";
                break;
            case "entertainment":
                url = "https://feeds.content.dowjones.io/public/rss/RSSArtsCulture";
                break;
            case "lifestyle":
                url = "https://feeds.content.dowjones.io/public/rss/RSSLifestyle";
                break;
            default:
                url = "https://feeds.content.dowjones.io/public/rss/RSSWorldNews";
                break;
        }
        RssParser.fetch_rss_url(url, "WSJ", FetcherUtils.category_display_name(category), category, search_query, session, set_label, clear_items, add_item);
    }

    public override string get_source_name() {
        return "WSJ";
    }

    private void fetch_google_domain(
        string current_category,
        string current_search_query,
        Soup.Session session,
        string domain,
        string source_name
    ) {
        string base_url = "https://news.google.com/rss/search";
        string ceid = "hl=en-US&gl=US&ceid=US:en";
        string category_name = FetcherUtils.category_display_name(current_category);
        string query = @"site:$(domain)";
        if (current_search_query.length > 0) {
            query = query + " " + current_search_query;
        }
        string url = @"$(base_url)?q=$(Uri.escape_string(query))&$(ceid)";

        RssParser.fetch_rss_url(url, source_name, category_name, current_category, current_search_query, session, set_label, clear_items, add_item);
    }
}
