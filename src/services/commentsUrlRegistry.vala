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

/*
 * Maps an article URL to its feed-provided comments page/feed URL
 * (RSS <comments> or wfw:commentRss), populated while parsing feeds in
 * RssFeedProcessor and read by ArticleSheet when opening an article.
 */
namespace Paperboy {
    public class CommentsUrlRegistry {
        private static LruCache<string, string>? cache = null;

        public static LruCache<string, string> get_instance() {
            if (cache == null) cache = new LruCache<string, string>(2000);
            return cache;
        }

        // Keyed by UrlUtils.normalize_article_url(article_url) since callers
        // (e.g. ArticleSheet.open()) receive an already-normalized URL, not
        // the raw feed link.
        public static void register(string? article_url, string? comments_url) {
            if (article_url == null || comments_url == null) return;
            if (article_url.length == 0 || comments_url.length == 0) return;
            get_instance().set(UrlUtils.normalize_article_url(article_url), comments_url);
        }

        public static string? lookup(string? article_url) {
            if (article_url == null) return null;
            return get_instance().get(UrlUtils.normalize_article_url(article_url));
        }
    }
}
