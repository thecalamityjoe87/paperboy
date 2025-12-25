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


using Gtk;
using Gee;

namespace Managers {

    public class ViewStateManager : GLib.Object {
        private weak NewsWindow window;

        // Article viewing state
        public Gee.HashSet<string> viewed_articles;
        // Suppress marking an article viewed when a preview closes if the user
        // explicitly requested to mark it unread from the preview pane.
        public Gee.HashSet<string> suppress_preview_mark;
        public Gee.HashMap<string, Gtk.Picture> url_to_picture;
        public Gee.HashMap<string, Gtk.Widget> url_to_card;
        public Gee.HashMap<string, string> normalized_to_url;
        public string? last_previewed_url;
        public double last_scroll_value = -1.0;

        // Signal emitted when an article is marked as viewed
        public signal void article_viewed(string url);

        public ViewStateManager(NewsWindow w) {
            window = w;
            viewed_articles = new Gee.HashSet<string>();
            suppress_preview_mark = new Gee.HashSet<string>();
            url_to_picture = new Gee.HashMap<string, Gtk.Picture>();
            url_to_card = new Gee.HashMap<string, Gtk.Widget>();
            normalized_to_url = new Gee.HashMap<string, string>();
        }

        public string normalize_article_url(string url) {
            return UrlUtils.normalize_article_url(url);
        }

        public void register_picture_for_url(string normalized, Gtk.Picture pic) {
            url_to_picture.set(normalized, pic);
        }

        public void register_card_for_url(string normalized, Gtk.Widget card) {
            url_to_card.set(normalized, card);
        }

        public void unregister_card_for_url(string normalized) {
            if (normalized == null) return;
            if (url_to_card == null) return;
            url_to_card.remove(normalized);
        }

        public void mark_article_viewed(string url) {
            if (url == null) return;
            string n = normalize_article_url(url);
            if (n == null || n.length == 0) return;
            if (viewed_articles == null) viewed_articles = new Gee.HashSet<string>();
            viewed_articles.add(n);

            // Mark as viewed in article state store (persists to disk)
            if (window.article_state_store != null) {
                window.article_state_store.mark_viewed(n);
            }

            Timeout.add(50, () => {
                Gtk.Widget? card = url_to_card.get(n);
                if (card != null) {
                    Gtk.Widget? first = card.get_first_child();
                    if (first != null && first is Gtk.Overlay) {
                        var overlay = (Gtk.Overlay) first;
                        bool already = false;
                        Gtk.Widget? c = overlay.get_first_child();
                        while (c != null) {
                            if (c.get_style_context().has_class("viewed-badge")) {
                                already = true;
                            }
                            if (already) break;
                            c = c.get_next_sibling();
                        }
                        if (!already) {
                            var badge = CardBuilder.build_viewed_badge();
                            overlay.add_overlay(badge);
                            badge.set_visible(true);
                            overlay.queue_draw();
                        }
                    }
                }
                return false;
            });

            // Emit signal for unread count updates
            article_viewed(n);
        }

        public void preview_opened(string url) {
            last_previewed_url = url;
            if (window.dim_overlay != null) window.dim_overlay.set_visible(true);
            if (window.main_scrolled != null) {
                var adj = window.main_scrolled.get_vadjustment();
                if (adj != null) last_scroll_value = adj.get_value(); else last_scroll_value = -1.0;
            } else {
                last_scroll_value = -1.0;
            }
        }

