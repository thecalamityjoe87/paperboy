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
using Gtk;
using Gdk;
using Adw;

/* 
 * Utility for creating category icons (both sidebar and header variants).
 * This mirrors the previous logic in `appWindow.vala` but centralizes it
 * so other modules can reuse the same icon-selection behavior.
 */

public class CategoryIcons : GLib.Object {
    private const int SIDEBAR_ICON_SIZE = 24;

    // Use centralized DataPaths helpers for file location logic

    private static bool is_dark_mode() {
        var sm = Adw.StyleManager.get_default();
        return sm != null ? sm.dark : false;
    }

    // Create a category icon widget for sidebar-sized use.
    public static Gtk.Widget? create_category_icon(string cat) {
        string? filename = null;
        switch (cat) {
            case "topten": filename = "topten-mono.svg"; break;
            case "frontpage": filename = "frontpage-mono.svg"; break;
            case "myfeed": filename = "myfeed-mono.svg"; break;
            case "general": filename = "world-mono.svg"; break;
            case "markets": filename = "markets-mono.svg"; break;
            case "industries": filename = "industries-mono.svg"; break;
            case "economics": filename = "economics-mono.svg"; break;
            case "wealth": filename = "wealth-mono.svg"; break;
            case "green": filename = "green-mono.svg"; break;
            case "us": filename = "us-mono.svg"; break;
            case "local_news": filename = "local-mono.svg"; break;
            case "technology": filename = "technology-mono.svg"; break;
            case "business": filename = "business-mono.svg"; break;
            case "science": filename = "science-mono.svg"; break;
            case "sports": filename = "sports-mono.svg"; break;
            case "health": filename = "health-mono.svg"; break;
            case "entertainment": filename = "entertainment-mono.svg"; break;
            case "politics": filename = "politics-mono.svg"; break;
            case "lifestyle": filename = "lifestyle-mono.svg"; break;
            default: filename = null; break;
        }

        if (filename != null) {
            string[] candidates = {
                GLib.Path.build_filename("icons", "symbolic", filename),
                GLib.Path.build_filename("icons", filename)
            };
            string? icon_path = null;
            foreach (var c in candidates) {
                icon_path = DataPaths.find_data_file(c);
                if (icon_path != null) break;
            }

            if (icon_path != null) {
                try {
                    string use_path = icon_path;
                    if (is_dark_mode()) {
                        string alt_name;
                        if (filename.has_suffix(".svg"))
                            alt_name = filename.substring(0, filename.length - 4) + "-white.svg";
                        else
                            alt_name = filename + "-white.svg";

                        string? white_candidate = null;
                        white_candidate = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", alt_name));
                        if (white_candidate == null) white_candidate = DataPaths.find_data_file(GLib.Path.build_filename("icons", alt_name));
                        if (white_candidate != null) use_path = white_candidate;
                    }

                    string key = "pixbuf::file:%s::%dx%d".printf(use_path, SIDEBAR_ICON_SIZE, SIDEBAR_ICON_SIZE);
                    var cached = ImageCache.get_global().get_or_load_file(key, use_path, SIDEBAR_ICON_SIZE, SIDEBAR_ICON_SIZE);
                    if (cached != null) {
                        try {
                            // Use cached texture instead of creating new one every time
                            var tex = ImageCache.get_global().get_texture(key);
                            if (tex != null) {
                                var img = new Gtk.Image();
                                try { img.set_from_paintable(tex); } catch (GLib.Error e) { }
                                img.set_pixel_size(SIDEBAR_ICON_SIZE);
                                return img;
                            }
                        } catch (GLib.Error e) { }
                    }
                    try {
                        var img2 = new Gtk.Image.from_file(use_path);
                        img2.set_pixel_size(SIDEBAR_ICON_SIZE);
                        return img2;
                    } catch (GLib.Error e) { }
                } catch (GLib.Error e) {
                    warning("Failed to load bundled icon %s: %s", icon_path, e.message);
                }
            }
        }

        string[] candidates;
        switch (cat) {
            case "topten":
                candidates = { "starred-symbolic", "emblem-favorite-symbolic", "non-starred-symbolic" };
                break;
            case "frontpage":
                candidates = { "go-home-symbolic", "applications-home-symbolic", "home-symbolic" };
                break;
            case "general":
                candidates = { "globe-symbolic", "emblem-web-symbolic" };
                break;
            case "us":
                candidates = { "mark-location-symbolic", "flag-symbolic", "map-symbolic" };
                break;
            case "local_news":
                candidates = { "mark-location-symbolic", "map-marker-symbolic", "map-symbolic" };
                break;
            case "technology":
                candidates = { "computer-symbolic", "applications-engineering-symbolic", "applications-system-symbolic" };
                break;
            case "business":
                // Use the specific business assets if present, otherwise fall back
                // to money/economics symbolic icons.
                candidates = { "business-symbolic", "economics-symbolic", "wealth-symbolic", "emblem-money-symbolic" };
                break;
            case "science":
                candidates = { "applications-science-symbolic", "utilities-science-symbolic", "view-list-symbolic" };
                break;
            case "sports":
                candidates = { "applications-games-symbolic", "emblem-favorite-symbolic" };
                break;
            case "health":
                candidates = { "face-smile-symbolic", "emblem-ok-symbolic", "help-about-symbolic" };
                break;
            case "entertainment":
                candidates = { "applications-multimedia-symbolic", "media-playback-start-symbolic", "emblem-videos-symbolic" };
                break;
            case "politics":
                candidates = { "emblem-system-symbolic", "preferences-system-symbolic", "emblem-important-symbolic" };
                break;
            case "lifestyle":
                candidates = { "org.gnome.Software-symbolic", "shopping-bag-symbolic", "emblem-favorite-symbolic", "preferences-desktop-personal-symbolic" };
                break;
            default:
                candidates = {};
                break;
        }
        var theme = Gtk.IconTheme.get_for_display(Gdk.Display.get_default());
        foreach (var candidate in candidates) {
            if (theme != null && theme.has_icon(candidate)) {
                var img = new Gtk.Image.from_icon_name(candidate);
                img.set_pixel_size(SIDEBAR_ICON_SIZE);
                return img;
            }
        }
        return null;
    }

