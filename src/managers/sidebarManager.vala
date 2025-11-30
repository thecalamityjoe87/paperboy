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
using Gee;
using GLib;
using Cairo;

public delegate void SidebarActivateHandler(string cat, string title);

public class SidebarManager : GLib.Object {
    private NewsWindow window;
    private Gtk.ListBox sidebar_list;
    private Gee.HashMap<string, Gtk.Box> sidebar_icon_holders;
    // We store RSS feed icon holders under keys prefixed with "rss:" + url
    private SidebarActivateHandler? activate_cb;
    private Gtk.ScrolledWindow sidebar_scrolled;
    private Gtk.Revealer sidebar_revealer;
    private Adw.NavigationPage sidebar_page;

    // Expandable sections tracking
    private bool followed_sources_expanded = true;  // Start expanded
    private bool popular_categories_expanded = true;
    private Gtk.Box? followed_sources_container;
    private Gtk.Box? popular_categories_container;
    private Gtk.Button? add_rss_button;

    // Track currently selected button for highlighting
    private Gtk.Button? currently_selected_button = null;

    public signal void category_selected(string category);

    public SidebarManager(NewsWindow window, SidebarActivateHandler? activate_cb = null) {
        GLib.Object();
        this.window = window;
        this.sidebar_icon_holders = new Gee.HashMap<string, Gtk.Box>();
        this.activate_cb = activate_cb;

        // Load saved expanded states from preferences
        load_expanded_states();

        build_sidebar_ui();

        // Listen for changes to custom RSS sources and rebuild sidebar when they change
        var store = Paperboy.RssSourceStore.get_instance();
        store.source_added.connect((s) => {
            Idle.add(() => {
                try { append_rss_feed_row(s); } catch (GLib.Error e) { }
                return false;
            });
        });
        store.source_removed.connect((s) => {
            Idle.add(() => {
                try { remove_rss_feed_row_by_url(s.url); } catch (GLib.Error e) { }
                return false;
            });
        });

        // When a source is updated (for example its icon file was saved), update only that icon
        store.source_updated.connect((s) => {
            Idle.add(() => {
                try {
                    string key = "rss:" + s.url;
                    try {
                        Gtk.Box holder = sidebar_icon_holders.get(key);
                        // Remove existing children
                        Gtk.Widget? child = holder.get_first_child();
                        while (child != null) {
                            Gtk.Widget? next = child.get_next_sibling();
                            try { holder.remove(child); } catch (GLib.Error e) { }
                            child = next;
                        }
                        // Create fresh picture and append
                        var pic = create_rss_source_picture(s);
                        if (pic != null) holder.append(pic);
                    } catch (GLib.Error e) {
                        // No holder for this source yet; ignore
                    }
                } catch (GLib.Error e) { }
                return false;
            });
        });
    }

    private void load_expanded_states() {
        var prefs = NewsPreferences.get_instance();
        // Load from config properties, default to true (expanded) if not set
        followed_sources_expanded = prefs.sidebar_followed_sources_expanded;
        popular_categories_expanded = prefs.sidebar_popular_categories_expanded;
    }

    private void save_followed_sources_state() {
        var prefs = NewsPreferences.get_instance();
        prefs.sidebar_followed_sources_expanded = followed_sources_expanded;
        prefs.save_config();
    }

    private void save_popular_categories_state() {
        var prefs = NewsPreferences.get_instance();
        prefs.sidebar_popular_categories_expanded = popular_categories_expanded;
        prefs.save_config();
    }

