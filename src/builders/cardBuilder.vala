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
using Gdk;
using Cairo;

public class CardBuilder : GLib.Object {

    public CardBuilder() {
        GLib.Object();
    }

    public static string category_display_text(NewsWindow win, string category_id) {
        if (category_id != null && category_id.has_prefix("rssfeed:")) {
            return "Feeds";
        }
        return win.category_display_name_for(category_id);
    }

    public static Gtk.Widget build_category_label(string display_text) {
        var lbl = new Gtk.Label(display_text.up());
        lbl.add_css_class("card-category-label");
        lbl.set_xalign(0);
        lbl.set_valign(Gtk.Align.START);
        lbl.set_ellipsize(Pango.EllipsizeMode.END);
        return lbl;
    }

    private static string source_display_name(NewsSource source) {
        switch (source) {
            case NewsSource.GUARDIAN: return "The Guardian";
            case NewsSource.WALL_STREET_JOURNAL: return "Wall Street Journal";
            case NewsSource.BBC: return "BBC News";
            case NewsSource.NEW_YORK_TIMES: return "NY Times";
            case NewsSource.BLOOMBERG: return "Bloomberg";
            case NewsSource.ABC_NEWS: return "ABC News";
            case NewsSource.NPR: return "NPR";
            case NewsSource.FOX: return "Fox News";
            case NewsSource.PBS: return "PBS NewsHour";
            default: return "News";
        }
    }

    // Shared with SourceMetadata.resolve_source_icon() so other UI can find the same bundled logo.
    public static NewsSource? resolve_builtin_news_source(string? display_name) {
        if (display_name == null || display_name.length == 0) return null;
        string low = display_name.down();
        if (low.index_of("guardian") >= 0) return NewsSource.GUARDIAN;
        if (low.index_of("bbc") >= 0) return NewsSource.BBC;
        if (low.index_of("nytimes") >= 0 || low.index_of("ny times") >= 0 ||
            (low.index_of("new york times") >= 0 && low.index_of("post") < 0)) return NewsSource.NEW_YORK_TIMES;
        if (low.index_of("wsj") >= 0 || low.index_of("wall street") >= 0) return NewsSource.WALL_STREET_JOURNAL;
        if (low.index_of("bloomberg") >= 0) return NewsSource.BLOOMBERG;
        if (low.index_of("abc news") >= 0 || low.index_of("abcnews") >= 0) return NewsSource.ABC_NEWS;
        if (low.index_of("npr") >= 0) return NewsSource.NPR;
        if (low.index_of("fox") >= 0) return NewsSource.FOX;
        if (low.index_of("pbs") >= 0) return NewsSource.PBS;
        return null;
    }

    public static string? source_icon_filename(NewsSource source) {
        switch (source) {
            case NewsSource.GUARDIAN: return "guardian-logo.png";
            case NewsSource.BBC: return "bbc-logo.png";
            case NewsSource.NEW_YORK_TIMES: return "nytimes-logo.png";
            case NewsSource.BLOOMBERG: return "bloomberg-logo.png";
            case NewsSource.ABC_NEWS: return "abc-logo.png";
            case NewsSource.NPR: return "npr-logo.png";
            case NewsSource.FOX: return "foxnews-logo.png";
            case NewsSource.WALL_STREET_JOURNAL: return "wsj-logo.png";
            case NewsSource.PBS: return "pbs-logo.png";
            default: return null;
        }
    }

    private static Gtk.Box create_badge_box() {
        var box = new Gtk.Box(Orientation.HORIZONTAL, 6);
        box.add_css_class("source-badge");
        box.set_margin_bottom(8);
        box.set_margin_end(8);
        box.set_valign(Gtk.Align.END);
        box.set_halign(Gtk.Align.END);
        return box;
    }

