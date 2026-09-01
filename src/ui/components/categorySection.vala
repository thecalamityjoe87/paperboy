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

/**
 * One Front Page category section: an uppercase label followed by a
 * horizontally-scrollable, hover-nav-button-driven row of article cards
 * (see ScrollNavButtons). Built hidden - LayoutManager shows `wrapper` once
 * the first card arrives, since categories populate asynchronously as
 * articles stream in and not every one is guaranteed to appear.
 *
 */
public class CategorySection : GLib.Object {
    public Gtk.Box wrapper;
    public Gtk.Box row;

    private weak NewsWindow? window;
    private string query_category;
    // Kept for refresh_load_more_affordance(): when a section is revealed
    // while still empty (see LayoutManager.reveal_sections_with_pending_overflow),
    // its row's adjustment never actually changes, so the signal-driven
    // update in add_nav_buttons never re-fires on its own.
    private Gtk.Adjustment? scroll_adjustment;
    private Gtk.Button? right_nav_button;

    public CategorySection(NewsWindow? window, string display_name, string query_category) {
        this.window = window;
        this.query_category = query_category;

        wrapper = new Gtk.Box(Gtk.Orientation.VERTICAL, 20);
        wrapper.set_halign(Gtk.Align.FILL);
        wrapper.set_hexpand(true);
        wrapper.set_visible(false);

        var label = new Gtk.Label("");
        label.set_xalign(0);
        label.add_css_class("caption");
        label.set_markup("<span size='18000'><b>%s</b></span>".printf(display_name.up()));
        wrapper.append(label);

        var scroller = new Gtk.ScrolledWindow();
        // Horizontal policy must stay AUTOMATIC, not NEVER: in GTK4, NEVER
        // doesn't just hide the scrollbar, it stops clipping that axis
        // entirely and lets the ScrolledWindow grow to fit its full content
        // width, blowing out the whole page into one big horizontal scroll
        // area. Keep AUTOMATIC for correct clipping/scrolling and hide the
        // bar itself via CSS instead (see .section-scroller in style.css).
        scroller.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.NEVER);
        scroller.add_css_class("section-scroller");
        scroller.set_hexpand(true);
        scroller.set_propagate_natural_height(true);

