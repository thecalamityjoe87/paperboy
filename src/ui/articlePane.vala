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
using GLib;
using Adw;
using Soup;
using Tools;

public class ArticlePane : GLib.Object {
    private Adw.NavigationView nav_view;
    private Soup.Session session;
    private NewsWindow parent_window;
    private ImageHandler? image_handler;
    // Preview overlay components
    private Adw.OverlaySplitView? preview_split;
    private Gtk.Box? preview_content_box;
    // In-memory cache for article preview textures (url@WxH -> Gdk.Texture).
    // Use an LRU cache with a small capacity so previews don't accumulate
    // indefinitely and cause unbounded memory growth.
    // Use a shared preview cache managed by PreviewCacheManager so the
    // main window can clear preview textures on category switches.

    // Centralized debug log path for this module. Use this variable so the
    // path can be adjusted in one place if we change where debug output
    // should be written (for example under a per-user data dir).
    private static string debug_log_path = "/tmp/paperboy-debug.log";

    // Callback type for snippet results
    private delegate void SnippetCallback(string text);

    public ArticlePane(Adw.NavigationView navigation_view, Soup.Session soup_session, NewsWindow window, ImageHandler? img_handler = null) {
        nav_view = navigation_view;
        session = soup_session;
        parent_window = window;
        image_handler = img_handler;
        // Initialize shared preview cache (centralized)
        try { PreviewCacheManager.get_cache(); } catch (GLib.Error e) { }
    }
    
    // Set the preview overlay components (called after ArticleWindow construction)
    public void set_preview_overlay(Adw.OverlaySplitView split, Gtk.Box content_box) {
        preview_split = split;
        preview_content_box = content_box;
    }

    // Robustly open a URL in the user's configured browser. Try the
    // platform Gio.AppInfo API first; on failure fall back to executing
    // `xdg-open` as a last resort. We log failures to the debug log when
    // PAPERBOY_DEBUG is enabled so failures can be diagnosed remotely.
    public void open_article_in_browser(string uri) {
        // Log the click and the raw URI so debugging is reliable even when
        // AppInfo doesn't report an error (AppInfo may succeed silently
        // or the desktop may be misconfigured).
    try { AppDebugger.append_debug_log(debug_log_path, "open_article_in_browser: invoked with raw uri='" + (uri != null ? uri : "(null)") + "'"); } catch (GLib.Error e) { }

        // Basic sanity: reject empty URIs early and log them.
        if (uri == null || uri.strip().length == 0) {
            try { AppDebugger.append_debug_log(debug_log_path, "open_article_in_browser: empty uri, aborting"); } catch (GLib.Error e) { }
            return;
        }

        // Normalize a missing scheme: many scrapers or feeds sometimes
        // omit 'https://' and only provide 'example.com/path'. Assume
        // https when a scheme is missing to give the user a sensible
        // result rather than a no-op.
        string normalized = uri.strip();
            if (!(normalized.has_prefix("http://") || normalized.has_prefix("https://") || normalized.has_prefix("mailto:") || normalized.has_prefix("file:") || normalized.has_prefix("ftp:"))) {
            normalized = "https://" + normalized;
            try { AppDebugger.append_debug_log(debug_log_path, "open_article_in_browser: normalized uri to '" + normalized + "'"); } catch (GLib.Error e) { }
        }

        try {
            try {
                AppInfo.launch_default_for_uri(normalized, null);
                try { AppDebugger.append_debug_log(debug_log_path, "open_article_in_browser: AppInfo.launch_default_for_uri invoked for '" + normalized + "'"); } catch (GLib.Error _e) { }
                return;
            } catch (GLib.Error e) {
                try { AppDebugger.append_debug_log(debug_log_path, "open_article_in_browser: AppInfo.launch_default_for_uri failed: " + e.message); } catch (GLib.Error _e) { }
            }

            // AppInfo failed — log the failure and return. We purposely avoid
            // introducing platform-specific subprocess fallbacks here (they
            // caused compile-time binding issues earlier). If we need a
            // fallback later, add a well-tested `Gio.Subprocess`/portal-based
            // implementation behind a runtime check and feature-guard.
            try { AppDebugger.append_debug_log(debug_log_path, "open_article_in_browser: AppInfo.launch_default_for_uri failed for '" + normalized + "'"); } catch (GLib.Error _e) { }
        } catch (GLib.Error e) {
            try { AppDebugger.append_debug_log(debug_log_path, "open_article_in_browser: unexpected error: " + e.message); } catch (GLib.Error _e) { }
        }
    }


