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

public class HeaderManager : GLib.Object {
    // Size of the icon beside the page title (category icons and feed
    // logos). Sized up from 36 so the square icons match the 4:3 national
    // flags, which only fill their box's width.
    private const int HEADER_ICON_SIZE = 42;

    private weak NewsWindow window;

    public Gtk.Label category_label;
    public Gtk.Label category_subtitle;
    public Gtk.Box? category_icon_holder;

    public HeaderManager(NewsWindow w) {
        window = w;

        // Listen for RSS source updates (logo downloads)
        var store = Paperboy.RssSourceStore.get_instance();
        store.source_updated.connect((source) => {
            // If the currently selected category is this RSS feed, refresh the header icon
            if (window.prefs.category != null && window.prefs.category.has_prefix("rssfeed:")) {
                string feed_url = window.prefs.category.substring(8);
                if (feed_url == source.url) {
                    Idle.add(() => {
                        update_category_icon();
                        update_podcast_button();
                        return false;
                    });
                }
            }
        });

        wire_podcast_button();
        wire_clear_history_button();
        wire_weather();

        var state_store = window.article_state_store;
        if (state_store != null) {
            state_store.saved_articles_loaded.connect(on_saved_count_changed);
            state_store.saved_article_added.connect((url) => { on_saved_count_changed(); });
            state_store.saved_article_removed.connect((url) => { on_saved_count_changed(); });
        }
    }

    private void on_saved_count_changed() {
        ViewSession.view_idle(() => {
            if (window.prefs.category == "saved") update_date_label();
            return false;
        });
    }

    // Opens GNOME Weather when installed; otherwise the weather is display-only.
    private void wire_weather() {
        var box = window.content_view != null ? window.content_view.weather_box : null;
        if (box == null) return;
        var click = new Gtk.GestureClick();
        click.set_button(1);
        box.add_controller(click);
        click.released.connect(() => {
            var app_info = new GLib.DesktopAppInfo("org.gnome.Weather.desktop");
            if (app_info == null) return;
            try {
                app_info.launch(null, window.get_display().get_app_launch_context());
            } catch (GLib.Error e) {
                GLib.warning("HeaderManager: couldn't open GNOME Weather: %s", e.message);
            }
        });
    }

    // Global search is its own view; prefs.category still names the page underneath.
    private bool is_searching() {
        return window.search_manager != null && window.search_manager.get_query().strip().length > 0;
    }

    // Pages showing the active local area's weather (My Feed only once it's enabled).
    private bool shows_weather(string? category) {
        if (category == "myfeed") return window.prefs.personalized_feed_enabled;
        return category == "local_news";
    }

    // Current conditions for the active local area, shown from cache right
    // away and refreshed in the background once stale.
    private void update_weather() {
        var view = window.content_view;
        if (view == null || view.weather_box == null) return;
        var area = NewsPreferences.get_instance().get_active_local_area();
        if (is_searching() || !shows_weather(window.prefs.category) || area == null) {
            hide_weather();
            return;
        }

        var cached = WeatherService.cached(area);
        if (cached != null) apply_weather(area, cached); else hide_weather();

        string key = area.key;
        var session = ViewSession.current();
        WeatherService.get_async(area, (report) => {
            if (report == null || session.is_closed()) return;
            var active = NewsPreferences.get_instance().get_active_local_area();
            if (active == null || active.key != key) return;
            apply_weather(active, report);
        });
    }

    private void apply_weather(LocalArea area, WeatherReport report) {
        var view = window.content_view;
        view.weather_icon.set_from_icon_name(report.icon_name());
        view.weather_temp_label.set_markup("%d<span rise='9000' size='50%%'>°</span>".printf((int) Math.round(report.temperature)));
        view.weather_condition_label.set_text(report.description());
        // TRANSLATORS: today's high and low temperatures, e.g. "H 75° · L 58°"; keep the <b></b> markup
        view.weather_range_label.set_markup(_("H <b>%s</b> · L <b>%s</b>").printf(WeatherReport.format_degrees(report.high), WeatherReport.format_degrees(report.low)));

        bool has_weather_app = new GLib.DesktopAppInfo("org.gnome.Weather.desktop") != null;
        string tooltip = _("Weather in %s").printf(area.name);
        if (has_weather_app) tooltip += _("\nOpen Weather for the full forecast");
        view.weather_box.set_tooltip_text(tooltip);
        view.weather_box.set_cursor_from_name(has_weather_app ? "pointer" : null);
        view.weather_box.set_visible(true);
        ViewSession.current().on_close("weather", () => hide_weather());
    }

