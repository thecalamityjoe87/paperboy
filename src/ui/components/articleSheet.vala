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
using WebKit;
using Gdk;

public class ArticleSheet : GLib.Object {
    private NewsWindow parent_window;
    private Gtk.Box container;
    private Gtk.Revealer revealer;
    private Gtk.Box content_box;
    private Gtk.Button? close_btn;
    private Gtk.Button? back_btn;
    private Gtk.Button? forward_btn;
    private Gtk.Button? refresh_btn;
    private Gtk.ToggleButton? reader_toggle_btn;
    private Gtk.Stack? view_stack;
    private ReaderView? reader_view;
    private string? reader_loaded_url = null;
    private string? current_source_name_encoded = null;
    private WebKit.WebView? webview;
    private string adblock_css = "";
    private string? current_url = null;
    private string? current_comments_url = null;

    private Adw.OverlaySplitView? comments_split;
    private Gtk.ToggleButton? comments_toggle_btn;
    private Gtk.Stack? comments_stack;
    private Gtk.Box? comments_list_box;
    private Gtk.Spinner? comments_spinner;
    private Gtk.Label? comments_status_label;
    private string? comments_loaded_url = null;

    private WebKit.UserContentManager? user_content_manager;
    private WebKit.UserStyleSheet? adblock_sheet;

    public signal void closed();
    private bool is_destroyed = false;

    public ArticleSheet(NewsWindow parent) {
        parent_window = parent;

        // Top-level container
        container = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        container.set_hexpand(true);
        container.set_vexpand(true);
        container.set_visible(false);

        // Revealer
        revealer = new Gtk.Revealer();
        revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_UP);
        revealer.set_transition_duration(800);
        revealer.set_reveal_child(false);
        revealer.set_valign(Gtk.Align.FILL);
        revealer.add_css_class("article-sheet");

        // Content box
        content_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        content_box.set_hexpand(true);
        content_box.set_vexpand(true);
        content_box.add_css_class("sheet");

        // Header with navigation buttons
        var header = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        header.set_margin_top(8);
        header.set_margin_bottom(8);
        header.set_margin_start(8);
        header.set_margin_end(8);
        header.set_hexpand(true);
        header.add_css_class("sheet-header");

        back_btn = new Gtk.Button.from_icon_name("go-previous-symbolic");
        back_btn.set_tooltip_text("Back");
        back_btn.set_can_focus(false);
        back_btn.clicked.connect(() => { if (!is_destroyed && webview != null) webview.go_back(); });

        forward_btn = new Gtk.Button.from_icon_name("go-next-symbolic");
        forward_btn.set_tooltip_text("Forward");
        forward_btn.set_can_focus(false);
        forward_btn.clicked.connect(() => { if (!is_destroyed && webview != null) webview.go_forward(); });

        refresh_btn = new Gtk.Button.from_icon_name("view-refresh-symbolic");
        refresh_btn.set_tooltip_text("Reload article");
        refresh_btn.clicked.connect(() => {
            if (!is_destroyed && webview != null) webview.reload();
        });

        reader_toggle_btn = new Gtk.ToggleButton();
        // "view-reader-symbolic" doesn't exist in Adwaita (only in some
        // third-party themes like elementary's), so it rendered as the
        // missing-icon glyph - "view-paged-symbolic" is a real Adwaita icon
        // and reads reasonably as a reading/document view toggle.
        reader_toggle_btn.set_icon_name("view-paged-symbolic");
        reader_toggle_btn.set_tooltip_text("Reader view");
        reader_toggle_btn.set_can_focus(false);
        reader_toggle_btn.toggled.connect(() => {
            if (is_destroyed) return;
            if (reader_toggle_btn.get_active()) {
                show_reader_view();
            } else {
                show_web_view();
            }
        });

        reader_view = new ReaderView(parent_window);

        var spacer = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        spacer.set_hexpand(true);

        close_btn = new Gtk.Button();
        var close_content = new Adw.ButtonContent();
        close_content.set_icon_name("window-close-symbolic");
        close_content.set_label("Close");
        close_btn.set_child(close_content);
        close_btn.set_tooltip_text("Close article");
        close_btn.clicked.connect(() => { if (!is_destroyed) dismiss(); });

        header.append(back_btn);
        header.append(forward_btn);
        header.append(refresh_btn);
        header.append(spacer);
        header.append(reader_toggle_btn);
        header.append(reader_view.get_settings_button());
        header.append(close_btn);

