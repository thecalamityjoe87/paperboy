using Gtk;
using Adw;

public class HeaderManager : GLib.Object {
    private NewsWindow window;

    public Gtk.Label category_label;
    public Gtk.Label category_subtitle;
    public Gtk.Box? category_icon_holder;
    public Gtk.Label source_label;
    public Gtk.Image source_logo;

    public HeaderManager(NewsWindow w) {
        window = w;
    }

    public void update_category_icon() {
        try {
            if (category_icon_holder == null) return;
            Gtk.Widget? child = category_icon_holder.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                category_icon_holder.remove(child);
                child = next;
            }
            var hdr = CategoryIcons.create_category_header_icon(window.prefs.category, 36);
            if (hdr != null) category_icon_holder.append(hdr);
        } catch (GLib.Error e) { }
    }

    public void update_source_info() {
        try {
            if (window.prefs != null && window.prefs.category == "local_news") {
                try { source_label.set_text("Local News"); } catch (GLib.Error e) { }
                try {
                    string? local_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "local-mono.svg"));
                    if (local_icon == null) local_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "local-mono.svg"));
                    if (local_icon != null) {
                        string use_path = local_icon;
                        try {
                            if (window.is_dark_mode()) {
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

        if (window.prefs.category == "frontpage") {
            try { source_label.set_text("Multiple Sources"); } catch (GLib.Error e) { }
            try {
                string? multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono.svg"));
                if (multi_icon == null) multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "multiple-mono.svg"));
                if (multi_icon != null) {
                    string use_path = multi_icon;
                    try {
                        if (window.is_dark_mode()) {
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

        if (window.prefs.category == "topten") {
            try { source_label.set_text("Multiple Sources"); } catch (GLib.Error e) { }
            try {
                string? multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono.svg"));
                if (multi_icon == null) multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "multiple-mono.svg"));
                if (multi_icon != null) {
                    string use_path = multi_icon;
                    try {
                        if (window.is_dark_mode()) {
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

        if (window.prefs.preferred_sources != null && window.prefs.preferred_sources.size > 1) {
            source_label.set_text("Multiple Sources");
            string? multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "symbolic", "multiple-mono.svg"));
            if (multi_icon == null) multi_icon = DataPaths.find_data_file(GLib.Path.build_filename("icons", "multiple-mono.svg"));
            if (multi_icon != null) {
                try {
                    string use_path = multi_icon;
                    try {
                        if (window.is_dark_mode()) {
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
                } catch (GLib.Error e) { }
            }
            try { source_logo.set_from_icon_name("application-rss+xml-symbolic"); } catch (GLib.Error e) { }
            return;
        }

        NewsSource eff = window.effective_news_source();

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

        try { source_label.set_text(source_name); } catch (GLib.Error e) { }

        if (logo_file != null) {
            string? logo_path = DataPaths.find_data_file(GLib.Path.build_filename("icons", logo_file));
            if (logo_path != null) {
                try {
                    var pixbuf = new Gdk.Pixbuf.from_file(logo_path);
                    if (pixbuf != null) {
                        int orig_width = pixbuf.get_width();
                        int orig_height = pixbuf.get_height();
                        double aspect_ratio = (double)orig_width / orig_height;
                        double scale_factor;
                        if (aspect_ratio > 2.0 || aspect_ratio < 0.5) {
                            scale_factor = double.min(40.0 / orig_width, 40.0 / orig_height);
                        } else if (aspect_ratio > 1.5 || aspect_ratio < 0.67) {
                            scale_factor = double.min(36.0 / orig_width, 36.0 / orig_height);
                        } else {
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

        source_logo.set_from_icon_name("application-rss+xml-symbolic");
    }

    public void update_content_header() {
        string disp = category_display_name_for(window.prefs.category);
        string label_text;
        try {
            string q = window.get_current_search_query();
            if (q != null && q.length > 0)
                label_text = "Search Results: \"" + q + "\" in " + disp;
            else
                label_text = disp;
        } catch (GLib.Error e) {
            label_text = disp;
        }
        Idle.add(() => {
            try { if (category_label != null) category_label.set_text(label_text); } catch (GLib.Error e) { }
            try { update_category_icon(); } catch (GLib.Error e) { }
            try { update_source_info(); } catch (GLib.Error e) { }
            return false;
        });
    }

    public void update_content_header_now() {
        string disp = category_display_name_for(window.prefs.category);
        string label_text;
        try {
            string q = window.get_current_search_query();
            if (q != null && q.length > 0)
                label_text = "Search Results: \"" + q + "\" in " + disp;
            else
                label_text = disp;
        } catch (GLib.Error e) {
            label_text = disp;
        }

        try { if (category_label != null) category_label.set_text(label_text); } catch (GLib.Error e) { }

        if (window.prefs.category == "topten") {
            try {
                if (category_subtitle != null) {
                    // Make subtitle slightly larger for emphasis using Pango markup
                    try { category_subtitle.set_markup("<span size='11000'>TOP STORIES RIGHT NOW</span>"); } catch (GLib.Error e) { category_subtitle.set_text("TOP STORIES RIGHT NOW"); }
                    category_subtitle.set_visible(true);
                }
            } catch (GLib.Error e) { }
        } else {
            try {
                if (category_subtitle != null) category_subtitle.set_visible(false);
            } catch (GLib.Error e) { }
        }

        try { update_category_icon(); } catch (GLib.Error e) { }
        try { update_source_info(); } catch (GLib.Error e) { }
    }

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
        if (cat == null || cat.length == 0) return "News";
        string s = cat.strip();
        if (s.length == 0) return "News";
        s = s.replace("_", " ").replace("-", " ");
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
}
