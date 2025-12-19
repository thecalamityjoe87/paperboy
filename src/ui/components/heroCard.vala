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

public class HeroCard : GLib.Object {
    public Gtk.Box root;
    public Gtk.Overlay overlay;
    public Gtk.Picture image;
    public Gtk.Label title_label;
    public string url;
    public string? source_name;
    public string? category_id;
    public string? thumbnail_url;
    private bool enable_context_menu;
    private ArticleStateStore? article_state_store;
    private NewsWindow? parent_window;
    private ArticleMenu? current_menu;
    private Gtk.Popover? current_popover;

    // Signal emitted when the hero/slide is activated (clicked)
    public signal void activated(string url);

    // Signal emitted when context menu action is requested
    public signal void open_in_app_requested(string url);
    public signal void open_in_browser_requested(string url);
    public signal void follow_source_requested(string url, string? source_name);
    public signal void save_for_later_requested(string url);
    public signal void share_requested(string url);

    public HeroCard(string title, string url, int max_total_height, int image_h, Gtk.Widget? chip, bool enable_context_menu = false, ArticleStateStore? state_store = null, NewsWindow? window = null) {
        GLib.Object();
        this.url = url;
        this.enable_context_menu = enable_context_menu;
        this.article_state_store = state_store;
        this.parent_window = window;

        root = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        root.add_css_class("card");
        root.set_size_request(-1, max_total_height);
        root.set_hexpand(true);
        root.set_vexpand(false);
        root.set_halign(Gtk.Align.FILL);
        root.set_valign(Gtk.Align.START);
        root.set_margin_start(0);
        root.set_margin_end(0);

        image = new Gtk.Picture();
        image.set_halign(Gtk.Align.FILL);
        image.set_hexpand(true);
        image.set_size_request(-1, image_h);
        image.set_content_fit(Gtk.ContentFit.COVER);
        image.set_can_shrink(true);

        overlay = new Gtk.Overlay();
        overlay.set_child(image);
        if (chip != null) {
            overlay.add_overlay(chip);
        }

        root.append(overlay);

        var title_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
        title_box.set_margin_start(16);
        title_box.set_margin_end(16);
        title_box.set_margin_top(16);
        title_box.set_margin_bottom(16);
        title_box.set_size_request(-1, 80);
        title_box.set_vexpand(false);

        title_label = new Gtk.Label(title);
        title_label.set_ellipsize(Pango.EllipsizeMode.END);
        title_label.set_xalign(0);
        title_label.set_wrap(true);
        title_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        title_label.set_lines(3);
        title_label.set_max_width_chars(88);
        title_box.append(title_label);
        root.append(title_box);

        // Attach HeroCard object to root for search functionality
        root.set_data("hero-card", this);

        // Click gesture -> emit activated
        var gesture = new Gtk.GestureClick();
        gesture.set_button(1);
        gesture.released.connect(() => {
            activated(this.url);
        });
        root.add_controller(gesture);

        // Hover effects
        var motion = new Gtk.EventControllerMotion();
        motion.enter.connect(() => { root.add_css_class("card-hover"); });
        motion.leave.connect(() => { root.remove_css_class("card-hover"); });
        root.add_controller(motion);

        // Right-click context menu (only if enabled)
        if (enable_context_menu) {
            var right_click = new Gtk.GestureClick();
            right_click.set_button(3);
            right_click.pressed.connect((n_press, x, y) => {
                show_context_menu(x, y);
            });
            root.add_controller(right_click);
        }
    }

    private void show_context_menu(double x, double y) {
        // Check if article is already saved and if it's viewed
        bool is_saved = false;
        bool is_viewed = false;
        // Normalize URL before checking view/save state
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

        current_menu.mark_unread_requested.connect((article_url) => {
            string nurl = article_url;
            if (parent_window != null) nurl = parent_window.normalize_article_url(article_url);

            if (article_state_store != null) {
                article_state_store.mark_unviewed(nurl);
            }

            // Remove from in-memory viewed set so UI updates immediately
            if (parent_window != null && parent_window.view_state != null) parent_window.view_state.viewed_articles.remove(nurl);

            // Also remove any viewed-badge overlay directly from this hero
            if (overlay != null) {
                Gtk.Widget? child = overlay.get_first_child();
                while (child != null) {
                    Gtk.Widget? next = child.get_next_sibling();
                    if (child.get_style_context().has_class("viewed-badge")) {
                        overlay.remove_overlay(child);
                    }
                    child = next;
                }
                overlay.queue_draw();
            }

            // Badge update is handled via ArticleStateStore.viewed_status_changed signal
            if (parent_window != null && parent_window.view_state != null && source_name != null) {
                parent_window.view_state.refresh_viewed_badges_for_source(source_name);
                // Also refresh the single URL so carousel-registered hero widgets update immediately
                parent_window.view_state.refresh_viewed_badge_for_url(nurl);
            }
        });

        // Create and show popover, keep reference to prevent garbage collection
        current_popover = current_menu.create_popover(root, x, y);
        current_popover.popup();
    }
}