    // Show a modal preview with image and a small snippet
    // `category_id` is optional; when it's "local_news" we prefer the
    // app-local placeholder so previews for Local News items match the
    // card/hero placeholders used in the main UI.
    public void show_article_preview(string title, string url, string? thumbnail_url, string? category_id = null, string? source_name = null) {
        // Notify parent window that a preview is opening so it can track
        // the active preview (used to mark viewed on return).
        try { parent_window.preview_opened(url); } catch (GLib.Error e) { }
        
        // Clear previous preview content
        if (preview_content_box != null) {
            Gtk.Widget? child = preview_content_box.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                preview_content_box.remove(child);
                child = next;
            }
        }
        
        // Build a scrolling preview page
        var outer = new Gtk.Box(Orientation.VERTICAL, 0);

        outer.set_vexpand(true);
        outer.set_hexpand(false);
        outer.set_overflow(Gtk.Overflow.HIDDEN);

    // Get source from ArticleItem if available, otherwise infer from URL.
    // This ensures correct branding when multiple sources are enabled.
    NewsSource article_src = NewsSource.REDDIT; // Initialize to a default that will be overridden
    string? article_source_name = source_name; // Use the passed source_name directly!
    string? article_published = null;
    bool found_article_item = false;
    bool source_mapped = false;
    
    // Only look up in buffer if source_name wasn't provided
    if (article_source_name == null || article_source_name.length == 0) {
        foreach (var item in parent_window.article_buffer) {
            if (item.url == url && item is ArticleItem) {
                var ai = (ArticleItem) item;
                article_source_name = ai.source_name;
                article_published = ai.published;
                found_article_item = true;
                break;
            }
        }
    }
    if (found_article_item && article_source_name != null && article_source_name.length > 0) {
        // Map source name back to NewsSource enum
        if (article_source_name == "Reuters" || article_source_name.down().index_of("reuters") >= 0) { article_src = NewsSource.REUTERS; source_mapped = true; }
        else if (article_source_name == "The Guardian" || article_source_name.down().index_of("guardian") >= 0) { article_src = NewsSource.GUARDIAN; source_mapped = true; }
        else if (article_source_name == "BBC News" || article_source_name.down().index_of("bbc") >= 0) { article_src = NewsSource.BBC; source_mapped = true; }
        else if (article_source_name == "NY Times" || article_source_name.down().index_of("nytimes") >= 0) { article_src = NewsSource.NEW_YORK_TIMES; source_mapped = true; }
        else if (article_source_name == "Wall Street Journal" || article_source_name.down().index_of("wsj") >= 0) { article_src = NewsSource.WALL_STREET_JOURNAL; source_mapped = true; }
        else if (article_source_name == "Bloomberg" || article_source_name.down().index_of("bloomberg") >= 0) { article_src = NewsSource.BLOOMBERG; source_mapped = true; }
        else if (article_source_name == "NPR" || article_source_name.down().index_of("npr") >= 0) { article_src = NewsSource.NPR; source_mapped = true; }
        else if (article_source_name == "Fox News" || article_source_name.down().index_of("fox") >= 0) { article_src = NewsSource.FOX; source_mapped = true; }
        else if (article_source_name == "Reddit" || article_source_name.down().index_of("reddit") >= 0) { article_src = NewsSource.REDDIT; source_mapped = true; }
    }
    // If we didn't find ArticleItem OR found it but couldn't map the source name, infer from URL
    if (!found_article_item || !source_mapped) {
        article_src = SourceUtils.infer_source_from_url(url);
        
        // Check if the inferred source is actually a match or just a fallback
        // If it's a fallback (doesn't match the URL), we should use a generic placeholder
        bool is_actual_match = false;
        string url_lower = url.down();
        if (article_src == NewsSource.GUARDIAN && (url_lower.contains("guardian") || url_lower.contains("theguardian"))) is_actual_match = true;
        else if (article_src == NewsSource.BBC && url_lower.contains("bbc.")) is_actual_match = true;
        else if (article_src == NewsSource.REDDIT && (url_lower.contains("reddit") || url_lower.contains("redd.it"))) is_actual_match = true;
        else if (article_src == NewsSource.NEW_YORK_TIMES && (url_lower.contains("nytimes") || url_lower.contains("nyti.ms"))) is_actual_match = true;
        else if (article_src == NewsSource.WALL_STREET_JOURNAL && (url_lower.contains("wsj.com") || url_lower.contains("dowjones"))) is_actual_match = true;
        else if (article_src == NewsSource.BLOOMBERG && url_lower.contains("bloomberg")) is_actual_match = true;
        else if (article_src == NewsSource.REUTERS && url_lower.contains("reuters")) is_actual_match = true;
        else if (article_src == NewsSource.NPR && url_lower.contains("npr.org")) is_actual_match = true;
        else if (article_src == NewsSource.FOX && (url_lower.contains("foxnews") || url_lower.contains("fox.com"))) is_actual_match = true;
        
        // If it's not an actual match, mark it so we use generic placeholder
        if (!is_actual_match) {
            source_mapped = false; // This will trigger generic placeholder usage below
        }
    }