        content_box.append(header);

        view_stack = new Gtk.Stack();
        view_stack.set_hexpand(true);
        view_stack.set_vexpand(true);

        view_stack.add_named(reader_view.get_widget(), "reader");

        comments_split = new Adw.OverlaySplitView();
        comments_split.set_hexpand(true);
        comments_split.set_vexpand(true);
        comments_split.set_show_sidebar(false);
        comments_split.set_sidebar_position(Gtk.PackType.END);
        comments_split.set_max_sidebar_width(420);
        comments_split.set_min_sidebar_width(294);
        comments_split.set_sidebar_width_fraction(0.29);
        comments_split.set_collapsed(true); // Always overlay, never push content
        comments_split.set_enable_show_gesture(false); // Disable swipe to prevent accidental opens
        comments_split.set_enable_hide_gesture(true);  // Allow swipe to close
        comments_split.set_content(view_stack);

        // Keep the floating toggle button in sync with the sidebar's actual
        // state - hidden while the pane is open (it would otherwise render
        // on top of the pane's edge, since it's a plain overlay child of
        // the whole split view, not scoped to just the content side), and
        // resynced if the sidebar closes via a gesture rather than the
        // button itself (e.g. built-in Escape handling).
        comments_split.notify["show-sidebar"].connect(() => {
            bool open = comments_split.get_show_sidebar();
            if (comments_toggle_btn != null) {
                comments_toggle_btn.set_visible(!open);
                if (!open) comments_toggle_btn.set_active(false);
            }
        });

        var view_overlay = new Gtk.Overlay();
        view_overlay.set_hexpand(true);
        view_overlay.set_vexpand(true);
        view_overlay.set_child(comments_split);
        content_box.append(view_overlay);

        comments_toggle_btn = new Gtk.ToggleButton();
        var comments_toggle_icon = new Gtk.Image.from_icon_name(bundled_comments_icon_name());
        comments_toggle_icon.set_pixel_size(24);
        comments_toggle_btn.set_child(comments_toggle_icon);
        comments_toggle_btn.set_tooltip_text("View comments");
        comments_toggle_btn.add_css_class("circular");
        comments_toggle_btn.add_css_class("osd");
        comments_toggle_btn.add_css_class("comments-fab");
        comments_toggle_btn.set_can_focus(false);
        comments_toggle_btn.set_halign(Gtk.Align.END);
        comments_toggle_btn.set_valign(Gtk.Align.END);
        comments_toggle_btn.set_margin_end(20);
        comments_toggle_btn.set_margin_bottom(20);
        comments_toggle_btn.toggled.connect(() => {
            if (is_destroyed || comments_split == null) return;
            comments_split.set_show_sidebar(comments_toggle_btn.get_active());
            if (comments_toggle_btn.get_active()) load_comments();
        });
        view_overlay.add_overlay(comments_toggle_btn);

        var comments_header = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        comments_header.set_margin_top(8);
        comments_header.set_margin_bottom(8);
        comments_header.set_margin_start(12);
        comments_header.set_margin_end(12);
        var comments_title = new Gtk.Label("Comments");
        comments_title.add_css_class("title-4");
        comments_title.set_hexpand(true);
        comments_title.set_halign(Gtk.Align.START);
        var comments_close_btn = new Gtk.Button.from_icon_name("window-close-symbolic");
        comments_close_btn.set_tooltip_text("Close comments");
        comments_close_btn.set_can_focus(false);
        comments_close_btn.clicked.connect(() => {
            if (!is_destroyed && comments_toggle_btn != null) comments_toggle_btn.set_active(false);
        });
        comments_header.append(comments_title);
        comments_header.append(comments_close_btn);

        comments_list_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        comments_list_box.set_margin_start(12);
        comments_list_box.set_margin_end(12);
        comments_list_box.set_margin_top(12);
        comments_list_box.set_margin_bottom(12);

        var comments_scroller = new Gtk.ScrolledWindow();
        comments_scroller.set_hexpand(true);
        comments_scroller.set_vexpand(true);
        comments_scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        comments_scroller.set_child(comments_list_box);

        comments_spinner = new Gtk.Spinner();
        comments_spinner.set_size_request(32, 32);
        comments_spinner.set_halign(Gtk.Align.CENTER);
        comments_spinner.set_valign(Gtk.Align.CENTER);
        comments_spinner.set_vexpand(true);