        row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 20);
        row.set_valign(Gtk.Align.START);
        // A few extra px of breathing room: the ScrolledWindow's
        // propagate_natural_height sizes itself off this row's request, and
        // without this the very bottom edge of each card (border/shadow)
        // was getting clipped by the viewport.
        row.set_margin_bottom(8);
        scroller.set_child(row);

        var overlay = new Gtk.Overlay();
        overlay.set_child(scroller);
        overlay.set_hexpand(true);
        wrapper.append(overlay);

        add_nav_buttons(overlay, scroller);
    }

    /**
    * Append a card to this section, revealing the section if this is its
    * first (idempotent - safe to call on an already-visible section, which
    * is also how search-filter restoration re-shows a section after
    * clearing it).
    */
    public void add_card(Gtk.Widget card_root) {
        row.append(card_root);
        wrapper.set_visible(true);
    }

    /**
    * Wire the shared ScrollNavButtons onto this section's scroll row: each
    * click pages the scroller by one viewport width using GTK's own
    * smooth/kinetic scroll animation (scroll_child) rather than jumping
    * instantly, and bind_adjustment disables/hides a button once that end
    * of the row has nothing left to scroll to.
    *
    * On top of that default behavior, the right button doubles as a
    * per-category "load more": once the row is scrolled to its end, if
    * ArticleManager still has queued overflow articles for this category
    * (from the Front Page's initial-load cap), the button switches to a
    * reload icon that loads just that category's next batch instead of
    * staying disabled.
    *
    * Also adds edge-fade gradients as a cheap "more to scroll" cue (not an
    * actual blur of the scrolling content - that would need a custom
    * snapshot()/GSK blur node for a subtle effect nobody would tell apart
    * from this). Their visibility is tied to the same adjustment as the
    * nav buttons: each fade only shows when there's actually more content
    * in that direction, so the last real card at the true end of a row is
    * never obscured and the left fade stays hidden until the row has been
    * scrolled in from the start.
    */
    private void add_nav_buttons(Gtk.Overlay overlay, Gtk.ScrolledWindow scroller) {
        Gtk.Adjustment adj = scroller.get_hadjustment();

        var left_fade = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        left_fade.add_css_class("section-scroll-fade");
        left_fade.add_css_class("section-scroll-fade-left");
        left_fade.set_halign(Gtk.Align.START);
        left_fade.set_valign(Gtk.Align.FILL);
        left_fade.set_vexpand(true);
        left_fade.set_can_target(false);
        overlay.add_overlay(left_fade);

        var right_fade = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        right_fade.add_css_class("section-scroll-fade");
        right_fade.set_halign(Gtk.Align.END);
        right_fade.set_valign(Gtk.Align.FILL);
        right_fade.set_vexpand(true);
        right_fade.set_can_target(false);
        overlay.add_overlay(right_fade);

        var nav_buttons = new ScrollNavButtons(overlay, "section-nav", 4);
        scroll_adjustment = adj;
        right_nav_button = nav_buttons.right_button;

        nav_buttons.prev_requested.connect(() => {
            scroller.scroll_child(Gtk.ScrollType.PAGE_BACKWARD, true);
        });
        nav_buttons.next_requested.connect(() => {
            bool can_scroll_more = adj.get_value() < adj.get_upper() - adj.get_page_size() - 1.0;
            if (can_scroll_more) {
                scroller.scroll_child(Gtk.ScrollType.PAGE_FORWARD, true);
            } else if (window != null && window.article_manager != null) {
                window.article_manager.load_more_for_category(query_category);
            }
        });

        // Default disable-at-ends behavior first...
        nav_buttons.bind_adjustment(adj);
        // ...then layer the load-more override on top, connected after
        // bind_adjustment so it runs second and has the final say on the
        // right button's icon/sensitivity for this row.
        adj.value_changed.connect(() => update_load_more_affordance(adj, nav_buttons.right_button));
        adj.changed.connect(() => update_load_more_affordance(adj, nav_buttons.right_button));
        update_load_more_affordance(adj, nav_buttons.right_button);

        adj.value_changed.connect(() => update_scroll_fades(adj, left_fade, right_fade));
        adj.changed.connect(() => update_scroll_fades(adj, left_fade, right_fade));
        update_scroll_fades(adj, left_fade, right_fade);
    }

    /**
    * Re-check whether the right nav button should offer "load more" -
    * needed when a still-empty section is revealed (its row's adjustment
    * never changes on its own, since nothing has scrolled), so the button
    * would otherwise sit there disabled despite overflow now being queued.
    */
    public void refresh_load_more_affordance() {
        if (scroll_adjustment == null || right_nav_button == null) return;
        update_load_more_affordance(scroll_adjustment, right_nav_button);
    }

    private void update_scroll_fades(Gtk.Adjustment adj, Gtk.Widget left_fade, Gtk.Widget right_fade) {
        left_fade.set_visible(adj.get_value() > adj.get_lower() + 1.0);
        right_fade.set_visible(adj.get_value() < adj.get_upper() - adj.get_page_size() - 1.0);
    }

    private void update_load_more_affordance(Gtk.Adjustment adj, Gtk.Button right_btn) {
        bool can_scroll_more = adj.get_value() < adj.get_upper() - adj.get_page_size() - 1.0;
        if (can_scroll_more) {
            right_btn.set_icon_name("go-next-symbolic");
            return;
        }

        int remaining = (window != null && window.article_manager != null)
            ? window.article_manager.remaining_count_for_category(query_category)
            : 0;
        if (remaining > 0) {
            right_btn.set_icon_name("view-refresh-symbolic");
            //right_btn.set_tooltip_text("Load more");
            right_btn.set_sensitive(true);
        } else {
            right_btn.set_icon_name("go-next-symbolic");
            //right_btn.set_tooltip_text("See more");
            right_btn.set_sensitive(false);
        }
    }
}
