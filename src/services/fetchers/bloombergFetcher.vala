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

public class BloombergFetcher : BaseFetcher {
    public BloombergFetcher(FetchSink sink) {
        base(sink);
    }

    public override void fetch(string category, string search_query, Soup.Session session) {
        if (category == "business") {
            if (search_query.length > 0) {
                fetch_google_domain(category, search_query, session, "bloomberg.com", "Bloomberg");
                return;
            }
            // Bloomberg has no single "business" feed - Business pulls its
            // industries/markets/economics desks together instead. Additive
            // calls (view sinks have no clear handler), so these three don't
            // clobber each other or other sources' articles.
            string[] business_feeds = {
                "https://feeds.bloomberg.com/industries/news.rss",
                "https://feeds.bloomberg.com/markets/news.rss",
                "https://feeds.bloomberg.com/economics/news.rss"
            };
            foreach (var feed_url in business_feeds) {
                RssFeedProcessor.fetch_rss_url(feed_url, "Bloomberg", FetcherUtils.category_display_name(category), category, search_query, session, sink);
            }
            return;
        }

        string url;
        switch (category) {
            case "technology":
                url = "https://feeds.bloomberg.com/technology/news.rss";
                break;
            case "politics":
                url = "https://feeds.bloomberg.com/politics/news.rss";
                break;
            default:
            // No feed for this category - fetching a fallback feed here would
            // show its articles mislabeled under this category
                return;
        }
        // Searches stay within categories this source has a feed for
        if (search_query.length > 0) {
            fetch_google_domain(category, search_query, session, "bloomberg.com", "Bloomberg");
            return;
        }
        RssFeedProcessor.fetch_rss_url(url, "Bloomberg", FetcherUtils.category_display_name(category), category, search_query, session, sink);
    }

    public override string get_source_name() {
        return "Bloomberg";
    }

}