        comments_status_label = new Gtk.Label("");
        comments_status_label.add_css_class("dim-label");
        comments_status_label.set_halign(Gtk.Align.CENTER);
        comments_status_label.set_valign(Gtk.Align.CENTER);
        comments_status_label.set_vexpand(true);
        comments_status_label.set_wrap(true);
        comments_status_label.set_justify(Gtk.Justification.CENTER);
        comments_status_label.set_margin_start(24);
        comments_status_label.set_margin_end(24);

        comments_stack = new Gtk.Stack();
        comments_stack.set_hexpand(true);
        comments_stack.set_vexpand(true);
        comments_stack.add_named(comments_spinner, "loading");
        comments_stack.add_named(comments_status_label, "status");
        comments_stack.add_named(comments_scroller, "list");

        var comments_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        comments_box.set_vexpand(true);
        comments_box.set_hexpand(false);
        comments_box.add_css_class("sheet");
        comments_box.add_css_class("comments-pane");
        comments_box.append(comments_header);
        comments_box.append(new Gtk.Separator(Gtk.Orientation.HORIZONTAL));
        comments_box.append(comments_stack);

        comments_split.set_sidebar(comments_box);

        revealer.set_child(content_box);
        container.append(revealer);


        // Load adblock CSS
        adblock_css = "";
        string? css_path = DataPathsUtils.find_data_file("resources/adblock.css");
        if (css_path != null) {
            try {
                GLib.FileUtils.get_contents(css_path, out adblock_css);
            } catch (GLib.Error e) {
                adblock_css = "";
            }
        } else {
            adblock_css = "";
        }

        // Clicking outside content dismisses the sheet
        var click = new Gtk.GestureClick();
        click.set_propagation_phase(Gtk.PropagationPhase.CAPTURE);
        container.add_controller(click);
        click.pressed.connect((g, n_press, x, y) => {
            if (is_destroyed || !revealer.get_reveal_child()) return;
            double cxd = 0, cyd = 0;
            content_box.translate_coordinates(container, 0, 0, out cxd, out cyd);
            int cx = (int)cxd, cy = (int)cyd, cw = content_box.get_allocated_width(), ch = content_box.get_allocated_height();
            if (x < cx || x > (cx + cw) || y < cy || y > (cy + ch)) dismiss();
        });

        // Create initial WebView
        setup_webview();