        // Title label - AT THE TOP
        var title_wrap = new Gtk.Box(Orientation.VERTICAL, 8);
        title_wrap.set_margin_start(16);
        title_wrap.set_margin_end(16);
        title_wrap.set_margin_top(24);
        title_wrap.set_halign(Gtk.Align.FILL);
        title_wrap.set_hexpand(true);
        // Decode any HTML entities that may be present in scraped titles
        var ttl = new Gtk.Label(HtmlUtils.strip_html(title));
        ttl.add_css_class("title-2");
        ttl.set_xalign(0);
        ttl.set_wrap(true);
        ttl.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        ttl.set_lines(4);
        ttl.set_selectable(true);  // Keep selectable for copying
        ttl.set_can_focus(false);  // Prevent cursor from appearing
        ttl.set_justify(Gtk.Justification.LEFT);
        title_wrap.append(ttl);

        // Metadata label (source + published date/time) - AFTER TITLE
        var meta_label = new Gtk.Label("");
        meta_label.set_xalign(0);
        meta_label.set_selectable(false);
        meta_label.add_css_class("caption");
        meta_label.set_halign(Gtk.Align.START);
        meta_label.set_wrap(false);
        meta_label.set_margin_top(4);
        title_wrap.append(meta_label);
        outer.append(title_wrap);

        // Image (constrained) - AFTER METADATA
        int img_w = 600;
        int img_h = clampi((int)(img_w * 9.0 / 16.0), 240, 420);
        var pic_box = new Gtk.Box(Orientation.VERTICAL, 0);
        pic_box.set_vexpand(false);
        pic_box.set_hexpand(false);
        pic_box.set_size_request(-1, img_h);
        pic_box.set_margin_start(16);
        pic_box.set_margin_end(16);
        pic_box.set_margin_top(16);
        pic_box.set_margin_bottom(0);

        var pic = new Gtk.Picture();
        pic.set_halign(Gtk.Align.CENTER);
        pic.set_hexpand(false);
        pic.set_size_request(-1, img_h);
        pic.set_content_fit(Gtk.ContentFit.COVER);
        pic.set_can_shrink(true);
        
