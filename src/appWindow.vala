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
    public string? source_name { get; set; }
    
    public ArticleItem(string title, string url, string? thumbnail_url, string category_id, string? source_name = null) {
        this.title = title;
        this.url = url;
        this.thumbnail_url = thumbnail_url;
        this.category_id = category_id;
        this.source_name = source_name;
    }
}

// Small helper object to track hero image requests (size, multiplier, retries)
public class HeroRequest : GLib.Object {
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

// Deferred request holder for widgets that postpone downloads until visible
public class DeferredRequest : GLib.Object {
    public string url { get; set; }
    public int w { get; set; }
    public int h { get; set; }

    public DeferredRequest(string url, int w, int h) {
        this.url = url;
        this.w = w;
        this.h = h;
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
    private Gee.ArrayList<Gtk.Widget> featured_carousel_widgets;
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
    // During the initial loading phase we throttle concurrent downloads/decodes
    // to reduce main-loop jank (spinner animation stutter). This lower cap is
    // only used while `initial_phase` is true.
    private const int INITIAL_PHASE_MAX_CONCURRENT_DOWNLOADS = 3;
    private string current_search_query = "";
    private Gtk.Label category_label;
    private Gtk.Label source_label;
    private Gtk.Image source_logo;
    // Holder for the category icon shown to the left of the category title
    private Gtk.Box? category_icon_holder;
    private Gtk.ToggleButton sidebar_toggle;
    private Gtk.Box sidebar_spacer;
    private Gtk.ListBox sidebar_list;
    private Adw.OverlaySplitView split_view;
    private Gtk.ScrolledWindow sidebar_scrolled;
    // Main content scrolled window (exposed so we can capture/restore scroll)
    private Gtk.ScrolledWindow main_scrolled;
    private NewsPreferences prefs;
    // Holders for sidebar prefix icons so we can live-switch on theme changes
    private Gee.HashMap<string, Gtk.Box> sidebar_icon_holders = new Gee.HashMap<string, Gtk.Box>();
    // Navigation for sliding article preview
    private Adw.NavigationView nav_view;
    private Gtk.Button back_btn;
    private ArticleWindow article_window;
    // Article preview overlay split view (slides in from right)
    private Adw.OverlaySplitView article_preview_split;
    private Gtk.Box article_preview_content;
    // Dim overlay to disable main area when article preview is open
    private Gtk.Box dim_overlay;
    // Track category distribution across columns for better spread
    private Gee.HashMap<string, int> category_column_counts;
    // Track recent category placements to prevent horizontal clustering
    private Gee.ArrayList<string> recent_categories;
    // Simple counter for round-robin distribution in "All Categories"
    private int next_column_index;
    // Buffer for articles when in "All Categories" mode to allow shuffling
    public Gee.ArrayList<ArticleItem> article_buffer;
    // Track hero image request metadata so we can re-fetch on resize
    private Gee.HashMap<Gtk.Picture, HeroRequest> hero_requests;
    // Map article URL -> picture widget so we can update images in-place when higher-res images arrive
    private Gee.HashMap<string, Gtk.Picture> url_to_picture;
    // Map article URL -> card/hero widget so we can add overlays (e.g., viewed badge)
    private Gee.HashMap<string, Gtk.Widget> url_to_card;
    // Map normalized article URL -> original request URL (so upgrades use the real remote URL)
    private Gee.HashMap<string, string> normalized_to_url;
    // Track which normalized URLs the user has viewed during this session
    private Gee.HashSet<string> viewed_articles;
    // Remember the URL of the currently-open preview so keyboard/escape handlers
    // can mark viewed when the user returns to the main view
    private string? last_previewed_url;
    // Keep the last vertical scroll offset so we can restore it when closing previews
    private double last_scroll_value = -1.0;
    private MetaCache? meta_cache;

    // In-memory image cache (URL -> Gdk.Texture) to avoid repeated decodes during a session
    private Gee.HashMap<string, Gdk.Texture> memory_meta_cache;
    // Track the last requested size for each URL so we can upgrade images
    // after the initial phase without re-scanning the UI.
    private Gee.HashMap<string, string> requested_image_sizes;
    // Pending-downloads map for request deduplication: URL -> list of Gtk.Picture targets
    private Gee.HashMap<string, Gee.ArrayList<Gtk.Picture>> pending_downloads;

    // Deferred downloads for widgets that are not yet visible: Picture -> DeferredRequest
    private Gee.HashMap<Gtk.Picture, DeferredRequest> deferred_downloads;
    private uint deferred_check_timeout_id = 0;

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
        int total = featured_carousel_widgets != null ? featured_carousel_widgets.size : 0;
        if (total <= 1) return;
        // Advance index and select next widget that is actually in the stack
        featured_carousel_index = (featured_carousel_index + 1) % total;
        for (int i = 0; i < total; i++) {
            var child = featured_carousel_widgets.get(featured_carousel_index) as Gtk.Widget;
            if (child != null && child.get_parent() == featured_carousel_stack) {
                featured_carousel_stack.set_visible_child(child);
                update_carousel_dots(featured_carousel_index);
                return;
            }
            featured_carousel_index = (featured_carousel_index + 1) % total;
        }
        append_debug_log("carousel_next: no valid child found for stack");
    }

    // Move carousel to the previous slide
    private void carousel_prev() {
        if (featured_carousel_stack == null) return;
        int total = featured_carousel_widgets != null ? featured_carousel_widgets.size : 0;
        if (total <= 1) return;
        // Move backwards and pick a valid widget actually present in the stack
        featured_carousel_index = (featured_carousel_index - 1 + total) % total;
        for (int i = 0; i < total; i++) {
            var child = featured_carousel_widgets.get(featured_carousel_index) as Gtk.Widget;
            if (child != null && child.get_parent() == featured_carousel_stack) {
                featured_carousel_stack.set_visible_child(child);
                update_carousel_dots(featured_carousel_index);
                return;
            }
            featured_carousel_index = (featured_carousel_index - 1 + total) % total;
        }
        append_debug_log("carousel_prev: no valid child found for stack");
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
    private Gtk.Label? loading_label = null;
    // Message box shown in main content when personalized feed is disabled
    private Gtk.Box? personalized_message_box = null;
    // Label and action button inside the personalized message overlay
    private Gtk.Label? personalized_message_label = null;
    private Gtk.Button? personalized_message_action = null;
    // Local-news guidance overlay (shown when no location configured)
    private Gtk.Box? local_news_message_box = null;
    private Gtk.Label? local_news_title = null;
    private Gtk.Label? local_news_hint = null;
    private Gtk.Button? local_news_button = null;
    // Initial-load gating: wait for hero (or timeout) before revealing main content
    private bool initial_phase = false;
    private bool hero_image_loaded = false;
    private uint initial_reveal_timeout_id = 0;
    // Track pending image loads during initial phase so we can keep the spinner
    // visible until all initial images are ready (with a safety timeout).
    private int pending_images = 0;
    private bool initial_items_populated = false;
    private const int INITIAL_MAX_WAIT_MS = 5000; // maximum time to wait for images
    // Debug log path (written when PAPERBOY_DEBUG is set)
    private string debug_log_path = "/tmp/paperboy-debug.log";

    private void append_debug_log(string line) {
        try {
            string path = debug_log_path;
            string old = "";
            try { GLib.FileUtils.get_contents(path, out old); } catch (GLib.Error e) { old = ""; }
            string outc = old + line + "\n";
            GLib.FileUtils.set_contents(path, outc);
        } catch (GLib.Error e) {
            // best-effort logging only
        }
    }

    // Small helper to join a Gee.ArrayList<string> for debug output
    private string array_join(Gee.ArrayList<string>? list) {
        if (list == null) return "(null)";
        string out = "";
        try {
            foreach (var s in list) {
                if (out.length > 0) out += ",";
                out += s;
            }
        } catch (GLib.Error e) { return "(error)"; }
        return out;
    }

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
            // Prefer pre-bundled symbolic mono icons (both black and white
            // variants live in data/icons/symbolic/). Fall back to the
            // original data/icons/ location for compatibility.
            string[] candidates = {
                GLib.Path.build_filename("icons", "symbolic", filename),
                GLib.Path.build_filename("icons", filename)
            };
            string? icon_path = null;
            foreach (var c in candidates) {
                icon_path = find_data_file(c);
                if (icon_path != null) break;
            }

            if (icon_path != null) {
                try {
                    // If we're in dark mode, prefer a bundled white variant
                    // shipped alongside the symbolic icons: <name>-white.svg.
                    string use_path = icon_path;
                    if (is_dark_mode()) {
                        string alt_name;
                        if (filename.has_suffix(".svg"))
                            alt_name = filename.substring(0, filename.length - 4) + "-white.svg";
                        else
                            alt_name = filename + "-white.svg";

                        string? white_candidate = null;
                        // Check the symbolic folder first for the white asset
                        white_candidate = find_data_file(GLib.Path.build_filename("icons", "symbolic", alt_name));
                        if (white_candidate == null) white_candidate = find_data_file(GLib.Path.build_filename("icons", alt_name));
                        if (white_candidate != null) use_path = white_candidate;
                    }

                    var img = new Gtk.Image.from_file(use_path);
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
            // Debug: log sidebar activations when debug env var is set
            try {
                string? _dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                if (_dbg != null && _dbg.length > 0) {
                    append_debug_log("sidebar_activate: category=" + cat + " title=" + title);
                }
            } catch (GLib.Error e) { }
            // Persist selection immediately and update UI selection synchronously
            prefs.category = cat;
            // Update the header category icon immediately so users get
            // instant visual feedback of the selected category.
            try { update_category_icon(); } catch (GLib.Error e) { }
            try {
                string? _dbg3 = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                if (_dbg3 != null && _dbg3.length > 0) append_debug_log("activation_set_prefs: prefs.category=" + prefs.category);
            } catch (GLib.Error e) { }
            prefs.save_config();
            try { sidebar_list.select_row(row); } catch (GLib.Error e) { }
            // Immediately update local-news overlay visibility so the UI
            // reflects the new selection without waiting for the deferred
            // idle callback. This avoids confusing delays where clicking
            // "Local News" appears to do nothing.
            try { update_local_news_ui(); } catch (GLib.Error e) { }

            // If the user activated the special "frontpage" row, trigger
            // the fetch immediately (instead of only deferring it). This
            // prevents a subtle race where the deferred idle path may
            // observe a different UI/source state when exactly one
            // preferred source is configured and fall back to "All
            // Categories". Calling fetch synchronously here ensures the
            // backend frontpage fetch runs reliably on click.
            try {
                if (cat == "frontpage") {
                    fetch_news();
                    return;
                }
            } catch (GLib.Error e) { }

            // Defer the fetch to the main loop to avoid re-entrant rebuilds
            // that remove the row while the handler is still running. Set
            // the preference again inside the Idle callback to avoid race
            // conditions with other scheduled work that may overwrite it.
            Idle.add(() => {
                try {
                    prefs.category = cat;
                    prefs.save_config();
                } catch (GLib.Error e) { }
                // Debug: note that the deferred callback is running and what
                // category we'll fetch for
                try {
                    string? _dbg2 = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                    if (_dbg2 != null && _dbg2.length > 0) append_debug_log("idle_fetch: scheduled_category=" + prefs.category);
                } catch (GLib.Error e) { }
                try { fetch_news(); } catch (GLib.Error e) { }
                try { update_personalization_ui(); } catch (GLib.Error e) { }
                return false;
            });
        });
        sidebar_list.append(row);
        // Debug: record row additions
        try {
            string? _dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
            if (_dbg != null && _dbg.length > 0) append_debug_log("sidebar_add_row: cat=" + cat + " title=" + title + " selected=" + (selected ? "yes" : "no"));
        } catch (GLib.Error e) { }
        if (selected) sidebar_list.select_row(row);
    }

    // Rebuild the sidebar rows according to the currently selected source
    private void rebuild_sidebar_rows_for_source() {
        // Debug: log sidebar rebuild and preferred sources for tracing
        try {
            string? _dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                if (_dbg != null && _dbg.length > 0) {
                    string pref = array_join(prefs.preferred_sources);
                    append_debug_log("rebuild_sidebar: preferred_sources=" + pref + " current_category=" + prefs.category);
                }
        } catch (GLib.Error e) { }
        // Clear existing rows
        int removed = 0;
        Gtk.Widget? child = sidebar_list.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            try { sidebar_list.remove(child); } catch (GLib.Error e) { }
            child = next;
            removed++;
        }
        try {
            string? _dbg2 = GLib.Environment.get_variable("PAPERBOY_DEBUG");
            if (_dbg2 != null && _dbg2.length > 0) append_debug_log("rebuild_sidebar: removed_rows=" + removed.to_string());
        } catch (GLib.Error e) { }

    // Place "The Frontpage" and "My Feed" above the Categories header,
    // then include the "All Categories" option
    sidebar_add_row("The Frontpage", "frontpage", prefs.category == "frontpage");
    sidebar_add_row("My Feed", "myfeed", prefs.category == "myfeed");
    // Local News is a special sidebar item that is not part of Categories
    sidebar_add_row("Local News", "local_news", prefs.category == "local_news");
    sidebar_add_header("Categories");
    sidebar_add_row("All Categories", "all", prefs.category == "all");

    // If multiple preferred sources are selected, build the union of
    // categories supported by those sources and show only those rows.
    if (prefs.preferred_sources != null && prefs.preferred_sources.size > 1) {
        var allowed = new Gee.HashMap<string, bool>();
        // Default fallback categories most sources support
        string[] default_cats = { "general", "us", "technology", "science", "sports", "health", "entertainment", "politics", "lifestyle" };
        // Add defaults for any multi-source selection, then add source-specific ones
        foreach (var c in default_cats) allowed.set(c, true);

        foreach (var id in prefs.preferred_sources) {
            switch (id) {
                case "bloomberg": {
                    allowed.set("markets", true);
                    allowed.set("industries", true);
                    allowed.set("economics", true);
                    allowed.set("wealth", true);
                    allowed.set("green", true);
                    // Bloomberg also has technology & politics which are already allowed above
                }
                break;
                case "guardian": {
                    // Guardian covers the default set; no-op
                }
                break;
                case "nytimes": {
                    // NYT uses defaults but lacks a dedicated 'lifestyle' feed in some cases
                }
                break;
                case "reddit": {
                    // Reddit can supply most categories via subreddits
                }
                break;
                case "wsj": {
                    // WSJ supports world, tech, sports, health, etc.
                }
                break;
                case "bbc": {
                    // BBC supports the default set
                }
                break;
                default: {
                    // Unknown sources: assume defaults
                }
                break;
            }
        }

        // Display categories in a stable, prioritized order
        string[] priority = { "general", "us", "technology", "science", "markets", "industries", "economics", "wealth", "green", "sports", "health", "entertainment", "politics", "lifestyle" };
        foreach (var cat in priority) {
            bool present = false;
            // Gee.HashMap<bool> returns a bool for get; avoid comparing to null.
            // Iterate entries to safely detect presence and truthiness.
            foreach (var kv in allowed.entries) {
                if (kv.key == cat) { present = kv.value; break; }
            }
            if (present) sidebar_add_row(category_display_name_for(cat), cat, prefs.category == cat);
        }
        return;
    }

    // Single-source path: show categories appropriate to the selected source
    // Use the effective source (honour a single-item preferred_sources list)
    NewsSource sidebar_eff = effective_news_source();
    if (sidebar_eff == NewsSource.BLOOMBERG) {
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
        // Only show "Lifestyle" for sources that actually support it. BBC
        // does not expose a dedicated lifestyle RSS feed, so hide the row
        // when the effective single source is BBC.
        try {
            if (NewsSources.supports_category(sidebar_eff, "lifestyle")) {
                sidebar_add_row("Lifestyle", "lifestyle", prefs.category == "lifestyle");
            }
        } catch (GLib.Error e) {
            // On error, conservatively show the row to avoid hiding UI unexpectedly
            sidebar_add_row("Lifestyle", "lifestyle", prefs.category == "lifestyle");
        }
    }
    }