    private static Gtk.Box create_logo_wrapper() {
        var logo_wrapper = new Gtk.Box(Orientation.HORIZONTAL, 0);
        logo_wrapper.add_css_class("circular-logo");
        logo_wrapper.set_valign(Gtk.Align.CENTER);
        logo_wrapper.set_halign(Gtk.Align.CENTER);

        // Pin to 24 logical px - a Gtk.Picture's natural size is its texture's pixel
        // size, so HiDPI textures (24 * scale factor) would otherwise grow the badge.
        logo_wrapper.set_layout_manager(new Gtk.CustomLayout(null,
            (w, orientation, for_size, out minimum, out natural, out min_baseline, out nat_baseline) => {
                minimum = natural = 24;
                min_baseline = nat_baseline = -1;
            },
            (w, width, height, baseline) => {
                for (var c = w.get_first_child(); c != null; c = c.get_next_sibling()) {
                    c.allocate(width, height, baseline, null);
                }
            }));

        return logo_wrapper;
    }

    // Fits the icon into a (24 * scale)px square, preserving aspect.
    private static Gdk.Pixbuf? load_scaled_icon_pixbuf(string icon_path, int scale) {
        Gdk.Pixbuf? probe = ImageCache.get_global().get_or_load_file(
            "pixbuf::file:%s::%dx%d".printf(icon_path, 0, 0),
            icon_path,
            0,
            0
        );

        if (probe == null) {
            return null;
        }

        int orig_w = probe.get_width();
        int orig_h = probe.get_height();
        double target = 24.0 * scale;

        double factor = 1.0;
        if (orig_w > 0 && orig_h > 0) {
            factor = double.min(target / orig_w, target / orig_h);
        }

        int sw = int.max(1, (int)(orig_w * factor));
        int sh = int.max(1, (int)(orig_h * factor));

        string key = "pixbuf::file:%s::%dx%d".printf(icon_path, sw, sh);
        return ImageCache.get_global().get_or_load_file(key, icon_path, sw, sh);
    }

    private static Gtk.Picture? load_and_scale_icon(string icon_path) {
        if (icon_path == null || !GLib.FileUtils.test(icon_path, GLib.FileTest.EXISTS)) {
            return null;
        }

        Gdk.Pixbuf? scaled_pb = load_scaled_icon_pixbuf(icon_path, 1);
        if (scaled_pb == null) {
            return null;
        }

        var pic = new Gtk.Picture();
        pic.set_paintable(Gdk.Texture.for_pixbuf(scaled_pb));
        pic.set_content_fit(Gtk.ContentFit.CONTAIN);
        pic.set_halign(Gtk.Align.CENTER);
        pic.set_valign(Gtk.Align.CENTER);

        // Scale factor is only known once realized; re-render so HiDPI logos stay sharp.
        pic.realize.connect(() => {
            int scale = pic.get_scale_factor();
            if (scale <= 1) return;
            Gdk.Pixbuf? hi_pb = load_scaled_icon_pixbuf(icon_path, scale);
            if (hi_pb != null) pic.set_paintable(Gdk.Texture.for_pixbuf(hi_pb));
        });

        return pic;
    }

    private static Gtk.Box? create_logo_wrapper_from_url(NewsWindow win, string image_url) {
        if (win.image_manager == null) {
            return null;
        }

        var logo_wrapper = create_logo_wrapper();

        var pic = new Gtk.Picture();
        pic.set_valign(Gtk.Align.CENTER);
        pic.set_halign(Gtk.Align.CENTER);
        pic.set_content_fit(Gtk.ContentFit.CONTAIN);
        pic.set_size_request(24, 24);

        win.image_manager.load_image_async(pic, image_url, 24, 24);

        logo_wrapper.append(pic);

        return logo_wrapper;
    }



    private static Gtk.Label create_source_badge_label(string text, int max_width_chars = 14) {
        var lbl = new Gtk.Label(text);
        lbl.add_css_class("source-badge-label");
        lbl.set_valign(Gtk.Align.CENTER);
        lbl.set_xalign(0.5f);
        lbl.set_ellipsize(Pango.EllipsizeMode.END);
        lbl.set_max_width_chars(max_width_chars);
        return lbl;
    }

    private static Gtk.Box? create_logo_wrapper_from_file(string? icon_path) {
        if (icon_path == null) {
            return null;
        }
        Gtk.Picture? pic = load_and_scale_icon(icon_path);
        if (pic == null) {
            return null;
        }
        var logo_wrapper = create_logo_wrapper();
        logo_wrapper.append(pic);
        return logo_wrapper;
    }