        // Hide container when revealer fully hides
        revealer.notify["reveal-child"].connect(() => {
            if (!revealer.get_reveal_child()) {
                container.set_visible(false);
                // Rebuild the webview so its back-forward list (and any
                // WebKit-suspended processes retained for it) is dropped
                // once the article is closed, instead of accumulating for
                // the lifetime of this long-lived, reused ArticleSheet.
                setup_webview();
                if (reader_view != null) reader_view.reset();
                closed();
            }
        });
    }

    private void update_nav_buttons() {
        if (back_btn != null) back_btn.set_sensitive(webview != null ? webview.can_go_back() : false);
        if (forward_btn != null) forward_btn.set_sensitive(webview != null ? webview.can_go_forward() : false);
    }

    private void setup_webview() {
        if (webview != null) {
            webview.stop_loading();
            if (user_content_manager != null && adblock_sheet != null) {
                user_content_manager.remove_style_sheet(adblock_sheet);
            }
            view_stack.remove(webview);
            webview = null;
            user_content_manager = null;
            adblock_sheet = null;
        }

        webview = new WebKit.WebView();
        webview.get_settings().set_enable_page_cache(false);
        if (adblock_css.length > 0) {
            user_content_manager = webview.get_user_content_manager();
            adblock_sheet = new WebKit.UserStyleSheet(adblock_css, WebKit.UserContentInjectedFrames.ALL_FRAMES, WebKit.UserStyleLevel.USER, null, null);
            user_content_manager.add_style_sheet(adblock_sheet);
        }
        webview.set_hexpand(true);
        webview.set_vexpand(true);

        // Popup/new window handling
        webview.create.connect((view, nav) => {
            if (is_destroyed) return null;
            var new_sheet = new ArticleSheet(parent_window);
            parent_window.root_overlay.add_overlay(new_sheet.get_widget());
            new_sheet.closed.connect(() => {
                parent_window.root_overlay.remove_overlay(new_sheet.get_widget()); new_sheet.destroy();
            });
            return new_sheet.webview;
        });

        // Load state changes update navigation and refresh buttons
        webview.load_changed.connect((_) => {
            if (is_destroyed) return;
                update_nav_buttons();
                if (refresh_btn != null && webview != null) {
                    refresh_btn.set_sensitive(!webview.is_loading);
                }
        });

        // Link-click interception
        webview.decide_policy.connect((decision, decision_type) => {
            if (is_destroyed) return false;
            if (decision_type != WebKit.PolicyDecisionType.NAVIGATION_ACTION) return false;

            var nav_decision = (WebKit.NavigationPolicyDecision)decision;
            var nav_action = nav_decision.get_navigation_action();
            if (nav_action == null || nav_action.get_navigation_type() != WebKit.NavigationType.LINK_CLICKED) return false;

            bool wants_new_sheet = false;
            uint btn = nav_action.get_mouse_button();
            if (btn == 2) wants_new_sheet = true;
            var mods = nav_action.get_modifiers();
            if ((mods & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.META_MASK)) != 0) wants_new_sheet = true;

            if (!wants_new_sheet) return false;

            string? uri = null;
            uri = nav_action.get_request()?.get_uri();

            if (uri != null) {
                var new_sheet = new ArticleSheet(parent_window);
                parent_window.root_overlay.add_overlay(new_sheet.get_widget()); new_sheet.open(uri);
                new_sheet.closed.connect(() => {
                    parent_window.root_overlay.remove_overlay(new_sheet.get_widget()); new_sheet.destroy();
                });
                nav_decision.ignore();
                return true;
            }

            return false;
        });

        view_stack.add_named(webview, "web");
        if (view_stack.get_visible_child_name() == null || !(reader_toggle_btn != null && reader_toggle_btn.get_active())) {
            view_stack.set_visible_child_name("web");
        }
    }

    private void show_reader_view() {
        if (view_stack == null || reader_view == null) return;
        view_stack.set_visible_child_name("reader");
        reader_view.get_settings_button().set_visible(true);

        if (current_url != null && reader_loaded_url != current_url) {
            reader_view.show_loading();
            string url_snapshot = current_url;
            ArticleExtractorService.extract_async(url_snapshot, (extracted) => {
                if (is_destroyed || current_url != url_snapshot) return;
                if (extracted.success) {
                    reader_loaded_url = url_snapshot;
                    reader_view.show_article(extracted, url_snapshot, current_source_name_encoded);
                } else {
                    reader_view.show_error();
                }
            });
        }
    }

    private string bundled_comments_icon_name() {
        string prefixed = "io.github.thecalamityjoe87.Paperboy-comments-symbolic";
        var theme = Gtk.IconTheme.get_for_display(Gdk.Display.get_default());
        if (theme != null && theme.has_icon(prefixed)) return prefixed;
        return "chat-message-new-symbolic";
    }

    private void show_web_view() {
        if (view_stack == null) return;
        view_stack.set_visible_child_name("web");
        if (reader_view != null) reader_view.get_settings_button().set_visible(false);
    }

    private void load_comments() {
        if (comments_stack == null || current_url == null) return;
        if (comments_loaded_url == current_url) return;
        comments_loaded_url = current_url;

        comments_stack.set_visible_child_name("loading");
        if (comments_spinner != null) comments_spinner.start();

        string url_snapshot = current_url;
        string? wfw_url = current_comments_url;

        // Try the feed's own native comment RSS first, then Disqus, then
        // Hacker News discussion of the URL - stopping at the first
        // provider that actually has comments.
        void finish(Gee.ArrayList<FeedComment> comments, bool success) {
            if (is_destroyed || current_url != url_snapshot) return;
            if (comments_spinner != null) comments_spinner.stop();
            show_comments(comments, success);
        }

        void try_hn() {
            Paperboy.HackerNewsCommentsService.fetch_for_url(url_snapshot, (comments, success) => {
                finish(comments, success);
            });
        }

        void try_disqus() {
            Paperboy.DisqusCommentsService.fetch_for_url(url_snapshot, (comments, success) => {
                if (comments.size > 0) {
                    finish(comments, success);
                    return;
                }
                try_hn();
            });
        }

        if (wfw_url != null) {
            Paperboy.CommentsFeedService.fetch(wfw_url, (comments, success) => {
                if (comments.size > 0) {
                    finish(comments, success);
                    return;
                }
                try_disqus();
            });
        } else {
            try_disqus();
        }
    }

    private void show_comments(Gee.ArrayList<FeedComment> comments, bool success) {
        if (comments_stack == null || comments_list_box == null || comments_status_label == null) return;

        if (comments.size == 0) {
            comments_status_label.set_text(success ? "No comments yet." : "Couldn't load comments.");
            comments_stack.set_visible_child_name("status");
            return;
        }

        Gtk.Widget? child = comments_list_box.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            comments_list_box.remove(child);
            child = next;
        }

        foreach (var comment in comments) {
            var row = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);
            row.add_css_class("comment-card");
            row.set_margin_bottom(10);

            var meta_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
            var author_label = new Gtk.Label(comment.author);
            author_label.add_css_class("heading");
            author_label.set_halign(Gtk.Align.START);
            author_label.set_hexpand(true);
            author_label.set_ellipsize(Pango.EllipsizeMode.END);
            meta_row.append(author_label);

            if (comment.published != null) {
                var date_label = new Gtk.Label(DateUtils.time_ago(comment.published));
                date_label.add_css_class("dim-label");
                date_label.add_css_class("caption");
                date_label.set_halign(Gtk.Align.END);
                meta_row.append(date_label);
            }
            row.append(meta_row);

            var body_label = new Gtk.Label(comment.body);
            body_label.set_wrap(true);
            body_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
            body_label.set_halign(Gtk.Align.START);
            body_label.set_justify(Gtk.Justification.LEFT);
            body_label.set_selectable(true);
            row.append(body_label);

            comments_list_box.append(row);
        }

        comments_stack.set_visible_child_name("list");
    }

    public Gtk.Widget get_widget() {
        return container;
    }

    public bool is_open() {
        return revealer.get_reveal_child();
    }

    public void open(string url, bool? force_reader_view = null, string? source_name_encoded = null) {
        if (url == null) return;
        current_url = url;
        reader_loaded_url = null;
        current_source_name_encoded = source_name_encoded;
        if (webview == null) setup_webview();
        if (webview != null) webview.load_uri(url);
        container.set_visible(true);
        revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_UP);
        revealer.set_reveal_child(true);

        current_comments_url = Paperboy.CommentsUrlRegistry.lookup(url);
        comments_loaded_url = null;
        bool comments_enabled = parent_window != null && parent_window.prefs != null && parent_window.prefs.comments_enabled;
        if (comments_toggle_btn != null) {
            comments_toggle_btn.set_active(false);
            comments_toggle_btn.set_visible(comments_enabled);
        }
        if (comments_split != null) comments_split.set_show_sidebar(false);

        bool want_reader = force_reader_view ?? (parent_window != null && parent_window.prefs != null && parent_window.prefs.reader_view_enabled);
        if (reader_toggle_btn != null) {
            if (reader_toggle_btn.get_active() == want_reader) {
                // Toggling to the same state won't fire the `toggled` signal,
                // so drive the view directly to still (re-)extract this article.
                if (want_reader) show_reader_view(); else show_web_view();
            } else {
                reader_toggle_btn.set_active(want_reader);
            }
        }

        Idle.add(() => { update_nav_buttons(); return false; });
    }

    public void dismiss() {
        revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_DOWN);
        revealer.set_reveal_child(false);
    }

    public void destroy() {
        is_destroyed = true;

        if (webview != null) {
            webview.stop_loading();
            if (user_content_manager != null && adblock_sheet != null) {
                user_content_manager.remove_style_sheet(adblock_sheet);
            }
        }
        container.destroy();

        webview = null;
        adblock_sheet = null;
        user_content_manager = null;
        container = null;
        revealer = null;
        content_box = null;
        close_btn = null;
        reader_toggle_btn = null;
        view_stack = null;
        reader_view = null;
        current_url = null;
        reader_loaded_url = null;
        current_source_name_encoded = null;
        current_comments_url = null;
        comments_split = null;
        comments_toggle_btn = null;
        comments_stack = null;
        comments_list_box = null;
        comments_spinner = null;
        comments_status_label = null;
        comments_loaded_url = null;
        parent_window = null;
    }

    protected override void dispose() {
        destroy();
        base.dispose();
    }
}

