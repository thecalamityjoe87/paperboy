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
using Gee;
using GLib;
using Adw;

// Non-cyclic holder for the carousel's navigation/scroll/timer state, so
// the static do_*() functions below can read and mutate it without a
// HeroCarousel reference - see the constructor's comment.
private class CarouselState : GLib.Object {
    public Gtk.Overlay? slide_holder;
    public Gtk.Widget? current_slide;
    // Keeps crossfade animations alive until they finish; see
    // AnimationManager.active_entrance_animations for why locals aren't enough.
    public Gee.ArrayList<GLib.Object> active_slide_animations = new Gee.ArrayList<GLib.Object>();
    public ArrayList<Widget>? widgets;
    // One dot row per slide, injected into that slide's own text pane
    // (see add_dots_row_for) rather than a shared strip below the picture.
    public ArrayList<ArrayList<Widget>>? dot_rows;
    public int index = 0;
    public uint timeout_id = 0;
    // Trackpad/wheel scroll state - see do_carousel_scroll().
    public double scroll_accum_x = 0;
    public bool scroll_cooldown = false;
}

public class HeroCarousel : GLib.Object {
    public Box? container;

    // Layout constants - kept equal since the picture spans the card's full height.
    public const int SLIDE_MAX_HEIGHT = 500;
    public const int SLIDE_IMAGE_HEIGHT = 500;

    // Callback shape for reacting to a slide's activation (clicked) - see
    // create_article_slide()/build_slide_activation_adapter() for why this
    // is a plain per-call callback rather than a GObject signal.
    public delegate void SlideActivatedCallback(string title, string url, string? thumbnail_url, string category_id, string? source_name);

    private CarouselState state = new CarouselState();

    public HeroCarousel(Gtk.Box parent) {
        GLib.Object();
        // nav_buttons/scroll_controller are owned (transitively) by
        // `container`, a field of this HeroCarousel, so their closures must
        // not capture `self` - see wire_navigation() below, which does the
        // actual wiring as a static method for that reason. HeroCarousel is
        // recreated on every category switch back to the front page/Top
        // Ten (see ArticleManager.reset_featured_state), so a self-capture
        // here leaked the whole carousel, hero slide images included, each
        // time.
        var state = this.state;

        // Create title and container
        var top_stories_title = new Gtk.Label("");
        top_stories_title.set_xalign(0);
        top_stories_title.add_css_class("caption");
        // Margins live in CSS (.top-stories-title), not set_margin_top/
        // bottom here: the top margin was silently not taking effect via
        // the widget API (bottom did), so app-level CSS - which always
        // wins over the GTK theme's own defaults - is the reliable place
        // to control this regardless of what was overriding it.
        top_stories_title.add_css_class("top-stories-title");
        // Use Pango markup to match the subtitle sizing used elsewhere.
        top_stories_title.set_markup("<span size='26000'><b>FEATURED</b></span>");
        parent.append(top_stories_title);
        state.widgets = new ArrayList<Widget>();
        state.dot_rows = new ArrayList<ArrayList<Widget>>();

        var slide_holder = new Gtk.Overlay();
        slide_holder.set_halign(Gtk.Align.FILL);
        slide_holder.set_hexpand(true);
        // Unlike Gtk.Stack, Overlay doesn't size itself to the tallest
        // child by default, so pin the height explicitly.
        slide_holder.set_size_request(-1, SLIDE_MAX_HEIGHT);
        state.slide_holder = slide_holder;

        // No "card" class here - the card look (background, border, rounded
        // corners) comes from the HeroCard slide itself, so this only needs
        // its own layout classes.
        var carousel_container = new Gtk.Box(Orientation.VERTICAL, 0);
        carousel_container.add_css_class("card-featured");
        carousel_container.set_halign(Gtk.Align.FILL);
        carousel_container.set_hexpand(true);
        // Room for the card's own shadow so it doesn't get clipped at the bottom.
        carousel_container.set_margin_bottom(8);

        var carousel_overlay = new Gtk.Overlay();
        carousel_overlay.set_child(slide_holder);

        wire_navigation(carousel_overlay, state);

        carousel_container.append(carousel_overlay);

        container = carousel_container;
        parent.append(carousel_container);
    }