        // Add rounded corners to the image
        pic.add_css_class("pane-card");
        pic.add_css_class("pane-round-image-card");  // optional new class for no-hover
        pic.set_overflow(Gtk.Overflow.HIDDEN);
        // If a thumbnail URL will be requested, skip painting any branded
        // placeholder now to avoid briefly showing a logo before the real
        // image loads. The async loader will paint a placeholder on failure
        // or when it decides a placeholder is preferable (e.g., very large
        // images). If no thumbnail URL is available, paint the usual
        // source/local placeholder immediately.
        bool will_load_image = thumbnail_url != null && thumbnail_url.length > 0 && (thumbnail_url.has_prefix("http://") || thumbnail_url.has_prefix("https://"));
                if (!will_load_image) {
            // Use the Local News placeholder when the article belongs to the
            // Local News category so previews match the feed cards. Otherwise
            // fall back to the source-specific placeholder.
                if (category_id != null && category_id == "local_news") {
                try {
                    // Delegate to the main window's local placeholder routine so
                    // the styling is consistent across the app.
                    parent_window.set_local_placeholder_image(pic, img_w, img_h);
                    } catch (GLib.Error e) {
                    // If for some reason the parent can't render the local
                    // placeholder, fall back to the per-source placeholder.
                    PlaceholderBuilder.set_placeholder_image_for_source(pic, img_w, img_h, article_src);
                }
            } else if (!source_mapped) {
                // Use generic gradient placeholder for unknown/RSS sources
                PlaceholderBuilder.create_gradient_placeholder(pic, img_w, img_h);
            } else {
                // Use an article-specific placeholder (so the preview shows the correct
                // source branding even when the user's global prefs include multiple
                // sources).
                PlaceholderBuilder.set_placeholder_image_for_source(pic, img_w, img_h, article_src);
            }
        }

        if (will_load_image) {
            int multiplier = (article_src == NewsSource.REDDIT) ? 2 : 3;
            int target_w = img_w * multiplier;
            int target_h = img_h * multiplier;
            // Try to serve a cached preview texture synchronously for snappy
            // preview opens. The cache key includes the requested size so we
            // can store scaled variants separately.
            bool loaded_from_cache = false;
            try {
                string key = make_preview_cache_key(thumbnail_url, target_w, target_h);
                // Use get_texture() to get cached texture instead of creating new one
                var texture = PreviewCacheManager.get_cache().get_texture(key);
                if (texture != null) {
                    try {
                        pic.set_paintable(texture);
                    } catch (GLib.Error e) { }
                    loaded_from_cache = true;
                }
            } catch (GLib.Error e) { /* ignore cache errors and continue to load */ }
            if (!loaded_from_cache) load_image_async(pic, thumbnail_url, target_w, target_h, article_src, category_id, source_mapped);
        }
        pic_box.append(pic);
        outer.append(pic_box);

        // Snippet area
        var pad = new Gtk.Box(Orientation.VERTICAL, 8);
        pad.set_margin_start(16);
        pad.set_margin_end(16);
        pad.set_margin_top(16);
        pad.set_margin_bottom(16);
        var snippet_label = new Gtk.Label("Loading snippet…");
        snippet_label.set_xalign(0);
        snippet_label.set_wrap(true);
        snippet_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        // Allow more lines in the preview (user requested more article text). The
        // scrolled container already constrains total height so this can expand
        // and be scrollable.
        snippet_label.set_lines(12);
        snippet_label.set_selectable(true);
        snippet_label.set_can_focus(false);  // Prevent cursor from appearing
        snippet_label.set_justify(Gtk.Justification.LEFT);
        pad.append(snippet_label);

    
        outer.append(pad);

        // Buttons row
        var actions = new Gtk.Box(Orientation.HORIZONTAL, 10);
        actions.add_css_class("article-actions");
        actions.set_margin_start(10);
        actions.set_margin_end(10);
        actions.set_margin_bottom(24);
        actions.set_margin_top(8);
        actions.set_halign(Gtk.Align.FILL);
        actions.set_homogeneous(true);

