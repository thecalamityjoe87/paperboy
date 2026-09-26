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
    private Adw.NavigationView nav_view;
    private Adw.NavigationPage article_page;
    private Gtk.Box content_box;
    private Gtk.Button? close_btn;
    private Gtk.Button? options_btn;
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
    private Gtk.Overlay? comments_fab_overlay;
    private Gtk.Label? comments_count_badge;
    private Gtk.Stack? comments_stack;
    private Gtk.Box? comments_list_box;
    private Gtk.Spinner? comments_spinner;
    private Gtk.Label? comments_status_label;
    private string? comments_loaded_url = null;

    private Adw.OverlaySplitView? notes_split;
    private Gtk.ToggleButton? notes_toggle_btn;
    private Gtk.Stack? notes_stack;
    private Gtk.Box? notes_list_box;
    private Gtk.Label? notes_status_label;
    private ulong notes_added_handler = 0;
    private ulong notes_updated_handler = 0;
    private ulong notes_removed_handler = 0;

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

        // Adw.NavigationView gives the sheet a native push/pop slide
        // animation and the platform's own swipe-back gesture for free.
        nav_view = new Adw.NavigationView();
        nav_view.set_hexpand(true);
        nav_view.set_vexpand(true);
        nav_view.add_css_class("article-sheet");
        var root_page = new Adw.NavigationPage(new Gtk.Box(Gtk.Orientation.VERTICAL, 0), "Root");
        nav_view.push(root_page);

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
        back_btn.add_css_class("flat");
        back_btn.set_tooltip_text("Back");
        back_btn.set_can_focus(false);
        back_btn.clicked.connect(() => { if (!is_destroyed && webview != null) webview.go_back(); });

        forward_btn = new Gtk.Button.from_icon_name("go-next-symbolic");
        forward_btn.add_css_class("flat");
        forward_btn.set_tooltip_text("Forward");
        forward_btn.set_can_focus(false);
        forward_btn.clicked.connect(() => { if (!is_destroyed && webview != null) webview.go_forward(); });

        refresh_btn = new Gtk.Button.from_icon_name("view-refresh-symbolic");
        refresh_btn.add_css_class("flat");
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
        reader_toggle_btn.add_css_class("flat");
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

        options_btn = new Gtk.Button.from_icon_name("view-more-symbolic");
        options_btn.add_css_class("flat");
        options_btn.set_tooltip_text("Article options");
        options_btn.set_can_focus(false);
        options_btn.clicked.connect(() => { if (!is_destroyed) show_options_menu(); });

        notes_toggle_btn = new Gtk.ToggleButton();
        notes_toggle_btn.set_icon_name("document-edit-symbolic");
        notes_toggle_btn.add_css_class("flat");
        notes_toggle_btn.set_tooltip_text("Notes");
        notes_toggle_btn.set_can_focus(false);
        notes_toggle_btn.toggled.connect(() => {
            if (is_destroyed || notes_split == null) return;
            notes_split.set_show_sidebar(notes_toggle_btn.get_active());
            if (notes_toggle_btn.get_active()) load_notes();
        });

        header.append(back_btn);
        header.append(forward_btn);
        header.append(refresh_btn);
        header.append(spacer);
        header.append(reader_toggle_btn);
        header.append(reader_view.get_settings_button());
        header.append(notes_toggle_btn);
        header.append(options_btn);
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
            if (comments_toggle_btn != null && !open) comments_toggle_btn.set_active(false);
            update_comments_fab_visibility();
        });

        // Notes gets its own OverlaySplitView, nested outside comments_split,
        // so the two panes toggle independently instead of sharing one
        // sidebar's content.
        notes_split = new Adw.OverlaySplitView();
        notes_split.set_hexpand(true);
        notes_split.set_vexpand(true);
        notes_split.set_show_sidebar(false);
        notes_split.set_sidebar_position(Gtk.PackType.END);
        notes_split.set_max_sidebar_width(420);
        notes_split.set_min_sidebar_width(294);
        notes_split.set_sidebar_width_fraction(0.29);
        notes_split.set_collapsed(true);
        notes_split.set_enable_show_gesture(false);
        notes_split.set_enable_hide_gesture(true);
        notes_split.set_content(comments_split);

        notes_split.notify["show-sidebar"].connect(() => {
            bool open = notes_split.get_show_sidebar();
            if (notes_toggle_btn != null && !open) notes_toggle_btn.set_active(false);
            update_comments_fab_visibility();
        });

        var view_overlay = new Gtk.Overlay();
        view_overlay.set_hexpand(true);
        view_overlay.set_vexpand(true);
        view_overlay.set_child(notes_split);
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
        comments_toggle_btn.toggled.connect(() => {
            if (is_destroyed || comments_split == null) return;
            comments_split.set_show_sidebar(comments_toggle_btn.get_active());
            if (comments_toggle_btn.get_active()) load_comments();
        });

        comments_count_badge = new Gtk.Label("");
        comments_count_badge.add_css_class("comments-fab-badge");
        // xalign centers the text within the label's own CSS-sized box;
        // halign/valign below only place that box within the overlay, and
        // don't otherwise guarantee the text itself is centered inside it.
        comments_count_badge.set_xalign(0.5f);
        comments_count_badge.set_yalign(0.5f);
        comments_count_badge.set_justify(Gtk.Justification.CENTER);
        comments_count_badge.set_halign(Gtk.Align.END);
        comments_count_badge.set_valign(Gtk.Align.START);
        comments_count_badge.set_visible(false);

        // Small overlay so the count badge can sit on the FAB's own
        // top-right corner, slightly overlapping it, independent of the
        // FAB's own position within the larger view_overlay.
        comments_fab_overlay = new Gtk.Overlay();
        comments_fab_overlay.set_child(comments_toggle_btn);
        comments_fab_overlay.add_overlay(comments_count_badge);
        comments_fab_overlay.set_halign(Gtk.Align.END);
        comments_fab_overlay.set_valign(Gtk.Align.END);
        comments_fab_overlay.set_margin_end(32);
        comments_fab_overlay.set_margin_bottom(20);
        view_overlay.add_overlay(comments_fab_overlay);

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

        var notes_header = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        notes_header.set_margin_top(8);
        notes_header.set_margin_bottom(8);
        notes_header.set_margin_start(12);
        notes_header.set_margin_end(12);
        var notes_title = new Gtk.Label("Notes");
        notes_title.add_css_class("title-4");
        notes_title.set_hexpand(true);
        notes_title.set_halign(Gtk.Align.START);
        var new_note_btn = new Gtk.Button.from_icon_name("list-add-symbolic");
        new_note_btn.set_tooltip_text("New note");
        new_note_btn.set_can_focus(false);
        new_note_btn.clicked.connect(() => {
            if (is_destroyed || current_url == null || parent_window == null) return;
            string? selected_quote = reader_view != null ? reader_view.get_selected_text() : null;
            NoteEditorDialog.show(parent_window, current_url, null, selected_quote);
        });
        var notes_close_btn = new Gtk.Button.from_icon_name("window-close-symbolic");
        notes_close_btn.set_tooltip_text("Close notes");
        notes_close_btn.set_can_focus(false);
        notes_close_btn.clicked.connect(() => {
            if (!is_destroyed && notes_toggle_btn != null) notes_toggle_btn.set_active(false);
        });
        notes_header.append(notes_title);
        notes_header.append(new_note_btn);
        notes_header.append(notes_close_btn);

        notes_list_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        notes_list_box.set_margin_start(12);
        notes_list_box.set_margin_end(12);
        notes_list_box.set_margin_top(12);
        notes_list_box.set_margin_bottom(12);

        var notes_scroller = new Gtk.ScrolledWindow();
        notes_scroller.set_hexpand(true);
        notes_scroller.set_vexpand(true);
        notes_scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        notes_scroller.set_child(notes_list_box);

        notes_status_label = new Gtk.Label("No notes yet.");
        notes_status_label.add_css_class("dim-label");
        notes_status_label.set_halign(Gtk.Align.CENTER);
        notes_status_label.set_valign(Gtk.Align.CENTER);
        notes_status_label.set_vexpand(true);

        notes_stack = new Gtk.Stack();
        notes_stack.set_hexpand(true);
        notes_stack.set_vexpand(true);
        notes_stack.add_named(notes_status_label, "status");
        notes_stack.add_named(notes_scroller, "list");

        var notes_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        notes_box.set_vexpand(true);
        notes_box.set_hexpand(false);
        notes_box.add_css_class("sheet");
        notes_box.add_css_class("comments-pane");
        notes_box.append(notes_header);
        notes_box.append(new Gtk.Separator(Gtk.Orientation.HORIZONTAL));
        notes_box.append(notes_stack);

        notes_split.set_sidebar(notes_box);

        var notes_store = Paperboy.NotesStore.get_instance();
        notes_added_handler = notes_store.note_added.connect((note) => {
            if (is_destroyed || current_url == null || note.url != current_url) return;
            load_notes();
        });
        notes_updated_handler = notes_store.note_updated.connect((note) => {
            if (is_destroyed || current_url == null || note.url != current_url) return;
            load_notes();
        });
        notes_removed_handler = notes_store.note_removed.connect((url, id) => {
            if (is_destroyed || current_url == null || url != current_url) return;
            if (reader_view != null) reader_view.remove_note_highlight(id);
            load_notes();
        });

        article_page = new Adw.NavigationPage(content_box, "Article");
        container.append(nav_view);


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

        // Clicking outside content dismisses the sheet. Primary button
        // only - unrestricted here (a capture-phase gesture on an ancestor
        // of the reader view) was seeing every right-click inside the
        // article body before the TextView's own context-menu handling
        // got a chance, blocking the native right-click menu entirely.
        var click = new Gtk.GestureClick();
        click.set_button(Gdk.BUTTON_PRIMARY);
        click.set_propagation_phase(Gtk.PropagationPhase.CAPTURE);
        container.add_controller(click);
        click.pressed.connect((g, n_press, x, y) => {
            if (is_destroyed || !is_open()) return;
            // Any primary click in the sheet dismisses an active text
            // selection's "add note" popover, not just one landing back
            // inside the reader body - previously only content_box's own
            // click handling covered that.
            if (reader_view != null) reader_view.hide_add_note_popover();
            double cxd = 0, cyd = 0;
            content_box.translate_coordinates(container, 0, 0, out cxd, out cyd);
            int cx = (int)cxd, cy = (int)cyd, cw = content_box.get_allocated_width(), ch = content_box.get_allocated_height();
            if (x < cx || x > (cx + cw) || y < cy || y > (cy + ch)) dismiss();
        });

        // Create initial WebView
        setup_webview();

        // Fires once the article page is fully off-screen, whether closed
        // via the close button, outside click, or the NavigationView's own
        // native swipe-back gesture.
        article_page.hidden.connect(() => {
            container.set_visible(false);
            // Rebuild the webview so its back-forward list (and any
            // WebKit-suspended processes retained for it) is dropped
            // once the article is closed, instead of accumulating for
            // the lifetime of this long-lived, reused ArticleSheet.
            setup_webview();
            if (reader_view != null) reader_view.reset();
            closed();
        });
    }

    private void update_nav_buttons() {
        if (back_btn != null) back_btn.set_sensitive(webview != null ? webview.can_go_back() : false);
        if (forward_btn != null) forward_btn.set_sensitive(webview != null ? webview.can_go_forward() : false);
    }

    // The comments FAB is a plain overlay child of view_overlay, drawn on
    // top of both split views regardless of their own sidebar state - hide
    // it whenever either pane is open so it doesn't float over the pane.
    private void update_comments_fab_visibility() {
        if (comments_fab_overlay == null) return;
        bool comments_open = comments_split != null && comments_split.get_show_sidebar();
        bool notes_open = notes_split != null && notes_split.get_show_sidebar();
        comments_fab_overlay.set_visible(!comments_open && !notes_open);
    }

    // Same options as an article card's context menu (open in browser,
    // follow source, save, mark unread, share), minus "view in app" since
    // the sheet is already showing it.
    private void show_options_menu() {
        if (current_url == null || parent_window == null || options_btn == null) return;
        string url = current_url;
        string? source_name = current_source_name_encoded;
        string norm_url = parent_window.normalize_article_url(url);

        bool is_saved = false;
        bool is_viewed = false;
        if (parent_window.article_state_store != null) {
            is_saved = parent_window.article_state_store.is_saved(norm_url);
            is_viewed = parent_window.article_state_store.is_viewed(norm_url);
        }

        var menu = new ArticleMenu(url, source_name, is_saved, is_viewed, parent_window);
        menu.show_view_in_app = false;

        menu.open_in_browser_requested.connect((article_url) => {
            if (parent_window.article_manager != null) parent_window.article_manager.open_article_in_browser_if_online(article_url);
        });
        menu.follow_source_requested.connect((article_url, src_name) => {
            parent_window.show_toast("Searching for feed...");
            if (parent_window.source_manager != null) parent_window.source_manager.follow_rss_source(article_url, src_name);
        });
        menu.save_for_later_requested.connect((article_url) => {
            if (parent_window.article_state_store == null) return;
            if (parent_window.article_state_store.is_saved(norm_url)) {
                parent_window.article_state_store.unsave_article(article_url);
                parent_window.show_toast("Removed article from saved");
            } else {
                string title = (webview != null ? webview.get_title() : null) ?? "";
                if (title.length == 0) title = article_url;
                parent_window.article_state_store.save_article(article_url, title, null, source_name, null);
                parent_window.show_toast("Added article to saved");
            }
        });
        menu.mark_unread_requested.connect((article_url) => {
            if (parent_window.article_state_store != null) parent_window.article_state_store.mark_unviewed(norm_url);
            if (parent_window.view_state != null) {
                parent_window.view_state.viewed_articles.remove(norm_url);
                if (source_name != null) parent_window.view_state.refresh_viewed_badges_for_source(source_name);
                parent_window.view_state.refresh_viewed_badge_for_url(norm_url);
            }
        });
        menu.share_requested.connect((article_url) => {
            parent_window.show_share_dialog(article_url);
        });

        var popover = new Gtk.Popover();
        popover.set_parent(options_btn);
        popover.set_child(menu.create_menu_box(popover));
        popover.popup();
    }

    private void setup_webview() {
        if (webview != null) {
            webview.stop_loading();
            if (user_content_manager != null && adblock_sheet != null) {
                user_content_manager.remove_style_sheet(adblock_sheet);
            }
            view_stack.remove(webview);
            // Dropping every ref alone leaks the bwrap web process - must
            // terminate it explicitly.
            WebViewUtils.terminate_process(webview);
            webview = null;
            user_content_manager = null;
            adblock_sheet = null;
        }

        webview = WebViewUtils.create();
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
            ArticleExtractorService.extract_async(url_snapshot, true, (extracted) => {
                if (is_destroyed || current_url != url_snapshot) return;
                if (extracted.success) {
                    reader_loaded_url = url_snapshot;
                    reader_view.show_article(extracted, url_snapshot, current_source_name_encoded);
                    reader_view.highlight_notes(Paperboy.NotesStore.get_instance().get_notes_for_url(url_snapshot));
                    backfill_card_thumbnail(url_snapshot, extracted.hero_image_url);
                } else {
                    reader_view.show_error();
                }
            });
        }
    }

    // If the card for this article never had a real thumbnail (only a
    // placeholder), but reader view found a hero image on the actual page,
    // use it as the card's thumbnail. Never touches a card that already has
    // a real, API-provided image.
    private void backfill_card_thumbnail(string url, string? hero_image_url) {
        if (hero_image_url == null || hero_image_url.length == 0) return;
        if (!hero_image_url.has_prefix("http://") && !hero_image_url.has_prefix("https://")) return;
        if (parent_window == null || parent_window.view_state == null || parent_window.image_manager == null) return;

        string norm = parent_window.normalize_article_url(url);
        var pic = parent_window.view_state.url_to_picture.get(norm);
        if (pic == null) return;
        if (pic.get_data<bool>("has-real-thumbnail")) return;

        int w = pic.get_width();
        int h = pic.get_height();
        if (w <= 0 || h <= 0) return;

        parent_window.image_manager.load_image_async(pic, hero_image_url, w * 3, h * 3, true);
        pic.set_data<bool>("has-real-thumbnail", true);
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

        // Try the feed's own native comment RSS first, then Coral, then
        // Viafoura, then OpenWeb, then Disqus, then Hacker News discussion
        // of the URL - stopping at the first provider that actually has
        // comments.
        void finish(Gee.ArrayList<FeedComment> comments, bool success) {
            if (is_destroyed || current_url != url_snapshot) return;
            if (comments_spinner != null) comments_spinner.stop();
            if (comments_count_badge != null) {
                if (success && comments.size > 0) {
                    comments_count_badge.set_text(comments.size > 9 ? "9+" : comments.size.to_string());
                    comments_count_badge.set_visible(true);
                } else {
                    comments_count_badge.set_visible(false);
                }
            }
            show_comments(comments, success);
        }

        void try_hn() {
            GLib.debug("ArticleSheet: trying HackerNewsCommentsService");
            Paperboy.HackerNewsCommentsService.fetch_for_url(url_snapshot, (comments, success) => {
                GLib.debug("ArticleSheet: HN returned %d comments", comments.size);
                finish(comments, success);
            });
        }

        void try_disqus() {
            GLib.debug("ArticleSheet: trying DisqusCommentsService");
            Paperboy.DisqusCommentsService.fetch_for_url(url_snapshot, (comments, success) => {
                GLib.debug("ArticleSheet: Disqus returned %d comments", comments.size);
                if (comments.size > 0) {
                    finish(comments, success);
                    return;
                }
                try_hn();
            });
        }

        void try_openweb() {
            GLib.debug("ArticleSheet: trying OpenWebCommentsService");
            Paperboy.OpenWebCommentsService.fetch_for_url(url_snapshot, (comments, success) => {
                GLib.debug("ArticleSheet: OpenWeb returned %d comments", comments.size);
                if (comments.size > 0) {
                    finish(comments, success);
                    return;
                }
                try_disqus();
            });
        }

        void try_viafoura() {
            GLib.debug("ArticleSheet: trying ViafouraCommentsService");
            Paperboy.ViafouraCommentsService.fetch_for_url(url_snapshot, (comments, success) => {
                GLib.debug("ArticleSheet: Viafoura returned %d comments", comments.size);
                if (comments.size > 0) {
                    finish(comments, success);
                    return;
                }
                try_openweb();
            });
        }

        void try_coral() {
            GLib.debug("ArticleSheet: trying CoralCommentsService");
            Paperboy.CoralCommentsService.fetch_for_url(url_snapshot, (comments, success) => {
                GLib.debug("ArticleSheet: Coral returned %d comments", comments.size);
                if (comments.size > 0) {
                    finish(comments, success);
                    return;
                }
                try_viafoura();
            });
        }

        // No feed-level wfw:commentRss (e.g. built-in fetchers like
        // Guardian/Fox/Reddit, or Frontpage/Top Ten's GNews-backed
        // pipeline, none of which carry that field) - check the article's
        // own page directly for WordPress's standard per-post comments
        // feed link before falling back to OpenWeb/Disqus/HN/generic scrape.
        void try_native_discovery() {
            Paperboy.NativeCommentsDiscoveryService.find(url_snapshot, (discovered_url) => {
                if (discovered_url == null) {
                    try_coral();
                    return;
                }
                Paperboy.CommentsFeedService.fetch(discovered_url, (comments, success) => {
                    if (comments.size > 0) {
                        finish(comments, success);
                        return;
                    }
                    try_coral();
                });
            });
        }

        if (wfw_url != null) {
            Paperboy.CommentsFeedService.fetch(wfw_url, (comments, success) => {
                if (comments.size > 0) {
                    finish(comments, success);
                    return;
                }
                try_coral();
            });
        } else {
            try_native_discovery();
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

    private void load_notes() {
        if (notes_stack == null || notes_list_box == null || current_url == null) return;

        var notes = Paperboy.NotesStore.get_instance().get_notes_for_url(current_url);
        if (reader_view != null) reader_view.highlight_notes(notes);

        Gtk.Widget? child = notes_list_box.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            notes_list_box.remove(child);
            child = next;
        }

        if (notes.size == 0) {
            notes_stack.set_visible_child_name("status");
            return;
        }

        foreach (var note in notes) {
            int display_number = reader_view != null ? reader_view.get_note_display_number(note.id) : 0;
            notes_list_box.append(build_note_row(note, display_number));
        }
        notes_stack.set_visible_child_name("list");
    }

    private Gtk.Widget build_note_row(Paperboy.ArticleNote note, int display_number) {
        var row = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);
        row.add_css_class("comment-card");
        row.set_margin_bottom(10);

        var meta_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);

        var title_label = new Gtk.Label(note.title);
        title_label.add_css_class("heading");
        title_label.set_halign(Gtk.Align.START);
        title_label.set_hexpand(true);
        title_label.set_ellipsize(Pango.EllipsizeMode.END);
        meta_row.append(title_label);

        var date_label = new Gtk.Label(DateUtils.time_ago(note.updated_at.to_string()));
        date_label.add_css_class("dim-label");
        date_label.add_css_class("caption");
        date_label.set_halign(Gtk.Align.END);
        meta_row.append(date_label);
        row.append(meta_row);

        string snippet = stripHtmlUtils.strip_html(note.content_html).strip();
        var body_label = new Gtk.Label(snippet);
        body_label.set_wrap(true);
        body_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        body_label.set_halign(Gtk.Align.START);
        body_label.set_justify(Gtk.Justification.LEFT);
        body_label.set_lines(3);
        body_label.set_ellipsize(Pango.EllipsizeMode.END);
        row.append(body_label);

        if (display_number > 0) {
            var badge_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            badge_row.set_halign(Gtk.Align.END);
            var badge_label = new Gtk.Label(display_number.to_string());
            badge_label.add_css_class("note-list-badge");
            badge_row.append(badge_label);
            row.append(badge_row);
        }

        var click = new Gtk.GestureClick();
        row.add_controller(click);
        click.pressed.connect((g, n_press, x, y) => {
            if (n_press == 2 && !is_destroyed && parent_window != null) {
                NoteEditorDialog.show(parent_window, note.url, note);
            }
        });

        return row;
    }

    public Gtk.Widget get_widget() {
        return container;
    }

    public bool is_open() {
        return nav_view.get_visible_page() == article_page;
    }

    public void open(string url, bool? force_reader_view = null, string? source_name_encoded = null) {
        if (url == null) return;
        current_url = url;
        reader_loaded_url = null;
        current_source_name_encoded = source_name_encoded;
        if (webview == null) setup_webview();
        if (webview != null) webview.load_uri(url);
        container.set_visible(true);
        if (!is_open()) nav_view.push(article_page);

        current_comments_url = Paperboy.CommentsUrlRegistry.lookup(url);
        comments_loaded_url = null;
        bool comments_enabled = parent_window != null && parent_window.prefs != null && parent_window.prefs.comments_enabled;
        if (comments_toggle_btn != null) {
            comments_toggle_btn.set_active(false);
        }
        if (comments_fab_overlay != null) {
            comments_fab_overlay.set_visible(false);
            if (comments_enabled && parent_window != null && parent_window.animation_manager != null) {
                parent_window.animation_manager.animate_card_entrance(comments_fab_overlay, 300u);
            }
        }
        if (comments_count_badge != null) comments_count_badge.set_visible(false);
        if (comments_split != null) comments_split.set_show_sidebar(false);
        // Fetch comments eagerly so the FAB's count badge can appear
        // before the user ever opens the pane, not just after.
        if (comments_enabled) load_comments();

        if (notes_toggle_btn != null) notes_toggle_btn.set_active(false);
        if (notes_split != null) notes_split.set_show_sidebar(false);

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
        if (is_open()) nav_view.pop();
    }

    public void destroy() {
        is_destroyed = true;

        var notes_store = Paperboy.NotesStore.get_instance();
        if (notes_added_handler != 0) notes_store.disconnect(notes_added_handler);
        if (notes_updated_handler != 0) notes_store.disconnect(notes_updated_handler);
        if (notes_removed_handler != 0) notes_store.disconnect(notes_removed_handler);

        if (webview != null) {
            webview.stop_loading();
            if (user_content_manager != null && adblock_sheet != null) {
                user_content_manager.remove_style_sheet(adblock_sheet);
            }
            WebViewUtils.terminate_process(webview);
        }
        container.destroy();

        webview = null;
        adblock_sheet = null;
        user_content_manager = null;
        container = null;
        nav_view = null;
        article_page = null;
        content_box = null;
        close_btn = null;
        options_btn = null;
        reader_toggle_btn = null;
        view_stack = null;
        reader_view = null;
        current_url = null;
        reader_loaded_url = null;
        current_source_name_encoded = null;
        current_comments_url = null;
        comments_split = null;
        comments_toggle_btn = null;
        comments_fab_overlay = null;
        comments_count_badge = null;
        comments_stack = null;
        comments_list_box = null;
        comments_spinner = null;
        comments_status_label = null;
        comments_loaded_url = null;
        notes_split = null;
        notes_toggle_btn = null;
        notes_stack = null;
        notes_list_box = null;
        notes_status_label = null;
        parent_window = null;
    }

    protected override void dispose() {
        destroy();
        base.dispose();
    }
}