    // Update the source logo and label based on current news source
    private void update_source_info() {
        // If the user is viewing Local News, prefer the app-local
        // 'local-mono' symbolic icon (and its white variant in dark mode).
        // This prevents theme-change handlers from overwriting the Local
        // News badge with a provider-specific logo (e.g. Guardian).
        try {
            if (prefs != null && prefs.category == "local_news") {
                try { source_label.set_text("Local News"); } catch (GLib.Error e) { }
                try {
                    string? local_icon = find_data_file(GLib.Path.build_filename("icons", "symbolic", "local-mono.svg"));
                    if (local_icon == null) local_icon = find_data_file(GLib.Path.build_filename("icons", "local-mono.svg"));
                    if (local_icon != null) {
                        string use_path = local_icon;
                        try {
                            if (is_dark_mode()) {
                                string? white_cand = find_data_file(GLib.Path.build_filename("icons", "symbolic", "local-mono-white.svg"));
                                if (white_cand == null) white_cand = find_data_file(GLib.Path.build_filename("icons", "local-mono-white.svg"));
                                if (white_cand != null) use_path = white_cand;
                            }
                        } catch (GLib.Error e) { }
                        var pix = new Gdk.Pixbuf.from_file_at_size(use_path, 32, 32);
                        if (pix != null) {
                            var tex = Gdk.Texture.for_pixbuf(pix);
                            try { source_logo.set_from_paintable(tex); } catch (GLib.Error e) { try { source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { } }
                        } else {
                            try { source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error e) { }
                        }
                    } else {
                        try { source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error e) { }
                    }
                } catch (GLib.Error e) { try { source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { } }
                return;
            }
        } catch (GLib.Error e) { }
        // If multiple preferred sources are selected, show a combined label
        // For the special "frontpage" category, present a generic
        // "Multiple Sources" label and bundled monochrome logo. Keep this
        // UI-only: fetching is handled elsewhere (in fetch_news) so we must
        // not attempt to call fetch-specific callbacks or variables here.
        if (prefs.category == "frontpage") {
            try { source_label.set_text("Multiple Sources"); } catch (GLib.Error e) { }
            try {
                string? multi_icon = find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono.svg"));
                if (multi_icon == null) multi_icon = find_data_file(GLib.Path.build_filename("icons", "multiple-mono.svg"));
                if (multi_icon != null) {
                    string use_path = multi_icon;
                    try {
                        if (is_dark_mode()) {
                            string? white_cand = find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono-white.svg"));
                            if (white_cand == null) white_cand = find_data_file(GLib.Path.build_filename("icons", "multiple-mono-white.svg"));
                            if (white_cand != null) use_path = white_cand;
                        }
                    } catch (GLib.Error e) { }
                    try {
                        var pix = new Gdk.Pixbuf.from_file_at_size(use_path, 32, 32);
                        if (pix != null) {
                            var tex = Gdk.Texture.for_pixbuf(pix);
                            source_logo.set_from_paintable(tex);
                        } else {
                            try { source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { }
                        }
                    } catch (GLib.Error e) { try { source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { } }
                } else {
                    try { source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error e) { }
                }
            } catch (GLib.Error e) { }
            return;
        }

        if (prefs.preferred_sources != null && prefs.preferred_sources.size > 1) {
            source_label.set_text("Multiple Sources");
            // Prefer the pre-bundled symbolic mono icons (symbolic/)
            string? multi_icon = find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono.svg"));
            if (multi_icon == null) multi_icon = find_data_file(GLib.Path.build_filename("icons", "multiple-mono.svg"));
            if (multi_icon != null) {
                try {
                    string use_path = multi_icon;
                    try {
                        if (is_dark_mode()) {
                            string? white_candidate = find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono-white.svg"));
                            if (white_candidate == null) white_candidate = find_data_file(GLib.Path.build_filename("icons", "multiple-mono-white.svg"));
                            if (white_candidate != null) use_path = white_candidate;
                        }
                    } catch (GLib.Error e) { }
                    var pix = new Gdk.Pixbuf.from_file_at_size(use_path, 32, 32);
                    if (pix != null) {
                        var tex = Gdk.Texture.for_pixbuf(pix);
                        source_logo.set_from_paintable(tex);
                        return;
                    }
                } catch (GLib.Error e) { /* fall back to symbolic icon below */ }
            }
            try { source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error e) { }
            return;
        }

    // Determine effective single source (if the user enabled exactly one
    // preferred source, treat that as the active source). This lets the
    // multi-select preferences influence the single-source UI when the
    // user chooses exactly one source via the preferences dialog.
    NewsSource eff = effective_news_source();

    string source_name = "";
    string? logo_file = null;
        
    switch (eff) {
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

    // Return the NewsSource the UI should treat as "active". If the
    // user has enabled exactly one preferred source, map that id to the
    // corresponding enum; otherwise use the explicit prefs.news_source.
    private NewsSource effective_news_source() {
        if (prefs.preferred_sources != null && prefs.preferred_sources.size == 1) {
            try {
                string id = prefs.preferred_sources.get(0);
                switch (id) {
                    case "guardian": return NewsSource.GUARDIAN;
                    case "reddit": return NewsSource.REDDIT;
                    case "bbc": return NewsSource.BBC;
                    case "nytimes": return NewsSource.NEW_YORK_TIMES;
                    case "wsj": return NewsSource.WALL_STREET_JOURNAL;
                    case "bloomberg": return NewsSource.BLOOMBERG;
                    case "reuters": return NewsSource.REUTERS;
                    case "npr": return NewsSource.NPR;
                    case "fox": return NewsSource.FOX;
                    default: return prefs.news_source;
                }
            } catch (GLib.Error e) {
                return prefs.news_source;
            }
        }
        return prefs.news_source;
    }

    // Determine if the system is currently using dark mode
    private bool is_dark_mode() {
        var sm = Adw.StyleManager.get_default();
        return sm != null ? sm.dark : false;
    }

    private Gtk.Label? personalized_message_sub_label;

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
    // Map of normalized article URL -> card/hero widget (used for overlays like Viewed)
    url_to_card = new Gee.HashMap<string, Gtk.Widget>();
    normalized_to_url = new Gee.HashMap<string, string>();
    // Track viewed articles in this session
    viewed_articles = new Gee.HashSet<string>();
    // Initialize in-memory cache and pending-downloads map
    memory_meta_cache = new Gee.HashMap<string, Gdk.Texture>();
    requested_image_sizes = new Gee.HashMap<string, string>();
    pending_downloads = new Gee.HashMap<string, Gee.ArrayList<Gtk.Picture>>();
    deferred_downloads = new Gee.HashMap<Gtk.Picture, DeferredRequest>();
    // Initialize on-disk cache helper
    try {
        meta_cache = new MetaCache();
    } catch (GLib.Error e) {
        meta_cache = null;
    }
        
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
        back_btn.clicked.connect(() => {
            if (nav_view != null) {
                nav_view.pop();
                back_btn.set_visible(false);
            }
        });
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
    menu.append("Preferences", "app.change-source");
    menu.append("Set User Location", "app.set-location");
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

    // Place "The Frontpage" and "My Feed" above the Categories header,
    // then include the "All Categories" option
    sidebar_add_row("The Frontpage", "frontpage", prefs.category == "frontpage");
    sidebar_add_row("My Feed", "myfeed", prefs.category == "myfeed");
    // Local News is a special sidebar item that is not part of Categories
    sidebar_add_row("Local News", "local_news", prefs.category == "local_news");
    sidebar_add_header("Categories");
    sidebar_add_row("All Categories", "all", prefs.category == "all");
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

    // Build main content UI in a separate helper object so the window
    // constructor stays concise. ContentView constructs the widgets and
    // exposes them; we then wire them into the existing NewsWindow fields.
    var content_view = new ContentView(prefs);
    category_label = content_view.category_label;
    category_icon_holder = content_view.category_icon_holder;
    source_logo = content_view.source_logo;
    source_label = content_view.source_label;
    main_content_container = content_view.main_content_container;
    hero_container = content_view.hero_container;
    featured_box = content_view.featured_box;
    columns_row = content_view.columns_row;
    content_area = content_view.content_area;
    content_box = content_view.content_box;
    main_scrolled = content_view.main_scrolled;
    loading_container = content_view.loading_container;
    loading_spinner = content_view.loading_spinner;
    loading_label = content_view.loading_label;
    personalized_message_box = content_view.personalized_message_box;
    personalized_message_label = content_view.personalized_message_label;
    personalized_message_sub_label = content_view.personalized_message_sub_label;
    personalized_message_action = content_view.personalized_message_action;
    local_news_message_box = content_view.local_news_message_box;
    local_news_title = content_view.local_news_title;
    local_news_hint = content_view.local_news_hint;
    local_news_button = content_view.local_news_button;

    // Split view: sidebar + content with collapsible sidebar
    split_view = new Adw.OverlaySplitView();
    split_view.set_sidebar(sidebar_scrolled);
    // Wrap content in a NavigationView so we can slide in a preview page
    nav_view = new Adw.NavigationView();
    var main_page = new Adw.NavigationPage(main_scrolled, "Main");
    nav_view.push(main_page);

    // Create a root overlay that wraps the NavigationView so we can
    // overlay the personalized-message box across the entire visible
    // viewport (not just the inner scrolled content). This makes centering
    // reliable regardless of scroll/content size.
    var root_overlay = new Gtk.Overlay();
    root_overlay.set_child(nav_view);
    
    // Create article preview overlay split view (slides in from right)
    article_preview_split = new Adw.OverlaySplitView();
    article_preview_split.set_show_sidebar(false);
    article_preview_split.set_sidebar_position(Gtk.PackType.END); // Right side
    article_preview_split.set_max_sidebar_width(480);  // 20% thinner (was 600)
    article_preview_split.set_min_sidebar_width(320);  // 20% thinner (was 400)
    article_preview_split.set_sidebar_width_fraction(0.32);  // 20% thinner (was 0.4)
    article_preview_split.set_collapsed(true); // Always overlay, never push content
    article_preview_split.set_enable_show_gesture(false); // Disable swipe to prevent accidental opens
    article_preview_split.set_enable_hide_gesture(true);  // Allow swipe to close
    
    // Create article preview content container
    article_preview_content = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
    var preview_scrolled = new Gtk.ScrolledWindow();
    preview_scrolled.set_child(article_preview_content);
    preview_scrolled.set_vexpand(true);
    preview_scrolled.set_hexpand(true);
    
    // Wrap scrolled window in a box for proper rounded corner rendering
    var preview_wrapper = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
    preview_wrapper.append(preview_scrolled);
    preview_wrapper.set_vexpand(true);
    preview_wrapper.set_hexpand(true);
    preview_wrapper.add_css_class("article-preview-panel");
    
    article_preview_split.set_sidebar(preview_wrapper);
    
    // Wrap root_overlay with article preview split
    article_preview_split.set_content(root_overlay);
    
    // Create dim overlay to disable main area when article preview is open
    dim_overlay = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
    dim_overlay.set_vexpand(true);
    dim_overlay.set_hexpand(true);
    dim_overlay.set_visible(false);
    dim_overlay.add_css_class("dim-overlay");
    
    // Add click handler to close preview when clicking the dim overlay
    var dim_click = new Gtk.GestureClick();
    dim_click.pressed.connect(() => {
        article_preview_split.set_show_sidebar(false);
        back_btn.set_visible(false);
        // Call preview_closed with the last URL to properly mark viewed and restore scroll
        try {
            if (last_previewed_url != null && last_previewed_url.length > 0) {
                preview_closed(last_previewed_url);
            } else {
                dim_overlay.set_visible(false);
            }
        } catch (GLib.Error e) { 
            dim_overlay.set_visible(false);
        }
    });
    dim_overlay.add_controller(dim_click);
    
    root_overlay.add_overlay(dim_overlay);
    
    // Add the personalized message overlay on top of the root overlay
    root_overlay.add_overlay(personalized_message_box);

    // Reparent the initial loading spinner overlay from the inner
    // `main_overlay` to `root_overlay` so it truly centers within the
    // visible viewport (not just the scrolled content area). Use a
    // best-effort approach and ignore errors during early initialization.
    try {
        if (loading_container != null) {
            try { content_view.main_overlay.remove_overlay(loading_container); } catch (GLib.Error e) { }
            try { root_overlay.add_overlay(loading_container); } catch (GLib.Error e) { }
        }
    } catch (GLib.Error e) { }

    // Local News overlay: shown when the user selects Local News but has not
    // configured a location in preferences. This is separate from the
    // personalized_message_box so it can be tailored to local-news guidance.
    local_news_message_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
    local_news_message_box.set_halign(Gtk.Align.FILL);
    local_news_message_box.set_valign(Gtk.Align.FILL);
    local_news_message_box.set_hexpand(true);
    local_news_message_box.set_vexpand(true);

    var ln_inner = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
    ln_inner.set_hexpand(true);
    ln_inner.set_vexpand(true);
    ln_inner.set_halign(Gtk.Align.CENTER);
    ln_inner.set_valign(Gtk.Align.CENTER);

    local_news_title = new Gtk.Label("To See Local News, Set Your Location in Preferences");
    local_news_title.add_css_class("title-4");
    local_news_title.add_css_class("dim-label");
    local_news_title.set_halign(Gtk.Align.CENTER);
    local_news_title.set_valign(Gtk.Align.CENTER);
    try { local_news_title.set_justify(Gtk.Justification.CENTER); } catch (GLib.Error e) { }
    try { local_news_title.set_wrap(true); } catch (GLib.Error e) { }
    ln_inner.append(local_news_title);

    local_news_hint = new Gtk.Label("Open the main menu (☰) and choose 'Set User Location' to configure your city or ZIP code.");
    local_news_hint.add_css_class("dim-label");
    local_news_hint.set_halign(Gtk.Align.CENTER);
    local_news_hint.set_valign(Gtk.Align.CENTER);
    try { local_news_hint.set_wrap(true); } catch (GLib.Error e) { }
    local_news_hint.set_margin_top(6);
    ln_inner.append(local_news_hint);

    local_news_button = new Gtk.Button.with_label("Set Location");
    local_news_button.set_halign(Gtk.Align.CENTER);
    local_news_button.set_valign(Gtk.Align.CENTER);
    local_news_button.set_margin_top(12);
    local_news_button.clicked.connect(() => {
        try { PrefsDialog.show_set_location_dialog(this); } catch (GLib.Error e) { }
    });
    ln_inner.append(local_news_button);

    local_news_message_box.append(ln_inner);
    local_news_message_box.set_visible(false);
    root_overlay.add_overlay(local_news_message_box);

    split_view.set_content(article_preview_split); // Wrap with article preview overlay
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
        article_window.set_preview_overlay(article_preview_split, article_preview_content);

        // Add keyboard event controller for closing article preview with Escape
        var key_controller = new Gtk.EventControllerKey();
        key_controller.key_pressed.connect((keyval, keycode, state) => {
            if (keyval == Gdk.Key.Escape && back_btn.get_visible()) {
                // Close article preview if it's open
                article_preview_split.set_show_sidebar(false);
                back_btn.set_visible(false);
                // Call preview_closed to properly mark viewed and restore scroll
                try {
                    if (last_previewed_url != null && last_previewed_url.length > 0) {
                        preview_closed(last_previewed_url);
                    } else {
                        dim_overlay.set_visible(false);
                    }
                } catch (GLib.Error e) { 
                    dim_overlay.set_visible(false);
                }
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
                article_preview_split.set_show_sidebar(false);
                back_btn.set_visible(false);
                // Call preview_closed to properly mark viewed and restore scroll
                try {
                    if (last_previewed_url != null && last_previewed_url.length > 0) {
                        preview_closed(last_previewed_url);
                    } else {
                        dim_overlay.set_visible(false);
                    }
                } catch (GLib.Error e) { 
                    dim_overlay.set_visible(false);
                }
            }
        });
        split_view.add_controller(main_click_controller);

        // Listen for theme changes to live-switch custom icons
        var sm = Adw.StyleManager.get_default();
        if (sm != null) {
            // When the theme's dark property changes, update sidebar icons
            // and the source/logo in the header so bundled mono icons
            // (including the multi-source icon) can be swapped for their
            // white variants or back to the original variant as appropriate.
            sm.notify["dark"].connect(() => {
                try {
                    update_sidebar_icons_for_theme();
                    // Update the top-right source logo to pick the correct
                    // white or normal variant based on the new theme.
                    try { update_source_info(); } catch (GLib.Error e) { }
                    // Update the category icon in the header so bundled
                    // mono icons can swap to their white variants in dark
                    // mode as well.
                    try { update_category_icon(); } catch (GLib.Error e) { }
                } catch (GLib.Error e) { }
            });
        }

        // initial state and fetch
        update_sidebar_for_source();
        // If this is the user's first run, the preferences dialog will be
        // presented from main.activate(). Defer the initial network fetch
        // so the dialog can appear and the user can adjust sources first.
        try {
            var prefs_local = NewsPreferences.get_instance();
            if (prefs_local == null || !prefs_local.first_run) {
                fetch_news();
            }
        } catch (GLib.Error e) { fetch_news(); }

    // Ensure the personalized message visibility is correct at startup
    update_personalization_ui();

        // Clear only cached images on window close to avoid disk clutter
        // while preserving per-article metadata (e.g., viewed flags).
        this.close_request.connect(() => {
            if (meta_cache != null) {
                try { meta_cache.clear_images(); } catch (GLib.Error e) { }
            }
            return false; // allow default handler to run
        });
    }

    // Public helper so external callers (e.g., dialogs) can close an open article preview
    public void close_article_preview() {
        if (back_btn != null && back_btn.get_visible()) {
            if (nav_view != null) nav_view.pop();
            back_btn.set_visible(false);
        }
    }

    // Update the small category icon shown left of the main category title.
    // This re-creates the icon according to the active prefs.category and
    // respects theme changes (create_category_icon already chooses white
    // variants when in dark mode).
    private void update_category_icon() {
        try {
            if (category_icon_holder == null) return;
            // Remove existing children
            Gtk.Widget? child = category_icon_holder.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                category_icon_holder.remove(child);
                child = next;
            }
            var hdr = create_category_header_icon(prefs.category, 36);
            if (hdr != null) category_icon_holder.append(hdr);
        } catch (GLib.Error e) { }
    }

    // Create a header-ready category icon using the bundled 128x128 assets
    // when available. This prefers the symbolic/128x128 folder and will
    // pick a "-white" variant in dark mode if present. The returned widget
    // is a Gtk.Image with a paintable texture scaled to `size` pixels.
    private Gtk.Widget? create_category_header_icon(string cat, int size) {
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
            // Prefer the bundled 128x128 symbolic assets
            string[] candidates = {
                GLib.Path.build_filename("icons", "symbolic", "128x128", filename),
                GLib.Path.build_filename("icons", "128x128", filename),
                GLib.Path.build_filename("icons", filename)
            };
            string? icon_path = null;
            foreach (var c in candidates) {
                icon_path = find_data_file(c);
                if (icon_path != null) break;
            }

            if (icon_path != null) {
                try {
                    // Prefer white variant in dark mode if available
                    string use_path = icon_path;
                    if (is_dark_mode()) {
                        string alt_name;
                        if (filename.has_suffix(".svg"))
                            alt_name = filename.substring(0, filename.length - 4) + "-white.svg";
                        else
                            alt_name = filename + "-white.svg";
                        string? white_candidate = null;
                        white_candidate = find_data_file(GLib.Path.build_filename("icons", "symbolic", "128x128", alt_name));
                        if (white_candidate == null) white_candidate = find_data_file(GLib.Path.build_filename("icons", "128x128", alt_name));
                        if (white_candidate != null) use_path = white_candidate;
                    }
                    // If the asset is an SVG, prefer loading it as a file-backed
                    // Gtk.Image and let GTK render it as a vector at the
                    // requested pixel size. This avoids rasterizing the SVG to
                    // a small pixbuf and then letting the layout scale it which
                    // causes blurriness (especially on HiDPI displays).
                    if (use_path.has_suffix(".svg")) {
                        try {
                            var img = new Gtk.Image.from_file(use_path);
                            img.set_pixel_size(size);
                            return img;
                        } catch (GLib.Error e) {
                            // Fall back to pixbuf path below on error
                        }
                    }

                    // Non-SVG assets (PNG, etc): load a scaled pixbuf and convert
                    // to a texture so we get reasonable performance and layout.
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
        // Fall back to the existing create_category_icon behavior
        return create_category_icon(cat);
    }

    // Public helper to update personalized-feed UI state -- shows or hides
    // the centered message overlay depending on the preference.
    public void update_personalization_ui() {
        if (personalized_message_box == null) return;
        var prefs = NewsPreferences.get_instance();
        bool enabled = prefs.personalized_feed_enabled;
        bool is_myfeed = prefs.category == "myfeed";
        // Determine if the user has chosen any personalized categories
        bool has_personalized = prefs.personalized_categories != null && prefs.personalized_categories.size > 0;

        // We show a centered overlay in two cases when the user has selected
        // the "My Feed" category:
        //  1) Personalization is disabled: instruct how to enable it.
        //  2) Personalization is enabled but no categories were chosen: instruct
        //     the user to open preferences and pick categories (provide a button).
        bool show_message = false;
        try {
            if (is_myfeed) {
                if (!enabled) {
                    // Prompt to enable personalization (main line + smaller hint beneath)
                    if (personalized_message_label != null) personalized_message_label.set_text("Enable this option in settings to get a personalized feed.");
                    if (personalized_message_sub_label != null) {
                        personalized_message_sub_label.set_text("Open the main menu (☰) and choose 'Preferences' → 'Set Source Options' and toggle 'Enable Personalized Feed'");
                        personalized_message_sub_label.set_visible(true);
                    }
                    // Show the action button so users can jump straight to prefs
                    if (personalized_message_action != null) personalized_message_action.set_visible(true);
                    show_message = true;
                } else if (enabled && !has_personalized) {
                    // Personalization enabled but no categories selected: provide a smaller hint line beneath
                    if (personalized_message_label != null) personalized_message_label.set_text("Personalized Feed is enabled but no categories are selected.");
                    if (personalized_message_sub_label != null) {
                        personalized_message_sub_label.set_text("Open Preferences → Personalized Feed and choose categories to enable My Feed.");
                        personalized_message_sub_label.set_visible(true);
                    }
                    if (personalized_message_action != null) personalized_message_action.set_visible(true);
                    show_message = true;
                } else {
                    // Personalization enabled and categories selected -> show content
                    show_message = false;
                }
            } else {
                // For non-MyFeed categories, never show the personalized overlay
                show_message = false;
            }

            personalized_message_box.set_visible(show_message);

            // Only reveal the main content when not in the initial loading
            // phase. During initial_phase the global loading spinner controls
            // visibility so overlay helpers must not unhide the main view.
            if (!initial_phase && main_content_container != null) {
                main_content_container.set_visible(!show_message);
            }
        } catch (GLib.Error e) { }

        // If the message is visible, hide the loading spinner; otherwise
        // leave the spinner state alone (it may be controlled by fetch logic).
        try {
            if (loading_container != null && show_message) {
                loading_container.set_visible(false);
            }
        } catch (GLib.Error e) { }

        // Ensure the secondary hint label is hidden when the overlay is not shown
        try {
            if (personalized_message_sub_label != null && !show_message) personalized_message_sub_label.set_visible(false);
        } catch (GLib.Error e) { }

        // Also update local-news guidance overlay state in case the user
        // selected the Local News row. This keeps all overlay visibility
        // logic centralized.
        try { update_local_news_ui(); } catch (GLib.Error e) { }
    }

    // Show or hide the Local News guidance overlay depending on whether
    // the user has configured a location and whether Local News is active.
    public void update_local_news_ui() {
        if (local_news_message_box == null || main_content_container == null) return;
        var prefs = NewsPreferences.get_instance();
        bool needs_location = false;
        try {
            bool is_local = prefs.category == "local_news";
            bool has_location = prefs.user_location != null && prefs.user_location.length > 0;
            needs_location = is_local && !has_location;
        } catch (GLib.Error e) { needs_location = false; }

    try { local_news_message_box.set_visible(needs_location); } catch (GLib.Error e) { }
    // Respect the initial loading phase: overlays should not reveal the
    // main content while we are waiting for initial images to load.
    try { if (!initial_phase) main_content_container.set_visible(!needs_location); } catch (GLib.Error e) { }
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
            case "frontpage": return "The Frontpage";
            case "all": return "All Categories";
            case "myfeed": return "My Feed";
            case "local_news": return "Local News";
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
        // Fallback: humanize unknown slugs into a readable label
        if (cat == null || cat.length == 0) return "News";
        string s = cat.strip();
        if (s.length == 0) return "News";
        s = s.replace("_", " ").replace("-", " ");
        // Strip leading/trailing non-alphanumeric characters (colons, punctuation)
        int st = 0;
        while (st < s.length) {
            char ch = s[st];
            bool is_alnum = ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9'));
            if (is_alnum) break;
            st++;
        }
        if (st > 0) s = s.substring(st);
        int en = s.length - 1;
        while (en >= 0) {
            char ch = s[en];
            bool is_alnum = ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9'));
            if (is_alnum) break;
            en--;
        }
        if (en < s.length - 1) s = s.substring(0, en + 1);
        // Capitalize words ASCII-safely
        string out = "";
        string[] parts = s.split(" ");
        foreach (var p in parts) {
            if (p.length == 0) continue;
            // ASCII capitalize: upper first char, lower the remainder
            string w = p;
            char c = w[0];
            char up = c;
            if (c >= 'a' && c <= 'z') up = (char)(c - 32);
            string first = "%c".printf(up);
            string rest = w.length > 1 ? w.substring(1).down() : "";
            out += (out.length > 0 ? " " : "") + first + rest;
        }
        if (out.length == 0) return "News";
        return out;
    }

    private Gtk.Widget build_category_chip(string category_id) {
        var chip = new Gtk.Label(category_display_name_for(category_id));
        chip.add_css_class("category-chip");
        chip.set_halign(Gtk.Align.START);
        chip.set_valign(Gtk.Align.START);
        return chip;
    }

    private void add_item(string title, string url, string? thumbnail_url, string category_id, string? source_name) {
        // Ensure we have a sensible per-item source name. If callers didn't
        // provide one, infer from the URL. For Local News items prefer the
        // user-configured city name when available so previews/readers show
        // a meaningful local label.
        string? final_source_name = source_name;
        try {
            var prefs_local = NewsPreferences.get_instance();
            if (final_source_name == null || final_source_name.length == 0) {
                if (category_id == "local_news") {
                    if (prefs_local.user_location_city != null && prefs_local.user_location_city.length > 0)
                        final_source_name = prefs_local.user_location_city;
                    else
                        final_source_name = "Local News";
                } else {
                    NewsSource inferred = infer_source_from_url(url);
                    final_source_name = get_source_name(inferred);
                }
            }
        } catch (GLib.Error e) {
            // Best-effort: leave final_source_name as provided (may be null)
            final_source_name = source_name;
        }

        // Debug helper: print when enabled via env var
        bool debug_enabled() {
            // Use GLib.Environment-compatible accessor for environment variables
            string? e = Environment.get_variable("PAPERBOY_DEBUG");
            return e != null && e.length > 0;
        }

        if (debug_enabled()) {
            warning("add_item called: current_view=%s article_cat=%s title=%s", prefs.category, category_id, title);
        }
        // Persist debug trace to file when enabled so we can inspect logs even
        // if the GUI detaches from the terminal.
        try {
            string? _dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
            if (_dbg != null && _dbg.length > 0) {
                append_debug_log("add_item: view=" + prefs.category + " article_cat=" + category_id + " title=" + title);
            }
        } catch (GLib.Error e) { }
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
        // articles that don't belong to the current view. Treat the special
        // "myfeed" view as a personalized union of categories when the
        // personalized feed is enabled.
        string view_category = prefs.category;
    if (view_category == "myfeed") {
            // If personalization is enabled, accept only articles that match
            // one of the user's personalized categories (if any). If no
            // personalized categories are selected, accept everything so the
            // fallback fetches (which may request a default category) still
            // populate the view.
            if (prefs.personalized_feed_enabled) {
                bool has_personalized = prefs.personalized_categories != null && prefs.personalized_categories.size > 0;
                if (has_personalized) {
                    bool match = false;
                    foreach (var pc in prefs.personalized_categories) if (pc == category_id) { match = true; break; }
                    if (!match) {
                        if (debug_enabled()) warning("Dropping non-personalized article for My Feed: article_cat=%s title=%s", category_id, title);
                        return;
                    }
                }
                // else: no personalized categories selected -> accept all
            } else {
                // Personalized feed not enabled: don't populate My Feed
                if (debug_enabled()) warning("Dropping article because My Feed personalization is disabled: article_cat=%s title=%s", category_id, title);
                return;
            }
        } else {
            // Treat the special 'frontpage' view as an aggregator: accept
            // articles of any category when the user is viewing the frontpage.
            // This allows frontpage fetchers to supply per-article category
            // metadata (for chips) without causing the UI to drop items.
            if (view_category != "all" && view_category != "frontpage" && view_category != category_id) {
                // Drop stale article for a different category
                if (debug_enabled()) warning("Dropping stale article for category %s (view=%s)", category_id, view_category);
                return;
            }
        }

        // Enforce that articles originate from the user's selected sources.
        // For the special aggregated "frontpage" category, do NOT enforce
        // per-source filtering because the backend intentionally returns
        // mixed-source results for the frontpage view.
        // Map the inferred source to the preference id strings and drop any
        // articles that come from sources the user hasn't enabled. This
        // protects against fetchers that may return cross-domain results.
        if (category_id != "frontpage" && prefs.preferred_sources != null && prefs.preferred_sources.size > 0) {
            NewsSource article_src = infer_source_from_url(url);
            string article_src_id = "";
            switch (article_src) {
                case NewsSource.GUARDIAN: article_src_id = "guardian"; break;
                case NewsSource.REDDIT: article_src_id = "reddit"; break;
                case NewsSource.BBC: article_src_id = "bbc"; break;
                case NewsSource.NEW_YORK_TIMES: article_src_id = "nytimes"; break;
                case NewsSource.WALL_STREET_JOURNAL: article_src_id = "wsj"; break;
                case NewsSource.BLOOMBERG: article_src_id = "bloomberg"; break;
                case NewsSource.REUTERS: article_src_id = "reuters"; break;
                case NewsSource.NPR: article_src_id = "npr"; break;
                case NewsSource.FOX: article_src_id = "fox"; break;
                default: article_src_id = ""; break;
            }

            if (article_src_id.length > 0) {
                bool allowed_src = false;
                foreach (var ps in prefs.preferred_sources) {
                    if (ps == article_src_id) { allowed_src = true; break; }
                }
                if (!allowed_src) {
                    if (debug_enabled()) warning("Dropping article from unselected source %s title=%s", article_src_id, title);
                    return;
                }
            }
            // If we couldn't infer a source id, conservatively accept the article.
        }

        // If multiple preferred sources are selected and this article's
        // category is one of Bloomberg's unique categories, only accept
        // articles that actually originate from Bloomberg. This prevents
        // other sources from supplying results into Bloomberg-only rows
        // (e.g., markets, industries).
        if (prefs.preferred_sources != null && prefs.preferred_sources.size > 1) {
            string[] bloomberg_only = { "markets", "industries", "economics", "wealth", "green" };
            bool is_bloomberg_cat = false;
            foreach (var bc in bloomberg_only) if (bc == category_id) { is_bloomberg_cat = true; break; }
            if (is_bloomberg_cat) {
                NewsSource article_src = infer_source_from_url(url);
                if (article_src != NewsSource.BLOOMBERG) {
                    if (debug_enabled()) warning("Dropping non-Bloomberg article for Bloomberg-only category %s title=%s", category_id, title);
                    return;
                }
            }
        }
        
    if (prefs.category == "all") {
            // If the user selected "All Categories" but the EFFECTIVE single
            // source is Bloomberg (i.e. single-source Bloomberg mode), only
            // accept articles whose category is one of Bloomberg's available
            // categories. When in multi-source mode we must NOT apply this
            // restriction because the combined view should show the union
            // of categories from all enabled sources.
            NewsSource eff = effective_news_source();
            if (eff == NewsSource.BLOOMBERG && (prefs.preferred_sources == null || prefs.preferred_sources.size <= 1)) {
                string[] bloomberg_cats = { "markets", "industries", "economics", "wealth", "green", "politics", "technology" };
                bool allowed = false;
                foreach (string bc in bloomberg_cats) {
                    if (bc == category_id) { allowed = true; break; }
                }
                if (!allowed) {
                    // Drop articles from categories Bloomberg doesn't have
                    if (debug_enabled()) {
                        warning("Dropping article for Bloomberg (single-source): view=all source=Bloomberg article_cat=%s title=%s", category_id, title);
                    }
                    return;
                }
            }

        // For "All Categories", add to buffer for later shuffling
            var item = new ArticleItem(title, url, thumbnail_url, category_id, final_source_name);
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
            add_item_immediate_to_column(title, url, thumbnail_url, category_id, -1, null, final_source_name);
        }
    }
    
    // Called when all articles have been fetched for "All Categories" mode
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
            add_item_shuffled(article.title, article.url, article.thumbnail_url, article.category_id, article.source_name);
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
    
    private void add_item_shuffled(string title, string url, string? thumbnail_url, string category_id, string? source_name) {
        // Simple round-robin distribution for shuffled articles  
        int target_col = next_column_index;
        next_column_index = (next_column_index + 1) % columns.length;
        
        // Temporarily override category to force immediate placement
        string saved_category = prefs.category;
        prefs.category = category_id; // Set to non-"all" to skip buffering logic
        add_item_immediate_to_column(title, url, thumbnail_url, category_id, target_col, saved_category, source_name);
        prefs.category = saved_category; // Restore
    }
    
    private void add_item_immediate_to_column(string title, string url, string? thumbnail_url, string category_id, int forced_column = -1, string? original_category = null, string? source_name = null) {
    // Check article limit for "All Categories" mode FIRST
    // Debug: log incoming per-article source_name and URL when debugging is enabled
    try {
        string? _dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
        if (_dbg != null && _dbg.length > 0) {
            string in_src = source_name != null ? source_name : "<null>";
            append_debug_log("add_item_immediate_to_column: incoming_source_name=" + in_src + " url=" + (url != null ? url : "<null>") + " category=" + category_id + " title=" + title);
        }
    } catch (GLib.Error e) { }
        // Use original_category if provided (for when category is temporarily overridden)
        string check_category = original_category ?? prefs.category;
        if (check_category == "all" && articles_shown >= INITIAL_ARTICLE_LIMIT && load_more_button == null) {
            show_load_more_button();
            return; // Stop adding articles until user clicks "Load More"
        }
        
    // Smart column selection for "All Categories" to prevent category clustering
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
        
    // For "All Categories", randomly select hero from first few items (not always the first)
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
            // Build a HeroCard UI (presentation only) and keep image-loading
            // and metadata mapping in NewsWindow.
            int max_hero_height = 350;
            int default_hero_w = estimate_content_width();
            int default_hero_h = 250;

            string hero_display_cat = category_id;
            try {
                if (hero_display_cat == "frontpage" && source_name != null) {
                    int idx = source_name.index_of("##category::");
                    if (idx >= 0) hero_display_cat = source_name.substring(idx + 11).strip();
                }
            } catch (GLib.Error e) { }

            var hero_chip = build_category_chip(hero_display_cat);
            var hero_card = new HeroCard(title, url, max_hero_height, default_hero_h, hero_chip);

            bool hero_will_load = thumbnail_url != null && thumbnail_url.length > 0 &&
                (thumbnail_url.has_prefix("http://") || thumbnail_url.has_prefix("https://"));

            if (!hero_will_load) {
                if (category_id == "local_news")
                    set_local_placeholder_image(hero_card.image, default_hero_w, default_hero_h);
                else
                    set_placeholder_image_for_source(hero_card.image, default_hero_w, default_hero_h, resolve_source(source_name, url));
            }

            if (hero_will_load) {
                int multiplier = (prefs.news_source == NewsSource.REDDIT) ? (initial_phase ? 2 : 2) : (initial_phase ? 1 : 4);
                if (initial_phase) pending_images++;
                load_image_async(hero_card.image, thumbnail_url, default_hero_w * multiplier, default_hero_h * multiplier);
                hero_requests.set(hero_card.image, new HeroRequest(thumbnail_url, default_hero_w * multiplier, default_hero_h * multiplier, multiplier));
                string _norm = normalize_article_url(url);
                url_to_picture.set(_norm, hero_card.image);
                normalized_to_url.set(_norm, url);
                url_to_card.set(_norm, hero_card.root);
                try { append_debug_log("url_to_card.set: hero mapping url=" + _norm + " widget=hero"); } catch (GLib.Error e) { }
                try {
                    if (meta_cache != null) {
                        bool was = false;
                        try { was = meta_cache.is_viewed(_norm); } catch (GLib.Error e) { was = false; }
                        try { append_debug_log("meta_check: hero url=" + _norm + " was=" + (was ? "true" : "false")); } catch (GLib.Error e) { }
                        if (was) { try { mark_article_viewed(_norm); } catch (GLib.Error e) { } }
                    }
                } catch (GLib.Error e) { }
                Timeout.add(300, () => { var info = hero_requests.get(hero_card.image); if (info != null) maybe_refetch_hero_for(hero_card.image, info); return false; });
            }

            // Connect activation to the preview handler
            hero_card.activated.connect((s) => { try { article_window.show_article_preview(title, url, thumbnail_url, category_id); } catch (GLib.Error e) { } });

            // Add the hero as the first slide and initialize the carousel containers
            var top_stories_title = new Gtk.Label("Top Stories");
            top_stories_title.set_xalign(0);
            top_stories_title.add_css_class("top-stories-title");
            top_stories_title.set_margin_bottom(6);
            featured_box.append(top_stories_title);

            if (featured_carousel_items == null) featured_carousel_items = new Gee.ArrayList<ArticleItem>();
            if (featured_carousel_widgets == null) featured_carousel_widgets = new Gee.ArrayList<Gtk.Widget>();
            featured_carousel_items.add(new ArticleItem(title, url, thumbnail_url, category_id, source_name));
            featured_carousel_category = category_id;

            // Create a stack to hold up to 5 slides
            featured_carousel_stack = new Gtk.Stack();
            featured_carousel_stack.set_transition_type(Gtk.StackTransitionType.SLIDE_LEFT_RIGHT);
            featured_carousel_stack.set_halign(Gtk.Align.FILL);
            featured_carousel_stack.set_hexpand(true);

            featured_carousel_stack.add_named(hero_card.root, "0");
            featured_carousel_widgets.add(hero_card.root);

            var carousel_container = new Gtk.Box(Orientation.VERTICAL, 0);
            carousel_container.add_css_class("card");
            carousel_container.add_css_class("card-featured");
            carousel_container.set_halign(Gtk.Align.FILL);
            carousel_container.set_hexpand(true);

            var carousel_overlay = new Gtk.Overlay();
            carousel_overlay.set_child(featured_carousel_stack);

            var left_btn = new Gtk.Button.from_icon_name("go-previous-symbolic");
            left_btn.add_css_class("carousel-nav");
            left_btn.add_css_class("carousel-nav-left");
            left_btn.set_halign(Gtk.Align.START);
            left_btn.set_valign(Gtk.Align.CENTER);
            left_btn.set_margin_start(8);
            left_btn.set_margin_end(8);
            carousel_overlay.add_overlay(left_btn);
            left_btn.clicked.connect(() => { carousel_prev(); });

            var right_btn = new Gtk.Button.from_icon_name("go-next-symbolic");
            right_btn.add_css_class("carousel-nav");
            right_btn.add_css_class("carousel-nav-right");
            right_btn.set_halign(Gtk.Align.END);
            right_btn.set_valign(Gtk.Align.CENTER);
            right_btn.set_margin_start(8);
            right_btn.set_margin_end(8);
            carousel_overlay.add_overlay(right_btn);
            right_btn.clicked.connect(() => { carousel_next(); });

            carousel_container.append(carousel_overlay);

            var global_dots = new Gtk.Box(Orientation.HORIZONTAL, 6);
            global_dots.set_halign(Gtk.Align.CENTER);
            global_dots.set_margin_top(6);
            if (featured_carousel_dot_widgets == null) featured_carousel_dot_widgets = new Gee.ArrayList<Gtk.Label>();
            for (int d = 0; d < 5; d++) {
                var dot = new Gtk.Label("•");
                dot.add_css_class("carousel-dot");
                if (d == 0) dot.add_css_class("active");
                dot.set_valign(Gtk.Align.CENTER);
                var dot_attrs = new Pango.AttrList();
                dot_attrs.insert(Pango.attr_scale_new(1.35));
                dot.set_attributes(dot_attrs);
                global_dots.append(dot);
                featured_carousel_dot_widgets.add(dot);
            }
            featured_carousel_dots_box = global_dots;
            carousel_container.append(global_dots);
            featured_box.append(carousel_container);

            featured_carousel_index = 0;
            if (featured_carousel_timeout_id != 0) { Source.remove(featured_carousel_timeout_id); featured_carousel_timeout_id = 0; }
            featured_carousel_timeout_id = Timeout.add_seconds(5, () => {
                if (featured_carousel_stack == null) return false;
                int total = featured_carousel_widgets != null ? featured_carousel_widgets.size : 0;
                if (total <= 1) return true;
                featured_carousel_index = (featured_carousel_index + 1) % total;
                for (int i = 0; i < total; i++) {
                    var child = featured_carousel_widgets.get(featured_carousel_index) as Gtk.Widget;
                    if (child != null && child.get_parent() == featured_carousel_stack) {
                        featured_carousel_stack.set_visible_child(child);
                        update_carousel_dots(featured_carousel_index);
                        return true;
                    }
                    featured_carousel_index = (featured_carousel_index + 1) % total;
                }
                append_debug_log("carousel_timer: no valid child found for stack");
                return true;
            });

            featured_used = true;
            if (initial_phase) mark_initial_items_populated();
            return;
        }

        // If a featured carousel is active and we haven't reached 5 slides yet,
        // collect additional articles that match the featured category and add
        // them as slides to the carousel instead of rendering normal cards.
            if (featured_carousel_stack != null && featured_carousel_items != null &&
            featured_carousel_items.size < 5) {
            // In "all" mode we only append slides that match the featured
            // category (the carousel is seeded with a category). For
            // specific-category views, prefer using the current view
            // (`prefs.category`) as the authority since some fetchers may
            // return slightly different category ids. This makes the
            // carousel robust for non-"all" categories while preserving
            // current behaviour for the mixed "all" view.
            bool allow_slide = false;
            if (prefs.category == "all") {
                // In "all" mode, only append slides that match the seeded featured category
                allow_slide = (featured_carousel_category != null && featured_carousel_category == category_id);
            } else if (prefs.category == "myfeed" && prefs.personalized_feed_enabled) {
                // In My Feed personalization mode, allow slides that either match the
                // featured category or belong to one of the user's personalized categories.
                if (featured_carousel_category != null && featured_carousel_category == category_id) {
                    allow_slide = true;
                } else {
                    bool has_personalized = prefs.personalized_categories != null && prefs.personalized_categories.size > 0;
                    if (!has_personalized) {
                        // No personalized categories selected -> accept any category
                        allow_slide = true;
                    } else {
                        foreach (var pc in prefs.personalized_categories) {
                            if (pc == category_id) { allow_slide = true; break; }
                        }
                    }
                }
            } else {
                // For specific single-category views, only allow slides that match the view
                allow_slide = (category_id == prefs.category);
            }
            if (!allow_slide) {
                return;
            }

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
            string slide_display_cat = category_id;
            try {
                if (slide_display_cat == "frontpage" && source_name != null) {
                    int idx2 = source_name.index_of("##category::");
                    if (idx2 >= 0) slide_display_cat = source_name.substring(idx2 + 11).strip();
                }
            } catch (GLib.Error e) { }
            var slide_chip = build_category_chip(slide_display_cat);
            slide_overlay.add_overlay(slide_chip);
            // No source badge on carousel slides to keep the hero area clean

            int default_w = estimate_content_width();
            int default_h = 250;
            bool slide_will_load = thumbnail_url != null && thumbnail_url.length > 0 &&
                (thumbnail_url.has_prefix("http://") || thumbnail_url.has_prefix("https://"));
            if (!slide_will_load) {
                if (category_id == "local_news") {
                    set_local_placeholder_image(slide_image, default_w, default_h);
                } else {
                    set_placeholder_image_for_source(slide_image, default_w, default_h, resolve_source(source_name, url));
                }
            }
            if (slide_will_load) {
                int multiplier = (prefs.news_source == NewsSource.REDDIT) ? (initial_phase ? 2 : 2) : (initial_phase ? 1 : 4);
                if (initial_phase) pending_images++;
                load_image_async(slide_image, thumbnail_url, default_w * multiplier, default_h * multiplier);
                hero_requests.set(slide_image, new HeroRequest(thumbnail_url, default_w * multiplier, default_h * multiplier, multiplier));
                string _norm = normalize_article_url(url);
                url_to_picture.set(_norm, slide_image);
                normalized_to_url.set(_norm, url);
                // Map slide to URL for viewed badge support
                url_to_card.set(_norm, slide);
                try { append_debug_log("url_to_card.set: slide mapping url=" + _norm + " widget=slide"); } catch (GLib.Error e) { }
                try {
                    if (meta_cache != null) {
                        bool was = false;
                        try { was = meta_cache.is_viewed(_norm); } catch (GLib.Error e) { was = false; }
                        try { append_debug_log("meta_check: slide url=" + _norm + " was=" + (was ? "true" : "false")); } catch (GLib.Error e) { }
                        if (was) { try { mark_article_viewed(_norm); } catch (GLib.Error e) { } }
                    }
                } catch (GLib.Error e) { }
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
                article_window.show_article_preview(title, url, thumbnail_url, category_id);
            });
            slide.add_controller(slide_click);

            // Add slide to stack and to our item list
            int new_index = featured_carousel_items.size;
            featured_carousel_stack.add_named(slide, "%d".printf(new_index));
            featured_carousel_widgets.add(slide);
            featured_carousel_items.add(new ArticleItem(title, url, thumbnail_url, category_id, source_name));

            // Debug: log slide addition when debug env var is set (also write to file)
            try {
                string? _dbg2 = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                if (_dbg2 != null && _dbg2.length > 0) {
                    print("DEBUG: added slide idx=%d category=%s title=%s\n", new_index, category_id, title);
                    append_debug_log("slide_added: idx=" + new_index.to_string() + " category=" + category_id + " title=" + title);
                }
            } catch (GLib.Error e) { }

            // Ensure dots array exists and update their state
            if (featured_carousel_dot_widgets != null) update_carousel_dots(featured_carousel_index);

            return;
        }

        // Build an ArticleCard UI-only widget and let the window orchestrate
        // image loading, badges and metadata mappings. Compute the variant,
        // column width and image height the same way as before so visuals
        // remain unchanged.
        int variant = rng.int_range(0, 3);
        int col_w = estimate_column_width(columns_count);
        int img_w = col_w;
        int img_h = 0;
        switch (variant) {
            case 0:
                img_h = (int)(col_w * 0.42);
                if (img_h < 80) img_h = 80;
                break;
            case 1:
                img_h = (int)(col_w * 0.5);
                if (img_h < 100) img_h = 100;
                break;
            default:
                img_h = (int)(col_w * 0.58);
                if (img_h < 120) img_h = 120;
                break;
        }

        // Compute the display category chip (frontpage may embed a token)
        string card_display_cat = category_id;
        try {
            if (card_display_cat == "frontpage" && source_name != null) {
                int idx3 = source_name.index_of("##category::");
                if (idx3 >= 0) card_display_cat = source_name.substring(idx3 + 11).strip();
            }
        } catch (GLib.Error e) { }

        var chip = build_category_chip(card_display_cat);

        // Instantiate the ArticleCard UI (presentation only)
        var article_card = new ArticleCard(title, url, col_w, img_h, chip, variant);

        // Allow caller to add a dynamic source badge overlay (skip for local_news)
        if (category_id != "local_news") {
            var card_badge = build_source_badge_dynamic(source_name, url, category_id);
            try { article_card.overlay.add_overlay(card_badge); } catch (GLib.Error e) { }
        }

        // Decide whether we'll load an image and, if not, let the caller set placeholders
        bool card_will_load = thumbnail_url != null && thumbnail_url.length > 0 &&
            (thumbnail_url.has_prefix("http://") || thumbnail_url.has_prefix("https://"));

        string _norm = normalize_article_url(url);

        if (card_will_load) {
            int multiplier = (prefs.news_source == NewsSource.REDDIT) ? (initial_phase ? 2 : 2) : (initial_phase ? 1 : 3);
            if (initial_phase) pending_images++;
            // Caller retains image-load logic; register picture for in-place updates
            load_image_async(article_card.image, thumbnail_url, img_w * multiplier, img_h * multiplier);
            url_to_picture.set(_norm, article_card.image);
            normalized_to_url.set(_norm, url);
        } else {
            if (category_id == "local_news") {
                set_local_placeholder_image(article_card.image, img_w, img_h);
            } else {
                set_placeholder_image_for_source(article_card.image, img_w, img_h, resolve_source(source_name, url));
            }
        }

        // Map normalized URL -> card widget for overlays/badges and viewed state
        try { url_to_card.set(_norm, article_card.root); } catch (GLib.Error e) { }
        try { append_debug_log("url_to_card.set: card mapping url=" + _norm + " widget=card"); } catch (GLib.Error e) { }
        try {
            if (meta_cache != null) {
                bool was = false;
                try { was = meta_cache.is_viewed(_norm); } catch (GLib.Error e) { was = false; }
                try { append_debug_log("meta_check: card url=" + _norm + " was=" + (was ? "true" : "false")); } catch (GLib.Error e) { }
                if (was) { try { mark_article_viewed(_norm); } catch (GLib.Error e) { } }
            }
        } catch (GLib.Error e) { }

        // Connect activation to opening the article preview
        article_card.activated.connect((s) => {
            try { article_window.show_article_preview(title, url, thumbnail_url, category_id); } catch (GLib.Error e) { }
        });

        // Append to the calculated target column
        if (target_col == -1) {
            target_col = 0;
            int random_noise = rng.int_range(0, 11);
            int best_score = column_heights[0] + random_noise;
            for (int i = 1; i < columns.length; i++) {
                random_noise = rng.int_range(0, 11);
                int score = column_heights[i] + random_noise;
                if (score < best_score) { best_score = score; target_col = i; }
            }
        }
        columns[target_col].append(article_card.root);

        string current_category = original_category ?? prefs.category;
        if (current_category == "all") articles_shown++;

        int estimated_card_h = img_h + 120;
        column_heights[target_col] += estimated_card_h + 12;

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

                // If we have a cached ETag/Last-Modified, perform a conditional GET
                if (meta_cache != null) {
                    string? et = null;
                    string? lm = null;
                    meta_cache.get_etag_and_modified(url, out et, out lm);
                    if (et != null) msg.request_headers.append("If-None-Match", et);
                    if (lm != null) msg.request_headers.append("If-Modified-Since", lm);
                }

                append_debug_log("start_image_download_for_url: sending request url=" + url + " size=" + target_w.to_string() + "x" + target_h.to_string());
                session.send_message(msg);
                append_debug_log("start_image_download_for_url: got response status=" + msg.status_code.to_string() + " body_len=" + msg.response_body.length.to_string() + " url=" + url);

                if (prefs.news_source == NewsSource.REDDIT && msg.response_body.length > 2 * 1024 * 1024) {
                    Idle.add(() => {
                        set_placeholder_image_for_source(image, target_w, target_h, infer_source_from_url(url));
                        on_image_loaded(image);
                        return false;
                    });
                    return null;
                }

                if (msg.status_code == 200 && msg.response_body.length > 0) {
                    // Decode and scale the image off the main thread to avoid
                    // blocking the UI. We then hand a ready Gdk.Pixbuf to the
                    // main loop to create a Gdk.Texture and update widgets.
                    try {
                        var loader = new Gdk.PixbufLoader();
                        uint8[] data = new uint8[msg.response_body.length];
                        Memory.copy(data, msg.response_body.data, (size_t)msg.response_body.length);
                        loader.write(data);
                        loader.close();
                        var pixbuf = loader.get_pixbuf();
                        if (pixbuf != null) {
                            int width = pixbuf.get_width();
                            int height = pixbuf.get_height();
                            double scale = double.min((double) target_w / width, (double) target_h / height);
                            if (scale < 1.0) {
                                int new_width = (int)(width * scale);
                                if (new_width < 1) new_width = 1;
                                int new_height = (int)(height * scale);
                                if (new_height < 1) new_height = 1;
                                // Always scale down to the requested target (even for small badges)
                                pixbuf = pixbuf.scale_simple(new_width, new_height, Gdk.InterpType.HYPER);
                            } else if (scale > 1.0) {
                                double max_upscale = 2.0;
                                double upscale = double.min(scale, max_upscale);
                                int new_width = (int)(width * upscale);
                                int new_height = (int)(height * upscale);
                                if (upscale > 1.01) {
                                    pixbuf = pixbuf.scale_simple(new_width, new_height, Gdk.InterpType.HYPER);
                                }
                            }
                            // Create texture and update UI on the main thread only
                            var pb_for_idle = pixbuf;
                            Idle.add(() => {
                                try {
                                    var texture = Gdk.Texture.for_pixbuf(pb_for_idle);
                                    image.set_paintable(texture);
                                    on_image_loaded(image);
                                } catch (GLib.Error e) {
                                    set_placeholder_image_for_source(image, target_w, target_h, infer_source_from_url(url));
                                    on_image_loaded(image);
                                }
                                return false;
                            });
                        } else {
                            Idle.add(() => {
                                set_placeholder_image_for_source(image, target_w, target_h, infer_source_from_url(url));
                                on_image_loaded(image);
                                return false;
                            });
                        }
                    } catch (GLib.Error e) {
                        Idle.add(() => {
                            set_placeholder_image_for_source(image, target_w, target_h, infer_source_from_url(url));
                            on_image_loaded(image);
                            return false;
                        });
                    }
                } else {
                    Idle.add(() => {
                        set_placeholder_image_for_source(image, target_w, target_h, infer_source_from_url(url));
                        on_image_loaded(image);
                        return false;
                    });
                }
            } catch (GLib.Error e) {
                Idle.add(() => {
                        set_placeholder_image_for_source(image, target_w, target_h, infer_source_from_url(url));
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
    
    // Start a single download for a URL and update all registered targets when done.
    private void start_image_download_for_url(string url, int target_w, int target_h) {
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
                        var list = pending_downloads.get(url);
                        if (list != null) {
                            foreach (var pic in list) {
                                set_placeholder_image_for_source(pic, target_w, target_h, infer_source_from_url(url));
                                on_image_loaded(pic);
                            }
                            pending_downloads.remove(url);
                        }
                        return false;
                    });
                    return null;
                }

                if (msg.status_code == 304) {
                    append_debug_log("start_image_download_for_url: 304 Not Modified for url=" + url);
                    // Not modified; refresh last-access and serve cached image
                    Idle.add(() => {
                        if (meta_cache != null) meta_cache.touch(url);
                        var path = meta_cache != null ? meta_cache.get_cached_path(url) : null;
                        if (path != null) {
                            append_debug_log("start_image_download_for_url: serving disk-cached path=" + path + " for url=" + url);
                            try {
                                Gdk.Texture? texture = null;
                                var pix = new Gdk.Pixbuf.from_file(path);

                                // Determine device/widget scale by inspecting all pending targets
                                // and picking the largest scale factor. This avoids using a
                                // single possibly-unrealized widget and ensures we rasterize
                                // to enough device pixels for any attached targets.
                                int device_scale = 1;
                                try {
                                    var list_try = pending_downloads.get(url);
                                    if (list_try != null && list_try.size > 0) {
                                        foreach (var pic_obj in list_try) {
                                            try {
                                                var pic = (Gtk.Picture) pic_obj;
                                                int s = pic.get_scale_factor();
                                                if (s > device_scale) device_scale = s;
                                            } catch (GLib.Error e) {
                                                // ignore and continue
                                            }
                                        }
                                        if (device_scale < 1) device_scale = 1;
                                    }
                                } catch (GLib.Error e) { device_scale = 1; }

                                // If we know the requested size for this URL, scale to the
                                // effective (device) target so cached textures match callers
                                // and look crisp on HiDPI displays.
                                var size_rec = requested_image_sizes.get(url);
                                if (pix != null && size_rec != null && size_rec.length > 0) {
                                    try {
                                        string[] parts = size_rec.split("x");
                                        if (parts.length == 2) {
                                            int sw = int.parse(parts[0]);
                                            int sh = int.parse(parts[1]);
                                            int eff_sw = sw * device_scale;
                                            int eff_sh = sh * device_scale;
                                            try { append_debug_log("start_image_download_for_url: 304 serving url=" + url + " requested=" + sw.to_string() + "x" + sh.to_string() + " device_scale=" + device_scale.to_string() + " eff_target=" + eff_sw.to_string() + "x" + eff_sh.to_string() + " pix_before=" + pix.get_width().to_string() + "x" + pix.get_height().to_string()); } catch (GLib.Error e) { }
                                            double sc = double.min((double) eff_sw / pix.get_width(), (double) eff_sh / pix.get_height());
                                            if (sc < 1.0) {
                                                int nw = (int)(pix.get_width() * sc);
                                                if (nw < 1) nw = 1;
                                                int nh = (int)(pix.get_height() * sc);
                                                if (nh < 1) nh = 1;
                                                try { pix = pix.scale_simple(nw, nh, Gdk.InterpType.HYPER); } catch (GLib.Error e) { }
                                            }
                                            texture = Gdk.Texture.for_pixbuf(pix);
                                            string k = make_cache_key(url, sw, sh);
                                            memory_meta_cache.set(k, texture);
                                            // Only set a URL-keyed fallback for small targets
                                            if (sw <= 64 && sh <= 64) memory_meta_cache.set(url, texture);
                                            try { append_debug_log("start_image_download_for_url: 304 cached size_key=" + k + " pix_after=" + pix.get_width().to_string() + "x" + pix.get_height().to_string()); } catch (GLib.Error e) { }
                                        } else {
                                            texture = Gdk.Texture.for_pixbuf(pix);
                                            if (pix.get_width() <= 64 && pix.get_height() <= 64) memory_meta_cache.set(url, texture);
                                        }
                                    } catch (GLib.Error e) {
                                        texture = Gdk.Texture.for_pixbuf(pix);
                                        if (pix.get_width() <= 64 && pix.get_height() <= 64) memory_meta_cache.set(url, texture);
                                    }
                                } else if (pix != null) {
                                    texture = Gdk.Texture.for_pixbuf(pix);
                                    if (pix.get_width() <= 64 && pix.get_height() <= 64) memory_meta_cache.set(url, texture);
                                }
                                var list2 = pending_downloads.get(url);
                                if (list2 != null) {
                                    foreach (var pic in list2) {
                                        if (texture != null) pic.set_paintable(texture);
                                        else set_placeholder_image_for_source(pic, target_w, target_h, infer_source_from_url(url));
                                        on_image_loaded(pic);
                                    }
                                    pending_downloads.remove(url);
                                }
                            } catch (GLib.Error e) {
                                var list2 = pending_downloads.get(url);
                                if (list2 != null) {
                                    foreach (var pic in list2) { set_placeholder_image_for_source(pic, target_w, target_h, infer_source_from_url(url)); on_image_loaded(pic); }
                                    pending_downloads.remove(url);
                                }
                            }
                        } else {
                            var list2 = pending_downloads.get(url);
                            if (list2 != null) {
                                foreach (var pic in list2) { set_placeholder_image_for_source(pic, target_w, target_h, infer_source_from_url(url)); on_image_loaded(pic); }
                                pending_downloads.remove(url);
                            }
                        }
                        return false;
                    });
                    return null;
                }

                if (msg.status_code == 200 && msg.response_body.length > 0) {
                    // Perform disk cache write and pixbuf decoding/scaling off the
                    // main thread, then update the UI with a lightweight idle.
                    try {
                        uint8[] data = new uint8[msg.response_body.length];
                        Memory.copy(data, msg.response_body.data, (size_t)msg.response_body.length);

                        // Persist to disk cache (best-effort) using ETag/Last-Modified headers
                        if (meta_cache != null) {
                            string? etg = null;
                            string? lm2 = null;
                            try { etg = msg.response_headers.get_one("ETag"); } catch (GLib.Error e) { etg = null; }
                            try { lm2 = msg.response_headers.get_one("Last-Modified"); } catch (GLib.Error e) { lm2 = null; }
                            try {
                                string? ct = null;
                                try { ct = msg.response_headers.get_one("Content-Type"); } catch (GLib.Error e) { ct = null; }
                                meta_cache.write_cache(url, data, etg, lm2, ct);
                                append_debug_log("start_image_download_for_url: wrote disk cache for url=" + url + " etag=" + (etg != null ? etg : "<null>"));
                            } catch (GLib.Error e) { }
                        }

                        var loader = new Gdk.PixbufLoader();
                        loader.write(data);
                        loader.close();
                        var pixbuf = loader.get_pixbuf();
                        if (pixbuf != null) {
                            int width = pixbuf.get_width();
                            int height = pixbuf.get_height();
                            try { append_debug_log("start_image_download_for_url: decoded url=" + url + " orig=" + width.to_string() + "x" + height.to_string() + " requested=" + target_w.to_string() + "x" + target_h.to_string()); } catch (GLib.Error e) { }
                            double scale = double.min((double) target_w / width, (double) target_h / height);
                            if (scale < 1.0) {
                                int new_width = (int)(width * scale);
                                if (new_width < 1) new_width = 1;
                                int new_height = (int)(height * scale);
                                if (new_height < 1) new_height = 1;
                                // Always scale down to the requested target so badges/layouts receive
                                // appropriately-sized textures (allow small targets like 20x20).
                                try { pixbuf = pixbuf.scale_simple(new_width, new_height, Gdk.InterpType.HYPER); } catch (GLib.Error e) { }
                                try { append_debug_log("start_image_download_for_url: scaled-down url=" + url + " to=" + pixbuf.get_width().to_string() + "x" + pixbuf.get_height().to_string()); } catch (GLib.Error e) { }
                            } else if (scale > 1.0) {
                                double max_upscale = 2.0;
                                double upscale = double.min(scale, max_upscale);
                                int new_width = (int)(width * upscale);
                                int new_height = (int)(height * upscale);
                                if (upscale > 1.01) {
                                    try { pixbuf = pixbuf.scale_simple(new_width, new_height, Gdk.InterpType.HYPER); } catch (GLib.Error e) { }
                                    try { append_debug_log("start_image_download_for_url: upscaled url=" + url + " to=" + pixbuf.get_width().to_string() + "x" + pixbuf.get_height().to_string()); } catch (GLib.Error e) { }
                                }
                            }

                            var pb_for_idle = pixbuf;
                            Idle.add(() => {
                                try {
                                    var texture = Gdk.Texture.for_pixbuf(pb_for_idle);
                                    // Cache texture in-memory for the session using size-key
                                    string size_key = make_cache_key(url, target_w, target_h);
                                    memory_meta_cache.set(size_key, texture);
                                    try { append_debug_log("start_image_download_for_url: cached memory size_key=" + size_key + " url=" + url + " tex_size=" + pb_for_idle.get_width().to_string() + "x" + pb_for_idle.get_height().to_string()); } catch (GLib.Error e) { }

                                    var list = pending_downloads.get(url);
                                    if (list != null) {
                                        foreach (var pic in list) {
                                            pic.set_paintable(texture);
                                            on_image_loaded(pic);
                                        }
                                        pending_downloads.remove(url);
                                    }
                                } catch (GLib.Error e) {
                                    var list = pending_downloads.get(url);
                                    if (list != null) {
                                        foreach (var pic in list) {
                                            set_placeholder_image_for_source(pic, target_w, target_h, infer_source_from_url(url));
                                            on_image_loaded(pic);
                                        }
                                        pending_downloads.remove(url);
                                    }
                                }
                                return false;
                            });
                        } else {
                            Idle.add(() => {
                                var list = pending_downloads.get(url);
                                if (list != null) {
                                    foreach (var pic in list) {
                                        set_placeholder_image_for_source(pic, target_w, target_h, infer_source_from_url(url));
                                        on_image_loaded(pic);
                                    }
                                    pending_downloads.remove(url);
                                }
                                return false;
                            });
                        }
                    } catch (GLib.Error e) {
                        Idle.add(() => {
                            var list = pending_downloads.get(url);
                            if (list != null) {
                                foreach (var pic in list) {
                                    set_placeholder_image_for_source(pic, target_w, target_h, infer_source_from_url(url));
                                    on_image_loaded(pic);
                                }
                                pending_downloads.remove(url);
                            }
                            return false;
                        });
                    }
                } else {
                    Idle.add(() => {
                        var list = pending_downloads.get(url);
                        if (list != null) {
                            foreach (var pic in list) {
                                    set_placeholder_image_for_source(pic, target_w, target_h, infer_source_from_url(url));
                                on_image_loaded(pic);
                            }
                            pending_downloads.remove(url);
                        }
                        return false;
                    });
                }
            } catch (GLib.Error e) {
                Idle.add(() => {
                    var list = pending_downloads.get(url);
                    if (list != null) {
                        foreach (var pic in list) {
                            set_placeholder_image_for_source(pic, target_w, target_h, infer_source_from_url(url));
                            on_image_loaded(pic);
                        }
                        pending_downloads.remove(url);
                    }
                    return false;
                });
            } finally {
                // Decrement active downloads counter
                GLib.AtomicInt.dec_and_test(ref active_downloads);
            }
            return null;
        });
    }

    // Ensure we don't start more than MAX_CONCURRENT_DOWNLOADS downloads; if we are at capacity,
    // retry shortly until a slot frees up.
    private void ensure_start_download(string url, int target_w, int target_h) {
        // Use a lower concurrency cap during the initial loading phase to
        // reduce main-loop work (decodes/Idle callbacks) and keep the UI
        // animation (spinner) smooth. Outside initial_phase we use the
        // normal, higher cap.
        int cap = initial_phase ? INITIAL_PHASE_MAX_CONCURRENT_DOWNLOADS : MAX_CONCURRENT_DOWNLOADS;
        if (active_downloads >= cap) {
            // Retry after a short delay
            Timeout.add(150, () => { ensure_start_download(url, target_w, target_h); return false; });
            return;
        }
        start_image_download_for_url(url, target_w, target_h);
    }

    private void load_image_async(Gtk.Picture image, string url, int target_w, int target_h, bool force = false) {
        // If the widget is not visible yet, defer starting the download to
        // avoid fetching/decoding images for off-screen items. A background
        // timer will process deferred requests when widgets become visible.
        if (!force) {
            try {
                // Prefer the mapped/visible check; fall back to visible when unavailable
                bool vis = false;
                try { vis = image.get_visible(); } catch (GLib.Error e) { vis = true; }
                if (!vis) {
                    // Record requested size so upgrade pass can see it even while deferred
                    requested_image_sizes.set(url, "%dx%d".printf(target_w, target_h));
                    try {
                        string nkey = normalize_article_url(url);
                        if (nkey != null && nkey.length > 0) requested_image_sizes.set(nkey, "%dx%d".printf(target_w, target_h));
                    } catch (GLib.Error e) { }

                    deferred_downloads.set(image, new DeferredRequest(url, target_w, target_h));
                    // Start/ensure a one-shot timer to process deferred requests shortly
                    if (deferred_check_timeout_id == 0) {
                        deferred_check_timeout_id = Timeout.add(500, () => {
                            try { process_deferred_downloads(); } catch (GLib.Error e) { }
                            deferred_check_timeout_id = 0;
                            return false;
                        });
                    }
                    return;
                }
            } catch (GLib.Error e) { /* ignore visibility check errors */ }
        }
    // Fast-path: if we have an in-memory texture for this exact size, use it immediately
        string key = make_cache_key(url, target_w, target_h);
        var cached = memory_meta_cache.get(key);
        if (cached != null) {
            append_debug_log("load_image_async: memory cache hit key=" + key + " url=" + url + " size=" + target_w.to_string() + "x" + target_h.to_string());
            image.set_paintable(cached);
            on_image_loaded(image);
            return;
        }
        // Fallback: avoid using a URL-keyed texture that may have been cached
        // at an earlier, different size. Using a wrong-size cached texture
        // can cause visible blurriness when it's upscaled for larger targets.
        // Keep a small-target fast-path (icons/badges) but otherwise prefer
        // the size-keyed cache, disk cache, or a fresh download.
        var cached_any = memory_meta_cache.get(url);
        if (cached_any != null) {
            // For very small targets (badges/icons) the generic cached texture
            // is acceptable and avoids an extra disk/network round-trip.
            if (target_w <= 64 && target_h <= 64) {
                append_debug_log("load_image_async: memory cache (any-size) hit (small target) url=" + url + " size=" + target_w.to_string() + "x" + target_h.to_string());
                image.set_paintable(cached_any);
                on_image_loaded(image);
                return;
            } else {
                append_debug_log("load_image_async: memory cache (any-size) hit but skipping due to size mismatch url=" + url + " requested=" + target_w.to_string() + "x" + target_h.to_string());
                // Fall through to disk/network path to obtain an appropriately-sized texture
            }
        }

        // Eager disk short-circuit: if we have the image on-disk from a
        // previous run (MetaCache), load it synchronously and populate the
        // size-keyed memory cache so the UI shows logos immediately.
        try {
            if (meta_cache != null) {
                var disk_path = meta_cache.get_cached_path(url);
                if (disk_path != null) {
                    append_debug_log("load_image_async: disk cache hit path=" + disk_path + " url=" + url + " size=" + target_w.to_string() + "x" + target_h.to_string());
                        try {
                            var pix = new Gdk.Pixbuf.from_file(disk_path);
                            if (pix != null) {
                                // Determine widget/device scale so we rasterize to enough
                                // device pixels for HiDPI displays and avoid blurry upscaling.
                                int device_scale = 1;
                                try { device_scale = image.get_scale_factor(); if (device_scale < 1) device_scale = 1; } catch (GLib.Error e) { device_scale = 1; }

                                int eff_target_w = target_w * device_scale;
                                int eff_target_h = target_h * device_scale;

                                // If the on-disk image is larger than the effective target, scale it
                                int width = pix.get_width();
                                int height = pix.get_height();
                                double scale = double.min((double) eff_target_w / width, (double) eff_target_h / height);
                                if (scale < 1.0) {
                                    int new_w = (int)(width * scale);
                                    if (new_w < 1) new_w = 1;
                                    int new_h = (int)(height * scale);
                                    if (new_h < 1) new_h = 1;
                                    try { pix = pix.scale_simple(new_w, new_h, Gdk.InterpType.HYPER); } catch (GLib.Error e) { }
                                }
                                // Debug: record disk-cache serving details
                                try { append_debug_log("load_image_async: disk-cached path=" + disk_path + " url=" + url + " requested=" + target_w.to_string() + "x" + target_h.to_string() + " device_scale=" + device_scale.to_string() + " pix_after=" + pix.get_width().to_string() + "x" + pix.get_height().to_string()); } catch (GLib.Error e) { }
                                // Create a texture and cache it under the size-key (logical size)
                                var tex = Gdk.Texture.for_pixbuf(pix);
                                string size_key = make_cache_key(url, target_w, target_h);
                                memory_meta_cache.set(size_key, tex);
                                // keep URL-keyed fallback only for small icons to avoid
                                // accidental upscaling of low-res textures for larger cards
                                if (target_w <= 64 && target_h <= 64) memory_meta_cache.set(url, tex);
                                image.set_paintable(tex);
                                on_image_loaded(image);
                                try { append_debug_log("load_image_async: disk-cached served url=" + url + " size_key=" + size_key); } catch (GLib.Error e) { }
                                return;
                            }
                        } catch (GLib.Error e) {
                            // Fall through to network fetch on any disk read/decoding error
                        }
                }
            }
        } catch (GLib.Error e) { /* best-effort; continue to network path */ }

        // If a download is already in-flight for this URL, enqueue the widget and return
        var existing = pending_downloads.get(url);
        if (existing != null) {
            append_debug_log("load_image_async: pending download exists, enqueueing url=" + url + " size=" + target_w.to_string() + "x" + target_h.to_string());
            existing.add(image);
            return;
        }

        // Otherwise, create a pending list and start the download (subject to concurrency cap)
        var list = new Gee.ArrayList<Gtk.Picture>();
        list.add(image);
    pending_downloads.set(url, list);
    append_debug_log("load_image_async: queued download url=" + url + " size=" + target_w.to_string() + "x" + target_h.to_string());
        // Remember the last requested size for this URL so we can upgrade later
        requested_image_sizes.set(url, "%dx%d".printf(target_w, target_h));
        // Also record under a normalized key (url_to_picture uses normalized URLs)
        try {
            string nkey = normalize_article_url(url);
            if (nkey != null && nkey.length > 0) requested_image_sizes.set(nkey, "%dx%d".printf(target_w, target_h));
        } catch (GLib.Error e) { }
    // If we're in the initial loading phase, proactively request a larger
    // device-pixel image for medium/large card thumbnails so the first
    // painted result is already crisp instead of appearing blurry then
    // upgrading after a refresh. Use a simple heuristic: targets >= 160px
    // are likely article/card images and benefit from an initial upscale.
    int download_w = target_w;
    int download_h = target_h;
    try {
        if (initial_phase && target_w >= 160) {
            // Request higher-res (2x) but clamp to reasonable maximums
            download_w = clampi(target_w * 2, target_w, 1600);
            download_h = clampi(target_h * 2, target_h, 1600);
            append_debug_log("load_image_async: initial_phase bump request for url=" + url + " requested=" + target_w.to_string() + "x" + target_h.to_string() + " -> download=" + download_w.to_string() + "x" + download_h.to_string());
        }
    } catch (GLib.Error e) { }
    ensure_start_download(url, download_w, download_h);
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

    // Infer source from a URL by checking known domain substrings. Falls back
    // to the current prefs.news_source when uncertain.
    private NewsSource infer_source_from_url(string? url) {
        if (url == null || url.length == 0) return prefs.news_source;
    string low = url.down();
        if (low.index_of("guardian") >= 0 || low.index_of("theguardian") >= 0) return NewsSource.GUARDIAN;
        if (low.index_of("bbc.co") >= 0 || low.index_of("bbc.") >= 0) return NewsSource.BBC;
        if (low.index_of("reddit.com") >= 0 || low.index_of("redd.it") >= 0) return NewsSource.REDDIT;
        if (low.index_of("nytimes") >= 0 || low.index_of("nyti.ms") >= 0) return NewsSource.NEW_YORK_TIMES;
        if (low.index_of("wsj.com") >= 0 || low.index_of("dowjones") >= 0) return NewsSource.WALL_STREET_JOURNAL;
        if (low.index_of("bloomberg") >= 0) return NewsSource.BLOOMBERG;
        if (low.index_of("reuters") >= 0) return NewsSource.REUTERS;
        if (low.index_of("npr.org") >= 0) return NewsSource.NPR;
        if (low.index_of("foxnews") >= 0 || low.index_of("fox.com") >= 0) return NewsSource.FOX;
        // Unknown, return preference as a sensible default
        return prefs.news_source;
    }

    // Resolve a NewsSource from a provided display/source name if possible;
    // fall back to URL inference when the name is missing or unrecognized.
    private NewsSource resolve_source(string? source_name, string? url) {
        // Start with URL-inferred source as a sensible default
        NewsSource resolved = infer_source_from_url(url);
        if (source_name != null && source_name.length > 0) {
            string low = source_name.down();
            if (low.index_of("guardian") >= 0) resolved = NewsSource.GUARDIAN;
            else if (low.index_of("bbc") >= 0) resolved = NewsSource.BBC;
            else if (low.index_of("reddit") >= 0) resolved = NewsSource.REDDIT;
            else if (low.index_of("nytimes") >= 0 || low.index_of("new york") >= 0) resolved = NewsSource.NEW_YORK_TIMES;
            else if (low.index_of("wsj") >= 0 || low.index_of("wall street") >= 0) resolved = NewsSource.WALL_STREET_JOURNAL;
            else if (low.index_of("bloomberg") >= 0) resolved = NewsSource.BLOOMBERG;
            else if (low.index_of("reuters") >= 0) resolved = NewsSource.REUTERS;
            else if (low.index_of("npr") >= 0) resolved = NewsSource.NPR;
            else if (low.index_of("fox") >= 0) resolved = NewsSource.FOX;
            // If we couldn't match the provided name, keep the URL-inferred value
        }

        // Debug: write a trace when PAPERBOY_DEBUG is set so we can inspect decisions
        try {
            string? _dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
            if (_dbg != null && _dbg.length > 0) {
                string in_src = source_name != null ? source_name : "<null>";
                append_debug_log("resolve_source: input_name=" + in_src + " url=" + (url != null ? url : "<null>") + " resolved=" + get_source_name(resolved));
            }
        } catch (GLib.Error e) { }

        return resolved;
    }

    // Normalize an arbitrary source display name into candidate icon basenames.
    // e.g. "Associated Press" -> "associated-press" / "associated_press"
    private string[] source_name_to_icon_candidates(string name) {
        string low = name.down();
        // Remove punctuation except spaces and dashes/underscores
        var sb = new StringBuilder();
        for (int i = 0; i < low.length; i++) {
            char c = low[i];
            if (c.isalnum() || c == ' ' || c == '-' || c == '_') sb.append_c(c);
            else sb.append_c(' ');
        }
        string cleaned = sb.str.strip();
        // Variants: hyphen, underscore, concatenated
    string hyphen = cleaned.replace(" ", "-").replace("--", "-");
    string underscore = cleaned.replace(" ", "_").replace("__", "_");
    string concat = cleaned.replace(" ", "");
        return new string[] { hyphen, underscore, concat };
    }

    // Build a source badge using the provided arbitrary source name (often
    // provided by external APIs) and article URL. This attempts to map the
    // name to a known NewsSource first; if that fails, it looks for a local
    // icon file derived from the source name. If no icon is found it falls
    // back to a text-only badge using the provided name.
    private Gtk.Widget build_source_badge_dynamic(string? source_name, string? url, string? category_id) {
        // Support encoded API-provided logo information: "Display Name||https://.../logo.png"
        string? provided_logo_url = null;
        string? display_name = source_name;
        if (source_name != null && source_name.index_of("||") >= 0) {
            string[] parts = source_name.split("||");
            if (parts.length >= 1) display_name = parts[0].strip();
            if (parts.length >= 2) provided_logo_url = parts[1].strip();
        }

        // Debug: record what the badge builder was handed so we can see
        // whether the frontpage parsing supplied a logo URL or not.
        try {
            string in_dn = display_name != null ? display_name : "<null>";
            string in_logo = provided_logo_url != null ? provided_logo_url : "<null>";
            append_debug_log("build_source_badge_dynamic: display_name='" + in_dn + "' provided_logo_url='" + in_logo + "' category='" + (category_id != null ? category_id : "<null>") + "'");
        } catch (GLib.Error e) { }

    // If the source_name maps to a known NewsSource, reuse existing badge
        // but only when the API did NOT provide an explicit logo URL. When the
        // API provides a logo URL (encoded with "||") we treat it as the
        // authoritative branding and do NOT map to the bundled built-in icons.
        // Additionally: when viewing the special 'frontpage' category the
        // backend's provided source name/logo should be treated as authoritative
        // and we must NOT map it to the user's preferred/built-in sources.
        bool is_frontpage = (category_id != null && category_id == "frontpage");
        if (!is_frontpage && provided_logo_url == null && display_name != null && display_name.length > 0) {
            NewsSource resolved = resolve_source(display_name, url);
            // If resolve_source matched a known built-in source, produce that badge
            // by checking if get_source_icon_path would return a non-null path.
            string? icon_path = get_source_icon_path(resolved);
            if (icon_path != null) return build_source_badge(resolved);
        }

        // Log parsed badge details for debugging when enabled
        try {
            append_debug_log("build_source_badge_dynamic: display_name='" + (display_name != null ? display_name : "<null>") + "' provided_logo_url='" + (provided_logo_url != null ? provided_logo_url : "<null>") + "' category='" + (category_id != null ? category_id : "<null>") + "'");
        } catch (GLib.Error e) { }

        // Try to find a bundled icon based on the API-provided source name
            if (display_name != null && display_name.length > 0) {
            // If the API provided a remote logo URL, prefer using it and
            // leverage the existing image caching/downloading pipeline.
                // For frontpage items, prefer the API-provided logo even if it
                // is not an http(s) URL (some APIs may return data-uris), but
                // the download pipeline expects http(s) so guard accordingly.
            // Accept protocol-relative URLs as well (e.g. //example.com/logo.png)
            if (provided_logo_url != null) {
                provided_logo_url = provided_logo_url.strip();
                if (provided_logo_url.has_prefix("//")) {
                    provided_logo_url = "https:" + provided_logo_url;
                }
            }

            if (provided_logo_url != null && (provided_logo_url.has_prefix("http://") || provided_logo_url.has_prefix("https://"))) {
                var box = new Gtk.Box(Orientation.HORIZONTAL, 6);
                box.add_css_class("source-badge");
                box.set_margin_bottom(8);
                box.set_margin_end(8);
                box.set_valign(Gtk.Align.END);
                box.set_halign(Gtk.Align.END);

                // Circular wrapper for remote logo so dynamic logos appear as
                // rounded avatars consistent with the app's visual language.
                var logo_wrapper = new Gtk.Box(Orientation.HORIZONTAL, 0);
                logo_wrapper.add_css_class("circular-logo");
                // Ensure the wrapper has a stable size so CSS can clip the child
                logo_wrapper.set_size_request(20, 20);
                logo_wrapper.set_valign(Gtk.Align.CENTER);
                logo_wrapper.set_halign(Gtk.Align.CENTER);

                // Picture for the remote logo (will be updated from cache or download)
                var pic = new Gtk.Picture();
                // Force a fixed size so the wrapper is always square and the
                // image is clipped to a perfect circle instead of stretching.
                pic.set_size_request(20, 20);
                pic.set_valign(Gtk.Align.CENTER);
                pic.set_halign(Gtk.Align.CENTER);
                // Start async load which will use memory_meta_cache/meta_cache and
                // pending_downloads to dedupe and persist the image.
                try { load_image_async(pic, provided_logo_url, 20, 20); } catch (GLib.Error e) { }

                logo_wrapper.append(pic);
                box.append(logo_wrapper);

                var lbl = new Gtk.Label(display_name);
                lbl.add_css_class("source-badge-label");
                lbl.set_valign(Gtk.Align.CENTER);
                lbl.set_xalign(0.5f);
                lbl.set_ellipsize(Pango.EllipsizeMode.END);
                lbl.set_max_width_chars(14);
                box.append(lbl);
                return box;
            }

            foreach (var cand in source_name_to_icon_candidates(display_name)) {
                // Check multiple common locations and suffixes
                string[] paths = {
                    GLib.Path.build_filename("icons", cand + "-logo.png"),
                    GLib.Path.build_filename("icons", cand + "-logo.svg"),
                    GLib.Path.build_filename("icons", "symbolic", cand + "-symbolic.svg"),
                    GLib.Path.build_filename("icons", cand + ".png"),
                    GLib.Path.build_filename("icons", cand + ".svg")
                };
                foreach (var rel in paths) {
                    string? full = find_data_file(rel);
                    if (full != null) {
                        // Build a badge that mirrors build_source_badge but uses the
                        // discovered icon and the provided source_name as label.
                        var box = new Gtk.Box(Orientation.HORIZONTAL, 6);
                        box.add_css_class("source-badge");
                        box.set_margin_bottom(8);
                        box.set_margin_end(8);
                        box.set_valign(Gtk.Align.END);
                        box.set_halign(Gtk.Align.END);

                        try {
                            var icon_pix = new Gdk.Pixbuf.from_file(full);
                            if (icon_pix != null) {
                                // Create a 20x20 surface and draw the image scaled-to-cover
                                int orig_w = icon_pix.get_width();
                                int orig_h = icon_pix.get_height();
                                double scale = 1.0;
                                if (orig_w > 0 && orig_h > 0) scale = double.max(20.0 / orig_w, 20.0 / orig_h);
                                int sw = (int)(orig_w * scale);
                                int sh = (int)(orig_h * scale);
                                var scaled_icon = icon_pix.scale_simple(sw, sh, Gdk.InterpType.BILINEAR);

                                var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, 20, 20);
                                var cr = new Cairo.Context(surface);
                                int x = (20 - sw) / 2;
                                int y = (20 - sh) / 2;
                                try { Gdk.cairo_set_source_pixbuf(cr, scaled_icon, x, y); cr.paint(); } catch (GLib.Error e) { }
                                var tex = Gdk.Texture.for_pixbuf(Gdk.pixbuf_get_from_surface(surface, 0, 0, 20, 20));

                                var pic = new Gtk.Picture();
                                pic.set_paintable(tex);
                                pic.set_size_request(20, 20);

                                // Wrap known/local icon in circular wrapper to match dynamic badges
                                var logo_wrapper = new Gtk.Box(Orientation.HORIZONTAL, 0);
                                logo_wrapper.add_css_class("circular-logo");
                                logo_wrapper.set_size_request(20, 20);
                                logo_wrapper.set_valign(Gtk.Align.CENTER);
                                logo_wrapper.set_halign(Gtk.Align.CENTER);
                                logo_wrapper.append(pic);
                                box.append(logo_wrapper);
                            }
                        } catch (GLib.Error e) { /* ignore icon load failure */ }

                        var lbl = new Gtk.Label(display_name != null && display_name.length > 0 ? display_name : source_name);
                        lbl.add_css_class("source-badge-label");
                        lbl.set_valign(Gtk.Align.CENTER);
                        lbl.set_xalign(0.5f);
                        lbl.set_ellipsize(Pango.EllipsizeMode.END);
                        lbl.set_max_width_chars(14);
                        box.append(lbl);
                        return box;
                    }
                }
            }
        }

        // Last resort: return a text-only badge using the provided source name
        var box = new Gtk.Box(Orientation.HORIZONTAL, 6);
        box.add_css_class("source-badge");
        box.set_margin_bottom(8);
        box.set_margin_end(8);
        box.set_valign(Gtk.Align.END);
        box.set_halign(Gtk.Align.END);
    var lbl = new Gtk.Label(display_name != null && display_name.length > 0 ? display_name : (source_name != null && source_name.length > 0 ? source_name : "News"));
        lbl.add_css_class("source-badge-label");
        lbl.set_valign(Gtk.Align.CENTER);
        lbl.set_xalign(0.5f);
        lbl.set_ellipsize(Pango.EllipsizeMode.END);
        lbl.set_max_width_chars(14);
        box.append(lbl);
        return box;
    }

    // Build a small source badge widget (icon + short name) to place in the
    // top-right corner of cards and hero slides.
    private Gtk.Widget build_source_badge(NewsSource source) {
        var box = new Gtk.Box(Orientation.HORIZONTAL, 6);
        box.add_css_class("source-badge");
    // Position badge at the bottom-right of the overlay
    box.set_margin_bottom(8);
    box.set_margin_end(8);
    box.set_valign(Gtk.Align.END);
    box.set_halign(Gtk.Align.END);

        // Try to load an icon image for the source
        string? path = get_source_icon_path(source);
        if (path != null) {
                try {
                    var icon_pix = new Gdk.Pixbuf.from_file(path);
                    if (icon_pix != null) {
                        int orig_w = icon_pix.get_width();
                        int orig_h = icon_pix.get_height();
                        double scale = 1.0;
                        if (orig_w > 0 && orig_h > 0) scale = double.max(20.0 / orig_w, 20.0 / orig_h);
                        int sw = (int)(orig_w * scale);
                        int sh = (int)(orig_h * scale);
                        var scaled_icon = icon_pix.scale_simple(sw, sh, Gdk.InterpType.BILINEAR);

                        var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, 20, 20);
                        var cr = new Cairo.Context(surface);
                        int x = (20 - sw) / 2;
                        int y = (20 - sh) / 2;
                        try { Gdk.cairo_set_source_pixbuf(cr, scaled_icon, x, y); cr.paint(); } catch (GLib.Error e) { }
                        var tex = Gdk.Texture.for_pixbuf(Gdk.pixbuf_get_from_surface(surface, 0, 0, 20, 20));

                        var pic = new Gtk.Picture();
                        pic.set_paintable(tex);
                        pic.set_size_request(20, 20);

                        // Wrap bundled source icons in the same circular wrapper
                        var logo_wrapper = new Gtk.Box(Orientation.HORIZONTAL, 0);
                        logo_wrapper.add_css_class("circular-logo");
                        logo_wrapper.set_size_request(20, 20);
                        logo_wrapper.set_valign(Gtk.Align.CENTER);
                        logo_wrapper.set_halign(Gtk.Align.CENTER);
                        logo_wrapper.append(pic);
                        box.append(logo_wrapper);
                    }
                } catch (GLib.Error e) {
                    // ignore and fall back to text
                }
        }

        var lbl = new Gtk.Label(get_source_name(source));
        lbl.add_css_class("source-badge-label");
        lbl.set_valign(Gtk.Align.CENTER);
    lbl.set_xalign(0.5f);
        lbl.set_ellipsize(Pango.EllipsizeMode.END);
        lbl.set_max_width_chars(12);
        box.append(lbl);

        return box;
    }

