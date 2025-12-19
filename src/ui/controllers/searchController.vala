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
 * SearchController - Thin coordinator for client-side article search
 * Delegates to SearchManager for matching logic and ArticleManager for card creation
 */

 public class SearchController : GLib.Object {

    /**
     * Filter article cards from columns and hero container based on a search query
     * Creates ArticleCards from matching HeroCards and includes them in results
     */
    public static Gee.ArrayList<ArticleCard> filter_cards_from_columns(
        GLib.ListModel columns_children,
        Gtk.Box hero_container,
        string query,
        int col_w,
        int img_h,
        ArticleStateStore? state_store,
        NewsWindow? window
    ) {
        var matching_cards = new Gee.ArrayList<ArticleCard>();
        var seen_urls = new Gee.HashSet<string>();

        // If query is empty, return all existing article cards
        if (query.strip().length == 0) {
            for (uint col_idx = 0; col_idx < columns_children.get_n_items(); col_idx++) {
                var column = columns_children.get_item(col_idx) as Gtk.Box;
                if (column == null) continue;

                var card_roots = column.observe_children();
                for (uint card_idx = 0; card_idx < card_roots.get_n_items(); card_idx++) {
                    var card_root = card_roots.get_item(card_idx) as Gtk.Box;
                    if (card_root == null) continue;

                    ArticleCard? card = card_root.get_data("article-card");
                    if (card != null) {
                        matching_cards.add(card);
                    }
                }
            }
            return matching_cards;
        }

        // SEARCHING: Check all regular article cards
        for (uint col_idx = 0; col_idx < columns_children.get_n_items(); col_idx++) {
            var column = columns_children.get_item(col_idx) as Gtk.Box;
            if (column == null) continue;

            var card_roots = column.observe_children();
            for (uint card_idx = 0; card_idx < card_roots.get_n_items(); card_idx++) {
                var card_root = card_roots.get_item(card_idx) as Gtk.Box;
                if (card_root == null) continue;

                ArticleCard? card = card_root.get_data("article-card");
                if (card != null && !seen_urls.contains(card.url)) {
                    // Use SearchManager for matching logic
                    if (Managers.SearchManager.article_matches_query(card.title_text, card.url, query)) {
                        matching_cards.add(card);
                        seen_urls.add(card.url);
                    }
                }
            }
        }

        // SEARCHING: Check all hero cards and build ArticleCards from matches
        find_and_build_hero_matches(hero_container, query, seen_urls, matching_cards, col_w, img_h, state_store, window);

        return matching_cards;
    }

    /**
     * Recursively find HeroCards and build ArticleCards from matches
     */
    private static void find_and_build_hero_matches(
        Gtk.Widget widget,
        string query,
        Gee.HashSet<string> seen_urls,
        Gee.ArrayList<ArticleCard> matching_cards,
        int col_w,
        int img_h,
        ArticleStateStore? state_store,
        NewsWindow? window
    ) {
        // Check if this widget has a HeroCard
        if (widget is Gtk.Box) {
            var box = widget as Gtk.Box;
            HeroCard? hero = box.get_data("hero-card");

            if (hero != null && !seen_urls.contains(hero.url)) {
                // Use SearchManager for matching logic
                if (Managers.SearchManager.article_matches_query(hero.title_label.get_label(), hero.url, query)) {
                    seen_urls.add(hero.url);

                    // Delegate ArticleCard creation to ArticleManager
                    if (window != null && window.article_manager != null) {
                        var article_card = window.article_manager.create_article_card_from_hero(
                            hero,
                            col_w,
                            img_h,
                            state_store
                        );
                        matching_cards.add(article_card);
                    }
                }
            }
        }

        // Search children recursively
        if (widget is Gtk.Box) {
            var box = widget as Gtk.Box;
            var children = box.observe_children();
            for (uint i = 0; i < children.get_n_items(); i++) {
                var child = children.get_item(i) as Gtk.Widget;
                if (child != null) {
                    find_and_build_hero_matches(child, query, seen_urls, matching_cards, col_w, img_h, state_store, window);
                }
            }
        } else if (widget is Gtk.Stack) {
            var stack = widget as Gtk.Stack;
            var child = stack.get_first_child();
            while (child != null) {
                find_and_build_hero_matches(child, query, seen_urls, matching_cards, col_w, img_h, state_store, window);
                child = child.get_next_sibling();
            }
        } else if (widget is Gtk.Overlay) {
            var overlay = widget as Gtk.Overlay;
            var main_child = overlay.get_child();
            if (main_child != null) {
                find_and_build_hero_matches(main_child, query, seen_urls, matching_cards, col_w, img_h, state_store, window);
            }
        }
    }
}
