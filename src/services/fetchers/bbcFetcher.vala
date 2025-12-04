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

public class BbcFetcher : BaseFetcher {
    public BbcFetcher(SetLabelFunc set_label_func, ClearItemsFunc clear_items_func, AddItemFunc add_item_func) {
        base(set_label_func, clear_items_func, add_item_func);
    }

    public override void fetch(string category, string search_query, Soup.Session session) {
        string url = "https://feeds.bbci.co.uk/news/world/rss.xml";

        switch (category) {
            case "technology":
                url = "https://feeds.bbci.co.uk/news/technology/rss.xml";
                break;
            case "business":
                url = "https://feeds.bbci.co.uk/news/business/rss.xml";
                break;
            case "science":
                url = "https://feeds.bbci.co.uk/news/science_and_environment/rss.xml";
                break;
            case "sports":
                url = "https://feeds.bbci.co.uk/sport/rss.xml";
                break;
            case "health":
                url = "https://feeds.bbci.co.uk/news/health/rss.xml";
                break;
            case "us":
                url = "https://feeds.bbci.co.uk/news/world/us_and_canada/rss.xml";
                break;
            case "politics":
                url = "https://feeds.bbci.co.uk/news/politics/rss.xml";
                break;
            case "entertainment":
                url = "https://feeds.bbci.co.uk/news/entertainment_and_arts/rss.xml";
                break;
            default:
                url = "https://feeds.bbci.co.uk/news/world/rss.xml";
                break;
        }

        RssParser.fetch_rss_url(url, "BBC News", category_display_name(category), category, search_query, session, set_label, clear_items, add_item);
    }

    public override string get_source_name() {
        return "BBC News";
    }

    private string category_display_name(string category_id) {
        switch (category_id) {
            case "technology": return "Technology";
            case "business": return "Business";
            case "science": return "Science";
            case "sports": return "Sports";
            case "health": return "Health";
            case "us": return "US News";
            case "politics": return "Politics";
            case "entertainment": return "Entertainment";
            default: return "World News";
        }
    }
}
