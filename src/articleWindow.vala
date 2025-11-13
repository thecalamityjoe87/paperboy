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
using Tools;

public class ArticleWindow : GLib.Object {
    private Adw.NavigationView nav_view;
    private Gtk.Button back_btn;
    private Soup.Session session;
    private NewsWindow parent_window;
    // In-memory cache for article preview textures (url@WxH -> Gdk.Texture).
    // Kept local to ArticleWindow to avoid touching NewsWindow's private cache.
    private static Gee.HashMap<string, Gdk.Texture>? preview_cache = null;
    // Track a per-preview handler so we can attach a one-shot click
    // listener to the shared header back button and disconnect it when
    // the preview is closed. This avoids leaving stale handlers that
    // would incorrectly mark unrelated previews as viewed.
    private ulong back_btn_handler_id = 0;

    // Callback type for snippet results
    private delegate void SnippetCallback(string text);

    public ArticleWindow(Adw.NavigationView navigation_view, Gtk.Button back_button, Soup.Session soup_session, NewsWindow window) {
        nav_view = navigation_view;
        back_btn = back_button;
        session = soup_session;
        parent_window = window;
        // Initialize preview cache on first construction
        if (preview_cache == null) preview_cache = new Gee.HashMap<string, Gdk.Texture>();
    }

    // Local debug logger: write lightweight traces to /tmp/paperboy-debug.log
    // This mirrors the debug helper in NewsWindow but is kept private so
    // the ArticleWindow can emit logs without accessing NewsWindow's private
    // members.
    private void append_debug_log(string line) {
        try {
            string path = "/tmp/paperboy-debug.log";
            string old = "";
            try { GLib.FileUtils.get_contents(path, out old); } catch (GLib.Error e) { old = ""; }
            string outc = old + line + "\n";
            GLib.FileUtils.set_contents(path, outc);
        } catch (GLib.Error e) {
            // best-effort logging only
        }
    }

