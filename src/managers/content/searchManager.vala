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
     * SearchManager - Global, fuzzy-tolerant search over every cached
     * article (all categories/feeds), not just the ones currently on
     * screen. Backed by Paperboy.RssArticleCache, which is kept populated
     * for every configured category/source by the startup unread-count
     * fetch, so a query can find articles the user hasn't visited yet.
     */
    public class SearchManager : GLib.Object {
        private weak NewsWindow window;
        private string current_query = "";
        private uint search_timeout_id = 0;

        // Maximum matching articles rendered per query - keeps card
        // creation (and its per-card image loads) bounded.
        private const int MAX_RESULTS = 60;

        // How many of the most-recently-cached articles are considered as
        // search candidates. Bounds the per-keystroke scan cost.
        private const int MAX_CANDIDATES = 4000;

        // Debounce delay in milliseconds (wait this long after user stops typing)
        private const uint DEBOUNCE_DELAY_MS = 150;

        // Normalized URLs of the article cards built for the current search
        // results. Each keystroke's results replace the previous ones in the
        // UI, but ViewStateManager.url_to_card/url_to_picture only ever grow
        // via register_*_for_url() - tracking exactly what the last batch
        // registered lets us unregister it before the next batch, so those
        // maps stay bounded to one search's worth of results instead of
        // accumulating every card ever built across a whole typing session.
        private Gee.ArrayList<string>? last_result_normalized_urls = null;

        public SearchManager(NewsWindow window) {
            this.window = window;
        }

        ~SearchManager() {
            // Clean up any pending timeout
            if (search_timeout_id > 0) {
                Source.remove(search_timeout_id);
                search_timeout_id = 0;
            }
        }

        /**
         * Update the search query and filter articles
         * This method is called on every search_changed event.
         * It will wait DEBOUNCE_DELAY_MS after the user stops typing
         * before filtering the UI.
         */
        public void update_query(string query) {
            string stripped = query.strip();

            // Gtk.SearchEntry's clear (X) icon can fire both search-changed
            // and stop-search for one click (both are wired to this method -
            // see appWindow.vala), and nothing upstream de-dupes that. Without
            // this guard, clearing search ran the whole restore-and-refetch
            // pipeline (LayoutManager teardown/rebuild + fetch_news()) twice
            // back to back for a single click - a big, sudden memory/CPU
            // spike, not the gradual growth a real leak would show.
            if (stripped == current_query) return;

            // Cancel previous timeout if user is still typing
            if (search_timeout_id > 0) {
                Source.remove(search_timeout_id);
                search_timeout_id = 0;
            }

            // Store the query
            current_query = stripped;

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
         * Reset query state (and cancel any pending debounce) without
         * triggering a re-render. Use this when the caller is about to
         * rebuild the view itself anyway (e.g. switching category) - unlike
         * clear(), this doesn't call filter_by_query()/fetch_news(), so it
         * can't race with that caller's own rebuild. See appWindow.vala's
         * category_selected handler, which blocks the search-changed signal
         * around its own programmatic search_entry.set_text("") for the
         * same reason - without both, clearing a search while navigating
         * away triggered two full fetch_news() calls back to back.
         *
         * Also drops LayoutManager's pre-search card snapshot (see
         * LayoutManager.discard_search_snapshot()) - skipping the normal
         * filter_by_query("") restore path here means restore_original_
         * layout() never runs to null it out, which otherwise pins every
         * pre-search card widget (and its decoded thumbnail) alive
         * indefinitely, since the snapshot is never retaken once set.
         */
        public void reset_query_state() {
            if (search_timeout_id > 0) {
                Source.remove(search_timeout_id);
                search_timeout_id = 0;
            }
            current_query = "";
            forget_result_urls();
            if (window != null && window.layout_manager != null) {
                window.layout_manager.discard_search_snapshot();
            }
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
         * Unregister the previous batch of search-result cards from
         * ViewStateManager (url_to_card/url_to_picture) so those maps don't
         * grow with every keystroke, then remember `new_urls` as the batch
         * to unregister next time. Call this right before wiring up a new
         * batch of result cards; pass an empty list (or call
         * forget_result_urls()) once search ends.
         */
        public void adopt_result_urls(Gee.ArrayList<string> new_urls) {
            forget_result_urls();
            last_result_normalized_urls = new_urls;
        }

        /**
         * Unregister the last-tracked batch of search-result URLs (see
         * adopt_result_urls()) without adopting a new one - call when
         * search results are being torn down for good (query cleared).
         */
        public void forget_result_urls() {
            if (last_result_normalized_urls == null || window == null || window.view_state == null) {
                last_result_normalized_urls = null;
                return;
            }
            foreach (var normalized in last_result_normalized_urls) {
                window.view_state.url_to_card.unset(normalized);
                window.view_state.url_to_picture.unset(normalized);
            }
            last_result_normalized_urls = null;
        }

        /**
         * Normalize a query string (lowercase and strip whitespace)
         */
        public static string normalize_query(string query) {
            return query.strip().down();
        }

        private struct RankedArticle {
            public Paperboy.RssArticleCache.CachedArticle article;
            public int score;
        }

        /**
         * Search every cached article (across all categories/feeds) for the
         * given query and return the best matches, highest-scoring first.
         */
        public Gee.ArrayList<Paperboy.RssArticleCache.CachedArticle?> search_global(string query) {
            var results = new Gee.ArrayList<Paperboy.RssArticleCache.CachedArticle?>();

            string query_lower = normalize_query(query);
            if (query_lower.length == 0) return results;

            var candidates = Paperboy.RssArticleCache.get_instance().get_all_cached_articles(MAX_CANDIDATES);

            var ranked = new Gee.ArrayList<RankedArticle?>();
            var seen_urls = new Gee.HashSet<string>();

            foreach (var candidate in candidates) {
                if (candidate.url == null || seen_urls.contains(candidate.url)) continue;

                int score = score_article(candidate.title, candidate.source_name, candidate.url, query_lower);
                if (score <= 0) continue;

                seen_urls.add(candidate.url);
                RankedArticle ranked_article = RankedArticle();
                ranked_article.article = candidate;
                ranked_article.score = score;
                ranked.add(ranked_article);
            }

            ranked.sort((a, b) => {
                if (a.score != b.score) return b.score - a.score;
                int64 diff = b.article.cached_at - a.article.cached_at;
                return diff > 0 ? 1 : (diff < 0 ? -1 : 0);
            });

            for (int i = 0; i < ranked.size && i < MAX_RESULTS; i++) {
                results.add(ranked.get(i).article);
            }

            return results;
        }

        /**
         * Score how well an article matches a (already-lowercased) query.
         * Every whitespace-separated token in the query must match
         * somewhere (title, source, or url) or the article is excluded
         * entirely (score 0) - this keeps multi-word queries precise.
         * A token may match as an exact substring (best), a substring of
         * the source name, a fuzzy (small edit-distance) word match in the
         * title, or a substring of the url (weakest, urls aren't prose).
         */
        private static int score_article(string title, string? source_name, string url, string query_lower) {
            string title_lower = title != null ? title.down() : "";
            string source_lower = source_name != null ? source_name.down() : "";
            string url_lower = url != null ? url.down() : "";

            var tokens = query_lower.split(" ");
            int total_score = 0;
            bool matched_any_token = false;

            foreach (var raw_token in tokens) {
                string token = raw_token.strip();
                if (token.length == 0) continue;
                matched_any_token = true;

                if (title_lower.contains(token)) {
                    total_score += 10;
                    continue;
                }
                if (source_lower.contains(token)) {
                    total_score += 6;
                    continue;
                }

                int fuzzy_distance = closest_word_distance(title_lower, token);
                if (fuzzy_distance >= 0) {
                    total_score += int.max(1, 5 - fuzzy_distance);
                    continue;
                }

                if (url_lower.contains(token)) {
                    total_score += 3;
                    continue;
                }

                // This token matched nowhere - the whole query fails (AND semantics).
                return 0;
            }

            return matched_any_token ? total_score : 0;
        }

        /**
         * Find the smallest edit distance between `token` and any
         * whitespace/punctuation-separated word in `text`, within a
         * threshold that scales with the token's length. Returns -1 if no
         * word is close enough to count as a fuzzy match.
         */
        private static int closest_word_distance(string text, string token) {
            if (token.length < 3) return -1; // too short to fuzzy-match usefully

            int max_distance = token.length <= 5 ? 1 : 2;
            int best = -1;

            foreach (var word in text.split_set(" \t\n-_.,:;!?'\"()[]/\\")) {
                if (word.length < 3) continue;
                // Cheap length-based pre-filter before the O(n*m) DP below.
                if ((word.length - token.length).abs() > max_distance) continue;

                int distance = levenshtein(word, token);
                if (distance <= max_distance && (best == -1 || distance < best)) {
                    best = distance;
                }
            }

            return best;
        }

        /**
         * Classic Levenshtein edit distance between two strings.
         */
        private static int levenshtein(string a, string b) {
            int len_a = a.length;
            int len_b = b.length;
            if (len_a == 0) return len_b;
            if (len_b == 0) return len_a;

            int[] previous_row = new int[len_b + 1];
            int[] current_row = new int[len_b + 1];

            for (int j = 0; j <= len_b; j++) previous_row[j] = j;

            for (int i = 1; i <= len_a; i++) {
                current_row[0] = i;
                unichar char_a = a.get_char(a.index_of_nth_char(i - 1));
                for (int j = 1; j <= len_b; j++) {
                    unichar char_b = b.get_char(b.index_of_nth_char(j - 1));
                    int cost = (char_a == char_b) ? 0 : 1;
                    int deletion = previous_row[j] + 1;
                    int insertion = current_row[j - 1] + 1;
                    int substitution = previous_row[j - 1] + cost;
                    current_row[j] = int.min(int.min(deletion, insertion), substitution);
                }
                var swap = previous_row;
                previous_row = current_row;
                current_row = swap;
            }

            return previous_row[len_b];
        }
    }
}
