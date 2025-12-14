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
        // Settings for persistent window geometry
        private GLib.Settings settings;
        public const int SIDEBAR_ICON_SIZE = 24;
        public const int MAX_CONCURRENT_DOWNLOADS = 10;
        public const int INITIAL_PHASE_MAX_CONCURRENT_DOWNLOADS = 10;  // Match MAX to avoid retry delays on startup
        public const int INITIAL_MAX_WAIT_MS = 30000;  // Increased from 15s to 30s to allow more time for image downloads on startup

        // Track active downloads globally (used by ImageHandler)
        public static int active_downloads = 0;
        // Restored fields required by window logic (many are accessed from other modules)
        public NewsPreferences prefs;
        public LocationDialog location_dialog;
        public GLib.Rand rng;
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
        public ImageManager image_manager;
        public Soup.Session session;
        public SidebarManager sidebar_manager;
        public SidebarView sidebar_view;
        public Adw.NavigationSplitView split_view;
        public Adw.NavigationView nav_view;
        public Adw.OverlaySplitView article_preview_split;
        public Gtk.Box article_preview_content;
        public ArticlePane article_pane;
        public ArticleSheet article_sheet;
        public Gtk.Overlay root_overlay;
        public ToastManager? toast_manager;
        private Gtk.Widget? current_toast_widget;
        public Gtk.Widget dim_overlay;
        public Gtk.Box main_content_container;
        public Gtk.ScrolledWindow main_scrolled;
        public Gtk.Widget content_area;
        public Gtk.Box content_box;
        // ContentView-provided widgets (wired in constructor)
        public ContentView? content_view;
        public Gtk.Label category_label;
        public Gtk.Label category_subtitle;
        public Gtk.Box? category_icon_holder;
        public Gtk.Image source_logo;
        public Gtk.Label source_label;
        public Gtk.Box featured_box_dummy;

        // Manager instance for header-related UI
        public HeaderManager header_manager;
        // Manager instance for loading/overlay UI
        public Managers.LoadingStateManager? loading_state;
        // Manager instance for RSS feed updates
        private FeedUpdateManager? feed_updater;

        // Search query state and debug log path
        private string current_search_query = "";
        private string debug_log_path = "/tmp/paperboy-debug.log";

        // Deferred download check timeout
        public uint deferred_check_timeout_id = 0;
    
        // Update the source/logo label via HeaderManager
        private void update_source_info() {
            try { if (header_manager != null) header_manager.update_source_info(); } catch (GLib.Error e) { }
        }
    

    // Return the NewsSource the UI should treat as "active". If the
    // user has enabled exactly one preferred source, map that id to the
    // corresponding enum; otherwise use the explicit prefs.news_source.
    public NewsSource effective_news_source() {
        return source_manager.effective_news_source();
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
        // Initialize GSettings for persistent geometry
        try {
            settings = new GLib.Settings("io.github.thecalamityjoe87.Paperboy");
        } catch (GLib.Error e) {
            warning("Failed to initialize GSettings: %s", e.message);
            settings = null;
        }

        // Restore saved window size (use defaults from schema when missing)
        int saved_w = 1400;
        int saved_h = 925;
        bool saved_max = false;
        if (settings != null) {
            saved_w = settings.get_int("window-width");
            saved_h = settings.get_int("window-height");
            saved_max = settings.get_boolean("window-maximized");
        }

        // Apply the saved size (use get_default_size()/set_default_size for Wayland correctness)
        set_default_size(saved_w, saved_h);
        // Initialize RNG for per-card randomization
        rng = new GLib.Rand();
        // Initialize preferences early (needed for building sidebar selection state)
        prefs = NewsPreferences.get_instance();
        // Initialize source and category managers early (needed for all source/category logic)
        source_manager = new SourceManager(prefs);
        source_manager.set_window(this);
        category_manager = new CategoryManager(prefs, source_manager);
        // Initialize ArticleManager early (before any article-related code)
        article_manager = new Managers.ArticleManager(this);
        
        // Connect ArticleManager signals for UI operations
        article_manager.request_show_load_more_button.connect(() => {
            if (content_view != null) {
                content_view.create_and_show_load_more_button();
            }
        });
        
        article_manager.request_hide_load_more_button.connect(() => {
            if (content_view != null) {
                content_view.hide_load_more_button();
            }
        });
        
        article_manager.request_remove_end_feed_message.connect(() => {
            if (content_view != null) {
                content_view.remove_end_of_feed_message();
            }
        });
        
        // Instantiate view-state manager which owns URL/card mappings and viewed state
        view_state = new Managers.ViewStateManager(this);

        // Connect signal to update unread count badges when articles are viewed
        view_state.article_viewed.connect((url) => {
            if (sidebar_manager != null) {
                sidebar_manager.refresh_all_badge_counts();
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
    image_manager = new ImageManager(this);        

        // Load CSS
        var css_provider = new Gtk.CssProvider();
        try {
            string? css_path = DataPathsUtils.find_data_file("style.css");
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
        // Create SidebarManager (logic only)
        sidebar_manager = new SidebarManager(this);

        // When saved articles finish loading, refresh badge counts so the
        // "Saved" badge appears promptly on startup.
        try {
            if (article_state_store != null) {
                article_state_store.saved_articles_loaded.connect(() => {
                    try { if (sidebar_manager != null) sidebar_manager.refresh_all_badge_counts(); } catch (GLib.Error e) { }

                    // If the user was viewing Saved when the app started, the
                    // saved articles may have been loaded after `fetch_news()`
                    // ran. In that case, re-run `fetch_news()` so the Saved
                    // view is populated now that saved articles are available.
                    try {
                        var p = NewsPreferences.get_instance();
                        if (p != null && p.category == "saved") {
                            Idle.add(() => {
                                try { fetch_news(); } catch (GLib.Error _) { }
                                return false;
                            });
                        }
                    } catch (GLib.Error e) { }
                });
            }
        } catch (GLib.Error e) { }

        // Create SidebarView (UI only)
        sidebar_view = new SidebarView(this, sidebar_manager);

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

        // Delay sidebar rebuild slightly to ensure window is fully realized before starting initial fetch
        // This prevents race conditions where images are requested before GTK widgets are ready
        GLib.Idle.add(() => {
            sidebar_manager.rebuild_sidebar();
            return false;
        });

        // Delay badge refresh until after initial content loads to avoid competing with image downloads
        // Badge refresh can be CPU/disk intensive and may block image loading threads
        GLib.Timeout.add_seconds(2, () => {
            try {
                if (sidebar_manager != null) {
                    sidebar_manager.refresh_all_badge_counts();
                }
            } catch (GLib.Error e) { }
            return false;
        });

        // Fetch article metadata for all categories in background to populate unread counts
        // Delay longer if user is viewing an RSS feed to avoid SQLite lock contention
        bool is_rss_view = false;
        try {
            is_rss_view = prefs != null && prefs.category != null && prefs.category.has_prefix("rssfeed:");
        } catch (GLib.Error e) { }

        uint delay_ms = is_rss_view ? 5000 : 1000;  // 5 seconds for RSS, 1 second otherwise
        Timeout.add(delay_ms, () => {
            try { fetch_all_category_metadata_for_counts(); } catch (GLib.Error e) { }
            return false;
        });

        // Request the completed navigation page from the view (use the
        // `sidebar_header` built earlier above)
        Adw.NavigationPage sidebar_page = sidebar_view.build_navigation_page(sidebar_header);

    // Wrap content in a NavigationPage for NavigationSplitView
    // We need to create the content page after setting up root_overlay
    
    // Build main content UI in a separate helper object so the window
    // constructor stays concise. ContentView constructs the widgets and
    // exposes them; we then wire them into the existing NewsWindow fields.
    content_view = new ContentView(prefs);
    content_view.set_window(this);
    category_label = content_view.category_label;
    category_subtitle = content_view.category_subtitle;
    category_icon_holder = content_view.category_icon_holder;
    source_logo = content_view.source_logo;
    source_label = content_view.source_label;
    content_box = content_view.content_box;
    main_scrolled = content_view.main_scrolled;
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
    layout_manager.hero_container?.set_visible(true);
    layout_manager.columns_row?.set_visible(true);
    content_box?.set_visible(true);
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
        if (sidebar_view != null) sidebar_view.set_revealed(active);
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

        // Set the constructed split view as the window content
        set_content(split_view);

        // Initialize toast manager with root_overlay so custom toasts
        // can be positioned in the content area without blocking scrolling
        toast_manager = new ToastManager();
        current_toast_widget = null;
        
        // Connect toast manager signals to handle GTK overlay manipulation
        toast_manager.request_show_toast.connect((message, persistent) => {
            // Dismiss any existing toast
            if (current_toast_widget != null) {
                root_overlay.remove_overlay(current_toast_widget);
                current_toast_widget = null;
            }
            
            // Create and show new toast
            current_toast_widget = ToastWidget.create_toast_widget(message, true, () => {
                if (toast_manager != null) {
                    toast_manager.clear_persistent_toast();
                }
            });
            root_overlay.add_overlay(current_toast_widget);
        });
        
        toast_manager.request_dismiss_toast.connect(() => {
            if (current_toast_widget != null) {
                root_overlay.remove_overlay(current_toast_widget);
                current_toast_widget = null;
            }
        });

        // Initialize feed update manager for automatic RSS feed updates
        feed_updater = new FeedUpdateManager(this);

        // Create session with timeout (max_conns properties are read-only in libsoup3)
        session = new Soup.Session() {
            timeout = 10 // Default timeout in seconds (reduced for faster failure recovery)
        };

        // Initialize article window with image handler for loading preview images
        article_pane = new ArticlePane(nav_view, session, this, image_manager);
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
                    if (sidebar_view != null) sidebar_view.update_icons_for_theme();
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

        // Delay automatic feed updates to avoid startup contention
        // Wait 45 seconds after launch so initial content loads smoothly
        // This allows time for user to view initial content and for background
        // metadata fetch to complete before heavy feed regeneration starts
        if (feed_updater != null) {
            GLib.Timeout.add_seconds(45, () => {
                feed_updater.update_all_feeds_async();
                return false; // One-shot
            });
        }

    // Ensure the personalized message visibility is correct at startup
    update_personalization_ui();

        // If the saved state requested maximized, maximize now (do not treat maximized geometry as normal size)
            if (settings != null) {
                bool want_max = false;
                want_max = settings.get_boolean("window-maximized");
                if (want_max) {
                    maximize();
                }
            }

        // Clear only cached in-memory images on window close to free textures
        // while preserving per-article metadata (e.g., viewed flags) on disk.
        // Also persist window geometry into GSettings. We save on close (not on resize)
        // so transient states (like maximized) don't become stored as normal sizes.
        this.close_request.connect(() => {
            try {
                // Persist maximized state and size (only when not maximized)
                    if (settings != null) {
                        bool is_max = false;
                        is_max = this.is_maximized();
                        settings.set_boolean("window-maximized", is_max);

                        if (!is_max) {
                            int cw = 1400;
                            int ch = 925;
                            this.get_default_size(out cw, out ch);
                            if (cw > 0 && ch > 0) {
                                settings.set_int("window-width", cw);
                                settings.set_int("window-height", ch);
                            }
                        }
                    }

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

    public void update_category_icon() {
        try { if (header_manager != null) header_manager.update_category_icon(); } catch (GLib.Error e) { }
    }

    public void update_content_header() {
        try { if (header_manager != null) header_manager.update_content_header(); } catch (GLib.Error e) { }
    }

    public void update_content_header_now() {
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

    public void update_sidebar_for_source() {
        try { if (sidebar_manager != null) sidebar_manager.update_for_source_change(); } catch (GLib.Error e) { }
    }

    public string category_display_name_for(string cat) {
        if (header_manager != null) {
            return header_manager.category_display_name_for(cat);
        }
        // Fallback to CategoryManager's static lookup if header_manager not ready
        return CategoryManager.get_category_display_name(cat);
    }

    public Gtk.Widget build_category_chip(string category_id) {
        return CardBuilder.build_category_chip(this, category_id);
    }

    public string get_source_name(NewsSource source) {
        return SourceManager.get_source_name(source);
    }

    public NewsSource infer_source_from_url(string? url) {
        return SourceManager.infer_source_from_url(url);
    }

    public NewsSource resolve_source(string? source_name, string url) {
        return SourceManager.resolve_source(source_name, url);
    }

    // Build a source badge using the provided arbitrary source name (often
    // provided by external APIs) and article URL. This attempts to map the
    // name to a known NewsSource first; if that fails, it looks for a local
    // icon file derived from the source name. If no icon is found it falls
    // back to a text-only badge using the provided name.
    public Gtk.Widget build_source_badge_dynamic(string? source_name, string url, string category_id) {
        return CardBuilder.build_source_badge_dynamic(this, source_name, url, category_id);
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

    // Layout-related logic has been moved to LayoutManager; delegate to it.
    public int estimate_content_width() {
        try { if (layout_manager != null) return layout_manager.estimate_content_width(); } catch (GLib.Error e) { }
        return 1280;
    }

    private void update_main_content_size(bool sidebar_visible) {
        try { if (layout_manager != null) layout_manager.update_main_content_size(sidebar_visible); } catch (GLib.Error e) { }
    }

    public void maybe_refetch_hero_for(Gtk.Picture pic, HeroRequest info) {
        try { if (layout_manager != null) layout_manager.maybe_refetch_hero_for(pic, info); } catch (GLib.Error e) { }
    }

    public void show_loading_spinner() {
        try { if (loading_state != null) loading_state.show_loading_spinner(); } catch (GLib.Error e) { }
    }
    
    public void hide_loading_spinner() {
        try { if (loading_state != null) loading_state.hide_loading_spinner(); } catch (GLib.Error e) { }
    }

    // Show the global error overlay. If `msg` is provided it will be shown
    // in the overlay label; otherwise we use a generic "no articles" text.
    public void show_error_message(string? msg = null) {
        try { if (loading_state != null) loading_state.show_error_message(msg); } catch (GLib.Error e) { }
        
        // Also show a user-visible toast for immediate feedback
        string toast_msg = msg != null && msg.length > 0 ? msg : "Failed to load articles. Please try again.";
        try { show_toast(toast_msg); } catch (GLib.Error e) { }
    }

    // Reveal main content (stop showing the loading spinner)
    public void reveal_initial_content() {
        try { if (loading_state != null) loading_state.reveal_initial_content(); } catch (GLib.Error e) { }
    }

    // Helper to form memory cache keys that include requested size
    public string make_cache_key(string url, int w, int h) {
        // Use deterministic pixbuf keys: origin=url, include size
        return "pixbuf::url:%s::%dx%d".printf(url, w, h);
    }

    // Helper to mark that initial items have been added to the UI. If there are
    // no pending image loads, reveal the UI immediately.
    public void mark_initial_items_populated() {
        try { if (loading_state != null) loading_state.mark_initial_items_populated(); } catch (GLib.Error e) { }
    }

    // Clean up memory by releasing old textures and widget references
    public void cleanup_old_content() {
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
        image_manager.hero_requests.clear();
        
        // Clear deferred downloads
        deferred_downloads.clear();
        
        // Clear requested image sizes
        requested_image_sizes.clear();
        
        // Clear the centralized ImageCache (pixbufs) and preview cache.
        // Suppress clearing here to avoid excessive eviction when switching
        // categories; rely on the LRU policy instead. Window-close still
        // frees widget-held textures elsewhere.
    }

    // Thin wrapper delegating to FetchNewsController. Keeps public API stable
    // while the heavy implementation lives in `fetch_news_impl` for easier
    // staged extraction.
    public void fetch_news() {
        try {
            FetchNewsController.fetch_news(this);
        } catch (GLib.Error e) { }
    }

    // Fetch article metadata for all *regular* categories and RSS sources in background
    // to populate unread counts. Special categories like myfeed, local_news, and saved
    // are handled separately and must not be treated as normal fetchable categories here.
    private void fetch_all_category_metadata_for_counts() {
        UnreadFetchService.fetch_all_category_metadata_for_counts(this);
    }
}

