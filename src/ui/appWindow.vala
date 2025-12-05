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
    // Centralized source and category management
    public SourceManager source_manager;
    public CategoryManager category_manager;
    // Masonry layout is managed by LayoutManager
    public Managers.LayoutManager layout_manager;
    // Article management is handled by ArticleManager
    public Managers.ArticleManager article_manager;
        // Hero container reference for responsive sizing
    private Gtk.Box hero_container;
        public const int SIDEBAR_ICON_SIZE = 24;
        public const int MAX_CONCURRENT_DOWNLOADS = 10;
        public const int INITIAL_PHASE_MAX_CONCURRENT_DOWNLOADS = 3;
        public const int INITIAL_MAX_WAIT_MS = 15000;

        // Track active downloads globally (used by ImageHandler)
        public static int active_downloads = 0;
        // Restored fields required by window logic (many are accessed from other modules)
        public NewsPreferences prefs;
        public LocationDialog location_dialog;
        public GLib.Rand rng;
        public Gee.HashMap<Gtk.Picture, HeroRequest> hero_requests;
        public Managers.ViewStateManager? view_state;
        // Image caching moved to ImageCache (pixbuf-backed). Do not store
        // Gdk.Texture or Gdk.Pixbuf in window fields; use `image_cache`.
        public Gee.HashMap<string, string> requested_image_sizes;
        public Gee.HashMap<string, Gee.ArrayList<Gtk.Picture>> pending_downloads;
        public Gee.HashMap<Gtk.Picture, DeferredRequest> deferred_downloads;
        // THREAD SAFETY: Mutex to protect pending_downloads and requested_image_sizes
        // from concurrent access by background download threads
        public GLib.Mutex download_mutex;
        // Per-picture flag indicating we should show the local placeholder
        // (used for Local News cards so fallbacks keep the local look).
        public Gee.HashMap<Gtk.Picture, bool> pending_local_placeholder;
        public MetaCache? meta_cache;
        public ArticleStateStore? article_state_store;
        public ImageCache? image_cache;
        public ImageHandler image_handler;
        public Soup.Session session;
        public SidebarManager sidebar_manager;
        public Adw.NavigationSplitView split_view;
        public Adw.NavigationView nav_view;
        public Adw.OverlaySplitView article_preview_split;
        public Gtk.Box article_preview_content;
        public ArticlePane article_pane;
        public ArticleSheet article_sheet;
        public Gtk.Overlay root_overlay;
        public Adw.ToastOverlay toast_overlay;
        public Adw.ToastOverlay? content_toast_overlay;
        public ToastManager? toast_manager;
        public Gtk.Widget dim_overlay;
        public Gtk.Box main_content_container;
        public Gtk.ScrolledWindow main_scrolled;
        public Gtk.Widget content_area;
        public Gtk.Box content_box;
        // ContentView-provided widgets (wired in constructor)
        public Gtk.Label category_label;
        public Gtk.Label category_subtitle;
        public Gtk.Box? category_icon_holder;
        public Gtk.Image source_logo;
        public Gtk.Label source_label;
        public Gtk.Box featured_box_dummy;

        // Manager instance for header-related UI (kept private)
        private HeaderManager header_manager;
        // Manager instance for loading/overlay UI
        public Managers.LoadingStateManager? loading_state;
        // Manager instance for RSS feed updates
        private FeedUpdateManager? feed_updater;

        // Search query state and debug log path
        private string current_search_query = "";
        private string debug_log_path = "/tmp/paperboy-debug.log";

        // Fetch / initial state tracking
        public uint fetch_sequence = 0;
        public uint deferred_check_timeout_id = 0;

        // RSS feed adaptive layout tracking
        private uint rss_feed_layout_timeout_id = 0;
        private int rss_feed_article_count = 0;
    
        // Convenience accessors for ArticleManager properties (for backward compatibility)
        public ArticleItem[]? remaining_articles { get { return article_manager.remaining_articles; } set { article_manager.remaining_articles = value; } }
        public int articles_shown { get { return article_manager.articles_shown; } set { article_manager.articles_shown = value; } }
        public Gee.ArrayList<ArticleItem> article_buffer { get { return article_manager.article_buffer; } }
        public bool is_featured_used() { return article_manager.featured_used; }
        // Update the source/logo label via HeaderManager
        private void update_source_info() {
            try { if (header_manager != null) header_manager.update_source_info(); } catch (GLib.Error e) { }
        }
    

    // Return the NewsSource the UI should treat as "active". If the
    // user has enabled exactly one preferred source, map that id to the
    // corresponding enum; otherwise use the explicit prefs.news_source.
    public NewsSource effective_news_source() {
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
    public bool is_dark_mode() {
        var sm = Adw.StyleManager.get_default();
        return sm != null ? sm.dark : false;
    }

    // Expose current search query for header manager access
    public string get_current_search_query() {
        return current_search_query;
    }

    // Append a line to the debug log path (safe wrapper)
    public void append_debug_log(string line) {
        try {
            AppDebugger.append_debug_log(debug_log_path, line);
        } catch (GLib.Error e) { }
    }

    // Delegate URL normalization to the ViewStateManager (which uses UrlUtils)
    public string normalize_article_url(string url) {
        try { if (view_state != null) return view_state.normalize_article_url(url); } catch (GLib.Error e) { }
        return UrlUtils.normalize_article_url(url);
    }

    

    public NewsWindow(Adw.Application app) {
        GLib.Object(application: app);
        title = "Paperboy";
        // Set the window icon
        set_icon_name("paperboy");
        // Reasonable default window size that fits well on most screens
        set_default_size(1400, 925);
        // Initialize RNG for per-card randomization
        rng = new GLib.Rand();
        // Initialize preferences early (needed for building sidebar selection state)
        prefs = NewsPreferences.get_instance();
        // Initialize source and category managers early (needed for all source/category logic)
        source_manager = new SourceManager(prefs);
        source_manager.set_window(this);
        category_manager = new CategoryManager(prefs, source_manager);
        // Initialize hero request tracking map
        hero_requests = new Gee.HashMap<Gtk.Picture, HeroRequest>();
        // Initialize ArticleManager early (before any article-related code)
        article_manager = new Managers.ArticleManager(this);
        // Instantiate view-state manager which owns URL/card mappings and viewed state
        view_state = new Managers.ViewStateManager(this);

        // Connect signal to update unread count badges when articles are viewed
        view_state.article_viewed.connect((url) => {
            if (sidebar_manager != null) {
                sidebar_manager.refresh_all_badges();
            }
        });

        // Initialize in-memory cache and pending-downloads map
        // Capacity reduced to 30 (from 50) to prevent memory bloat with multiple sources
        // With all sources enabled, this prevents caching 200+ images in RAM
        // Use ImageCache for in-memory pixbuf caching; evictions/unrefs are
        // handled by ImageCache itself. The per-window `image_cache` is
        // instantiated below and will be set as the global ImageCache.
        requested_image_sizes = new Gee.HashMap<string, string>();
        pending_downloads = new Gee.HashMap<string, Gee.ArrayList<Gtk.Picture>>();
        deferred_downloads = new Gee.HashMap<Gtk.Picture, DeferredRequest>();
        pending_local_placeholder = new Gee.HashMap<Gtk.Picture, bool>();
        // Initialize download mutex for thread-safe access
        download_mutex = new GLib.Mutex();
        // Initialize on-disk cache helper
        try {
            meta_cache = new MetaCache();
        } catch (GLib.Error e) {
            meta_cache = null;
        }
        try {
            article_state_store = new ArticleStateStore();
            // Clear stale article tracking from previous session on startup.
            // Fresh articles will be registered as they're fetched, preventing
            // inflated unread counts from persisted data.
            if (article_state_store != null) {
                article_state_store.clear_article_tracking();
            }
        } catch (GLib.Error e) { article_state_store = null; }
        try {
            image_cache = new ImageCache(256);
        } catch (GLib.Error e) { image_cache = null; }
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
        // Create SidebarManager (it now builds its own UI)
        sidebar_manager = new SidebarManager(this);

        // Listen for category selections and trigger fetch/update from the window
        sidebar_manager.category_selected.connect((category) => {
            if (category == "frontpage") {
                try { fetch_news(); } catch (GLib.Error e) { }
                return;
            }
            Idle.add(() => {
                try { fetch_news(); } catch (GLib.Error e) { }
                try { update_personalization_ui(); } catch (GLib.Error e) { }
                return false;
            });
        });

        sidebar_manager.rebuild_rows();

        // Fetch article metadata for all categories in background to populate unread counts
        Timeout.add(1000, () => {
            try { fetch_all_category_metadata_for_counts(); } catch (GLib.Error e) { }
            return false;
        });

        // Request the completed navigation page from the manager (use the
        // `sidebar_header` built earlier above)
        Adw.NavigationPage sidebar_page = sidebar_manager.build_navigation_page(sidebar_header);

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
    content_box = content_view.content_box;
    main_scrolled = content_view.main_scrolled;
    // Wire content-local toast overlay so we can center toasts inside content
    try { this.content_toast_overlay = content_view.toast_overlay; } catch (GLib.Error e) { this.content_toast_overlay = null; }

    // Instantiate LayoutManager and wire container refs
    layout_manager = new Managers.LayoutManager(this);
    layout_manager.main_content_container = content_view.main_content_container;
    // Also keep the legacy `main_content_container` field set so other
    // managers (like LoadingStateManager) that still reference
    // `window.main_content_container` continue to work during refactor.
    try { this.main_content_container = content_view.main_content_container; } catch (GLib.Error e) { }
    layout_manager.hero_container = content_view.hero_container;
    layout_manager.featured_box = content_view.featured_box;
    layout_manager.columns_row = content_view.columns_row;
    layout_manager.content_area = content_view.content_area;
    // Ensure UI containers are visible after wiring
    try { layout_manager.hero_container?.set_visible(true); } catch (GLib.Error e) { }
    try { layout_manager.columns_row?.set_visible(true); } catch (GLib.Error e) { }
    try { content_box?.set_visible(true); } catch (GLib.Error e) { }
    // Ensure hero container visibility via helper
    layout_manager.ensure_hero_container_visible();
    // Wire loading/overlay widgets into LoadingStateManager (manager owns these now)
    loading_state = new Managers.LoadingStateManager(this);
    loading_state.loading_container = content_view.loading_container;
    loading_state.loading_spinner = content_view.loading_spinner;
    loading_state.loading_label = content_view.loading_label;
    loading_state.personalized_message_box = content_view.personalized_message_box;
    loading_state.personalized_message_label = content_view.personalized_message_label;
    loading_state.personalized_message_sub_label = content_view.personalized_message_sub_label;
    loading_state.personalized_message_action = content_view.personalized_message_action;
    loading_state.local_news_message_box = content_view.local_news_message_box;
    loading_state.local_news_title = content_view.local_news_title;
    loading_state.local_news_hint = content_view.local_news_hint;
    loading_state.local_news_button = content_view.local_news_button;
    loading_state.error_message_box = content_view.error_message_box;
    loading_state.error_icon = content_view.error_icon;
    loading_state.error_message_label = content_view.error_message_label;
    loading_state.error_retry_button = content_view.error_retry_button;

    // Ensure all overlay widgets are initially hidden
    try { if (loading_state.loading_container != null) loading_state.loading_container.set_visible(false); } catch (GLib.Error e) { }
    try { if (loading_state.personalized_message_box != null) loading_state.personalized_message_box.set_visible(false); } catch (GLib.Error e) { }
    try { if (loading_state.local_news_message_box != null) loading_state.local_news_message_box.set_visible(false); } catch (GLib.Error e) { }
    try { if (loading_state.error_message_box != null) loading_state.error_message_box.set_visible(false); } catch (GLib.Error e) { }

    // Ensure local-news UI is updated once widgets are wired. This makes
    // our debug logging in LoadingStateManager visible during startup.
    try { if (loading_state != null) loading_state.update_local_news_ui(); } catch (GLib.Error e) { }

    // Initialize HeaderManager and wire its widget references
    header_manager = new HeaderManager(this);
    header_manager.category_label = category_label;
    header_manager.category_subtitle = category_subtitle;
    header_manager.category_icon_holder = category_icon_holder;
    header_manager.source_label = source_label;
    header_manager.source_logo = source_logo;

    // LoadingStateManager already initialized and wired above

    // Split view: sidebar + content with adaptive collapsible sidebar
    split_view = new Adw.NavigationSplitView();
    split_view.set_min_sidebar_width(266);
    split_view.set_max_sidebar_width(266);
    // Wrap content in a NavigationView so we can slide in a preview page
    nav_view = new Adw.NavigationView();
    var main_page = new Adw.NavigationPage(main_scrolled, "Main");
    nav_view.push(main_page);

    // Create a root overlay that wraps the NavigationView so we can
    // overlay the personalized-message box across the entire visible
    // viewport (not just the inner scrolled content). This makes centering
    // reliable regardless of scroll/content size.
    root_overlay = new Gtk.Overlay();
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
                    if (view_state != null && view_state.last_previewed_url != null && view_state.last_previewed_url.length > 0) {
                        preview_closed(view_state.last_previewed_url);
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
    preview_scrolled.set_hexpand(false);
    preview_scrolled.set_propagate_natural_width(false);

    // Wrap scrolled window in a box for proper rounded corner rendering
    var preview_wrapper = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
    preview_wrapper.append(preview_scrolled);
    preview_wrapper.set_vexpand(true);
    preview_wrapper.set_hexpand(false);
    preview_wrapper.add_css_class("article-preview-panel");
    
    article_preview_split.set_sidebar(preview_wrapper);
    
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
                if (view_state != null && view_state.last_previewed_url != null && view_state.last_previewed_url.length > 0) {
                    preview_closed(view_state.last_previewed_url);
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
    try { if (loading_state.personalized_message_box != null) root_overlay.add_overlay(loading_state.personalized_message_box); } catch (GLib.Error e) { }

    // Reparent the initial loading spinner overlay from the inner
    // `main_overlay` to `root_overlay` so it truly centers within the
    // visible viewport (not just the scrolled content area). Use a
    // best-effort approach and ignore errors during early initialization.
    try {
        if (loading_state.loading_container != null) {
            try { content_view.main_overlay.remove_overlay(loading_state.loading_container); } catch (GLib.Error e) { }
            try { root_overlay.add_overlay(loading_state.loading_container); } catch (GLib.Error e) { }
        }
    } catch (GLib.Error e) { }

    // Local News overlay: use the `ContentView`-provided `local_news_message_box`
    // and wire its button to open the Set Location prefs dialog. Add it as
    // an overlay so it appears on top of the content when needed.
    try {
        if (loading_state.local_news_button != null) {
            loading_state.local_news_button.clicked.connect(() => {
                try { location_dialog.show(this); } catch (GLib.Error e) { }
            });
        }
    } catch (GLib.Error e) { }

    // My Feed overlay: wire the "Select news sources" button to open the sources dialog
    try {
        if (loading_state.personalized_message_action != null) {
            loading_state.personalized_message_action.clicked.connect(() => {
                try { PrefsDialog.show_preferences_dialog(this); } catch (GLib.Error e) { }
            });
        }
    } catch (GLib.Error e) { }

    try { if (loading_state.local_news_message_box != null) root_overlay.add_overlay(loading_state.local_news_message_box); } catch (GLib.Error e) { }

    // Add error message overlay and wire up retry button
    try {
        if (loading_state.error_retry_button != null) {
            loading_state.error_retry_button.clicked.connect(() => {
                try {
                    if (loading_state.error_message_box != null) loading_state.error_message_box.set_visible(false);
                    fetch_news();
                } catch (GLib.Error e) { }
            });
        }
    } catch (GLib.Error e) { }
    try { if (loading_state.error_message_box != null) root_overlay.add_overlay(loading_state.error_message_box); } catch (GLib.Error e) { }

    // Create the in-app article sheet overlay (WebKit-based) and add it
    try {
        this.article_sheet = new ArticleSheet(this);
        try { root_overlay.add_overlay(this.article_sheet.get_widget()); } catch (GLib.Error e) { }
    } catch (GLib.Error e) { }

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
        try { if (sidebar_manager != null) sidebar_manager.set_revealed(active); } catch (GLib.Error e) { }
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

        // Wrap split_view with toast overlay for notifications
        toast_overlay = new Adw.ToastOverlay();
        toast_overlay.set_child(split_view);
        set_content(toast_overlay);

        // Initialize toast manager with root_overlay so custom toasts
        // can be positioned in the content area without blocking scrolling
        toast_manager = new ToastManager(root_overlay);

        // Initialize feed update manager for automatic RSS feed updates
        feed_updater = new FeedUpdateManager(this);

        // Create session with timeout (max_conns properties are read-only in libsoup3)
        session = new Soup.Session() {
            timeout = 15 // Default timeout in seconds
        };

        // Initialize article window with image handler for loading preview images
        article_pane = new ArticlePane(nav_view, session, this, image_handler);
        article_pane.set_preview_overlay(article_preview_split, article_preview_content);

        // Add keyboard event controller for closing article preview with Escape
        var key_controller = new Gtk.EventControllerKey();
        key_controller.key_pressed.connect((keyval, keycode, state) => {
            // Escape: close preview
            if (keyval == Gdk.Key.Escape && article_preview_split.get_show_sidebar()) {
                // Close the preview pane visually first
                article_preview_split.set_show_sidebar(false);
                try {
                    if (view_state != null && view_state.last_previewed_url != null && view_state.last_previewed_url.length > 0) {
                        preview_closed(view_state.last_previewed_url);
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
                    if (view_state != null && view_state.last_previewed_url != null && view_state.last_previewed_url.length > 0) {
                        preview_closed(view_state.last_previewed_url);
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

        // Update RSS feeds in background after a short delay (2 seconds)
        // This gives the app time to fully initialize before starting network requests
        if (feed_updater != null) {
            GLib.Timeout.add_seconds(2, () => {
                feed_updater.update_all_feeds_async();
                return false; // One-shot
            });
        }

    // Ensure the personalized message visibility is correct at startup
    update_personalization_ui();

        // Clear only cached in-memory images on window close to free textures
        // while preserving per-article metadata (e.g., viewed flags) on disk.
        this.close_request.connect(() => {
            try {
                // Clear any paintables held by window-level widgets to release textures
                try { if (source_logo != null) source_logo.set_from_paintable(null); } catch (GLib.Error e) { }
            } catch (GLib.Error e) { }
            if (image_cache != null) {
                try { image_cache.clear(); } catch (GLib.Error e) { }
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
            try { cache_size = image_cache != null ? image_cache.size() : ImageCache.get_global().size(); } catch (GLib.Error e) { cache_size = -1; }
            append_debug_log("DEBUG: image_cache.size=" + cache_size.to_string());

            // If the cache supports key enumeration, dump each entry and pixbuf dimensions
            try {
                var keys = image_cache != null ? image_cache.keys() : ImageCache.get_global().keys();
                int key_count = 0;
                try { key_count = keys.size; } catch (GLib.Error e) { key_count = 0; }
                append_debug_log("DEBUG: image_cache.keys_count=" + key_count.to_string());
                for (int i = 0; i < keys.size; i++) {
                    string k = keys.get(i);
                    try {
                        var pb = image_cache != null ? image_cache.get(k) : ImageCache.get_global().get(k);
                        if (pb != null) {
                            int w = 0; int h = 0;
                            try { w = pb.get_width(); } catch (GLib.Error e) { }
                            try { h = pb.get_height(); } catch (GLib.Error e) { }
                            append_debug_log("DEBUG: cache_entry: " + k.to_string() + " => pixbuf " + w.to_string() + "x" + h.to_string());
                        } else {
                            append_debug_log("DEBUG: cache_entry: " + k.to_string() + " => <null pixbuf>");
                        }
                    } catch (GLib.Error e) {
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
                if (view_state != null) {
                    foreach (var kv in view_state.url_to_picture.entries) {
                        try {
                            var pic = kv.value;
                            var p = pic.get_paintable();
                            if (p is Gdk.Texture) {
                                set.add((Gdk.Texture)p);
                            }
                        } catch (GLib.Error e) { }
                    }
                }
                widget_tex_count = set.size;
            } catch (GLib.Error e) { widget_tex_count = -1; }

            append_debug_log("DEBUG: unique_textures_referenced_by_widgets=" + widget_tex_count.to_string());

            // Report total registered pictures and pending downloads
            int pictures_registered = 0;
            try { pictures_registered = view_state != null ? view_state.url_to_picture.size : 0; } catch (GLib.Error e) { pictures_registered = -1; }
            int pending = 0;
            try { pending = pending_downloads.size; } catch (GLib.Error e) { pending = -1; }
            append_debug_log("DEBUG: url_to_picture.count=" + pictures_registered.to_string() + " pending_downloads.count=" + pending.to_string());
        } catch (GLib.Error e) {
            // best-effort only
        }
    }

    public void update_category_icon() {
        try { if (header_manager != null) header_manager.update_category_icon(); } catch (GLib.Error e) { }
    }

    private void update_content_header() {
        try { if (header_manager != null) header_manager.update_content_header(); } catch (GLib.Error e) { }
    }

    private void update_content_header_now() {
        try { if (header_manager != null) header_manager.update_content_header_now(); } catch (GLib.Error e) { }
    }

    // Delegate personalization UI updates to the LoadingStateManager
    public void update_personalization_ui() {
        try { if (loading_state != null) loading_state.update_personalization_ui(); } catch (GLib.Error e) { }
    }

    // Show or hide the Local News guidance overlay depending on whether
    // the user has configured a location and whether Local News is active.
    // Delegate local-news UI updates to the LoadingStateManager
    public void update_local_news_ui() {
        try { if (loading_state != null) loading_state.update_local_news_ui(); } catch (GLib.Error e) { }
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
        try { if (sidebar_manager != null) sidebar_manager.update_for_source_change(); } catch (GLib.Error e) { }
    }

    // SidebarManager handles sidebar icon updates on theme changes now.

    public string category_display_name_for(string cat) {
        try { if (header_manager != null) return header_manager.category_display_name_for(cat); } catch (GLib.Error e) { }
        // Fallback: if header_manager not ready, return a simple humanized label
        if (cat == null || cat.length == 0) return "News";
        string s = cat.strip();
        if (s.length == 0) return "News";
        s = s.replace("_", " ").replace("-", " ");
        string out = "";
        string[] parts = s.split(" ");
        foreach (var p in parts) {
            if (p.length == 0) continue;
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

    public Gtk.Widget build_category_chip(string category_id) {
        return CardBuilder.build_category_chip(this, category_id);
    }

    public string get_source_name(NewsSource source) {
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
        if (url == null || url.length == 0) return NewsSource.UNKNOWN;
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
        // Unknown source - don't default to user preference to avoid incorrect branding
        return NewsSource.UNKNOWN;
    }

    // Resolve a NewsSource from a provided display/source name if possible;
    // fall back to URL inference when the name is missing or unrecognized.
    public NewsSource resolve_source(string? source_name, string url) {
        // Parse encoded source name format: "SourceName||logo_url##category::cat"
        string? clean_name = source_name;
        if (source_name != null && source_name.length > 0) {
            // Strip logo URL if present
            int pipe_idx = source_name.index_of("||");
            if (pipe_idx >= 0 && source_name.length > pipe_idx) {
                clean_name = source_name.substring(0, pipe_idx).strip();
            }
            // Strip category suffix if present
            int cat_idx = clean_name.index_of("##category::");
            if (cat_idx >= 0 && clean_name.length > cat_idx) {
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
            else if (low.index_of("nytimes") >= 0) resolved = NewsSource.NEW_YORK_TIMES;
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
    public Gtk.Widget build_source_badge_dynamic(string? source_name, string url, string category_id) {
        return CardBuilder.build_source_badge_dynamic(this, source_name, url, category_id);
    }

    // Build a small source badge widget (icon + short name) to place in the
    // top-right corner of cards and hero slides.
    private Gtk.Widget build_source_badge(NewsSource source) {
        return CardBuilder.build_source_badge(source);
    }

    // Build a small 'Viewed' badge with a check icon to place in the top-right
    // corner of a card/hero when the user has already opened the preview.
    private Gtk.Widget build_viewed_badge() {
        return CardBuilder.build_viewed_badge();
    }

    // Delegate marking an article viewed to the ViewStateManager
    public void mark_article_viewed(string url) {
        try { if (view_state != null) view_state.mark_article_viewed(url); } catch (GLib.Error e) { }
    }

    // Delegate preview-opened handling to the ViewStateManager
    public void preview_opened(string url) {
        try { if (view_state != null) view_state.preview_opened(url); } catch (GLib.Error e) { }
    }

    // Delegate preview-closed handling to the ViewStateManager
    public void preview_closed(string url) {
        try { if (view_state != null) view_state.preview_closed(url); } catch (GLib.Error e) { }
    }

    public void show_toast(string message) {
        if (toast_manager != null) {
            toast_manager.show_toast(message);
        }
    }

    public void show_persistent_toast(string message) {
        if (toast_manager != null) {
            toast_manager.show_persistent_toast(message);
        }
    }

    // Cleanup stale downloads to prevent unbounded HashMap growth and memory leaks
    public void cleanup_stale_downloads() {
        download_mutex.lock();
        try {
            const int MAX_PENDING_DOWNLOADS = 100;
            
            // If pending_downloads exceeds threshold, clear oldest entries
            if (pending_downloads.size > MAX_PENDING_DOWNLOADS) {
                warning("cleanup_stale_downloads: pending_downloads size=%d exceeds limit, clearing oldest entries", pending_downloads.size);
                
                // Clear half of the entries to avoid frequent cleanup
                int to_remove = pending_downloads.size / 2;
                var keys_to_remove = new Gee.ArrayList<string>();
                
                // Collect keys to remove (can't modify HashMap while iterating)
                int count = 0;
                foreach (var entry in pending_downloads.entries) {
                    if (count >= to_remove) break;
                    keys_to_remove.add(entry.key);
                    count++;
                }
                
                // Remove collected keys
                foreach (var key in keys_to_remove) {
                    try {
                        pending_downloads.unset(key);
                        requested_image_sizes.unset(key);
                    } catch (GLib.Error e) { }
                }
                
                warning("cleanup_stale_downloads: removed %d stale entries, new size=%d", keys_to_remove.size, pending_downloads.size);
            }
        } catch (GLib.Error e) {
            warning("cleanup_stale_downloads: error during cleanup: %s", e.message);
        } finally {
            download_mutex.unlock();
        }
    }

    public void clear_persistent_toast() {
        if (toast_manager != null) {
            toast_manager.clear_persistent_toast();
        }
    }

    public void show_share_dialog(string url) {
        if (article_pane != null) {
            article_pane.show_share_dialog(url);
        }
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

    // RSS feed specific placeholder: use the RSS feed's source logo from source_logos directory
    public void set_rss_placeholder_image(Gtk.Picture image, int width, int height, string source_name) {
        try {
            PlaceholderBuilder.set_rss_placeholder_image(image, width, height, source_name);
            return;
        } catch (GLib.Error e) {
            // Fallback to text-based placeholder with source name
            try { PlaceholderBuilder.create_source_text_placeholder(image, source_name, NewsSource.GUARDIAN, width, height); } catch (GLib.Error ee) { }
        }
    }

    private void create_gradient_placeholder(Gtk.Picture image, int width, int height) {
        try { PlaceholderBuilder.create_gradient_placeholder(image, width, height); } catch (GLib.Error e) { }
    }

    // Layout-related logic has been moved to LayoutManager; delegate to it.
    public int estimate_content_width() {
        try { if (layout_manager != null) return layout_manager.estimate_content_width(); } catch (GLib.Error e) { }
        return 1280;
    }

    private void update_main_content_size(bool sidebar_visible) {
        try { if (layout_manager != null) layout_manager.update_main_content_size(sidebar_visible); } catch (GLib.Error e) { }
    }

    private void update_existing_hero_card_size() {
        try { if (layout_manager != null) layout_manager.update_existing_hero_card_size(); } catch (GLib.Error e) { }
    }

    public void maybe_refetch_hero_for(Gtk.Picture pic, HeroRequest info) {
        try { if (layout_manager != null) layout_manager.maybe_refetch_hero_for(pic, info); } catch (GLib.Error e) { }
    }

    private int estimate_column_width(int cols) {
        try { if (layout_manager != null) return layout_manager.estimate_column_width(cols); } catch (GLib.Error e) { }
        return 200;
    }

    private void rebuild_columns(int count) {
        try { if (layout_manager != null) layout_manager.rebuild_columns(count); } catch (GLib.Error e) { }
    }
    
    private void show_loading_spinner() {
        try { if (loading_state != null) loading_state.show_loading_spinner(); } catch (GLib.Error e) { }
    }
    
    public void hide_loading_spinner() {
        try { if (loading_state != null) loading_state.hide_loading_spinner(); } catch (GLib.Error e) { }
    }

    // Show the global error overlay. If `msg` is provided it will be shown
    // in the overlay label; otherwise we use a generic "no articles" text.
    private void show_error_message(string? msg = null) {
        try { if (loading_state != null) loading_state.show_error_message(msg); } catch (GLib.Error e) { }
        
        // Also show a user-visible toast for immediate feedback
        string toast_msg = msg != null && msg.length > 0 ? msg : "Failed to load articles. Please try again.";
        try { show_toast(toast_msg); } catch (GLib.Error e) { }
    }

    private void hide_error_message() {
        try { if (loading_state != null) loading_state.hide_error_message(); } catch (GLib.Error e) { }
    }

    // Reveal main content (stop showing the loading spinner)
    private void reveal_initial_content() {
        try { if (loading_state != null) loading_state.reveal_initial_content(); } catch (GLib.Error e) { }
    }

    // Helper to form memory cache keys that include requested size
    public string make_cache_key(string url, int w, int h) {
        // Use deterministic pixbuf keys: origin=url, include size
        return "pixbuf::url:%s::%dx%d".printf(url, w, h);
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
    public void upgrade_images_after_initial() {
        // Be conservative: smaller batches and longer pause to avoid
        // saturating network/CPU and doing many main-thread decodes.
        const int UPGRADE_BATCH_SIZE = 3;
        int processed = 0;

        if (view_state != null) {
            foreach (var kv in view_state.url_to_picture.entries) {
                // kv.key is the normalized article URL
                string norm_url = kv.key;
                Gtk.Picture? pic = kv.value;
                if (pic == null) continue;

                // Look up the last requested size (may be stored under normalized key)
                var rec = requested_image_sizes.get(norm_url);
                if (rec == null || rec.length == 0) continue;
                string[] parts = rec.split("x");
                if (parts.length < 2) continue;
                int last_w = 0; int last_h = 0;
                try { last_w = int.parse(parts[0]); last_h = int.parse(parts[1]); } catch (GLib.Error e) { continue; }

                int new_w = (int)(last_w * 2);
                int new_h = (int)(last_h * 2);
                new_w = layout_manager.clampi(new_w, last_w, 1600);
                new_h = layout_manager.clampi(new_h, last_h, 1600);

                // Check memory cache for both normalized-keyed and original-keyed entries
                bool has_large = false;
                string key_norm = make_cache_key(norm_url, new_w, new_h);
                if ((image_cache != null ? image_cache.get(key_norm) : ImageCache.get_global().get(key_norm)) != null) has_large = true;

                string? original = null;
                try { if (view_state != null) original = view_state.normalized_to_url.get(norm_url); } catch (GLib.Error e) { original = null; }
                if (!has_large && original != null) {
                    string key_orig = make_cache_key(original, new_w, new_h);
                    if ((image_cache != null ? image_cache.get(key_orig) : ImageCache.get_global().get(key_orig)) != null) has_large = true;
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
        }
        // finished all entries (no-op)
    }

    // Called when an image finished being set on a Picture. If it's a hero image and we're
    // Called when an image finished being set (success or fallback). During the
    // initial phase we decrement the pending counter and reveal the UI when all
    // initial items are populated and no pending image loads remain.
    public void on_image_loaded(Gtk.Picture image) {
        if (loading_state == null) return;
        if (!loading_state.initial_phase) return;
        if (hero_requests.get(image) != null) loading_state.hero_image_loaded = true;
        if (loading_state.pending_images > 0) loading_state.pending_images--;

        if (loading_state.initial_items_populated && loading_state.pending_images == 0) {
            try { loading_state.reveal_initial_content(); } catch (GLib.Error e) { }
        }
    }

    // Helper to mark that initial items have been added to the UI. If there are
    // no pending image loads, reveal the UI immediately.
    public void mark_initial_items_populated() {
        try { if (loading_state != null) loading_state.mark_initial_items_populated(); } catch (GLib.Error e) { }
    }

    // Clean up memory by releasing old textures and widget references
    private void cleanup_old_content() {
        // Force clear all Picture widgets to release texture references
        foreach (var pic in view_state != null ? view_state.url_to_picture.values : new Gee.ArrayList<Gtk.Picture>()) {
            pic.set_paintable(null);
        }
        
        // Clear URL-to-widget mappings (these should auto-cleanup via destroy signals, but ensure)
        try { if (view_state != null) view_state.url_to_picture.clear(); } catch (GLib.Error e) { }
        try { if (view_state != null) view_state.url_to_card.clear(); } catch (GLib.Error e) { }
        try { if (view_state != null) view_state.normalized_to_url.clear(); } catch (GLib.Error e) { }
        
        // Clear pending downloads
        pending_downloads.clear();
        
        // Clear hero requests
        hero_requests.clear();
        
        // Clear deferred downloads
        deferred_downloads.clear();
        
        // Clear requested image sizes
        requested_image_sizes.clear();
        
        // Clear the centralized ImageCache (pixbufs) and preview cache.
        // Suppress clearing here to avoid excessive eviction when switching
        // categories; rely on the LRU policy instead. Window-close still
        // frees widget-held textures elsewhere.
        try {
            if (AppDebugger.debug_enabled()) {
                try { stderr.printf("DEBUG: suppressed ImageCache.clear() during category navigation\n"); } catch (GLib.Error e) { }
            }
        } catch (GLib.Error e) { }
    }

    public void fetch_news() {
        // Clean up stale downloads to prevent memory leaks
        try { cleanup_stale_downloads(); } catch (GLib.Error e) { }
        
        // Debug: log fetch_news invocation and current sequence
        try {
            string? _dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
            if (_dbg != null && _dbg.length > 0) {
                append_debug_log("fetch_news: entering seq=" + fetch_sequence.to_string() + " category=" + prefs.category + " preferred_sources=" + AppDebugger.array_join(prefs.preferred_sources));
            }
        } catch (GLib.Error e) { }

        // Clear all old articles and widgets before loading new category
        try { if (article_manager != null) article_manager.clear_articles(); } catch (GLib.Error e) { }

        // Clear old article tracking for this category so unread counts reflect current content
        if (article_state_store != null && prefs.category != null && prefs.category.length > 0) {
            // Set badge to placeholder before clearing article tracking
            // This prevents showing partial counts during async article loading
            if (sidebar_manager != null) {
                sidebar_manager.set_badge_placeholder_for_category(prefs.category);
            }

            article_state_store.clear_article_tracking_for_category(prefs.category);
            // Refresh badge after loading completes with a delay to ensure all async registration finishes
            // This replaces the "--" placeholder with the actual count
            string current_cat = prefs.category;
            weak NewsWindow? weak_self = this;
            GLib.Timeout.add(2000, () => {
                if (weak_self != null && weak_self.sidebar_manager != null) {
                    weak_self.sidebar_manager.update_badge_for_category(current_cat);
                }
                return false;
            });
        }

        // Ensure sidebar visibility reflects current source
        update_sidebar_for_source();
        // Clear featured hero and randomize columns count per fetch between 2 and 4 for extra variety
        // Clear featured and destroy widgets
        Gtk.Widget? fchild = layout_manager.featured_box.get_first_child();
        while (fchild != null) {
            Gtk.Widget? next = fchild.get_next_sibling();
            try {
                var parent = fchild.get_parent();
                stderr.printf("TRACE remove: featured_box.remove child=%p parent_is_featured_box=%s\n", fchild, (parent == layout_manager.featured_box) ? "YES" : "NO");
            } catch (GLib.Error e) { }
            layout_manager.featured_box.remove(fchild);
            fchild.unparent();
            fchild = next;
        }
        article_manager.featured_used = false;
        // Reset featured carousel state so new category fetches start fresh
            if (article_manager.hero_carousel != null) {
            article_manager.hero_carousel.stop_timer();
            try {
                if (article_manager.hero_carousel.container != null) {
                    try {
                        var parent = article_manager.hero_carousel.container.get_parent();
                        stderr.printf("TRACE remove: featured_box.remove hero_carousel.container parent_is_featured_box=%s\n", (parent == layout_manager.featured_box) ? "YES" : "NO");
                    } catch (GLib.Error e) { }
                    layout_manager.featured_box.remove(article_manager.hero_carousel.container);
                }
            } catch (GLib.Error e) { }
            article_manager.hero_carousel = null;
        }
        if (article_manager.featured_carousel_items != null) {
            article_manager.featured_carousel_items.clear();
        }

        // Restore hero/featured container visibility (may have been hidden by RSS adaptive layout)
        try {
            if (layout_manager.hero_container != null) {
                layout_manager.hero_container.set_visible(true);
            }
        } catch (GLib.Error e) { }
        try {
            if (layout_manager.featured_box != null) {
                layout_manager.featured_box.set_visible(true);
            }
        } catch (GLib.Error e) { }
        article_manager.featured_carousel_category = null;
        
        // Clear hero_container for Top Ten (remove all children including featured_box)
        // For other categories, hero_container should just have featured_box
        if (category_manager.is_topten_view()) {
            // Remove and destroy all children from hero_container
            Gtk.Widget? hchild = layout_manager.hero_container.get_first_child();
            while (hchild != null) {
                Gtk.Widget? next = hchild.get_next_sibling();
                try {
                    var parent = hchild.get_parent();
                    stderr.printf("TRACE remove: hero_container.remove child=%p parent_is_hero_container=%s\n", hchild, (parent == layout_manager.hero_container) ? "YES" : "NO");
                } catch (GLib.Error e) { }
                layout_manager.hero_container.remove(hchild);
                hchild.unparent();
                hchild = next;
            }
            article_manager.topten_hero_count = 0;
        } else {
            // For non-topten views, clear and destroy everything first then add featured_box
            Gtk.Widget? hchild = layout_manager.hero_container.get_first_child();
            while (hchild != null) {
                Gtk.Widget? next = hchild.get_next_sibling();
                layout_manager.hero_container.remove(hchild);
                hchild.unparent();
                hchild = next;
            }
            // Now add featured_box for carousel
            layout_manager.hero_container.append(layout_manager.featured_box);
        }
        
        // Top Ten uses special 2-row grid layout (2 heroes + 2 rows of 4 cards)
        // Other categories use standard 3-column masonry
        if (category_manager.is_topten_view()) {
            rebuild_columns(4); // 4 columns for grid layout
        } else {
            rebuild_columns(3); // Standard masonry
        }
        
        // Clean up memory: clear image caches and widget references
        cleanup_old_content();
        
        // Reset category distribution tracking for new content
        article_manager.category_column_counts.clear();
        article_manager.recent_categories.clear();
        article_manager.next_column_index = 0;
        article_buffer.clear();
        article_manager.category_last_column.clear();
        
        // Clean up category tracking
        article_manager.recent_category_queue.clear();
        articles_shown = 0;

        // Adjust preview cache size for Local News view to conserve memory.
        // Local News can have many items; reduce preview cache to a small number
        // when active. Restore default capacity for other views.
        try {
            if (category_manager.is_local_news_view()) {
                try { PreviewCacheManager.get_cache().set_capacity(6); } catch (GLib.Error e) { }
            } else {
                try { PreviewCacheManager.get_cache().set_capacity(12); } catch (GLib.Error e) { }
            }
        } catch (GLib.Error e) { }
        
        // Cancel any pending buffer flush
        if (article_manager.buffer_flush_timeout_id > 0) {
            Source.remove(article_manager.buffer_flush_timeout_id);
            article_manager.buffer_flush_timeout_id = 0;
        }
        
        // Clear remaining articles from previous session
        remaining_articles = null;
        article_manager.remaining_articles_index = 0;
        
        // Remove any existing Load More button - now managed by ArticleManager
        // (ArticleManager will handle button cleanup internally)
        
        // If the user selected "My Feed" but personalization is disabled,
        // show the personalized overlay and return (no content should be fetched).
        bool is_myfeed_category = category_manager.is_myfeed_category();

        bool is_myfeed_disabled = (is_myfeed_category && !prefs.personalized_feed_enabled);
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
        if (loading_state != null) {
            loading_state.initial_phase = true;
            loading_state.hero_image_loaded = false;
            loading_state.pending_images = 0;
            loading_state.initial_items_populated = false;
            loading_state.network_failure_detected = false;
            if (loading_state.initial_reveal_timeout_id > 0) {
                Source.remove(loading_state.initial_reveal_timeout_id);
                loading_state.initial_reveal_timeout_id = 0;
            }
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
        if (loading_state != null) {
            loading_state.initial_reveal_timeout_id = Timeout.add(INITIAL_MAX_WAIT_MS, () => {
                if (!self_ref.loading_state.initial_items_populated) {
                    try {
                        if (self_ref.loading_state.network_failure_detected) {
                            self_ref.show_error_message("No network connection detected. Check your connection and try again.");
                        } else {
                            self_ref.show_error_message();
                        }
                    } catch (GLib.Error e) { }
                } else {
                    self_ref.reveal_initial_content();
                }
                self_ref.loading_state.initial_reveal_timeout_id = 0;
                return false;
            });
        }
        
        
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
                            if (self_ref.loading_state != null) self_ref.loading_state.network_failure_detected = true;
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
        // Ensure we only clear once per fetch: some fetchers may call the
        // provided clear callback multiple times during retries/fallbacks.
        bool wrapped_clear_ran = false;
        ClearItemsFunc wrapped_clear = () => {
            // Schedule the clear on the main loop to avoid worker-thread UI access
            Idle.add(() => {
                if (my_seq != self_ref.fetch_sequence) {
                    try { if (GLib.Environment.get_variable("PAPERBOY_DEBUG") != null) append_debug_log("wrapped_clear: ignoring stale seq=" + my_seq.to_string() + " current=" + self_ref.fetch_sequence.to_string()); } catch (GLib.Error e) { }
                    return false;
                }
                // Guard: make this clear idempotent per-fetch
                if (wrapped_clear_ran) {
                    try { if (GLib.Environment.get_variable("PAPERBOY_DEBUG") != null) append_debug_log("wrapped_clear: already ran for seq=" + my_seq.to_string()); } catch (GLib.Error e) { }
                    return false;
                }
                wrapped_clear_ran = true;

                // Log execution of wrapped_clear so we can correlate clears with fetch sequences and view
                long _ts = (long) GLib.get_monotonic_time();
                try { stderr.printf("TRACE wrapped_clear: time=%lld executing seq=%u current=%u category=%s\n", _ts, my_seq, self_ref.fetch_sequence, self_ref.prefs.category); } catch (GLib.Error e) { }
                // Clearing was already done above in fetch_news(), but some sources
                // call clear_items again from worker threads; guard to avoid
                // clearing content created by a newer fetch.
                Gtk.Widget? cur = self_ref.layout_manager.featured_box.get_first_child();
                while (cur != null) {
                    Gtk.Widget? next = cur.get_next_sibling();
                                    try {
                                        var parent = cur.get_parent();
                                        stderr.printf("TRACE wrapped_clear: featured_box.remove child=%p parent_is_featured_box=%s time=%lld\n", cur, (parent == self_ref.layout_manager.featured_box) ? "YES" : "NO", (long) GLib.get_monotonic_time());
                                    } catch (GLib.Error e) { }
                    self_ref.layout_manager.featured_box.remove(cur);
                    cur = next;
                }
                self_ref.article_manager.featured_used = false;
                // Remove columns' children
                        for (int i = 0; i < self_ref.layout_manager.columns.length; i++) {
                            Gtk.Widget? curc = self_ref.layout_manager.columns[i].get_first_child();
                            while (curc != null) {
                                Gtk.Widget? next = curc.get_next_sibling();
                                try {
                                    var parent = curc.get_parent();
                                    stderr.printf("TRACE wrapped_clear: column[%d].remove child=%p parent_is_column=%s time=%lld\n", i, curc, (parent == self_ref.layout_manager.columns[i]) ? "YES" : "NO", (long) GLib.get_monotonic_time());
                                } catch (GLib.Error e) { }
                                self_ref.layout_manager.columns[i].remove(curc);
                                curc = next;
                            }
                            self_ref.layout_manager.column_heights[i] = 0;
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
                            try {
                                var parent = label.get_parent();
                                stderr.printf("TRACE wrapped_clear: content_box.remove label=%p parent_is_content_box=%s time=%lld\n", label, (parent == self_ref.content_box) ? "YES" : "NO", (long) GLib.get_monotonic_time());
                            } catch (GLib.Error e) { }
                            self_ref.content_box.remove(label);
                            break;
                        }
                    }
                }
                // Ensure any load-more button managed by ArticleManager is removed
                try { self_ref.article_manager.clear_load_more_button(); } catch (GLib.Error e) { }
                
                // Also clear image bookkeeping so subsequent fetches create
                // fresh widgets instead of updating removed ones.
                try { if (self_ref.view_state != null) self_ref.view_state.url_to_picture.clear(); } catch (GLib.Error e) { }
                try { self_ref.hero_requests.clear(); } catch (GLib.Error e) { }
                self_ref.remaining_articles = null;
                article_manager.remaining_articles_index = 0;
                // Note: load_more_button is now managed by ArticleManager
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
                self_ref.prefs.category == "lifestyle" ||
                self_ref.prefs.category == "markets" ||
                self_ref.prefs.category == "industries" ||
                self_ref.prefs.category == "economics" ||
                self_ref.prefs.category == "wealth" ||
                self_ref.prefs.category == "green"
                || self_ref.prefs.category == "local_news"
                || self_ref.prefs.category == "myfeed"
            );
                        
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
                                    self_ref.article_manager.add_item(ai.title, ai.url, ai.thumbnail_url, ai.category_id, ai.source_name);
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
            
            // Track RSS feed articles for adaptive layout
            if (self_ref.category_manager.is_rssfeed_view()) {
                self_ref.rss_feed_article_count++;
                                
                // Cancel any existing timeout and schedule a new one
                // This ensures we wait until all articles have arrived
                if (self_ref.rss_feed_layout_timeout_id > 0) {
                    Source.remove(self_ref.rss_feed_layout_timeout_id);
                }
                
                // Schedule layout check after 500ms of no new articles
                self_ref.rss_feed_layout_timeout_id = Timeout.add(500, () => {
                    if (my_seq != self_ref.fetch_sequence) {
                        self_ref.rss_feed_layout_timeout_id = 0;
                        return false;
                    }
                    
                    // Check if we need to adapt the layout
                    if (self_ref.rss_feed_article_count < 15) {
                        // Rebuild as 2-column hero layout
                        Idle.add(() => {
                            if (my_seq != self_ref.fetch_sequence) return false;
                            try {
                                self_ref.article_manager.rebuild_rss_feed_as_heroes();
                            } catch (GLib.Error e) { }
                            return false;
                        });
                    }
                    
                    self_ref.rss_feed_layout_timeout_id = 0;
                    return false;
                });
            }
            
            self_ref.article_manager.add_item(title, url, thumbnail, category_id, source_name);
        };

        // Support fetching from multiple preferred sources when the user
        // has enabled more than one in preferences. The preferences store
        // string ids (e.g. "guardian", "reddit"). Map those to the
        // NewsSource enum and invoke NewsService.fetch for each. Ensure
        // we only clear the UI once (for the first fetch) so subsequent
        // fetches append their results.
        bool used_multi = false;
        // Use CategoryManager for My Feed logic
        bool is_myfeed_mode = category_manager.is_myfeed_view();
        string[] myfeed_cats = new string[0];

        // Load custom RSS sources if in My Feed mode
        Gee.ArrayList<Paperboy.RssSource>? custom_rss_sources = null;
        if (is_myfeed_mode) {
            var rss_store = Paperboy.RssSourceStore.get_instance();
            var all_custom = rss_store.get_all_sources();
            custom_rss_sources = new Gee.ArrayList<Paperboy.RssSource>();

            // Filter to only enabled custom sources
            foreach (var src in all_custom) {
                if (prefs.preferred_source_enabled("custom:" + src.url)) {
                    custom_rss_sources.add(src);
                }
            }
        }

        if (is_myfeed_mode) {
            // Load personalized categories if configured (applies only to built-in sources)
            if (category_manager.is_myfeed_configured()) {
                var cats = category_manager.get_myfeed_categories();
                myfeed_cats = new string[cats.size];
                for (int i = 0; i < cats.size; i++) myfeed_cats[i] = cats.get(i);
            }

            // Check if we have ANY content to show (personalized categories OR custom RSS sources)
            bool has_personalized_cats = (myfeed_cats != null && myfeed_cats.length > 0);
            bool has_custom_rss = (custom_rss_sources != null && custom_rss_sources.size > 0);

            if (!has_personalized_cats && !has_custom_rss) {
                // No personalized categories AND no custom RSS sources - nothing to show
                try { wrapped_clear(); } catch (GLib.Error e) { }
                try { wrapped_set_label("My Feed — No personalized categories or custom RSS feeds configured"); } catch (GLib.Error e) { }
                hide_loading_spinner();
                return;
            }
        }

        // Saved Articles: display articles the user has saved for later
        if (prefs.category == "saved") {
            stderr.printf("[SAVED] Starting saved articles display, seq=%u\n", my_seq);

            try { self_ref.source_label.set_text("Saved Articles"); } catch (GLib.Error e) { }
            try { self_ref.source_logo.set_from_icon_name("user-bookmarks-symbolic"); } catch (GLib.Error e) { }

            if (article_state_store == null) {
                try { wrapped_set_label("Saved Articles — Unable to load saved articles"); } catch (GLib.Error e) { }
                hide_loading_spinner();
                return;
            }

            var saved_articles = article_state_store.get_saved_articles();

            // Filter by search query if provided
            if (current_search_query.length > 0) {
                var filtered_articles = new Gee.ArrayList<ArticleStateStore.SavedArticle?>();
                string query_lower = current_search_query.down();
                foreach (var article in saved_articles) {
                    if (article != null) {
                        string title_lower = article.title != null ? article.title.down() : "";
                        string url_lower = article.url != null ? article.url.down() : "";
                        if (title_lower.contains(query_lower) || url_lower.contains(query_lower)) {
                            filtered_articles.add(article);
                        }
                    }
                }
                saved_articles = filtered_articles;
            }

            stderr.printf("[SAVED] Got %d articles, current_seq=%u\n", saved_articles.size, self_ref.fetch_sequence);
            if (saved_articles.size == 0) {
                if (current_search_query.length > 0) {
                    try { wrapped_set_label(@"Saved Articles — No results for \"$(current_search_query)\""); } catch (GLib.Error e) { }
                } else {
                    try { wrapped_set_label("Saved Articles — No saved articles yet"); } catch (GLib.Error e) { }
                }
                hide_loading_spinner();
                return;
            }

            // Clear and repopulate in a single idle callback to ensure proper ordering
            Idle.add(() => {
                if (my_seq != self_ref.fetch_sequence) return false;

                // Set label based on search query
                if (current_search_query.length > 0) {
                    try { wrapped_set_label(@"Search Results: \"$(current_search_query)\" in Saved Articles"); } catch (GLib.Error e) { }
                } else {
                    try { wrapped_set_label("Saved Articles"); } catch (GLib.Error e) { }
                }

                // Clear columns
                for (int i = 0; i < self_ref.layout_manager.columns.length; i++) {
                    Gtk.Widget? child = self_ref.layout_manager.columns[i].get_first_child();
                    while (child != null) {
                        Gtk.Widget? next = child.get_next_sibling();
                        self_ref.layout_manager.columns[i].remove(child);
                        child = next;
                    }
                    self_ref.layout_manager.column_heights[i] = 0;
                }
                self_ref.article_buffer.clear();
                self_ref.articles_shown = 0;

                // Add saved articles immediately after clearing
                foreach (var article in saved_articles) {
                    if (article != null && my_seq == self_ref.fetch_sequence) {
                        try {
                            wrapped_add(article.title, article.url, article.thumbnail, "saved", article.source ?? "Saved");
                        } catch (GLib.Error e) { }
                    }
                }

                stderr.printf("[SAVED] Finished adding %d articles, seq=%u current_seq=%u\n", saved_articles.size, my_seq, self_ref.fetch_sequence);

                // Force queue draw to ensure UI updates - with bounds checking
                if (self_ref.layout_manager != null && self_ref.layout_manager.columns != null) {
                    if (self_ref.layout_manager.columns.length > 0) self_ref.layout_manager.columns[0].queue_draw();
                    if (self_ref.layout_manager.columns.length > 1) self_ref.layout_manager.columns[1].queue_draw();
                    if (self_ref.layout_manager.columns.length > 2) self_ref.layout_manager.columns[2].queue_draw();
                }

                self_ref.hide_loading_spinner();
                return false;
            });
            return;
        }

        // Local News: if the user selected the Local News sidebar item,
        // attempt to read per-user feeds from ~/.config/paperboy/local_feeds
        // and fetch each feed URL with the RSS parser. This allows the
        // rssFinder helper (a separate binary) to populate the file and
        // the app to display the resulting feeds.
        if (category_manager.is_local_news_view()) {
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
                    string cache_key = "pixbuf::file:%s::%dx%d".printf(use_path, 32, 32);
                    Gdk.Pixbuf? cached_pb = null;
                    try {
                        cached_pb = image_cache != null ? image_cache.get_or_load_file(cache_key, use_path, 32, 32) : ImageCache.get_global().get_or_load_file(cache_key, use_path, 32, 32);
                    } catch (GLib.Error e) { cached_pb = null; }
                    if (cached_pb != null) {
                        try {
                            var tex = Gdk.Texture.for_pixbuf(cached_pb);
                            try { self_ref.source_logo.set_from_paintable(tex); } catch (GLib.Error e) { try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { } }
                        } catch (GLib.Error e) {
                            try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { }
                        }
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
                article_manager.featured_used = true;
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

        // RSS Feed: if the user selected an individual RSS feed from the sidebar,
        // fetch articles from that specific feed URL using the RSS parser.
        if (category_manager.is_rssfeed_view()) {
            string? feed_url = category_manager.get_rssfeed_url();
            if (feed_url == null || feed_url.length == 0) {
                try { wrapped_set_label("RSS Feed — Invalid feed URL"); } catch (GLib.Error e) { }
                hide_loading_spinner();
                return;
            }

            // Get the RSS source details from the database
            var rss_store = Paperboy.RssSourceStore.get_instance();
            var rss_source = rss_store.get_source_by_url(feed_url);
            
            string feed_name = rss_source != null ? rss_source.name : "RSS Feed";
            
            // Clear UI and schedule feed fetch
            try { wrapped_clear(); } catch (GLib.Error e) { }
            ClearItemsFunc no_op_clear = () => { };
            // SIMPLIFIED: Just use a no-op label function to avoid closure issues
            SetLabelFunc label_fn = (text) => { };

            // Header will be updated by update_content_header_now() call later

            // Reset RSS feed article counter for adaptive layout
            self_ref.rss_feed_article_count = 0;
            if (self_ref.rss_feed_layout_timeout_id > 0) {
                Source.remove(self_ref.rss_feed_layout_timeout_id);
                self_ref.rss_feed_layout_timeout_id = 0;
            }

            // Set badge to placeholder before clearing article tracking
            // This prevents showing partial counts during async article loading
            if (self_ref.sidebar_manager != null) {
                self_ref.sidebar_manager.set_badge_placeholder_for_source(feed_name);
            }

            // Clear old article tracking for this source so unread counts reflect current feed content
            if (self_ref.article_state_store != null) {
                self_ref.article_state_store.clear_article_tracking_for_source(feed_name);
            }

            // Fetch articles from the RSS feed
            // Don't set featured_used - let articles populate normally, adaptive layout will handle it
            // Use a unique category ID for single RSS feeds to avoid "myfeed" logic
            RssParser.fetch_rss_url(feed_url, feed_name, feed_name, "rssfeed:" + feed_url, current_search_query, session, label_fn, no_op_clear, wrapped_add);

            // Update badge after articles finish loading
            // Use a 1.5-second delay to ensure all articles have been registered
            weak NewsWindow? weak_self = self_ref;
            GLib.Timeout.add(1500, () => {
                if (weak_self != null && weak_self.sidebar_manager != null) {
                    weak_self.sidebar_manager.update_badge_for_source(feed_name);
                }
                return false;
            });

            return;
        }
        // If the user selected "Front Page", always request the backend
        // frontpage endpoint regardless of preferred_sources. Place this
        // before the multi-source branch so frontpage works even when the
        // user has zero or one preferred source selected.
        if (category_manager.is_frontpage_view()) {
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
                        string cache_key = "pixbuf::file:%s::%dx%d".printf(use_path, 32, 32);
                        Gdk.Pixbuf? cached_pb = null;
                        try { cached_pb = image_cache != null ? image_cache.get_or_load_file(cache_key, use_path, 32, 32) : ImageCache.get_global().get_or_load_file(cache_key, use_path, 32, 32); } catch (GLib.Error e) { cached_pb = null; }
                        if (cached_pb != null) {
                            try {
                                var tex = Gdk.Texture.for_pixbuf(cached_pb);
                                try { self_ref.source_logo.set_from_paintable(tex); } catch (GLib.Error e) { try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { } }
                            } catch (GLib.Error e) {
                                try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { }
                            }
                        } else {
                            try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error e) { }
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
            NewsService.fetch(prefs.news_source, "frontpage", current_search_query, session, wrapped_set_label, wrapped_clear, wrapped_add);
            return;
        }

        // If the user selected "Top Ten", request the backend headlines endpoint
        // regardless of preferred_sources. Same early-return logic as frontpage.
        if (category_manager.is_topten_view()) {
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
                        string cache_key = "pixbuf::file:%s::%dx%d".printf(use_path, 32, 32);
                        Gdk.Pixbuf? cached_pb = null;
                        try { cached_pb = image_cache != null ? image_cache.get(cache_key) : ImageCache.get_global().get(cache_key); } catch (GLib.Error e) { cached_pb = null; }
                        if (cached_pb == null) {
                            try {
                                cached_pb = image_cache != null ? image_cache.get_or_load_file(cache_key, use_path, 32, 32) : ImageCache.get_global().get_or_load_file(cache_key, use_path, 32, 32);
                            } catch (GLib.Error e) { cached_pb = null; }
                        }
                        if (cached_pb != null) {
                            var tex = Gdk.Texture.for_pixbuf(cached_pb);
                            try { self_ref.source_logo.set_from_paintable(tex); } catch (GLib.Error e) { try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { } }
                        } else {
                            try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error e) { }
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
            NewsService.fetch(prefs.news_source, "topten", current_search_query, session, wrapped_set_label, wrapped_clear, wrapped_add);

            return;
        }

        // Check if we should use multi-source mode (multiple built-in sources OR custom RSS sources in My Feed)
        int total_sources = (prefs.preferred_sources != null ? prefs.preferred_sources.size : 0);
        if (is_myfeed_mode && custom_rss_sources != null) {
            total_sources += custom_rss_sources.size;
        }

        if (total_sources > 1 || (is_myfeed_mode && custom_rss_sources != null && custom_rss_sources.size > 0)) {
            // Treat The Frontpage as a multi-source view visually, but do NOT
            // let the user's preferred_sources list influence which providers
            // are queried. Instead, when viewing the special "frontpage"
            // category, simply request the backend frontpage once and present
            // the combined/multi-source UI.
            if (category_manager.is_frontpage_view()) {
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
                            string cache_key = "pixbuf::file:%s::%dx%d".printf(use_path, 32, 32);
                            Gdk.Pixbuf? cached_pb = null;
                            try { cached_pb = image_cache != null ? image_cache.get_or_load_file(cache_key, use_path, 32, 32) : ImageCache.get_global().get_or_load_file(cache_key, use_path, 32, 32); } catch (GLib.Error e) { cached_pb = null; }
                            if (cached_pb != null) {
                                try {
                                    var tex = Gdk.Texture.for_pixbuf(cached_pb);
                                    try { self_ref.source_logo.set_from_paintable(tex); } catch (GLib.Error e) { try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { } }
                                } catch (GLib.Error e) {
                                    try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { }
                                }
                            } else {
                                try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error e) { }
                            }
                        } catch (GLib.Error e) { try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { } }
                    } else {
                        try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error e) { }
                    }
                } catch (GLib.Error e) { }
                used_multi = true;

                // Clear UI and ask the backend frontpage fetcher once. NewsService
                // will route a request with current_category == "frontpage" to
                // the Paperboy backend fetcher regardless of the NewsSource value.
                try { wrapped_clear(); } catch (GLib.Error e) { }
                NewsService.fetch(prefs.news_source, "frontpage", current_search_query, session, wrapped_set_label, wrapped_clear, wrapped_add);
                return;
            }

            // Same logic for Top Ten: request backend headlines endpoint
            if (category_manager.is_topten_view()) {
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
                            string cache_key = "pixbuf::file:%s::%dx%d".printf(use_path, 32, 32);
                            Gdk.Pixbuf? cached_pb = null;
                            try { cached_pb = image_cache != null ? image_cache.get(cache_key) : ImageCache.get_global().get(cache_key); } catch (GLib.Error e) { cached_pb = null; }
                            if (cached_pb == null) {
                                try {
                                    cached_pb = image_cache != null ? image_cache.get_or_load_file(cache_key, use_path, 32, 32) : ImageCache.get_global().get_or_load_file(cache_key, use_path, 32, 32);
                                } catch (GLib.Error e) { cached_pb = null; }
                            }
                            if (cached_pb != null) {
                                var tex = Gdk.Texture.for_pixbuf(cached_pb);
                                try { self_ref.source_logo.set_from_paintable(tex); } catch (GLib.Error e) { try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { } }
                            } else {
                                try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error e) { }
                            }
                        } catch (GLib.Error e) { try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error ee) { } }
                    } else {
                        try { self_ref.source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error e) { }
                    }
                } catch (GLib.Error e) { }
                used_multi = true;

                try { wrapped_clear(); } catch (GLib.Error e) { }
                NewsService.fetch(prefs.news_source, "topten", current_search_query, session, wrapped_set_label, wrapped_clear, wrapped_add);
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
                        string cache_key = "pixbuf::file:%s::%dx%d".printf(use_path, 32, 32);
                        Gdk.Pixbuf? cached_pb = null;
                        try { cached_pb = image_cache != null ? image_cache.get(cache_key) : ImageCache.get_global().get(cache_key); } catch (GLib.Error e) { cached_pb = null; }
                        if (cached_pb == null) {
                            try {
                                cached_pb = image_cache != null ? image_cache.get_or_load_file(cache_key, use_path, 32, 32) : ImageCache.get_global().get_or_load_file(cache_key, use_path, 32, 32);
                            } catch (GLib.Error e) { cached_pb = null; }
                        }
                        if (cached_pb != null) {
                            var tex = Gdk.Texture.for_pixbuf(cached_pb);
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

            //Use SourceManager to get enabled sources as enums
            Gee.ArrayList<NewsSource> srcs = source_manager.get_enabled_source_enums();

            // If mapping failed or produced no sources, fall back to single source
            if (srcs.size == 0) {
                NewsService.fetch(
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
                                    if (NewsService.supports_category(s, cat)) { include = true; break; }
                                }
                            }
                        } else {
                            if (NewsService.supports_category(s, prefs.category)) include = true;
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

                // Fetch from built-in sources (unless in My Feed with custom_only mode enabled)
                bool skip_builtin = is_myfeed_mode && prefs.myfeed_custom_only;
                if (!skip_builtin) {
                    foreach (var s in use_srcs) {
                        if (is_myfeed_mode) {
                            foreach (var cat in myfeed_cats) {
                                NewsService.fetch(s, cat, current_search_query, session, label_fn, no_op_clear, wrapped_add);
                            }
                        } else {
                            NewsService.fetch(s, prefs.category, current_search_query, session, label_fn, no_op_clear, wrapped_add);
                        }
                    }
                }

                // Fetch from custom RSS sources if in My Feed mode and sources are enabled
                if (is_myfeed_mode && custom_rss_sources != null && custom_rss_sources.size > 0) {
                    // Don't set featured_used - allow first article to become hero/carousel
                    GLib.print("DEBUG: Fetching %d custom RSS sources\n", custom_rss_sources.size);
                    foreach (var rss_src in custom_rss_sources) {
                        GLib.print("DEBUG: Fetching RSS from %s (%s)\n", rss_src.name, rss_src.url);
                        RssParser.fetch_rss_url(
                            rss_src.url,
                            rss_src.name,
                            "My Feed",
                            "myfeed",
                            current_search_query,
                            session,
                            label_fn,
                            no_op_clear,
                            wrapped_add
                        );
                    }
                }
            }
        } else {
            // Single-source path: keep existing behavior. Use the
            // effective source so a single selected preferred_source is
            // respected without requiring prefs.news_source to be changed.
            // Special-case: when viewing The Frontpage in single-source
            // mode, make sure we still request the backend frontpage API.
            if (category_manager.is_frontpage_view()) {
                try { wrapped_clear(); } catch (GLib.Error e) { }
                try { wrapped_set_label("Frontpage — Loading from backend (single-source)"); } catch (GLib.Error e) { }
                try {
                    string s = "frontpage-single-source-branch: preferred_sources_size=" + (prefs.preferred_sources != null ? prefs.preferred_sources.size.to_string() : "0") + "\n";
                    append_debug_log(s);
                } catch (GLib.Error e) { }
                NewsService.fetch(prefs.news_source, "frontpage", current_search_query, session, wrapped_set_label, wrapped_clear, wrapped_add);
                return;
            }

            // Same for Top Ten in single-source mode
            if (category_manager.is_topten_view()) {
                try { wrapped_clear(); } catch (GLib.Error e) { }
                try { wrapped_set_label("Top Ten — Loading from backend (single-source)"); } catch (GLib.Error e) { }
                try {
                    string s = "topten-single-source-branch: preferred_sources_size=" + (prefs.preferred_sources != null ? prefs.preferred_sources.size.to_string() : "0") + "\n";
                    append_debug_log(s);
                } catch (GLib.Error e) { }
                NewsService.fetch(prefs.news_source, "topten", current_search_query, session, wrapped_set_label, wrapped_clear, wrapped_add);
                return;
            }

            if (is_myfeed_mode) {
                // Fetch each personalized category for the single effective source
                try { wrapped_clear(); } catch (GLib.Error e) { }
                ClearItemsFunc no_op_clear = () => { };
                SetLabelFunc label_fn = (text) => {
                    Idle.add(() => {
                        if (my_seq != self_ref.fetch_sequence) return false;
                        try { self_ref.update_content_header(); } catch (GLib.Error e) { }
                        return false;
                    });
                };

                // Fetch from built-in source (unless custom_only mode is enabled in My Feed)
                if (!prefs.myfeed_custom_only) {
                    foreach (var cat in myfeed_cats) {
                        NewsService.fetch(effective_news_source(), cat, current_search_query, session, label_fn, no_op_clear, wrapped_add);
                    }
                }

                // Fetch from custom RSS sources if sources are enabled
                if (custom_rss_sources != null && custom_rss_sources.size > 0) {
                    article_manager.featured_used = true;
                    foreach (var rss_src in custom_rss_sources) {
                        RssParser.fetch_rss_url(
                            rss_src.url,
                            rss_src.name,
                            "My Feed",
                            "myfeed",
                            current_search_query,
                            session,
                            label_fn,
                            no_op_clear,
                            wrapped_add
                        );
                    }
                }
            } else {
                try { wrapped_clear(); } catch (GLib.Error e) { }
                NewsService.fetch(
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

    // Fetch article metadata for all categories and RSS sources in background to populate unread counts
    private void fetch_all_category_metadata_for_counts() {
        string[] categories = {"general", "us", "sports", "science", "health", "technology",
                              "business", "entertainment", "politics", "lifestyle", "markets", "industries"};

        // Simple metadata-only add function that just registers articles
        AddItemFunc metadata_add = (title, url, thumbnail_url, category_id, source_name) => {
            try {
                if (article_state_store != null) {
                    string normalized = normalize_article_url(url);
                    article_state_store.register_article(normalized, category_id, source_name);
                }
            } catch (GLib.Error e) { }
        };

        // Fetch articles for all hardcoded categories
        foreach (string cat in categories) {
            NewsService.fetch(
                effective_news_source(),
                cat,
                "",  // no search query
                session,
                (s) => {},  // no label updates
                () => {},   // no clear
                metadata_add  // just register articles
            );
        }

        // Fetch articles from all custom RSS sources
        try {
            var rss_store = Paperboy.RssSourceStore.get_instance();
            var all_sources = rss_store.get_all_sources();

            foreach (var rss_src in all_sources) {
                RssParser.fetch_rss_url(
                    rss_src.url,
                    rss_src.name,
                    rss_src.name,  // category_name = source name
                    "custom:" + rss_src.url,  // category_id
                    "",  // no search query
                    session,
                    (s) => {},  // no label updates
                    () => {},   // no clear
                    metadata_add  // just register articles
                );
            }
        } catch (GLib.Error e) { }

        // Save after fetching all metadata and refresh badges
        Timeout.add(5000, () => {
            try {
                if (article_state_store != null) {
                    article_state_store.save_article_tracking_to_disk();
                }
                if (sidebar_manager != null) {
                    sidebar_manager.refresh_all_badges();
                }
            } catch (GLib.Error e) { }
            return false;
        });
    }
}
