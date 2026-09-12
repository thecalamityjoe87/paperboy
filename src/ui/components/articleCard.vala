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
    // Fixed height reserved for the title area (margins + up to 3 wrapped
    // title lines + the relative-time caption below it), so total card
    // height is a hard constant that never depends on how much text a given
    // title has.
    public const int TITLE_AREA_HEIGHT = 78;

    public Gtk.Box root;
    public Gtk.Overlay overlay;
    public Gtk.Picture image;
    public Gtk.Box title_box;
    public Gtk.Label title_label;
    public Gtk.Label time_label;
    // Top-right corner row (save ribbon, see CardBuilder) and the ribbon
    // itself - exposed so AnimationManager can animate it when the article
    // is saved/unsaved.
    public Gtk.Box corner_badges;
    public Gtk.Widget save_ribbon;
    // Bottom-right of the title area, opposite time_label - where
    // ViewStateManager adds/removes the "Read" badge (see build_viewed_badge).
    public Gtk.Box viewed_badge_slot;
    public string url;
    public string title_text;
    public string? source_name;
    public string? category_id;
    public string? thumbnail_url;

    // Plain callback types used by wire_interactions() instead of GObject
    // signals - see the comment there for why.
    public delegate void UrlCallback(string url);
    public delegate void FollowSourceCallback(string url, string? source_name);

    public ArticleCard(string title, string url, int col_w, int img_h, Gtk.Widget chip, ArticleStateStore? state_store = null, NewsWindow? window = null, string? published = null) {
        GLib.Object();
        this.url = url;
        this.title_text = title;

        root = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        root.add_css_class("card");
        root.set_hexpand(true);
        root.set_halign(Gtk.Align.FILL);
        root.set_size_request(col_w, -1);

        image = new Gtk.Picture();
        image.set_halign(Gtk.Align.FILL);
        image.set_valign(Gtk.Align.START);
        image.set_hexpand(true);
        image.set_vexpand(false);
        image.set_size_request(col_w, img_h);
        image.set_content_fit(Gtk.ContentFit.COVER);
        image.set_can_shrink(true);

        overlay = new Gtk.Overlay();
        overlay.set_child(image);
        // Pin the picture to its exact height: if this were allowed to stretch,
        // a taller row (from a longer title elsewhere) would hand the overlay
        // extra space, and ContentFit.COVER would render a visibly different
        // crop/zoom of the photo per card instead of every image matching.
        overlay.set_valign(Gtk.Align.START);
        overlay.set_vexpand(false);
        // Clamp the container itself, not just the image: Gtk.Picture
        // defaults to keep-aspect-ratio=true, and its aspect-driven minimum
        // size is computed from whichever texture is loaded, which happens
        // asynchronously and can land at a different moment for each card
        // in a row (a section's cards load their images independently).
        // Without this, a card whose image finishes loading later than its
        // neighbors could get a different natural height right as its real
        // texture swaps in, producing rows of visibly mismatched card
        // heights. Explicitly sizing the overlay caps it regardless of
        // what the image ends up wanting.
        overlay.set_size_request(-1, img_h);

        // Add the provided category chip overlay (owner computes chip)
        if (chip != null) overlay.add_overlay(chip);

        // Persistent save badge, top-right (see CardBuilder.build_corner_badge_row).
        bool already_saved = false;
        if (state_store != null) {
            string norm_for_save = window != null ? window.normalize_article_url(url) : url;
            already_saved = state_store.is_saved(norm_for_save);
        }
        corner_badges = CardBuilder.build_corner_badge_row();
        overlay.add_overlay(corner_badges);
        save_ribbon = CardBuilder.build_save_ribbon(already_saved);
        corner_badges.append(save_ribbon);

        // Quick-open buttons, centered over the image - hidden until the
        // card is hovered (see .card-hover-actions in style.css), giving a
        // one-click path straight to reader view or the preview pane
        // instead of always going through the preview pane first. Stored
        // via set_data (not public fields wire_interactions could capture
        // directly) for the same reason save_ribbon/corner_badges are
        // looked up that way elsewhere - see wire_interactions() below.
        // Always built (not skipped) so toggling the "hover actions" pref
        // can just flip this box's visibility live on every already-
        // rendered card (see set_hover_actions_visible_for_all below)
        // instead of requiring a full view rebuild.
        bool hover_actions_enabled = window == null || window.prefs == null || window.prefs.card_hover_actions_enabled;
        var hover_actions = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 10);
        hover_actions.add_css_class("card-hover-actions");
        hover_actions.set_halign(Gtk.Align.CENTER);
        hover_actions.set_valign(Gtk.Align.CENTER);
        hover_actions.set_hexpand(true);
        hover_actions.set_vexpand(true);
        hover_actions.set_visible(hover_actions_enabled);

        var quick_reader_btn = new Gtk.Button();
        quick_reader_btn.add_css_class("card-hover-action-btn");
        quick_reader_btn.set_tooltip_text("Open in reader view");
        var quick_reader_icon = new Gtk.Image.from_icon_name("view-paged-symbolic");
        quick_reader_icon.set_pixel_size(26);
        quick_reader_btn.set_child(quick_reader_icon);
        hover_actions.append(quick_reader_btn);

        var quick_pane_btn = new Gtk.Button();
        quick_pane_btn.add_css_class("card-hover-action-btn");
        quick_pane_btn.set_tooltip_text("Preview article");
        var quick_pane_icon = new Gtk.Image.from_icon_name("view-reveal-symbolic");
        quick_pane_icon.set_pixel_size(26);
        quick_pane_btn.set_child(quick_pane_icon);
        hover_actions.append(quick_pane_btn);

        overlay.add_overlay(hover_actions);
        root.set_data("quick-reader-btn", quick_reader_btn);
        root.set_data("quick-pane-btn", quick_pane_btn);
        root.set_data("hover-actions-box", hover_actions);

        root.append(overlay);

        // Title container
        title_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
        title_box.set_margin_start(12);
        title_box.set_margin_end(12);
        title_box.set_margin_top(12);
        title_box.set_margin_bottom(12);
        // Fixed height reserved for the maximum text this area can ever show
        // (the label below is capped at 3 lines and ellipsizes past that), so
        // total card height never varies with how much text a title has. A
        // short title just leaves blank space in its own reserved area below
        // it instead of shrinking the whole card.
        title_box.set_vexpand(false);
        title_box.set_valign(Gtk.Align.START);
        title_box.set_size_request(-1, TITLE_AREA_HEIGHT);

        title_label = new Gtk.Label(title);
        title_label.add_css_class("article-card-title");
        title_label.set_ellipsize(Pango.EllipsizeMode.END);
        title_label.set_xalign(0);
        title_label.set_valign(Gtk.Align.START);
        title_label.set_wrap(true);
        title_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        // Size request tuned by caller
        title_label.set_size_request(col_w - 24, -1);
        title_label.set_lines(3);
        title_box.append(title_label);

        // Bottom row of the reserved title area: relative-time caption
        // ("7h ago") on the left, "Read" badge (added/removed by
        // ViewStateManager into viewed_badge_slot) on the right - the row
        // itself is pinned to the bottom via vexpand + valign END, so it
        // sits at a fixed position regardless of how many lines the title
        // above it takes up, rather than trailing right after a short
        // title. Always created (even with empty time text) so every card
        // reserves the same title-area height regardless of whether this
        // particular article has a known publish date.
        var bottom_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        bottom_row.set_valign(Gtk.Align.END);
        bottom_row.set_vexpand(true);

        time_label = new Gtk.Label(DateUtils.time_ago(published));
        time_label.add_css_class("article-card-time");
        time_label.set_xalign(0);
        time_label.set_hexpand(true);
        bottom_row.append(time_label);

        viewed_badge_slot = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        viewed_badge_slot.set_halign(Gtk.Align.END);
        viewed_badge_slot.set_valign(Gtk.Align.CENTER);
        bottom_row.append(viewed_badge_slot);

        title_box.append(bottom_row);

        root.append(title_box);

        // Expose just what external code needs to look up via the widget
        // (search, dedup-time backfill, viewed-badge updates) instead of
        // attaching a reference to this ArticleCard itself - see
        // wire_interactions() below.
        root.set_data("article-url", url);
        root.set_data("article-title-text", title);
        root.set_data("article-time-label", time_label);
        root.set_data("article-viewed-badge-slot", viewed_badge_slot);
    }

    // Lets the "show hover quick-actions" preference take effect immediately
    // on every currently-rendered card, without rebuilding/re-fetching the
    // view - each card's hover_actions box always exists (see the
    // constructor above) and is just hidden/shown here via the same
    // url_to_card registry used for viewed-badge updates.
    public static void set_hover_actions_visible_for_all(NewsWindow window, bool visible) {
        if (window == null || window.view_state == null || window.view_state.url_to_card == null) return;
        foreach (var cards in window.view_state.url_to_card.values) {
            foreach (var card in cards) {
                var hover_actions = card.get_data<Gtk.Box>("hover-actions-box");
                if (hover_actions != null) hover_actions.set_visible(visible);
            }
        }
    }

    // Called explicitly by the caller once source_name/category_id/
    // thumbnail_url are set, instead of the old
    // `article_card.activated.connect(...)` pattern.
    //
    // Must stay static: an instance method here would fold a strong ref to
    // `self` into the shared closure block of every lambda below, and
    // those lambdas attach to controllers owned by `root_widget` - itself
    // owned by this ArticleCard's own `root` field - closing an
    // uncollectible root -> controller -> closure -> self -> root cycle.
    // Actions that used to be signals emitted via `self.activated(url)`
    // are plain callback delegates instead, built in the caller's own
    // scope (e.g. ArticleManager), so nothing here ever needs `self`.
    public static void wire_interactions(
        Gtk.Box root_widget,
        string card_url,
        ArticleStateStore? article_state_store,
        NewsWindow? parent_window,
        string? source_name,
        owned UrlCallback? on_activated,
        owned UrlCallback? on_open_in_app,
        owned UrlCallback? on_open_in_browser,
        owned FollowSourceCallback? on_follow_source,
        owned UrlCallback? on_save_for_later,
        owned UrlCallback? on_share,
        owned UrlCallback? on_quick_reader = null
    ) {
        var gesture = new Gtk.GestureClick();
        gesture.set_button(1);
        gesture.released.connect(() => {
            if (on_activated != null) on_activated(card_url);
        });
        root_widget.add_controller(gesture);

        var quick_reader_btn = root_widget.get_data<Gtk.Button>("quick-reader-btn");
        if (quick_reader_btn != null) {
            quick_reader_btn.clicked.connect(() => {
                // Deferred - opening the sheet synchronously mid-click can
                // leave the button's own gesture unable to fire again.
                GLib.Idle.add(() => {
                    if (on_quick_reader != null) on_quick_reader(card_url);
                    return false;
                });
            });
        }

        var quick_pane_btn = root_widget.get_data<Gtk.Button>("quick-pane-btn");
        if (quick_pane_btn != null) {
            quick_pane_btn.clicked.connect(() => {
                if (on_activated != null) on_activated(card_url);
            });
        }

        // get_widget() avoids capturing root_widget directly - same cycle
        // as the class comment above describes for `self`, since these
        // attach to controllers root_widget itself owns.
        var motion = new Gtk.EventControllerMotion();
        motion.enter.connect(() => {
            var w = motion.get_widget();
            if (w != null) w.add_css_class("card-hover");
        });
        motion.leave.connect(() => {
            var w = motion.get_widget();
            if (w != null) w.remove_css_class("card-hover");
        });
        root_widget.add_controller(motion);

        var right_click = new Gtk.GestureClick();
        right_click.set_button(3);
        right_click.pressed.connect((n_press, x, y) => {
            var w = right_click.get_widget() as Gtk.Box;
            if (w == null) return;
            show_context_menu(
                w, card_url, article_state_store, parent_window, source_name, x, y,
                on_open_in_app, on_open_in_browser, on_follow_source, on_save_for_later, on_share
            );
        });
        root_widget.add_controller(right_click);
    }

    // Static for the same reason as wire_interactions() above.
    private static void show_context_menu(
        Gtk.Box root_widget,
        string url,
        ArticleStateStore? article_state_store,
        NewsWindow? parent_window,
        string? source_name,
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
        // Normalize URL before checking view/save state so we match the stored keys
        string norm_url = url;
        if (parent_window != null) norm_url = parent_window.normalize_article_url(url);
        if (article_state_store != null) {
            is_saved = article_state_store.is_saved(norm_url);
            is_viewed = article_state_store.is_viewed(norm_url);
        }

        var menu = new ArticleMenu(url, source_name, is_saved, is_viewed, parent_window);

        // Connect menu signals to the caller-supplied callbacks
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

        // Handle marking a single article as unread
        menu.mark_unread_requested.connect((article_url) => {
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

        // Keep menu/popover alive on root_widget (not an ArticleCard field)
        // until the popover closes.
        var popover = menu.create_popover(root_widget, x, y);
        root_widget.set_data("article-current-menu", menu);
        root_widget.set_data("article-current-popover", popover);
        popover.popup();
    }
}
