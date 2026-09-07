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

        public Gee.HashSet<string> viewed_articles;
        // Skip the auto-mark-viewed-on-close when the user explicitly marked it unread from the preview pane.
        public Gee.HashSet<string> suppress_preview_mark;
        public Gee.HashMap<string, Gtk.Picture> url_to_picture;
        // A URL can back more than one card (My Feed shows it in both its source row and category row),
        // so lookups need every copy, not just the last one registered.
        public Gee.HashMap<string, Gee.ArrayList<Gtk.Widget>> url_to_card;
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
            url_to_card = new Gee.HashMap<string, Gee.ArrayList<Gtk.Widget>>();
            normalized_to_url = new Gee.HashMap<string, string>();
        }

        public string normalize_article_url(string url) {
            return UrlUtils.normalize_article_url(url);
        }

        public void register_picture_for_url(string normalized, Gtk.Picture pic) {
            url_to_picture.set(normalized, pic);
        }

        public void register_card_for_url(string normalized, Gtk.Widget card) {
            var list = url_to_card.get(normalized);
            if (list == null) {
                list = new Gee.ArrayList<Gtk.Widget>();
                url_to_card.set(normalized, list);
            }
            if (!list.contains(card)) list.add(card);
        }

        public void unregister_card_for_url(string normalized) {
            if (normalized == null) return;
            if (url_to_card == null) return;
            url_to_card.remove(normalized);
        }

        // For single-placement views (Saved, Front Page). My Feed callers should use get_cards_for_url() instead.
        public Gtk.Widget? get_card_for_url(string normalized) {
            var list = url_to_card.get(normalized);
            return (list != null && list.size > 0) ? list.get(0) : null;
        }

        public Gee.ArrayList<Gtk.Widget>? get_cards_for_url(string normalized) {
            return url_to_card.get(normalized);
        }

        // HeroCard nests its overlay inside a Grid, so it needs its own badge-slot lookup
        // rather than ArticleCard's "first child is an Overlay" check.
        private Gtk.Widget? resolve_badge_container_for_card(Gtk.Widget card) {
            var hero_badge_slot = card.get_data<Gtk.Box>("hero-viewed-badge-slot");
            if (hero_badge_slot != null) return hero_badge_slot;

            var article_badge_slot = card.get_data<Gtk.Box>("article-viewed-badge-slot");
            if (article_badge_slot != null) return article_badge_slot;

            return null;
        }

        private void remove_viewed_badges_from(Gtk.Widget container) {
            Gtk.Widget? child = container.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                if (child.get_style_context().has_class("viewed-badge")) {
                    if (container is Gtk.Overlay) ((Gtk.Overlay) container).remove_overlay(child);
                    else if (container is Gtk.Box) ((Gtk.Box) container).remove(child);
                }
                child = next;
            }
        }

        private void add_viewed_badge_to(Gtk.Widget container) {
            var badge = CardBuilder.build_viewed_badge();
            if (container is Gtk.Overlay) ((Gtk.Overlay) container).add_overlay(badge);
            else if (container is Gtk.Box) ((Gtk.Box) container).append(badge);
            badge.set_visible(true);
            container.queue_draw();
            if (window != null && window.animation_manager != null) {
                window.animation_manager.animate_viewed_badge_pop(badge);
            }
        }

        public void mark_article_viewed(string url) {
            if (url == null) return;
            string n = normalize_article_url(url);
            if (n == null || n.length == 0) return;
            if (viewed_articles == null) viewed_articles = new Gee.HashSet<string>();
            viewed_articles.add(n);

            if (window.article_state_store != null) {
                window.article_state_store.mark_viewed(n);
            }

            Timeout.add(50, () => {
                var cards = url_to_card.get(n);
                if (cards != null) {
                    foreach (var card in cards) {
                        var container = resolve_badge_container_for_card(card);
                        if (container == null) continue;
                        bool already = false;
                        Gtk.Widget? c = container.get_first_child();
                        while (c != null) {
                            if (c.get_style_context().has_class("viewed-badge")) {
                                already = true;
                            }
                            if (already) break;
                            c = c.get_next_sibling();
                        }
                        if (!already) add_viewed_badge_to(container);
                    }
                }
                return false;
            });

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

        public void refresh_viewed_badges_for_source(string source_name) {
            if (window.article_state_store == null) return;
            
            var articles = window.article_state_store.get_articles_for_source(source_name);
            if (articles == null) return;
            
            foreach (string url in articles) {
                string normalized = normalize_article_url(url);
                if (normalized == null || normalized.length == 0) continue;
                
                var cards = url_to_card.get(normalized);
                if (cards == null) continue;

                bool is_viewed = window.article_state_store.is_viewed(normalized);

                foreach (var card in cards) {
                    var container = resolve_badge_container_for_card(card);
                    if (container == null) continue;
                    remove_viewed_badges_from(container);
                    if (is_viewed) add_viewed_badge_to(container);
                }
            }
        }

        public void suppress_mark_on_preview_close(string url) {
            if (url == null) return;
            string n = normalize_article_url(url);
            if (n == null || n.length == 0) return;
            if (suppress_preview_mark == null) suppress_preview_mark = new Gee.HashSet<string>();
            suppress_preview_mark.add(n);
        }

        public void refresh_viewed_badge_for_url(string url) {
            if (url == null) return;
            string n = normalize_article_url(url);
            if (n == null || n.length == 0) return;
            if (window == null || window.article_state_store == null) return;

            var cards = url_to_card.get(n);
            if (cards == null) return;

            bool is_viewed = false;
            is_viewed = window.article_state_store.is_viewed(n);

            foreach (var card in cards) {
                var container = resolve_badge_container_for_card(card);
                if (container == null) continue;
                remove_viewed_badges_from(container);
                if (is_viewed) {
                    add_viewed_badge_to(container);
                } else {
                    container.queue_draw();
                }
            }
        }
    }
}
