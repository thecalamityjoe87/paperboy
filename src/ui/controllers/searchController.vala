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

using Gee;

/**
 * SearchController - Thin coordinator for global article search.
 * Delegates matching/ranking to SearchManager and card creation to
 * ArticleManager, turning ranked cache rows into ready-to-display cards.
 */

 public class SearchController : GLib.Object {

    /**
     * Run a global search (across every cached category/feed, not just the
     * one currently on screen) and build display-ready ArticleCards for the
     * ranked matches.
     */
    public static Gee.ArrayList<Gtk.Widget> build_global_search_cards(
        Managers.SearchManager search_manager,
        string query,
        int col_w,
        int img_h,
        ArticleStateStore? state_store,
        NewsWindow? window
    ) {
        var matching_cards = new Gee.ArrayList<Gtk.Widget>();
        if (window == null || window.article_manager == null) return matching_cards;

        var results = search_manager.search_global(query);
        var result_normalized_urls = new Gee.ArrayList<string>();

        foreach (var result in results) {
            var article_card = window.article_manager.create_article_card_from_hero(
                result.title,
                result.url,
                null,
                result.source_name,
                result.category_id,
                result.thumbnail_url,
                col_w,
                img_h,
                state_store
            );

            if (result.thumbnail_url != null && result.thumbnail_url.length > 0 && window.image_manager != null) {
                window.image_manager.load_image_async(article_card.image, result.thumbnail_url, col_w, img_h, true);
            }

            matching_cards.add(article_card.root);
            if (window.view_state != null) {
                result_normalized_urls.add(window.view_state.normalize_article_url(result.url));
            }
        }

        // Drop the previous keystroke's result cards from ViewStateManager
        // and remember this batch instead, so url_to_card/url_to_picture
        // stay bounded to one search's worth of cards rather than growing
        // with every keystroke.
        search_manager.adopt_result_urls(result_normalized_urls);

        // Every keystroke here builds and discards up to MAX_RESULTS full
        // card widget trees - return freed heap to the OS after each batch
        // rather than only at category-switch boundaries.
        malloc_trim(0);

        return matching_cards;
    }
}
