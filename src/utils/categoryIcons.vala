// Utility for creating category icons (both sidebar and header variants).
// This mirrors the previous logic in `appWindow.vala` but centralizes it
// so other modules can reuse the same icon-selection behavior.

using GLib;
using Gtk;
using Gdk;
using Adw;

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
            case "all": filename = "all-mono.svg"; break;
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

                    var img = new Gtk.Image.from_file(use_path);
                    img.set_pixel_size(SIDEBAR_ICON_SIZE);
                    return img;
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
            case "all":
                candidates = { "view-list-symbolic", "applications-all-symbolic", "folder-symbolic" };
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
            case "all": filename = "all-mono.svg"; break;
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
                            var img = new Gtk.Image.from_file(use_path);
                            img.set_pixel_size(size);
                            return img;
                        } catch (GLib.Error e) {
                            // Fall back to pixbuf path below on error
                        }
                    }

                    var pix = new Gdk.Pixbuf.from_file_at_size(use_path, size, size);
                    if (pix != null) {
                        var tex = Gdk.Texture.for_pixbuf(pix);
                        var img = new Gtk.Image();
                        try { img.set_from_paintable(tex); } catch (GLib.Error e) { try { img.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { } }
                        return img;
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
