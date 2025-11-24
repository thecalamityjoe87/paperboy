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

public delegate void SidebarActivateHandler(string cat, string title);

public class SidebarManager : GLib.Object {
    private NewsWindow window;
    private Gtk.ListBox sidebar_list;
    private Gee.HashMap<string, Gtk.Box> sidebar_icon_holders;
    private SidebarActivateHandler? activate_cb;
    private Gtk.ScrolledWindow sidebar_scrolled;
    private Gtk.Revealer sidebar_revealer;
    private Adw.NavigationPage sidebar_page;

    public signal void category_selected(string category);

    public SidebarManager(NewsWindow window, SidebarActivateHandler? activate_cb = null) {
        GLib.Object();
        this.window = window;
        this.sidebar_icon_holders = new Gee.HashMap<string, Gtk.Box>();
        this.activate_cb = activate_cb;
        build_sidebar_ui();
    }

    private void build_sidebar_ui() {
        // Create list
        sidebar_list = new Gtk.ListBox();
        sidebar_list.add_css_class("navigation-sidebar");
        sidebar_list.set_selection_mode(Gtk.SelectionMode.SINGLE);
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

        // Clear existing rows
        int removed = 0;
        Gtk.Widget? child = sidebar_list.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            try { sidebar_list.remove(child); } catch (GLib.Error e) { }
            child = next;
            removed++;
        }

        // Place "Front Page" and "My Feed" above the Categories header
            add_row("Top Ten", "topten", window.prefs.category == "topten");
            add_row("Front Page", "frontpage", window.prefs.category == "frontpage");
            add_row("My Feed", "myfeed", window.prefs.category == "myfeed");
            add_row("Local News", "local_news", window.prefs.category == "local_news");
            add_header("Popular Categories");

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
                if (present) add_row(window.category_display_name_for(cat), cat, window.prefs.category == cat);
            }
            return;
        }

        // Single-source path: show categories appropriate to the selected source
        NewsSource sidebar_eff = effective_news_source();
        if (sidebar_eff == NewsSource.BLOOMBERG) {
            add_row("Markets", "markets", window.prefs.category == "markets");
            add_row("Industries", "industries", window.prefs.category == "industries");
            add_row("Economics", "economics", window.prefs.category == "economics");
            add_row("Wealth", "wealth", window.prefs.category == "wealth");
            add_row("Green", "green", window.prefs.category == "green");
            add_row("Technology", "technology", window.prefs.category == "technology");
            add_row("Politics", "politics", window.prefs.category == "politics");
        } else {
            add_row("World News", "general", window.prefs.category == "general");
            add_row("US News", "us", window.prefs.category == "us");
            add_row("Technology", "technology", window.prefs.category == "technology");
            add_row("Business", "business", window.prefs.category == "business");
            add_row("Sports", "sports", window.prefs.category == "sports");
            add_row("Science", "science", window.prefs.category == "science");
            add_row("Health", "health", window.prefs.category == "health");
            add_row("Entertainment", "entertainment", window.prefs.category == "entertainment");
            add_row("Politics", "politics", window.prefs.category == "politics");
            try {
                if (NewsSources.supports_category(sidebar_eff, "lifestyle")) {
                    add_row("Lifestyle", "lifestyle", window.prefs.category == "lifestyle");
                }
            } catch (GLib.Error e) { add_row("Lifestyle", "lifestyle", window.prefs.category == "lifestyle"); }
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
        foreach (var kv in sidebar_icon_holders.entries) {
            string cat = kv.key;
            Gtk.Box holder = kv.value;
            Gtk.Widget? child = holder.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                holder.remove(child);
                child = next;
            }
            var w = CategoryIcons.create_category_icon(cat);
            if (w != null) holder.append(w);
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

    // Add a selectable row with optional category icon and activation handling
    public void add_row(string title, string cat, bool selected=false) {
        var row = new Adw.ActionRow();
        row.set_title(title);
        row.activatable = true;
        var holder = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        holder.set_hexpand(false);
        holder.set_vexpand(false);

        var prefix_widget = CategoryIcons.create_category_icon(cat);
        if (prefix_widget != null) { holder.append(prefix_widget); }
        row.add_prefix(holder);
        sidebar_icon_holders.set(cat, holder);

        // store category on the row for future retrieval
        row.set_data("category_id", cat);

        row.activated.connect(() => {
            try {
                handle_category_activation(cat, title);
            } catch (GLib.Error e) { }
            try { sidebar_list.select_row(row); } catch (GLib.Error e) { }
        });

        sidebar_list.append(row);
        if (selected) sidebar_list.select_row(row);
    }
}