    private void build_sidebar_ui() {
        // Create list
        sidebar_list = new Gtk.ListBox();
        sidebar_list.add_css_class("navigation-sidebar");
        sidebar_list.set_selection_mode(Gtk.SelectionMode.NONE);
        sidebar_list.set_activate_on_single_click(true);

        // Create scrolled window
        sidebar_scrolled = new Gtk.ScrolledWindow();
        sidebar_scrolled.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        sidebar_scrolled.set_child(sidebar_list);

        // Create revealer
        sidebar_revealer = new Gtk.Revealer();
        sidebar_revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_RIGHT);
        sidebar_revealer.set_transition_duration(200);
        sidebar_revealer.set_reveal_child(true);
    }

    public Adw.NavigationPage build_navigation_page(Adw.HeaderBar header) {
        var sidebar_toolbar = new Adw.ToolbarView();
        sidebar_toolbar.add_top_bar(header);
        sidebar_toolbar.set_content(sidebar_scrolled);

        sidebar_revealer.set_child(sidebar_toolbar);
        sidebar_page = new Adw.NavigationPage(sidebar_revealer, "Categories");
        return sidebar_page;
    }

    public Adw.NavigationPage get_page() {
        return sidebar_page;
    }

    // Rebuild the sidebar rows according to the currently selected source
    public void rebuild_rows() {
        // Debug logging removed - keep sidebar rebuild lean.

        // Preserve vertical scroll position so clicking items doesn't jump to top
        double saved_value = 0.0;
        double saved_upper = 0.0;
        double saved_page = 0.0;
        try {
            var vadj = sidebar_scrolled.get_vadjustment();
            saved_value = vadj.get_value();
            saved_upper = vadj.get_upper();
            saved_page = vadj.get_page_size();
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

        // Reset selection tracking since we're rebuilding everything
        currently_selected_button = null;
        currently_selected_row = null;

        // Place "Front Page" and "My Feed" above the Categories header
        add_row("Top Ten", "topten", window.prefs.category == "topten");
        add_row("Front Page", "frontpage", window.prefs.category == "frontpage");
        add_row("My Feed", "myfeed", window.prefs.category == "myfeed");
        add_row("Local News", "local_news", window.prefs.category == "local_news");

        // Add expandable Custom RSS Feeds section
        build_followed_sources_section();

        // Add expandable Popular Categories section
        build_popular_categories_header();

        // If multiple preferred sources are selected, build the union of
        // categories supported by those sources and show only those rows.
        if (window.prefs.preferred_sources != null && window.prefs.preferred_sources.size > 1) {
            var allowed = new Gee.HashMap<string, bool>();
            string[] default_cats = { "general", "us", "technology", "business", "science", "sports", "health", "entertainment", "politics", "lifestyle" };
            foreach (var c in default_cats) allowed.set(c, true);
            
            // Check if at least one source supports lifestyle
            bool any_source_supports_lifestyle = false;
            foreach (var id in window.prefs.preferred_sources) {
                NewsSource src = NewsSource.GUARDIAN; // default
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
                if (NewsSources.supports_category(src, "lifestyle")) {
                    any_source_supports_lifestyle = true;
                }
            }
            
            // If no source supports lifestyle, remove it from allowed categories
            if (!any_source_supports_lifestyle) {
                allowed.unset("lifestyle");
            }

            foreach (var id in window.prefs.preferred_sources) {
                switch (id) {
                    case "bloomberg": {
                        allowed.set("markets", true);
                        allowed.set("industries", true);
                        allowed.set("economics", true);
                        allowed.set("wealth", true);
                        allowed.set("green", true);
                    }
                    break;
                    default: break;
                }
            }

            string[] priority = { "general", "us", "technology", "business", "markets", "industries", "economics", "wealth", "green", "sports", "science", "health", "entertainment", "politics", "lifestyle" };
            foreach (var cat in priority) {
                bool present = false;
                foreach (var kv in allowed.entries) {
                    if (kv.key == cat) { present = kv.value; break; }
                }
                if (present) build_category_row_to_container(window.category_display_name_for(cat), cat, window.prefs.category == cat);
            }
            // Restore previous scroll position (clamped to valid range) before returning
            try {
                var vadj = sidebar_scrolled.get_vadjustment();
                double max_val = saved_upper - saved_page;
                if (max_val < 0) max_val = 0;
                double to_set = saved_value;
                if (to_set < 0) to_set = 0;
                if (to_set > max_val) to_set = max_val;
                vadj.set_value(to_set);
            } catch (GLib.Error e) { }

            return;
        }

        // Single-source path: show categories appropriate to the selected source
        NewsSource sidebar_eff = effective_news_source();
        if (sidebar_eff == NewsSource.BLOOMBERG) {
            build_category_row_to_container("Markets", "markets", window.prefs.category == "markets");
            build_category_row_to_container("Industries", "industries", window.prefs.category == "industries");
            build_category_row_to_container("Economics", "economics", window.prefs.category == "economics");
            build_category_row_to_container("Wealth", "wealth", window.prefs.category == "wealth");
            build_category_row_to_container("Green", "green", window.prefs.category == "green");
            build_category_row_to_container("Technology", "technology", window.prefs.category == "technology");
            build_category_row_to_container("Politics", "politics", window.prefs.category == "politics");
        } else {
            build_category_row_to_container("World News", "general", window.prefs.category == "general");
            build_category_row_to_container("US News", "us", window.prefs.category == "us");
            build_category_row_to_container("Technology", "technology", window.prefs.category == "technology");
            build_category_row_to_container("Business", "business", window.prefs.category == "business");
            build_category_row_to_container("Sports", "sports", window.prefs.category == "sports");
            build_category_row_to_container("Science", "science", window.prefs.category == "science");
            build_category_row_to_container("Health", "health", window.prefs.category == "health");
            build_category_row_to_container("Entertainment", "entertainment", window.prefs.category == "entertainment");
            build_category_row_to_container("Politics", "politics", window.prefs.category == "politics");
            try {
                if (NewsSources.supports_category(sidebar_eff, "lifestyle")) {
                    build_category_row_to_container("Lifestyle", "lifestyle", window.prefs.category == "lifestyle");
                }
            } catch (GLib.Error e) { build_category_row_to_container("Lifestyle", "lifestyle", window.prefs.category == "lifestyle"); }
        
        // Restore previous scroll position (clamped to valid range)
        try {
            var vadj = sidebar_scrolled.get_vadjustment();
            double max_val = saved_upper - saved_page;
            if (max_val < 0) max_val = 0;
            double to_set = saved_value;
            if (to_set < 0) to_set = 0;
            if (to_set > max_val) to_set = max_val;
            vadj.set_value(to_set);
        } catch (GLib.Error e) { }
        }
    }

    private NewsSource effective_news_source() {
        if (window.prefs.preferred_sources != null && window.prefs.preferred_sources.size == 1) {
            try {
                string id = window.prefs.preferred_sources.get(0);
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
                    default: return window.prefs.news_source;
                }
            } catch (GLib.Error e) { return window.prefs.news_source; }
        }
        return window.prefs.news_source;
    }

    public void update_icons_for_theme() {
        var store = Paperboy.RssSourceStore.get_instance();
        foreach (var kv in sidebar_icon_holders.entries) {
            string key = kv.key;
            Gtk.Box holder = kv.value;
            Gtk.Widget? child = holder.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                try { holder.remove(child); } catch (GLib.Error e) { }
                child = next;
            }

            // If this holder is for a followed RSS source, recreate the
            // source-specific picture so saved logos (or the RSS fallback)
            // are used instead of category icons.
            if (key.has_prefix("rss:")) {
                string url = key.substring(4);
                try {
                    var src = store.get_source_by_url(url);
                    if (src != null) {
                        var pic = create_rss_source_picture(src);
                        if (pic != null) holder.append(pic);
                        continue;
                    }
                } catch (GLib.Error e) { }

                // Fallback if the source record is missing: use a themed RSS image
                try {
                    var fallback = new Gtk.Image.from_icon_name("application-rss+xml-symbolic");
                    fallback.set_pixel_size(CategoryIcons.SIDEBAR_ICON_SIZE);
                    holder.append(fallback);
                } catch (GLib.Error e) { }
            } else {
                var w = CategoryIcons.create_category_icon(key);
                if (w != null) holder.append(w);
            }
        }
    }

    public void update_for_source_change() {
        rebuild_rows();
    }

    public void show() {
        try { sidebar_revealer.set_reveal_child(true); } catch (GLib.Error e) { }
    }

    public void hide() {
        try { sidebar_revealer.set_reveal_child(false); } catch (GLib.Error e) { }
    }

    public void toggle() {
        try { sidebar_revealer.set_reveal_child(!sidebar_revealer.get_reveal_child()); } catch (GLib.Error e) { }
    }

    public bool is_visible() {
        try { return sidebar_revealer.get_reveal_child(); } catch (GLib.Error e) { return false; }
    }

    public void set_revealed(bool revealed) {
        try { sidebar_revealer.set_reveal_child(revealed); } catch (GLib.Error e) { }
    }

    private void handle_category_activation(string cat, string title) {
        string validated = validate_category_for_sources(cat);

        window.prefs.category = validated;
        try { window.update_category_icon(); } catch (GLib.Error e) { }
        try { window.update_local_news_ui(); } catch (GLib.Error e) { }
        try { window.prefs.save_config(); } catch (GLib.Error e) { }

        // Notify listeners (NewsWindow) to trigger fetch/update
        try { category_selected(validated); } catch (GLib.Error e) { }
        // Also invoke legacy callback if provided
        try { if (activate_cb != null) activate_cb(validated, title); } catch (GLib.Error e) { }
    }

    private string validate_category_for_sources(string requested_cat) {
        bool category_supported = false;
        if (window.prefs.preferred_sources != null && window.prefs.preferred_sources.size > 1) {
            foreach (var id in window.prefs.preferred_sources) {
                NewsSource src = parse_source_id(id);
                if (NewsSources.supports_category(src, requested_cat)) { category_supported = true; break; }
            }
        } else {
            NewsSource current_source = effective_news_source();
            try { category_supported = NewsSources.supports_category(current_source, requested_cat); } catch (GLib.Error e) { category_supported = false; }
        }

        if (!category_supported) return "frontpage";
        return requested_cat;
    }

    private NewsSource parse_source_id(string id) {
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
            default: return window.prefs.news_source;
        }
    }

    // Add a simple section header row
    public void add_header(string title) {
        var header_row = new Adw.ActionRow();
        header_row.set_title(title);
        header_row.activatable = false;
        header_row.selectable = false;
        header_row.add_css_class("caption-heading");
        header_row.set_margin_top(12);
        header_row.set_margin_bottom(6);
        sidebar_list.append(header_row);
    }

    // Track currently selected ListBox row for highlighting
    private Gtk.ListBoxRow? currently_selected_row = null;

    // Add a selectable row with optional category icon and activation handling
    public void add_row(string title, string cat, bool selected=false) {
        var row = new Adw.ActionRow();
        row.set_title(title);
        row.activatable = true;
        row.add_css_class("sidebar-item-row");
        var holder = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        holder.set_hexpand(false);
        holder.set_vexpand(false);

        var prefix_widget = CategoryIcons.create_category_icon(cat);
        if (prefix_widget != null) { holder.append(prefix_widget); }
        row.add_prefix(holder);
        sidebar_icon_holders.set(cat, holder);

        // store category on the row for future retrieval
        row.set_data("category_id", cat);

        // If this row is currently selected, mark it as selected
        if (selected) {
            row.add_css_class("selected");
            currently_selected_row = row;
        }

        row.activated.connect(() => {
            try {
                // Remove selected class from any previously selected button
                if (currently_selected_button != null) {
                    currently_selected_button.remove_css_class("selected");
                    currently_selected_button = null;
                }

                // Remove selected class from previously selected row
                if (currently_selected_row != null) {
                    currently_selected_row.remove_css_class("selected");
                }

                // Add selected class to this row
                row.add_css_class("selected");
                currently_selected_row = row;

                // Close the article sheet if it's open — clicking a sidebar item
                // is an obvious intent to switch content, so dismiss the sheet.
                try { if (window.article_sheet != null) window.article_sheet.dismiss(); } catch (GLib.Error _e) { }

                handle_category_activation(cat, title);
            } catch (GLib.Error e) { }
        });

        try { row.set_can_focus(false); } catch (GLib.Error e) { }
        sidebar_list.append(row);
    }

    // Build an expandable header with arrow icon
    private void build_popular_categories_header() {
        var header_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        header_box.set_margin_top(12);
        header_box.set_margin_bottom(6);
        header_box.set_margin_start(4); // Move the text left
        header_box.set_margin_end(12);

        var label = new Gtk.Label("Popular Categories");
        label.add_css_class("caption-heading");
        label.set_xalign(0);
        label.set_hexpand(true);
        header_box.append(label);

        var arrow = new Gtk.Image.from_icon_name(popular_categories_expanded ? "go-down-symbolic" : "go-next-symbolic");
        arrow.set_pixel_size(12);
        arrow.add_css_class("sidebar-arrow");
        arrow.set_opacity(0.85);
        header_box.append(arrow);

        var header_button = new Gtk.Button();
        header_button.set_child(header_box);
        header_button.add_css_class("flat");
        header_button.set_hexpand(true);

        try { header_button.set_can_focus(false); } catch (GLib.Error e) { }

        header_button.clicked.connect(() => {
            popular_categories_expanded = !popular_categories_expanded;
            arrow.set_from_icon_name(popular_categories_expanded ? "go-down-symbolic" : "go-next-symbolic");
            if (popular_categories_container != null) {
                popular_categories_container.set_visible(popular_categories_expanded);
            }
            // Save the state
            save_popular_categories_state();
        });

        var header_row = new Gtk.ListBoxRow();
        header_row.set_child(header_button);
        header_row.set_activatable(false);
        header_row.set_selectable(false);
        sidebar_list.append(header_row);

        // Create container for items
        popular_categories_container = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        popular_categories_container.set_visible(popular_categories_expanded);
        var container_row = new Gtk.ListBoxRow();
        container_row.set_child(popular_categories_container);
        container_row.set_activatable(false);
        container_row.set_selectable(false);
        sidebar_list.append(container_row);
    }

    // Build 'Followed Sources' expandable section
    private void build_followed_sources_section() {
        var header_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        header_box.set_margin_top(12);
        header_box.set_margin_bottom(6);
        header_box.set_margin_start(4); // Move the text left
        header_box.set_margin_end(12);

        var label = new Gtk.Label("Followed Sources");
        label.add_css_class("caption-heading");
        label.set_xalign(0);
        label.set_hexpand(true);
        header_box.append(label);

        var arrow = new Gtk.Image.from_icon_name(followed_sources_expanded ? "go-down-symbolic" : "go-next-symbolic");
        arrow.set_pixel_size(12);
        arrow.add_css_class("sidebar-arrow");
        arrow.set_opacity(0.85);
        header_box.append(arrow);

        var header_button = new Gtk.Button();
        header_button.set_child(header_box);
        header_button.add_css_class("flat");
        header_button.set_hexpand(true);

        try { header_button.set_can_focus(false); } catch (GLib.Error e) { }

        header_button.clicked.connect(() => {
            followed_sources_expanded = !followed_sources_expanded;
            arrow.set_from_icon_name(followed_sources_expanded ? "go-down-symbolic" : "go-next-symbolic");
            if (followed_sources_container != null) {
                followed_sources_container.set_visible(followed_sources_expanded);
            }
            // Save the state
            save_followed_sources_state();
        });

        var header_row = new Gtk.ListBoxRow();
        header_row.set_child(header_button);
        header_row.set_activatable(false);
        header_row.set_selectable(false);
        sidebar_list.append(header_row);

        // Create container for RSS feed items
        followed_sources_container = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        followed_sources_container.set_visible(followed_sources_expanded);

        // Load and display existing RSS feeds
        load_custom_rss_feeds();

        var container_row = new Gtk.ListBoxRow();
        container_row.set_child(followed_sources_container);
        container_row.set_activatable(false);
        container_row.set_selectable(false);
        sidebar_list.append(container_row);
    }

    // Load custom RSS feeds from the database
    private void load_custom_rss_feeds() {
        if (followed_sources_container == null) return;

        // Clear existing items
        Gtk.Widget? child = followed_sources_container.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            followed_sources_container.remove(child);
            child = next;
        }

        var store = Paperboy.RssSourceStore.get_instance();
        var sources = store.get_all_sources();

        // Add all RSS feed rows
        foreach (var source in sources) {
            build_rss_feed_row(source);
        }

        // Add "Add RSS Feed" button at the bottom
            var add_button = create_rss_feed_button();
            followed_sources_container.append(add_button);
            // Keep reference so incremental inserts can place new rows before this button
            add_rss_button = add_button;
    }

    // Add a row for a single RSS feed
    private Gtk.Widget create_rss_feed_widget(Paperboy.RssSource source) {
        var feed_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        feed_box.set_margin_start(12);
        feed_box.set_margin_end(12);
        feed_box.set_margin_top(4);
        feed_box.set_margin_bottom(4);

        // Create icon
        Gtk.Widget pic_widget = create_rss_source_picture(source);

        var icon_holder = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        icon_holder.add_css_class("circular-logo");
        icon_holder.set_size_request(CategoryIcons.SIDEBAR_ICON_SIZE, CategoryIcons.SIDEBAR_ICON_SIZE);
        icon_holder.set_valign(Gtk.Align.CENTER);
        icon_holder.set_halign(Gtk.Align.CENTER);
        icon_holder.append(pic_widget);
        feed_box.append(icon_holder);

        // Remember this holder so we can update the logo later when metadata arrives
        try { sidebar_icon_holders.set("rss:" + source.url, icon_holder); } catch (GLib.Error e) { }

        var name_label = new Gtk.Label(source.name);
        string? display_name = SourceMetadata.get_display_name_for_source(source.name);
        if (display_name != null && display_name.length > 0) {
            name_label.set_text(display_name);
        }
        name_label.set_xalign(0);
        name_label.set_hexpand(true);
        name_label.set_ellipsize(Pango.EllipsizeMode.END);
        feed_box.append(name_label);

        var feed_button = new Gtk.Button();
        feed_button.set_child(feed_box);
        try { feed_button.set_can_focus(false); } catch (GLib.Error e) { }
        feed_button.add_css_class("flat");
        feed_button.add_css_class("sidebar-item-row");

        // Store URL and name for later lookup and ordering when inserting/removing
        try { feed_button.set_data("rss_url", source.url); } catch (GLib.Error e) { }
        try { feed_button.set_data("rss_name", source.name); } catch (GLib.Error e) { }

        feed_button.clicked.connect(() => {
            try {
                if (currently_selected_row != null) {
                    currently_selected_row.remove_css_class("selected");
                    currently_selected_row = null;
                }
                if (currently_selected_button != null) {
                    currently_selected_button.remove_css_class("selected");
                }
                feed_button.add_css_class("selected");
                currently_selected_button = feed_button;

                string rss_category = "rssfeed:" + source.url;
                handle_category_activation(rss_category, source.name);
            } catch (GLib.Error e) { }
        });

        // If this RSS is currently active in prefs, mark it selected on creation
        try {
            string rss_category_check = "rssfeed:" + source.url;
            if (window.prefs.category == rss_category_check) {
                // Clear any previously selected row
                if (currently_selected_row != null) {
                    currently_selected_row.remove_css_class("selected");
                    currently_selected_row = null;
                }
                feed_button.add_css_class("selected");
                currently_selected_button = feed_button;
            }
        } catch (GLib.Error e) { }

        return feed_button;
    }

    private void build_rss_feed_row(Paperboy.RssSource source) {
        if (followed_sources_container == null) return;
        var widget = create_rss_feed_widget(source);
        followed_sources_container.append(widget);
    }

    private void append_rss_feed_row(Paperboy.RssSource source) {
        if (followed_sources_container == null) return;
        // Build widget for new source
        var new_widget = create_rss_feed_widget(source);

        // Gather existing widgets except the Add button
        var widgets = new Gee.ArrayList<Gtk.Widget>();
        Gtk.Widget? child = followed_sources_container.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            if (add_rss_button != null && child == add_rss_button) {
                // skip the add button for now
            } else {
                widgets.add(child);
            }
            child = next;
        }

        // Find insertion index using authoritative DB ordering (get_all_sources() is ORDER BY name ASC)
        int insert_at = widgets.size; // default to append
        try {
            var store = Paperboy.RssSourceStore.get_instance();
            var ordered = store.get_all_sources();
            int pos = -1;
            for (int i = 0; i < ordered.size; i++) {
                // SAFETY: Check for null before accessing properties to prevent segfault
                var item = ordered.get(i);
                if (item != null && item.url == source.url) { pos = i; break; }
            }
            if (pos >= 0) {
                // Clamp to available widget count
                if (pos < widgets.size) insert_at = pos; else insert_at = widgets.size;
            }
        } catch (GLib.Error e) {
            // On error, fall back to appending
            insert_at = widgets.size;
        }

        // Insert new_widget into the list at insert_at
        var new_list = new Gee.ArrayList<Gtk.Widget>();
        for (int i = 0; i < insert_at; i++) new_list.add(widgets.get(i));
        new_list.add(new_widget);
        for (int i = insert_at; i < widgets.size; i++) new_list.add(widgets.get(i));

        // Clear container and re-append widgets in new order, then add button
        child = followed_sources_container.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            try { followed_sources_container.remove(child); } catch (GLib.Error _) { }
            child = next;
        }

        foreach (var w in new_list) followed_sources_container.append(w);
        if (add_rss_button != null) followed_sources_container.append(add_rss_button);
    }

    private void remove_rss_feed_row_by_url(string url) {
        if (followed_sources_container == null) return;
        Gtk.Widget? child = followed_sources_container.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            try {
                string? stored = child.get_data<string>("rss_url");
                if (stored != null && stored == url) {
                    followed_sources_container.remove(child);
                    // Remove sidebar_icon_holders mapping
                    try { sidebar_icon_holders.unset("rss:" + url); } catch (GLib.Error e) { }
                    // If this removed widget was selected, clear selection and fall back to Front Page
                    try {
                        if (currently_selected_button != null && currently_selected_button == child) {
                            currently_selected_button = null;
                            handle_category_activation("frontpage", "Front Page");
                        }
                    } catch (GLib.Error e) { }
                    return;
                }
            } catch (GLib.Error e) { }
            child = next;
        }
    }

    // Create and return the "Add RSS Feed" button (caller appends it)
    private Gtk.Button create_rss_feed_button() {
        var button_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        button_box.set_margin_start(12);
        button_box.set_margin_end(12);
        button_box.set_margin_top(4);
        button_box.set_margin_bottom(4);

        var icon = new Gtk.Image.from_icon_name("list-add-symbolic");
        icon.set_pixel_size(CategoryIcons.SIDEBAR_ICON_SIZE);
        button_box.append(icon);

        var label = new Gtk.Label("Add RSS Feed");
        label.set_xalign(0);
        label.set_hexpand(true);
        button_box.append(label);

        var add_button = new Gtk.Button();
        try { add_button.set_can_focus(false); } catch (GLib.Error e) { }
        add_button.set_child(button_box);
        add_button.add_css_class("flat");
        add_button.add_css_class("sidebar-item-row");

        add_button.clicked.connect(() => {
            show_add_rss_dialog();
        });

        return add_button;
    }

    // Show dialog to add a new RSS feed
    private void show_add_rss_dialog() {
        var dialog = new Adw.MessageDialog((Gtk.Window)window, "Add RSS Feed", null);
        dialog.set_body("Enter the RSS feed URL:");

        var entry_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
        entry_box.set_margin_top(12);
        entry_box.set_margin_bottom(12);

        var url_entry = new Gtk.Entry();
        url_entry.set_placeholder_text("https://example.com/feed.xml");
        entry_box.append(url_entry);

        var name_entry = new Gtk.Entry();
        name_entry.set_placeholder_text("Feed name (optional)");
        entry_box.append(name_entry);

        dialog.set_extra_child(entry_box);
        dialog.add_response("cancel", "Cancel");
        dialog.add_response("add", "Add Feed");
        dialog.set_response_appearance("add", Adw.ResponseAppearance.SUGGESTED);

        dialog.response.connect((response) => {
            if (response == "add") {
                string url = url_entry.get_text().strip();
                string name = name_entry.get_text().strip();

                if (url.length > 0) {
                    if (name.length == 0) {
                        // Extract name from URL
                        name = extract_name_from_url(url);
                    }
                    add_rss_feed(name, url);
                }
            }
            dialog.close();
        });

        dialog.present();
    }

    // Extract a name from URL
    private string extract_name_from_url(string url) {
        try {
            var uri = Uri.parse(url, UriFlags.NONE);
            string? host = uri.get_host();
            if (host != null) {
                return host.replace("www.", "");
            }
        } catch (Error e) {
            // Fallback: just use the URL
        }
        return url;
    }

    // Add a new RSS feed with robust metadata discovery
    private void add_rss_feed(string name, string url) {
        // Show loading toast
        var loading_toast = new Adw.Toast("Discovering feed...");
        loading_toast.set_timeout(0); // Keep it visible until we're done
        window.toast_overlay.add_toast(loading_toast);

        // Use SourceManager's robust discovery method
        window.source_manager.add_rss_feed_with_discovery(url, name, (success, discovered_name) => {
            // Dismiss loading toast
            loading_toast.dismiss();

            if (success) {
                load_custom_rss_feeds();
                var toast = new Adw.Toast("RSS feed added: " + discovered_name);
                toast.set_timeout(3);
                window.toast_overlay.add_toast(toast);
            } else {
                var toast = new Adw.Toast("Failed to add RSS feed");
                toast.set_timeout(3);
                window.toast_overlay.add_toast(toast);
            }
        });
    }

    // Load RSS source icon from SourceMetadata (same logic as prefsDialog)
    // Create a Widget (usually an Image or Picture) with rendered logo.
    private Gtk.Widget create_rss_source_picture(Paperboy.RssSource source) {
        string? icon_filename = null;

        // Priority 1: Check SourceMetadata first
        icon_filename = SourceMetadata.get_saved_filename_for_source(source.name);

        // Priority 2: Fall back to RSS database icon_filename
        if (icon_filename == null || icon_filename.length == 0) {
            icon_filename = source.icon_filename;
        }

        // Priority 3: Guess from source name as last resort
        if (icon_filename == null || icon_filename.length == 0) {
            icon_filename = SourceMetadata.sanitize_filename(source.name) + "-logo.png";
        }

        // Check if icon file exists and load it using Cairo
        if (icon_filename != null) {
            var data_dir = GLib.Environment.get_user_data_dir();
            var icon_path = GLib.Path.build_filename(data_dir, "paperboy", "source_logos", icon_filename);

            if (GLib.FileUtils.test(icon_path, GLib.FileTest.EXISTS)) {
                try {
                    // Load and scale using ImageCache (like cardBuilder)
                    int size = CategoryIcons.SIDEBAR_ICON_SIZE;
                    var probe = ImageCache.get_global().get_or_load_file("pixbuf::file:%s::%dx%d".printf(icon_path, 0, 0), icon_path, 0, 0);
                    if (probe != null) {
                        int orig_w = 0; int orig_h = 0;
                        try { orig_w = probe.get_width(); } catch (GLib.Error e) { orig_w = 0; }
                        try { orig_h = probe.get_height(); } catch (GLib.Error e) { orig_h = 0; }
                        double scale = 1.0;
                        if (orig_w > 0 && orig_h > 0) scale = double.max((double)size / orig_w, (double)size / orig_h);
                        int sw = (int)(orig_w * scale);
                        int sh = (int)(orig_h * scale);
                        if (sw < 1) sw = 1;
                        if (sh < 1) sh = 1;

                        var scaled_icon = ImageCache.get_global().get_or_load_file("pixbuf::file:%s::%dx%d".printf(icon_path, sw, sh), icon_path, sw, sh);

                        // Render centered on Cairo surface
                        var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, size, size);
                        var cr = new Cairo.Context(surface);
                        int x = (size - sw) / 2;
                        int y = (size - sh) / 2;
                        try { Gdk.cairo_set_source_pixbuf(cr, scaled_icon, x, y); cr.paint(); } catch (GLib.Error e) { }
                        var surf_key = "pixbuf::surface:icon:%s::%dx%d".printf(icon_path, size, size);
                        var pb_surf = ImageCache.get_global().get_or_from_surface(surf_key, surface, 0, 0, size, size);

                        if (pb_surf != null) {
                            var pic = new Gtk.Picture();
                            try { pic.set_paintable(Gdk.Texture.for_pixbuf(pb_surf)); } catch (GLib.Error e) { }
                            pic.set_size_request(size, size);
                            return pic;
                        }
                    }
                } catch (GLib.Error e) {
                    // Fall through to fallback icon
                }
            }
        }

        // Fallback: return a themed RSS icon (as Gtk.Image) sized for sidebar
        int fsize = CategoryIcons.SIDEBAR_ICON_SIZE;
        try {
            var fallback = new Gtk.Image.from_icon_name("application-rss+xml-symbolic");
            fallback.set_pixel_size(fsize);
            return fallback;
        } catch (GLib.Error e) {
            // As a very last resort return an empty Picture sized correctly
            var pic = new Gtk.Picture();
            pic.set_size_request(fsize, fsize);
            return pic;
        }
    }

    // Helper to build category rows to the popular categories container
    private void build_category_row_to_container(string title, string cat, bool selected=false) {
        if (popular_categories_container == null) {
            // Fallback to old behavior if container doesn't exist yet
            add_row(title, cat, selected);
            return;
        }

        var row_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        row_box.set_margin_start(12);
        row_box.set_margin_end(12);
        row_box.set_margin_top(4);
        row_box.set_margin_bottom(4);

        var holder = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        holder.set_hexpand(false);
        holder.set_vexpand(false);

        var prefix_widget = CategoryIcons.create_category_icon(cat);
        if (prefix_widget != null) { holder.append(prefix_widget); }
        row_box.append(holder);
        sidebar_icon_holders.set(cat, holder);

        var label = new Gtk.Label(title);
        label.set_xalign(0);
        label.set_hexpand(true);
        row_box.append(label);

        var button = new Gtk.Button();
        // Prevent the button grabbing keyboard focus which can trigger the
        // scrolled window to scroll and jump the view when clicked.
        try { button.set_can_focus(false); } catch (GLib.Error e) { }
        try { button.set_can_focus(false); } catch (GLib.Error e) { }
        button.set_child(row_box);
        button.add_css_class("flat");
        button.add_css_class("sidebar-item-row");

        // Store category ID on the button for later lookup
        button.set_data("category_id", cat);

        // If this category is currently selected, mark the button as selected
        if (selected) {
            button.add_css_class("selected");
            currently_selected_button = button;
        }

        button.clicked.connect(() => {
            try {
                // Remove selected class from any previously selected row
                if (currently_selected_row != null) {
                    currently_selected_row.remove_css_class("selected");
                    currently_selected_row = null;
                }

                // Remove selected class from previously selected button
                if (currently_selected_button != null) {
                    currently_selected_button.remove_css_class("selected");
                }

                // Add selected class to this button
                button.add_css_class("selected");
                currently_selected_button = button;

                handle_category_activation(cat, title);
            } catch (GLib.Error e) { }
        });

        popular_categories_container.append(button);
    }
}