    // Build a small 'Viewed' badge with a check icon to place in the top-right
    // corner of a card/hero when the user has already opened the preview.
    private Gtk.Widget build_viewed_badge() {
        var box = new Gtk.Box(Orientation.HORIZONTAL, 6);
        box.add_css_class("viewed-badge");
        box.set_valign(Gtk.Align.START);
        box.set_halign(Gtk.Align.END);
        box.set_margin_top(8);
        box.set_margin_end(8);

        try {
            var icon = new Gtk.Image.from_icon_name("emblem-ok-symbolic");
            icon.set_pixel_size(14);
            box.append(icon);
        } catch (GLib.Error e) { }

    var lbl = new Gtk.Label("Viewed");
    // Avoid using the theme's dim label class so the text remains bright.
    // Add a dedicated class we can target from CSS for any further tweaks.
    try { lbl.get_style_context().remove_class("dim-label"); } catch (GLib.Error e) { }
    lbl.add_css_class("viewed-badge-label");
    lbl.add_css_class("caption");
    box.append(lbl);
        return box;
    }

    // Mark the given article URL as viewed (normalized) and add a badge to the
    // corresponding card/hero if it is currently present in the UI.
    public void mark_article_viewed(string url) {
        if (url == null) return;
        string n = normalize_article_url(url);
        if (n == null || n.length == 0) return;
        if (viewed_articles == null) viewed_articles = new Gee.HashSet<string>();
        viewed_articles.add(n);

        try { append_debug_log("mark_article_viewed: normalized=" + n); } catch (GLib.Error e) { }

        // Add the badge overlay after a small delay to avoid interfering with scroll restoration
        Timeout.add(50, () => {
            try {
                var card = url_to_card.get(n);
                if (card != null) {
                    try { append_debug_log("mark_article_viewed: found mapped widget for " + n); } catch (GLib.Error e) { }
                    // The card's first child is the overlay we created earlier
                    Gtk.Widget? first = card.get_first_child();
                    if (first != null && first is Gtk.Overlay) {
                        var overlay = (Gtk.Overlay) first;
                        // Avoid adding duplicate viewed badges
                        bool already = false;
                        Gtk.Widget? c = overlay.get_first_child();
                        while (c != null) {
                            try {
                                // GTK4's StyleContext does not expose a list_classes API in
                                // the Vala bindings; use has_class to detect our badge class.
                                if (c.get_style_context().has_class("viewed-badge")) {
                                    already = true;
                                }
                            } catch (GLib.Error e) { }
                            if (already) break;
                            c = c.get_next_sibling();
                        }
                        if (!already) {
                            var badge = build_viewed_badge();
                            overlay.add_overlay(badge);
                            badge.set_visible(true);
                            overlay.queue_draw();
                            try { append_debug_log("mark_article_viewed: added viewed badge for " + n); } catch (GLib.Error e) { }
                        } else {
                            try { append_debug_log("mark_article_viewed: badge already exists for " + n); } catch (GLib.Error e) { }
                        }
                    } else {
                        try { append_debug_log("mark_article_viewed: first child is not overlay for " + n); } catch (GLib.Error e) { }
                    }
                } else {
                    try { append_debug_log("mark_article_viewed: no card found for " + n); } catch (GLib.Error e) { }
                }
            } catch (GLib.Error e) { 
                try { append_debug_log("mark_article_viewed: error adding badge - " + e.message); } catch (GLib.Error ee) { }
            }
            return false;
        });
        
        // Persist viewed state to per-article metadata cache so this is stored
        // with the cached image/metadata rather than the global config file.
        try {
            if (meta_cache != null) {
                bool already = false;
                try { already = meta_cache.is_viewed(n); } catch (GLib.Error e) { already = false; }
                if (!already) {
                    try { meta_cache.mark_viewed(n); } catch (GLib.Error e) { }
                }
            }
        } catch (GLib.Error e) { }
    }