    private void hide_weather() {
        var view = window.content_view;
        if (view != null && view.weather_box != null) view.weather_box.set_visible(false);
    }

    // Wired once - the button is reused for the app's whole lifetime.
    private void wire_clear_history_button() {
        var button = window.content_view != null ? window.content_view.clear_history_button : null;
        if (button == null) return;

        button.clicked.connect(() => {
            DialogUtils.confirm_destructive(window, _("Clear history?"),
                _("This will permanently delete your reading history. This can't be undone."), _("Clear History"), () => {
                if (window.article_state_store != null) window.article_state_store.clear_history();
                if (window.prefs != null && window.prefs.category == "history") window.fetch_news();
                if (window.toast_manager != null) window.toast_manager.show_toast(_("History cleared"));
            });
        });
    }

    // Shows/hides/relabels the "Add podcast"/"Browse podcasts" button.
    // Toggles opacity/can_target, not set_visible() - keeps its reserved
    // layout space so the separator below never shifts (see date_overlay).
    private void update_podcast_button() {
        var button = window.content_view != null ? window.content_view.rss_podcast_button : null;
        if (button == null) return;

        if (window.prefs.category == null || !window.prefs.category.has_prefix("rssfeed:")) {
            button.set_opacity(0);
            button.set_can_target(false);
            return;
        }

        string feed_url = window.prefs.category.substring(8);
        var rss_source = Paperboy.RssSourceStore.get_instance().get_source_by_url(feed_url);
        if (rss_source == null || rss_source.podcast_feed_url == null) {
            button.set_opacity(0);
            button.set_can_target(false);
            return;
        }

        button.set_opacity(1);
        button.set_can_target(true);

        // Multiple podcasts: no single "the" one to be "Subscribed" to.
        if (rss_source.podcast_candidate_count > 1) {
            if (window.content_view.rss_podcast_button_label != null) {
                window.content_view.rss_podcast_button_label.set_text(_("Browse podcasts"));
            }
            button.add_css_class("suggested-action");
            return;
        }

        // One podcast: normal add/remove toggle.
        int64 synthetic_id = Paperboy.PodcastFeedResolver.get_instance().compute_synthetic_feed_id(rss_source.podcast_feed_url);
        bool subscribed = Paperboy.PodcastSubscriptionStore.get_instance().is_subscribed(synthetic_id);
        if (window.content_view.rss_podcast_button_label != null) {
            window.content_view.rss_podcast_button_label.set_text(subscribed ? _("Subscribed") : _("Add podcast"));
        }
        if (subscribed) {
            button.remove_css_class("suggested-action");
        } else {
            button.add_css_class("suggested-action");
        }
    }

    // Wired once - the button is reused for the app's whole lifetime.
    private void wire_podcast_button() {
        var button = window.content_view != null ? window.content_view.rss_podcast_button : null;
        if (button == null) return;

        // Picker dialog subscriptions don't otherwise notify this button.
        var sub_store = Paperboy.PodcastSubscriptionStore.get_instance();
        sub_store.subscription_added.connect(() => { update_podcast_button(); });
        sub_store.subscription_removed.connect(() => { update_podcast_button(); });

        button.clicked.connect(() => {
            if (window.prefs.category == null || !window.prefs.category.has_prefix("rssfeed:")) return;
            string feed_url = window.prefs.category.substring(8);
            var rss_source = Paperboy.RssSourceStore.get_instance().get_source_by_url(feed_url);
            if (rss_source == null || rss_source.podcast_feed_url == null) return;
            string podcast_feed_url = rss_source.podcast_feed_url;

            // One podcast: just toggle it, no need to search first.
            if (rss_source.podcast_candidate_count <= 1) {
                int64 synthetic_id = Paperboy.PodcastFeedResolver.get_instance().compute_synthetic_feed_id(podcast_feed_url);
                if (sub_store.is_subscribed(synthetic_id)) {
                    sub_store.unsubscribe(synthetic_id);
                    return;
                }
            }

            // Otherwise search fresh and let the user choose.
            button.set_sensitive(false);
            string domain_source = UrlUtils.extract_root_url(rss_source.original_url) != null ? rss_source.original_url : rss_source.url;
            string site_domain = UrlUtils.extract_host_from_url(domain_source);
            Paperboy.PodcastIndexService.get_instance().find_podcasts_by_site(rss_source.name, site_domain, rss_source.url, (shows) => {
                button.set_sensitive(true);

                if (shows.size >= 2) {
                    var parent = window as Gtk.Window;
                    if (parent != null) {
                        PodcastPickerDialog.show(window, shows, podcast_feed_url, parent);
                    }
                    return;
                }

                // 0 or 1 result: fall back to the already-known url.
                Paperboy.PodcastFeedResolver.get_instance().resolve_show(podcast_feed_url, window.session, (success, show, error_message) => {
                    if (!success || show == null) {
                        if (window.toast_manager != null) {
                            // TRANSLATORS: %s is the reason, e.g. "Couldn't add podcast: no episodes found"
                            window.toast_manager.show_toast(_("Couldn't add podcast: %s").printf(error_message ?? _("unknown error")));
                        }
                        return;
                    }
                    sub_store.subscribe(show);
                    if (window.toast_manager != null) {
                        window.toast_manager.show_toast(_("Podcast added: %s").printf(show.title));
                    }
                });
            });
        });
    }

