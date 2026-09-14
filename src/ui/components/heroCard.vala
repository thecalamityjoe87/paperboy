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
    // Save ribbon (see CardBuilder.build_save_ribbon) - exposed so
    // AnimationManager can animate it when the article is saved/unsaved.
    public Gtk.Widget save_ribbon;
    // Bottom-right of the footer row, opposite time_label - where
    // ViewStateManager adds/removes the "Read" badge (see build_viewed_badge).
    public Gtk.Box viewed_badge_slot;
    private bool enable_context_menu;
    private ArticleStateStore? article_state_store;
    private NewsWindow? parent_window;

    // Plain callback types used by wire_interactions() instead of GObject
    // signals - see the comment there for why.
    public delegate void UrlCallback(string url);
    public delegate void FollowSourceCallback(string url, string? source_name);

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

        // Cap at 2 lines (not the shared 4-line default) so a long title
        // can't grow past text_height and desync card heights in the row.
        title_label.set_lines(2);
        // Don't let title_box compete with the image for any extra height a
        // FlowBox row hands this card (e.g. to match a taller sibling) -
        // all of that should go to the picture, keeping the text pane
        // pinned to exactly text_height.
        title_box.set_vexpand(false);

        var split = new Gtk.Grid();
        split.set_hexpand(true);
        split.set_vexpand(true);
        split.attach(overlay, 0, 0, 1, 1);
        split.attach(title_box, 0, 1, 1, 1);
        root.append(split);
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

        // Persistent save badge, top-right (see CardBuilder.build_save_ribbon).
        bool already_saved = false;
        if (article_state_store != null) {
            string norm_for_save = parent_window != null ? parent_window.normalize_article_url(url) : url;
            already_saved = article_state_store.is_saved(norm_for_save);
        }
        save_ribbon = CardBuilder.build_save_ribbon(already_saved);
        overlay.add_overlay(save_ribbon);

        // Same quick-open buttons ArticleCard shows on hover, centered over
        // the image - see ArticleCard's constructor for the full reasoning.
        bool hover_actions_enabled = parent_window == null || parent_window.prefs == null || parent_window.prefs.card_hover_actions_enabled;
        var hover_actions = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 10);
        hover_actions.add_css_class("card-hover-actions");
        hover_actions.set_halign(Gtk.Align.CENTER);
        hover_actions.set_valign(Gtk.Align.CENTER);
        hover_actions.set_hexpand(true);
        hover_actions.set_vexpand(true);
        hover_actions.set_visible(hover_actions_enabled);

        var quick_reader_btn = new Gtk.Button();
        quick_reader_btn.add_css_class("card-hover-action-btn");
        quick_reader_btn.add_css_class("hero-card-hover-action-btn");
        quick_reader_btn.set_tooltip_text("Open in reader view");
        var quick_reader_icon = new Gtk.Image.from_icon_name("view-paged-symbolic");
        quick_reader_icon.set_pixel_size(28);
        quick_reader_btn.set_child(quick_reader_icon);
        hover_actions.append(quick_reader_btn);

        var quick_pane_btn = new Gtk.Button();
        quick_pane_btn.add_css_class("card-hover-action-btn");
        quick_pane_btn.add_css_class("hero-card-hover-action-btn");
        quick_pane_btn.set_tooltip_text("Preview article");
        var quick_pane_icon = new Gtk.Image.from_icon_name("view-reveal-symbolic");
        quick_pane_icon.set_pixel_size(28);
        quick_pane_btn.set_child(quick_pane_icon);
        hover_actions.append(quick_pane_btn);

        overlay.add_overlay(hover_actions);
        root.set_data("hero-quick-reader-btn", quick_reader_btn);
        root.set_data("hero-quick-pane-btn", quick_pane_btn);
        root.set_data("hero-hover-actions-box", hover_actions);

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

        // Time caption + "Read" badge (added/removed by ViewStateManager
        // into viewed_badge_slot) share one row, opposite ends - this row
        // is footer_box's first child, so HeroCarousel's dots (appended
        // after) still stack below it rather than sharing its row.
        var time_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);

        time_label = new Gtk.Label(DateUtils.time_ago(published));
        time_label.add_css_class("hero-card-time");
        time_label.set_xalign(0);
        time_label.set_hexpand(true);
        time_row.append(time_label);

        viewed_badge_slot = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        viewed_badge_slot.set_halign(Gtk.Align.END);
        viewed_badge_slot.set_valign(Gtk.Align.CENTER);
        time_row.append(viewed_badge_slot);

        footer_box.append(time_row);

        title_box.append(footer_box);
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

    // Called explicitly by the caller once source_name/category_id/
    // thumbnail_url are set - the HeroCard equivalent of
    // ArticleCard.wire_interactions() (see there for the full reasoning).
    // Must stay static so none of these closures fold in a `self` ref that
    // would chain root -> controller -> closure -> self -> root into an
    // uncollectible cycle. Only plain, non-back-referencing data (strings,
    // Gtk.Label/Box/Picture widgets) goes on `root_widget` via set_data for
    // later lookup (search, badge updates, carousel dot/title updates).
    public static void wire_interactions(
        Gtk.Box root_widget,
        string card_url,
        bool enable_context_menu,
        ArticleStateStore? article_state_store,
        NewsWindow? parent_window,
        string? source_name,
        string? category_id,
        string? thumbnail_url,
        Gtk.Label title_label,
        Gtk.Picture image,
        Gtk.Box viewed_badge_slot,
        Gtk.Box footer_box,
        Gtk.Overlay overlay,
        owned UrlCallback? on_activated,
        owned UrlCallback? on_open_in_app,
        owned UrlCallback? on_open_in_browser,
        owned FollowSourceCallback? on_follow_source,
        owned UrlCallback? on_save_for_later,
        owned UrlCallback? on_share,
        owned UrlCallback? on_quick_reader = null
    ) {
        // Expose just the pieces external code needs to look up via the
        // widget (search, carousel title/dots updates, viewed-badge
        // updates, ArticleCard-from-hero conversion) as plain data on
        // `root_widget` itself.
        root_widget.set_data("hero-url", card_url);
        root_widget.set_data("hero-title-label", title_label);
        root_widget.set_data("hero-image", image);
        root_widget.set_data("hero-viewed-badge-slot", viewed_badge_slot);
        root_widget.set_data("hero-footer-box", footer_box);
        root_widget.set_data("hero-overlay", overlay);
        if (source_name != null) root_widget.set_data("hero-source-name", source_name);
        if (category_id != null) root_widget.set_data("hero-category-id", category_id);
        if (thumbnail_url != null) root_widget.set_data("hero-thumbnail-url", thumbnail_url);

        var gesture = new Gtk.GestureClick();
        gesture.set_button(1);
        gesture.released.connect(() => {
            if (on_activated != null) on_activated(card_url);
        });
        root_widget.add_controller(gesture);

        var quick_reader_btn = root_widget.get_data<Gtk.Button>("hero-quick-reader-btn");
        if (quick_reader_btn != null) {
            quick_reader_btn.clicked.connect(() => {
                // Deferred - opening the sheet synchronously mid-click left
                // the button's gesture unable to fire again after rotation.
                GLib.Idle.add(() => {
                    if (on_quick_reader != null) on_quick_reader(card_url);
                    return false;
                });
            });
        }

        var quick_pane_btn = root_widget.get_data<Gtk.Button>("hero-quick-pane-btn");
        if (quick_pane_btn != null) {
            quick_pane_btn.clicked.connect(() => {
                if (on_activated != null) on_activated(card_url);
            });
        }

        var motion = new Gtk.EventControllerMotion();
        motion.enter.connect(() => { root_widget.add_css_class("card-hover"); });
        motion.leave.connect(() => { root_widget.remove_css_class("card-hover"); });
        root_widget.add_controller(motion);

        if (enable_context_menu) {
            var right_click = new Gtk.GestureClick();
            right_click.set_button(3);
            right_click.pressed.connect((n_press, x, y) => {
                show_context_menu(
                    root_widget, card_url, article_state_store, parent_window, source_name, viewed_badge_slot, x, y,
                    on_open_in_app, on_open_in_browser, on_follow_source, on_save_for_later, on_share
                );
            });
            root_widget.add_controller(right_click);
        }
    }

    // Static for the same reason as wire_interactions() above.
    private static void show_context_menu(
        Gtk.Box root_widget,
        string url,
        ArticleStateStore? article_state_store,
        NewsWindow? parent_window,
        string? source_name,
        Gtk.Box viewed_badge_slot,
        double x,
        double y,
        owned UrlCallback? on_open_in_app,
        owned UrlCallback? on_open_in_browser,
        owned FollowSourceCallback? on_follow_source,
        owned UrlCallback? on_save_for_later,
        owned UrlCallback? on_share
    ) {
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

        var menu = new ArticleMenu(url, source_name, is_saved, is_viewed, parent_window);

        menu.open_in_app_requested.connect((article_url) => {
            if (on_open_in_app != null) on_open_in_app(article_url);
        });
        menu.open_in_browser_requested.connect((article_url) => {
            if (on_open_in_browser != null) on_open_in_browser(article_url);
        });
        menu.follow_source_requested.connect((article_url, menu_source_name) => {
            if (on_follow_source != null) on_follow_source(article_url, menu_source_name);
        });
        menu.save_for_later_requested.connect((article_url) => {
            if (on_save_for_later != null) on_save_for_later(article_url);
        });
        menu.share_requested.connect((article_url) => {
            if (on_share != null) on_share(article_url);
        });

        menu.mark_unread_requested.connect((article_url) => {
            string nurl = article_url;
            if (parent_window != null) nurl = parent_window.normalize_article_url(article_url);

            if (article_state_store != null) {
                article_state_store.mark_unviewed(nurl);
            }

            // Remove from in-memory viewed set so UI updates immediately
            if (parent_window != null && parent_window.view_state != null) parent_window.view_state.viewed_articles.remove(nurl);

            // Also remove any viewed-badge directly from this hero's slot
            if (viewed_badge_slot != null) {
                Gtk.Widget? child = viewed_badge_slot.get_first_child();
                while (child != null) {
                    Gtk.Widget? next = child.get_next_sibling();
                    if (child.get_style_context().has_class("viewed-badge")) {
                        viewed_badge_slot.remove(child);
                    }
                    child = next;
                }
                viewed_badge_slot.queue_draw();
            }

            // Badge update is handled via ArticleStateStore.viewed_status_changed signal
            if (parent_window != null && parent_window.view_state != null && source_name != null) {
                parent_window.view_state.refresh_viewed_badges_for_source(source_name);
                // Also refresh the single URL so carousel-registered hero widgets update immediately
                parent_window.view_state.refresh_viewed_badge_for_url(nurl);
            }
        });

        // Keep menu/popover alive on root_widget (not a HeroCard field)
        // until the popover closes.
        var popover = menu.create_popover(root_widget, x, y);
        root_widget.set_data("hero-current-menu", menu);
        root_widget.set_data("hero-current-popover", popover);
        popover.popup();
    }
}
