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

    public SidebarManager(NewsWindow window, Gtk.ListBox list, SidebarActivateHandler? activate_cb = null) {
        GLib.Object();
        this.window = window;
        this.sidebar_list = list;
        this.sidebar_icon_holders = new Gee.HashMap<string, Gtk.Box>();
        this.activate_cb = activate_cb;
    }

    // Rebuild the sidebar rows according to the currently selected source
    public void rebuild_rows() {
        try {
            string? _dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
            if (_dbg != null && _dbg.length > 0) {
                string pref = AppDebugger.array_join(window.prefs.preferred_sources);
                window.append_debug_log("rebuild_sidebar: preferred_sources=" + pref + " current_category=" + window.prefs.category);
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
            if (_dbg2 != null && _dbg2.length > 0) window.append_debug_log("rebuild_sidebar: removed_rows=" + removed.to_string());
        } catch (GLib.Error e) { }

        // Place "The Frontpage" and "My Feed" above the Categories header,
        // then include the "All Categories" option
            add_row("The Frontpage", "frontpage", window.prefs.category == "frontpage");
            add_row("My Feed", "myfeed", window.prefs.category == "myfeed");
            add_row("Local News", "local_news", window.prefs.category == "local_news");
            add_header("Popular Categories");
            add_row("All Categories", "all", window.prefs.category == "all");

        // If multiple preferred sources are selected, build the union of
        // categories supported by those sources and show only those rows.
        if (window.prefs.preferred_sources != null && window.prefs.preferred_sources.size > 1) {
            var allowed = new Gee.HashMap<string, bool>();
            string[] default_cats = { "general", "us", "technology", "science", "sports", "health", "entertainment", "politics", "lifestyle" };
            foreach (var c in default_cats) allowed.set(c, true);

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

            string[] priority = { "general", "us", "technology", "science", "markets", "industries", "economics", "wealth", "green", "sports", "health", "entertainment", "politics", "lifestyle" };
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
            add_row("Science", "science", window.prefs.category == "science");
            add_row("Sports", "sports", window.prefs.category == "sports");
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

    // Add a simple section header row
    public void add_header(string title) {
        var header_row = new Adw.ActionRow();
        header_row.set_title(title);
        header_row.activatable = false;
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

        row.activated.connect(() => {
            // Let the owner handle preference/state updates via callback
            try {
                if (activate_cb != null) activate_cb(cat, title);
            } catch (GLib.Error e) { }
            // Select the row in the UI for immediate feedback
            try { sidebar_list.select_row(row); } catch (GLib.Error e) { }
        });

        sidebar_list.append(row);
        try {
            string? _dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
            if (_dbg != null && _dbg.length > 0) window.append_debug_log("sidebar_add_row: cat=" + cat + " title=" + title + " selected=" + (selected ? "yes" : "no"));
        } catch (GLib.Error e) { }
        if (selected) sidebar_list.select_row(row);
    }
}