    // Static for the same reason as the constructor's comment above.
    private static void wire_navigation(Gtk.Overlay carousel_overlay, CarouselState state) {
        // Hover-reveal prev/next buttons (see ScrollNavButtons). The
        // carousel loops, so there's no bounded end to disable.
        var nav_buttons = new ScrollNavButtons(carousel_overlay, "carousel-nav");
        nav_buttons.prev_requested.connect(() => { do_prev(state); });
        nav_buttons.next_requested.connect(() => { do_next(state); });

        // Trackpad/wheel horizontal scroll: accumulate delta and advance
        // one slide per swipe, then cool down briefly so a single gesture
        // doesn't skip several slides.
        var scroll_controller = new Gtk.EventControllerScroll(Gtk.EventControllerScrollFlags.BOTH_AXES);
        scroll_controller.scroll.connect((dx, dy) => do_carousel_scroll(state, dx, dy));
        carousel_overlay.add_controller(scroll_controller);
    }

    public void add_initial_slide(Gtk.Widget slide) {
        if (state.slide_holder == null) return;
        mark_slide_title(slide);
        state.slide_holder.add_overlay(slide);
        state.widgets.add(slide);
        add_dots_row_for(state, slide);
        state.index = 0;
        do_show_slide(state, slide, false);
        do_update_dots(state);
    }

    public void add_slide(Gtk.Widget slide) {
        if (state.slide_holder == null || state.widgets == null) return;
        mark_slide_title(slide);
        // Parented but hidden, not left unparented: a slide needs to stay
        // rooted in the window at all times, since its snippet text can
        // arrive (an async fetch) before it's ever shown, and
        // HeroCard.set_snippet() drops the text if the widget has no root.
        slide.set_visible(false);
        state.slide_holder.add_overlay(slide);
        state.widgets.add(slide);
        add_dots_row_for(state, slide);
        do_update_dots(state);
    }

    /**
    * Show one slide, hide the rest - never reparents, only toggles
    * visibility/opacity. animate=false is an instant cut (used for the
    * first slide); otherwise the incoming slide fades in while the
    * outgoing one fades out.
    *
    * STATIC - see the constructor's comment for why: the anim_in.done/
    * anim_out.done closures below reference `active_slide_animations`,
    * which would otherwise require `self`. Takes `state` explicitly
    * instead.
    */
    private static void do_show_slide(CarouselState state, Gtk.Widget new_slide, bool animate) {
        if (state.slide_holder == null || state.current_slide == new_slide) return;
        Gtk.Widget? old_slide = state.current_slide;
        state.current_slide = new_slide;

        if (old_slide == null || !animate) {
            if (old_slide != null) old_slide.set_visible(false);
            new_slide.set_opacity(1.0);
            new_slide.set_visible(true);
            return;
        }

        new_slide.set_opacity(0.0);
        new_slide.set_visible(true);

        uint duration = 400u;
        var target_in = new Adw.PropertyAnimationTarget((GLib.Object) new_slide, "opacity");
        var anim_in = new Adw.TimedAnimation(new_slide, 0.0, 1.0, duration, target_in);
        var target_out = new Adw.PropertyAnimationTarget((GLib.Object) old_slide, "opacity");
        var anim_out = new Adw.TimedAnimation(old_slide, 1.0, 0.0, duration, target_out);

        var animations = state.active_slide_animations;
        animations.add(target_in);
        animations.add(anim_in);
        animations.add(target_out);
        animations.add(anim_out);

        anim_in.done.connect(() => {
            animations.remove(anim_in);
            animations.remove(target_in);
            new_slide.set_opacity(1.0);
        });
        anim_out.done.connect(() => {
            animations.remove(anim_out);
            animations.remove(target_out);
            // Reset opacity for next time this slide comes back around.
            old_slide.set_visible(false);
            old_slide.set_opacity(1.0);
        });

        anim_in.play();
        anim_out.play();
    }