        var back_local = new Gtk.Button();
        var back_content = new Adw.ButtonContent();
        back_content.set_icon_name("window-close-symbolic");
        back_content.set_label("Close");
        back_local.set_child(back_content);
        back_local.set_hexpand(true);
        back_local.clicked.connect(() => {
            // Close the overlay split view
            if (preview_split != null) preview_split.set_show_sidebar(false);
            // Notify parent that the preview closed so it can mark the
            // article as viewed now that the user returned to the main view.
            try { parent_window.preview_closed(url); } catch (GLib.Error e) { }
        });

        // Create a single menu button for "Open" which exposes both
        // "Open in app" and "Open in browser" as menu items to reduce
        // visual clutter.
        var open_menu = new GLib.Menu();
        open_menu.append("View in app", "article.open-in-app");
        open_menu.append("Open in browser", "article.open-in-browser");
        // Keep the follow-source item as well under the same menu
        open_menu.append("Follow this source", "article.follow-source");

        var open_menu_btn = new Gtk.MenuButton();
        var menu_content = new Adw.ButtonContent();
        menu_content.set_icon_name("view-more-symbolic");
        menu_content.set_label("Article options");
        open_menu_btn.set_child(menu_content);
        open_menu_btn.set_menu_model(open_menu);
        open_menu_btn.set_hexpand(true);
        open_menu_btn.add_css_class("suggested-action");
        open_menu_btn.set_tooltip_text("Article view and source options");

        // Actions backing the menu entries
        var open_in_app_action = new GLib.SimpleAction("open-in-app", null);
        open_in_app_action.activate.connect(() => {
            try {
                string normalized = parent_window.normalize_article_url(url);
                if (parent_window.article_sheet != null) parent_window.article_sheet.open(normalized);
                if (preview_split != null) preview_split.set_show_sidebar(false);
            } catch (GLib.Error e) { }
        });

        var open_in_browser_action = new GLib.SimpleAction("open-in-browser", null);
        open_in_browser_action.activate.connect(() => {
            try { open_article_in_browser(url); } catch (GLib.Error e) { }
        });

        var follow_action = new GLib.SimpleAction("follow-source", null);
        follow_action.activate.connect(() => {
            try {
                // Show immediate feedback while the feed discovery runs.
                // Use the global window.toast_overlay directly so the
                // message is visible even if the content-local overlay
                // is not yet ready or has unexpected layout behavior.
                        try {
                        // Show a persistent (sticky) toast while feed discovery runs.
                        // It will be removed automatically when the next non-persistent
                        // toast is shown (e.g. success/failure message) or you can
                        // explicitly clear it by calling clear_persistent_toast().
                        parent_window.show_persistent_toast("Searching for feed...");
                } catch (GLib.Error _e) {
                    try { parent_window.show_persistent_toast("Searching for feed..."); } catch (GLib.Error __e) { }
                }

                parent_window.source_manager.follow_rss_source(url, article_source_name);
            } catch (GLib.Error e) { }
        });

        // Disable follow action for built-in sources (can't follow built-in providers)
        try {
            bool is_builtin = SourceManager.is_article_from_builtin(url);
            follow_action.set_enabled(!is_builtin);
        } catch (GLib.Error e) { }

        var action_group = new GLib.SimpleActionGroup();
        action_group.add_action(open_in_app_action);
        action_group.add_action(open_in_browser_action);
        action_group.add_action(follow_action);

        // Attach actions to the actions container so the menu can reference
        // them with the "article." prefix.
        actions.insert_action_group("article", action_group);

        actions.append(back_local);
        actions.append(open_menu_btn);
        outer.append(actions);

        // Add content to the preview container and show the overlay
        if (preview_content_box != null) {
            preview_content_box.append(outer);
        }
        
        if (preview_split != null) {
            preview_split.set_show_sidebar(true);
        }
        
        // Clear any auto-selection on the title label after it's shown
        Idle.add(() => {
            try { ttl.select_region(0, 0); } catch (GLib.Error e) { }
            return false;
        });
        
