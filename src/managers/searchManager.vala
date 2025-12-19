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
using Gee;

namespace Managers {
    /**
     * SearchManager - Manages client-side search filtering of loaded articles
     *
     * Filters already-loaded articles in the UI instead of re-fetching from network.
     * This provides instant search results and avoids unnecessary network calls.
     */
    public class SearchManager : GLib.Object {
        private weak NewsWindow window;
        private string current_query = "";
        private uint search_timeout_id = 0;

        // Store all loaded articles before filtering
        private Gee.ArrayList<ArticleItem>? all_articles = null;

        // Debounce delay in milliseconds (wait this long after user stops typing)
        private const uint DEBOUNCE_DELAY_MS = 150;

        public SearchManager(NewsWindow window) {
            this.window = window;
            this.all_articles = new Gee.ArrayList<ArticleItem>();
        }

        ~SearchManager() {
            // Clean up any pending timeout
            if (search_timeout_id > 0) {
                Source.remove(search_timeout_id);
                search_timeout_id = 0;
            }
        }

        /**
         * Store the current articles for search filtering
         * Should be called after articles are loaded
         */
        public void store_articles(Gee.ArrayList<ArticleItem> articles) {
            all_articles = new Gee.ArrayList<ArticleItem>();
            foreach (var article in articles) {
                all_articles.add(article);
            }
        }

        /**
         * Update the search query and filter articles
         * This method is called on every search_changed event.
         * It will wait DEBOUNCE_DELAY_MS after the user stops typing
         * before filtering the UI.
         */
        public void update_query(string query) {
            // Cancel previous timeout if user is still typing
            if (search_timeout_id > 0) {
                Source.remove(search_timeout_id);
                search_timeout_id = 0;
            }

            // Store the query
            current_query = query.strip();

            // If query is empty, restore all articles immediately (no debounce)
            if (current_query.length == 0) {
                filter_articles();
                return;
            }

            // Wait before filtering for non-empty queries
            search_timeout_id = Timeout.add(DEBOUNCE_DELAY_MS, () => {
                filter_articles();
                search_timeout_id = 0;
                return Source.REMOVE;
            });
        }

        /**
         * Filter the UI to show only articles matching the search query
         */
        private void filter_articles() {
            if (window == null || window.content_view == null) return;

            // Tell ContentView to filter its cards based on the current query
            window.content_view.filter_by_query(current_query);
        }

        /**
         * Get the current search query
         */
        public string get_query() {
            return current_query;
        }

        /**
         * Clear the search query and restore all articles
         */
        public void clear() {
            // Cancel any pending search
            if (search_timeout_id > 0) {
                Source.remove(search_timeout_id);
                search_timeout_id = 0;
            }

            current_query = "";
            filter_articles();
        }

        /**
         * Tokenized substring-match helper used by search routines.
         * All matching is done against lower-cased inputs.
         */
        public static bool tokens_match(string text_lower, string query_lower) {
            var tokens = query_lower.split(" ");
            foreach (var t in tokens) {
                var tok = t.strip();
                if (tok.length == 0) continue;
                if (!text_lower.contains(tok)) return false;
            }
            return true;
        }

        /**
         * Normalize a query string (lowercase and strip whitespace)
         */
        public static string normalize_query(string query) {
            return query.strip().down();
        }

        /**
         * Check if an article matches the search query
         * @param title Article title
         * @param url Article URL
         * @param query Search query (will be normalized)
         * @return true if the article matches the query
         */
        public static bool article_matches_query(string title, string url, string query) {
            string query_lower = normalize_query(query);
            if (query_lower.length == 0) return true;

            string title_lower = title != null ? title.down() : "";
            string url_lower = url != null ? url.down() : "";

            return tokens_match(title_lower, query_lower) || tokens_match(url_lower, query_lower);
        }
    }
}