    // Larger title for carousel slides only (see .carousel-hero-title).
    // Also marks the slide root itself so a snippet that arrives later
    // (async fetch - see add_slide's comment) still picks up the carousel
    // snippet sizing via the .hero-card-carousel .hero-snippet descendant
    // selector in style.css, without needing a second direct-class call
    // once that label actually exists.
    private void mark_slide_title(Gtk.Widget slide) {
        slide.add_css_class("hero-card-carousel");
        // See HeroCard.wire_interactions() for why this is a plain widget
        // lookup rather than a HeroCard reference.
        var title_label = slide.get_data<Gtk.Label>("hero-title-label");
        if (title_label != null) {
            title_label.add_css_class("carousel-hero-title");
        }
    }

    // Build a dot-indicator row and place it in the slide's own text pane,
    // bottom-aligned. update_dots keeps every row in sync.
    private static void add_dots_row_for(CarouselState state, Gtk.Widget slide) {
        var footer_box = slide.get_data<Gtk.Box>("hero-footer-box");
        if (footer_box == null) return;

        var row = new Gtk.Box(Orientation.HORIZONTAL, 6);
        row.set_halign(Gtk.Align.CENTER);

        var labels = new ArrayList<Widget>();
        for (int d = 0; d < 5; d++) {
            var dot = new Gtk.Box(Orientation.HORIZONTAL, 0);
            dot.add_css_class("carousel-dot");
            dot.set_valign(Gtk.Align.CENTER);
            row.append(dot);
            labels.add(dot);
        }

        // Appended into the same bottom-pinned footer_box as the time
        // caption (see HeroCard.build_image_overlay_and_title) so the two
        // stack together at the bottom instead of each claiming their own
        // separate vexpand share of title_box.
        footer_box.append(row);
        state.dot_rows.add(labels);
    }

    // Builds the click-adapter closure outside of any HeroCarousel instance
    // method - the adapter ends up stored on the slide's own root widget
    // (via HeroCard.wire_interactions() below), which HeroCarousel retains,
    // so defining it in an instance method would leak HeroCarousel the
    // same way as the constructor's nav/scroll closures.
    private static HeroCard.UrlCallback build_slide_activation_adapter(string title, string? thumbnail_url, string category_id, string? source_name, owned SlideActivatedCallback on_slide_activated) {
        return (activated_url) => {
            on_slide_activated(title, activated_url, thumbnail_url, category_id, source_name);
        };
    }

    /**
     * Build a HeroCard slide, add it to the carousel, and return it (plus
     * its image widget) for external image loading.
     */
    public SlideComponents create_article_slide(string title, string url, string? thumbnail_url,
                                                  string category_id, string? source_name,
                                                  Gtk.Widget? category_chip, owned SlideActivatedCallback on_slide_activated,
                                                  string? published = null,
                                                  owned HeroCard.UrlCallback? on_quick_reader = null) {
        var hero = new HeroCard(title, url, SLIDE_MAX_HEIGHT, SLIDE_IMAGE_HEIGHT, category_chip, false, null, null, published);
        hero.source_name = source_name;
        hero.category_id = category_id;

        HeroCard.wire_interactions(
            hero.root, hero.url, false, null, null, source_name, category_id, thumbnail_url,
            hero.title_label, hero.image, hero.viewed_badge_slot, hero.footer_box, hero.overlay,
            build_slide_activation_adapter(title, thumbnail_url, category_id, source_name, (owned) on_slide_activated),
            null, null, null, null, null, (owned) on_quick_reader
        );

        if (state.widgets.size == 0) {
            add_initial_slide(hero.root);
        } else {
            add_slide(hero.root);
        }

        return new SlideComponents(hero.root, hero.image, hero);
    }

    public void update_dots() {
        do_update_dots(state);
    }

    private static void do_update_dots(CarouselState state) {
        if (state.dot_rows == null || state.widgets == null) return;
        int total = state.widgets.size;
        foreach (var row in state.dot_rows) {
            for (int i = 0; i < row.size; i++) {
                var dot = row[i];
                if (i >= total) {
                    dot.add_css_class("inactive");
                    dot.remove_css_class("active");
                } else {
                    dot.remove_css_class("inactive");
                    if (i == state.index) dot.add_css_class("active"); else dot.remove_css_class("active");
                }
            }
        }
    }

