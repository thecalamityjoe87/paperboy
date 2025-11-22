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
        try {
            pic.destroy.connect(() => {
                try {
                    Gtk.Picture? cur = null;
                    try { cur = url_to_picture.get(normalized); } catch (GLib.Error e) { cur = null; }
                    if (cur == pic) {
                        try { url_to_picture.remove(normalized); } catch (GLib.Error e) { }
                        try { window.append_debug_log("DEBUG: url_to_picture removed mapping for " + normalized + " on picture destroy"); } catch (GLib.Error e) { }
                    }
                } catch (GLib.Error e) { }
            });
        } catch (GLib.Error e) { }
    }

    public void register_card_for_url(string normalized, Gtk.Widget card) {
        try { url_to_card.set(normalized, card); } catch (GLib.Error e) { }
        try {
            card.destroy.connect(() => {
                try {
                    Gtk.Widget? cur = null;
                    try { cur = url_to_card.get(normalized); } catch (GLib.Error e) { cur = null; }
                    if (cur == card) {
                        try { url_to_card.remove(normalized); } catch (GLib.Error e) { }
                        try { window.append_debug_log("DEBUG: url_to_card removed mapping for " + normalized + " on widget destroy"); } catch (GLib.Error e) { }
                    }
                } catch (GLib.Error e) { }
            });
        } catch (GLib.Error e) { }
    }

    public void mark_article_viewed(string url) {
        if (url == null) return;
        string n = normalize_article_url(url);
        if (n == null || n.length == 0) return;
        if (viewed_articles == null) viewed_articles = new Gee.HashSet<string>();
        viewed_articles.add(n);

        try { window.append_debug_log("mark_article_viewed: normalized=" + n); } catch (GLib.Error e) { }
        stderr.printf("[MARK_VIEWED] URL: %s\n", n);

        Timeout.add(50, () => {
            try {
                Gtk.Widget? card = null;
                try { card = url_to_card.get(n); } catch (GLib.Error e) { card = null; }
                if (card != null) {
                    try { window.append_debug_log("mark_article_viewed: found mapped widget for " + n); } catch (GLib.Error e) { }
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
                            try { window.append_debug_log("mark_article_viewed: added viewed badge for " + n); } catch (GLib.Error e) { }
                        } else {
                            try { window.append_debug_log("mark_article_viewed: badge already exists for " + n); } catch (GLib.Error e) { }
                        }
                    } else {
                        try { window.append_debug_log("mark_article_viewed: first child is not overlay for " + n); } catch (GLib.Error e) { }
                    }
                } else {
                    try { window.append_debug_log("mark_article_viewed: no card found for " + n); } catch (GLib.Error e) { }
                }
            } catch (GLib.Error e) { 
                try { window.append_debug_log("mark_article_viewed: error adding badge - " + e.message); } catch (GLib.Error ee) { }
            }
            return false;
        });

        if (window.meta_cache != null) {
            stderr.printf("[META_CACHE] Saving viewed state for: %s\n", n);
            try { 
                window.meta_cache.mark_viewed(n); 
                stderr.printf("[META_CACHE] Successfully saved\n");
            } catch (GLib.Error e) {
                stderr.printf("[META_CACHE] Error in mark_viewed: %s\n", e.message);
            }
        } else {
            stderr.printf("[META_CACHE] meta_cache is NULL!\n");
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
        try { window.append_debug_log("preview_opened: " + (url != null ? url : "<null>") + " scroll=" + last_scroll_value.to_string()); } catch (GLib.Error e) { }
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

        try { window.append_debug_log("preview_closed: " + (url_copy != null ? url_copy : "<null>") + " scroll_to_restore=" + saved_scroll.to_string()); } catch (GLib.Error e) { }

        try { if (url_copy != null) mark_article_viewed(url_copy); } catch (GLib.Error e) { }

        try {
            if (window.main_scrolled != null && saved_scroll >= 0.0) {
                Idle.add(() => {
                    try {
                        var adj = window.main_scrolled.get_vadjustment();
                        if (adj != null) {
                            adj.set_value(saved_scroll);
                            try { window.append_debug_log("scroll restored (immediate): " + saved_scroll.to_string()); } catch (GLib.Error e) { }
                        }
                    } catch (GLib.Error e) { }
                    return false;
                }, Priority.HIGH);

                Timeout.add(100, () => {
                    try {
                        var adj = window.main_scrolled.get_vadjustment();
                        if (adj != null) {
                            adj.set_value(saved_scroll);
                            try { window.append_debug_log("scroll restored (100ms): " + saved_scroll.to_string()); } catch (GLib.Error e) { }
                        }
                    } catch (GLib.Error e) { }
                    return false;
                });

                Timeout.add(200, () => {
                    try {
                        var adj = window.main_scrolled.get_vadjustment();
                        if (adj != null) {
                            adj.set_value(saved_scroll);
                            try { window.append_debug_log("scroll restored (200ms): " + saved_scroll.to_string()); } catch (GLib.Error e) { }
                        }
                    } catch (GLib.Error e) { }
                    return false;
                });
            }
        } catch (GLib.Error e) { }

        last_scroll_value = -1.0;
    }
}

} // namespace
