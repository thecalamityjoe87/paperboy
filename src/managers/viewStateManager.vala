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
    private NewsWindow window;

    // Article viewing state
    public Gee.HashSet<string> viewed_articles;
    public Gee.HashMap<string, Gtk.Picture> url_to_picture;
    public Gee.HashMap<string, Gtk.Widget> url_to_card;
    public Gee.HashMap<string, string> normalized_to_url;
    public string? last_previewed_url;
    public double last_scroll_value = -1.0;

    public ViewStateManager(NewsWindow w) {
        window = w;
        viewed_articles = new Gee.HashSet<string>();
        url_to_picture = new Gee.HashMap<string, Gtk.Picture>();
        url_to_card = new Gee.HashMap<string, Gtk.Widget>();
        normalized_to_url = new Gee.HashMap<string, string>();
    }

    public string normalize_article_url(string url) {
        return UrlUtils.normalize_article_url(url);
    }

    public void register_picture_for_url(string normalized, Gtk.Picture pic) {
        try { url_to_picture.set(normalized, pic); } catch (GLib.Error e) { }
    }

    public void register_card_for_url(string normalized, Gtk.Widget card) {
        try { url_to_card.set(normalized, card); } catch (GLib.Error e) { }
    }

    public void mark_article_viewed(string url) {
        if (url == null) return;
        string n = normalize_article_url(url);
        if (n == null || n.length == 0) return;
        if (viewed_articles == null) viewed_articles = new Gee.HashSet<string>();
        viewed_articles.add(n);

        Timeout.add(50, () => {
            try {
                Gtk.Widget? card = null;
                try { card = url_to_card.get(n); } catch (GLib.Error e) { card = null; }
                if (card != null) {
                    Gtk.Widget? first = card.get_first_child();
                    if (first != null && first is Gtk.Overlay) {
                        var overlay = (Gtk.Overlay) first;
                        bool already = false;
                        Gtk.Widget? c = overlay.get_first_child();
                        while (c != null) {
                            try {
                                if (c.get_style_context().has_class("viewed-badge")) {
                                    already = true;
                                }
                            } catch (GLib.Error e) { }
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
            } catch (GLib.Error e) { }
            return false;
        });

        if (window.article_state_store != null) {
            stderr.printf("[ARTICLE_STATE] Saving viewed state for: %s\n", n);
            try { window.article_state_store.mark_viewed(n); stderr.printf("[ARTICLE_STATE] Successfully saved\n"); } catch (GLib.Error e) { stderr.printf("[ARTICLE_STATE] Error in mark_viewed: %s\n", e.message); }
        } else {
            stderr.printf("[ARTICLE_STATE] article_state_store is NULL!\n");
        }
    }

    public void preview_opened(string url) {
        try { last_previewed_url = url; } catch (GLib.Error e) { last_previewed_url = null; }
        if (window.dim_overlay != null) window.dim_overlay.set_visible(true);
        try {
            if (window.main_scrolled != null) {
                try {
                    var adj = window.main_scrolled.get_vadjustment();
                    if (adj != null) last_scroll_value = adj.get_value();
                } catch (GLib.Error e) { last_scroll_value = -1.0; }
            }
        } catch (GLib.Error e) { last_scroll_value = -1.0; }
    }

    public void preview_closed(string url) {
        string? url_copy = null;
        try {
            if (url != null && url.length > 0) {
                url_copy = url.dup();
            }
        } catch (GLib.Error e) { }

        try { last_previewed_url = null; } catch (GLib.Error e) { }
        if (window.dim_overlay != null) window.dim_overlay.set_visible(false);

        double saved_scroll = last_scroll_value;
        if (saved_scroll < 0.0) {
            try {
                if (window.main_scrolled != null) {
                    var adj = window.main_scrolled.get_vadjustment();
                    if (adj != null) saved_scroll = adj.get_value();
                }
            } catch (GLib.Error e) { }
        }

        try { if (url_copy != null) mark_article_viewed(url_copy); } catch (GLib.Error e) { }

        try {
            if (window.main_scrolled != null && saved_scroll >= 0.0) {
                Idle.add(() => {
                    try {
                        var adj = window.main_scrolled.get_vadjustment();
                        if (adj != null) {
                            adj.set_value(saved_scroll);
                        }
                    } catch (GLib.Error e) { }
                    return false;
                }, Priority.HIGH);

                Timeout.add(100, () => {
                    try {
                        var adj = window.main_scrolled.get_vadjustment();
                        if (adj != null) {
                            adj.set_value(saved_scroll);
                        }
                    } catch (GLib.Error e) { }
                    return false;
                });

                Timeout.add(200, () => {
                    try {
                        var adj = window.main_scrolled.get_vadjustment();
                        if (adj != null) {
                            adj.set_value(saved_scroll);
                        }
                    } catch (GLib.Error e) { }
                    return false;
                });
            }
        } catch (GLib.Error e) { }

        last_scroll_value = -1.0;
    }
}

}