    private static bool do_carousel_scroll(CarouselState state, double dx, double dy) {
        // Only treat clearly horizontal gestures as navigation; let
        // vertical scrolls bubble up to scroll the page instead.
        if (dx.abs() <= dy.abs()) {
            return false;
        }

        if (!state.scroll_cooldown) {
            state.scroll_accum_x += dx;
            double threshold = 40.0;
            if (state.scroll_accum_x > threshold) {
                do_next(state);
                start_scroll_cooldown(state);
            } else if (state.scroll_accum_x < -threshold) {
                do_prev(state);
                start_scroll_cooldown(state);
            }
        }
        return true;
    }

    private static void start_scroll_cooldown(CarouselState state) {
        state.scroll_accum_x = 0;
        state.scroll_cooldown = true;
        Timeout.add(450, () => {
            state.scroll_cooldown = false;
            return false;
        });
    }

    public void next() {
        do_next(state);
    }

    public void prev() {
        do_prev(state);
    }

    private static void do_next(CarouselState state) {
        if (state.widgets == null) return;
        int total = state.widgets.size;
        if (total <= 1) return;
        state.index = (state.index + 1) % total;
        do_show_slide(state, state.widgets.get(state.index), true);
        do_update_dots(state);
    }

    private static void do_prev(CarouselState state) {
        if (state.widgets == null) return;
        int total = state.widgets.size;
        if (total <= 1) return;
        state.index = (state.index - 1 + total) % total;
        do_show_slide(state, state.widgets.get(state.index), true);
        do_update_dots(state);
    }

    public void start_timer(int seconds) {
        do_start_timer(state, seconds);
    }

    // Static: the GLib.Timeout source holds this closure for as long as the
    // timer runs, so a self-capturing version would keep HeroCarousel alive
    // via the timer alone even with the widget-tree cycle fixed elsewhere.
    private static void do_start_timer(CarouselState state, int seconds) {
        if (state.timeout_id != 0) { Source.remove(state.timeout_id); state.timeout_id = 0; }
        state.timeout_id = Timeout.add_seconds(seconds, () => {
            int total = state.widgets != null ? state.widgets.size : 0;
            if (total <= 1) return true;
            state.index = (state.index + 1) % total;
            do_show_slide(state, state.widgets.get(state.index), true);
            do_update_dots(state);
            return true;
        });
    }

    public void stop_timer() {
        if (state.timeout_id != 0) { Source.remove(state.timeout_id); state.timeout_id = 0; }
    }

    /**
     * Snap out of any in-flight crossfade and force every slide back to a
     * consistent state (only current_slide visible, full opacity).
     *
     * While the window is minimized/unfocused, the GLib timer that drives
     * next() keeps firing on schedule even though the widget's frame clock
     * is not ticking (nothing is being painted). Adw.TimedAnimation.done
     * therefore never fires, so old_slide never gets hidden again and the
     * new slide's opacity can stay stuck at 0 - i.e. the card renders
     * blank. Call this when the window becomes active again to recover.
     */
    public void force_settle() {
        foreach (var obj in state.active_slide_animations) {
            var anim = obj as Adw.TimedAnimation;
            if (anim != null) anim.pause();
        }
        state.active_slide_animations.clear();

        if (state.widgets == null) return;
        foreach (var w in state.widgets) {
            w.set_opacity(1.0);
            w.set_visible(w == state.current_slide);
        }
    }

    ~HeroCarousel() {
        stop_timer();
    }
}

/**
 * Helper class to return slide components for external image loading
 */
public class SlideComponents : GLib.Object {
    public Gtk.Widget slide { get; private set; }
    public Gtk.Picture image { get; private set; }
    // For immediate use right after create_article_slide() returns
    // (attaching a snippet, adding a source badge) - don't stash this away.
    public HeroCard hero { get; private set; }

    public SlideComponents(Gtk.Widget slide, Gtk.Picture image, HeroCard hero) {
        this.slide = slide;
        this.image = image;
        this.hero = hero;
    }
}