    // Show a modal preview with image and a small snippet
    // `category_id` is optional; when it's "local_news" we prefer the
    // app-local placeholder so previews for Local News items match the
    // card/hero placeholders used in the main UI.
    public void show_article_preview(string title, string url, string? thumbnail_url, string? category_id = null) {
        // Notify parent window that a preview is opening so it can track
        // the active preview (used to mark viewed on return).
        try { parent_window.preview_opened(url); } catch (GLib.Error e) { }
        // Build a scrolling preview page with a max height constraint
        var outer = new Gtk.Box(Orientation.VERTICAL, 0);

        // Set a maximum height for the preview content (e.g., 700px)
        const int MAX_PREVIEW_HEIGHT = 700;
        outer.set_vexpand(false);
        outer.set_hexpand(true);
        outer.set_size_request(-1, MAX_PREVIEW_HEIGHT);

        // Title label
        var title_wrap = new Gtk.Box(Orientation.VERTICAL, 8);
        title_wrap.set_margin_start(16);
        title_wrap.set_margin_end(16);
        title_wrap.set_margin_top(16);
        title_wrap.set_halign(Gtk.Align.FILL);
        title_wrap.set_hexpand(true);
        // Decode any HTML entities that may be present in scraped titles
        var ttl = new Gtk.Label(HtmlUtils.strip_html(title));
        ttl.add_css_class("title-2");
        ttl.set_xalign(0);
        ttl.set_wrap(true);
        ttl.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        ttl.set_lines(4);
        ttl.set_selectable(true);
        ttl.set_justify(Gtk.Justification.LEFT);
        title_wrap.append(ttl);

        // Metadata label (source + published date/time)
        var meta_label = new Gtk.Label("");
        meta_label.set_xalign(0);
        meta_label.set_selectable(false);
        meta_label.add_css_class("caption");
        meta_label.set_halign(Gtk.Align.START);
        meta_label.set_wrap(false);
        meta_label.set_margin_top(4);
        title_wrap.append(meta_label);
        outer.append(title_wrap);

    // Infer source for this article so previews show correct branding when
    // multiple preferred sources are enabled.
    NewsSource article_src = infer_source_from_url(url);

    // Image (constrained)
        int img_w = estimate_content_width();
        int img_h = clampi((int)(img_w * 9.0 / 16.0), 240, 420);
        var pic_box = new Gtk.Box(Orientation.VERTICAL, 0);
        pic_box.set_vexpand(false);
        pic_box.set_hexpand(true);
        pic_box.set_size_request(-1, img_h);
        var pic = new Gtk.Picture();
        pic.set_halign(Gtk.Align.FILL);
        pic.set_hexpand(true);
        pic.set_size_request(-1, img_h);
        pic.set_content_fit(Gtk.ContentFit.COVER);
        pic.set_can_shrink(true);
        pic.set_margin_start(16);
        pic.set_margin_end(16);
        pic.set_margin_top(8);
        pic.set_margin_bottom(8);
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
                    set_placeholder_image_for_source(pic, img_w, img_h, article_src);
                }
            } else {
                // Use an article-specific placeholder (so the preview shows the correct
                // source branding even when the user's global prefs include multiple
                // sources).
                set_placeholder_image_for_source(pic, img_w, img_h, article_src);
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
                if (preview_cache != null) {
                    var cached = preview_cache.get(key);
                    if (cached != null) {
                        try { pic.set_paintable(cached); } catch (GLib.Error e) { }
                        loaded_from_cache = true;
                    }
                }
            } catch (GLib.Error e) { /* ignore cache errors and continue to load */ }
            if (!loaded_from_cache) load_image_async(pic, thumbnail_url, target_w, target_h);
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
        snippet_label.set_justify(Gtk.Justification.LEFT);
        pad.append(snippet_label);

    
        outer.append(pad);

        // Buttons row
        var actions = new Gtk.Box(Orientation.HORIZONTAL, 8);
        actions.set_margin_start(16);
        actions.set_margin_end(16);
        actions.set_margin_bottom(24);
        actions.set_halign(Gtk.Align.END);
        var open_btn = new Gtk.Button.with_label("Open in browser");
        open_btn.add_css_class("suggested-action");
        open_btn.clicked.connect(() => { try { AppInfo.launch_default_for_uri(url, null); } catch (GLib.Error e) { } });
        var back_local = new Gtk.Button.with_label("Back");
        back_local.clicked.connect(() => {
            if (nav_view != null) nav_view.pop();
            back_btn.set_visible(false);
            // Notify parent that the preview closed so it can mark the
            // article as viewed now that the user returned to the main view.
            try { parent_window.preview_closed(url); } catch (GLib.Error e) { }
        });
        actions.append(back_local);
        actions.append(open_btn);
        outer.append(actions);

        // Put content into a scrolled window for overflow
        var sc = new Gtk.ScrolledWindow();
        sc.set_vexpand(true);
        sc.set_hexpand(true);
        sc.set_child(outer);

        var page = new Adw.NavigationPage(sc, "Article");
        nav_view.push(page);
        back_btn.set_visible(true);
        // Attach a one-shot handler to the shared header back button so
        // clicks on that arrow also notify the parent preview-closed
        // lifecycle. We disconnect the handler after it runs to avoid
        // duplicate or stale callbacks.
        try {
            if (back_btn_handler_id != 0) {
                try { back_btn.disconnect(back_btn_handler_id); } catch (GLib.Error e) { }
                back_btn_handler_id = 0;
            }
            back_btn_handler_id = back_btn.clicked.connect(() => {
                if (nav_view != null) nav_view.pop();
                back_btn.set_visible(false);
                try { parent_window.preview_closed(url); } catch (GLib.Error e) { }
                // Disconnect this handler (one-shot)
                try { back_btn.disconnect(back_btn_handler_id); } catch (GLib.Error e) { }
                back_btn_handler_id = 0;
            });
        } catch (GLib.Error e) { }
        // Try to set metadata from any cached article entry (source + published time)
    var prefs = NewsPreferences.get_instance();
        string? homepage_published_any = null;
        string? explicit_source_name = null;
        foreach (var item in parent_window.article_buffer) {
            if (item.url == url) {
                // Prefer explicit per-item source name when available (ArticleItem)
                try {
                    if (item is ArticleItem) {
                        var ai = (ArticleItem) item;
                        explicit_source_name = ai.source_name;
                    } else if (item.get_type().name() == "Paperboy.NewsArticle") {
                        var na = (Paperboy.NewsArticle)item;
                        homepage_published_any = na.published;
                    }
                } catch (GLib.Error e) { }
                // Continue searching to prefer a Paperboy.NewsArticle published time if present
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
                    string host = extract_host_from_url(url);
                    if (host != null && host.length > 0) {
                        // If the host clearly indicates a well-known provider (e.g. bbc,
                        // guardian, nytimes), prefer the canonical brand name rather
                        // than prettifying the host (which would turn "bbc" -> "Bbc").
                        string lowhost = host.down();
                        if (lowhost.index_of("bbc") >= 0 || lowhost.index_of("guardian") >= 0 || lowhost.index_of("nytimes") >= 0 || lowhost.index_of("wsj") >= 0 || lowhost.index_of("bloomberg") >= 0 || lowhost.index_of("reuters") >= 0 || lowhost.index_of("npr") >= 0 || lowhost.index_of("fox") >= 0) {
                            display_source = get_source_name(article_src);
                        } else {
                            display_source = prettify_host(host);
                        }
                    }
                }
                if (display_source == null) display_source = get_source_name(article_src);
            }
        }

                // Debug trace the decision so we can inspect runtime behavior when
                // PAPERBOY_DEBUG is enabled. This helps explain cases where the
                // preview label is repainted unexpectedly.
                try {
            string? _dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
            if (_dbg != null && _dbg.length > 0) {
                try { append_debug_log("show_article_preview: explicit_source=" + (explicit_source_name != null ? explicit_source_name : "(null)") +
                                 " inferred=" + get_source_name(article_src) +
                                 " prefs_news_source=" + get_source_name(prefs.news_source) +
                                 " category=" + (category_id != null ? category_id : "(null)") +
                                 " host=" + extract_host_from_url(url) +
                                 " display_source=" + display_source); } catch (GLib.Error ee) { }
            }
        } catch (GLib.Error e) { }

                if (homepage_published_any != null && homepage_published_any.length > 0)
                    meta_label.set_text(display_source + " • " + format_published(homepage_published_any));
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
                meta_label.set_text(get_source_name(article_src) + " • " + format_published(homepage_published));
            } else {
                // show just source name
                meta_label.set_text(get_source_name(article_src));
            }

            if (homepage_snippet != null && homepage_snippet.length > 0) {
                snippet_label.set_text(homepage_snippet);
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

    private void load_image_async(Gtk.Picture image, string url, int target_w, int target_h) {
        // Helper for preview cache keys
        string make_preview_cache_key(string u, int w, int h) {
            return u + "@" + w.to_string() + "x" + h.to_string();
        }

        new Thread<void*>("load-image", () => {
            try {
                // download initiated
                var msg = new Soup.Message("GET", url);
                
                // Optimize headers based on source
                var prefs_instance = NewsPreferences.get_instance();
                if (prefs_instance.news_source == NewsSource.REDDIT) {
                    msg.request_headers.append("User-Agent", "Mozilla/5.0 (compatible; Paperboy/1.0)");
                    // Reddit-specific optimizations
                    msg.request_headers.append("Accept", "image/jpeg,image/png,image/webp,image/*;q=0.8");
                    msg.request_headers.append("Cache-Control", "max-age=3600");
                } else {
                    msg.request_headers.append("User-Agent", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36");
                    msg.request_headers.append("Accept", "image/webp,image/png,image/jpeg,image/*;q=0.8");
                }
                msg.request_headers.append("Accept-Encoding", "gzip, deflate, br");
                
                session.send_message(msg);
                
                // status received
                
                // Skip extremely large images to prevent slowdowns (especially for Reddit)
                if (prefs_instance.news_source == NewsSource.REDDIT && msg.response_body.length > 2 * 1024 * 1024) {
                    print("Skipping large Reddit image (%ld bytes), using placeholder\n", (long)msg.response_body.length);
                    Idle.add(() => {
                        set_placeholder_image(image, target_w, target_h);
                        return false;
                    });
                    return null;
                }
                
                if (msg.status_code == 200 && msg.response_body.length > 0) {
                    // Create a loader that can auto-detect format
                    Idle.add(() => {
                        try {
                            // creating pixbuf loader
                            var loader = new Gdk.PixbufLoader();
                            
                            // Write data to loader
                            uint8[] data = new uint8[msg.response_body.length];
                            Memory.copy(data, msg.response_body.data, (size_t)msg.response_body.length);
                            loader.write(data);
                            loader.close();
                            
                            var pixbuf = loader.get_pixbuf();
                            // pixbuf loaded check
                            
                            if (pixbuf != null) {
                                // Avoid expensive, high-quality downscaling on the main
                                // thread which causes jank when opening previews. Instead:
                                //  - Prefer to set the decoded pixbuf directly as a texture
                                //    so the GPU can handle scaling where possible (fast).
                                //  - Only perform a conservative BILINEAR downscale when the
                                //    decoded image is extremely larger than the target area to
                                //    avoid huge textures and excessive memory use.
                                int device_scale = 1;
                                try {
                                    device_scale = image.get_scale_factor();
                                    if (device_scale < 1) device_scale = 1;
                                } catch (GLib.Error e) { device_scale = 1; }

                                int eff_target_w = target_w * device_scale;
                                int eff_target_h = target_h * device_scale;

                                int width = pixbuf.get_width();
                                int height = pixbuf.get_height();

                                // If the image is massively larger than the effective target
                                // (e.g., more than 3× in either dimension), downscale to a
                                // reasonable cap using the faster BILINEAR interpolation.
                                // This reduces memory and keeps the preview responsive.
                                if ((width > eff_target_w * 3) || (height > eff_target_h * 3)) {
                                    double scale = double.min((double)(eff_target_w * 2) / width,
                                                              (double)(eff_target_h * 2) / height);
                                    if (scale <= 0) scale = 1.0;
                                    int new_width = (int)(width * scale);
                                    if (new_width < 1) new_width = 1;
                                    int new_height = (int)(height * scale);
                                    if (new_height < 1) new_height = 1;
                                    // Use BILINEAR here for speed (trade a tiny amount of quality)
                                    pixbuf = pixbuf.scale_simple(new_width, new_height, Gdk.InterpType.BILINEAR);
                                    try { append_debug_log("article preview: fast downscale to " + new_width.to_string() + "x" + new_height.to_string()); } catch (GLib.Error e) { }
                                }

                                // Create a texture directly from the (possibly resized) pixbuf
                                // and hand it to the Gtk.Picture. Creating the texture is
                                // relatively cheap compared to full HYPER resampling on the
                                // main thread and yields a crisp result when the source image
                                // has sufficient resolution.
                                var texture = Gdk.Texture.for_pixbuf(pixbuf);
                                image.set_paintable(texture);
                                // Cache the texture for faster future preview opens.
                                try {
                                    string key = make_preview_cache_key(url, target_w, target_h);
                                    if (preview_cache == null) preview_cache = new Gee.HashMap<string, Gdk.Texture>();
                                    preview_cache.set(key, texture);
                                } catch (GLib.Error e) { /* best-effort cache */ }
                            } else {
                                // pixbuf null -> use placeholder
                                set_placeholder_image(image, target_w, target_h);
                            }
                        } catch (GLib.Error e) {
                            // error loading image
                            set_placeholder_image(image, target_w, target_h);
                        }
                        return false;
                    });
                } else {
                    // HTTP error or empty body
                    Idle.add(() => {
                        set_placeholder_image(image, target_w, target_h);
                        return false;
                    });
                }
            } catch (GLib.Error e) {
                // download error
                Idle.add(() => {
                    set_placeholder_image(image, target_w, target_h);
                    return false;
                });
            }
            return null;
        });
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

        // Infer source from a URL by checking known domain substrings. Falls back
        // to the current prefs.news_source when uncertain. This mirrors the
        // helper in appWindow so ArticleWindow can decide branding independently.
        private NewsSource infer_source_from_url(string? url) {
            var prefs = NewsPreferences.get_instance();
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

    // Extract host portion from a URL (e.g., "https://www.example.com/path" -> "example.com").
        private string extract_host_from_url(string? url) {
            if (url == null) return "";
            string u = url.strip();
            if (u.length == 0) return "";
            // Strip scheme
            int scheme_end = u.index_of("://");
            if (scheme_end >= 0) u = u.substring(scheme_end + 3);
            // Cut at first slash
        int slash = u.index_of("/");
            if (slash >= 0) u = u.substring(0, slash);
            // Remove port if present
        int colon = u.index_of(":");
            if (colon >= 0) u = u.substring(0, colon);
            u = u.down();
            // Strip common www prefix
            if (u.has_prefix("www.")) u = u.substring(4);
            return u;
        }

        // Turn a host like "example-news.co.uk" into a friendly display string
        // such as "Example News". This is intentionally simple and is only
        // used as a fallback when no explicit source name is available.
    private string prettify_host(string host) {
            if (host == null) return "News";
            string h = host.strip();
            if (h.length == 0) return "News";
            // Take left-most label as the short name (e.g., "example-news")
            int dot = h.index_of(".");
            if (dot >= 0) h = h.substring(0, dot);
            // Replace hyphens/underscores with spaces and split into words
            h = h.replace("-", " ");
            h = h.replace("_", " ");
            // Capitalize words (ASCII-safe simple capitalization)
            string out = "";
            string[] parts = h.split(" ");
            foreach (var p in parts) {
                if (p.length == 0) continue;
                string w = ascii_capitalize(p);
                out += (out.length > 0 ? " " : "") + w;
            }
            // Handle common host-name quirks and a couple of branded exceptions
            // e.g. "theguardian" -> "The Guardian", "nytimes" -> "NY Times"
            string lower_out = out.down();
            if (lower_out.has_prefix("the") && lower_out.length > 3 && lower_out.index_of(" ") < 0) {
                // Split off the leading "the" into a separate word
                string rest = lower_out.substring(3);
                if (rest.length > 0) {
                    // Capitalize the remainder nicely and return
                    return "The " + ascii_capitalize(rest);
                }
            }
            // Small exceptions map for well-known sites that are commonly
            // concatenated in hosts.
            if (lower_out == "nytimes" || lower_out == "ny time") return "NY Times";
            if (lower_out == "wsj" || lower_out == "wallstreetjournal" || lower_out == "wallstreet") return "Wall Street Journal";
            if (out.length == 0) return "News";
            return out;
        }

    // Simple ASCII capitalization helper: first char upper, remainder lower.
    private string ascii_capitalize(string s) {
        if (s == null) return "";
        if (s.length == 0) return s;
        char c = s[0];
        char up = c;
        if (c >= 'a' && c <= 'z') up = (char)(c - 32);
        string first = "%c".printf(up);
        string rest = s.length > 1 ? s.substring(1).down() : "";
        return first + rest;
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
        
        // Try to find icon in data directory using the same method as main window
        string[] prefixes = {
            "/home/dev/paperboy/data/",
            "./data/",
            "../data/",
            "/usr/share/paperboy/"
        };
        
        foreach (string prefix in prefixes) {
            string full_path = prefix + "icons/" + icon_filename;
            if (FileUtils.test(full_path, FileTest.EXISTS)) {
                return full_path;
            }
        }
        
        return null;
    }

    private void create_icon_placeholder(Gtk.Picture image, string icon_path, NewsSource source, int width, int height) {
        try {
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, width, height);
            var cr = new Cairo.Context(surface);

            // Create gradient background matching source brand colors
            var gradient = new Cairo.Pattern.linear(0, 0, 0, height);
            
            switch (source) {
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
            string source_name = get_source_name(source);
            create_source_text_placeholder(image, source_name, source, width, height);
        }
    }

    private void create_source_text_placeholder(Gtk.Picture image, string source_name, NewsSource source, int width, int height) {
        try {
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, width, height);
            var cr = new Cairo.Context(surface);

            // Create gradient background based on source
            var gradient = new Cairo.Pattern.linear(0, 0, 0, height);
            
            // Use different colors for different sources
            switch (source) {
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

    // Variant of set_placeholder_image that honors an explicit NewsSource. This
    // lets previews and other per-article UI show the correct branding even
    // when the user's preferences are set to "multiple sources".
    private void set_placeholder_image_for_source(Gtk.Picture image, int width, int height, NewsSource source) {
        string? icon_path = get_source_icon_path(source);
        string source_name = get_source_name(source);
        if (icon_path != null) {
            create_icon_placeholder(image, icon_path, source, width, height);
        } else {
            create_source_text_placeholder(image, source_name, source, width, height);
        }
    }

    private void set_placeholder_image(Gtk.Picture image, int width, int height) {
        // Get source icon and create branded placeholder
        var prefs = NewsPreferences.get_instance();
        string? icon_path = get_source_icon_path(prefs.news_source);
        string source_name = get_source_name(prefs.news_source);
        if (icon_path != null) {
            create_icon_placeholder(image, icon_path, prefs.news_source, width, height);
        } else {
            // Fallback to text-based placeholder
            create_source_text_placeholder(image, source_name, prefs.news_source, width, height);
        }
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

    // Fetch a short snippet from an article URL using common meta tags or first paragraph
    private void fetch_snippet_async(string url, SnippetCallback on_done, Gtk.Label? meta_label, NewsSource source, string? display_source) {
        new Thread<void*>("snippet-fetch", () => {
            string result = "";
            string published = "";
            try {
                var msg = new Soup.Message("GET", url);
                msg.request_headers.append("User-Agent", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36");
                session.send_message(msg);
                if (msg.status_code == 200 && msg.response_body.length > 0) {
                    // Copy to a null-terminated buffer
                    uint8[] buf = new uint8[msg.response_body.length + 1];
                    Memory.copy(buf, msg.response_body.data, (size_t) msg.response_body.length);
                    buf[msg.response_body.length] = 0;
                    string html = (string) buf;
                    result = extract_snippet_from_html(html);
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
                                string content = extract_attr(tag, "content");
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
                                    string dt = extract_attr(ttag, "datetime");
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
                    string label_to_use = (display_source != null && display_source.length > 0) ? display_source : get_source_name(source);
                    try {
                        string? _dbg = GLib.Environment.get_variable("PAPERBOY_DEBUG");
                        if (_dbg != null && _dbg.length > 0) append_debug_log("fetch_snippet_async: url=" + url + " published=" + published + " label=" + label_to_use);
                    } catch (GLib.Error e) { }
                    meta_label.set_text(label_to_use + " • " + format_published(published));
                }
                on_done(final);
                return false;
            });
            return null;
        });
    }

    private string extract_attr(string tag, string attr) {
        // naive attribute extractor attr="..."
        int ai = tag.index_of(attr + "=");
        if (ai < 0) return "";
        ai += attr.length + 1;
        if (ai >= tag.length) return "";
        char quote = tag[ai];
        if (quote != '"' && quote != '\'') return "";
        int start = ai + 1;
        int end = tag.index_of_char(quote, start);
        if (end <= start) return "";
        return tag.substring(start, end - start);
    }

    private string extract_snippet_from_html(string html) {
        string lower = html.down();
        // Try OpenGraph description
        int pos = 0;
        while ((pos = lower.index_of("<meta", pos)) >= 0) {
            int end = lower.index_of(">", pos);
            if (end < 0) break;
            string tag = html.substring(pos, end - pos + 1);
            string tl = lower.substring(pos, end - pos + 1);
            bool matches = tl.index_of("property=\"og:description\"") >= 0 ||
                           tl.index_of("name=\"description\"") >= 0 ||
                           tl.index_of("name=\"twitter:description\"") >= 0;
            if (matches) {
                string content = extract_attr(tag, "content");
                    if (content != null && content.strip().length > 0) {
                    return truncate_snippet(HtmlUtils.strip_html(content), 280);
                }
            }
            pos = end + 1;
        }

        // Fallback: first paragraph
        int p1 = lower.index_of("<p");
        if (p1 >= 0) {
            int p1end = lower.index_of(">", p1);
            if (p1end > p1) {
                int p2 = lower.index_of("</p>", p1end);
                    if (p2 > p1end) {
                    string inner = html.substring(p1end + 1, p2 - (p1end + 1));
                    return truncate_snippet(HtmlUtils.strip_html(inner), 280);
                }
            }
        }
        return "";
    }

    private string truncate_snippet(string s, int maxlen) {
        if (s.length <= maxlen) return s;
        return s.substring(0, maxlen - 1) + "…";
    }

    // Convert raw published strings into a short, friendly representation.
    // Examples:
    //  - "2025-11-07T02:38:00.000Z" -> "Nov 7 • 02:38"
    //  - "02:38:00.000" -> "02:38"
    private string format_published(string raw) {
        if (raw == null) return "";
        string s = raw.strip();
        if (s.length == 0) return "";

        // If ISO-style date/time (contains 'T'), split into date/time
        string date_part = "";
        string time_part = s;
        int tpos = s.index_of("T");
        if (tpos >= 0) {
            date_part = s.substring(0, tpos);
            time_part = s.substring(tpos + 1);
        }

        // Trim timezone designators from time_part (Z or +hh:mm or -hh:mm)
        int tzpos = time_part.index_of("Z");
        if (tzpos < 0) tzpos = time_part.index_of("+");
        if (tzpos < 0) tzpos = time_part.index_of("-");
        if (tzpos >= 0) time_part = time_part.substring(0, tzpos);

        // Extract HH:MM using regex
        var tm_re = new Regex("([0-2][0-9]):([0-5][0-9])", RegexCompileFlags.DEFAULT);
        MatchInfo tm_info;
        if (tm_re.match(time_part, 0, out tm_info)) {
            string hh = tm_info.fetch(1);
            string mm = tm_info.fetch(2);
            string hhmm = "%s:%s".printf(hh, mm);

            if (date_part.length >= 8) {
                // Try to parse YYYY-MM-DD
                var d_re = new Regex("^(\\d{4})-(\\d{2})-(\\d{2})", RegexCompileFlags.DEFAULT);
                MatchInfo d_info;
                if (d_re.match(date_part, 0, out d_info)) {
                    string year = d_info.fetch(1);
                    string mo = d_info.fetch(2);
                    string day = d_info.fetch(3);
                    string mon_name = "";
                    // Map month number to short name
                    if (mo == "01") mon_name = "Jan";
                    else if (mo == "02") mon_name = "Feb";
                    else if (mo == "03") mon_name = "Mar";
                    else if (mo == "04") mon_name = "Apr";
                    else if (mo == "05") mon_name = "May";
                    else if (mo == "06") mon_name = "Jun";
                    else if (mo == "07") mon_name = "Jul";
                    else if (mo == "08") mon_name = "Aug";
                    else if (mo == "09") mon_name = "Sep";
                    else if (mo == "10") mon_name = "Oct";
                    else if (mo == "11") mon_name = "Nov";
                    else if (mo == "12") mon_name = "Dec";
                    // Trim leading zero from day for nicer display
                    if (day.has_prefix("0")) day = day.substring(1);
                    // Include year in the display per UX request
                    return "%s %s, %s • %s".printf(mon_name, day, year, hhmm);
                }
            }

            // Fallback: just return HH:MM
            return hhmm;
        }

        // No time matched — strip milliseconds/extra and return trimmed
        int dot = s.index_of(".");
        if (dot >= 0) s = s.substring(0, dot);
        if (s.has_suffix("Z")) s = s.substring(0, s.length - 1);
        return s;
    }

    // Helper: clamp integer between bounds
    private int clampi(int v, int min, int max) {
        if (v < min) return min;
        if (v > max) return max;
        return v;
    }

    // Estimate the content width inside margins
    private int estimate_content_width() {
        int w = parent_window.get_width();
        if (w <= 0) w = 1280; // fall back to a reasonable default
        // Use the same margins as the main window
        const int H_MARGIN = 12;
        return clampi(w - (H_MARGIN * 2), 600, 4096);
    }

    // Generate a cache key for preview textures (url + requested size)
    private string make_preview_cache_key(string u, int w, int h) {
        return u + "@" + w.to_string() + "x" + h.to_string();
    }
}