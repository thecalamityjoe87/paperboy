/*
 * Copyright (C) 2025  Isaac Joseph <calamityjoe87@gmail.com>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

using Gtk;
using Adw;
using Soup;

public class ArticleItem : GLib.Object {
    public string title { get; set; }
    public string url { get; set; }
    public string? thumbnail_url { get; set; }
    public string category_id { get; set; }
    
    public ArticleItem(string title, string url, string? thumbnail_url, string category_id) {
        this.title = title;
        this.url = url;
        this.thumbnail_url = thumbnail_url;
        this.category_id = category_id;
    }
}
 
// Image download helper functions live below; queueing removed in favor of a simpler
// approach (cache + direct download threads). This keeps code straightforward now
// that we use on-disk caching to reduce redundant downloads.

// Track hero image requests so we can re-request higher-res images when layout changes
private class HeroRequest : GLib.Object {
    public string url { get; set; }
    public int last_requested_w { get; set; }
    public int last_requested_h { get; set; }
    public int multiplier { get; set; }
    public int retries { get; set; }

    public HeroRequest(string url, int w, int h, int multiplier) {
        this.url = url;
        this.last_requested_w = w;
        this.last_requested_h = h;
        this.multiplier = multiplier;
        this.retries = 0;
    }
}
    

public class NewsWindow : Adw.ApplicationWindow {
    // Masonry layout: horizontal row of vertical columns
    private Gtk.Box columns_row;
    private Gtk.Box[] columns;
    private int[] column_heights;
    private int columns_count = 3;
    // Featured hero container for the first story
    private Gtk.Box featured_box;
    private bool featured_used = false;
    // Carousel for featured/top stories (up to 5)
    private Gee.ArrayList<ArticleItem> featured_carousel_items;
    private Gtk.Stack? featured_carousel_stack;
    private Gtk.Box? featured_carousel_dots_box;
    private int featured_carousel_index = 0;
    private uint featured_carousel_timeout_id = 0;
    private string? featured_carousel_category = null;
    private Gee.ArrayList<Gtk.Label> featured_carousel_dot_widgets;
    // Hero container reference for responsive sizing
    private Gtk.Box hero_container;
    // Main content container that holds both hero and columns
    private Gtk.Box main_content_container;
    // Content area container that constrains to window size
    private Gtk.Box content_area;
    private Gtk.Box content_box;
    // Content default sizing constants
    private const int H_MARGIN = 12;
    private const int COL_SPACING = 12;
    // Sidebar icon size (monochrome icons)
    private const int SIDEBAR_ICON_SIZE = 24;
    private Soup.Session session;
    private GLib.Rand rng;
    private static int active_downloads = 0;
    // Increase concurrent downloads to improve initial load throughput while
    // keeping a reasonable cap to avoid overwhelming the system.
    private const int MAX_CONCURRENT_DOWNLOADS = 10;
    private string current_search_query = "";
    private Gtk.Label category_label;
    private Gtk.Label source_label;
    private Gtk.Image source_logo;
    private Gtk.ToggleButton sidebar_toggle;
    private Gtk.Box sidebar_spacer;
    private Gtk.ListBox sidebar_list;
    private Adw.OverlaySplitView split_view;
    private Gtk.ScrolledWindow sidebar_scrolled;
    private NewsPreferences prefs;
    // Holders for sidebar prefix icons so we can live-switch on theme changes
    private Gee.HashMap<string, Gtk.Box> sidebar_icon_holders = new Gee.HashMap<string, Gtk.Box>();
    // Navigation for sliding article preview
    private Adw.NavigationView nav_view;
    private Gtk.Button back_btn;
    private ArticleWindow article_window;
    // Track category distribution across columns for better spread
    private Gee.HashMap<string, int> category_column_counts;
    // Track recent category placements to prevent horizontal clustering
    private Gee.ArrayList<string> recent_categories;
    // Simple counter for round-robin distribution in "All News"
    private int next_column_index;
    // Buffer for articles when in "All News" mode to allow shuffling
    public Gee.ArrayList<ArticleItem> article_buffer;
    // Track hero image request metadata so we can re-fetch on resize
    private Gee.HashMap<Gtk.Picture, HeroRequest> hero_requests;
    // Map article URL -> picture widget so we can update images in-place when higher-res images arrive
    private Gee.HashMap<string, Gtk.Picture> url_to_picture;

    // Cache system/user data dirs to avoid querying the environment repeatedly
    private string[] system_data_dirs_cached;
    private string? user_data_dir_cached;

    // No explicit download queue; downloads are performed directly (cache reduces load).

    // Normalize article URLs for stable mapping (strip query params, trailing slash, lowercase host)
    private string normalize_article_url(string url) {
        if (url == null) return "";
    string u = url.strip();
        // Remove query string entirely (utm and tracking params commonly appended)
        int qpos = u.index_of("?");
        if (qpos >= 0) {
            u = u.substring(0, qpos);
        }
        // Remove trailing slash
        while (u.length > 1 && u.has_suffix("/")) {
            u = u.substring(0, u.length - 1);
        }
        // Lowercase scheme and host portion
        int scheme_end = u.index_of("://");
        if (scheme_end >= 0) {
            int path_start = u.index_of("/", scheme_end + 3);
            string host_part = path_start >= 0 ? u.substring(0, path_start) : u;
            string rest = path_start >= 0 ? u.substring(path_start) : "";
            host_part = host_part.down();
            u = host_part + rest;
        } else {
            u = u.down();
        }
        return u;
    }

    // Update the visible state of the carousel dots based on the active index.
    private void update_carousel_dots(int active_index) {
        if (featured_carousel_dot_widgets == null) return;
        int total = featured_carousel_items != null ? featured_carousel_items.size : 0;
        for (int i = 0; i < featured_carousel_dot_widgets.size; i++) {
            var dot = featured_carousel_dot_widgets[i];
            // Dim dots that represent slides not yet populated
            if (i >= total) {
                dot.add_css_class("inactive");
                dot.remove_css_class("active");
            } else {
                dot.remove_css_class("inactive");
                if (i == active_index) {
                    dot.add_css_class("active");
                } else {
                    dot.remove_css_class("active");
                }
            }
        }
    }

    // Move carousel to the next slide
    private void carousel_next() {
        if (featured_carousel_stack == null) return;
        int total = featured_carousel_items != null ? featured_carousel_items.size : 0;
        if (total <= 1) return;
        featured_carousel_index = (featured_carousel_index + 1) % total;
        string name = "%d".printf(featured_carousel_index);
        featured_carousel_stack.set_visible_child_name(name);
        update_carousel_dots(featured_carousel_index);
    }

    // Move carousel to the previous slide
    private void carousel_prev() {
        if (featured_carousel_stack == null) return;
        int total = featured_carousel_items != null ? featured_carousel_items.size : 0;
        if (total <= 1) return;
        featured_carousel_index = (featured_carousel_index - 1 + total) % total;
        string name = "%d".printf(featured_carousel_index);
        featured_carousel_stack.set_visible_child_name(name);
        update_carousel_dots(featured_carousel_index);
    }
    
    // Remaining articles after hitting the Load More limit
    private ArticleItem[]? remaining_articles = null;
    private int remaining_articles_index = 0;
    
    // Track column assignments for each category to ensure spread
    private Gee.HashMap<string, int> category_last_column;
    
    // Smart category distribution tracking
    private Gee.ArrayList<string> recent_category_queue;
    private const int MAX_RECENT_CATEGORIES = 6;
    
    // Article count and "Load More" functionality
    private int articles_shown = 0;
    private const int INITIAL_ARTICLE_LIMIT = 30;
    private Gtk.Button? load_more_button = null;
    private uint buffer_flush_timeout_id = 0;
    // Fetch sequencing token to ignore stale background fetch callbacks
    private uint fetch_sequence = 0;
    
    // Loading spinner for initial content load
    private Gtk.Spinner? loading_spinner = null;
    private Gtk.Box? loading_container = null;
    // Initial-load gating: wait for hero (or timeout) before revealing main content
    private bool initial_phase = false;
    private bool hero_image_loaded = false;
    private uint initial_reveal_timeout_id = 0;
    // Track pending image loads during initial phase so we can keep the spinner
    // visible until all initial images are ready (with a safety timeout).
    private int pending_images = 0;
    private bool initial_items_populated = false;
    private const int INITIAL_MAX_WAIT_MS = 5000; // maximum time to wait for images

    // Locate data files both in development tree (data/...) and installed locations
    private string? find_data_file(string relative) {
        // Development-time paths (running from project or build dir)
        string[] dev_prefixes = { "data", "../data" };
        foreach (var prefix in dev_prefixes) {
            var path = GLib.Path.build_filename(prefix, relative);
            if (GLib.FileUtils.test(path, GLib.FileTest.EXISTS)) {
                return path;
            }
        }

        // User data dir (e.g., ~/.local/share/paperboy/...)
        var user_data = user_data_dir_cached != null ? user_data_dir_cached : GLib.Environment.get_user_data_dir();
        if (user_data != null && user_data.length > 0) {
            var user_path = GLib.Path.build_filename(user_data, "paperboy", relative);
            if (GLib.FileUtils.test(user_path, GLib.FileTest.EXISTS)) {
                return user_path;
            }
        }

        // System data dirs (e.g., /usr/share or /usr/local/share) - use cached copy
        var sys_dirs = system_data_dirs_cached != null ? system_data_dirs_cached : GLib.Environment.get_system_data_dirs();
        foreach (var dir in sys_dirs) {
            var sys_path = GLib.Path.build_filename(dir, "paperboy", relative);
            if (GLib.FileUtils.test(sys_path, GLib.FileTest.EXISTS)) {
                return sys_path;
            }
        }
        return null;
    }

    // Create a category icon widget from our custom icons, with theme fallbacks
    private Gtk.Widget? create_category_icon(string cat) {
        string? filename = null;
        switch (cat) {
            case "all": filename = "all-mono.svg"; break;
            case "general": filename = "world-mono.svg"; break;
            case "markets": filename = "markets-mono.svg"; break;
            case "industries": filename = "industries-mono.svg"; break;
            case "economics": filename = "economics-mono.svg"; break;
            case "wealth": filename = "wealth-mono.svg"; break;
            case "green": filename = "green-mono.svg"; break;
            case "us": filename = "us-mono.svg"; break;
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
            var icon_path = find_data_file(GLib.Path.build_filename("icons", filename));
            if (icon_path != null) {
                try {
                    // If we're in dark mode and the icon has colors tuned for light
                    // backgrounds, produce/get a white variant to improve contrast.
                    string? maybe_white = null;
                    if (is_dark_mode()) {
                        maybe_white = ensure_white_icon_for(icon_path);
                    }
                    var load_path = maybe_white != null ? maybe_white : icon_path;
                    // Load the image directly from the data directory and size it
                    var img = new Gtk.Image.from_file(load_path);
                    img.set_pixel_size(SIDEBAR_ICON_SIZE);
                    return img;
                } catch (GLib.Error e) {
                    // fall through to theme icons
                    warning("Failed to load bundled icon %s: %s", icon_path, e.message);
                }
            }
        }
        // Fallback to theme icons chain
        string[] candidates;
        switch (cat) {
            case "all":
                candidates = { "view-list-symbolic", "applications-all-symbolic", "folder-symbolic" };
                break;
            case "general":
                candidates = { "globe-symbolic", "emblem-web-symbolic" };
                break;
            case "us":
                candidates = { "mark-location-symbolic", "flag-symbolic", "map-symbolic" };
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

    // Helper to add a section header to the sidebar
    private void sidebar_add_header(string title) {
        var header_row = new Adw.ActionRow();
        header_row.set_title(title);
        header_row.activatable = false;
        header_row.add_css_class("caption-heading");
        header_row.set_margin_top(12);
        header_row.set_margin_bottom(6);
        sidebar_list.append(header_row);
    }

    // Helper to add a row with optional icon and switch category
    private void sidebar_add_row(string title, string cat, bool selected=false) {
        var row = new Adw.ActionRow();
        row.set_title(title);
        row.activatable = true;
        // Use a holder box for the icon so we can replace it on theme changes
        var holder = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        holder.set_hexpand(false);
        holder.set_vexpand(false);
        // Prefer custom icons bundled with the app; fall back to theme icons
        var prefix_widget = create_category_icon(cat);
        if (prefix_widget != null) { holder.append(prefix_widget); }
        row.add_prefix(holder);
        sidebar_icon_holders.set(cat, holder);

        row.activated.connect(() => {
            prefs.category = cat;
            prefs.save_config();
            fetch_news();
            sidebar_list.select_row(row);
        });
        sidebar_list.append(row);
        if (selected) sidebar_list.select_row(row);
    }

    // Rebuild the sidebar rows according to the currently selected source
    private void rebuild_sidebar_rows_for_source() {
        // Clear existing rows
        Gtk.Widget? child = sidebar_list.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            sidebar_list.remove(child);
            child = next;
        }

        // Always include All News
        sidebar_add_row("All News", "all", prefs.category == "all");
        sidebar_add_header("Categories");

        if (prefs.news_source == NewsSource.BLOOMBERG) {
            // Bloomberg-specific categories
            sidebar_add_row("Markets", "markets", prefs.category == "markets");
            sidebar_add_row("Industries", "industries", prefs.category == "industries");
            sidebar_add_row("Economics", "economics", prefs.category == "economics");
            sidebar_add_row("Wealth", "wealth", prefs.category == "wealth");
            sidebar_add_row("Green", "green", prefs.category == "green");
            // Keep technology for Bloomberg as well
            sidebar_add_row("Technology", "technology", prefs.category == "technology");
            // Also expose politics for completeness
            sidebar_add_row("Politics", "politics", prefs.category == "politics");
        } else {
            // Default set used for most sources
            sidebar_add_row("World News", "general", prefs.category == "general");
            sidebar_add_row("US News", "us", prefs.category == "us");
            sidebar_add_row("Technology", "technology", prefs.category == "technology");
            sidebar_add_row("Science", "science", prefs.category == "science");
            sidebar_add_row("Sports", "sports", prefs.category == "sports");
            sidebar_add_row("Health", "health", prefs.category == "health");
            sidebar_add_row("Entertainment", "entertainment", prefs.category == "entertainment");
            sidebar_add_row("Politics", "politics", prefs.category == "politics");
            sidebar_add_row("Lifestyle", "lifestyle", prefs.category == "lifestyle");
        }
    }

    // Update the source logo and label based on current news source
    private void update_source_info() {
        string source_name = "";
        string? logo_file = null;
        
        switch (prefs.news_source) {
            case NewsSource.GUARDIAN:
                source_name = "The Guardian";
                logo_file = "guardian-logo.png";
                break;
            case NewsSource.BBC:
                source_name = "BBC News";
                logo_file = "bbc-logo.png";
                break;
            case NewsSource.REDDIT:
                source_name = "Reddit";
                logo_file = "reddit-logo.png";
                break;
            case NewsSource.NEW_YORK_TIMES:
                source_name = "New York Times";
                logo_file = "nytimes-logo.png";
                break;
            case NewsSource.BLOOMBERG:
                source_name = "Bloomberg";
                logo_file = "bloomberg-logo.png";
                break;
            case NewsSource.REUTERS:
                source_name = "Reuters";
                logo_file = "reuters-logo.png";
                break;
            case NewsSource.NPR:
                source_name = "NPR";
                logo_file = "npr-logo.png";
                break;
            case NewsSource.FOX:
                source_name = "Fox News";
                logo_file = "foxnews-logo.png";
                break;
            case NewsSource.WALL_STREET_JOURNAL:
                source_name = "Wall Street Journal";
                logo_file = "wsj-logo.png";
                break;
            default:
                source_name = "News";
                logo_file = null;
                break;
        }
        
        source_label.set_text(source_name);
        
        // Try to load the actual logo file, fallback to symbolic icon
        if (logo_file != null) {
            string? logo_path = find_data_file(GLib.Path.build_filename("icons", logo_file));
            if (logo_path != null) {
                try {
                    // Load and scale the pixbuf to ensure consistent size
                    var pixbuf = new Gdk.Pixbuf.from_file(logo_path);
                    if (pixbuf != null) {
                        // Scale to consistent size (32px) while preserving aspect ratio
                        int orig_width = pixbuf.get_width();
                        int orig_height = pixbuf.get_height();
                        
                        // Calculate scale factor to ensure consistent visual size
                        // For logos with extreme aspect ratios, we'll be more generous with size
                        double aspect_ratio = (double)orig_width / orig_height;
                        double scale_factor;
                        
                        if (aspect_ratio > 2.0 || aspect_ratio < 0.5) {
                            // Very wide or very tall logos: use 40px constraint for more presence
                            scale_factor = double.min(40.0 / orig_width, 40.0 / orig_height);
                        } else if (aspect_ratio > 1.5 || aspect_ratio < 0.67) {
                            // Moderately rectangular logos: use 36px constraint
                            scale_factor = double.min(36.0 / orig_width, 36.0 / orig_height);
                        } else {
                            // Square or nearly square logos: use standard 32px constraint
                            scale_factor = double.min(32.0 / orig_width, 32.0 / orig_height);
                        }
                        
                        int new_width = (int)(orig_width * scale_factor);
                        int new_height = (int)(orig_height * scale_factor);
                        
                        var scaled_pixbuf = pixbuf.scale_simple(new_width, new_height, Gdk.InterpType.BILINEAR);
                        var texture = Gdk.Texture.for_pixbuf(scaled_pixbuf);
                        source_logo.set_from_paintable(texture);
                        return;
                    }
                } catch (GLib.Error e) {
                    warning("Failed to load logo %s: %s", logo_path, e.message);
                }
            }
        }
        
        // Fallback to symbolic icon (this will respect set_pixel_size)
        source_logo.set_from_icon_name("application-rss+xml-symbolic");
    }

    // Determine if the system is currently using dark mode
    private bool is_dark_mode() {
        var sm = Adw.StyleManager.get_default();
        return sm != null ? sm.dark : false;
    }

    // Ensure a white-variant SVG exists for the given custom icon and return its path, else null
    private string? ensure_white_icon_for(string original_path) {
        try {
            // Write white variants to user data dir to avoid modifying install tree
            var user_data = GLib.Environment.get_user_data_dir();
            if (user_data == null || user_data.length == 0) return null;
            var out_dir = GLib.Path.build_filename(user_data, "paperboy", "icons");
            GLib.DirUtils.create_with_parents(out_dir, 0755);

            var basename = GLib.Path.get_basename(original_path);
            // Build output name: append -white before .svg if present
            string out_name;
            if (basename.has_suffix(".svg")) {
                out_name = basename.substring(0, basename.length - 4) + "-white.svg";
            } else {
                out_name = basename + "-white.svg";
            }
            var out_path = GLib.Path.build_filename(out_dir, out_name);

            // If already exists, return it
            if (GLib.FileUtils.test(out_path, GLib.FileTest.EXISTS)) {
                return out_path;
            }

            // Read original SVG
            string svg;
            GLib.FileUtils.get_contents(original_path, out svg);

            // Best-effort recolor to white. We'll perform broader replacements so
            // icons using various black/near-black values or inline styles are
            // converted to white for dark mode.
            string white = svg;

            // 1) Replace explicit fill/stroke attributes unless they are 'none' or a URL reference
            int pos = 0;
            while ((pos = white.index_of("fill=\"", pos)) >= 0) {
                int start = pos + 6; // after 'fill="'
                int end = white.index_of("\"", start);
                if (end < 0) break;
                string val = white.substring(start, end - start);
                string val_l = val.down().strip();
                if (val_l != "none" && !val_l.has_prefix("url(")) {
                    white = white.substring(0, start) + "#ffffff" + white.substring(end);
                    pos = start + 7; // move past inserted value
                } else {
                    pos = end + 1;
                }
            }
            pos = 0;
            while ((pos = white.index_of("stroke=\"", pos)) >= 0) {
                int start = pos + 8; // after 'stroke="'
                int end = white.index_of("\"", start);
                if (end < 0) break;
                string val = white.substring(start, end - start);
                string val_l = val.down().strip();
                if (val_l != "none" && !val_l.has_prefix("url(")) {
                    white = white.substring(0, start) + "#ffffff" + white.substring(end);
                    pos = start + 7;
                } else {
                    pos = end + 1;
                }
            }

            // 2) Replace occurrences inside style="..." attributes for fill and stroke
            pos = 0;
            while ((pos = white.index_of("style=\"", pos)) >= 0) {
                int start = pos + 7;
                int end = white.index_of("\"", start);
                if (end < 0) break;
                string style = white.substring(start, end - start);
                string new_style = style;
                // Replace fill:...; patterns
                int s_pos = 0;
                while ((s_pos = new_style.index_of("fill:", s_pos)) >= 0) {
                    int vstart = s_pos + 5;
                    int vend = new_style.index_of(";", vstart);
                    if (vend < 0) vend = new_style.length;
                    string v = new_style.substring(vstart, vend - vstart).strip();
                    if (v.down() != "none" && !v.has_prefix("url(")) {
                        new_style = new_style.substring(0, vstart) + "#ffffff" + new_style.substring(vend);
                        s_pos = vstart + 7;
                    } else {
                        s_pos = vend + 1;
                    }
                }
                // Replace stroke:...; patterns
                s_pos = 0;
                while ((s_pos = new_style.index_of("stroke:", s_pos)) >= 0) {
                    int vstart = s_pos + 7;
                    int vend = new_style.index_of(";", vstart);
                    if (vend < 0) vend = new_style.length;
                    string v = new_style.substring(vstart, vend - vstart).strip();
                    if (v.down() != "none" && !v.has_prefix("url(")) {
                        new_style = new_style.substring(0, vstart) + "#ffffff" + new_style.substring(vend);
                        s_pos = vstart + 7;
                    } else {
                        s_pos = vend + 1;
                    }
                }
                // Replace the full style attribute
                white = white.substring(0, start) + new_style + white.substring(end);
                pos = start + new_style.length + 1;
            }

            // 3) If the icon uses currentColor, set the root color to white
            if (white.index_of("currentColor") >= 0) {
                int idx = white.index_of("<svg");
                if (idx >= 0) {
                    int end = white.index_of(">", idx);
                    if (end > idx) {
                        var head = white.substring(0, end);
                        var tail = white.substring(end);
                        if (head.index_of(" color=") < 0) {
                            head += " color=\"#ffffff\"";
                            white = head + tail;
                        }
                    }
                }
            }

            GLib.FileUtils.set_contents(out_path, white);
            return out_path;
        } catch (GLib.Error e) {
            // On failure, fall back to original
            return null;
        }
    }

    public NewsWindow(Adw.Application app) {
        GLib.Object(application: app);
        title = "Paperboy";
        // Set the window icon
        set_icon_name("paperboy");
        // Reasonable default window size that fits well on most screens
        set_default_size(1425, 925);
        // Initialize RNG for per-card randomization
        rng = new GLib.Rand();
        // Initialize category distribution tracking
        category_column_counts = new Gee.HashMap<string, int>();
        recent_categories = new Gee.ArrayList<string>();
        next_column_index = 0;
        article_buffer = new Gee.ArrayList<ArticleItem>();
    // no download queue to initialize
        category_last_column = new Gee.HashMap<string, int>();
        recent_category_queue = new Gee.ArrayList<string>();
        // Initialize preferences early (needed for building sidebar selection state)
        prefs = NewsPreferences.get_instance();
    // Initialize hero request tracking map
    hero_requests = new Gee.HashMap<Gtk.Picture, HeroRequest>();
    url_to_picture = new Gee.HashMap<string, Gtk.Picture>();
        
    // Cache user/system data dirs early to avoid repeated environment calls
    user_data_dir_cached = GLib.Environment.get_user_data_dir();
    system_data_dirs_cached = GLib.Environment.get_system_data_dirs();

    // Load CSS
        var css_provider = new Gtk.CssProvider();
        try {
            string? css_path = find_data_file("style.css");
            if (css_path != null) {
                css_provider.load_from_path(css_path);
            }
            Gtk.StyleContext.add_provider_for_display(
                Gdk.Display.get_default(),
                css_provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            );
        } catch (GLib.Error e) {
            warning("Failed to load CSS: %s", e.message);
        }

        // Top-level layout: Adw.ToolbarView with an Adw.HeaderBar
        var toolbar_view = new Adw.ToolbarView();
        var header = new Adw.HeaderBar();
        
        // App icon in header
                    var app_icon = new Gtk.Image.from_icon_name("paperboy");
        app_icon.set_pixel_size(SIDEBAR_ICON_SIZE);
        header.pack_start(app_icon);
        
        // App title in main header
        var title_label = new Gtk.Label("Paperboy");
        title_label.add_css_class("title");
        header.pack_start(title_label);

        // Create a spacer to push the sidebar toggle to the right position
        sidebar_spacer = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        sidebar_spacer.set_size_request(100, -1); // Adjust this value to position toggle correctly
        header.pack_start(sidebar_spacer);

        // Sidebar toggle button 
        sidebar_toggle = new Gtk.ToggleButton();
        var sidebar_icon = new Gtk.Image.from_icon_name("view-sidebar-symbolic");
        sidebar_icon.set_pixel_size(16);
        sidebar_toggle.set_child(sidebar_icon);
        sidebar_toggle.set_active(true);
        sidebar_toggle.set_tooltip_text("Hide sidebar");
        sidebar_toggle.add_css_class("sidebar-toggle");
        header.pack_start(sidebar_toggle);

        // Back button for preview navigation
        back_btn = new Gtk.Button.from_icon_name("go-previous-symbolic");
        back_btn.set_visible(false);
        back_btn.set_tooltip_text("Back");
        back_btn.clicked.connect(() => { if (nav_view != null) { nav_view.pop(); back_btn.set_visible(false); } });
        header.pack_start(back_btn);

        // Search bar in the center (offset 50px to the right)
        var search_container = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        var search_spacer = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        search_spacer.set_size_request(50, -1); // 50px offset
        search_container.append(search_spacer);
        
        var search_entry = new Gtk.SearchEntry();
        search_entry.set_placeholder_text("Search News for Keywords...");
        search_entry.set_max_width_chars(60);
        search_container.append(search_entry);
        
        header.set_title_widget(search_container);
        
        // Connect search entry to trigger search
        search_entry.search_changed.connect(() => {
            current_search_query = search_entry.get_text().strip();
            fetch_news();
        });

        var refresh_btn = new Gtk.Button.from_icon_name("view-refresh-symbolic");
        refresh_btn.set_tooltip_text("Refresh news");
        refresh_btn.clicked.connect (() => {
            refresh_btn.set_sensitive(false);
            fetch_news();
            refresh_btn.set_sensitive(true);
        });
        header.pack_end(refresh_btn);
        
        // Add hamburger menu
        var menu = new Menu();
        menu.append("Change News Source", "app.change-source");
        menu.append("About Paperboy", "app.about");
        
        var menu_button = new Gtk.MenuButton();
        menu_button.set_icon_name("open-menu-symbolic");
        menu_button.set_menu_model(menu);
        menu_button.set_tooltip_text("Main Menu");
        header.pack_end(menu_button);
        
        toolbar_view.add_top_bar(header);
    sidebar_list = new Gtk.ListBox();
    sidebar_list.add_css_class("navigation-sidebar");
    sidebar_list.set_selection_mode(SelectionMode.SINGLE);
    sidebar_list.set_activate_on_single_click(true);

        // Populate sidebar using helper methods
        sidebar_add_row("All News", "all", prefs.category == "all");
        sidebar_add_header("Categories");
        // Default site categories (will be rebuilt for sources like Bloomberg)
        sidebar_add_row("World News", "general", prefs.category == "general");
        sidebar_add_row("US News", "us", prefs.category == "us");
        sidebar_add_row("Technology", "technology", prefs.category == "technology");
        sidebar_add_row("Science", "science", prefs.category == "science");
        sidebar_add_row("Sports", "sports", prefs.category == "sports");
        sidebar_add_row("Health", "health", prefs.category == "health");
        sidebar_add_row("Entertainment", "entertainment", prefs.category == "entertainment");
        sidebar_add_row("Politics", "politics", prefs.category == "politics");
        sidebar_add_row("Lifestyle", "lifestyle", prefs.category == "lifestyle");

        sidebar_scrolled = new Gtk.ScrolledWindow();
        sidebar_scrolled.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        sidebar_scrolled.set_child(sidebar_list);

        var scrolled = new Gtk.ScrolledWindow();
        scrolled.set_vexpand(true);
        scrolled.set_hexpand(true);

        // Create a size-constraining container that responds to window size
        content_area = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        content_area.set_halign(Gtk.Align.FILL);
        content_area.set_hexpand(true);

        // Create a container for category label and grid
        content_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        content_box.set_hexpand(true);
        content_box.set_halign(Gtk.Align.FILL);
        
        // Create a container for category header (title + date)
        var header_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);
        header_box.set_margin_start(12);
        header_box.set_margin_end(12);
        header_box.set_margin_top(12);
        header_box.set_margin_bottom(6);
        
        // Create horizontal box for category label and source info
        var title_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
        
        // Add category label (bigger size) - left aligned
        category_label = new Gtk.Label("World News");
        category_label.set_xalign(0);
        category_label.set_hexpand(true); // Take available space
        category_label.add_css_class("heading");
        category_label.add_css_class("title-1");
        // Make it even bigger by adding custom styling
        var category_attrs = new Pango.AttrList();
        category_attrs.insert(Pango.attr_scale_new(1.3)); // 30% larger
        category_attrs.insert(Pango.attr_weight_new(Pango.Weight.BOLD));
        category_label.set_attributes(category_attrs);
        title_row.append(category_label);
        
        // Create source info box (logo + text) - right aligned
        var source_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        source_box.set_valign(Gtk.Align.CENTER);
        
        // Add source logo placeholder
        source_logo = new Gtk.Image();
        source_logo.set_pixel_size(32); // Increased from 24 to 32
        source_logo.set_valign(Gtk.Align.CENTER);
        source_box.append(source_logo);
        
        // Add source label
        source_label = new Gtk.Label("The Guardian");
        source_label.set_xalign(1); // Right align text
        source_label.add_css_class("dim-label");
        source_label.add_css_class("title-4"); // Changed from "caption" to "title-4" for bigger text
        // Make it bigger with custom styling
        var source_attrs = new Pango.AttrList();
        source_attrs.insert(Pango.attr_scale_new(1.2)); // 20% larger
        source_attrs.insert(Pango.attr_weight_new(Pango.Weight.MEDIUM)); // Medium weight
        source_label.set_attributes(source_attrs);
        source_box.append(source_label);
        
        title_row.append(source_box);
        header_box.append(title_row);
        
        // Add current date label (smaller text)
        var date = new DateTime.now_local();
        var date_str = date.format("%A, %B %d, %Y");
        var date_label = new Gtk.Label(date_str);
        date_label.set_xalign(0);
        date_label.add_css_class("dim-label");
        date_label.add_css_class("body");
        header_box.append(date_label);
        
        content_box.append(header_box);

        // Create a main content container that holds both hero and columns
        main_content_container = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
        main_content_container.set_halign(Gtk.Align.FILL);
        main_content_container.set_hexpand(true);
        main_content_container.set_margin_start(H_MARGIN);
        main_content_container.set_margin_end(H_MARGIN);
        main_content_container.set_margin_top(6);
        main_content_container.set_margin_bottom(12);
        
        // Hero container - fill the main container width
        hero_container = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        hero_container.set_halign(Gtk.Align.FILL);
        hero_container.set_hexpand(true);
        
        featured_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        featured_box.set_halign(Gtk.Align.FILL);
        featured_box.set_hexpand(true);
        
        hero_container.append(featured_box);
        main_content_container.append(hero_container);

        // Masonry columns container - also within main container
        columns_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, COL_SPACING);
        columns_row.set_halign(Gtk.Align.FILL);
        columns_row.set_valign(Gtk.Align.START);
        columns_row.set_hexpand(true);
        columns_row.set_vexpand(true);
        columns_row.set_homogeneous(true); // equal column widths
    rebuild_columns(3);
    // Clear any mappings from previous view; widgets were just removed
    // and mappings like `url_to_picture` / `hero_requests` would point
    // to widgets that are no longer in the UI. Keep maps in sync to
    // avoid treating removed pictures as "existing" and updating
    // invisible widgets (which leaves the view blank on revisit).
    url_to_picture.clear();
    hero_requests.clear();
        main_content_container.append(columns_row);
        
        // Create an overlay container for main content and loading spinner
        var main_overlay = new Gtk.Overlay();
        main_overlay.set_child(main_content_container);
        
        // Loading spinner container (initially hidden) - centered over main content
        loading_container = new Gtk.Box(Gtk.Orientation.VERTICAL, 16);
        loading_container.set_halign(Gtk.Align.CENTER);
        loading_container.set_valign(Gtk.Align.CENTER);
        loading_container.set_hexpand(false);
        loading_container.set_vexpand(false);
        loading_container.set_visible(false);
        
        loading_spinner = new Gtk.Spinner();
        loading_spinner.set_size_request(48, 48);
        loading_container.append(loading_spinner);
        
        var loading_label = new Gtk.Label("Loading news...");
        loading_label.add_css_class("dim-label");
        loading_label.add_css_class("title-4");
        loading_container.append(loading_label);
        
        // Add loading spinner as overlay on top of main content area
        main_overlay.add_overlay(loading_container);
        content_box.append(main_overlay);
        
        // Add content_box to content_area and set up proper containment
        content_area.append(content_box);
        scrolled.set_child(content_area);

        // Split view: sidebar + content with collapsible sidebar
        split_view = new Adw.OverlaySplitView();
        split_view.set_sidebar(sidebar_scrolled);
        // Wrap content in a NavigationView so we can slide in a preview page
        nav_view = new Adw.NavigationView();
        var main_page = new Adw.NavigationPage(scrolled, "Main");
        nav_view.push(main_page);
        split_view.set_content(nav_view);
        split_view.set_show_sidebar(true);

        // Connect toggle after split view exists
        sidebar_toggle.toggled.connect(() => {
            bool show = sidebar_toggle.get_active();
            split_view.set_show_sidebar(show);
            sidebar_toggle.set_tooltip_text(show ? "Hide sidebar" : "Show sidebar");
            
            // Adjust spacer width based on sidebar visibility
            if (show) {
                sidebar_spacer.set_size_request(100, -1); // Position at right edge of sidebar
            } else {
                sidebar_spacer.set_size_request(20, -1);  // Move to left edge when hidden
            }
            
            // Add/remove CSS class to style header over sidebar
            if (show) {
                header.add_css_class("sidebar-header");
            } else {
                header.remove_css_class("sidebar-header");
            }
            
            // Adjust main content container to expand when sidebar is hidden
            update_main_content_size(show);
        });
        
        // Initially set the sidebar header style since sidebar starts visible
        header.add_css_class("sidebar-header");
        
        // Initialize main content container size for initial sidebar state
        update_main_content_size(true);

        toolbar_view.set_content(split_view);
        set_content(toolbar_view);

        session = new Soup.Session();
        // Optimize session for better performance
        session.max_conns = 10; // Allow more concurrent connections
        session.max_conns_per_host = 4; // Limit per host to prevent overwhelming servers
        session.timeout = 15; // Default timeout

        // Initialize article window
        article_window = new ArticleWindow(nav_view, back_btn, session, this);

        // Add keyboard event controller for closing article preview with Escape
        var key_controller = new Gtk.EventControllerKey();
        key_controller.key_pressed.connect((keyval, keycode, state) => {
            if (keyval == Gdk.Key.Escape && back_btn.get_visible()) {
                // Close article preview if it's open
                nav_view.pop();
                back_btn.set_visible(false);
                return true;
            }
            return false;
        });
        nav_view.add_controller(key_controller);

        // Add click event controller to main content area to close preview when clicking outside
        var main_click_controller = new Gtk.GestureClick();
        main_click_controller.pressed.connect((n_press, x, y) => {
            // Only close if article preview is open (back button is visible)
            if (back_btn.get_visible()) {
                nav_view.pop();
                back_btn.set_visible(false);
            }
        });
        split_view.add_controller(main_click_controller);

        // Listen for theme changes to live-switch custom icons
        var sm = Adw.StyleManager.get_default();
        if (sm != null) {
            sm.notify["dark"].connect(() => { update_sidebar_icons_for_theme(); });
        }

        // initial state and fetch
        update_sidebar_for_source();
        fetch_news();
    }

    // Public helper so external callers (e.g., dialogs) can close an open article preview
    public void close_article_preview() {
        if (back_btn != null && back_btn.get_visible()) {
            if (nav_view != null) nav_view.pop();
            back_btn.set_visible(false);
        }
    }

    private bool source_has_categories(NewsSource s) {
        switch (s) {
            // So far, all our sources support categories
            // but I'll leave this here in case I add one that doesn't
            /*case NewsSource.BLOOMBERG:
                return true;
            case NewsSource.REUTERS:
            case NewsSource.NPR:
            case NewsSource.FOX:
                return true;*/
            default:
                return true;
        }
    }

    private void update_sidebar_for_source() {
        update_source_info(); // Update the source logo and label
        bool has = source_has_categories(prefs.news_source);
        if (!has) {
            // Hide and disable sidebar controls
            split_view.set_show_sidebar(false);
            sidebar_toggle.set_active(false);
            sidebar_toggle.set_sensitive(false);
            sidebar_toggle.set_tooltip_text("Sidebar not available for this source");
            // Move button to left edge when sidebar is hidden
            sidebar_spacer.set_size_request(20, -1);
        } else {
            // Show and enable sidebar controls
            sidebar_toggle.set_sensitive(true);
            sidebar_toggle.set_active(true);
            split_view.set_show_sidebar(true);
            sidebar_toggle.set_tooltip_text("Hide sidebar");
            // Move button to right edge when sidebar is shown
            sidebar_spacer.set_size_request(100, -1);
        }
        // Rebuild rows to reflect source-specific categories (e.g., Bloomberg)
        rebuild_sidebar_rows_for_source();
    }

    // Replace the icon in each sidebar row holder according to the active theme
    private void update_sidebar_icons_for_theme() {
        foreach (var kv in sidebar_icon_holders.entries) {
            string cat = kv.key;
            Gtk.Box holder = kv.value;
            // Remove current child(ren)
            Gtk.Widget? child = holder.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                holder.remove(child);
                child = next;
            }
            var w = create_category_icon(cat);
            if (w != null) holder.append(w);
        }
    }

    private string category_display_name_for(string cat) {
        switch (cat) {
            case "all": return "All News";
            case "general": return "World News";
            case "us": return "US News";
            case "technology": return "Technology";
            case "markets": return "Markets";
            case "industries": return "Industries";
            case "economics": return "Economics";
            case "wealth": return "Wealth";
            case "green": return "Green";
            case "science": return "Science";
            case "sports": return "Sports";
            case "health": return "Health";
            case "entertainment": return "Entertainment";
            case "politics": return "Politics";
            case "lifestyle": return "Lifestyle";
        }
        return "News";
    }

    private Gtk.Widget build_category_chip(string category_id) {
        var chip = new Gtk.Label(category_display_name_for(category_id));
        chip.add_css_class("category-chip");
        chip.set_halign(Gtk.Align.START);
        chip.set_valign(Gtk.Align.START);
        return chip;
    }

    private void add_item(string title, string url, string? thumbnail_url, string category_id) {
        // Debug helper: print when enabled via env var
        bool debug_enabled() {
            // Use GLib.Environment-compatible accessor for environment variables
            string? e = Environment.get_variable("PAPERBOY_DEBUG");
            return e != null && e.length > 0;
        }

        if (debug_enabled()) {
            warning("add_item called: current_view=%s article_cat=%s title=%s", prefs.category, category_id, title);
        }
        // Do not hide the initial loading spinner here; we'll reveal content
        // once the hero image is ready or after a short timeout to avoid jarring.
        // If we already have a picture registered for this URL, treat this as an image update
        string normalized = normalize_article_url(url);
        Gtk.Picture? existing = url_to_picture.get(normalized);
            // Fallback: try fuzzy match (strip/trailing differences or query variants)
        if (existing == null) {
            foreach (var kv in url_to_picture.entries) {
                string k = kv.key;
                if (k == null) continue;
                // Match when one URL is a suffix of the other (same article, different params)
                if (k.has_suffix(normalized) || normalized.has_suffix(k)) {
                    existing = kv.value;
                    // fuzzy match found; update will proceed without debug logging
                    break;
                }
            }
        }
        if (existing != null && thumbnail_url != null && thumbnail_url.length > 0) {
                // Determine target size from hero_requests (if this is a hero) or column width
                var info = hero_requests.get(existing);
                int target_w = info != null ? info.last_requested_w : estimate_column_width(columns_count);
                int target_h = info != null ? info.last_requested_h : (int)(target_w * 0.5);
                // Updating existing article image in-place (silent)
                // Update regardless of current prefs since it's an in-place replacement
                if (initial_phase) pending_images++;
                load_image_async(existing, thumbnail_url, target_w, target_h);
                return; // updated image in-place
        }

        // If the user has switched categories since this fetch began, ignore
        // articles that don't belong to the current view, unless we're in
        // "all" view which accepts everything.
        string view_category = prefs.category;
        if (view_category != "all" && view_category != category_id) {
            // Drop stale article for a different category
            if (debug_enabled()) warning("Dropping stale article for category %s (view=%s)", category_id, view_category);
            return;
        }
        
        if (prefs.category == "all") {
            // If the user selected "All News" but the active source is
            // Bloomberg, only accept articles whose category is one of
            // Bloomberg's available categories. This prevents showing
            // unrelated categories that Bloomberg doesn't provide.
            if (prefs.news_source == NewsSource.BLOOMBERG) {
                string[] bloomberg_cats = { "markets", "industries", "economics", "wealth", "green", "politics", "technology" };
                bool allowed = false;
                foreach (string bc in bloomberg_cats) {
                    if (bc == category_id) { allowed = true; break; }
                }
                if (!allowed) {
                    // Drop articles from categories Bloomberg doesn't have
                    if (debug_enabled()) {
                        warning("Dropping article for Bloomber g: view=all source=Bloomberg article_cat=%s title=%s", category_id, title);
                    }
                    return;
                }
            }

            // For "All News", add to buffer for later shuffling
            var item = new ArticleItem(title, url, thumbnail_url, category_id);
            article_buffer.add(item);
            
            // Schedule buffer flush (reset timer each time an article is added)
            if (buffer_flush_timeout_id > 0) {
                Source.remove(buffer_flush_timeout_id);
            }
            buffer_flush_timeout_id = Timeout.add(500, () => {
                flush_article_buffer();
                buffer_flush_timeout_id = 0;
                return false;
            });
        } else {
            // For specific categories, add directly
            add_item_immediate_to_column(title, url, thumbnail_url, category_id);
        }
    }
    
    // Called when all articles have been fetched for "All News" mode
    public void flush_article_buffer() {
        if (prefs.category != "all" || article_buffer.size == 0) {
            return;
        }
        
        // During initial_phase we keep the spinner visible until initial items
        // and their images are ready (or until the safety timeout). If we're
        // not in initial_phase, normal behavior applies and we can hide it.
        if (!initial_phase) {
            hide_loading_spinner();
        }
        
        // Convert to array for easy shuffling
        var articles = new ArticleItem[article_buffer.size];
        for (int i = 0; i < article_buffer.size; i++) {
            articles[i] = article_buffer[i];
        }
        
        // Fisher-Yates shuffle for truly random distribution
        for (int i = articles.length - 1; i > 0; i--) {
            int j = rng.int_range(0, i + 1);
            var temp = articles[i];
            articles[i] = articles[j];
            articles[j] = temp;
        }
        
        // Now add them in shuffled order with simple round-robin distribution
        // But respect the article limit for Load More functionality
        int articles_added = 0;
        for (int i = 0; i < articles.length; i++) {
            // Check if we've reached the limit before adding more articles
            if (articles_shown >= INITIAL_ARTICLE_LIMIT && load_more_button == null) {
                // Store remaining articles for Load More functionality
                int remaining_count = articles.length - i;
                remaining_articles = new ArticleItem[remaining_count];
                for (int j = 0; j < remaining_count; j++) {
                    remaining_articles[j] = articles[i + j];
                }
                remaining_articles_index = 0;
                show_load_more_button();
                break; // Stop adding articles until user clicks "Load More"
            }
            
            var article = articles[i];
            add_item_shuffled(article.title, article.url, article.thumbnail_url, article.category_id);
            articles_added++;
        }
        
        article_buffer.clear();

        // Mark that initial items have been added to the UI. If there are no
        // pending image loads, reveal immediately. Otherwise, wait until
        // pending_images reaches zero (handled by image_ready()).
        initial_items_populated = true;
        if (pending_images == 0) {
            reveal_initial_content();
        }
    }
    
    private void add_item_shuffled(string title, string url, string? thumbnail_url, string category_id) {
        // Simple round-robin distribution for shuffled articles  
        int target_col = next_column_index;
        next_column_index = (next_column_index + 1) % columns.length;
        
        // Temporarily override category to force immediate placement
        string saved_category = prefs.category;
        prefs.category = category_id; // Set to non-"all" to skip buffering logic
        add_item_immediate_to_column(title, url, thumbnail_url, category_id, target_col, saved_category);
        prefs.category = saved_category; // Restore
    }
    
    private void add_item_immediate_to_column(string title, string url, string? thumbnail_url, string category_id, int forced_column = -1, string? original_category = null) {
        // Check article limit for "All News" mode FIRST
        // Use original_category if provided (for when category is temporarily overridden)
        string check_category = original_category ?? prefs.category;
        if (check_category == "all" && articles_shown >= INITIAL_ARTICLE_LIMIT && load_more_button == null) {
            show_load_more_button();
            return; // Stop adding articles until user clicks "Load More"
        }
        
        // Smart column selection for "All News" to prevent category clustering
        int target_col = -1;
        if (prefs.category == "all" && forced_column == -1) {
            // Light anti-clustering: only prevent very long runs (4+ consecutive)
            int consecutive_count = 0;
            
            // Count consecutive articles of the same category from the end
            for (int i = recent_category_queue.size - 1; i >= 0; i--) {
                if (recent_category_queue.get(i) == category_id) {
                    consecutive_count++;
                } else {
                    break; // Stop at first different category
                }
            }
            
            // Only skip if we have 4+ consecutive of the same category
            if (consecutive_count >= 4) {
                return; // Skip to prevent very long runs
            }
            
            // Track this category and use round-robin
            recent_category_queue.add(category_id);
            if (recent_category_queue.size > MAX_RECENT_CATEGORIES) {
                recent_category_queue.remove_at(0);
            }
            
            target_col = next_column_index;
            next_column_index = (next_column_index + 1) % columns.length;
        } else if (forced_column != -1) {
            target_col = forced_column;
        } else {
            // Regular round-robin for specific categories
            target_col = next_column_index;
            next_column_index = (next_column_index + 1) % columns.length;
        }
        
        // For "All News", randomly select hero from first few items (not always the first)
        // For specific categories, keep the first item as hero for consistency
        bool should_be_hero = false;
        if (!featured_used) {
            if (prefs.category == "all") {
                // 60% chance for first 3 items to become hero, then 0% chance
                should_be_hero = rng.int_range(0, 10) < 6;
            } else {
                // Always use first item as hero for specific categories
                should_be_hero = true;
            }

            // If the source is Reddit, avoid promoting live threads as the top story.
            // Reddit live threads typically include `/live/` in the path or use reddit.com/live.
            if (prefs.news_source == NewsSource.REDDIT && url != null) {
                string u_low = url.down();
                if (u_low.index_of("/live/") >= 0 || u_low.has_suffix("/live") || u_low.index_of("reddit.com/live") >= 0) {
                    // Force not to be hero
                    should_be_hero = false;
                }
            }
        }
        
        if (should_be_hero) {
            var hero = new Gtk.Box(Orientation.VERTICAL, 0);
            
            // Let the container control the width, only constrain height
            int max_hero_height = 350; // Maximum total height
            
            // Let hero fill available width from container, but constrain height
            hero.set_size_request(-1, max_hero_height); // -1 means use natural width
            hero.set_hexpand(true);  // Expand to fill container width
            hero.set_vexpand(false);
            hero.set_halign(Gtk.Align.FILL); // Fill the container width
            hero.set_valign(Gtk.Align.START);
            hero.set_margin_start(0);
            hero.set_margin_end(0);

            var hero_image = new Gtk.Picture();
            hero_image.set_halign(Gtk.Align.FILL);
            hero_image.set_hexpand(true); // Expand to fill hero card width
            hero_image.set_size_request(-1, 250); // Let width be natural, set reasonable height
            hero_image.set_content_fit(Gtk.ContentFit.COVER);
            hero_image.set_can_shrink(true);

            // Overlay with category chip for hero image
            var hero_overlay = new Gtk.Overlay();
            hero_overlay.set_child(hero_image);
            var hero_chip = build_category_chip(category_id);
            hero_overlay.add_overlay(hero_chip);

            // Use reasonable defaults for placeholder and loading since hero will be responsive
            // Estimate hero width from current content width so we request an appropriately-sized image
            int default_hero_w = estimate_content_width();
            int default_hero_h = 250; // Match the image height we set above
            
            set_placeholder_image(hero_image, default_hero_w, default_hero_h);
            if (thumbnail_url != null && thumbnail_url.length > 0 &&
                (thumbnail_url.has_prefix("http://") || thumbnail_url.has_prefix("https://"))) {
                // Use different resolution multiplier based on source - Reddit images are typically larger
                int multiplier = (prefs.news_source == NewsSource.REDDIT) ? 2 : 4; // request larger for hero
                if (initial_phase) pending_images++;
                load_image_async(hero_image, thumbnail_url, default_hero_w * multiplier, default_hero_h * multiplier);
                // Remember this request so we can re-request larger images if layout changes
                hero_requests.set(hero_image, new HeroRequest(thumbnail_url, default_hero_w * multiplier, default_hero_h * multiplier, multiplier));
                // Register the picture for this article URL so future updates (OG image fetches) can replace it in-place
                url_to_picture.set(normalize_article_url(url), hero_image);
                // Schedule a short delayed re-check in case layout finalizes after creation
                Timeout.add(300, () => { 
                    // Attempt one re-check shortly after creation
                    var info = hero_requests.get(hero_image);
                    if (info != null) maybe_refetch_hero_for(hero_image, info);
                    return false; 
                });
            }
            hero.append(hero_overlay);

            var hero_title_box = new Gtk.Box(Orientation.VERTICAL, 8);
            hero_title_box.set_margin_start(16);
            hero_title_box.set_margin_end(16);
            hero_title_box.set_margin_top(16);
            hero_title_box.set_margin_bottom(16);
            hero_title_box.set_vexpand(true);

            var hero_label = new Gtk.Label(title);
            hero_label.set_ellipsize(Pango.EllipsizeMode.END);
            hero_label.set_xalign(0);
            hero_label.set_wrap(true);
            hero_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
            hero_label.set_lines(8);
            hero_label.set_max_width_chars(88);
            hero_title_box.append(hero_label);

            hero.append(hero_title_box);

            var hero_click = new Gtk.GestureClick();
            hero_click.released.connect(() => {
                article_window.show_article_preview(title, url, thumbnail_url);
            });
            hero.add_controller(hero_click);

            var hero_motion = new Gtk.EventControllerMotion();
            hero_motion.enter.connect(() => { hero.add_css_class("card-hover"); });
            hero_motion.leave.connect(() => { hero.remove_css_class("card-hover"); });
            hero.add_controller(hero_motion);

            // Build the featured carousel container and add the first slide.
            // Use an explicit title above the carousel for accessibility.
            var top_stories_title = new Gtk.Label("Top Stories");
            top_stories_title.set_xalign(0);
            top_stories_title.add_css_class("top-stories-title");
            top_stories_title.set_margin_bottom(6);
            featured_box.append(top_stories_title);

            // Initialize carousel state
            if (featured_carousel_items == null) featured_carousel_items = new Gee.ArrayList<ArticleItem>();
            featured_carousel_items.add(new ArticleItem(title, url, thumbnail_url, category_id));
            featured_carousel_category = category_id;

            // Create a stack to hold up to 5 slides
            featured_carousel_stack = new Gtk.Stack();
            featured_carousel_stack.set_transition_type(Gtk.StackTransitionType.SLIDE_LEFT_RIGHT);
            featured_carousel_stack.set_halign(Gtk.Align.FILL);
            featured_carousel_stack.set_hexpand(true);

            // Add the first slide (we'll add more slides as subsequent articles arrive)
            featured_carousel_stack.add_named(hero, "0");

            // Wrap the stack and the dots in a single container so the dots
            // appear as part of the hero card itself.
            var carousel_container = new Gtk.Box(Orientation.VERTICAL, 0);
            carousel_container.add_css_class("card");
            carousel_container.add_css_class("card-featured");
            carousel_container.set_halign(Gtk.Align.FILL);
            carousel_container.set_hexpand(true);

            // Add stack into the carousel container
            // Wrap the stack in an overlay so we can place nav buttons over the image
            var carousel_overlay = new Gtk.Overlay();
            carousel_overlay.set_child(featured_carousel_stack);

            // Left navigation button
            var left_btn = new Gtk.Button.from_icon_name("go-previous-symbolic");
            left_btn.add_css_class("carousel-nav");
            left_btn.add_css_class("carousel-nav-left");
            left_btn.set_halign(Gtk.Align.START);
            left_btn.set_valign(Gtk.Align.CENTER);
            left_btn.set_margin_start(8);
            left_btn.set_margin_end(8);
            left_btn.set_margin_top(0);
            left_btn.set_margin_bottom(0);
            carousel_overlay.add_overlay(left_btn);
            left_btn.clicked.connect(() => { carousel_prev(); });

            // Right navigation button
            var right_btn = new Gtk.Button.from_icon_name("go-next-symbolic");
            right_btn.add_css_class("carousel-nav");
            right_btn.add_css_class("carousel-nav-right");
            right_btn.set_halign(Gtk.Align.END);
            right_btn.set_valign(Gtk.Align.CENTER);
            right_btn.set_margin_start(8);
            right_btn.set_margin_end(8);
            right_btn.set_margin_top(0);
            right_btn.set_margin_bottom(0);
            carousel_overlay.add_overlay(right_btn);
            right_btn.clicked.connect(() => { carousel_next(); });

            carousel_container.append(carousel_overlay);

            // Create a single dots row under the carousel (keeps dots visually under
            // the article title while remaining easy to update). We show up to 5 dots
            // regardless of how many slides are currently available; inactive
            // ones will be dimmed.
            var global_dots = new Gtk.Box(Orientation.HORIZONTAL, 6);
            global_dots.set_halign(Gtk.Align.CENTER);
            global_dots.set_margin_top(6);
            if (featured_carousel_dot_widgets == null) featured_carousel_dot_widgets = new Gee.ArrayList<Gtk.Label>();
            for (int d = 0; d < 5; d++) {
                var dot = new Gtk.Label("•");
                dot.add_css_class("carousel-dot");
                if (d == 0) dot.add_css_class("active");
                dot.set_valign(Gtk.Align.CENTER);
                // Force a larger glyph size using Pango attributes so themes
                // that ignore label font-size in CSS still show bigger dots.
                var dot_attrs = new Pango.AttrList();
                // Scale relative to the default font size (1.35 = 35% larger)
                dot_attrs.insert(Pango.attr_scale_new(1.35));
                dot.set_attributes(dot_attrs);
                global_dots.append(dot);
                featured_carousel_dot_widgets.add(dot);
            }
            featured_carousel_dots_box = global_dots;

            // Add the dots row into the same carousel container so they are visually
            // contained within the hero card.
            carousel_container.append(global_dots);

            // Append the carousel container (stack + dots) to the featured box
            featured_box.append(carousel_container);

            // Start cycling through slides every 5 seconds
            featured_carousel_index = 0;
            if (featured_carousel_timeout_id != 0) {
                Source.remove(featured_carousel_timeout_id);
                featured_carousel_timeout_id = 0;
            }
            featured_carousel_timeout_id = Timeout.add_seconds(5, () => {
                if (featured_carousel_stack == null) return false;
                int total = featured_carousel_items != null ? featured_carousel_items.size : 0;
                if (total <= 1) return true; // keep running until there are more slides
                featured_carousel_index = (featured_carousel_index + 1) % total;
                string name = "%d".printf(featured_carousel_index);
                featured_carousel_stack.set_visible_child_name(name);
                // Update dots in the visible slide
                update_carousel_dots(featured_carousel_index);
                return true; // continue timeout
            });

            featured_used = true;
            // Mark that initial items exist so the spinner can be hidden
            if (initial_phase) mark_initial_items_populated();
            return;
        }

        // If a featured carousel is active and we haven't reached 5 slides yet,
        // collect additional articles that match the featured category and add
        // them as slides to the carousel instead of rendering normal cards.
        if (featured_carousel_stack != null && featured_carousel_items != null &&
            featured_carousel_items.size < 5 && featured_carousel_category != null &&
            featured_carousel_category == category_id) {

            // Build a slide similar to the hero we create above
            var slide = new Gtk.Box(Orientation.VERTICAL, 0);

            int max_hero_height = 350;
            slide.set_size_request(-1, max_hero_height);
            slide.set_hexpand(true);
            slide.set_vexpand(false);
            slide.set_halign(Gtk.Align.FILL);
            slide.set_valign(Gtk.Align.START);
            slide.set_margin_start(0);
            slide.set_margin_end(0);

            var slide_image = new Gtk.Picture();
            slide_image.set_halign(Gtk.Align.FILL);
            slide_image.set_hexpand(true);
            slide_image.set_size_request(-1, 250);
            slide_image.set_content_fit(Gtk.ContentFit.COVER);
            slide_image.set_can_shrink(true);

            var slide_overlay = new Gtk.Overlay();
            slide_overlay.set_child(slide_image);
            var slide_chip = build_category_chip(category_id);
            slide_overlay.add_overlay(slide_chip);

            int default_w = estimate_content_width();
            int default_h = 250;
            set_placeholder_image(slide_image, default_w, default_h);
            if (thumbnail_url != null && thumbnail_url.length > 0 &&
                (thumbnail_url.has_prefix("http://") || thumbnail_url.has_prefix("https://"))) {
                int multiplier = (prefs.news_source == NewsSource.REDDIT) ? 2 : 4;
                if (initial_phase) pending_images++;
                load_image_async(slide_image, thumbnail_url, default_w * multiplier, default_h * multiplier);
                hero_requests.set(slide_image, new HeroRequest(thumbnail_url, default_w * multiplier, default_h * multiplier, multiplier));
                url_to_picture.set(normalize_article_url(url), slide_image);
            }
            slide.append(slide_overlay);

            var slide_title_box = new Gtk.Box(Orientation.VERTICAL, 8);
            slide_title_box.set_margin_start(16);
            slide_title_box.set_margin_end(16);
            slide_title_box.set_margin_top(16);
            slide_title_box.set_margin_bottom(16);
            slide_title_box.set_vexpand(true);

            var slide_label = new Gtk.Label(title);
            slide_label.set_ellipsize(Pango.EllipsizeMode.END);
            slide_label.set_xalign(0);
            slide_label.set_wrap(true);
            slide_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
            slide_label.set_lines(8);
            slide_label.set_max_width_chars(88);
            slide_title_box.append(slide_label);
            slide.append(slide_title_box);

            var slide_click = new Gtk.GestureClick();
            slide_click.released.connect(() => {
                article_window.show_article_preview(title, url, thumbnail_url);
            });
            slide.add_controller(slide_click);

            // Add slide to stack and to our item list
            int new_index = featured_carousel_items.size;
            featured_carousel_stack.add_named(slide, "%d".printf(new_index));
            featured_carousel_items.add(new ArticleItem(title, url, thumbnail_url, category_id));

            // Ensure dots array exists and update their state
            if (featured_carousel_dot_widgets != null) update_carousel_dots(featured_carousel_index);

            return;
        }

        var card = new Gtk.Box(Orientation.VERTICAL, 0);
        card.add_css_class("card");

        // Randomly choose a size variant for this card (small/medium/large)
        int variant = rng.int_range(0, 3);
        // Make cards truly responsive - don't pre-calculate fixed sizes
        int col_w = estimate_column_width(columns_count);
        int img_w = col_w; // for loader/placeholder calculation only
        int img_h = 0;
        
        // Set taller, more readable image heights for better visual appeal
        switch (variant) {
            case 0: // small
                img_h = (int)(col_w * 0.42);
                if (img_h < 80) img_h = 80; // absolute minimum
                card.add_css_class("card-small");
                break;
            case 1: // medium (default)
                img_h = (int)(col_w * 0.5);
                if (img_h < 100) img_h = 100; // absolute minimum
                card.add_css_class("card-medium");
                break;
            case 2: // large
                img_h = (int)(col_w * 0.58);
                if (img_h < 120) img_h = 120; // absolute minimum
                card.add_css_class("card-large");
                break;
        }
        
        // Constrain card to fit within column
        card.set_hexpand(true);
        card.set_halign(Gtk.Align.FILL);
        card.set_size_request(col_w, -1); // Set maximum width to column width
        
        // Create image container
        var image = new Gtk.Picture();
        image.set_halign(Gtk.Align.FILL);
        image.set_hexpand(true);
        // Set minimum height but constrain width to prevent overflow
        image.set_size_request(col_w, img_h);
        image.set_content_fit(Gtk.ContentFit.COVER);
        image.set_can_shrink(true);

        // Overlay with category chip
        var overlay = new Gtk.Overlay();
        overlay.set_child(image);
        var chip = build_category_chip(category_id);
        overlay.add_overlay(chip);

        // Always set placeholder first
        set_placeholder_image(image, img_w, img_h);
        
        if (thumbnail_url != null && thumbnail_url.length > 0 && 
            (thumbnail_url.has_prefix("http://") || thumbnail_url.has_prefix("https://"))) {
            // Use different resolution multiplier based on source - Reddit images are typically larger
            int multiplier = (prefs.news_source == NewsSource.REDDIT) ? 2 : 3;
            if (initial_phase) pending_images++;
            load_image_async(image, thumbnail_url, img_w * multiplier, img_h * multiplier);
            // Register card image for in-place updates when higher-res images arrive later
            url_to_picture.set(normalize_article_url(url), image);
        }
        
        card.append(overlay);
        
        // Title container
        var title_box = new Gtk.Box(Orientation.VERTICAL, 6);
        title_box.set_margin_start(12);
        title_box.set_margin_end(12);
        title_box.set_margin_top(12);
        title_box.set_margin_bottom(12);
        title_box.set_vexpand(true);
        
        var label = new Gtk.Label(title);
        label.set_ellipsize(Pango.EllipsizeMode.END);
        label.set_xalign(0);
        label.set_wrap(true);
        label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        // Set width to match column width for proper text wrapping
        label.set_size_request(col_w - 24, -1); // Account for margins
        // Adjust label constraints based on variant
        switch (variant) {
            case 0: label.set_lines(3); break;
            case 1: label.set_lines(4); break;
            case 2: label.set_lines(6); break;
        }
        title_box.append(label);
        
        card.append(title_box);
        
        // Make the whole card clickable
        var gesture = new Gtk.GestureClick();
        gesture.released.connect(() => { article_window.show_article_preview(title, url, thumbnail_url); });
        card.add_controller(gesture);
        
        // Add hover effect
        var motion = new Gtk.EventControllerMotion();
        motion.enter.connect(() => {
            card.add_css_class("card-hover");
        });
        motion.leave.connect(() => {
            card.remove_css_class("card-hover");
        });
        card.add_controller(motion);

        // Append to the calculated target column
        if (target_col == -1) {
            // Fallback: find shortest column for specific categories
            target_col = 0;
            // Original logic for single category views
            int random_noise = rng.int_range(0, 11);
            int best_score = column_heights[0] + random_noise;
            
            for (int i = 1; i < columns.length; i++) {
                random_noise = rng.int_range(0, 11);
                int score = column_heights[i] + random_noise;
                if (score < best_score) { best_score = score; target_col = i; }
            }
        }
        columns[target_col].append(card);
        
        // Increment article counter for "All News" mode
        // Use original_category if provided (for when category is temporarily overridden)
        string current_category = original_category ?? prefs.category;
        if (current_category == "all") {
            articles_shown++;
        }
        
        // Update approximate column height (include spacing) - estimate based on image height + text
        int estimated_card_h = img_h + 120; // image + typical text height
        column_heights[target_col] += estimated_card_h + 12;

        // Mark that initial items exist so the spinner can be hidden once images are ready
        if (initial_phase) mark_initial_items_populated();
    }
    
    // Internal helper that starts a download thread for the provided image/url.
    // We no longer maintain a FIFO queue; downloads are best-effort and caching
    // reduces the number of network fetches significantly.
    private void start_image_download_thread(Gtk.Picture image, string url, int target_w, int target_h) {
        new Thread<void*>("pb-load-image", () => {
            GLib.AtomicInt.inc(ref active_downloads);
            try {
                var msg = new Soup.Message("GET", url);
                if (prefs.news_source == NewsSource.REDDIT) {
                    msg.request_headers.append("User-Agent", "Mozilla/5.0 (compatible; Paperboy/1.0)");
                    msg.request_headers.append("Accept", "image/jpeg,image/png,image/webp,image/*;q=0.8");
                    msg.request_headers.append("Cache-Control", "max-age=3600");
                } else {
                    msg.request_headers.append("User-Agent", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36");
                    msg.request_headers.append("Accept", "image/webp,image/png,image/jpeg,image/*;q=0.8");
                }
                msg.request_headers.append("Accept-Encoding", "gzip, deflate, br");

                session.send_message(msg);

                if (prefs.news_source == NewsSource.REDDIT && msg.response_body.length > 2 * 1024 * 1024) {
                    Idle.add(() => {
                        set_placeholder_image(image, target_w, target_h);
                        on_image_loaded(image);
                        return false;
                    });
                    return null;
                }

                if (msg.status_code == 200 && msg.response_body.length > 0) {
                    Idle.add(() => {
                        try {
                            var loader = new Gdk.PixbufLoader();
                            uint8[] data = new uint8[msg.response_body.length];
                            Memory.copy(data, msg.response_body.data, (size_t)msg.response_body.length);
                            // No disk cache in this build; just decode and display the image
                            loader.write(data);
                            loader.close();
                            var pixbuf = loader.get_pixbuf();
                            if (pixbuf != null) {
                                int width = pixbuf.get_width();
                                int height = pixbuf.get_height();
                                double scale = double.min((double) target_w / width, (double) target_h / height);
                                if (scale < 1.0) {
                                    int new_width = (int)(width * scale);
                                    int new_height = (int)(height * scale);
                                    if (new_width >= 64 && new_height >= 64) {
                                        pixbuf = pixbuf.scale_simple(new_width, new_height, Gdk.InterpType.HYPER);
                                    }
                                } else if (scale > 1.0) {
                                    double max_upscale = 2.0;
                                    double upscale = double.min(scale, max_upscale);
                                    int new_width = (int)(width * upscale);
                                    int new_height = (int)(height * upscale);
                                    if (upscale > 1.01) {
                                        pixbuf = pixbuf.scale_simple(new_width, new_height, Gdk.InterpType.HYPER);
                                    }
                                }
                                var texture = Gdk.Texture.for_pixbuf(pixbuf);
                                image.set_paintable(texture);
                                on_image_loaded(image);
                            } else {
                                set_placeholder_image(image, target_w, target_h);
                                on_image_loaded(image);
                            }
                        } catch (GLib.Error e) {
                            set_placeholder_image(image, target_w, target_h);
                            on_image_loaded(image);
                        }
                        return false;
                    });
                } else {
                    Idle.add(() => {
                        set_placeholder_image(image, target_w, target_h);
                        on_image_loaded(image);
                        return false;
                    });
                }
            } catch (GLib.Error e) {
                Idle.add(() => {
                    set_placeholder_image(image, target_w, target_h);
                    on_image_loaded(image);
                    return false;
                });
            } finally {
                // Decrement active downloads counter
                GLib.AtomicInt.dec_and_test(ref active_downloads);
            }
            return null;
        });
    }
    
    private void load_image_async(Gtk.Picture image, string url, int target_w, int target_h) {
        // Always download image (no disk cache available)
        start_image_download_thread(image, url, target_w, target_h);
    }
    

    
    private string get_source_name(NewsSource source) {
        switch (source) {
            case NewsSource.GUARDIAN:
                return "The Guardian";
            case NewsSource.WALL_STREET_JOURNAL:
                return "Wall Street Journal";
            case NewsSource.BBC:
                return "BBC News";
            case NewsSource.REDDIT:
                return "Reddit";
            case NewsSource.NEW_YORK_TIMES:
                return "NY Times";
            case NewsSource.BLOOMBERG:
                return "Bloomberg";
            case NewsSource.REUTERS:
                return "Reuters";
            case NewsSource.NPR:
                return "NPR";
            case NewsSource.FOX:
                return "Fox News";
            default:
                return "News";
        }
    }

    private string? get_source_icon_path(NewsSource source) {
        string icon_filename;
        switch (source) {
            case NewsSource.GUARDIAN:
                icon_filename = "guardian-logo.png";
                break;
            case NewsSource.BBC:
                icon_filename = "bbc-logo.png";
                break;
            case NewsSource.REDDIT:
                icon_filename = "reddit-logo.png";
                break;
            case NewsSource.NEW_YORK_TIMES:
                icon_filename = "nytimes-logo.png";
                break;
            case NewsSource.BLOOMBERG:
                icon_filename = "bloomberg-logo.png";
                break;
            case NewsSource.REUTERS:
                icon_filename = "reuters-logo.png";
                break;
            case NewsSource.NPR:
                icon_filename = "npr-logo.png";
                break;
            case NewsSource.FOX:
                icon_filename = "foxnews-logo.png";
                break;
            case NewsSource.WALL_STREET_JOURNAL:
                icon_filename = "wsj-logo.png";
                break;
            default:
                return null;
        }
        
        // Try to find icon in data directory
        string icon_path = find_data_file("icons/" + icon_filename);
        return icon_path;
    }

    private void create_icon_placeholder(Gtk.Picture image, string icon_path, int width, int height) {
        try {
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, width, height);
            var cr = new Cairo.Context(surface);

            // Create gradient background matching source brand colors
            var gradient = new Cairo.Pattern.linear(0, 0, 0, height);
            
            switch (prefs.news_source) {
                case NewsSource.GUARDIAN:
                    gradient.add_color_stop_rgb(0, 0.0, 0.2, 0.4);  // Guardian blue
                    gradient.add_color_stop_rgb(1, 0.0, 0.4, 0.6);
                    break;
                case NewsSource.BBC:
                    gradient.add_color_stop_rgb(0, 0.6, 0.0, 0.0);  // BBC red
                    gradient.add_color_stop_rgb(1, 0.8, 0.1, 0.1);
                    break;
                case NewsSource.REDDIT:
                    gradient.add_color_stop_rgb(0, 1.0, 0.2, 0.0);  // Reddit orange
                    gradient.add_color_stop_rgb(1, 1.0, 0.4, 0.1);
                    break;
                case NewsSource.NEW_YORK_TIMES:
                    gradient.add_color_stop_rgb(0, 0.1, 0.1, 0.1);  // NYT dark
                    gradient.add_color_stop_rgb(1, 0.3, 0.3, 0.3);
                    break;
                case NewsSource.BLOOMBERG:
                    gradient.add_color_stop_rgb(0, 0.0, 0.3, 0.7);  // Bloomberg blue
                    gradient.add_color_stop_rgb(1, 0.1, 0.5, 0.9);
                    break;
                case NewsSource.REUTERS:
                    gradient.add_color_stop_rgb(0, 0.3, 0.3, 0.4);  // Neutral gray for Reuters logo visibility
                    gradient.add_color_stop_rgb(1, 0.5, 0.5, 0.6);
                    break;
                case NewsSource.NPR:
                    gradient.add_color_stop_rgb(0, 0.1, 0.2, 0.5);  // NPR blue
                    gradient.add_color_stop_rgb(1, 0.2, 0.3, 0.7);
                    break;
                case NewsSource.FOX:
                    gradient.add_color_stop_rgb(0, 0.0, 0.2, 0.6);  // Fox blue
                    gradient.add_color_stop_rgb(1, 0.1, 0.3, 0.8);
                    break;
                default:
                    gradient.add_color_stop_rgb(0, 0.3, 0.3, 0.4);
                    gradient.add_color_stop_rgb(1, 0.5, 0.5, 0.6);
                    break;
            }

            cr.set_source(gradient);
            cr.rectangle(0, 0, width, height);
            cr.fill();

            // Load and draw the source icon
            var icon_pixbuf = new Gdk.Pixbuf.from_file(icon_path);
            if (icon_pixbuf != null) {
                // Calculate scaled size preserving aspect ratio (max 50% of placeholder)
                int orig_width = icon_pixbuf.get_width();
                int orig_height = icon_pixbuf.get_height();
                
                double max_size = double.min(width, height) * 0.5;
                double scale_factor = double.min(max_size / orig_width, max_size / orig_height);
                
                int scaled_width = (int)(orig_width * scale_factor);
                int scaled_height = (int)(orig_height * scale_factor);
                
                var scaled_icon = icon_pixbuf.scale_simple(scaled_width, scaled_height, Gdk.InterpType.BILINEAR);
                
                // Center the icon
                int x = (width - scaled_width) / 2;
                int y = (height - scaled_height) / 2;
                
                // Draw icon with slight transparency for elegance
                cr.save();
                cr.set_source_rgba(1, 1, 1, 0.9);
                Gdk.cairo_set_source_pixbuf(cr, scaled_icon, x, y);
                cr.paint_with_alpha(0.95);
                cr.restore();
            }

            var texture = Gdk.Texture.for_pixbuf(Gdk.pixbuf_get_from_surface(surface, 0, 0, width, height));
            image.set_paintable(texture);

        } catch (GLib.Error e) {
            print("✗ Error creating icon placeholder: %s\n", e.message);
            // Fallback to text placeholder
            string source_name = get_source_name(prefs.news_source);
            create_source_text_placeholder(image, source_name, width, height);
        }
    }

    private void create_source_text_placeholder(Gtk.Picture image, string source_name, int width, int height) {
        try {
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, width, height);
            var cr = new Cairo.Context(surface);

            // Create gradient background based on source
            var gradient = new Cairo.Pattern.linear(0, 0, 0, height);
            
            // Use different colors for different sources
            switch (prefs.news_source) {
                case NewsSource.GUARDIAN:
                    gradient.add_color_stop_rgb(0, 0.0, 0.3, 0.6);  // Guardian blue
                    gradient.add_color_stop_rgb(1, 0.0, 0.5, 0.8);
                    break;
                case NewsSource.BBC:
                    gradient.add_color_stop_rgb(0, 0.7, 0.0, 0.0);  // BBC red
                    gradient.add_color_stop_rgb(1, 0.9, 0.2, 0.2);
                    break;
                case NewsSource.REDDIT:
                    gradient.add_color_stop_rgb(0, 1.0, 0.3, 0.0);  // Reddit orange
                    gradient.add_color_stop_rgb(1, 1.0, 0.5, 0.2);
                    break;
                case NewsSource.NEW_YORK_TIMES:
                    gradient.add_color_stop_rgb(0, 0.0, 0.0, 0.0);  // NYT black
                    gradient.add_color_stop_rgb(1, 0.2, 0.2, 0.2);
                    break;
                case NewsSource.BLOOMBERG:
                    gradient.add_color_stop_rgb(0, 0.0, 0.4, 0.8);  // Bloomberg blue
                    gradient.add_color_stop_rgb(1, 0.2, 0.6, 1.0);
                    break;
                case NewsSource.REUTERS:
                    gradient.add_color_stop_rgb(0, 0.4, 0.4, 0.4);  // Neutral gray for Reuters
                    gradient.add_color_stop_rgb(1, 0.6, 0.6, 0.6);
                    break;
                case NewsSource.NPR:
                    gradient.add_color_stop_rgb(0, 0.2, 0.2, 0.6);  // NPR blue
                    gradient.add_color_stop_rgb(1, 0.4, 0.4, 0.8);
                    break;
                case NewsSource.FOX:
                    gradient.add_color_stop_rgb(0, 0.0, 0.3, 0.7);  // Fox blue
                    gradient.add_color_stop_rgb(1, 0.2, 0.5, 0.9);
                    break;
                default:
                    gradient.add_color_stop_rgb(0, 0.4, 0.4, 0.4);
                    gradient.add_color_stop_rgb(1, 0.6, 0.6, 0.6);
                    break;
            }

            cr.set_source(gradient);
            cr.rectangle(0, 0, width, height);
            cr.fill();

            // Add source name text
            cr.select_font_face("Sans", Cairo.FontSlant.NORMAL, Cairo.FontWeight.BOLD);
            
            // Calculate font size based on dimensions
            double font_size = double.min(width / 8.0, height / 4.0);
            font_size = double.max(font_size, 12.0);
            cr.set_font_size(font_size);

            Cairo.TextExtents extents;
            cr.text_extents(source_name, out extents);

            // Center the text
            double x = (width - extents.width) / 2;
            double y = (height + extents.height) / 2;

            // White text with shadow
            cr.set_source_rgba(0, 0, 0, 0.5);
            cr.move_to(x + 2, y + 2);
            cr.show_text(source_name);

            cr.set_source_rgba(1, 1, 1, 0.9);
            cr.move_to(x, y);
            cr.show_text(source_name);

            var texture = Gdk.Texture.for_pixbuf(Gdk.pixbuf_get_from_surface(surface, 0, 0, width, height));
            image.set_paintable(texture);

        } catch (GLib.Error e) {
            print("✗ Error creating source placeholder: %s\n", e.message);
            // Simple fallback
            create_gradient_placeholder(image, width, height);
        }
    }

    private void set_placeholder_image(Gtk.Picture image, int width, int height) {
        // Get source icon and create branded placeholder
        string? icon_path = get_source_icon_path(prefs.news_source);
        string source_name = get_source_name(prefs.news_source);
    // creating placeholder for source (silent)
        
        if (icon_path != null) {
            create_icon_placeholder(image, icon_path, width, height);
        } else {
            // Fallback to text-based placeholder
            create_source_text_placeholder(image, source_name, width, height);
        }
    }

    private void load_source_logo_placeholder(Gtk.Picture image, string logo_url, int width, int height) {
        new Thread<void*>("load-logo", () => {
            try {
                var msg = new Soup.Message("GET", logo_url);
                msg.request_headers.append("User-Agent", "Mozilla/5.0 (Linux; rv:91.0) Gecko/20100101 Firefox/91.0");
                session.send_message(msg);

                if (msg.status_code == 200) {
                    uint8[] data = new uint8[msg.response_body.length];
                    Memory.copy(data, msg.response_body.data, (size_t)msg.response_body.length);
                    
                    var loader = new Gdk.PixbufLoader();
                    loader.write(data);
                    loader.close();
                    
                    var pixbuf = loader.get_pixbuf();
                    if (pixbuf != null) {
                        // Scale logo to fit nicely within the placeholder area
                        int logo_size = int.min(width, height) / 2;
                        var scaled = pixbuf.scale_simple(logo_size, logo_size, Gdk.InterpType.BILINEAR);
                        
                        // Create placeholder with logo centered on gradient background
                        Idle.add(() => {
                            create_logo_placeholder(image, scaled, width, height);
                            return false;
                        });
                        return null;
                    }
                }
            } catch (GLib.Error e) {
                // Logo loading failed, use gradient fallback
            }
            
            // Fallback to gradient placeholder
            Idle.add(() => {
                create_gradient_placeholder(image, width, height);
                return false;
            });
            return null;
        });
    }

    private void create_logo_placeholder(Gtk.Picture image, Gdk.Pixbuf logo, int width, int height) {
        try {
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, width, height);
            var cr = new Cairo.Context(surface);

            // Subtle gradient background
            var pattern = new Cairo.Pattern.linear(0, 0, width, height);
            pattern.add_color_stop_rgb(0, 0.95, 0.95, 0.97);
            pattern.add_color_stop_rgb(1, 0.88, 0.88, 0.92);
            cr.set_source(pattern);
            cr.paint();

            // Center the logo
            int logo_w = logo.get_width();
            int logo_h = logo.get_height();
            double x = (width - logo_w) / 2.0;
            double y = (height - logo_h) / 2.0;
            
            Gdk.cairo_set_source_pixbuf(cr, logo, x, y);
            cr.paint_with_alpha(0.7); // Slight transparency

            var texture = Gdk.Texture.for_pixbuf(Gdk.pixbuf_get_from_surface(surface, 0, 0, width, height));
            image.set_paintable(texture);
        } catch (GLib.Error e) {
            create_gradient_placeholder(image, width, height);
        }
    }

    private void create_gradient_placeholder(Gtk.Picture image, int width, int height) {
        try {
            var surface = new Cairo.ImageSurface(Cairo.Format.RGB24, width, height);
            var cr = new Cairo.Context(surface);

            // Gradient background
            var pattern = new Cairo.Pattern.linear(0, 0, width, height);
            pattern.add_color_stop_rgb(0, 0.2, 0.4, 0.8);
            pattern.add_color_stop_rgb(1, 0.1, 0.3, 0.6);
            cr.set_source(pattern);
            cr.paint();

            // Centered text
            cr.set_source_rgb(1.0, 1.0, 1.0);
            cr.select_font_face("Sans", Cairo.FontSlant.NORMAL, Cairo.FontWeight.BOLD);
            double font_size = double.max(12.0, height * 0.12);
            cr.set_font_size(font_size);
            Cairo.TextExtents extents;
            cr.text_extents("No Image", out extents);
            double tx = (width - extents.width) / 2.0 - extents.x_bearing;
            double ty = (height - extents.height) / 2.0 - extents.y_bearing;
            cr.move_to(tx, ty);
            cr.show_text("No Image");

            var texture = Gdk.Texture.for_pixbuf(Gdk.pixbuf_get_from_surface(surface, 0, 0, width, height));
            image.set_paintable(texture);
        } catch (GLib.Error e) {
            // If placeholder fails, just leave it blank
        }
    }

    // Helper: clamp integer between bounds
    private int clampi(int v, int min, int max) {
        if (v < min) return min;
        if (v > max) return max;
        return v;
    }

    // Estimate the available content width for both hero and columns
    private int estimate_content_width() {
        int w = content_area != null ? content_area.get_width() : this.get_width();
        if (w <= 0) w = 1280; // fall back to a reasonable default
        
        // Get current margin from main container (dynamically set)
        int current_margin = main_content_container != null ? 
            main_content_container.get_margin_start() : H_MARGIN;
        
        return clampi(w - (current_margin * 2), 600, 1400);
    }
    
    // Update main content container size based on sidebar visibility
    private void update_main_content_size(bool sidebar_visible) {
        if (main_content_container == null) return;
        
        // Adjust margins for the main container - this affects both hero and columns
        int margin = sidebar_visible ? H_MARGIN : 6; // Minimal margin when sidebar hidden
        
        main_content_container.set_margin_start(margin);
        main_content_container.set_margin_end(margin);
        
        // Update any existing hero card sizes to match new available width
        update_existing_hero_card_size();
    }
    
    // Update existing hero card to new size if it exists
    private void update_existing_hero_card_size() {
        if (!featured_used) return;
        
        // The hero card should now be automatically responsive to container changes
        // No manual resizing needed since it uses hexpand=true and halign=FILL
        
        // Just ensure the hero card is still properly configured
        var hero_card = featured_box.get_first_child();
        if (hero_card != null) {
            hero_card.set_hexpand(true);
            hero_card.set_halign(Gtk.Align.FILL);
        }
        // Also check any registered hero images to see if we should re-request larger variants
        foreach (var kv in hero_requests.entries) {
            Gtk.Picture pic = kv.key;
            HeroRequest info = kv.value;
            maybe_refetch_hero_for(pic, info);
        }
    }

    // If container/reported content width has grown since we last requested an image, re-request
    private void maybe_refetch_hero_for(Gtk.Picture picture, HeroRequest info) {
        if (picture == null || info == null) return;

        int base_desired = estimate_content_width();
        if (base_desired <= 0) return;

        // If the new base desired width is significantly larger than what we last requested, fetch again
        int last_base = (int)(info.last_requested_w / (double)info.multiplier);
        if (base_desired > last_base * 1.25 && info.retries < 3) {
            info.retries += 1;
            int new_w = base_desired * info.multiplier;
            int new_h = (int)(info.last_requested_h * ((double)base_desired / last_base));
            // Update recorded requested size immediately to avoid duplicate concurrent fetches
            info.last_requested_w = new_w;
            info.last_requested_h = new_h;
            print("Refetching hero image at larger size: %dx%d (retry %d)\n", new_w, new_h, info.retries);
            load_image_async(picture, info.url, new_w, new_h);
            // Schedule one more check in case layout continues to grow
            Timeout.add(500, () => {
                maybe_refetch_hero_for(picture, info);
                return false;
            });
        }
    }

    // Estimate a single column width given the number of columns
    private int estimate_column_width(int cols) {
        int content_w = estimate_content_width();
        int total_spacing = (cols - 1) * COL_SPACING;
        int col_w = (content_w - total_spacing) / cols;
        // Force compact cards that always fit
        return clampi(col_w, 160, 280);
    }

    

    // Recreate the columns for masonry layout with a new count
    private void rebuild_columns(int count) {
        // Remove any existing column widgets from the row
        Gtk.Widget? child = columns_row.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            columns_row.remove(child);
            child = next;
        }

        // Allocate new arrays
        columns_count = count;
        columns = new Gtk.Box[count];
        column_heights = new int[count];

        for (int i = 0; i < count; i++) {
            var col = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
            col.set_valign(Gtk.Align.START);
            col.set_halign(Gtk.Align.FILL);
            col.set_hexpand(true);
            col.set_vexpand(true);
            // Let GTK handle column sizing naturally with homogeneous container
            columns[i] = col;
            column_heights[i] = 0;
            columns_row.append(col);
        }
    }
    
    private void show_loading_spinner() {
        if (loading_container != null && loading_spinner != null) {
            loading_container.set_visible(true);
            loading_spinner.start();
        }
    }
    
    private void hide_loading_spinner() {
        if (loading_container != null && loading_spinner != null) {
            loading_container.set_visible(false);
            loading_spinner.stop();
        }
    }

    // Reveal main content (stop showing the loading spinner)
    private void reveal_initial_content() {
        if (!initial_phase) return;
        initial_phase = false;
        hero_image_loaded = false;
        if (initial_reveal_timeout_id > 0) {
            Source.remove(initial_reveal_timeout_id);
            initial_reveal_timeout_id = 0;
        }
        hide_loading_spinner();
    }

    // Called when an image finished being set on a Picture. If it's a hero image and we're
    // Called when an image finished being set (success or fallback). During the
    // initial phase we decrement the pending counter and reveal the UI when all
    // initial items are populated and no pending image loads remain.
    private void on_image_loaded(Gtk.Picture image) {
        if (!initial_phase) return;
        // If this image corresponds to a hero request, mark it
        if (hero_requests.get(image) != null) hero_image_loaded = true;
        // Decrement pending counter (safely)
        if (pending_images > 0) pending_images--;

        // If the initial items have been added and there are no pending images,
        // reveal the UI now.
        if (initial_items_populated && pending_images == 0) {
            reveal_initial_content();
        }
    }

    // Helper to mark that initial items have been added to the UI. If there are
    // no pending image loads, reveal the UI immediately.
    private void mark_initial_items_populated() {
        initial_items_populated = true;
        if (initial_phase && pending_images == 0) {
            reveal_initial_content();
        }
    }

    public void fetch_news() {
        // Ensure sidebar visibility reflects current source
        update_sidebar_for_source();
        // Clear featured hero and randomize columns count per fetch between 2 and 4 for extra variety
        // Clear featured
        Gtk.Widget? fchild = featured_box.get_first_child();
        while (fchild != null) {
            Gtk.Widget? next = fchild.get_next_sibling();
            featured_box.remove(fchild);
            fchild = next;
        }
        featured_used = false;
        // Reset featured carousel state so new category fetches start fresh
        if (featured_carousel_timeout_id != 0) {
            Source.remove(featured_carousel_timeout_id);
            featured_carousel_timeout_id = 0;
        }
        if (featured_carousel_items != null) {
            featured_carousel_items.clear();
        }
        featured_carousel_stack = null;
        featured_carousel_dots_box = null;
        featured_carousel_index = 0;
        featured_carousel_category = null;
        if (featured_carousel_dot_widgets != null) featured_carousel_dot_widgets.clear();
        rebuild_columns(3);
        // Reset category distribution tracking for new content
        category_column_counts.clear();
        recent_categories.clear();
        next_column_index = 0;
        article_buffer.clear();
        category_last_column.clear();
        
        // Clean up category tracking
        recent_category_queue.clear();
        articles_shown = 0;
        
        // Cancel any pending buffer flush
        if (buffer_flush_timeout_id > 0) {
            Source.remove(buffer_flush_timeout_id);
            buffer_flush_timeout_id = 0;
        }
        
        // Clear remaining articles from previous session
        remaining_articles = null;
        remaining_articles_index = 0;
        
        // Remove any existing Load More button
        if (load_more_button != null) {
            var parent = load_more_button.get_parent() as Gtk.Box;
            if (parent != null) {
                parent.remove(load_more_button);
            }
            load_more_button = null;
        }
        
        // Show loading spinner while fetching content
        show_loading_spinner();

        // Start initial-phase gating: wait for initial items and their images
        initial_phase = true;
        hero_image_loaded = false;
        pending_images = 0;
        initial_items_populated = false;
        if (initial_reveal_timeout_id > 0) {
            Source.remove(initial_reveal_timeout_id);
            initial_reveal_timeout_id = 0;
        }
        // Safety timeout: reveal after a reasonable maximum to avoid blocking forever
        initial_reveal_timeout_id = Timeout.add(INITIAL_MAX_WAIT_MS, () => {
            // Timeout reached; reveal content even if some images haven't finished
            reveal_initial_content();
            initial_reveal_timeout_id = 0;
            return false;
        });
        
        // Bump fetch_sequence so callbacks from older fetches are ignored
        fetch_sequence += 1;
        uint my_seq = fetch_sequence;

        // Capture a strong reference to `this` so the wrapped callbacks hold
        // the NewsWindow alive while they're queued. Without this the window
        // may be freed before the callback runs and member access will crash.
        var self_ref = this;
        // Explicitly bump the GLib reference count for the duration of this
        // fetch. We'll unref after a short safety timeout so we don't leak
        // refs if something goes wrong. This prevents callbacks from racing
        // against object destruction.
        // Increase and later decrease the object's reference count so the
        // callbacks won't race with object destruction.
        self_ref.ref();
        Timeout.add(INITIAL_MAX_WAIT_MS + 2000, () => {
            try { self_ref.unref(); } catch (GLib.Error e) { }
            return false;
        });

        // Wrapped set_label: only update if this fetch is still current
    SetLabelFunc wrapped_set_label = (text) => {
            if (my_seq != self_ref.fetch_sequence) return;
            // Extract just the category part before the " — " separator
            string category_part = text;
            int separator_pos = text.index_of(" — ");
            if (separator_pos > 0) {
                category_part = text.substring(0, separator_pos);
            }
            self_ref.category_label.set_text(category_part);
        };

        // Wrapped clear_items: only clear if this fetch is still current
        ClearItemsFunc wrapped_clear = () => {
            if (my_seq != self_ref.fetch_sequence) return;
            // Clearing was already done above in fetch_news(), but some sources
            // call clear_items again from worker threads; guard to avoid
            // clearing content created by a newer fetch.
            Gtk.Widget? cur = self_ref.featured_box.get_first_child();
            while (cur != null) {
                Gtk.Widget? next = cur.get_next_sibling();
                self_ref.featured_box.remove(cur);
                cur = next;
            }
            self_ref.featured_used = false;
            // Remove columns' children
            for (int i = 0; i < self_ref.columns.length; i++) {
                Gtk.Widget? curc = self_ref.columns[i].get_first_child();
                while (curc != null) {
                    Gtk.Widget? next = curc.get_next_sibling();
                    self_ref.columns[i].remove(curc);
                    curc = next;
                }
                self_ref.column_heights[i] = 0;
            }
            // Reset load-more state
            self_ref.article_buffer.clear();
            // Also clear image bookkeeping so subsequent fetches create
            // fresh widgets instead of updating removed ones.
            self_ref.url_to_picture.clear();
            self_ref.hero_requests.clear();
            self_ref.remaining_articles = null;
            self_ref.remaining_articles_index = 0;
            if (self_ref.load_more_button != null) {
                var parent = self_ref.load_more_button.get_parent() as Gtk.Box;
                if (parent != null) parent.remove(self_ref.load_more_button);
                self_ref.load_more_button = null;
            }
            self_ref.articles_shown = 0;
        };

        // Wrapped add_item: ignore items from stale fetches
    AddItemFunc wrapped_add = (title, url, thumbnail, category_id) => {
            if (my_seq != self_ref.fetch_sequence) return;
            self_ref.add_item(title, url, thumbnail, category_id);
        };

        NewsSources.fetch(
            prefs.news_source,
            prefs.category,
            current_search_query,
            session,
            wrapped_set_label,
            wrapped_clear,
            wrapped_add
        );
    }

    private void show_load_more_button() {
        if (load_more_button != null) return; // Already shown
        
        // Create Load More button
        load_more_button = new Gtk.Button.with_label("Load More Articles");
        load_more_button.add_css_class("suggested-action");
        load_more_button.add_css_class("pill");
        load_more_button.set_margin_top(20);
        load_more_button.set_margin_bottom(20);
        load_more_button.set_halign(Gtk.Align.CENTER);
        
        // Add click handler to load more articles
        load_more_button.clicked.connect(() => {
            // Show loading state with smooth feedback
            load_more_button.set_label("Loading...");
            load_more_button.set_sensitive(false);
            load_more_button.remove_css_class("suggested-action");
            load_more_button.add_css_class("loading");
            
            // Add slight delay for smooth visual feedback
            Timeout.add(150, () => {
                load_more_articles();
                return false;
            });
        });
        
        // Add button with smooth fade-in animation
        load_more_button.add_css_class("fade-out"); // Start invisible with CSS
        content_box.append(load_more_button);
        
        // Smooth fade-in effect
        Timeout.add(50, () => {
            load_more_button.remove_css_class("fade-out");
            load_more_button.add_css_class("fade-in");
            return false;
        });
    }
    
    private void load_more_articles() {
        if (remaining_articles == null || remaining_articles_index >= remaining_articles.length) {
            // No more articles to load, remove button
            if (load_more_button != null) {
                load_more_button.add_css_class("fade-out");
                Timeout.add(300, () => {
                    if (load_more_button != null) {
                        var parent = load_more_button.get_parent() as Gtk.Box;
                        if (parent != null) {
                            parent.remove(load_more_button);
                        }
                        load_more_button = null;
                    }
                    return false;
                });
            }
            return;
        }
        
        // Load another batch of articles (15 more)
        int articles_to_load = int.min(INITIAL_ARTICLE_LIMIT, remaining_articles.length - remaining_articles_index);
        
        for (int i = 0; i < articles_to_load; i++) {
            var article = remaining_articles[remaining_articles_index + i];
            add_item_shuffled(article.title, article.url, article.thumbnail_url, article.category_id);
        }
        
        remaining_articles_index += articles_to_load;
        
        // Remove the Load More button with smooth animation
        if (load_more_button != null) {
            load_more_button.add_css_class("fade-out");
            Timeout.add(300, () => {
                if (load_more_button != null) {
                    var parent = load_more_button.get_parent() as Gtk.Box;
                    if (parent != null) {
                        parent.remove(load_more_button);
                    }
                    load_more_button = null;
                }
                
                // If there are still more articles, show the button again after the new articles are loaded
                if (remaining_articles_index < remaining_articles.length) {
                    Timeout.add(500, () => {
                        show_load_more_button();
                        return false;
                    });
                }
                return false;
            });
        }
    }

}