        try { parent_window.preview_opened(url); } catch (GLib.Error e) { }
        // Try to set metadata from any cached article entry (source + published time)
        var prefs = NewsPreferences.get_instance();
        string? homepage_published_any = article_published;
        string? explicit_source_name = article_source_name;
        
        // Parse encoded source name (format: "SourceName||logo_url##category::cat")
        if (explicit_source_name != null && explicit_source_name.length > 0) {
            int pipe_idx = explicit_source_name.index_of("||");
            if (pipe_idx >= 0) {
                explicit_source_name = explicit_source_name.substring(0, pipe_idx);
            }
            int cat_idx = explicit_source_name.index_of("##category::");
            if (cat_idx >= 0) {
                explicit_source_name = explicit_source_name.substring(0, cat_idx);
            }

            // Try to get the proper display name from source_info metadata
            // This ensures we show "Tom's Guide" instead of sanitized versions
            string? meta_display_name = SourceMetadata.get_display_name_for_source(explicit_source_name);
            if (meta_display_name == null || meta_display_name.length == 0) {
                // Try URL-based lookup as fallback
                string? url_display_name = null;
                string? url_logo_url = null;
                string? url_filename = null;
                SourceMetadata.get_source_info_by_url(url, out url_display_name, out url_logo_url, out url_filename);
                if (url_display_name != null && url_display_name.length > 0) {
                    meta_display_name = url_display_name;
                }
            }
            // Use the proper display name if found
            if (meta_display_name != null && meta_display_name.length > 0) {
                explicit_source_name = meta_display_name;
            }
        }

        // Also check for NewsArticle entries which may have published dates
        foreach (var item in parent_window.article_buffer) {
            if (item.url == url) {
                try {
                    if (item.get_type().name() == "Paperboy.NewsArticle") {
                        var na = (Paperboy.NewsArticle)item;
                        if (na.published != null && na.published.length > 0) {
                            homepage_published_any = na.published;
                        }
                    }
                } catch (GLib.Error e) { }
            }
        }
        // Choose a sensible display name for the source. Prefer an explicit
        // per-item source when present. Otherwise, derive a friendly name
        // from the inferred NewsSource. If inference fell back to the
        // user's default (e.g. NewsPreferences.news_source) while multiple
        // preferred sources are enabled, try to derive a host-based name
        // from the article URL so we don't incorrectly show a specific
        // provider like "The Guardian".
        string display_source = null;
        if (explicit_source_name != null && explicit_source_name.length > 0) {
            display_source = explicit_source_name;
        } else {
            // If no explicit source name, try to get it from source_info by URL
            string? url_display_name = null;
            string? url_logo_url = null;
            string? url_filename = null;
            SourceMetadata.get_source_info_by_url(url, out url_display_name, out url_logo_url, out url_filename);
            if (url_display_name != null && url_display_name.length > 0) {
                display_source = url_display_name;
            }
        }

        // If we still don't have a display_source, derive one from other sources
        if (display_source == null || display_source.length == 0) {
            // Local News should prefer a user-friendly local label (city)
            // when available so previews don't show unrelated provider names.
            if (category_id != null && category_id == "local_news") {
                if (prefs.user_location_city != null && prefs.user_location_city.length > 0)
                    display_source = prefs.user_location_city;
                else
                    display_source = "Local News";
            } else {
                // If inference fell back to the user's global default (e.g. the
                // user has set a single preferred source) but the article URL
                // is from an unknown host, prefer a host-derived friendly name
                // instead of always showing the global provider (avoids "The Guardian"
                // appearing for local or miscellaneous feeds).
                if (article_src == prefs.news_source) {
                    string host = UrlUtils.extract_host_from_url(url);
                    if (host != null && host.length > 0) {
                        // If the host clearly indicates a well-known provider (e.g. bbc,
                        // guardian, nytimes), prefer the canonical brand name rather
                        // than prettifying the host (which would turn "bbc" -> "Bbc").
                        string lowhost = host.down();
                        if (lowhost.index_of("bbc") >= 0 || lowhost.index_of("guardian") >= 0 || lowhost.index_of("nytimes") >= 0 || lowhost.index_of("wsj") >= 0 || lowhost.index_of("bloomberg") >= 0 || lowhost.index_of("reuters") >= 0 || lowhost.index_of("npr") >= 0 || lowhost.index_of("fox") >= 0) {
                            display_source = SourceUtils.get_source_name(article_src);
                        } else {
                            display_source = UrlUtils.prettify_host(host);
                        }
                    }
                }
                if (display_source == null) display_source = SourceUtils.get_source_name(article_src);
            }
        }