    public static Gtk.Widget build_source_badge(NewsSource source) {
        var box = create_badge_box();

        string? filename = source_icon_filename(source);
        if (filename != null) {
            string? path = DataPathsUtils.find_data_file("icons/" + filename);
            Gtk.Box? logo_wrapper = create_logo_wrapper_from_file(path);
            if (logo_wrapper != null) {
                box.append(logo_wrapper);
            }
        }

        var lbl = create_source_badge_label(source_display_name(source), 12);
        box.append(lbl);

        return box;
    }

    // API-backed articles can encode source display name and logo URL in `source_name`
    // as "Name||logo_url##category::category_id".
    // This function centralizes decoding of that format.
    public static void parse_encoded_source_name(string? source_name, out string? display_name, out string? logo_url) {
        logo_url = null;
        display_name = source_name;
        if (source_name != null && source_name.index_of("||") >= 0) {
            string[] parts = source_name.split("||");
            if (parts.length >= 1) display_name = parts[0].strip();
            if (parts.length >= 2) {
                logo_url = parts[1].strip();
                int lcat_idx = logo_url.index_of("##category::");
                if (lcat_idx >= 0 && logo_url.length > lcat_idx) logo_url = logo_url.substring(0, lcat_idx).strip();
            }
        }
        if (display_name != null) {
            int cat_idx = display_name.index_of("##category::");
            if (cat_idx >= 0 && display_name.length > cat_idx) display_name = display_name.substring(0, cat_idx).strip();
        }
    }

    private static Gtk.Widget build_badge_with_optional_logo(string display_text, Gtk.Box? logo_wrapper) {
        var box = create_badge_box();
        if (logo_wrapper != null) {
            box.append(logo_wrapper);
        }
        var lbl = create_source_badge_label(display_text);
        box.append(lbl);
        return box;
    }

    // Tries to load a source logo in order: saved local file -> metadata logo URL -> Google favicon -> RSS favicon.
    private static Gtk.Box? try_load_icon_from_metadata(NewsWindow win, string? meta_filename, string? meta_logo_url, string? rss_url, string? rss_favicon_url) {
        if (meta_filename != null) {
            var data_dir = GLib.Environment.get_user_data_dir();
            var icon_path = GLib.Path.build_filename(data_dir, "paperboy", "source_logos", meta_filename);
            Gtk.Box? wrapper = create_logo_wrapper_from_file(icon_path);
            if (wrapper != null) {
                return wrapper;
            }
        }

        if (meta_logo_url != null && meta_logo_url.length > 0 &&
            (meta_logo_url.has_prefix("http://") || meta_logo_url.has_prefix("https://"))) {
            return create_logo_wrapper_from_url(win, meta_logo_url);
        }

        if (rss_url != null && rss_url.length > 0) {
            string? host = UrlUtils.extract_host_from_url(rss_url);
            if (host != null && host.length > 0) {
                string google_favicon_url = "https://www.google.com/s2/favicons?domain=" + host + "&sz=128";
                return create_logo_wrapper_from_url(win, google_favicon_url);
            }
        }

        if (rss_favicon_url != null && rss_favicon_url.length > 0 &&
            (rss_favicon_url.has_prefix("http://") || rss_favicon_url.has_prefix("https://"))) {
            return create_logo_wrapper_from_url(win, rss_favicon_url);
        }

        return null;
    }

    private static string get_final_display_name(string? display_name, string? source_name) {
        if (display_name != null && display_name.length > 0) {
            return display_name;
        }
        if (source_name != null && source_name.length > 0) {
            return source_name;
        }
        return "News";
    }

