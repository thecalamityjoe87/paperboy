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
using Tools;

public class ArticlePane : GLib.Object {
    private Adw.NavigationView nav_view;
    private NewsWindow parent_window;
    private ImageManager? image_manager;
    // Preview overlay components
    private Adw.OverlaySplitView? preview_split;
    private Gtk.Box? preview_content_box;
    // Store current article data for sharing
    private string? current_article_title = null;
    // Store current article menu to prevent garbage collection
    private ArticleMenu? current_article_menu = null;
    private static string debug_log_path = "/tmp/paperboy-debug.log";

    // Callback type for snippet results
    private delegate void SnippetCallback(string text);

    public ArticlePane(Adw.NavigationView navigation_view, NewsWindow window, ImageManager? img_handler = null) {
        nav_view = navigation_view;
        parent_window = window;
        image_manager = img_handler;
        // Initialize shared preview cache (centralized)
        PreviewCacheManager.get_cache();
    }
    
    // Set the preview overlay components (called after ArticleWindow construction)
    public void set_preview_overlay(Adw.OverlaySplitView split, Gtk.Box content_box) {
        preview_split = split;
        preview_content_box = content_box;
    }

    public void open_article_in_browser(string uri) {
        bool success = BrowserUtils.open_url_in_browser(uri);
        if (!success) {
            parent_window.show_toast("Failed to open link in browser");
        }
    }

    // Show a modal preview with image and a small snippet
    // `category_id` is optional; when it's "local_news" we prefer the
    // app-local placeholder so previews for Local News items match the
    // card/hero placeholders used in the main UI.
    public void show_article_preview(string title, string url, string? thumbnail_url, string? category_id = null, string? source_name = null) {
        // Store current article data for sharing
        current_article_title = title;

        // Notify parent window that a preview is opening so it can track
        // the active preview (used to mark viewed on return).
        parent_window.preview_opened(url);
        
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

        // Resolve the article source, whether it was mapped, and the published date
        NewsSource article_src;
        bool source_mapped;
        string? article_published;

        ArticleSourceResolver.resolve(
            source_name,
            url,
            parent_window.article_manager.article_buffer,
            out article_src,
            out source_mapped,
            out article_published
        );

        // Determine the article source name for display (fallback to source_name if not in buffer)
        string? article_source_name = source_name;

        if ((article_source_name == null || article_source_name.length == 0) && article_published != null) {
            // We found an ArticleItem in the buffer, so use its source_name
            foreach (var item in parent_window.article_manager.article_buffer) {
                if (item.url == url && item is ArticleItem) {
                    var ai = (ArticleItem) item;
                    article_source_name = ai.source_name;
                    break;
                }
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
        var ttl = new Gtk.Label(stripHtmlUtils.strip_html(title));
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
        // Delegate preview image work to ImageManager when available so the
        // pane focuses on layout only.
        if (image_manager != null) {
            image_manager.load_preview_image(pic, thumbnail_url, img_w, img_h, article_src, category_id, source_mapped);
        } else {
            // Fallback: keep previous inline behavior when no ImageManager
            bool will_load_image = thumbnail_url != null && thumbnail_url.length > 0 && (thumbnail_url.has_prefix("http://") || thumbnail_url.has_prefix("https://"));
            if (!will_load_image) {
                if (category_id != null && category_id == "local_news") {
                    parent_window.set_local_placeholder_image(pic, img_w, img_h);
                } else if (!source_mapped) {
                    PlaceholderBuilder.create_gradient_placeholder(pic, img_w, img_h);
                } else {
                    PlaceholderBuilder.set_placeholder_image_for_source(pic, img_w, img_h, article_src);
                }
            } else {
                int multiplier = (article_src == NewsSource.REDDIT) ? 2 : 3;
                int target_w = img_w * multiplier;
                int target_h = img_h * multiplier;
                bool loaded_from_cache = false;
                string key = ImageManager.make_preview_cache_key(thumbnail_url, target_w, target_h);
                var texture = PreviewCacheManager.get_cache().get_texture(key);
                if (texture != null) {
                    pic.set_paintable(texture);
                    loaded_from_cache = true;
                }
                if (!loaded_from_cache) load_image_async(pic, thumbnail_url, target_w, target_h, article_src, category_id, source_mapped);
            }
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
            parent_window.preview_closed(url);
        });

        // Check if article is already saved and if it's viewed to show correct menu state
        bool is_saved = false;
        bool is_viewed = false;
        // Narrow norm_url scope to where it's used
        if (parent_window.article_state_store != null) {
            string norm_url = url;
            if (parent_window != null) norm_url = parent_window.normalize_article_url(url);
            is_saved = parent_window.article_state_store.is_saved(norm_url);
            is_viewed = parent_window.article_state_store.is_viewed(norm_url);
        }

        // Create article menu using ArticleMenu class
        current_article_menu = new ArticleMenu(url, article_source_name, is_saved, is_viewed, parent_window);
        
        // Connect to menu signals
        current_article_menu.open_in_app_requested.connect((article_url) => {
            string normalized = parent_window.normalize_article_url(article_url);
            if (parent_window.article_sheet != null) parent_window.article_sheet.open(normalized);
            if (preview_split != null) preview_split.set_show_sidebar(false);
        });
        
        current_article_menu.open_in_browser_requested.connect((article_url) => {
            open_article_in_browser(article_url);
        });
        
        current_article_menu.follow_source_requested.connect((article_url, source_name) => {
            parent_window.show_persistent_toast("Searching for feed...");
            parent_window.source_manager.follow_rss_source(article_url, source_name);
        });
        
        current_article_menu.save_for_later_requested.connect((article_url) => {
            if (parent_window.article_state_store != null) {
                bool article_is_saved = parent_window.article_state_store.is_saved(article_url);
                if (article_is_saved) {
                    parent_window.article_state_store.unsave_article(article_url);
                    parent_window.show_toast("Removed article from saved");
                    if (parent_window.prefs.category == "saved") {
                        parent_window.fetch_news();
                        if (preview_split != null) preview_split.set_show_sidebar(false);
                    }
                } else {
                    parent_window.article_state_store.save_article(article_url, title, thumbnail_url, article_source_name);
                    parent_window.show_toast("Added article to saved");
                }
            }
        });
        
        current_article_menu.share_requested.connect((article_url) => {
            show_share_dialog(article_url);
        });

        current_article_menu.mark_unread_requested.connect((article_url) => {
            string nurl = article_url;
            if (parent_window != null) nurl = parent_window.normalize_article_url(article_url);
            if (parent_window.article_state_store != null) parent_window.article_state_store.mark_unviewed(nurl);
            // Prevent preview_closed from re-marking this article as viewed
            if (parent_window != null && parent_window.view_state != null) parent_window.view_state.suppress_mark_on_preview_close(nurl);
            // Remove from in-memory viewed set so UI updates immediately
            if (parent_window != null && parent_window.view_state != null) parent_window.view_state.viewed_articles.remove(nurl);
            // Badge update is handled via ArticleStateStore.viewed_status_changed signal
            if (parent_window != null && parent_window.view_state != null && article_source_name != null)
                parent_window.view_state.refresh_viewed_badges_for_source(article_source_name);
            if (parent_window != null && parent_window.view_state != null)
                parent_window.view_state.refresh_viewed_badge_for_url(nurl);
        });
        
        // Create the popover and menu box
        var menu_popover = new Gtk.Popover();
        var menu_box = current_article_menu.create_menu_box(menu_popover);
        menu_popover.set_child(menu_box);

        var open_menu_btn = new Gtk.MenuButton();
        var menu_content = new Adw.ButtonContent();
        menu_content.set_icon_name("view-more-symbolic");
        menu_content.set_label("Article options");
        open_menu_btn.set_child(menu_content);
        open_menu_btn.set_popover(menu_popover);
        open_menu_btn.set_hexpand(true);
        open_menu_btn.add_css_class("suggested-action");
        open_menu_btn.set_tooltip_text("Article view and source options");

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
            clear_selection(ttl);
            return false;
        });
        // Try to set metadata from any cached article entry (source + published time)
        var prefs = NewsPreferences.get_instance();
        string? homepage_published_any = article_published;
        string? explicit_source_name = article_source_name;
        
