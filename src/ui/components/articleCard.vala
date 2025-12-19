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

public class ArticleCard : GLib.Object {
    public Gtk.Box root;
    public Gtk.Overlay overlay;
    public Gtk.Picture image;
    public Gtk.Box title_box;
    public Gtk.Label title_label;
    public string url;
    public string title_text;
    public string? source_name;
    public string? category_id;
    public string? thumbnail_url;
    private ArticleStateStore? article_state_store;
    private NewsWindow? parent_window;
    private ArticleMenu? current_menu;
    private Gtk.Popover? current_popover;

    // Signal emitted when the card is activated (clicked/tapped)
    public signal void activated(string url);

    // Signal emitted when context menu action is requested
    public signal void open_in_app_requested(string url);
    public signal void open_in_browser_requested(string url);
    public signal void follow_source_requested(string url, string? source_name);
    public signal void save_for_later_requested(string url);
    public signal void share_requested(string url);

    public ArticleCard(string title, string url, int col_w, int img_h, Gtk.Widget chip, int variant, ArticleStateStore? state_store = null, NewsWindow? window = null) {
        GLib.Object();
        this.url = url;
        this.title_text = title;
        this.article_state_store = state_store;
        this.parent_window = window;

        root = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        root.add_css_class("card");
        root.set_hexpand(true);
        root.set_halign(Gtk.Align.FILL);
        root.set_size_request(col_w, -1);

        // Attach this ArticleCard object to the root widget so search can access it
        root.set_data("article-card", this);

        image = new Gtk.Picture();
        image.set_halign(Gtk.Align.FILL);
        image.set_hexpand(true);
        image.set_size_request(col_w, img_h);
        image.set_content_fit(Gtk.ContentFit.COVER);
        image.set_can_shrink(true);

        overlay = new Gtk.Overlay();
        overlay.set_child(image);

        // Add the provided category chip overlay (owner computes chip)
        if (chip != null) overlay.add_overlay(chip);

        root.append(overlay);

        // Title container
        title_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
        title_box.set_margin_start(12);
        title_box.set_margin_end(12);
        title_box.set_margin_top(12);
        title_box.set_margin_bottom(12);
        title_box.set_vexpand(true);

        title_label = new Gtk.Label(title);
        title_label.set_ellipsize(Pango.EllipsizeMode.END);
        title_label.set_xalign(0);
        title_label.set_wrap(true);
        title_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        // Size request tuned by caller
        title_label.set_size_request(col_w - 24, -1);
        switch (variant) {
            case 0: title_label.set_lines(3); break;
            case 1: title_label.set_lines(4); break;
            default: title_label.set_lines(6); break;
        }
        title_box.append(title_label);
        root.append(title_box);

        // Click gesture emits activated signal with the URL
        var gesture = new Gtk.GestureClick();
        // Accept primary button clicks (1) and handle release with full signature
        gesture.set_button(1);
        // Use a simple no-argument handler (original pattern) to avoid
        // signature mismatches; emit the declared signal so connected
        // handlers receive the article URL.
        gesture.released.connect(() => {
            activated(url);
        });
        root.add_controller(gesture);

        // Hover effects
        var motion = new Gtk.EventControllerMotion();
        motion.enter.connect(() => { root.add_css_class("card-hover"); });
        motion.leave.connect(() => { root.remove_css_class("card-hover"); });
        root.add_controller(motion);

        // Right-click context menu
        var right_click = new Gtk.GestureClick();
        right_click.set_button(3);
        right_click.pressed.connect((n_press, x, y) => {
            show_context_menu(x, y);
        });
        root.add_controller(right_click);
    }

    private void show_context_menu(double x, double y) {
        // Check if article is already saved and if it's viewed
        bool is_saved = false;
        bool is_viewed = false;
        // Normalize URL before checking view/save state so we match the stored keys
        string norm_url = url;
        if (parent_window != null) norm_url = parent_window.normalize_article_url(url);
        if (article_state_store != null) {
            is_saved = article_state_store.is_saved(norm_url);
            is_viewed = article_state_store.is_viewed(norm_url);
        }

        // Create ArticleMenu instance and keep reference to prevent garbage collection
        current_menu = new ArticleMenu(url, source_name, is_saved, is_viewed, parent_window);
        
        // Connect menu signals to card signals
        current_menu.open_in_app_requested.connect((url) => {
            open_in_app_requested(url);
        });
        current_menu.open_in_browser_requested.connect((url) => {
            open_in_browser_requested(url);
        });
        current_menu.follow_source_requested.connect((url, source_name) => {
            follow_source_requested(url, source_name);
        });
        current_menu.save_for_later_requested.connect((url) => {
            save_for_later_requested(url);
        });
        current_menu.share_requested.connect((url) => {
            share_requested(url);
        });

        // Handle marking a single article as unread
        current_menu.mark_unread_requested.connect((article_url) => {
            // Normalize and operate on canonical URL so disk/meta keys match
            string nurl = article_url;
            if (parent_window != null) nurl = parent_window.normalize_article_url(article_url);

            if (article_state_store != null) {
                article_state_store.mark_unviewed(nurl);
            }

            // Remove from in-memory viewed set so UI updates immediately
            if (parent_window != null && parent_window.view_state != null) parent_window.view_state.viewed_articles.remove(nurl);

            // Update badges and viewed badges for the source if possible
            // Badge update is handled via ArticleStateStore.viewed_status_changed signal
            if (parent_window != null && parent_window.view_state != null && source_name != null) {
                parent_window.view_state.refresh_viewed_badges_for_source(source_name);
                parent_window.view_state.refresh_viewed_badge_for_url(nurl);
            }
        });

        // Create and show popover, keep reference to prevent garbage collection
        current_popover = current_menu.create_popover(root, x, y);
        current_popover.popup();
    }
}