    // Called by ArticleWindow when a preview is opened so the main window
    // can remember which URL is active (used by keyboard handlers).
    public void preview_opened(string url) {
        try { last_previewed_url = url; } catch (GLib.Error e) { last_previewed_url = null; }
        // Show dim overlay to disable main area
        if (dim_overlay != null) dim_overlay.set_visible(true);
        // Capture current vertical scroll offset so we can restore it when the preview closes
        try {
            if (main_scrolled != null) {
                try {
                    var adj = main_scrolled.get_vadjustment();
                    if (adj != null) last_scroll_value = adj.get_value();
                } catch (GLib.Error e) { last_scroll_value = -1.0; }
            }
        } catch (GLib.Error e) { last_scroll_value = -1.0; }
        try { append_debug_log("preview_opened: " + (url != null ? url : "<null>") + " scroll=" + last_scroll_value.to_string()); } catch (GLib.Error e) { }
    }

    // Called by ArticleWindow when the preview is closed; mark the article
    // viewed now that the user returned to the main view.
    public void preview_closed(string url) {
        // Make a local copy of the URL to avoid any issues with the parameter being freed
        string? url_copy = null;
        try {
            if (url != null && url.length > 0) {
                url_copy = url.dup();
            }
        } catch (GLib.Error e) { }
        
        // Clear the last previewed URL
        try { last_previewed_url = null; } catch (GLib.Error e) { }
        
        // Hide dim overlay
        if (dim_overlay != null) dim_overlay.set_visible(false);
        
        // Save the scroll position again right before we do anything else
        double saved_scroll = last_scroll_value;
        if (saved_scroll < 0.0) {
            try {
                if (main_scrolled != null) {
                    var adj = main_scrolled.get_vadjustment();
                    if (adj != null) saved_scroll = adj.get_value();
                }
            } catch (GLib.Error e) { }
        }
        
        try { append_debug_log("preview_closed: " + (url_copy != null ? url_copy : "<null>") + " scroll_to_restore=" + saved_scroll.to_string()); } catch (GLib.Error e) { }
        
        // Mark viewed immediately using our local copy
        try { if (url_copy != null) mark_article_viewed(url_copy); } catch (GLib.Error e) { }
        
        // Restore previous scroll offset AFTER marking viewed. Use multiple attempts
        // with increasing delays to ensure it takes effect.
        try {
            if (main_scrolled != null && saved_scroll >= 0.0) {
                // First attempt immediately after marking viewed
                Idle.add(() => {
                    try {
                        var adj = main_scrolled.get_vadjustment();
                        if (adj != null) {
                            adj.set_value(saved_scroll);
                            try { append_debug_log("scroll restored (immediate): " + saved_scroll.to_string()); } catch (GLib.Error e) { }
                        }
                    } catch (GLib.Error e) { }
                    return false;
                }, Priority.HIGH);
                
                // Second attempt with delay
                Timeout.add(100, () => {
                    try {
                        var adj = main_scrolled.get_vadjustment();
                        if (adj != null) {
                            adj.set_value(saved_scroll);
                            try { append_debug_log("scroll restored (100ms): " + saved_scroll.to_string()); } catch (GLib.Error e) { }
                        }
                    } catch (GLib.Error e) { }
                    return false;
                });
                
                // Third attempt with longer delay to catch any late resets
                Timeout.add(200, () => {
                    try {
                        var adj = main_scrolled.get_vadjustment();
                        if (adj != null) {
                            adj.set_value(saved_scroll);
                            try { append_debug_log("scroll restored (200ms): " + saved_scroll.to_string()); } catch (GLib.Error e) { }
                        }
                    } catch (GLib.Error e) { }
                    return false;
                });
            }
        } catch (GLib.Error e) { }
        // Reset stored value
        last_scroll_value = -1.0;
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

    // Variant that honors an explicit NewsSource so the UI can render a
    // per-article branded placeholder even when the application's global
    // prefs.news_source differs (useful when multiple sources are enabled).
    private void set_placeholder_image_for_source(Gtk.Picture image, int width, int height, NewsSource source) {
        string? icon_path = get_source_icon_path(source);
        string source_name = get_source_name(source);
        if (icon_path != null) {
            try {
                // Draw icon-centered placeholder with a gradient chosen by the
                // provided source (not the global prefs.news_source).
                var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, width, height);
                var cr = new Cairo.Context(surface);
                var gradient = new Cairo.Pattern.linear(0, 0, 0, height);
                switch (source) {
                    case NewsSource.GUARDIAN:
                        gradient.add_color_stop_rgb(0, 0.0, 0.2, 0.4);
                        gradient.add_color_stop_rgb(1, 0.0, 0.4, 0.6);
                        break;
                    case NewsSource.BBC:
                        gradient.add_color_stop_rgb(0, 0.6, 0.0, 0.0);
                        gradient.add_color_stop_rgb(1, 0.8, 0.1, 0.1);
                        break;
                    case NewsSource.REDDIT:
                        gradient.add_color_stop_rgb(0, 1.0, 0.2, 0.0);
                        gradient.add_color_stop_rgb(1, 1.0, 0.4, 0.1);
                        break;
                    case NewsSource.NEW_YORK_TIMES:
                        gradient.add_color_stop_rgb(0, 0.1, 0.1, 0.1);
                        gradient.add_color_stop_rgb(1, 0.3, 0.3, 0.3);
                        break;
                    case NewsSource.BLOOMBERG:
                        gradient.add_color_stop_rgb(0, 0.0, 0.3, 0.7);
                        gradient.add_color_stop_rgb(1, 0.1, 0.5, 0.9);
                        break;
                    case NewsSource.REUTERS:
                        gradient.add_color_stop_rgb(0, 0.3, 0.3, 0.4);
                        gradient.add_color_stop_rgb(1, 0.5, 0.5, 0.6);
                        break;
                    case NewsSource.NPR:
                        gradient.add_color_stop_rgb(0, 0.1, 0.2, 0.5);
                        gradient.add_color_stop_rgb(1, 0.2, 0.3, 0.7);
                        break;
                    case NewsSource.FOX:
                        gradient.add_color_stop_rgb(0, 0.0, 0.2, 0.6);
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

                var icon_pixbuf = new Gdk.Pixbuf.from_file(icon_path);
                if (icon_pixbuf != null) {
                    int orig_w = icon_pixbuf.get_width();
                    int orig_h = icon_pixbuf.get_height();
                    double max_size = double.min(width, height) * 0.5;
                    double scale = double.min(max_size / orig_w, max_size / orig_h);
                    int scaled_w = (int)(orig_w * scale);
                    int scaled_h = (int)(orig_h * scale);
                    var scaled_icon = icon_pixbuf.scale_simple(scaled_w, scaled_h, Gdk.InterpType.BILINEAR);
                    int x = (width - scaled_w) / 2;
                    int y = (height - scaled_h) / 2;
                    cr.save();
                    cr.set_source_rgba(1, 1, 1, 0.9);
                    Gdk.cairo_set_source_pixbuf(cr, scaled_icon, x, y);
                    cr.paint_with_alpha(0.95);
                    cr.restore();
                }

                var texture = Gdk.Texture.for_pixbuf(Gdk.pixbuf_get_from_surface(surface, 0, 0, width, height));
                image.set_paintable(texture);
                return;
            } catch (GLib.Error e) {
                // Fall through to text placeholder on error
            }
        }

        // Text-based fallback
        try {
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, width, height);
            var cr = new Cairo.Context(surface);
            var gradient = new Cairo.Pattern.linear(0, 0, 0, height);
            switch (source) {
                case NewsSource.GUARDIAN:
                    gradient.add_color_stop_rgb(0, 0.0, 0.3, 0.6);
                    gradient.add_color_stop_rgb(1, 0.0, 0.5, 0.8);
                    break;
                case NewsSource.BBC:
                    gradient.add_color_stop_rgb(0, 0.7, 0.0, 0.0);
                    gradient.add_color_stop_rgb(1, 0.9, 0.2, 0.2);
                    break;
                case NewsSource.REDDIT:
                    gradient.add_color_stop_rgb(0, 1.0, 0.3, 0.0);
                    gradient.add_color_stop_rgb(1, 1.0, 0.5, 0.2);
                    break;
                case NewsSource.NEW_YORK_TIMES:
                    gradient.add_color_stop_rgb(0, 0.0, 0.0, 0.0);
                    gradient.add_color_stop_rgb(1, 0.2, 0.2, 0.2);
                    break;
                case NewsSource.BLOOMBERG:
                    gradient.add_color_stop_rgb(0, 0.0, 0.4, 0.8);
                    gradient.add_color_stop_rgb(1, 0.2, 0.6, 1.0);
                    break;
                case NewsSource.REUTERS:
                    gradient.add_color_stop_rgb(0, 0.4, 0.4, 0.4);
                    gradient.add_color_stop_rgb(1, 0.6, 0.6, 0.6);
                    break;
                case NewsSource.NPR:
                    gradient.add_color_stop_rgb(0, 0.2, 0.2, 0.6);
                    gradient.add_color_stop_rgb(1, 0.4, 0.4, 0.8);
                    break;
                case NewsSource.FOX:
                    gradient.add_color_stop_rgb(0, 0.0, 0.3, 0.7);
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

            cr.select_font_face("Sans", Cairo.FontSlant.NORMAL, Cairo.FontWeight.BOLD);
            double font_size = double.min(width / 8.0, height / 4.0);
            font_size = double.max(font_size, 12.0);
            cr.set_font_size(font_size);
            Cairo.TextExtents extents;
            cr.text_extents(source_name, out extents);
            double x = (width - extents.width) / 2;
            double y = (height + extents.height) / 2;
            cr.set_source_rgba(0, 0, 0, 0.5);
            cr.move_to(x + 2, y + 2);
            cr.show_text(source_name);
            cr.set_source_rgba(1, 1, 1, 0.9);
            cr.move_to(x, y);
            cr.show_text(source_name);
            var texture = Gdk.Texture.for_pixbuf(Gdk.pixbuf_get_from_surface(surface, 0, 0, width, height));
            image.set_paintable(texture);
        } catch (GLib.Error e) {
            // as a last resort fall back to the generic gradient placeholder
            create_gradient_placeholder(image, width, height);
        }
    }

    // Local-news specific placeholder that uses the app-local mono icon
    // (symbolic) and prefers a white variant in dark mode.
    public void set_local_placeholder_image(Gtk.Picture image, int width, int height) {
        try {
            string? local_icon = find_data_file(GLib.Path.build_filename("icons", "symbolic", "local-mono.svg"));
            if (local_icon == null) local_icon = find_data_file(GLib.Path.build_filename("icons", "local-mono.svg"));
            string use_path = local_icon != null ? local_icon : null;
            if (use_path != null) {
                try {
                    if (is_dark_mode()) {
                        string? white_cand = find_data_file(GLib.Path.build_filename("icons", "symbolic", "local-mono-white.svg"));
                        if (white_cand == null) white_cand = find_data_file(GLib.Path.build_filename("icons", "local-mono-white.svg"));
                        if (white_cand != null) use_path = white_cand;
                    }
                } catch (GLib.Error e) { }

                // Load the icon and draw it centered at a reduced size so it
                // doesn't look blown-out inside the placeholder. We create a
                // small Cairo surface the size of the placeholder and paint
                // a subtle background then draw the mono icon centered at
                // ~40% of the placeholder's min dimension.
                try {
                    var icon_pix = new Gdk.Pixbuf.from_file(use_path);
                    if (icon_pix != null) {
                        int orig_w = icon_pix.get_width();
                        int orig_h = icon_pix.get_height();

                        // Target icon max size: ~40% of the placeholder
                        double max_icon = double.min(width, height) * 0.4;
                        // Prevent upscaling too much; only downscale if needed
                        double scale = double.min(max_icon / (double)orig_w, max_icon / (double)orig_h);
                        if (scale > 1.0) scale = 1.0;

                        int scaled_w = (int)(orig_w * scale);
                        int scaled_h = (int)(orig_h * scale);
                        if (scaled_w < 1) scaled_w = 1;
                        if (scaled_h < 1) scaled_h = 1;

                        var scaled = icon_pix.scale_simple(scaled_w, scaled_h, Gdk.InterpType.BILINEAR);

                        // Create a surface and draw a subtle light-blue gradient
                        var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, width, height);
                        var cr = new Cairo.Context(surface);
                        var pattern = new Cairo.Pattern.linear(0, 0, 0, height);
                        // Light blue gradient (top -> bottom). Use a slightly
                        // darker tint so the mono icon has better contrast.
                        // Top: softened blue (slightly darker than before)
                        pattern.add_color_stop_rgb(0, 0.80, 0.90, 0.98);
                        // Bottom: a touch deeper blue for subtle depth (slightly darker)
                        pattern.add_color_stop_rgb(1, 0.70, 0.84, 0.98);
                        cr.set_source(pattern);
                        cr.rectangle(0, 0, width, height);
                        cr.fill();

                        // Center the icon
                        int x = (width - scaled_w) / 2;
                        int y = (height - scaled_h) / 2;
                        cr.save();
                        // Slightly translucent draw for elegance
                        Gdk.cairo_set_source_pixbuf(cr, scaled, x, y);
                        cr.paint_with_alpha(0.95);
                        cr.restore();

                        var tex = Gdk.Texture.for_pixbuf(Gdk.pixbuf_get_from_surface(surface, 0, 0, width, height));
                        try { image.set_paintable(tex); } catch (GLib.Error e) { }
                        return;
                    }
                } catch (GLib.Error e) {
                    // Fall back to generic placeholder below if loading/drawing fails
                }
            }
        } catch (GLib.Error e) {
            // fall through to generic placeholder
        }

        // Fallback: use the generic placeholder flow
        set_placeholder_image(image, width, height);
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
        if (loading_container != null && loading_spinner != null && loading_label != null) {
            // If we're fetching Local News, show a more specific message
            try {
                var prefs_local = NewsPreferences.get_instance();
                if (prefs_local != null && prefs_local.category == "local_news") {
                    loading_label.set_text("Loading local news...");
                } else {
                    loading_label.set_text("Loading news...");
                }
            } catch (GLib.Error e) { /* best-effort */ }

            loading_container.set_visible(true);
            loading_spinner.start();
            // While loading, hide the main content to present a single
            // focused loading state. Overlays (personalized/local) may
            // still be shown by their own logic; respect them afterwards.
            try { if (main_content_container != null) main_content_container.set_visible(false); } catch (GLib.Error e) { }
        }
    }
    