        // Sanitize per-item source name and extract any cached published date
        ArticleSnippetService.sanitize_source_and_lookup_published(
            url,
            explicit_source_name,
            parent_window.article_manager.article_buffer,
            out explicit_source_name,
            out homepage_published_any
        );
        // Resolve a user-friendly display name using the central helper
        string display_source = ArticleSnippetService.resolve_display_source(
            url,
            article_src,
            explicit_source_name,
            homepage_published_any,
            category_id,
            prefs,
            parent_window.article_manager.article_buffer
        );

        if (homepage_published_any != null && homepage_published_any.length > 0) {
            meta_label.set_text(display_source + " • " + DateUtils.format_published(homepage_published_any));
        } else {
            meta_label.set_text(display_source);
        }

        // Fetch snippet asynchronously. ArticlePreviewService will consult any
        // provided article buffer (cached feed entries) for quick results.
        ArticleSnippetService.fetch_snippet_async(url, (preview) => {
            // Ensure the preview UI is still present before mutating widgets
            if (snippet_label.get_parent() == null) return;

            string to_show = preview.snippet.length > 0 ? preview.snippet : "No preview available. Open the article to read more.";
            snippet_label.set_text(to_show);

            if (meta_label != null && preview.published != null && preview.published.length > 0) {
                string label_to_use = (display_source != null && display_source.length > 0) ? display_source : SourceUtils.get_source_name(article_src);
                meta_label.set_text(label_to_use + " • " + DateUtils.format_published(preview.published));
            }
        }, article_src, display_source, parent_window.article_manager.article_buffer);
        
    }

    // Load image using centralized ImageManager if available
    private void load_image_async(Gtk.Picture image, string url, int target_w, int target_h, NewsSource source, string? category_id = null, bool source_is_mapped = true) {
        if (image_manager != null) {
            // Use centralized ImageManager for consistency
            image_manager.load_image_async(image, url, target_w, target_h, true);
        } else {
            // Delegate placeholder selection to the centralized helper so logic
            // remains consistent with ImageManager behavior.
            ImageManager.set_preview_placeholder(image, target_w, target_h, source, category_id, source_is_mapped, parent_window);
        }
    }

    // Clear selection helper for labels so the Idle callback is clearer
    private void clear_selection(Gtk.Label? label) {
        if (label != null) {
            label.select_region(0, 0);
        }
    }

    // Helper: clamp integer between bounds
    private int clampi(int v, int min, int max) {
        if (v < min) return min;
        if (v > max) return max;
        return v;
    }

    // Show share dialog for article URL
    public void show_share_dialog(string article_url) {
        ShareDialog.show(article_url, current_article_title, parent_window);
    }
}