        public void preview_closed(string url) {
            string? url_copy = null;
            if (url != null && url.length > 0) url_copy = url.dup();

            last_previewed_url = null;
            if (window.dim_overlay != null) window.dim_overlay.set_visible(false);

            double saved_scroll = last_scroll_value;
            if (saved_scroll < 0.0) {
                if (window.main_scrolled != null) {
                    var adj = window.main_scrolled.get_vadjustment();
                    if (adj != null) saved_scroll = adj.get_value();
                }
            }

            if (url_copy != null) {
                // If the preview requested suppression (user marked unread from the
                // preview), honor that and do not mark viewed again.
                string n = normalize_article_url(url_copy);
                bool suppressed = (suppress_preview_mark != null && suppress_preview_mark.contains(n));
                if (suppressed) {
                    if (suppress_preview_mark != null) suppress_preview_mark.remove(n);
                } else {
                    mark_article_viewed(url_copy);
                }
            }

            if (window.main_scrolled != null && saved_scroll >= 0.0) {
                Idle.add(() => {
                    var adj = window.main_scrolled.get_vadjustment();
                    if (adj != null) {
                        adj.set_value(saved_scroll);
                    }
                    return false;
                }, Priority.HIGH);

                Timeout.add(100, () => {
                    var adj = window.main_scrolled.get_vadjustment();
                    if (adj != null) {
                        adj.set_value(saved_scroll);
                    }
                    return false;
                });

                Timeout.add(200, () => {
                    var adj = window.main_scrolled.get_vadjustment();
                    if (adj != null) {
                        adj.set_value(saved_scroll);
                    }
                    return false;
                });
            }

            last_scroll_value = -1.0;
        }

        /**
        * Refresh viewed badges for all articles from a specific source
        * Used after marking all as read/unread
        */
        public void refresh_viewed_badges_for_source(string source_name) {
            if (window.article_state_store == null) return;
            
            var articles = window.article_state_store.get_articles_for_source(source_name);
            if (articles == null) return;
            
            foreach (string url in articles) {
                string normalized = normalize_article_url(url);
                if (normalized == null || normalized.length == 0) continue;
                
                Gtk.Widget? card = null;
                card = url_to_card.get(normalized);
                if (card == null) continue;
                
                bool is_viewed = window.article_state_store.is_viewed(normalized);
                
                Gtk.Widget? first = card.get_first_child();
                if (first != null && first is Gtk.Overlay) {
                    var overlay = (Gtk.Overlay) first;
                    
                    // Find and remove existing viewed badge if present
                    Gtk.Widget? child = overlay.get_first_child();
                    while (child != null) {
                        Gtk.Widget? next = child.get_next_sibling();
                        if (child.get_style_context().has_class("viewed-badge")) {
                            overlay.remove_overlay(child);
                        }
                        child = next;
                    }
                    
                    // Add viewed badge if article is viewed
                    if (is_viewed) {
                        var badge = CardBuilder.build_viewed_badge();
                        overlay.add_overlay(badge);
                        badge.set_visible(true);
                        overlay.queue_draw();
                    }
                }
            }
        }

        /**
        * Suppress marking the given article as viewed when a preview closes.
        * This is used when the user explicitly marks the article unread from
        * the preview pane so the automatic "mark viewed on close" does not
        * re-mark it.
        */
        public void suppress_mark_on_preview_close(string url) {
            if (url == null) return;
            string n = normalize_article_url(url);
            if (n == null || n.length == 0) return;
            if (suppress_preview_mark == null) suppress_preview_mark = new Gee.HashSet<string>();
            suppress_preview_mark.add(n);
        }

        /**
        * Refresh the viewed badge for a single article URL (if a card exists).
        */
        public void refresh_viewed_badge_for_url(string url) {
            if (url == null) return;
            string n = normalize_article_url(url);
            if (n == null || n.length == 0) return;
            if (window == null || window.article_state_store == null) return;

            Gtk.Widget? card = null;
            card = url_to_card.get(n); // return null if n is not in map
            if (card == null) return;

            bool is_viewed = false;
            is_viewed = window.article_state_store.is_viewed(n);

            Gtk.Widget? first = card.get_first_child();
            if (first != null && first is Gtk.Overlay) {
                var overlay = (Gtk.Overlay) first;
                // Remove any existing viewed badges
                Gtk.Widget? child = overlay.get_first_child();
                while (child != null) {
                    Gtk.Widget? next = child.get_next_sibling();
                    if (child.get_style_context().has_class("viewed-badge")) {
                        overlay.remove_overlay(child);
                    }
                    child = next;
                }

                if (is_viewed) {
                    var badge = CardBuilder.build_viewed_badge();
                    overlay.add_overlay(badge);
                    badge.set_visible(true);
                    overlay.queue_draw();
                } else {
                    overlay.queue_draw();
                }
            }
        }
    }
}