    private void hide_loading_spinner() {
        if (loading_container != null && loading_spinner != null && loading_label != null) {
            // Reset generic message when hiding
            try { loading_label.set_text("Loading news..."); } catch (GLib.Error e) { }
            loading_container.set_visible(false);
            loading_spinner.stop();
            // Restore main content visibility, but defer to the personalized
            // and local-news overlay logic which will hide content when needed.
            try { update_personalization_ui(); } catch (GLib.Error e) { }
            try { update_local_news_ui(); } catch (GLib.Error e) { }
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
        // Hide spinner and reveal main content (unless an overlay wants it hidden).
        hide_loading_spinner();
        try {
            // If neither personalized nor local-news overlays are visible,
            // ensure the main content is visible now that initial loading
            // has completed.
            bool pvis = personalized_message_box != null ? personalized_message_box.get_visible() : false;
            bool lvis = local_news_message_box != null ? local_news_message_box.get_visible() : false;
            if (!pvis && !lvis) {
                try { if (main_content_container != null) main_content_container.set_visible(true); } catch (GLib.Error e) { }
            }
        } catch (GLib.Error e) { }
        // After revealing light-weight thumbnails, schedule a background pass
        // to upgrade images to higher quality so the UI feels fast but
        // still eventually shows crisp images.
        Timeout.add(500, () => {
            upgrade_images_after_initial();
            return false;
        });
    }

    // Helper to form memory cache keys that include requested size
    private string make_cache_key(string url, int w, int h) {
        return "%s@%dx%d".printf(url, w, h);
    }

    // Process deferred download requests: if a deferred widget becomes visible,
    // start its download. This runs on the main loop and reschedules itself
    // only when there are remaining deferred requests.
    private void process_deferred_downloads() {
        // Collect to-start entries to avoid modifying map while iterating
        var to_start = new Gee.ArrayList<Gtk.Picture>();
        foreach (var kv in deferred_downloads.entries) {
            Gtk.Picture pic = kv.key;
            DeferredRequest req = kv.value;
            bool vis = false;
            try { vis = pic.get_visible(); } catch (GLib.Error e) { vis = true; }
            if (vis) to_start.add(pic);
        }

        foreach (var pic in to_start) {
            var req = deferred_downloads.get(pic);
            if (req == null) continue;
            // Remove before starting to avoid races
            try { deferred_downloads.remove(pic); } catch (GLib.Error e) { }
            // Start immediately (force bypass visibility deferral)
            try { load_image_async(pic, req.url, req.w, req.h, true); } catch (GLib.Error e) { }
        }
        // If there are still deferred entries, schedule another check
        if (deferred_downloads.size > 0) {
            if (deferred_check_timeout_id == 0) {
                deferred_check_timeout_id = Timeout.add(700, () => {
                    try { process_deferred_downloads(); } catch (GLib.Error e) { }
                    deferred_check_timeout_id = 0;
                    return false;
                });
            }
        }
    }

    // After initial-phase end: request higher-res images for items we loaded
    // at reduced sizes. To avoid flooding the network/CPU we only upgrade
    // images that are still present in the UI (`url_to_picture`) and we do
    // them in small batches with a short delay between batches.
    private void upgrade_images_after_initial() {
        // Be conservative: smaller batches and longer pause to avoid
        // saturating network/CPU and doing many main-thread decodes.
        const int UPGRADE_BATCH_SIZE = 3;
        int processed = 0;

        foreach (var kv in url_to_picture.entries) {
            // kv.key is the normalized article URL
            string norm_url = kv.key;
            Gtk.Picture? pic = kv.value;
            if (pic == null) continue;

            // Look up the last requested size (may be stored under normalized key)
            var rec = requested_image_sizes.get(norm_url);
            if (rec == null || rec.length == 0) continue;
            string[] parts = rec.split("x");
            if (parts.length != 2) continue;
            int last_w = 0; int last_h = 0;
            try { last_w = int.parse(parts[0]); last_h = int.parse(parts[1]); } catch (GLib.Error e) { continue; }

            int new_w = (int)(last_w * 2);
            int new_h = (int)(last_h * 2);
            new_w = clampi(new_w, last_w, 1600);
            new_h = clampi(new_h, last_h, 1600);

            // Check memory cache for both normalized-keyed and original-keyed entries
            bool has_large = false;
            string key_norm = make_cache_key(norm_url, new_w, new_h);
            if (memory_meta_cache.get(key_norm) != null) has_large = true;

            string? original = normalized_to_url.get(norm_url);
            if (!has_large && original != null) {
                string key_orig = make_cache_key(original, new_w, new_h);
                if (memory_meta_cache.get(key_orig) != null) has_large = true;
            }

            if (has_large) continue; // already have larger

            // Find original URL to request (don't use normalized URL for network)
            if (original == null) continue;
            load_image_async(pic, original, new_w, new_h);

            processed += 1;
            if (processed >= UPGRADE_BATCH_SIZE) {
                // Schedule the next batch after a short pause
                Timeout.add(1000, () => {
                    upgrade_images_after_initial();
                    return false;
                });
                return;
            }
        }
        // finished all entries (no-op)
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
        // Debug: log fetch_news invocation and current sequence
        try {
            string? _dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
            if (_dbg != null && _dbg.length > 0) {
                append_debug_log("fetch_news: entering seq=" + fetch_sequence.to_string() + " category=" + prefs.category + " preferred_sources=" + array_join(prefs.preferred_sources));
            }
        } catch (GLib.Error e) { }

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
        if (featured_carousel_widgets != null) featured_carousel_widgets.clear();
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
        
        // If the user selected "My Feed" but personalization is disabled,
        // do not show the loading spinner or attempt to fetch content here.
        // Instead, ensure the personalized overlay is updated and return.
        bool is_myfeed_disabled = (prefs.category == "myfeed" && !prefs.personalized_feed_enabled);
        if (is_myfeed_disabled) {
            try { if (current_search_query.length > 0) category_label.set_text("Search Results: \"" + current_search_query + "\" in My Feed"); else category_label.set_text("My Feed"); } catch (GLib.Error e) { }
            try { update_personalization_ui(); } catch (GLib.Error e) { }
            // Ensure any spinner is hidden and don't proceed to fetch
            hide_loading_spinner();
            return;
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
        uint before_seq = fetch_sequence;
        fetch_sequence += 1;
        uint my_seq = fetch_sequence;
        try {
            string? _dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
            if (_dbg != null && _dbg.length > 0) append_debug_log("fetch_news: bumped fetch_sequence " + before_seq.to_string() + " -> " + fetch_sequence.to_string());
        } catch (GLib.Error e) { }

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
            if (my_seq != self_ref.fetch_sequence) {
                try { if (GLib.Environment.get_variable("PAPERBOY_DEBUG") != null) append_debug_log("wrapped_set_label: ignoring stale seq=" + my_seq.to_string() + " current=" + self_ref.fetch_sequence.to_string()); } catch (GLib.Error e) { }
                return;
            }
            // Extract just the category part before the " — " separator
            string category_part = text;
            int separator_pos = text.index_of(" — ");
            if (separator_pos > 0) {
                category_part = text.substring(0, separator_pos);
            }
            self_ref.category_label.set_text(category_part);
            // Keep the category icon in sync with the active preference
            // (wrapped_set_label runs on successful fetches and will
            // reflect the current prefs.category). Use a best-effort
            // call to avoid crashing on early initialization.
            try { self_ref.update_category_icon(); } catch (GLib.Error e) { }
        };

        // Wrapped clear_items: only clear if this fetch is still current
        ClearItemsFunc wrapped_clear = () => {
                if (my_seq != self_ref.fetch_sequence) {
                    try { if (GLib.Environment.get_variable("PAPERBOY_DEBUG") != null) append_debug_log("wrapped_clear: ignoring stale seq=" + my_seq.to_string() + " current=" + self_ref.fetch_sequence.to_string()); } catch (GLib.Error e) { }
                    return;
                }
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
    // Throttled add for Local News: queue incoming items and process in small batches
    var local_news_queue = new Gee.ArrayList<ArticleItem>();
    bool local_news_flush_scheduled = false;

    AddItemFunc wrapped_add = (title, url, thumbnail, category_id, source_name) => {
            if (my_seq != self_ref.fetch_sequence) {
                try { if (GLib.Environment.get_variable("PAPERBOY_DEBUG") != null) append_debug_log("wrapped_add: ignoring stale seq=" + my_seq.to_string() + " current=" + self_ref.fetch_sequence.to_string() + " article_cat=" + category_id); } catch (GLib.Error e) { }
                return;
            }

            // If we're in Local News mode, enqueue and process in small batches to avoid UI lockups
            try {
                var prefs_local = NewsPreferences.get_instance();
                if (prefs_local != null && prefs_local.category == "local_news") {
                    local_news_queue.add(new ArticleItem(title, url, thumbnail, category_id, source_name));
                    if (!local_news_flush_scheduled) {
                        local_news_flush_scheduled = true;
                        // Process up to 6 items per tick to keep UI responsive
                        Timeout.add(60, () => {
                            int processed = 0;
                            int batch = 6;
                            while (local_news_queue.size > 0 && processed < batch) {
                                var ai = local_news_queue.get(0);
                                local_news_queue.remove_at(0);
                                // Ensure still current before adding
                                if (my_seq == self_ref.fetch_sequence) {
                                    self_ref.add_item(ai.title, ai.url, ai.thumbnail_url, ai.category_id, ai.source_name);
                                }
                                processed++;
                            }
                            if (local_news_queue.size > 0) {
                                // Keep the timeout running until the queue is drained
                                return true;
                            } else {
                                local_news_flush_scheduled = false;
                                return false;
                            }
                        });
                    }
                    return;
                }
            } catch (GLib.Error e) { /* best-effort */ }

            // Default: immediate add
            self_ref.add_item(title, url, thumbnail, category_id, source_name);
        };

        // Support fetching from multiple preferred sources when the user
        // has enabled more than one in preferences. The preferences store
        // string ids (e.g. "guardian", "reddit"). Map those to the
        // NewsSource enum and invoke NewsSources.fetch for each. Ensure
        // we only clear the UI once (for the first fetch) so subsequent
        // fetches append their results.
        bool used_multi = false;
        // Support personalized "My Feed" mode: when the user has selected
        // the sidebar "My Feed" category and enabled personalization, we
        // should fetch each personalized category separately and combine
        // the results. Build the list of categories to request here.
        bool is_myfeed_mode = (prefs.category == "myfeed" && prefs.personalized_feed_enabled);
        string[] myfeed_cats = new string[0];
        if (is_myfeed_mode) {
            if (prefs.personalized_categories != null && prefs.personalized_categories.size > 0) {
                myfeed_cats = new string[prefs.personalized_categories.size];
                for (int i = 0; i < prefs.personalized_categories.size; i++) myfeed_cats[i] = prefs.personalized_categories.get(i);
            } else {
                // Personalization enabled but no categories selected: do not fall
                // back to a default. Instead, avoid fetching content so the
                // personalized overlay (shown elsewhere) can be displayed.
                try { wrapped_clear(); } catch (GLib.Error e) { }
                try { wrapped_set_label("My Feed — No personalized categories selected"); } catch (GLib.Error e) { }
                hide_loading_spinner();
                return;
            }
        }

        // Local News: if the user selected the Local News sidebar item,
        // attempt to read per-user feeds from ~/.config/paperboy/local_feeds
        // and fetch each feed URL with the RSS parser. This allows the
        // rssFinder helper (a separate binary) to populate the file and
        // the app to display the resulting feeds.
        if (prefs.category == "local_news") {
            string config_dir = GLib.Environment.get_user_config_dir() + "/paperboy";
            string file_path = config_dir + "/local_feeds";

            // If no local_feeds file exists, show a helpful label and stop.
            if (!GLib.FileUtils.test(file_path, GLib.FileTest.EXISTS)) {
                try { wrapped_set_label("Local News — No local feeds configured"); } catch (GLib.Error e) { }
                hide_loading_spinner();
                return;
            }

            string contents = "";
            try { GLib.FileUtils.get_contents(file_path, out contents); } catch (GLib.Error e) { contents = ""; }
            if (contents == null || contents.strip() == "") {
                try { wrapped_set_label("Local News — No local feeds configured"); } catch (GLib.Error e) { }
                hide_loading_spinner();
                return;
            }

            // Clear UI and schedule per-feed fetches
            try { wrapped_clear(); } catch (GLib.Error e) { }
            ClearItemsFunc no_op_clear = () => { };
            SetLabelFunc label_fn = (text) => {
                if (current_search_query.length > 0) self_ref.category_label.set_text("Search Results: \"" + current_search_query + "\" in Local News");
                else self_ref.category_label.set_text("Local News");
            };

            // Ensure the top-right source badge shows a generic/local affordance
            // when we're displaying Local News (feeds may represent many sources).
            try { self_ref.source_label.set_text("Local News"); } catch (GLib.Error e) { }
            // Prefer a repo-local symbolic "local-mono" icon when available so the
            // top-right logo matches the app's iconography. Fall back to the
            // generic RSS symbolic icon if no local asset is found.
            try {
                string? local_icon = self_ref.find_data_file(GLib.Path.build_filename("icons", "symbolic", "local-mono.svg"));
                if (local_icon == null) local_icon = self_ref.find_data_file(GLib.Path.build_filename("icons", "local-mono.svg"));
                if (local_icon != null) {
                    string use_path = local_icon;
                    try {
                        if (self_ref.is_dark_mode()) {
                            string? white_cand = self_ref.find_data_file(GLib.Path.build_filename("icons", "symbolic", "local-mono-white.svg"));
                            if (white_cand == null) white_cand = self_ref.find_data_file(GLib.Path.build_filename("icons", "local-mono-white.svg"));
                            if (white_cand != null) use_path = white_cand;
                        }
                    } catch (GLib.Error e) { }
                    var pix = new Gdk.Pixbuf.from_file_at_size(use_path, 32, 32);
                    if (pix != null) {
                        var tex = Gdk.Texture.for_pixbuf(pix);
                        try { self_ref.source_logo.set_from_paintable(tex); } catch (GLib.Error e) { try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { } }
                    } else {
                        try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error e) { }
                    }
                } else {
                    try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error e) { }
                }
            } catch (GLib.Error e) { try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { } }

            string[] lines = contents.split("\n");
            bool found_feed = false;
            for (int i = 0; i < lines.length; i++) {
                string u = lines[i].strip();
                if (u.length == 0) continue;
                found_feed = true;
                RssParser.fetch_rss_url(u, "Local Feed", "Local News", "local_news", current_search_query, session, label_fn, no_op_clear, wrapped_add);
            }
            if (!found_feed) {
                try { wrapped_set_label("Local News — No local feeds configured"); } catch (GLib.Error e) { }
            }
            return;
        }
        // If the user selected "The Frontpage", always request the backend
        // frontpage endpoint regardless of preferred_sources. Place this
        // before the multi-source branch so frontpage works even when the
        // user has zero or one preferred source selected.
        if (prefs.category == "frontpage") {
            // Present the multi-source label/logo in the header
            try { self_ref.source_label.set_text("Multiple Sources"); } catch (GLib.Error e) { }
            try {
                string? multi_icon = self_ref.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono.svg"));
                if (multi_icon == null) multi_icon = self_ref.find_data_file(GLib.Path.build_filename("icons", "multiple-mono.svg"));
                if (multi_icon != null) {
                    string use_path = multi_icon;
                    try {
                        if (self_ref.is_dark_mode()) {
                            string? white_cand = self_ref.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono-white.svg"));
                            if (white_cand == null) white_cand = self_ref.find_data_file(GLib.Path.build_filename("icons", "multiple-mono-white.svg"));
                            if (white_cand != null) use_path = white_cand;
                        }
                    } catch (GLib.Error e) { }
                    try {
                        var pix = new Gdk.Pixbuf.from_file_at_size(use_path, 32, 32);
                        if (pix != null) {
                            var tex = Gdk.Texture.for_pixbuf(pix);
                            self_ref.source_logo.set_from_paintable(tex);
                        } else {
                            try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { }
                        }
                    } catch (GLib.Error e) { try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { } }
                } else {
                    try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error e) { }
                }
            } catch (GLib.Error e) { }
            used_multi = true;

            try { wrapped_clear(); } catch (GLib.Error e) { }
            // Debug marker: set a distinct label so we can confirm this branch runs
            try { wrapped_set_label("Frontpage — Loading from backend (branch 1)"); } catch (GLib.Error e) { }
            try {
                // Write an entry to the debug log so we can inspect behavior when running with PAPERBOY_DEBUG
                string s = "frontpage-early-branch: preferred_sources_size=" + (prefs.preferred_sources != null ? prefs.preferred_sources.size.to_string() : "0") + "\n";
                append_debug_log(s);
            } catch (GLib.Error e) { }
            NewsSources.fetch(prefs.news_source, "frontpage", current_search_query, session, wrapped_set_label, wrapped_clear, wrapped_add);
            return;
        }
        if (prefs.preferred_sources != null && prefs.preferred_sources.size > 1) {
            // Treat The Frontpage as a multi-source view visually, but do NOT
            // let the user's preferred_sources list influence which providers
            // are queried. Instead, when viewing the special "frontpage"
            // category, simply request the backend frontpage once and present
            // the combined/multi-source UI.
            if (prefs.category == "frontpage") {
                try { self_ref.source_label.set_text("Multiple Sources"); } catch (GLib.Error e) { }
                try {
                    string? multi_icon = self_ref.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono.svg"));
                    if (multi_icon == null) multi_icon = self_ref.find_data_file(GLib.Path.build_filename("icons", "multiple-mono.svg"));
                    if (multi_icon != null) {
                        string use_path = multi_icon;
                        try {
                            if (self_ref.is_dark_mode()) {
                                string? white_cand = self_ref.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono-white.svg"));
                                if (white_cand == null) white_cand = self_ref.find_data_file(GLib.Path.build_filename("icons", "multiple-mono-white.svg"));
                                if (white_cand != null) use_path = white_cand;
                            }
                        } catch (GLib.Error e) { }
                        try {
                            var pix = new Gdk.Pixbuf.from_file_at_size(use_path, 32, 32);
                            if (pix != null) {
                                var tex = Gdk.Texture.for_pixbuf(pix);
                                self_ref.source_logo.set_from_paintable(tex);
                            } else {
                                try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { }
                            }
                        } catch (GLib.Error e) { try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { } }
                    } else {
                        try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error e) { }
                    }
                } catch (GLib.Error e) { }
                used_multi = true;

                // Clear UI and ask the backend frontpage fetcher once. NewsSources
                // will route a request with current_category == "frontpage" to
                // the Paperboy backend fetcher regardless of the NewsSource value.
                try { wrapped_clear(); } catch (GLib.Error e) { }
                NewsSources.fetch(prefs.news_source, "frontpage", current_search_query, session, wrapped_set_label, wrapped_clear, wrapped_add);
                return;
            }