    public static Gtk.Widget build_source_badge_dynamic(NewsWindow win, string? source_name, string? url, string? category_id) {
        string? provided_logo_url = null;
        string? display_name = null;
        parse_encoded_source_name(source_name, out display_name, out provided_logo_url);

        // For My Feed: first try SourceMetadata, then fall back to matching an RSS source by name or URL/domain.
        if (category_id == "myfeed") {
            string? meta_logo_url = null;
            string? meta_filename = null;
            string? meta_display_name = null;

            if (display_name != null && display_name.length > 0) {
                meta_logo_url = SourceMetadata.get_logo_url_for_source(display_name);
                meta_filename = SourceMetadata.get_saved_filename_for_source(display_name);
                meta_display_name = SourceMetadata.get_display_name_for_source(display_name);
            }

            if (meta_logo_url == null && meta_filename == null && url != null && url.length > 0) {
                string? url_display_name = null;
                string? url_logo_url = null;
                string? url_filename = null;
                SourceMetadata.get_source_info_by_url(url, out url_display_name, out url_logo_url, out url_filename);
                if (url_display_name != null || url_logo_url != null || url_filename != null) {
                    meta_display_name = url_display_name;
                    meta_logo_url = url_logo_url;
                    meta_filename = url_filename;
                }
            }

            if (meta_logo_url != null || meta_filename != null) {
                if (meta_display_name != null && meta_display_name.length > 0) {
                    display_name = meta_display_name;
                }
                Gtk.Box? logo_wrapper = try_load_icon_from_metadata(win, meta_filename, meta_logo_url, null, null);
                return build_badge_with_optional_logo(display_name != null ? display_name : "", logo_wrapper);
            }
        }

        if (provided_logo_url == null && category_id == "myfeed") {
            var rss_store = Paperboy.RssSourceStore.get_instance();
            var all_sources = rss_store.get_all_sources();
            foreach (var src in all_sources) {
                bool is_match = false;

                if (source_name != null && source_name == src.name) {
                    is_match = true;
                }

                if (!is_match && url != null && url.length > 0) {
                    string src_host = UrlUtils.extract_host_from_url(src.url);
                    string article_host = UrlUtils.extract_host_from_url(url);
                    if (src_host != null && article_host != null && src_host == article_host) {
                        is_match = true;
                    }
                }

                if (is_match) {
                    string? dummy_logo_url;
                    string final_display_name;
                    parse_encoded_source_name(src.name, out final_display_name, out dummy_logo_url);

                    string? meta_logo_url = SourceMetadata.get_logo_url_for_source(final_display_name);
                    string? meta_filename = SourceMetadata.get_saved_filename_for_source(final_display_name);

                    Gtk.Box? logo_wrapper = try_load_icon_from_metadata(win, meta_filename, meta_logo_url, src.url, src.favicon_url);
                    return build_badge_with_optional_logo(final_display_name, logo_wrapper);
                }
            }
        }

        if (provided_logo_url == null && display_name != null && display_name.length > 0) {
            NewsSource? resolved = resolve_builtin_news_source(display_name);
            if (resolved != null) {
                return build_source_badge(resolved);
            }
        }

        if (provided_logo_url == null && display_name != null && display_name.length > 0) {
            string? meta_logo_url = SourceMetadata.get_logo_url_for_source(display_name);
            string? meta_filename = SourceMetadata.get_saved_filename_for_source(display_name);
            
            if (meta_logo_url != null || meta_filename != null) {
                Gtk.Box? logo_wrapper = try_load_icon_from_metadata(win, meta_filename, meta_logo_url, null, null);
                return build_badge_with_optional_logo(display_name, logo_wrapper);
            }
        }

        bool is_aggregated = (category_id != null && (category_id == "frontpage" || category_id == "topten" || category_id == "myfeed"));
        if (is_aggregated && display_name != null && display_name.length > 0 && provided_logo_url == null) {
            return build_badge_with_optional_logo(display_name, null);
        }

        if (provided_logo_url != null) {
            provided_logo_url = provided_logo_url.strip();
            if (provided_logo_url.has_prefix("//")) provided_logo_url = "https:" + provided_logo_url;
        }

        if (provided_logo_url != null && (provided_logo_url.has_prefix("http://") || provided_logo_url.has_prefix("https://"))) {
            Gtk.Box? logo_wrapper = create_logo_wrapper_from_url(win, provided_logo_url);
            string final_display = get_final_display_name(display_name, source_name);
            return build_badge_with_optional_logo(final_display, logo_wrapper);
        }

        if (display_name != null && display_name.length > 0) {
            string low = display_name.down();
            var sb = new StringBuilder();
            for (int i = 0; i < low.length; i++) {
                char c = low[i];
                if (c.isalnum() || c == ' ' || c == '-' || c == '_') sb.append_c(c);
                else sb.append_c(' ');
            }
            string cleaned = sb.str.strip();
            string hyphen = cleaned.replace(" ", "-").replace("--", "-");
            string underscore = cleaned.replace(" ", "_").replace("__", "_");
            string concat = cleaned.replace(" ", "");
            string[] cands = { hyphen, underscore, concat };
            foreach (var cand in cands) {
                string[] paths = {
                    GLib.Path.build_filename("icons", cand + "-logo.png"),
                    GLib.Path.build_filename("icons", cand + "-logo.svg"),
                    GLib.Path.build_filename("icons", "symbolic", cand + "-symbolic.svg"),
                    GLib.Path.build_filename("icons", cand + ".png"),
                    GLib.Path.build_filename("icons", cand + ".svg")
                };
                foreach (var rel in paths) {
                    string? full = DataPathsUtils.find_data_file(rel);
                    if (full != null) {
                        Gtk.Box? logo_wrapper = create_logo_wrapper_from_file(full);
                        string final_display = get_final_display_name(display_name, source_name);
                        return build_badge_with_optional_logo(final_display, logo_wrapper);
                    }
                }
            }
        }

        string final_display = get_final_display_name(display_name, source_name);
        return build_badge_with_optional_logo(final_display, null);
    }