    // Create a circular clipped version of a pixbuf
    private Gdk.Pixbuf? create_circular_pixbuf(Gdk.Pixbuf source, int size) {
        var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, size, size);
        if (surface.status() != Cairo.Status.SUCCESS) {
            warning("Cairo surface creation failed: %s", surface.status().to_string());
            return null;
        }
        var cr = new Cairo.Context(surface);

        // Create circular clipping path
        cr.arc(size / 2.0, size / 2.0, size / 2.0, 0, 2 * Math.PI);
        cr.clip();

        // Same dimmed backing as .circular-logo, for transparent logos.
        cr.set_source_rgba(246 / 255.0, 243 / 255.0, 236 / 255.0, 0.92);
        cr.paint();

        // Draw the pixbuf
        Gdk.cairo_set_source_pixbuf(cr, source, 0, 0);
        cr.paint();

        if (surface.status() != Cairo.Status.SUCCESS) {
            warning("Cairo drawing failed: %s", surface.status().to_string());
        return null;
        }

        // Convert surface back to pixbuf
        string key = "pixbuf::circular::%p::%dx%d".printf(source, size, size);
        return ImageCache.get_global().get_or_from_surface(key, surface, 0, 0, size, size);
    }

    public void update_category_icon() {
        if (category_icon_holder == null) return;

        // Clear existing icon
        clear_category_icon_holder();

        // Search swaps the header title too (see ContentView.filter_by_query).
        if (is_searching()) {
            var search_icon = CategoryIconsUtils.create_category_header_icon("search", HEADER_ICON_SIZE);
            if (search_icon != null) category_icon_holder.append(search_icon);
            return;
        }

        // Handle RSS feed icons
        if (window.prefs.category != null && window.prefs.category.has_prefix("rssfeed:")) {
            set_rss_feed_icon();
            return;
        }

        // Handle regular category icons
        var icon = CategoryIconsUtils.create_category_header_icon(window.prefs.category, HEADER_ICON_SIZE);
        if (icon != null) category_icon_holder.append(icon);
    }

    private void clear_category_icon_holder() {
        Gtk.Widget? child = category_icon_holder.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            category_icon_holder.remove(child);
            child = next;
        }
    }

    private void set_rss_feed_icon() {
        // Extract feed URL from category
        if (window.prefs.category.length <= 8) {
            warning("Malformed rssfeed category: too short");
            set_fallback_rss_icon();
            return;
        }

        string feed_url = window.prefs.category.substring(8);
        var rss_store = Paperboy.RssSourceStore.get_instance();
        var rss_source = rss_store.get_source_by_url(feed_url);

        if (rss_source == null) {
            set_fallback_rss_icon();
            return;
        }

        // Try to load custom logo
        if (try_set_rss_logo(rss_source.icon_filename)) {
            return;
        }

        // Fallback to generic RSS icon
        set_fallback_rss_icon();
    }

    private bool try_set_rss_logo(string? icon_filename) {
        if (icon_filename == null || icon_filename.length == 0) {
            debug("HeaderManager: icon_filename is null or empty");
            return false;
        }

        var data_dir = GLib.Environment.get_user_data_dir();
        if (data_dir == null) return false;

        string logo_path = GLib.Path.build_filename(data_dir, "paperboy", "source_logos", icon_filename);
        if (!GLib.FileUtils.test(logo_path, GLib.FileTest.EXISTS)) {
            debug("HeaderManager: Logo file does NOT exist at path");
            return false;
        }

        string key = "pixbuf::file:%s::%dx%d".printf(logo_path, HEADER_ICON_SIZE, HEADER_ICON_SIZE);
        var pixbuf = ImageCache.get_global().get_or_load_file(key, logo_path, HEADER_ICON_SIZE, HEADER_ICON_SIZE);

        if (pixbuf == null || pixbuf.get_width() <= 1 || pixbuf.get_height() <= 1) {
            return false;
        }

        var circular = create_circular_pixbuf(pixbuf, HEADER_ICON_SIZE);
        if (circular == null) return false;

        var texture = Gdk.Texture.for_pixbuf(circular);
        var img = new Gtk.Image.from_paintable(texture);
        img.set_pixel_size(HEADER_ICON_SIZE);
        category_icon_holder.append(img);
        return true;
    }

    private void set_fallback_rss_icon() {
        var img = new Gtk.Image();
        img.set_from_icon_name("application-rss+xml-symbolic");
        img.set_pixel_size(HEADER_ICON_SIZE);
        category_icon_holder.append(img);
    }

    public void update_content_header() {
        string disp_cat = category_display_name_for(window.prefs.category);
        //string q = window.get_current_search_query();
        //string label_text = (q != null && q.length > 0) ? ("Search Results: \"" + q + "\" in " + disp) : disp;
        Idle.add(() => {
            if (category_label != null) category_label.set_text(disp_cat);
            update_date_label();
            update_category_icon();
            update_podcast_button();
            update_weather();
            return false;
        });
    }

    public void update_content_header_now() {
        string disp_cat = category_display_name_for(window.prefs.category);
        //string q = window.get_current_search_query();
        //string label_text = (q != null && q.length > 0) ? ("Search Results: \"" + q + "\" in " + disp) : disp;

        if (category_label != null) category_label.set_text(disp_cat);

        if (category_subtitle != null) category_subtitle.set_visible(false);

        update_date_label();
        update_category_icon();
        update_podcast_button();
        update_weather();
    }

    // Today's date is meaningless on archive pages: Saved shows its count instead, History drops the row.
    public void update_date_label() {
        var view = window.content_view;
        if (view == null || view.date_overlay == null || view.date_label == null) return;
        string cat = is_searching() ? "" : window.prefs.category;
        view.date_overlay.set_visible(cat != "history");

        if (cat == "saved") {
            int count = window.article_state_store != null ? window.article_state_store.get_saved_count() : 0;
            view.date_label.set_text(ngettext("%d saved article", "%d saved articles", count).printf(count));
        } else {
            view.date_label.set_text(DateUtils.full_date(new DateTime.now_local()));
        }
    }

    public string category_display_name_for(string cat) {
        // Handle RSS feed categories
        if (cat != null && cat.has_prefix("rssfeed:")) {
            if (cat.length <= 8) {
                warning("Malformed rssfeed category in display name");
                return _("RSS Feed");
            }
            string feed_url = cat.substring(8); // Extract URL after "rssfeed:" prefix
            var rss_store = Paperboy.RssSourceStore.get_instance();
            var rss_source = rss_store.get_source_by_url(feed_url);
            if (rss_source != null) {
                return rss_source.get_display_name();
            }
            return _("RSS Feed");
        }

        switch (cat) {
            case "frontpage": return _("Front Page");
            case "topten": return _("Trending");
            case "saved": return _("Saved");
            case "history": return _("History");
            case "general": return _("World News");
            case "us": return GoogleNewsUtils.national_label();
            case "world": return _("World News");
            case "nation": return GoogleNewsUtils.national_label();
            case "technology": return _("Technology");
            case "business": return _("Business");
            case "sports": return _("Sports");
            case "science": return _("Science");
            case "health": return _("Health");
            case "entertainment": return _("Entertainment");
            case "politics": return _("Politics");
            case "lifestyle": return _("Lifestyle");
            case "markets": return _("Markets");
            case "industries": return _("Industries");
            case "economics": return _("Economics");
            case "myfeed": return _("My Feed");
            case "local_news":
                var local_area = NewsPreferences.get_instance().get_active_local_area();
                return local_area != null ? local_area.display_name : _("Local News");
            case "podcasts": return _("Find Podcasts");
            case "podcasts_library": return _("My Library");
            case "magazines": return _("Magazine Rack");
            default: break;
        }
        if (cat == null || cat.length == 0) return _("News");
        string s = cat.strip();
        if (s.length == 0) return _("News");
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
        if (out.length == 0) return _("News");
        return out;
    }

}
