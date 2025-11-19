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
    public string? published { get; set; }
    
    public ArticleItem(string title, string url, string? thumbnail_url, string category_id, string? source_name = null, string? published = null) {
        this.title = title;
        this.url = url;
        this.thumbnail_url = thumbnail_url;
        this.category_id = category_id;
        this.source_name = source_name;
        this.published = published;
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
    private HeroCarousel? hero_carousel;
    private string? featured_carousel_category = null;
    private int topten_hero_count = 0; // Track hero cards for Top Ten layout
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
    public Soup.Session session;
    private GLib.Rand rng;
    public static int active_downloads = 0;
    // Increase concurrent downloads to improve initial load throughput while
    // keeping a reasonable cap to avoid overwhelming the system.
    public const int MAX_CONCURRENT_DOWNLOADS = 10;
    // During the initial loading phase we throttle concurrent downloads/decodes
    // to reduce main-loop jank (spinner animation stutter). This lower cap is
    // only used while `initial_phase` is true.
    public const int INITIAL_PHASE_MAX_CONCURRENT_DOWNLOADS = 3;
    private string current_search_query = "";
    private Gtk.Label category_label;
    private Gtk.Label category_subtitle;
    private Gtk.Label source_label;
    private Gtk.Image source_logo;
    // Holder for the category icon shown to the left of the category title
    private Gtk.Box? category_icon_holder;
    private Gtk.ListBox sidebar_list;
    private Adw.NavigationSplitView split_view;
    private Gtk.ScrolledWindow sidebar_scrolled;
    private Gtk.ToggleButton sidebar_toggle;
    private Adw.TimedAnimation? sidebar_animation;
    private Gtk.Revealer? sidebar_revealer;
    // Main content scrolled window (exposed so we can capture/restore scroll)
    private Gtk.ScrolledWindow main_scrolled;
    public NewsPreferences prefs;
    // Sidebar manager extracted to its own helper
    private SidebarManager? sidebar_manager;
    // Navigation for sliding article preview
    private Adw.NavigationView nav_view;
    private ArticlePane article_pane;
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
    public MetaCache? meta_cache;

    // In-memory image cache (URL -> Gdk.Texture) to avoid repeated decodes during a session
    // Use a small LRU cache to bound memory usage and evict old textures.
    public LruCache<string, Gdk.Texture> memory_meta_cache;
    // Separate fast cache for small thumbnails (≤64px) to improve hit rate
    public LruCache<string, Gdk.Texture> thumbnail_cache;
    // Track the last requested size for each URL so we can upgrade images
    // after the initial phase without re-scanning the UI.
    public Gee.HashMap<string, string> requested_image_sizes;
    // Pending-downloads map for request deduplication: URL -> list of Gtk.Picture targets
    public Gee.HashMap<string, Gee.ArrayList<Gtk.Picture>> pending_downloads;

    // Deferred downloads for widgets that are not yet visible: Picture -> DeferredRequest
    public Gee.HashMap<Gtk.Picture, DeferredRequest> deferred_downloads;
    public uint deferred_check_timeout_id = 0;

    // Public image handler instance (moved image/download logic)
    public ImageHandler? image_handler;

    // Data path helpers (moved to `DataPaths` util)

    // Normalize article URLs for stable mapping (delegates to UrlUtils.normalize_article_url)
    public string normalize_article_url(string url) {
        return UrlUtils.normalize_article_url(url);
    }

    // Carousel operations now handled by `HeroCarousel` in src/heroCarousel.vala
    
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
    private int articles_pending = 0;  // Articles queued but not yet rendered
    private const int INITIAL_ARTICLE_LIMIT = 25;  // Show 25 articles initially, rest behind Load More
    // Number of Local News items for which we'll fetch full-size images
    // at initial load. Items beyond this limit show placeholders until
    // the user triggers a load (e.g., scroll, click, or 'Load More').
    private const int LOCAL_NEWS_IMAGE_LOAD_LIMIT = 12;
    private Gtk.Button? load_more_button = null;
    private uint buffer_flush_timeout_id = 0;
    // Fetch sequencing token to ignore stale background fetch callbacks
    // Public read-only generation token used by async operations to determine
    // whether results are still valid for the current fetch. Exposed as a
    // public property with private setter so experiments can snapshot it.
    public uint fetch_sequence { get; private set; }
    
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
    // Error message overlay (shown when article fetching fails)
    private Gtk.Box? error_message_box = null;
    private Gtk.Image? error_icon = null;
    private Gtk.Label? error_message_label = null;
    private Gtk.Button? error_retry_button = null;
    // Initial-load gating: wait for hero (or timeout) before revealing main content
    public bool initial_phase = false;
    private bool hero_image_loaded = false;
    private uint initial_reveal_timeout_id = 0;
    // Track pending image loads during initial phase so we can keep the spinner
    // visible until all initial images are ready (with a safety timeout).
    private int pending_images = 0;
    private bool initial_items_populated = false;
    // How long to wait (ms) for initial article items/images before
    // showing the global error overlay. Increase this to give slow
    // or latent network sources more time to respond.
    private const int INITIAL_MAX_WAIT_MS = 15000; // 15s default
    // Debug log path (written when PAPERBOY_DEBUG is set)
    private string debug_log_path = "/tmp/paperboy-debug.log";

    // Delegate to centralized app debugger util for consistent behavior
    public void append_debug_log(string line) {
        try {
            AppDebugger.append_debug_log(debug_log_path, line);
        } catch (GLib.Error e) {
            // best-effort logging only
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
                    string? local_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "local-mono.svg"));
                    if (local_icon == null) local_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "local-mono.svg"));
                    if (local_icon != null) {
                        string use_path = local_icon;
                        try {
                            if (is_dark_mode()) {
                                string? white_cand = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "local-mono-white.svg"));
                                if (white_cand == null) white_cand = DataPaths.find_data_file(GLib.Path.build_filename("icons", "local-mono-white.svg"));
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
                string? multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono.svg"));
                if (multi_icon == null) multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "multiple-mono.svg"));
                if (multi_icon != null) {
                    string use_path = multi_icon;
                    try {
                        if (is_dark_mode()) {
                            string? white_cand = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono-white.svg"));
                            if (white_cand == null) white_cand = DataPaths.find_data_file(GLib.Path.build_filename("icons", "multiple-mono-white.svg"));
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

        // Same UI-only treatment for Top Ten category
        if (prefs.category == "topten") {
            try { source_label.set_text("Multiple Sources"); } catch (GLib.Error e) { }
            try {
                string? multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono.svg"));
                if (multi_icon == null) multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "multiple-mono.svg"));
                if (multi_icon != null) {
                    string use_path = multi_icon;
                    try {
                        if (is_dark_mode()) {
                            string? white_cand = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono-white.svg"));
                            if (white_cand == null) white_cand = DataPaths.find_data_file(GLib.Path.build_filename("icons", "multiple-mono-white.svg"));
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
            string? multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono.svg"));
            if (multi_icon == null) multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "multiple-mono.svg"));
            if (multi_icon != null) {
                try {
                    string use_path = multi_icon;
                    try {
                        if (is_dark_mode()) {
                            string? white_candidate = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono-white.svg"));
                            if (white_candidate == null) white_candidate = DataPaths.find_data_file(GLib.Path.build_filename("icons", "multiple-mono-white.svg"));
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
            string? logo_path = DataPaths.find_data_file(GLib.Path.build_filename("icons", logo_file));
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
        set_default_size(1400, 925);
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
        // Capacity reduced to 30 (from 50) to prevent memory bloat with multiple sources
        // With all sources enabled, this prevents caching 200+ images in RAM
        memory_meta_cache = new LruCache<string, Gdk.Texture>(30);
        // Separate thumbnail cache for small images (50 items) - improves hit rate
        thumbnail_cache = new LruCache<string, Gdk.Texture>(50);
        // Eviction callback: log evictions when PAPERBOY_DEBUG is set so we can
        // correlate evicted keys with resident memory. Keep lightweight.
        try {
            // Register a lightweight eviction callback when debugging is enabled.
            // Use an untyped lambda so Vala's parser can infer the delegate types
            // and avoid syntax errors that break compilation.
            memory_meta_cache.set_eviction_callback((k, v) => {
                try {
                    string? _dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                    if (_dbg != null && _dbg.length > 0) {
                        int w = 0; int h = 0;
                        try { w = ((Gdk.Texture) v).get_width(); } catch (GLib.Error e) { }
                        try { h = ((Gdk.Texture) v).get_height(); } catch (GLib.Error e) { }
                        append_debug_log("DEBUG: memory_meta_cache.evicted=" + k + " tex=" + w.to_string() + "x" + h.to_string());
                    }
                } catch (GLib.Error e) { }
            });
        } catch (GLib.Error e) { }
        requested_image_sizes = new Gee.HashMap<string, string>();
        pending_downloads = new Gee.HashMap<string, Gee.ArrayList<Gtk.Picture>>();
        deferred_downloads = new Gee.HashMap<Gtk.Picture, DeferredRequest>();
        // Initialize on-disk cache helper
        try {
            meta_cache = new MetaCache();
        } catch (GLib.Error e) {
            meta_cache = null;
        }
        // Initialize external image handler that owns download/cache logic
        image_handler = new ImageHandler(this);

        

        // Load CSS
        var css_provider = new Gtk.CssProvider();
        try {
            string? css_path = DataPaths.find_data_file("style.css");
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

        // Build header bars for sidebar and content (will be added to NavigationPages)
        // Sidebar headerbar with app icon and title
        var sidebar_header = new Adw.HeaderBar();
        sidebar_header.add_css_class("flat");
        
        // App icon for sidebar (left corner)
        var sidebar_icon = new Gtk.Image.from_icon_name("paperboy");
        sidebar_icon.set_pixel_size(SIDEBAR_ICON_SIZE);
        sidebar_header.pack_start(sidebar_icon);
        
        // App title for sidebar (centered)
        var sidebar_title = new Gtk.Label("Paperboy");
        sidebar_title.add_css_class("title");
        sidebar_header.set_title_widget(sidebar_title);
        
        // Content headerbar with app branding and controls
        var content_header = new Adw.HeaderBar();
        
        // Sidebar toggle button for NavigationSplitView
        var sidebar_toggle = new Gtk.ToggleButton();
        sidebar_toggle.set_icon_name("sidebar-show-symbolic");
        sidebar_toggle.set_active(true); // Start with sidebar shown
        sidebar_toggle.set_tooltip_text("Toggle Sidebar");
        content_header.pack_start(sidebar_toggle);

        // Search bar in the center
        var search_container = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        
        var search_entry = new Gtk.SearchEntry();
        search_entry.set_placeholder_text("Search News for Keywords...");
        search_entry.set_max_width_chars(60);
        search_container.append(search_entry);
        
        content_header.set_title_widget(search_container);
        
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
        content_header.pack_end(refresh_btn);
        
        // Add hamburger menu
        var menu = new Menu();
        menu.append("Preferences", "app.change-source");
        menu.append("Set User Location", "app.set-location");
        menu.append("About Paperboy", "app.about");
        
        var menu_button = new Gtk.MenuButton();
        menu_button.set_icon_name("open-menu-symbolic");
        menu_button.set_menu_model(menu);
        menu_button.set_tooltip_text("Main Menu");
        content_header.pack_end(menu_button);
        sidebar_list = new Gtk.ListBox();
        sidebar_list.add_css_class("navigation-sidebar");
        sidebar_list.set_selection_mode(SelectionMode.SINGLE);
        sidebar_list.set_activate_on_single_click(true);

    // Create SidebarManager to encapsulate building rows and icon holders
    sidebar_manager = new SidebarManager(this, sidebar_list, (cat, title) => {
        try {
            string? _dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
            if (_dbg != null && _dbg.length > 0) append_debug_log("sidebar_activate_cb: category=" + cat + " title=" + title);
        } catch (GLib.Error e) { }
        
        // Check if the selected category is supported by at least one source
        // In multi-source mode, allow if ANY source supports it
        // In single-source mode, check that specific source
        bool category_supported = false;
        if (prefs.preferred_sources != null && prefs.preferred_sources.size > 1) {
            // Multi-source: check if at least one source supports this category
            foreach (var id in prefs.preferred_sources) {
                NewsSource src = NewsSource.GUARDIAN;
                switch (id) {
                    case "guardian": src = NewsSource.GUARDIAN; break;
                    case "reddit": src = NewsSource.REDDIT; break;
                    case "bbc": src = NewsSource.BBC; break;
                    case "nytimes": src = NewsSource.NEW_YORK_TIMES; break;
                    case "wsj": src = NewsSource.WALL_STREET_JOURNAL; break;
                    case "bloomberg": src = NewsSource.BLOOMBERG; break;
                    case "reuters": src = NewsSource.REUTERS; break;
                    case "npr": src = NewsSource.NPR; break;
                    case "fox": src = NewsSource.FOX; break;
                }
                if (NewsSources.supports_category(src, cat)) {
                    category_supported = true;
                    break;
                }
            }
        } else {
            // Single source: check that specific source
            NewsSource current_source = effective_news_source();
            category_supported = NewsSources.supports_category(current_source, cat);
        }
        
        if (!category_supported) {
            // Record a short debug trace when falling back to frontpage
                // Removed temporary sidebar activation disk logging used during
                // diagnostics. Keep behavior: fall back to frontpage when the
                // selected category is unsupported.
            cat = "frontpage";
        }
        
        prefs.category = cat;
        try { update_category_icon(); } catch (GLib.Error e) { }
        prefs.save_config();
        try { update_local_news_ui(); } catch (GLib.Error e) { }
        try {
            if (cat == "frontpage") { fetch_news(); return; }
        } catch (GLib.Error e) { }
        Idle.add(() => {
            try { prefs.category = cat; prefs.save_config(); } catch (GLib.Error e) { }
            try { fetch_news(); } catch (GLib.Error e) { }
            try { update_personalization_ui(); } catch (GLib.Error e) { }
            return false;
        });
    });
    sidebar_manager.rebuild_rows();

    sidebar_scrolled = new Gtk.ScrolledWindow();
        sidebar_scrolled.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        sidebar_scrolled.set_child(sidebar_list);

    // Wrap sidebar in ToolbarView with headerbar
    var sidebar_toolbar = new Adw.ToolbarView();
    sidebar_toolbar.add_top_bar(sidebar_header);
    sidebar_toolbar.set_content(sidebar_scrolled);

    // Wrap sidebar in a Revealer for smooth slide animations
    sidebar_revealer = new Gtk.Revealer();
    sidebar_revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_RIGHT);
    sidebar_revealer.set_transition_duration(200);
    sidebar_revealer.set_child(sidebar_toolbar);
    sidebar_revealer.set_reveal_child(true);

    // Create NavigationPage for sidebar content
    var sidebar_page = new Adw.NavigationPage(sidebar_revealer, "Categories");

    // Wrap content in a NavigationPage for NavigationSplitView
    // We need to create the content page after setting up root_overlay
    
    // Build main content UI in a separate helper object so the window
    // constructor stays concise. ContentView constructs the widgets and
    // exposes them; we then wire them into the existing NewsWindow fields.
    var content_view = new ContentView(prefs);
    category_label = content_view.category_label;
    category_subtitle = content_view.category_subtitle;
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
    error_message_box = content_view.error_message_box;
    error_icon = content_view.error_icon;
    error_message_label = content_view.error_message_label;
    error_retry_button = content_view.error_retry_button;

    // Split view: sidebar + content with adaptive collapsible sidebar
    split_view = new Adw.NavigationSplitView();
    split_view.set_min_sidebar_width(266);
    split_view.set_max_sidebar_width(266);
    split_view.set_sidebar(sidebar_page);
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
    // Make the slide-out preview slightly wider (+5% from the trimmed size)
    // User requested a small increase for better legibility.
    article_preview_split.set_max_sidebar_width(420);
    article_preview_split.set_min_sidebar_width(294);
    article_preview_split.set_sidebar_width_fraction(0.29);
    article_preview_split.set_collapsed(true); // Always overlay, never push content
    article_preview_split.set_enable_show_gesture(false); // Disable swipe to prevent accidental opens
    article_preview_split.set_enable_hide_gesture(true);  // Allow swipe to close

    // Defensive: if the OverlaySplitView hides the sidebar via a gesture
    // or internal handler (e.g. built-in Escape handling), ensure the
    // dim overlay is also cleared and preview_closed is invoked so the
    // main view is restored consistently.
    article_preview_split.notify["show-sidebar"].connect(() => {
        try {
            if (!article_preview_split.get_show_sidebar()) {
                try {
                    if (last_previewed_url != null && last_previewed_url.length > 0) {
                        preview_closed(last_previewed_url);
                    } else {
                        if (dim_overlay != null) dim_overlay.set_visible(false);
                    }
                } catch (GLib.Error e) {
                    try { if (dim_overlay != null) dim_overlay.set_visible(false); } catch (GLib.Error _e) { }
                }
            }
        } catch (GLib.Error e) { }
    });
    
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
    // Only treat clicks on the dim overlay as a request to close the
    // preview when they occur outside the preview sidebar itself. If the
    // user clicks inside the sidebar (the preview panel), ignore the
    // click so the preview's internal controls can handle it.
    dim_click.pressed.connect((n_press, x, y) => {
        try {
            // If the sidebar is visible, compute its approximate left edge
            // and ignore clicks that fall inside it. Use the window width
            // and the preview wrapper width to compute the sidebar region.
            if (article_preview_split.get_show_sidebar()) {
                int win_w = 0;
                int sidebar_w = 0;
                try { win_w = this.get_width(); } catch (GLib.Error e) { win_w = 0; }
                try { sidebar_w = preview_wrapper.get_width(); } catch (GLib.Error e) { sidebar_w = 0; }
                if (win_w > 0 && sidebar_w > 0) {
                    double sidebar_left = (double)(win_w - sidebar_w);
                    if (x >= sidebar_left) {
                        // Click occurred inside the preview panel — ignore it
                        return;
                    }
                }
            }

            article_preview_split.set_show_sidebar(false);
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
        } catch (GLib.Error e) {
            // Best-effort: if anything goes wrong, hide the dim overlay
            try { dim_overlay.set_visible(false); } catch (GLib.Error _e) { }
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

    // Add error message overlay and wire up retry button
    error_retry_button.clicked.connect(() => {
        try { 
            error_message_box.set_visible(false);
            fetch_news(); 
        } catch (GLib.Error e) { }
    });
    root_overlay.add_overlay(error_message_box);

    // Wrap root_overlay with article preview split
    article_preview_split.set_content(root_overlay);
    
    // Wrap content in ToolbarView with headerbar
    var content_toolbar = new Adw.ToolbarView();
    content_toolbar.add_top_bar(content_header);
    content_toolbar.set_content(article_preview_split);
    
    // Create NavigationPage for main content
    var content_page = new Adw.NavigationPage(content_toolbar, "Content");

    // Set sidebar and content for NavigationSplitView
    split_view.set_sidebar(sidebar_page);
    split_view.set_content(content_page);
    // Keep split view always uncollapsed - we control visibility via Revealer
    split_view.set_collapsed(false);
    split_view.set_show_content(true);
    
    // Enable smooth transitions for sidebar collapse/expand
    // The NavigationSplitView uses spring animations by default in libadwaita
    
    // Wire up sidebar toggle button to control sidebar visibility
    sidebar_toggle.toggled.connect(() => {
        bool active = sidebar_toggle.get_active();
        split_view.set_collapsed(!active);
        sidebar_revealer.set_reveal_child(active);
    });
    
    content_page.set_can_pop(false); // Prevent accidental navigation away

    // NavigationSplitView handles sidebar toggle automatically with built-in button
        // Listen to show-content and collapsed changes to adjust content size
        // show-content=true means content is visible (sidebar hidden when collapsed)
        // show-content=false means sidebar is visible (when collapsed)
        split_view.notify["collapsed"].connect(() => {
            // When collapsed state changes, adjust main content container
            bool collapsed = split_view.get_collapsed();
            bool showing_content = split_view.get_show_content();
            // Sidebar is effectively visible when not collapsed OR when collapsed but showing sidebar
            bool sidebar_visible = !collapsed || !showing_content;
            update_main_content_size(sidebar_visible);
        });
        
        split_view.notify["show-content"].connect(() => {
            // When show-content changes (user navigates between sidebar/content in collapsed mode)
            bool collapsed = split_view.get_collapsed();
            bool showing_content = split_view.get_show_content();
            bool sidebar_visible = !collapsed || !showing_content;
            update_main_content_size(sidebar_visible);
        });
        
        // Initialize main content container size for initial state
        update_main_content_size(true);

        set_content(split_view);

        session = new Soup.Session();
        // Optimize session for better performance
        session.max_conns = 10; // Allow more concurrent connections
        session.max_conns_per_host = 4; // Limit per host to prevent overwhelming servers
        session.timeout = 15; // Default timeout

        // Initialize article window
        article_pane = new ArticlePane(nav_view, session, this);
        article_pane.set_preview_overlay(article_preview_split, article_preview_content);

        // Add keyboard event controller for closing article preview with Escape
        var key_controller = new Gtk.EventControllerKey();
        key_controller.key_pressed.connect((keyval, keycode, state) => {
            // Escape: close preview
            if (keyval == Gdk.Key.Escape && article_preview_split.get_show_sidebar()) {
                // Close the preview pane visually first
                article_preview_split.set_show_sidebar(false);
                try {
                    if (last_previewed_url != null && last_previewed_url.length > 0) {
                        preview_closed(last_previewed_url);
                    } else {
                        dim_overlay.set_visible(false);
                    }
                } catch (GLib.Error e) {
                    // Ensure overlay is hidden even if preview_closed raised an error
                    try { dim_overlay.set_visible(false); } catch (GLib.Error _e) { }
                }

                // Defensive: always ensure the dim overlay is hidden after handling Escape.
                try { if (dim_overlay != null) dim_overlay.set_visible(false); } catch (GLib.Error e) { }

                return true;
            }

            // Debug-only shortcuts: require PAPERBOY_DEBUG env var to be set
            try {
                string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                if (dbg != null && dbg.length > 0) {
                    // Ctrl+Shift+L -> dump cache stats (Ctrl+Shift+D conflicts with GTK inspector)
                    bool ctrl = (state & Gdk.ModifierType.CONTROL_MASK) != 0;
                    bool shift = (state & Gdk.ModifierType.SHIFT_MASK) != 0;
                    if (ctrl && shift && keyval == Gdk.Key.L) {
                        try { debug_dump_cache_stats(); } catch (GLib.Error e) { }
                        return true;
                    }
                    // Ctrl+Shift+K -> clear memory cache
                    if (ctrl && shift && keyval == Gdk.Key.K) {
                        try {
                            memory_meta_cache.clear();
                            append_debug_log("DEBUG: memory_meta_cache cleared via keyboard");
                        } catch (GLib.Error e) { }
                        return true;
                    }
                }
            } catch (GLib.Error e) { }

            return false;
        });
        nav_view.add_controller(key_controller);

        // Add click event controller to main content area to close preview when clicking outside
        var main_click_controller = new Gtk.GestureClick();
        // Similar to the dim overlay, ignore clicks that occur inside the
        // preview sidebar area so interactions within the preview don't
        // immediately close it.
        main_click_controller.pressed.connect((n_press, x, y) => {
            // Only close if article preview is open
            if (!article_preview_split.get_show_sidebar()) return;
            try {
                if (article_preview_split.get_show_sidebar()) {
                    int win_w = 0;
                    int sidebar_w = 0;
                    try { win_w = this.get_width(); } catch (GLib.Error e) { win_w = 0; }
                    try { sidebar_w = preview_wrapper.get_width(); } catch (GLib.Error e) { sidebar_w = 0; }
                    if (win_w > 0 && sidebar_w > 0) {
                        double sidebar_left = (double)(win_w - sidebar_w);
                        if (x >= sidebar_left) {
                            // Click is inside the preview panel — ignore it
                            return;
                        }
                    }
                }

                article_preview_split.set_show_sidebar(false);
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
            } catch (GLib.Error e) { 
                try { dim_overlay.set_visible(false); } catch (GLib.Error _e) { }
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
                    try { if (sidebar_manager != null) sidebar_manager.update_icons_for_theme(); } catch (GLib.Error e) { }
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
        if (article_preview_split != null && article_preview_split.get_show_sidebar()) {
            article_preview_split.set_show_sidebar(false);
        }
    }

    // Debug helper: dump memory cache stats and counts of widget-held textures.
    // This is a best-effort diagnostic and is intended to be called only when
    // PAPERBOY_DEBUG is set. It logs to the debug log path via append_debug_log().
    public void debug_dump_cache_stats() {
        try {
            int cache_size = 0;
            try { cache_size = memory_meta_cache.size(); } catch (GLib.Error e) { cache_size = -1; }
            append_debug_log("DEBUG: memory_meta_cache.size=" + cache_size.to_string());

            // If the cache supports key enumeration, dump each entry and any
            // texture dimensions we can obtain. This helps correlate which
            // textures are retained in the cache with resident memory.
            try {
                // memory_meta_cache is typically LruCache<string, Gdk.Texture>
                var keys = memory_meta_cache.keys();
                append_debug_log("DEBUG: memory_meta_cache.keys_count=" + keys.size.to_string());
                foreach (var k in keys) {
                    try {
                        var v = memory_meta_cache.get(k);
                        if (v is Gdk.Texture) {
                            var tex = (Gdk.Texture) v;
                            int w = 0;
                            int h = 0;
                            try { w = tex.get_width(); } catch (GLib.Error e) { }
                            try { h = tex.get_height(); } catch (GLib.Error e) { }
                            append_debug_log("DEBUG: cache_entry: " + k.to_string() + " => texture " + w.to_string() + "x" + h.to_string());
                        } else {
                            append_debug_log("DEBUG: cache_entry: " + k.to_string() + " => non-texture");
                        }
                    } catch (GLib.Error e) {
                        // best-effort per-entry; continue
                        try { append_debug_log("DEBUG: cache_entry_error for " + k.to_string()); } catch (GLib.Error _e) { }
                    }
                }
            } catch (GLib.Error e) {
                // ignore diagnostic failures
            }
            
            // Count unique textures referenced by registered Picture widgets
            int widget_tex_count = 0;
            try {
                var set = new Gee.HashSet<Gdk.Texture>();
                foreach (var kv in url_to_picture.entries) {
                    try {
                        var pic = kv.value;
                        var p = pic.get_paintable();
                        if (p is Gdk.Texture) {
                            set.add((Gdk.Texture)p);
                        }
                    } catch (GLib.Error e) { }
                }
                widget_tex_count = set.size;
            } catch (GLib.Error e) { widget_tex_count = -1; }

            append_debug_log("DEBUG: unique_textures_referenced_by_widgets=" + widget_tex_count.to_string());

            // Report total registered pictures and pending downloads
            int pictures_registered = 0;
            try { pictures_registered = url_to_picture.size; } catch (GLib.Error e) { pictures_registered = -1; }
            int pending = 0;
            try { pending = pending_downloads.size; } catch (GLib.Error e) { pending = -1; }
            append_debug_log("DEBUG: url_to_picture.count=" + pictures_registered.to_string() + " pending_downloads.count=" + pending.to_string());
        } catch (GLib.Error e) {
            // best-effort only
        }
    }

    // Register a picture for a normalized URL and ensure we remove the
    // mapping when the picture is destroyed. This avoids `url_to_picture`
    // retaining removed widgets.
    private void register_picture_for_url(string normalized, Gtk.Picture pic) {
        try { url_to_picture.set(normalized, pic); } catch (GLib.Error e) { }
        try {
            pic.destroy.connect(() => {
                try {
                    Gtk.Picture? cur = null;
                    try { cur = url_to_picture.get(normalized); } catch (GLib.Error e) { cur = null; }
                    if (cur == pic) {
                        try { url_to_picture.remove(normalized); } catch (GLib.Error e) { }
                        try { append_debug_log("DEBUG: url_to_picture removed mapping for " + normalized + " on picture destroy"); } catch (GLib.Error e) { }
                    }
                } catch (GLib.Error e) { }
            });
        } catch (GLib.Error e) { }
    }

    // Register a card/hero widget for a normalized URL and ensure the
    // mapping is removed when the widget is destroyed. Mirrors the
    // register_picture_for_url behaviour to avoid retaining dead widgets
    // in `url_to_card`.
    private void register_card_for_url(string normalized, Gtk.Widget card) {
        try { url_to_card.set(normalized, card); } catch (GLib.Error e) { }
        try {
            card.destroy.connect(() => {
                try {
                    Gtk.Widget? cur = null;
                    try { cur = url_to_card.get(normalized); } catch (GLib.Error e) { cur = null; }
                    if (cur == card) {
                        try { url_to_card.remove(normalized); } catch (GLib.Error e) { }
                        try { append_debug_log("DEBUG: url_to_card removed mapping for " + normalized + " on widget destroy"); } catch (GLib.Error e) { }
                    }
                } catch (GLib.Error e) { }
            });
        } catch (GLib.Error e) { }
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
            var hdr = CategoryIcons.create_category_header_icon(prefs.category, 36);
            if (hdr != null) category_icon_holder.append(hdr);
        } catch (GLib.Error e) { }
    }

    // Category header icon creation moved to `src/utils/category_icons.vala`.
    // Use CategoryIcons.create_category_header_icon(cat, size) instead.

    // Centralized content-header updater.
    // This enforces the rule: the content header shows only the category
    // icon and the category display name. When a search is active the
    // header becomes: Search Results: "<query>" in <Category Display Name>.
    // This helper is safe to call from worker threads because it schedules
    // the actual UI updates on the main loop via Idle.add.
    private void update_content_header() {
        string disp = category_display_name_for(prefs.category);
        string label_text;
        try {
            if (current_search_query != null && current_search_query.length > 0)
                label_text = "Search Results: \"" + current_search_query + "\" in " + disp;
            else
                label_text = disp;
        } catch (GLib.Error e) {
            // Fallback conservatively
            label_text = disp;
        }
        // Schedule on main loop to guarantee safe GTK access.
        Idle.add(() => {
            try { if (category_label != null) category_label.set_text(label_text); } catch (GLib.Error e) { }
            try { update_category_icon(); } catch (GLib.Error e) { }
            // Also ensure the top-right source badge reflects the current
            // source configuration (single source -> logo+name, multiple
            // sources or frontpage -> multi-source badge). Call the
            // updater on the main loop to keep UI changes centralized.
            try { update_source_info(); } catch (GLib.Error e) { }
            return false;
        });
    }

    // Synchronous variant intended to be called from the main thread when
    // we need the header to be painted immediately before constructing
    // any article/hero widgets. This performs the same updates as
    // update_content_header but runs them synchronously (no Idle.add).
    private void update_content_header_now() {
        string disp = category_display_name_for(prefs.category);
        string label_text;
        try {
            if (current_search_query != null && current_search_query.length > 0)
                label_text = "Search Results: \"" + current_search_query + "\" in " + disp;
            else
                label_text = disp;
        } catch (GLib.Error e) {
            label_text = disp;
        }

        try { if (category_label != null) category_label.set_text(label_text); } catch (GLib.Error e) { }
        
        // Show subtitle for Top Ten
        if (prefs.category == "topten") {
            try {
                if (category_subtitle != null) {
                    category_subtitle.set_text("TOP STORIES RIGHT NOW");
                    category_subtitle.set_visible(true);
                }
            } catch (GLib.Error e) { }
        } else {
            try {
                if (category_subtitle != null) category_subtitle.set_visible(false);
            } catch (GLib.Error e) { }
        }
        
        try { update_category_icon(); } catch (GLib.Error e) { }
        // Ensure the top-right source badge is in sync with the current
        // source selection. This will show either the single-source
        // logo+name or the multiple-sources badge for aggregated views.
        try { update_source_info(); } catch (GLib.Error e) { }
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
        // NavigationSplitView handles sidebar visibility automatically
        // based on collapsed state and user interaction
    // Rebuild rows to reflect source-specific categories (e.g., Bloomberg)
    try { if (sidebar_manager != null) sidebar_manager.rebuild_rows(); } catch (GLib.Error e) { }
    }

    // SidebarManager handles sidebar icon updates on theme changes now.

    public string category_display_name_for(string cat) {
        switch (cat) {
            case "topten": return "Top Ten";
            case "frontpage": return "Front Page";
            case "myfeed": return "My Feed";
            case "local_news": return "Local News";
            case "general": return "World News";
            case "us": return "US News";
            case "technology": return "Technology";
            case "business": return "Business";
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
        // Debug: log all add_item calls for topten
        try {
            string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
            if (dbg != null && dbg.length > 0 && prefs.category == "topten") {
                append_debug_log("add_item called for TOPTEN: category_id=" + category_id + " title=" + title);
            }
        } catch (GLib.Error e) { }
        
        // ONLY apply limit when user is VIEWING a specific category (world, sports, etc.)
        // Do NOT limit for: frontpage, topten, all, myfeed, local_news
        bool viewing_limited_category = (
            prefs.category == "general" || 
            prefs.category == "us" || 
            prefs.category == "sports" || 
            prefs.category == "science" || 
            prefs.category == "health" || 
            prefs.category == "technology" || 
            prefs.category == "business" || 
            prefs.category == "entertainment" || 
            prefs.category == "politics" ||
            prefs.category == "markets" ||
            prefs.category == "industries" ||
            prefs.category == "economics" ||
            prefs.category == "wealth" || 
            prefs.category == "green"
            || prefs.category == "local_news"
        );
        
        if (viewing_limited_category) {
            // Use lock to make check-and-increment atomic across multiple sources
            lock (articles_shown) {
                try {
                    string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                    if (dbg != null && dbg.length > 0) {
                        append_debug_log("add_item LOCK: shown=" + articles_shown.to_string() + " limit=" + INITIAL_ARTICLE_LIMIT.to_string() + " title=" + title);
                    }
                } catch (GLib.Error e) { }
                
                if (articles_shown >= INITIAL_ARTICLE_LIMIT && load_more_button == null) {
                    try {
                        string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                        if (dbg != null && dbg.length > 0) {
                            append_debug_log("add_item BLOCKING at " + articles_shown.to_string() + ": " + title);
                        }
                    } catch (GLib.Error e) { }
                    // Queue this article for Load More instead of displaying it
                    if (remaining_articles == null) {
                        remaining_articles = new ArticleItem[1];
                        remaining_articles[0] = new ArticleItem(title, url, thumbnail_url, category_id, source_name);
                    } else {
                        // Append to existing array
                        var new_arr = new ArticleItem[remaining_articles.length + 1];
                        for (int i = 0; i < remaining_articles.length; i++) {
                            new_arr[i] = remaining_articles[i];
                        }
                        new_arr[remaining_articles.length] = new ArticleItem(title, url, thumbnail_url, category_id, source_name);
                        remaining_articles = new_arr;
                    }
                    show_load_more_button();
                    return; // Don't add to UI, save for Load More
                }
            }
        }
        
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
        // Normalize the article URL for stable mapping. Be defensive: if
        // normalization fails or returns null/empty, fall back to the raw
        // URL (or an empty string) so we never pass a NULL key into Gee.
        string normalized = "";
        try {
            if (url != null) normalized = normalize_article_url(url);
        } catch (GLib.Error e) {
            // Best-effort fallback
            normalized = url != null ? url : "";
        }

        // Guard against an uninitialized map (shouldn't happen in normal
        // constructor flow) and avoid passing a NULL key into Gee which can
        // cause a crash. Use a safe empty-string key if needed.
        if (normalized == null) normalized = "";

        Gtk.Picture? existing = null;
        if (url_to_picture != null) {
            try { existing = url_to_picture.get(normalized); } catch (GLib.Error e) { existing = null; }
        }

        // Fallback: try fuzzy match (strip/trailing differences or query variants)
        if (existing == null && url_to_picture != null && normalized.length > 0) {
            foreach (var kv in url_to_picture.entries) {
                string k = kv.key;
                if (k == null) continue;
                // Match when one URL is a suffix of the other (same article, different params)
                // Guard against empty strings to avoid surprising behaviour.
                if (k.length > 0 && (k.has_suffix(normalized) || normalized.has_suffix(k))) {
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
                image_handler.load_image_async(existing, thumbnail_url, target_w, target_h);
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
            // Treat the special 'frontpage' and 'topten' views as aggregators: accept
            // articles of any category when the user is viewing these multi-source views.
            // This allows frontpage/topten fetchers to supply per-article category
            // metadata (for chips) without causing the UI to drop items.
            if (view_category != "all" && view_category != "frontpage" && view_category != "topten" && view_category != category_id) {
                // Drop stale article for a different category
                if (debug_enabled()) warning("Dropping stale article for category %s (view=%s)", category_id, view_category);
                return;
            }
        }

        // Enforce that articles originate from the user's selected sources.
        // For the special aggregated "frontpage" and "topten" categories, do NOT enforce
        // per-source filtering because the backend intentionally returns
        // mixed-source results for these multi-source views.
        // Map the inferred source to the preference id strings and drop any
        // articles that come from sources the user hasn't enabled. This
        // protects against fetchers that may return cross-domain results.
        // Skip filtering for frontpage and topten views
        if (prefs.category != "frontpage" && prefs.category != "topten" && category_id != "frontpage" && category_id != "topten" && prefs.preferred_sources != null && prefs.preferred_sources.size > 0) {
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
                    try {
                        string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                        if (dbg != null && dbg.length > 0) {
                            append_debug_log("add_item DROPPED (source filter): view=" + prefs.category + " source=" + article_src_id + " title=" + title);
                            if (prefs.category == "topten") {
                                append_debug_log("TOPTEN ARTICLE DROPPED BY SOURCE FILTER: " + title);
                            }
                        }
                    } catch (GLib.Error e) { }
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
                    try {
                        string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                        if (dbg != null && dbg.length > 0) {
                            append_debug_log("add_item DROPPED (Bloomberg filter): view=" + prefs.category + " category=" + category_id + " title=" + title);
                            if (prefs.category == "topten") {
                                append_debug_log("TOPTEN ARTICLE DROPPED BY BLOOMBERG FILTER: " + title);
                            }
                        }
                    } catch (GLib.Error e) { }
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
            
            // Block lifestyle articles for sources that don't provide them
            // (Reddit, BBC, Reuters don't have lifestyle content)
            // This applies in both single-source and multi-source modes
            if (category_id == "lifestyle") {
                NewsSource article_src = infer_source_from_url(url);
                if (article_src == NewsSource.REDDIT || article_src == NewsSource.BBC || article_src == NewsSource.REUTERS) {
                    if (debug_enabled()) {
                        warning("Dropping lifestyle article from source that doesn't provide lifestyle: source=%s title=%s", get_source_name(article_src), title);
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
            // For specific categories, add directly but also store in buffer
            // so article previews can retrieve source names and metadata
            var item = new ArticleItem(title, url, thumbnail_url, category_id, final_source_name);
            article_buffer.add(item);
            
            try {
                string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                if (dbg != null && dbg.length > 0 && prefs.category == "topten") {
                    append_debug_log("TOPTEN: About to call add_item_immediate_to_column for: " + title);
                }
            } catch (GLib.Error e) { }
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
        // No article limit for "all" category - add everything
        int articles_added = 0;
        for (int i = 0; i < articles.length; i++) {
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
    
    private void add_item_immediate_to_column(string title, string url, string? thumbnail_url, string category_id, int forced_column = -1, string? original_category = null, string? source_name = null, bool bypass_limit = false) {
    // Debug: log for topten
    try {
        string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
        if (dbg != null && dbg.length > 0 && prefs.category == "topten") {
            append_debug_log("add_item_immediate_to_column called for TOPTEN: category_id=" + category_id + " title=" + title);
        }
    } catch (GLib.Error e) { }
    
    // Check article limit FIRST for ALL categories (not just "all")
    // Debug: log incoming per-article source_name and URL when debugging is enabled
    try {
        string? _dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
        if (_dbg != null && _dbg.length > 0) {
            string in_src = source_name != null ? source_name : "<null>";
            append_debug_log("add_item_immediate_to_column: incoming_source_name=" + in_src + " url=" + (url != null ? url : "<null>") + " category=" + category_id + " title=" + title);
        }
    } catch (GLib.Error e) { }
    
        // Check if we're viewing a limited category and enforce the limit
        // Use original_category if provided (for when category is temporarily overridden)
        string check_category = original_category ?? prefs.category;
        
        try {
            string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
            if (dbg != null && dbg.length > 0) {
                append_debug_log("add_item_immediate_to_column: prefs.category=" + prefs.category + " original_category=" + (original_category != null ? original_category : "null") + " check_category=" + check_category + " article_cat=" + category_id);
            }
        } catch (GLib.Error e) { }
        
        bool is_limited_category = (
            check_category == "general" || 
            check_category == "us" || 
            check_category == "sports" || 
            check_category == "science" || 
            check_category == "health" || 
            check_category == "technology" || 
            check_category == "business" || 
            check_category == "entertainment" || 
            check_category == "politics" ||
            check_category == "markets" ||
            check_category == "industries" ||
            check_category == "economics" ||
            check_category == "wealth" ||
            check_category == "green"
            || check_category == "local_news"
        );
        
        try {
            string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
            if (dbg != null && dbg.length > 0) {
                append_debug_log("add_item_immediate_to_column: check_category=" + check_category + " is_limited=" + (is_limited_category ? "YES" : "NO") + " title=" + title);
            }
        } catch (GLib.Error e) { }
        
        if (is_limited_category && !bypass_limit) {
            // CRITICAL: Lock to make check-and-increment atomic
            lock (articles_shown) {
                try {
                    string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                    if (dbg != null && dbg.length > 0) {
                        append_debug_log("add_item_immediate_to_column LOCK: shown=" + articles_shown.to_string() + " limit=" + INITIAL_ARTICLE_LIMIT.to_string() + " category=" + check_category + " button=" + (load_more_button == null ? "null" : "EXISTS") + " title=" + title);
                    }
                } catch (GLib.Error e) { }
                
                if (articles_shown >= INITIAL_ARTICLE_LIMIT) {
                    try {
                        string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                        if (dbg != null && dbg.length > 0) {
                            append_debug_log("add_item_immediate_to_column BLOCKING at " + articles_shown.to_string() + ": " + title);
                        }
                    } catch (GLib.Error e) { }
                    
                    // Validate parameters before creating ArticleItem
                    if (title == null || url == null) {
                        return; // Skip invalid articles
                    }
                    
                    // Queue this article for Load More instead of displaying it
                    if (remaining_articles == null) {
                        remaining_articles = new ArticleItem[1];
                        remaining_articles[0] = new ArticleItem(title, url, thumbnail_url, category_id, source_name);
                    } else {
                        // Append to existing array
                        var new_arr = new ArticleItem[remaining_articles.length + 1];
                        for (int i = 0; i < remaining_articles.length; i++) {
                            new_arr[i] = remaining_articles[i];
                        }
                        new_arr[remaining_articles.length] = new ArticleItem(title, url, thumbnail_url, category_id, source_name);
                        remaining_articles = new_arr;
                    }
                    
                    // Show button only if it doesn't exist yet
                    if (load_more_button == null) {
                        show_load_more_button();
                    }
                    return; // Don't add to UI, save for Load More
                }
                
                // Increment immediately to reserve slot
                articles_shown++;
                
                try {
                    string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                    if (dbg != null && dbg.length > 0) {
                        append_debug_log("add_item_immediate_to_column INCREMENTED to " + articles_shown.to_string() + " category=" + check_category + " title=" + title);
                    }
                } catch (GLib.Error e) { }
            }
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
        // For Top Ten, select first 2 items as heroes
        // For specific categories, keep the first item as hero for consistency
        bool should_be_hero = false;
        if (prefs.category == "topten") {
            // Top Ten: first 2 articles should be heroes
            should_be_hero = (topten_hero_count < 2);
        } else if (!featured_used) {
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
            // For Top Ten: use smaller hero heights to fit everything in viewport
            int max_hero_height = (prefs.category == "topten") ? 280 : 350;
            int default_hero_w = estimate_content_width();
            int default_hero_h = (prefs.category == "topten") ? 210 : 250;

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
                image_handler.load_image_async(hero_card.image, thumbnail_url, default_hero_w * multiplier, default_hero_h * multiplier);
                hero_requests.set(hero_card.image, new HeroRequest(thumbnail_url, default_hero_w * multiplier, default_hero_h * multiplier, multiplier));
                string _norm = normalize_article_url(url);
                register_picture_for_url(_norm, hero_card.image);
                normalized_to_url.set(_norm, url);
                register_card_for_url(_norm, hero_card.root);
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
            hero_card.activated.connect((s) => { try { article_pane.show_article_preview(title, url, thumbnail_url, category_id); } catch (GLib.Error e) { } });

            // Top Ten: Add up to 2 hero cards side-by-side directly to hero_container
            // Other categories: Use carousel with up to 5 slides
            if (prefs.category == "topten") {
                if (topten_hero_count < 2) {
                    hero_container.append(hero_card.root);
                    topten_hero_count++;
                    featured_used = true;
                    if (initial_phase) mark_initial_items_populated();
                    return;
                }
                // If we already have 2 heroes, fall through to add as regular card
            } else {
                // Standard carousel behavior for other categories
                if (featured_carousel_items == null) featured_carousel_items = new Gee.ArrayList<ArticleItem>();
                if (hero_carousel == null) hero_carousel = new HeroCarousel(featured_box);
                featured_carousel_items.add(new ArticleItem(title, url, thumbnail_url, category_id, source_name));
                featured_carousel_category = category_id;

                hero_carousel.add_initial_slide(hero_card.root);
                hero_carousel.start_timer(5);

                featured_used = true;
                if (initial_phase) mark_initial_items_populated();
                return;
            }
        }

            // If a featured carousel is active and we haven't reached 5 slides yet,
            // collect additional articles that match the featured category and add
            // them as slides to the carousel instead of rendering normal cards.
            // Skip this for Top Ten since it uses side-by-side heroes, not carousel
            if (prefs.category != "topten" && hero_carousel != null && featured_carousel_items != null &&
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
                image_handler.load_image_async(slide_image, thumbnail_url, default_w * multiplier, default_h * multiplier);
                hero_requests.set(slide_image, new HeroRequest(thumbnail_url, default_w * multiplier, default_h * multiplier, multiplier));
                string _norm = normalize_article_url(url);
                register_picture_for_url(_norm, slide_image);
                normalized_to_url.set(_norm, url);
                // Map slide to URL for viewed badge support
                register_card_for_url(_norm, slide);
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
                article_pane.show_article_preview(title, url, thumbnail_url, category_id);
            });
            slide.add_controller(slide_click);

            // Add slide to carousel and to our item list
            int new_index = featured_carousel_items.size;
            if (hero_carousel == null) hero_carousel = new HeroCarousel(featured_box);
            hero_carousel.add_slide(slide);
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
            if (hero_carousel != null) hero_carousel.update_dots();

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
        
        // Make all cards 20% taller
        img_h = (int)(img_h * 1.2);

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
            // For Local News category, only load images for the first
            // LOCAL_NEWS_IMAGE_LOAD_LIMIT items to avoid allocating many
            // large textures simultaneously. Users still see full-quality
            // images for early/browsable content, and previews load the
            // full image when opened.
            if (category_id == "local_news" && !bypass_limit) {
                try {
                        if (articles_shown >= LOCAL_NEWS_IMAGE_LOAD_LIMIT) {
                        // Skip loading image for this card — show the app-local
                        // placeholder instead. This preserves quality for early
                        // items while keeping memory usage reasonable.
                        set_local_placeholder_image(article_card.image, img_w, img_h);
                        // Still register the picture so any later update (e.g., when
                        // 'Load More' is shown) will be applied consistently.
                        register_picture_for_url(_norm, article_card.image);
                        try {
                            string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                            if (dbg != null && dbg.length > 0) {
                                append_debug_log("Local News: skipped image load for item index=" + articles_shown.to_string() + " url=" + _norm);
                            }
                        } catch (GLib.Error e) { }
                        // Do not initiate network request
                        card_will_load = false;
                    }
                } catch (GLib.Error e) { }
            }
            int multiplier = (prefs.news_source == NewsSource.REDDIT) ? (initial_phase ? 2 : 2) : (initial_phase ? 1 : 3);
            // When viewing Local News, downscale aggressively to avoid creating
            // many large textures — local feeds often contain many small items
            // and we want to keep memory bounded.
            // Don't reduce image quality by default; instead, only load
            // images for the first N items (user-configurable) and
            // show placeholders for the rest to conserve memory while
            // keeping high-quality images for early/visible items.
            if (initial_phase) pending_images++;
            // Caller retains image-load logic; register picture for in-place updates
            image_handler.load_image_async(article_card.image, thumbnail_url, img_w * multiplier, img_h * multiplier);
            register_picture_for_url(_norm, article_card.image);
        } else {
            if (category_id == "local_news") {
                set_local_placeholder_image(article_card.image, img_w, img_h);
            } else {
                set_placeholder_image_for_source(article_card.image, img_w, img_h, resolve_source(source_name, url));
            }
        }

        // Map normalized URL -> original URL and card widget for overlays/badges and viewed state
        normalized_to_url.set(_norm, url);
        register_card_for_url(_norm, article_card.root);
        try {
            if (meta_cache != null) {
                bool was = false;
                try { was = meta_cache.is_viewed(_norm); } catch (GLib.Error e) { was = false; }
                try { append_debug_log("meta_check: card url=" + _norm + " was=" + (was ? "true" : "false")); } catch (GLib.Error e) { }
                // Debug output for viewed state
                stderr.printf("[VIEWED_CHECK] URL: %s | Viewed: %s\n", _norm, was ? "YES" : "NO");
                if (was) { try { mark_article_viewed(_norm); } catch (GLib.Error e) { } }
            }
        } catch (GLib.Error e) { }

        // Connect activation to opening the article preview
        article_card.activated.connect((s) => {
            try { article_pane.show_article_preview(title, url, thumbnail_url, category_id); } catch (GLib.Error e) { }
        });

        // Append to the calculated target column
        // Top Ten: Use sequential grid fill (row-by-row)
        // Others: Use masonry layout (shortest column)
        if (target_col == -1) {
            if (prefs.category == "topten") {
                // Sequential fill for grid: round-robin across 4 columns
                target_col = next_column_index;
                next_column_index = (next_column_index + 1) % columns.length;
            } else {
                // Masonry: find shortest column with random noise
                target_col = 0;
                int random_noise = rng.int_range(0, 11);
                int best_score = column_heights[0] + random_noise;
                for (int i = 1; i < columns.length; i++) {
                    random_noise = rng.int_range(0, 11);
                    int score = column_heights[i] + random_noise;
                    if (score < best_score) { best_score = score; target_col = i; }
                }
            }
        }
        columns[target_col].append(article_card.root);

        // articles_shown already incremented in the lock above - no need to increment again

        int estimated_card_h = img_h + 120;
        column_heights[target_col] += estimated_card_h + 12;

        if (initial_phase) mark_initial_items_populated();
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
    string icon_path = DataPaths.find_data_file("icons/" + icon_filename);
        return icon_path;
    }

    // Infer source from a URL by checking known domain substrings. Falls back
    // to the current prefs.news_source when uncertain.
    public NewsSource infer_source_from_url(string? url) {
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
        // Parse encoded source name format: "SourceName||logo_url##category::cat"
        string? clean_name = source_name;
        if (source_name != null && source_name.length > 0) {
            // Strip logo URL if present
            int pipe_idx = source_name.index_of("||");
            if (pipe_idx >= 0) {
                clean_name = source_name.substring(0, pipe_idx).strip();
            }
            // Strip category suffix if present
            int cat_idx = clean_name.index_of("##category::");
            if (cat_idx >= 0) {
                clean_name = clean_name.substring(0, cat_idx).strip();
            }
        }
        
        // Start with URL-inferred source as a sensible default
        NewsSource resolved = infer_source_from_url(url);
        if (clean_name != null && clean_name.length > 0) {
            string low = clean_name.down();
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
                string clean_src = clean_name != null ? clean_name : "<null>";
                append_debug_log("resolve_source: input_name=" + in_src + " clean_name=" + clean_src + " url=" + (url != null ? url : "<null>") + " resolved=" + get_source_name(resolved));
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
        // Support encoded API-provided logo information: "Display Name||https://.../logo.png##category::cat"
        string? provided_logo_url = null;
        string? display_name = source_name;
        if (source_name != null && source_name.index_of("||") >= 0) {
            string[] parts = source_name.split("||");
            if (parts.length >= 1) display_name = parts[0].strip();
            if (parts.length >= 2) {
                provided_logo_url = parts[1].strip();
                // Strip category suffix if present (format: "logo_url##category::cat")
                int cat_idx = provided_logo_url.index_of("##category::");
                if (cat_idx >= 0) {
                    provided_logo_url = provided_logo_url.substring(0, cat_idx).strip();
                }
            }
        }
        
        // Also strip ##category:: suffix from display_name if present
        if (display_name != null) {
            int cat_idx = display_name.index_of("##category::");
            if (cat_idx >= 0) {
                display_name = display_name.substring(0, cat_idx).strip();
            }
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
        // Additionally: when viewing the special 'frontpage' or 'topten' categories
        // the backend's provided source name/logo should be treated as authoritative
        // and we must NOT map it to the user's preferred/built-in sources.
        bool is_aggregated = (category_id != null && (category_id == "frontpage" || category_id == "topten"));
        if (!is_aggregated && provided_logo_url == null && display_name != null && display_name.length > 0) {
            NewsSource resolved = resolve_source(display_name, url);
            // If resolve_source matched a known built-in source, produce that badge
            // by checking if get_source_icon_path would return a non-null path.
            string? icon_path = get_source_icon_path(resolved);
            if (icon_path != null) return build_source_badge(resolved);
        }
        
        // For aggregated views (frontpage/topten) with explicit source names,
        // create a text-only badge without trying to resolve to built-in sources
        if (is_aggregated && display_name != null && display_name.length > 0 && provided_logo_url == null) {
            var box = new Gtk.Box(Orientation.HORIZONTAL, 6);
            box.add_css_class("source-badge");
            box.set_margin_bottom(8);
            box.set_margin_end(8);
            box.set_valign(Gtk.Align.END);
            box.set_halign(Gtk.Align.END);

            var lbl = new Gtk.Label(display_name);
            lbl.add_css_class("source-badge-label");
            lbl.set_valign(Gtk.Align.CENTER);
            lbl.set_xalign(0.5f);
            lbl.set_ellipsize(Pango.EllipsizeMode.END);
            lbl.set_max_width_chars(14);
            box.append(lbl);
            return box;
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
                try { image_handler.load_image_async(pic, provided_logo_url, 20, 20); } catch (GLib.Error e) { }

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
                    string? full = DataPaths.find_data_file(rel);
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
            // Force a small fixed pixel size so symbolic icons don't scale oddly
            // in overlay contexts (prevents vertical stretching on hero slides)
            try { icon.set_pixel_size(12); } catch (GLib.Error e) { }
            // Tag the icon so CSS can target the inner circular wrap specifically
            try { icon.get_style_context().add_class("viewed-badge-icon"); } catch (GLib.Error e) { }
            try { icon.set_valign(Gtk.Align.CENTER); icon.set_halign(Gtk.Align.CENTER); } catch (GLib.Error e) { }
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
        // Debug output for marking viewed
        stderr.printf("[MARK_VIEWED] URL: %s\n", n);

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
        
        // Persist viewed state to per-article metadata cache
        if (meta_cache != null) {
            stderr.printf("[META_CACHE] Saving viewed state for: %s\n", n);
            try { 
                meta_cache.mark_viewed(n); 
                stderr.printf("[META_CACHE] Successfully saved\n");
            } catch (GLib.Error e) {
                stderr.printf("[META_CACHE] Error in mark_viewed: %s\n", e.message);
            }
        } else {
            stderr.printf("[META_CACHE] meta_cache is NULL!\n");
        }
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
        // Delegate to centralized placeholder builder which accepts a NewsSource
        try {
            PlaceholderBuilder.create_icon_placeholder(image, icon_path, prefs.news_source, width, height);
        } catch (GLib.Error e) {
            // Best-effort fallback
            try { create_source_text_placeholder(image, get_source_name(prefs.news_source), width, height); } catch (GLib.Error ee) { }
        }
    }

    private void create_source_text_placeholder(Gtk.Picture image, string source_name, int width, int height) {
        try {
            PlaceholderBuilder.create_source_text_placeholder(image, source_name, prefs.news_source, width, height);
        } catch (GLib.Error e) {
            try { create_gradient_placeholder(image, width, height); } catch (GLib.Error ee) { }
        }
    }

    private void set_placeholder_image(Gtk.Picture image, int width, int height) {
        // Delegate to PlaceholderBuilder using the app-level news source
        try {
            PlaceholderBuilder.set_placeholder_image_for_source(image, width, height, prefs.news_source);
        } catch (GLib.Error e) {
            try { PlaceholderBuilder.create_gradient_placeholder(image, width, height); } catch (GLib.Error ee) { }
        }
    }

    // Variant that honors an explicit NewsSource so the UI can render a
    // per-article branded placeholder even when the application's global
    // prefs.news_source differs (useful when multiple sources are enabled).
    public void set_placeholder_image_for_source(Gtk.Picture image, int width, int height, NewsSource source) {
        try {
            PlaceholderBuilder.set_placeholder_image_for_source(image, width, height, source);
        } catch (GLib.Error e) {
            try { PlaceholderBuilder.create_gradient_placeholder(image, width, height); } catch (GLib.Error ee) { }
        }
    }

    // Local-news specific placeholder: delegate to PlaceholderBuilder which
    // implements the shared drawing logic so both NewsWindow and ArticlePane
    // can reuse the same visuals.
    public void set_local_placeholder_image(Gtk.Picture image, int width, int height) {
        try {
            PlaceholderBuilder.set_local_placeholder_image(image, width, height);
            return;
        } catch (GLib.Error e) {
            // Fallback conservatively to the generic placeholder if the helper fails
            try { PlaceholderBuilder.create_gradient_placeholder(image, width, height); } catch (GLib.Error ee) { }
        }
    }

    private void create_gradient_placeholder(Gtk.Picture image, int width, int height) {
        try { PlaceholderBuilder.create_gradient_placeholder(image, width, height); } catch (GLib.Error e) { }
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
            image_handler.load_image_async(picture, info.url, new_w, new_h);
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
        
        // For Top Ten, reduce column width by 15% to scale everything down
        if (prefs.category == "topten") {
            col_w = (int)(col_w * 0.85);
        }
        
        // Force compact cards that always fit
        return clampi(col_w, 160, 280);
    }

    

    // Recreate the columns for masonry layout with a new count
    private void rebuild_columns(int count) {
        // Remove and destroy existing column widgets to free memory
        Gtk.Widget? child = columns_row.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            columns_row.remove(child);
            // Force widget destruction to release texture references
            child.unparent();
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
            // Remove "No more articles" message when starting a new load
            var children = content_box.observe_children();
            for (uint i = 0; i < children.get_n_items(); i++) {
                var child = children.get_item(i) as Gtk.Widget;
                if (child is Gtk.Label) {
                    var label = child as Gtk.Label;
                    // Accept either the markup or plain-text form when removing
                    // the end-of-feed message so it won't persist when a new
                    // fetch begins.
                    var txt = label.get_label();
                    if (txt == "<b>No more articles</b>" || txt == "No more articles") {
                        content_box.remove(label);
                        break;
                    }
                }
            }
            
            // Hide My Feed instructions if switching away from My Feed
            update_personalization_ui();
            
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
            
            // Show Load More button if we have remaining articles and hit the limit
            if (remaining_articles != null && remaining_articles.length > 0 && articles_shown >= INITIAL_ARTICLE_LIMIT) {
                show_load_more_button();
            } else if (remaining_articles == null || remaining_articles.length == 0) {
                // No remaining articles, show end message after content is fully loaded
                Timeout.add(800, () => {
                    // Double-check spinner is still hidden before showing message
                    if (loading_container == null || !loading_container.get_visible()) {
                        show_end_of_feed_message();
                    }
                    return false;
                });
            }
        }
    }

    // Track whether any fetchers reported a network-related failure during
    // the current fetch sequence. Fetching code will emit error labels like
    // "... Error loading ..." which we detect and use to present a more
    // specific offline message when the global timeout fires.
    private bool network_failure_detected = false;

    // Show the global error overlay. If `msg` is provided it will be shown
    // in the overlay label; otherwise we use a generic "no articles" text.
    private void show_error_message(string? msg = null) {
        if (error_message_box != null) {
            // Hide loading spinner and other overlays
            try { hide_loading_spinner(); } catch (GLib.Error e) { }
            try { if (personalized_message_box != null) personalized_message_box.set_visible(false); } catch (GLib.Error e) { }
            try { if (local_news_message_box != null) local_news_message_box.set_visible(false); } catch (GLib.Error e) { }
            try { if (main_content_container != null) main_content_container.set_visible(false); } catch (GLib.Error e) { }

            if (msg == null) msg = "No articles could be loaded. Try refreshing or check your source settings.";
            try { if (error_message_label != null && msg != null) error_message_label.set_text(msg); } catch (GLib.Error e) { }
            error_message_box.set_visible(true);
        }
    }

    private void hide_error_message() {
        if (error_message_box != null) {
            error_message_box.set_visible(false);
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
    public string make_cache_key(string url, int w, int h) {
        return "%s@%dx%d".printf(url, w, h);
    }

    // Process deferred download requests: if a deferred widget becomes visible,
    // start its download. This runs on the main loop and reschedules itself
    // only when there are remaining deferred requests.
    public void process_deferred_downloads() {
        // Process only a few at a time to avoid scroll jank
        const int MAX_BATCH = 5;
        int processed = 0;
        
        // Collect to-start entries to avoid modifying map while iterating
        var to_start = new Gee.ArrayList<Gtk.Picture>();
        foreach (var kv in deferred_downloads.entries) {
            if (processed >= MAX_BATCH) break;
            Gtk.Picture pic = kv.key;
            DeferredRequest req = kv.value;
            bool vis = false;
            try { vis = pic.get_visible(); } catch (GLib.Error e) { vis = true; }
            if (vis) {
                to_start.add(pic);
                processed++;
            }
        }

        foreach (var pic in to_start) {
            var req = deferred_downloads.get(pic);
            if (req == null) continue;
            // Remove before starting to avoid races
            try { deferred_downloads.remove(pic); } catch (GLib.Error e) { }
            // Start immediately (force bypass visibility deferral)
            try { image_handler.load_image_async(pic, req.url, req.w, req.h, true); } catch (GLib.Error e) { }
        }
        // If there are still deferred entries, schedule another check
        if (deferred_downloads.size > 0) {
            if (deferred_check_timeout_id == 0) {
                deferred_check_timeout_id = Timeout.add(1200, () => {
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
            image_handler.load_image_async(pic, original, new_w, new_h);

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
    public void on_image_loaded(Gtk.Picture image) {
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

    // Clean up memory by releasing old textures and widget references
    private void cleanup_old_content() {
        // Force clear all Picture widgets to release texture references
        foreach (var pic in url_to_picture.values) {
            pic.set_paintable(null);
        }
        
        // Clear URL-to-widget mappings (these should auto-cleanup via destroy signals, but ensure)
        url_to_picture.clear();
        url_to_card.clear();
        normalized_to_url.clear();
        
        // Clear pending downloads
        pending_downloads.clear();
        
        // Clear hero requests
        hero_requests.clear();
        
        // Clear deferred downloads
        deferred_downloads.clear();
        
        // Clear requested image sizes
        requested_image_sizes.clear();
        
        // CRITICAL: Clear the memory texture cache to free large textures
        memory_meta_cache.clear();
        thumbnail_cache.clear();
        // Also clear the shared preview cache to free textures created by
        // article previews. This avoids retaining additional Gdk.Texture
        // objects across category switches.
        try { PreviewCacheManager.clear_cache(); } catch (GLib.Error e) { }
        
        // Clear disk image cache but preserve metadata (viewed states, etc)
        if (meta_cache != null) {
            meta_cache.clear_images();
        }
    }

    public void fetch_news() {
        // Debug: log fetch_news invocation and current sequence
        try {
            string? _dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
            if (_dbg != null && _dbg.length > 0) {
                append_debug_log("fetch_news: entering seq=" + fetch_sequence.to_string() + " category=" + prefs.category + " preferred_sources=" + AppDebugger.array_join(prefs.preferred_sources));
            }
        } catch (GLib.Error e) { }

        // Ensure sidebar visibility reflects current source
        update_sidebar_for_source();
        // Clear featured hero and randomize columns count per fetch between 2 and 4 for extra variety
        // Clear featured and destroy widgets
        Gtk.Widget? fchild = featured_box.get_first_child();
        while (fchild != null) {
            Gtk.Widget? next = fchild.get_next_sibling();
            featured_box.remove(fchild);
            fchild.unparent();
            fchild = next;
        }
        featured_used = false;
        // Reset featured carousel state so new category fetches start fresh
        if (hero_carousel != null) {
            hero_carousel.stop_timer();
            try {
                if (hero_carousel.container != null) featured_box.remove(hero_carousel.container);
            } catch (GLib.Error e) { }
            hero_carousel = null;
        }
        if (featured_carousel_items != null) {
            featured_carousel_items.clear();
        }
        featured_carousel_category = null;
        
        // Clear hero_container for Top Ten (remove all children including featured_box)
        // For other categories, hero_container should just have featured_box
        if (prefs.category == "topten") {
            // Remove and destroy all children from hero_container
            Gtk.Widget? hchild = hero_container.get_first_child();
            while (hchild != null) {
                Gtk.Widget? next = hchild.get_next_sibling();
                hero_container.remove(hchild);
                hchild.unparent();
                hchild = next;
            }
            topten_hero_count = 0;
        } else {
            // For non-topten views, clear and destroy everything first then add featured_box
            Gtk.Widget? hchild = hero_container.get_first_child();
            while (hchild != null) {
                Gtk.Widget? next = hchild.get_next_sibling();
                hero_container.remove(hchild);
                hchild.unparent();
                hchild = next;
            }
            // Now add featured_box for carousel
            hero_container.append(featured_box);
        }
        
        // Top Ten uses special 2-row grid layout (2 heroes + 2 rows of 4 cards)
        // Other categories use standard 3-column masonry
        if (prefs.category == "topten") {
            rebuild_columns(4); // 4 columns for grid layout
        } else {
            rebuild_columns(3); // Standard masonry
        }
        
        // Clean up memory: clear image caches and widget references
        cleanup_old_content();
        
        // Reset category distribution tracking for new content
        category_column_counts.clear();
        recent_categories.clear();
        next_column_index = 0;
        article_buffer.clear();
        category_last_column.clear();
        
        // Clean up category tracking
        recent_category_queue.clear();
        articles_shown = 0;

        // Adjust preview cache size for Local News view to conserve memory.
        // Local News can have many items; reduce preview cache to a small number
        // when active. Restore default capacity for other views.
        try {
            if (prefs.category == "local_news") {
                try { PreviewCacheManager.get_cache().set_capacity(6); } catch (GLib.Error e) { }
            } else {
                try { PreviewCacheManager.get_cache().set_capacity(12); } catch (GLib.Error e) { }
            }
        } catch (GLib.Error e) { }
        
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
            try { update_content_header(); } catch (GLib.Error e) { }
            try { update_personalization_ui(); } catch (GLib.Error e) { }
            // Ensure any spinner is hidden and don't proceed to fetch
            hide_loading_spinner();
            return;
        }

    // Show loading spinner while fetching content
    show_loading_spinner();
    // Ensure content header (icon + category + optional search text)
    // is painted immediately before we begin creating hero/article widgets.
    // update_sidebar_for_source() above has already updated source-related
    // state; call the synchronous header update now to guarantee ordering.
    try { update_content_header_now(); } catch (GLib.Error e) { }
        
        // Hide error message if it was visible from a previous failed fetch
        hide_error_message();

        // Start initial-phase gating: wait for initial items and their images
        initial_phase = true;
        hero_image_loaded = false;
        pending_images = 0;
        initial_items_populated = false;
    // Reset per-fetch network failure tracking
    network_failure_detected = false;
        if (initial_reveal_timeout_id > 0) {
            Source.remove(initial_reveal_timeout_id);
            initial_reveal_timeout_id = 0;
        }
        
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
        
        // Safety timeout: reveal after a reasonable maximum to avoid blocking forever
        initial_reveal_timeout_id = Timeout.add(INITIAL_MAX_WAIT_MS, () => {
            // Timeout reached; check if we got any items
            if (!self_ref.initial_items_populated) {
                // No articles received - show error. Prefer an offline-specific
                // message if any fetchers reported network failures during
                // this fetch sequence.
                try {
                    if (self_ref.network_failure_detected) {
                        self_ref.show_error_message("No network connection detected. Check your connection and try again.");
                    } else {
                        self_ref.show_error_message();
                    }
                } catch (GLib.Error e) { }
            } else {
                // Reveal content even if some images haven't finished
                self_ref.reveal_initial_content();
            }
            self_ref.initial_reveal_timeout_id = 0;
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

        Timeout.add(INITIAL_MAX_WAIT_MS + 2000, () => {
            try { self_ref.unref(); } catch (GLib.Error e) { }
            return false;
        });

        // Wrapped set_label: only update if this fetch is still current
        SetLabelFunc wrapped_set_label = (text) => {
            // Schedule UI updates on the main loop to avoid touching
            // window fields from worker threads. The Idle callback will
            // check the fetch_sequence token before applying changes.
            Idle.add(() => {
                if (my_seq != self_ref.fetch_sequence) {
                    try { if (GLib.Environment.get_variable("PAPERBOY_DEBUG") != null) append_debug_log("wrapped_set_label: ignoring stale seq=" + my_seq.to_string() + " current=" + self_ref.fetch_sequence.to_string()); } catch (GLib.Error e) { }
                    return false;
                }
                // Detect error-like labels emitted by fetchers and mark a
                // network failure flag so the timeout can present a more
                // specific offline message. Many fetchers call set_label
                // with "... Error loading ..." when network issues occur.
                try {
                    if (text != null) {
                        string lower = text.down();
                        if (lower.index_of("error") >= 0 || lower.index_of("failed") >= 0) {
                            self_ref.network_failure_detected = true;
                            try { append_debug_log("DEBUG: wrapped_set_label detected error label='" + text + "'"); } catch (GLib.Error e) { }
                        }
                    }
                } catch (GLib.Error e) { }

                // Use the centralized header updater which enforces the exact
                // UI contract (icon + category, or Search Results when active).
                try { self_ref.update_content_header(); } catch (GLib.Error e) { }
                return false;
            });
        };

        // Wrapped clear_items: only clear if this fetch is still current
        ClearItemsFunc wrapped_clear = () => {
            // Schedule the clear on the main loop to avoid worker-thread UI access
            Idle.add(() => {
                if (my_seq != self_ref.fetch_sequence) {
                    try { if (GLib.Environment.get_variable("PAPERBOY_DEBUG") != null) append_debug_log("wrapped_clear: ignoring stale seq=" + my_seq.to_string() + " current=" + self_ref.fetch_sequence.to_string()); } catch (GLib.Error e) { }
                    return false;
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
                
                // Remove "No more articles" message if it exists
                var children = self_ref.content_box.observe_children();
                for (uint i = 0; i < children.get_n_items(); i++) {
                    var child = children.get_item(i) as Gtk.Widget;
                    if (child is Gtk.Label) {
                        var label = child as Gtk.Label;
                        var _txt = label.get_label();
                        if (_txt == "<b>No more articles</b>" || _txt == "No more articles") {
                            self_ref.content_box.remove(label);
                            break;
                        }
                    }
                }
                
                // Also clear image bookkeeping so subsequent fetches create
                // fresh widgets instead of updating removed ones.
                try { self_ref.url_to_picture.clear(); } catch (GLib.Error e) { }
                try { self_ref.hero_requests.clear(); } catch (GLib.Error e) { }
                self_ref.remaining_articles = null;
                self_ref.remaining_articles_index = 0;
                if (self_ref.load_more_button != null) {
                    var parent = self_ref.load_more_button.get_parent() as Gtk.Box;
                    if (parent != null) parent.remove(self_ref.load_more_button);
                    self_ref.load_more_button = null;
                }
                self_ref.articles_shown = 0;
                return false;
            });
        };

        // Wrapped add_item: ignore items from stale fetches
        // Throttled add for Local News: queue incoming items and process in small batches
        var local_news_queue = new Gee.ArrayList<ArticleItem>();
        bool local_news_flush_scheduled = false;
        int local_news_items_enqueued = 0; // debug counter
        bool local_news_stats_scheduled = false;
        // General UI add queue to batch worker->main-thread article additions.
        // Using a single Idle to drain this queue avoids per-item refs on the
        // window/object and reduces thread churn that previously caused races
        // during heavy fetches.
        var ui_add_queue = new Gee.ArrayList<ArticleItem>();
        bool ui_add_idle_scheduled = false;

    AddItemFunc wrapped_add = (title, url, thumbnail, category_id, source_name) => {
            // Debug: log all wrapped_add calls for topten
            try {
                string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                if (dbg != null && dbg.length > 0 && self_ref.prefs.category == "topten") {
                    self_ref.append_debug_log("wrapped_add called for TOPTEN: category_id=" + category_id + " title=" + title);
                }
            } catch (GLib.Error e) { }
            
            // Check article limit ONLY for limited categories, NOT frontpage/topten/all
            bool viewing_limited_category = (
                self_ref.prefs.category == "general" || 
                self_ref.prefs.category == "us" || 
                self_ref.prefs.category == "sports" || 
                self_ref.prefs.category == "science" || 
                self_ref.prefs.category == "health" || 
                self_ref.prefs.category == "technology" || 
                self_ref.prefs.category == "business" || 
                self_ref.prefs.category == "entertainment" || 
                self_ref.prefs.category == "politics" ||
                self_ref.prefs.category == "markets" ||
                self_ref.prefs.category == "industries" ||
                self_ref.prefs.category == "economics" ||
                self_ref.prefs.category == "wealth" ||
                self_ref.prefs.category == "green"
                || self_ref.prefs.category == "local_news"
            );
            
            try {
                string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                if (dbg != null && dbg.length > 0) {
                    self_ref.append_debug_log("wrapped_add: category=" + self_ref.prefs.category + " shown=" + self_ref.articles_shown.to_string() + " limit=" + INITIAL_ARTICLE_LIMIT.to_string() + " is_limited=" + (viewing_limited_category ? "YES" : "NO") + " has_button=" + (self_ref.load_more_button != null ? "yes" : "no") + " title=" + title);
                }
            } catch (GLib.Error e) { }
            
            // Don't check limit here - let add_item_immediate_to_column() handle it after filtering
            
            // If we're in Local News mode, enqueue and process in small batches to avoid UI lockups
            try {
                var prefs_local = NewsPreferences.get_instance();
                if (prefs_local != null && prefs_local.category == "local_news") {
                    local_news_queue.add(new ArticleItem(title, url, thumbnail, category_id, source_name));
                    local_news_items_enqueued++;
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

            // Default: push the ArticleItem onto a shared UI queue and
            // schedule a single Idle to drain items in small batches.
            // This avoids scheduling one Idle per item (which created a
            // racey mix of refs) and keeps the main-loop work bounded.
            var ai = new ArticleItem(title, url, thumbnail, category_id, source_name);
            try { ai.ref(); } catch (GLib.Error e) { }
            try {
                ui_add_queue.add(ai);
            } catch (GLib.Error e) { try { ai.unref(); } catch (GLib.Error _e) { } }

            if (!ui_add_idle_scheduled) {
                ui_add_idle_scheduled = true;
                // Take one extra reference to the window for the duration
                // of the drain so the object cannot be finalized while we
                // are processing queued items.
                try { self_ref.ref(); } catch (GLib.Error e) { }
                Idle.add(() => {
                    int processed = 0;
                    const int BATCH = 8; // process up to 8 items per tick
                    
                    // Check if we're viewing a limited category
                    bool is_limited_cat = (
                        self_ref.prefs.category == "general" || 
                        self_ref.prefs.category == "us" || 
                        self_ref.prefs.category == "sports" || 
                        self_ref.prefs.category == "science" || 
                        self_ref.prefs.category == "health" || 
                        self_ref.prefs.category == "technology" || 
                        self_ref.prefs.category == "business" || 
                        self_ref.prefs.category == "entertainment" || 
                        self_ref.prefs.category == "politics" ||
                        self_ref.prefs.category == "markets" ||
                        self_ref.prefs.category == "industries" ||
                        self_ref.prefs.category == "economics" ||
                        self_ref.prefs.category == "wealth" ||
                        self_ref.prefs.category == "green"
                    );
                    
                    while (ui_add_queue.size > 0 && processed < BATCH) {
                        // Only enforce limit for specific categories
                        if (is_limited_cat && self_ref.articles_shown >= INITIAL_ARTICLE_LIMIT) {
                            // Transfer remaining items to remaining_articles array
                            while (ui_add_queue.size > 0) {
                                ArticleItem? x = null;
                                try { x = ui_add_queue.get(0); } catch (GLib.Error e) { x = null; }
                                if (x == null) break;
                                try { ui_add_queue.remove_at(0); } catch (GLib.Error e) { }
                                
                                // Add to remaining articles array
                                if (self_ref.remaining_articles == null) {
                                    self_ref.remaining_articles = new ArticleItem[1];
                                    self_ref.remaining_articles[0] = x;
                                } else {
                                    var new_arr = new ArticleItem[self_ref.remaining_articles.length + 1];
                                    for (int i = 0; i < self_ref.remaining_articles.length; i++) {
                                        new_arr[i] = self_ref.remaining_articles[i];
                                    }
                                    new_arr[self_ref.remaining_articles.length] = x;
                                    self_ref.remaining_articles = new_arr;
                                }
                            }
                            
                            // Show the Load More button only if it doesn't exist
                            if (self_ref.load_more_button == null) {
                                self_ref.show_load_more_button();
                            }
                            ui_add_idle_scheduled = false;
                            try { self_ref.unref(); } catch (GLib.Error e) { }
                            return false;
                        }
                        
                        ArticleItem? x = null;
                        try { x = ui_add_queue.get(0); } catch (GLib.Error e) { x = null; }
                        if (x == null) break;
                        try { 
                            ui_add_queue.remove_at(0);
                        } catch (GLib.Error e) { }
                        // Ensure still current before adding
                        if (my_seq == self_ref.fetch_sequence) {
                            try { self_ref.add_item(x.title, x.url, x.thumbnail_url, x.category_id, x.source_name); } catch (GLib.Error e) { }
                        }
                        // Release the temporary ref we took when enqueuing
                        try { x.unref(); } catch (GLib.Error e) { }
                        processed += 1;
                    }
                    if (ui_add_queue.size > 0) {
                        // Keep the idle scheduled until we drain the queue
                        return true;
                    } else {
                        // No more items: clear flag and release window ref
                        ui_add_idle_scheduled = false;
                        try { self_ref.unref(); } catch (GLib.Error e) { }
                        return false;
                    }
                });
            }
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
                // Schedule UI update on main loop
                Idle.add(() => {
                    if (my_seq != self_ref.fetch_sequence) return false;
                    try {
                        self_ref.update_content_header();
                    } catch (GLib.Error e) { }
                    return false;
                });
            };

            // Ensure the top-right source badge shows a generic/local affordance
            // when we're displaying Local News (feeds may represent many sources).
            try { self_ref.source_label.set_text("Local News"); } catch (GLib.Error e) { }
            // Prefer a repo-local symbolic "local-mono" icon when available so the
            // top-right logo matches the app's iconography. Fall back to the
            // generic RSS symbolic icon if no local asset is found.
            try {
                string? local_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "local-mono.svg"));
                if (local_icon == null) local_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "local-mono.svg"));
                if (local_icon != null) {
                    string use_path = local_icon;
                    try {
                        if (self_ref.is_dark_mode()) {
                            string? white_cand = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "local-mono-white.svg"));
                            if (white_cand == null) white_cand = DataPaths.find_data_file(GLib.Path.build_filename("icons", "local-mono-white.svg"));
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
            try {
                string? dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                if (dbg != null && dbg.length > 0) {
                    // Log the fact that we scheduled multiple local feeds — helpful
                    // when diagnosing memory spikes from many small feeds.
                    append_debug_log("Local News: scheduled " + lines.length.to_string() + " feed candidates");
                    // Also schedule a short timeout to report how many items were enqueued
                    // for UI processing. This gets updated as RssParser.fetch_rss_url
                    // invokes `wrapped_add` asynchronously.
                    if (!local_news_stats_scheduled) {
                        local_news_stats_scheduled = true;
                        Timeout.add(250, () => {
                            try {
                                append_debug_log("Local News: enqueued items=" + local_news_items_enqueued.to_string() + " queue_size=" + local_news_queue.size.to_string());
                            } catch (GLib.Error e) { }
                            return false;
                        });
                    }
                }
            } catch (GLib.Error e) { }
            if (!found_feed) {
                try { wrapped_set_label("Local News — No local feeds configured"); } catch (GLib.Error e) { }
            }
            return;
        }
        // If the user selected "Front Page", always request the backend
        // frontpage endpoint regardless of preferred_sources. Place this
        // before the multi-source branch so frontpage works even when the
        // user has zero or one preferred source selected.
        if (prefs.category == "frontpage") {
            // Present the multi-source label/logo in the header
            try { self_ref.source_label.set_text("Multiple Sources"); } catch (GLib.Error e) { }
            try {
                string? multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono.svg"));
                if (multi_icon == null) multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "multiple-mono.svg"));
                if (multi_icon != null) {
                    string use_path = multi_icon;
                    try {
                        if (self_ref.is_dark_mode()) {
                            string? white_cand = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono-white.svg"));
                            if (white_cand == null) white_cand = DataPaths.find_data_file(GLib.Path.build_filename("icons", "multiple-mono-white.svg"));
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

        // If the user selected "Top Ten", request the backend headlines endpoint
        // regardless of preferred_sources. Same early-return logic as frontpage.
        if (prefs.category == "topten") {
            // Present the multi-source label/logo in the header
            try { self_ref.source_label.set_text("Multiple Sources"); } catch (GLib.Error e) { }
            try {
                string? multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono.svg"));
                if (multi_icon == null) multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "multiple-mono.svg"));
                if (multi_icon != null) {
                    string use_path = multi_icon;
                    try {
                        if (self_ref.is_dark_mode()) {
                            string? white_cand = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono-white.svg"));
                            if (white_cand == null) white_cand = DataPaths.find_data_file(GLib.Path.build_filename("icons", "multiple-mono-white.svg"));
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
            try { wrapped_set_label("Top Ten — Loading from backend"); } catch (GLib.Error e) { }
            try {
                string s = "topten-early-branch: preferred_sources_size=" + (prefs.preferred_sources != null ? prefs.preferred_sources.size.to_string() : "0") + "\n";
                append_debug_log(s);
            } catch (GLib.Error e) { }
            NewsSources.fetch(prefs.news_source, "topten", current_search_query, session, wrapped_set_label, wrapped_clear, wrapped_add);
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
                    string? multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono.svg"));
                    if (multi_icon == null) multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "multiple-mono.svg"));
                    if (multi_icon != null) {
                        string use_path = multi_icon;
                        try {
                            if (self_ref.is_dark_mode()) {
                                string? white_cand = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono-white.svg"));
                                if (white_cand == null) white_cand = DataPaths.find_data_file(GLib.Path.build_filename("icons", "multiple-mono-white.svg"));
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

            // Same logic for Top Ten: request backend headlines endpoint
            if (prefs.category == "topten") {
                try { self_ref.source_label.set_text("Multiple Sources"); } catch (GLib.Error e) { }
                try {
                    string? multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono.svg"));
                    if (multi_icon == null) multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "multiple-mono.svg"));
                    if (multi_icon != null) {
                        string use_path = multi_icon;
                        try {
                            if (self_ref.is_dark_mode()) {
                                string? white_cand = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono-white.svg"));
                                if (white_cand == null) white_cand = DataPaths.find_data_file(GLib.Path.build_filename("icons", "multiple-mono-white.svg"));
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
                NewsSources.fetch(prefs.news_source, "topten", current_search_query, session, wrapped_set_label, wrapped_clear, wrapped_add);
                return;
            }

            // Display a combined label and bundled monochrome logo for multi-source mode
            try {
                self_ref.source_label.set_text("Multiple Sources");
                // Try symbolic first (includes -white variants), then fall back
                // to the old location for compatibility.
                string? multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono.svg"));
                if (multi_icon == null) multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "multiple-mono.svg"));
                if (multi_icon != null) {
                    try {
                        string use_path = multi_icon;
                        try {
                            if (self_ref.is_dark_mode()) {
                                string? white_cand = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono-white.svg"));
                                if (white_cand == null) white_cand = DataPaths.find_data_file(GLib.Path.build_filename("icons", "multiple-mono-white.svg"));
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
                    Idle.add(() => {
                        if (my_seq != self_ref.fetch_sequence) return false;
                        try { self_ref.update_content_header(); } catch (GLib.Error e) { }
                        return false;
                    });
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

            // Same for Top Ten in single-source mode
            if (prefs.category == "topten") {
                try { wrapped_clear(); } catch (GLib.Error e) { }
                try { wrapped_set_label("Top Ten — Loading from backend (single-source)"); } catch (GLib.Error e) { }
                try {
                    string s = "topten-single-source-branch: preferred_sources_size=" + (prefs.preferred_sources != null ? prefs.preferred_sources.size.to_string() : "0") + "\n";
                    append_debug_log(s);
                } catch (GLib.Error e) { }
                NewsSources.fetch(prefs.news_source, "topten", current_search_query, session, wrapped_set_label, wrapped_clear, wrapped_add);
                return;
            }

            if (is_myfeed_mode) {
                // Fetch each personalized category for the single effective source
                try { wrapped_clear(); } catch (GLib.Error e) { }
                SetLabelFunc label_fn = (text) => {
                    Idle.add(() => {
                        if (my_seq != self_ref.fetch_sequence) return false;
                        try { self_ref.update_content_header(); } catch (GLib.Error e) { }
                        return false;
                    });
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

    private void show_end_of_feed_message() {
        // Check if message already exists
        var children = content_box.observe_children();
        for (uint i = 0; i < children.get_n_items(); i++) {
            var child = children.get_item(i) as Gtk.Widget;
            if (child is Gtk.Label) {
                var label = child as Gtk.Label;
                // Check both the markup and the CSS class to identify our message
                var label_text = label.get_label();
                if ((label_text == "<b>No more articles</b>" || label_text == "No more articles") 
                    && label.has_css_class("dim-label")) {
                    return; // Already shown
                }
            }
        }
        // Remove Load More button if present so we don't show both
        if (load_more_button != null) {
            var parent_btn = load_more_button.get_parent() as Gtk.Box;
            if (parent_btn != null) parent_btn.remove(load_more_button);
            load_more_button = null;
        }

        var end_label = new Gtk.Label("<b>No more articles</b>");
        end_label.set_use_markup(true);
        end_label.add_css_class("dim-label");
        end_label.set_margin_top(20);
        end_label.set_margin_bottom(20);
        end_label.set_halign(Gtk.Align.CENTER);
        content_box.append(end_label);
    }

    private void show_load_more_button() {
        if (load_more_button != null) return; // Already shown
        
        // Don't show button while loading spinner is active
        if (loading_container != null && loading_container.get_visible()) {
            return;
        }
        
        // Create Load More button
        load_more_button = new Gtk.Button.with_label("Load more articles");
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
        // Remove any existing end-of-feed labels before adding the button so
        // they won't coexist (some pathways can add the end label earlier).
        var children = content_box.observe_children();
        for (uint i = 0; i < children.get_n_items(); i++) {
            var child = children.get_item(i) as Gtk.Widget;
            if (child is Gtk.Label) {
                var lbl = child as Gtk.Label;
                var txt = lbl.get_label();
                if (txt == "<b>No more articles</b>" || txt == "No more articles") {
                    content_box.remove(lbl);
                    break;
                }
            }
        }

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
            // No more articles to load, replace button with end message
            if (load_more_button != null) {
                load_more_button.add_css_class("fade-out");
                Timeout.add(300, () => {
                    if (load_more_button != null) {
                        var parent = load_more_button.get_parent() as Gtk.Box;
                        if (parent != null) {
                            parent.remove(load_more_button);
                        }
                        load_more_button = null;
                        
                        // Show end message only if spinner is not visible
                        if (loading_container == null || !loading_container.get_visible()) {
                            show_end_of_feed_message();
                        }
                    }
                    return false;
                });
            }
            return;
        }
        
        // Load another batch of articles (10 more, reduced from 15 to manage memory)
        int articles_to_load = int.min(10, remaining_articles.length - remaining_articles_index);
        
        for (int i = 0; i < articles_to_load; i++) {
            var article = remaining_articles[remaining_articles_index + i];
            // Add to article_buffer so article pane can find metadata
            article_buffer.add(article);
            // Add directly without going through limiting logic
            add_item_immediate_to_column(article.title, article.url, article.thumbnail_url, article.category_id, -1, null, article.source_name, true);
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
                } else {
                    // No more articles, show end message only if spinner is not visible
                    Timeout.add(500, () => {
                        if (loading_container == null || !loading_container.get_visible()) {
                            show_end_of_feed_message();
                        }
                        return false;
                    });
                }
                return false;
            });
        }
    }

}