    // Eye icon represents that the article has been read/viewed.
    public static Gtk.Widget build_viewed_badge() {
        var box = new Gtk.Box(Orientation.HORIZONTAL, 4);
        box.add_css_class("viewed-badge");
        box.set_valign(Gtk.Align.CENTER);

        var icon = new Gtk.Image.from_icon_name("view-reveal-symbolic");
        icon.set_pixel_size(14);
        icon.get_style_context().add_class("viewed-badge-icon");
        icon.set_valign(Gtk.Align.CENTER); icon.set_halign(Gtk.Align.CENTER);
        box.append(icon);

        var lbl = new Gtk.Label("Read");
        lbl.get_style_context().remove_class("dim-label");
        lbl.add_css_class("viewed-badge-label");
        lbl.add_css_class("caption");
        box.append(lbl);
        return box;
    }

    public const int SAVE_RIBBON_HEIGHT = 50;
    public const int SAVE_RIBBON_REST_Y = -8;
    public const int SAVE_RIBBON_HIDDEN_Y = SAVE_RIBBON_REST_Y - SAVE_RIBBON_HEIGHT;

    // Uses Gtk.Fixed with negative Y positioning to poke above the card. Hidden with set_visible(false) when unsaved
    // to avoid reserving space in the layout.
    public static Gtk.Widget build_save_ribbon(bool initially_saved) {
        var tab = new Gtk.Image();
        tab.add_css_class("save-ribbon");
        int icon_px = SAVE_RIBBON_HEIGHT - 6;

        string? asset_path = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "symbolic", "save-ribbon.png"));
        if (asset_path != null) {
            var cache = ImageCache.get_global();
            int hi = icon_px * 2;
            string key = "pixbuf::file:%s::%dx%d".printf(asset_path, hi, hi);
            if (cache.get_or_load_file(key, asset_path, hi, hi) != null) {
                var tex = cache.get_texture(key);
                if (tex != null) tab.set_from_paintable(tex);
            }
        }
        if (tab.get_paintable() == null) {
            tab.set_from_icon_name("user-bookmarks-symbolic");
        }
        tab.set_pixel_size(icon_px);
        tab.set_size_request(icon_px, icon_px);
        tab.set_visible(initially_saved);

        var fixed = new Gtk.Fixed();
        //fixed.set_halign(Gtk.Align.END);
        fixed.set_halign(Gtk.Align.START);
        fixed.set_valign(Gtk.Align.START);
        fixed.set_margin_start(8);
        fixed.set_size_request(icon_px, icon_px);
        fixed.put(tab, 0, initially_saved ? SAVE_RIBBON_REST_Y : SAVE_RIBBON_HIDDEN_Y);
        fixed.set_data<Gtk.Widget>("ribbon-image", tab);
        return fixed;
    }

}