    // Create a header-ready category icon using larger/bundled assets.
    public static Gtk.Widget? create_category_header_icon(string cat, int size) {
        string? filename = null;
        switch (cat) {
            case "frontpage": filename = "frontpage-mono.svg"; break;
            case "myfeed": filename = "myfeed-mono.svg"; break;
            case "general": filename = "world-mono.svg"; break;
            case "markets": filename = "markets-mono.svg"; break;
            case "industries": filename = "industries-mono.svg"; break;
            case "economics": filename = "economics-mono.svg"; break;
            case "wealth": filename = "wealth-mono.svg"; break;
            case "green": filename = "green-mono.svg"; break;
            case "us": filename = "us-mono.svg"; break;
            case "local_news": filename = "local-mono.svg"; break;
            case "technology": filename = "technology-mono.svg"; break;
            case "business": filename = "business-mono.svg"; break;
            case "science": filename = "science-mono.svg"; break;
            case "sports": filename = "sports-mono.svg"; break;
            case "health": filename = "health-mono.svg"; break;
            case "entertainment": filename = "entertainment-mono.svg"; break;
            case "politics": filename = "politics-mono.svg"; break;
            case "lifestyle": filename = "lifestyle-mono.svg"; break;
            default: filename = null; break;
        }

        if (filename != null) {
            string[] candidates = {
                GLib.Path.build_filename("icons", "symbolic", "128x128", filename),
                GLib.Path.build_filename("icons", "128x128", filename),
                GLib.Path.build_filename("icons", filename)
            };
            string? icon_path = null;
            foreach (var c in candidates) {
                icon_path = DataPaths.find_data_file(c);
                if (icon_path != null) break;
            }

            if (icon_path != null) {
                try {
                    string use_path = icon_path;
                    if (is_dark_mode()) {
                        string alt_name;
                        if (filename.has_suffix(".svg"))
                            alt_name = filename.substring(0, filename.length - 4) + "-white.svg";
                        else
                            alt_name = filename + "-white.svg";
                        string? white_candidate = null;
                        white_candidate = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "128x128", alt_name));
                        if (white_candidate == null) white_candidate = DataPaths.find_data_file(GLib.Path.build_filename("icons", "128x128", alt_name));
                        if (white_candidate != null) use_path = white_candidate;
                    }
                    if (use_path.has_suffix(".svg")) {
                        try {
                            // Rasterize SVG to a higher-resolution pixbuf to avoid
                            // blur on small sizes and when running on a HiDPI
                            // display. Rendering at 2x the requested size then
                            // scaling down improves visual crispness for icons.
                            int render_size = size * 2;
                            string key_hi = "pixbuf::file:%s::%dx%d".printf(use_path, render_size, render_size);
                            var cached_hi = ImageCache.get_global().get_or_load_file(key_hi, use_path, render_size, render_size);
                            if (cached_hi != null) {
                                // Use cached texture instead of creating new one
                                var tex = ImageCache.get_global().get_texture(key_hi);
                                if (tex != null) {
                                    var img = new Gtk.Image();
                                    try { img.set_from_paintable(tex); } catch (GLib.Error e) { }
                                    img.set_pixel_size(size);
                                    img.add_css_class("header-category-icon");
                                    return img;
                                }
                            }
                        } catch (GLib.Error e) {
                            // Fall back to pixbuf path below on error
                        }
                    }

                    string key_sz = "pixbuf::file:%s::%dx%d".printf(use_path, size, size);
                    var cached_sz = ImageCache.get_global().get_or_load_file(key_sz, use_path, size, size);
                    if (cached_sz != null) {
                        try {
                            // Use cached texture instead of creating new one
                            var tex = ImageCache.get_global().get_texture(key_sz);
                            if (tex != null) {
                                var img = new Gtk.Image();
                                try { img.set_from_paintable(tex); } catch (GLib.Error e) {
                                    try { img.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { }
                                }
                                img.add_css_class("header-category-icon");
                                return img;
                            }
                        } catch (GLib.Error e) { }
                    }
                } catch (GLib.Error e) {
                    // fall through to theme icons below
                }
            }
        }
        // Fallback to sidebar icon behavior for header if no header asset found
        return create_category_icon(cat);
    }
}
