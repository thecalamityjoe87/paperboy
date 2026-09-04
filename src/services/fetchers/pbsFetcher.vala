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

public class PbsFetcher : BaseFetcher {
    public PbsFetcher(SetLabelFunc set_label_func, ClearItemsFunc clear_items_func, AddItemFunc add_item_func) {
        base(set_label_func, clear_items_func, add_item_func);
    }

    public override void fetch(string category, string search_query, Soup.Session session) {
        // PBS NewsHour publishes real per-section RSS feeds at
        // /newshour/feeds/rss/<section> (verified by hand - the more
        // obvious-looking /newshour/<section>/feed URLs return an
        // unrelated HTML article page, not a feed, despite a 200 status).
        // It has no dedicated technology, business, or sports desk, so
        // those (and anything else unmapped) fall back to World News,
        // matching how BbcFetcher/RedditFetcher handle sections a source
        // simply doesn't cover.
        string url = "https://www.pbs.org/newshour/feeds/rss/world";

        switch (category) {
            case "us":
                url = "https://www.pbs.org/newshour/feeds/rss/nation";
                break;
            case "business":
                url = "https://www.pbs.org/newshour/feeds/rss/economy";
                break;
            case "science":
                url = "https://www.pbs.org/newshour/feeds/rss/science";
                break;
            case "health":
                url = "https://www.pbs.org/newshour/feeds/rss/health";
                break;
            case "politics":
                url = "https://www.pbs.org/newshour/feeds/rss/politics";
                break;
            case "entertainment":
                url = "https://www.pbs.org/newshour/feeds/rss/arts";
                break;
            default:
                url = "https://www.pbs.org/newshour/feeds/rss/world";
                break;
        }

        RssFeedProcessor.fetch_rss_url(url, "PBS NewsHour", category_display_name(category), category, search_query, session, set_label, clear_items, add_item);
    }

    public override string get_source_name() {
        return "PBS NewsHour";
    }

    private string category_display_name(string category_id) {
        switch (category_id) {
            case "us": return "US News";
            case "business": return "Business";
            case "science": return "Science";
            case "health": return "Health";
            case "politics": return "Politics";
            case "entertainment": return "Entertainment";
            default: return "World News";
        }
    }
}