                // Debug trace the decision so we can inspect runtime behavior when
                // PAPERBOY_DEBUG is enabled. This helps explain cases where the
                // preview label is repainted unexpectedly.
                try {
            string? _dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
            if (_dbg != null && _dbg.length > 0) {
                try { AppDebugger.append_debug_log(debug_log_path, "show_article_preview: explicit_source=" + (explicit_source_name != null ? explicit_source_name : "(null)") +
                                 " inferred=" + SourceUtils.get_source_name(article_src) +
                                 " prefs_news_source=" + SourceUtils.get_source_name(prefs.news_source) +
                                 " category=" + (category_id != null ? category_id : "(null)") +
                                 " host=" + UrlUtils.extract_host_from_url(url) +
                                 " display_source=" + display_source); } catch (GLib.Error ee) { }
            }
        } catch (GLib.Error e) { }

                if (homepage_published_any != null && homepage_published_any.length > 0)
                    meta_label.set_text(display_source + " • " + DateUtils.format_published(homepage_published_any));
                else
                    meta_label.set_text(display_source);

        // Use homepage snippet for Fox News if available
    if (article_src == NewsSource.FOX) {
            // Try to get snippet from parent_window/article_buffer
            string? homepage_snippet = null;
            string? homepage_published = null;
            foreach (var item in parent_window.article_buffer) {
                if (item.url == url && item.get_type().name() == "Paperboy.NewsArticle") {
                    var na = (Paperboy.NewsArticle)item;
                    homepage_snippet = na.snippet;
                    homepage_published = na.published;
                    break;
                }
            }
            if (homepage_published != null && homepage_published.length > 0) {
                meta_label.set_text(SourceUtils.get_source_name(article_src) + " • " + DateUtils.format_published(homepage_published));
            } else {
                // show just source name
                meta_label.set_text(SourceUtils.get_source_name(article_src));
            }

            if (homepage_snippet != null && homepage_snippet.length > 0) {
                snippet_label.set_text(HtmlUtils.strip_html(homepage_snippet));
                return;
            }
        }
        // Otherwise, fetch snippet asynchronously
        // Pass the already-chosen friendly display_source into the snippet
        // fetcher so it doesn't overwrite our localized/host-derived label
        // with the (potentially incorrect) global provider name.
        fetch_snippet_async(url, (text) => {
            string to_show = text.length > 0 ? text : "No preview available. Open the article to read more.";
            snippet_label.set_text(to_show);
        }, meta_label, article_src, display_source);
        
    }

    // Load image using centralized ImageHandler if available
    private void load_image_async(Gtk.Picture image, string url, int target_w, int target_h, NewsSource source, string? category_id = null, bool source_is_mapped = true) {
        if (image_handler != null) {
            // Use centralized ImageHandler for consistency
            image_handler.load_image_async(image, url, target_w, target_h, true);
        } else {
            // Fallback: set placeholder directly
            if (category_id != null && category_id == "local_news") {
                parent_window.set_local_placeholder_image(image, target_w, target_h);
            } else if (!source_is_mapped) {
                // Use generic gradient placeholder for unknown/RSS sources
                PlaceholderBuilder.create_gradient_placeholder(image, target_w, target_h);
            } else {
                PlaceholderBuilder.set_placeholder_image_for_source(image, target_w, target_h, source);
            }
        }
    }



    // Fetch a short snippet from an article URL using common meta tags or first paragraph
    private void fetch_snippet_async(string url, SnippetCallback on_done, Gtk.Label? meta_label, NewsSource source, string? display_source) {
        new Thread<void*>("snippet-fetch", () => {
            string result = "";
            string published = "";
            try {
                var client = Paperboy.HttpClient.get_default();
                var options = new Paperboy.HttpClient.RequestOptions().with_browser_headers();
                var http_response = client.fetch_sync(url, options);

                if (http_response.is_success() && http_response.body != null && http_response.body.get_size() > 0) {
                    // Get response data from GLib.Bytes
                    unowned uint8[] body_data = http_response.body.get_data();

                    // Copy to a null-terminated buffer
                    uint8[] buf = new uint8[body_data.length + 1];
                    Memory.copy(buf, body_data, body_data.length);
                    buf[body_data.length] = 0;
                    string html = (string) buf;

                    // Use centralized HtmlUtils for snippet extraction
                    result = HtmlUtils.extract_snippet_from_html(html);

                    // Try to extract published date/time from common meta tags or <time>
                    try {
                        string lower = html.down();
                        int pos = 0;
                        while ((pos = lower.index_of("<meta", pos)) >= 0) {
                            int end = lower.index_of(">", pos);
                            if (end < 0) break;
                            string tag = html.substring(pos, end - pos + 1);
                            string tl = lower.substring(pos, end - pos + 1);
                            if (tl.index_of("datepublished") >= 0 || tl.index_of("article:published_time") >= 0 || tl.index_of("property=\"article:published_time\"") >= 0 || tl.index_of("name=\"pubdate\"") >= 0 || tl.index_of("itemprop=\"datePublished\"") >= 0) {
                                string content = HtmlUtils.extract_attr(tag, "content");
                                if (content != null && content.strip().length > 0) { published = content.strip(); break; }
                            }
                            pos = end + 1;
                        }
                        if (published.length == 0) {
                            // search for <time datetime="...">
                            int tpos = lower.index_of("<time");
                            if (tpos >= 0) {
                                int tend = lower.index_of(">", tpos);
                                if (tend > tpos) {
                                    string ttag = html.substring(tpos, tend - tpos + 1);
                                    string dt = HtmlUtils.extract_attr(ttag, "datetime");
                                    if (dt != null && dt.strip().length > 0) published = dt.strip();
                                    else {
                                        // fallback inner text
                                        int close = lower.index_of("</time>", tend);
                                        if (close > tend) {
                                            string inner = html.substring(tend + 1, close - (tend + 1));
                                            inner = HtmlUtils.strip_html(inner).strip();
                                            if (inner.length > 0) published = inner;
                                        }
                                    }
                                }
                            }
                        }
                    } catch (GLib.Error e) { /* ignore */ }
                }
            } catch (GLib.Error e) {
                // ignore, use empty result
            }
            string final = result;
            Idle.add(() => {
                // If we discovered a published time, set the meta label too.
                // Use the display_source chosen by the preview logic when
                // available so that the snippet fetcher doesn't overwrite a
                // more specific/local label (for example the user's city for
                // Local News) with the application's global source name.
                if (meta_label != null && published.length > 0) {
                    string label_to_use = (display_source != null && display_source.length > 0) ? display_source : SourceUtils.get_source_name(source);
                    try {
                        string? _dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                        if (_dbg != null && _dbg.length > 0) AppDebugger.append_debug_log(debug_log_path, "fetch_snippet_async: url=" + url + " published=" + published + " label=" + label_to_use);
                    } catch (GLib.Error e) { }
                    meta_label.set_text(label_to_use + " • " + DateUtils.format_published(published));
                }
                on_done(final);
                return false;
            });
            return null;
        });
    }

    // Helper: clamp integer between bounds
    private int clampi(int v, int min, int max) {
        if (v < min) return min;
        if (v > max) return max;
        return v;
    }

    // Generate a cache key for preview textures (url + requested size)
    private string make_preview_cache_key(string u, int w, int h) {
        return u + "@" + w.to_string() + "x" + h.to_string();
    }
}