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
    public Gtk.Label? snippet_label;
    public Gtk.Box title_box;
    // Bottom-pinned footer within title_box - holds the relative-time
    // caption and, for carousel slides, the dot-indicator row appended
    // afterward by HeroCarousel. Both stack here rather than each
    // independently claiming vexpand space, which would split them apart.
    public Gtk.Box footer_box;
    public Gtk.Label time_label;
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

    public HeroCard(string title, string url, int max_total_height, int image_h, Gtk.Widget? chip, bool enable_context_menu = false, ArticleStateStore? state_store = null, NewsWindow? window = null, string? published = null) {
        GLib.Object();
        init_base(url, enable_context_menu, state_store, window, max_total_height);
        build_image_overlay_and_title(title, chip, published);

        // A Grid with homogeneous columns gives a proportional (not just
        // even) split that holds its ratio as the card is resized, which a
        // plain Box's hexpand can't do on its own. Text pane takes 2 of 5
        // columns (40%), picture takes 3 of 5 (60%).
        var split = new Gtk.Grid();
        split.set_column_homogeneous(true);
        split.set_hexpand(true);
        split.set_vexpand(true);
        image.set_size_request(-1, image_h);
        split.attach(title_box, 0, 0, 2, 1);
        split.attach(overlay, 2, 0, 3, 1);
        root.append(split);

        finish_interactive_setup();
    }

    /**
    * Top Ten's dedicated layout: picture over text instead of side by
    * side, sized to an exact 70/30 pixel split of max_total_height rather
    * than a proportional grid share.
    */
    public HeroCard.for_topten(string title, string url, int max_total_height, Gtk.Widget? chip, bool enable_context_menu = false, ArticleStateStore? state_store = null, NewsWindow? window = null, string? published = null) {
        GLib.Object();
        init_base(url, enable_context_menu, state_store, window, max_total_height);
        build_image_overlay_and_title(title, chip, published);
        // .hero-card picture normally rounds only the right edge (image
        // sits on the right in the side-by-side layout) - this variant
        // needs the top edge rounded instead, since the image is now on
        // top. See .hero-card.hero-card-stacked in style.css.
        root.add_css_class("hero-card-stacked");

        int image_height = (int) Math.round(max_total_height * 0.7);
        int text_height = max_total_height - image_height;
        image.set_size_request(-1, image_height);
        title_box.set_size_request(-1, text_height);

        var split = new Gtk.Grid();
        split.set_hexpand(true);
        split.set_vexpand(true);
        split.attach(overlay, 0, 0, 1, 1);
        split.attach(title_box, 0, 1, 1, 1);
        root.append(split);

        finish_interactive_setup();
    }

    /**
    * Field/root setup shared by every HeroCard layout.
    */
    private void init_base(string url, bool enable_context_menu, ArticleStateStore? state_store, NewsWindow? window, int max_total_height) {
        this.url = url;
        this.enable_context_menu = enable_context_menu;
        this.article_state_store = state_store;
        this.parent_window = window;

        root = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        root.add_css_class("card");
        root.add_css_class("hero-card");
        root.set_size_request(-1, max_total_height);
        root.set_hexpand(true);
        root.set_vexpand(true);
        root.set_halign(Gtk.Align.FILL);
        // FILL (not START) so side-by-side heroes in hero_container stretch to
        // match whichever one is naturally taller, instead of each keeping its
        // own smaller natural size and ending up visibly different heights.
        root.set_valign(Gtk.Align.FILL);
        root.set_margin_start(0);
        root.set_margin_end(0);
    }

    /**
    * Builds image/overlay/title_box/title_label the same way regardless of
    * layout - only the grid/split arrangement and explicit sizing differ
    * between the constructors, so that part is factored out here.
    */
    private void build_image_overlay_and_title(string title, Gtk.Widget? chip, string? published = null) {
        image = new Gtk.Picture();
        image.set_halign(Gtk.Align.FILL);
        image.set_hexpand(true);
        image.set_vexpand(true);
        image.set_content_fit(Gtk.ContentFit.COVER);
        image.set_can_shrink(true);
        // Tried disabling keep-aspect-ratio here at one point to force a
        // smaller size in the Top Ten layout, but that broke content-fit
        // COVER's aspect-preserving crop for every hero card, stretching
        // (squishing) the image instead of cropping it. Left at its GTK
        // default (true); HeroCard.for_topten pins its image to an exact
        // pixel height via set_size_request instead, which constrains the
        // size correctly without touching this property.


        overlay = new Gtk.Overlay();
        overlay.set_child(image);
        overlay.set_hexpand(true);
        overlay.set_vexpand(true);
        if (chip != null) {
            overlay.add_overlay(chip);
        }

        title_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 10);
        title_box.set_margin_start(20);
        title_box.set_margin_end(16);
        title_box.set_margin_top(20);
        title_box.set_margin_bottom(16);
        title_box.set_hexpand(true);
        title_box.set_vexpand(true);
        // FILL (not START/CENTER) so the box occupies the pane's full height.
        // Title/snippet still sit at the top since neither is vexpand, but
        // this lets a vexpand footer widget (e.g. carousel dots, appended by
        // HeroCarousel) claim the leftover space and sit flush at the bottom
        // instead of right under the snippet.
        title_box.set_valign(Gtk.Align.FILL);

        title_label = new Gtk.Label(title);
        title_label.add_css_class("hero-title");
        title_label.set_ellipsize(Pango.EllipsizeMode.END);
        title_label.set_xalign(0);
        title_label.set_valign(Gtk.Align.START);
        title_label.set_hexpand(true);
        title_label.set_wrap(true);
        title_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        title_label.set_lines(4);
        title_box.append(title_label);

        // Bottom-left relative-time caption ("7h ago"), pinned to the
        // bottom of title_box via vexpand + valign END regardless of title
        // length - matches ArticleCard's treatment. HeroCarousel appends its
        // dot-indicator row into this same footer_box (see
        // HeroCarousel.add_dots_row_for) so both stack together at the
        // bottom instead of each claiming their own separate vexpand share.
        footer_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);
        footer_box.set_halign(Gtk.Align.FILL);
        footer_box.set_valign(Gtk.Align.END);
        footer_box.set_vexpand(true);

        time_label = new Gtk.Label(DateUtils.time_ago(published));
        time_label.add_css_class("hero-card-time");
        time_label.set_xalign(0);
        time_label.set_halign(Gtk.Align.START);
        footer_box.append(time_label);

        title_box.append(footer_box);
    }

    /**
    * Click/hover/context-menu wiring shared by every HeroCard layout.
    */
    private void finish_interactive_setup() {
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

    // Show (or update, or clear) the snippet line under the title. Called
    // once ArticleSnippetService resolves, since fetching it is an async
    // network request rather than something available at construction time.
    public void set_snippet(string? text) {
        // The snippet resolves asynchronously (a network fetch), so by the
        // time it arrives this card may already have been torn down (e.g.
        // a category switch cleared hero_container). Guard the same way
        // articlePane.vala does for its own async snippet callback: bail if
        // the widget tree we'd be touching is no longer live.
        if (title_box.get_root() == null) return;

        string? cleaned = text != null ? text.strip() : null;
        if (cleaned == null || cleaned.length == 0) {
            if (snippet_label != null) {
                title_box.remove(snippet_label);
                snippet_label = null;
            }
            return;
        }

        if (snippet_label == null) {
            snippet_label = new Gtk.Label(cleaned);
            snippet_label.add_css_class("hero-snippet");
            snippet_label.set_ellipsize(Pango.EllipsizeMode.END);
            snippet_label.set_xalign(0);
            snippet_label.set_valign(Gtk.Align.START);
            snippet_label.set_hexpand(true);
            snippet_label.set_wrap(true);
            snippet_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
            snippet_label.set_lines(4);
            // Insert right after the title rather than append, since by the
            // time this resolves (an async fetch) a footer widget - the
            // carousel dots - may already have been added after the title,
            // which would otherwise push the snippet below the dots instead
            // of keeping it directly under the title where it belongs.
            title_box.insert_child_after(snippet_label, title_label);
        } else {
            snippet_label.set_text(cleaned);
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
