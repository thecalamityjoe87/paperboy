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
    // True while the load-more spinner is showing. Appending the new cards
    // inside load_more_for_category changes the row's content width, which
    // fires the adjustment's own changed/value_changed signals almost
    // immediately - those are wired to update_load_more_affordance too, and
    // without this guard they'd stomp the spinner back to the arrow before
    // it ever got a chance to render a frame.
    private bool loading_more = false;

    // center_nav_on_full_row: article cards place a fixed-height picture
    // flush at the top of the row (see ArticleCard), so by default the nav
    // arrows center on just that picture height, not the full row (picture
    // + title area below it) - see add_nav_buttons. Score cards (see
    // ScoreCard) have no picture at all, just text top to bottom, so that
    // picture-height math would center the arrows too high; pass true to
    // center them on the row's actual full height instead.
    // card_container: wraps the scroll row (not the title above it) in a
    // bordered/rounded panel so the row's cards read as one grouped unit -
    // used for the Sports score sections; article-row sections leave it off
    // and keep their plain flush layout.
    public CategorySection(NewsWindow? window, string display_name, string query_category, bool center_nav_on_full_row = false, bool card_container = false, string? logo_url = null) {
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

        // Only the Sports score sections pass a logo_url - every other
        // CategorySection caller keeps the plain text-only header.
        if (logo_url != null && logo_url.length > 0) {
            var header = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            header.set_halign(Gtk.Align.START);
            header.set_valign(Gtk.Align.CENTER);

            // Circular logo baked into the pixel data via PixbufUtils, same
            // technique the source-badge/source-row favicons already use
            // elsewhere in the app - CSS-only circular clipping (a plain
            // "circular-logo" class) only clips widgets already scoped
            // under one of those existing selectors, so a new context like
            // this header needs the circle baked in rather than a new CSS
            // scope.
            var logo = PixbufUtils.make_circular_logo_placeholder(30);
            header.append(logo);
            header.append(label);
            wrapper.append(header);

            PixbufUtils.load_circular_logo_async(logo, logo_url, 30);
        } else {
            wrapper.append(label);
        }

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

        if (card_container) {
            var container = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            container.add_css_class("section-card-container");
            container.set_hexpand(true);
            container.append(overlay);
            wrapper.append(container);
        } else {
            wrapper.append(overlay);
        }

        add_nav_buttons(overlay, scroller, center_nav_on_full_row);
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
    * Also adds edge-fade gradients as a cheap "more to scroll" cue (not an
    * actual blur of the scrolling content. Their visibility is tied to the 
    * same adjustment as the nav buttons: each fade only shows when there's actually more content
    * in that direction, so the last real card at the true end of a row is
    * never obscured and the left fade stays hidden until the row has been
    * scrolled in from the start.
    */
    private void add_nav_buttons(Gtk.Overlay overlay, Gtk.ScrolledWindow scroller, bool center_nav_on_full_row = false) {
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

        if (!center_nav_on_full_row) {
            // Center the nav buttons on the card picture, not the full row
            // height (picture + title area below it) - ScrollNavButtons
            // defaults to valign CENTER on the whole overlay, which sits too
            // low here. Cards place their picture flush at the top of the row
            // at a fixed height (see ArticleCard), so the picture's vertical
            // center is just half of that fixed height down from the top.
            int nav_btn_size = 36; // matches .section-nav min-height in style.css
            int nav_margin_top = (Managers.ArticleManager.CARD_IMAGE_HEIGHT - nav_btn_size) / 2;
            nav_buttons.left_button.set_valign(Gtk.Align.START);
            nav_buttons.left_button.set_margin_top(nav_margin_top);
            nav_buttons.right_button.set_valign(Gtk.Align.START);
            nav_buttons.right_button.set_margin_top(nav_margin_top);
        }
        // else: leave ScrollNavButtons' default valign CENTER on the whole
        // overlay, which centers on the row's actual full height - correct
        // for picture-less cards like ScoreCard.

        nav_buttons.prev_requested.connect(() => {
            scroller.scroll_child(Gtk.ScrollType.PAGE_BACKWARD, true);
        });
        nav_buttons.next_requested.connect(() => {
            bool can_scroll_more = adj.get_value() < adj.get_upper() - adj.get_page_size() - 1.0;
            if (can_scroll_more) {
                scroller.scroll_child(Gtk.ScrollType.PAGE_FORWARD, true);
            } else if (window != null && window.article_manager != null) {
                loading_more = true;
                show_load_more_spinner(nav_buttons.right_button);
                window.article_manager.load_more_for_category(query_category);

                // The new cards widen the row, but scroll position is
                // unchanged, so without this the user would still be
                // sitting at the old end and have to hit the arrow again
                // themselves to actually see what just loaded. A full
                // scroll_child(PAGE_FORWARD) jump was too dramatic here, so
                // animate forward by half a viewport instead of a whole
                // one - enough to bring the new cards into view without
                // launching past the ones right at the old edge. Deferred
                // to idle so the row's adjustment has picked up the new
                // width first (append happened synchronously above, but
                // layout allocation hasn't run yet).
                GLib.Idle.add(() => {
                    double target_value = adj.get_value() + (adj.get_page_size() * 0.5);
                    double max_value = adj.get_upper() - adj.get_page_size();
                    if (target_value > max_value) target_value = max_value;
                    var scroll_target = new Adw.PropertyAnimationTarget((GLib.Object) adj, "value");
                    var scroll_anim = new Adw.TimedAnimation(row, adj.get_value(), target_value, 300u, scroll_target);
                    scroll_anim.play();
                    return false;
                });

                // load_more_for_category resolves synchronously from the
                // in-memory overflow queue, so without a floor here the
                // spinner would flash by unnoticed even though new cards are
                // genuinely being added - give it a moment to register
                // before swapping the arrow back in.
                GLib.Timeout.add(450, () => {
                    loading_more = false;
                    update_load_more_affordance(adj, nav_buttons.right_button);
                    return false;
                });
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
        // While the spinner is showing, leave the button alone - the
        // adjustment's own changed/value_changed signals also call into
        // here and would otherwise immediately replace the spinner with the
        // arrow again as soon as the newly-loaded cards resize the row.
        if (loading_more) return;

        bool can_scroll_more = adj.get_value() < adj.get_upper() - adj.get_page_size() - 1.0;
        if (can_scroll_more) {
            right_btn.set_label("→");
            right_btn.set_sensitive(true);
            return;
        }

        int remaining = (window != null && window.article_manager != null)
            ? window.article_manager.remaining_count_for_category(query_category)
            : 0;
        right_btn.set_label("→");
        right_btn.set_sensitive(remaining > 0);
    }

    // Swap the right nav button's arrow for a spinner while the next batch
    // of queued articles for this category is being added to the row.
    private void show_load_more_spinner(Gtk.Button btn) {
        var spinner = new Gtk.Spinner();
        // Match the arrow glyph's footprint instead of the spinner's own
        // larger default, so swapping in the spinner doesn't visibly
        // change the button's weight.
        spinner.set_size_request(16, 16);
        spinner.add_css_class("section-nav-spinner");
        spinner.set_spinning(true);
        btn.set_child(spinner);
        btn.set_sensitive(false);
    }
}