            // Display a combined label and bundled monochrome logo for multi-source mode
            try {
                self_ref.source_label.set_text("Multiple Sources");
                // Try symbolic first (includes -white variants), then fall back
                // to the old location for compatibility.
                string? multi_icon = self_ref.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono.svg"));
                if (multi_icon == null) multi_icon = self_ref.find_data_file(GLib.Path.build_filename("icons", "multiple-mono.svg"));
                if (multi_icon != null) {
                    try {
                        string use_path = multi_icon;
                        try {
                            if (self_ref.is_dark_mode()) {
                                string? white_cand = self_ref.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono-white.svg"));
                                if (white_cand == null) white_cand = self_ref.find_data_file(GLib.Path.build_filename("icons", "multiple-mono-white.svg"));
                                if (white_cand != null) use_path = white_cand;
                            }
                        } catch (GLib.Error e) { }
                        var pix = new Gdk.Pixbuf.from_file_at_size(use_path, 32, 32);
                        if (pix != null) {
                            var tex = Gdk.Texture.for_pixbuf(pix);
                            self_ref.source_logo.set_from_paintable(tex);
                        } else {
                            self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic");
                        }
                    } catch (GLib.Error e) {
                        try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { }
                    }
                } else {
                    try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error e) { }
                }
            } catch (GLib.Error e) { }
            used_multi = true;

            // Build list of NewsSource enums from preferred_sources strings
            Gee.ArrayList<NewsSource> srcs = new Gee.ArrayList<NewsSource>();
            foreach (var id in prefs.preferred_sources) {
                switch (id) {
                    case "guardian": srcs.add(NewsSource.GUARDIAN); break;
                    case "reddit": srcs.add(NewsSource.REDDIT); break;
                    case "bbc": srcs.add(NewsSource.BBC); break;
                    case "nytimes": srcs.add(NewsSource.NEW_YORK_TIMES); break;
                    case "wsj": srcs.add(NewsSource.WALL_STREET_JOURNAL); break;
                    case "bloomberg": srcs.add(NewsSource.BLOOMBERG); break;
                    case "reuters": srcs.add(NewsSource.REUTERS); break;
                    case "npr": srcs.add(NewsSource.NPR); break;
                    case "fox": srcs.add(NewsSource.FOX); break;
                    default: /* ignore unknown ids */ break;
                }
            }

            // If mapping failed or produced no sources, fall back to single source
            if (srcs.size == 0) {
                NewsSources.fetch(
                    prefs.news_source,
                    prefs.category,
                    current_search_query,
                    session,
                    wrapped_set_label,
                    wrapped_clear,
                    wrapped_add
                );
            } else {
                // Filter the selected sources to those that actually support
                // the requested category. Special-case the personalized
                // My Feed mode: prefs.category == "myfeed" is not a real
                // provider category, so check per-personalized-category
                // support (e.g., Bloomberg supports markets/industries but
                // not a generic "myfeed"). This ensures Bloomberg isn't
                // excluded from the combined fetch when the user has
                // selected Bloomberg-specific personalized categories.
                var filtered = new Gee.ArrayList<NewsSource>();
                foreach (var s in srcs) {
                    try {
                        bool include = false;
                        if (is_myfeed_mode) {
                            // If no personalized categories selected, be permissive
                            if (myfeed_cats == null || myfeed_cats.length == 0) {
                                include = true;
                            } else {
                                foreach (var cat in myfeed_cats) {
                                    if (NewsSources.supports_category(s, cat)) { include = true; break; }
                                }
                            }
                        } else {
                            if (NewsSources.supports_category(s, prefs.category)) include = true;
                        }
                        if (include) filtered.add(s);
                    } catch (GLib.Error e) {
                        // If something goes wrong querying support, include the source
                        filtered.add(s);
                    }
                }

                // If filtering removed all sources (unlikely), fall back to original
                // list so we at least attempt to fetch something.
                var use_srcs = filtered.size > 0 ? filtered : srcs;

                // Clear the UI once up-front so we don't race with asynchronous
                // fetch completions (a later-completing fetch shouldn't be able
                // to wipe results added by an earlier one).
                try { wrapped_clear(); } catch (GLib.Error e) { }

                // Use a no-op clear for all individual fetches since we've
                // already cleared above. Keep a combined label while in multi
                // source mode. If we're in My Feed personalized mode, request
                // each personalized category separately and combine results.
                ClearItemsFunc no_op_clear = () => { };
                SetLabelFunc label_fn = (text) => {
                    string src_label = "Multiple Sources";
                    string display_cat = is_myfeed_mode ? "My Feed" : category_display_name_for(prefs.category);
                    // Avoid appending the generic "Multiple Sources" suffix to the
                    // left-side category title since it is redundant. Only include
                    // the source name when it is a specific source.
                    string left_label = display_cat;
                    if (src_label != "Multiple Sources") left_label = display_cat + " — " + src_label;

                    if (current_search_query.length > 0) {
                        self_ref.category_label.set_text("Search Results: \"" + current_search_query + "\" in " + left_label);
                    } else {
                        self_ref.category_label.set_text(left_label);
                    }
                };
                foreach (var s in use_srcs) {
                    if (is_myfeed_mode) {
                        foreach (var cat in myfeed_cats) {
                            NewsSources.fetch(s, cat, current_search_query, session, label_fn, no_op_clear, wrapped_add);
                        }
                    } else {
                        NewsSources.fetch(s, prefs.category, current_search_query, session, label_fn, no_op_clear, wrapped_add);
                    }
                }
            }
        } else {
            // Single-source path: keep existing behavior. Use the
            // effective source so a single selected preferred_source is
            // respected without requiring prefs.news_source to be changed.
            // Special-case: when viewing The Frontpage in single-source
            // mode, make sure we still request the backend frontpage API.
            if (prefs.category == "frontpage") {
                try { wrapped_clear(); } catch (GLib.Error e) { }
                try { wrapped_set_label("Frontpage — Loading from backend (single-source)"); } catch (GLib.Error e) { }
                try {
                    string s = "frontpage-single-source-branch: preferred_sources_size=" + (prefs.preferred_sources != null ? prefs.preferred_sources.size.to_string() : "0") + "\n";
                    append_debug_log(s);
                } catch (GLib.Error e) { }
                NewsSources.fetch(prefs.news_source, "frontpage", current_search_query, session, wrapped_set_label, wrapped_clear, wrapped_add);
                return;
            }
            if (is_myfeed_mode) {
                // Fetch each personalized category for the single effective source
                try { wrapped_clear(); } catch (GLib.Error e) { }
                SetLabelFunc label_fn = (text) => {
                    string src_label = get_source_name(effective_news_source());
                    if (current_search_query.length > 0) {
                        self_ref.category_label.set_text("Search Results: \"" + current_search_query + "\" in My Feed — " + src_label);
                    } else {
                        self_ref.category_label.set_text("My Feed — " + src_label);
                    }
                };
                foreach (var cat in myfeed_cats) {
                    NewsSources.fetch(effective_news_source(), cat, current_search_query, session, label_fn, wrapped_clear, wrapped_add);
                }
            } else {
                NewsSources.fetch(
                    effective_news_source(),
                    prefs.category,
                    current_search_query,
                    session,
                    wrapped_set_label,
                    wrapped_clear,
                    wrapped_add
                );
            }
        }
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
            add_item_shuffled(article.title, article.url, article.thumbnail_url, article.category_id, article.source_name);
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
