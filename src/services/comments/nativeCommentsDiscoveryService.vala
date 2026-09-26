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

// Finds a native WordPress comments RSS feed directly from an article's own
// page, for articles that didn't come through RssFeedProcessor (built-in
// fetchers like Guardian/Fox/Reddit, or Frontpage/Top Ten's GNews-backed
// pipeline, none of which carry a feed-level wfw:commentRss). WordPress
// emits a standard per-post "Comments Feed" <link> in every article page's
// own <head>, independent of how the page was reached - so this works
// regardless of which fetcher produced the article, no backend needed.
namespace Paperboy {
    public delegate void NativeCommentsUrlCallback(string? comments_url);

    public class NativeCommentsDiscoveryService {
        public static void find(string article_url, owned NativeCommentsUrlCallback callback) {
            var options = new HttpClientUtils.RequestOptions().with_browser_headers();
            HttpClientUtils.get_default().fetch_string(article_url, options, (response) => {
                if (!response.is_success()) {
                    callback(null);
                    return;
                }
                string? html = response.get_body_string();
                callback(extract(html, article_url));
            });
        }

        private static string? extract(string? html, string article_url) {
            if (html == null) return null;

            string article_prefix = article_url.has_suffix("/") ? article_url.substring(0, article_url.length - 1) : article_url;

            string? fallback = null;
            try {
                var regex = new GLib.Regex("<link\\s+rel=[\"']alternate[\"']\\s+type=[\"']application/rss\\+xml[\"']\\s+title=[\"']([^\"']*)[\"']\\s+href=[\"']([^\"']+)[\"']\\s*/?>", GLib.RegexCompileFlags.CASELESS);
                GLib.MatchInfo mi;
                if (regex.match(html, 0, out mi)) {
                    do {
                        string title = mi.fetch(1) ?? "";
                        string href = mi.fetch(2) ?? "";
                        if (title.down().contains("comments feed") && href.length > 0) {
                            href = href.replace("&#038;", "&").replace("&amp;", "&");
                            if (href.has_prefix(article_prefix)) return href;
                            if (fallback == null) fallback = href;
                        }
                    } while (mi.next());
                }
            } catch (GLib.RegexError e) { }

            return fallback;
        }
    }
}
