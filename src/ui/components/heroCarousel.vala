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

public class HeroCarousel : GLib.Object {
    // Manual crossfade instead of Gtk.Stack: Gtk.Stack broke :hover on
    // every slide but the first (see show_slide). A custom slide
    // transition via Gtk.Overlay.get_child_position was tried too and hit
    // the same hover bug, so crossfade is what stays.
    public Gtk.Overlay? slide_holder;
    private Gtk.Widget? current_slide;
    // Keeps crossfade animations alive until they finish; see
    // AnimationManager.active_entrance_animations for why locals aren't enough.
    private Gee.ArrayList<GLib.Object> active_slide_animations = new Gee.ArrayList<GLib.Object>();

    public Box? container;
    // One dot row per slide, injected into that slide's own text pane
    // (see add_dots_row_for) rather than a shared strip below the picture.
    public ArrayList<ArrayList<Label>>? dot_rows;
    public ArrayList<Widget>? widgets;
    public int index = 0;
    public uint timeout_id = 0;

    // Trackpad/wheel scroll state - see on_carousel_scroll().
    private double scroll_accum_x = 0;
    private bool scroll_cooldown = false;
    
    // Layout constants - kept equal since the picture spans the card's full height.
    public const int SLIDE_MAX_HEIGHT = 500;
    public const int SLIDE_IMAGE_HEIGHT = 500;
    
    // Signal emitted when a slide is activated (clicked)
    public signal void slide_activated(string title, string url, string? thumbnail_url, string category_id, string? source_name);

    public HeroCarousel(Gtk.Box parent) {
        GLib.Object();
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
        top_stories_title.set_markup("<span size='26000'><b>TOP STORIES</b></span>");
        parent.append(top_stories_title);
        widgets = new ArrayList<Widget>();
        dot_rows = new ArrayList<ArrayList<Label>>();

        slide_holder = new Gtk.Overlay();
        slide_holder.set_halign(Gtk.Align.FILL);
        slide_holder.set_hexpand(true);
        // Unlike Gtk.Stack, Overlay doesn't size itself to the tallest
        // child by default, so pin the height explicitly.
        slide_holder.set_size_request(-1, SLIDE_MAX_HEIGHT);

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

        // Hover-reveal prev/next buttons (see ScrollNavButtons). The
        // carousel loops, so there's no bounded end to disable.
        var nav_buttons = new ScrollNavButtons(carousel_overlay, "carousel-nav");
        nav_buttons.prev_requested.connect(() => { prev(); });
        nav_buttons.next_requested.connect(() => { next(); });

        // Trackpad/wheel horizontal scroll: accumulate delta and advance
        // one slide per swipe, then cool down briefly so a single gesture
        // doesn't skip several slides.
        var scroll_controller = new Gtk.EventControllerScroll(Gtk.EventControllerScrollFlags.BOTH_AXES);
        scroll_controller.scroll.connect((dx, dy) => on_carousel_scroll(dx, dy));
        carousel_overlay.add_controller(scroll_controller);

        carousel_container.append(carousel_overlay);

        container = carousel_container;
        parent.append(carousel_container);
    }

    public void add_initial_slide(Gtk.Widget slide) {
        if (slide_holder == null) return;
        mark_slide_title(slide);
        slide_holder.add_overlay(slide);
        widgets.add(slide);
        add_dots_row_for(slide);
        index = 0;
        show_slide(slide, false);
        update_dots();
    }

    public void add_slide(Gtk.Widget slide) {
        if (slide_holder == null || widgets == null) return;
        mark_slide_title(slide);
        // Parented but hidden, not left unparented: a slide needs to stay
        // rooted in the window at all times, since its snippet text can
        // arrive (an async fetch) before it's ever shown, and
        // HeroCard.set_snippet() drops the text if the widget has no root.
        slide.set_visible(false);
        slide_holder.add_overlay(slide);
        widgets.add(slide);
        add_dots_row_for(slide);
        update_dots();
    }

    /**
    * Show one slide, hide the rest - never reparents, only toggles
    * visibility/opacity. animate=false is an instant cut (used for the
    * first slide); otherwise the incoming slide fades in while the
    * outgoing one fades out.
    */
    private void show_slide(Gtk.Widget new_slide, bool animate) {
        if (slide_holder == null || current_slide == new_slide) return;
        Gtk.Widget? old_slide = current_slide;
        current_slide = new_slide;

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

        active_slide_animations.add(target_in);
        active_slide_animations.add(anim_in);
        active_slide_animations.add(target_out);
        active_slide_animations.add(anim_out);

        anim_in.done.connect(() => {
            active_slide_animations.remove(anim_in);
            active_slide_animations.remove(target_in);
            new_slide.set_opacity(1.0);
        });
        anim_out.done.connect(() => {
            active_slide_animations.remove(anim_out);
            active_slide_animations.remove(target_out);
            // Reset opacity for next time this slide comes back around.
            old_slide.set_visible(false);
            old_slide.set_opacity(1.0);
        });

        anim_in.play();
        anim_out.play();
    }

    // Larger title for carousel slides only (see .carousel-hero-title).
    private void mark_slide_title(Gtk.Widget slide) {
        var hero = slide.get_data<HeroCard>("hero-card");
        if (hero != null && hero.title_label != null) {
            hero.title_label.add_css_class("carousel-hero-title");
        }
    }

    // Build a dot-indicator row and place it in the slide's own text pane,
    // bottom-aligned. update_dots keeps every row in sync.
    private void add_dots_row_for(Gtk.Widget slide) {
        var hero = slide.get_data<HeroCard>("hero-card");
        if (hero == null || hero.title_box == null) return;

        var row = new Gtk.Box(Orientation.HORIZONTAL, 6);
        row.set_halign(Gtk.Align.CENTER);
        row.set_valign(Gtk.Align.END);
        row.set_vexpand(true);

        var labels = new ArrayList<Label>();
        for (int d = 0; d < 5; d++) {
            var dot = new Gtk.Label("•");
            dot.add_css_class("carousel-dot");
            dot.set_valign(Gtk.Align.CENTER);
            var dot_attrs = new Pango.AttrList();
            dot_attrs.insert(Pango.attr_scale_new(1.35));
            dot.set_attributes(dot_attrs);
            row.append(dot);
            labels.add(dot);
        }

        hero.title_box.append(row);
        dot_rows.add(labels);
    }

    /**
     * Build a HeroCard slide, add it to the carousel, and return it (plus
     * its image widget) for external image loading.
     */
    public SlideComponents create_article_slide(string title, string url, string? thumbnail_url,
                                                  string category_id, string? source_name,
                                                  Gtk.Widget? category_chip) {
        var hero = new HeroCard(title, url, SLIDE_MAX_HEIGHT, SLIDE_IMAGE_HEIGHT, category_chip, false, null, null);
        hero.source_name = source_name;
        hero.category_id = category_id;
        hero.activated.connect((activated_url) => {
            slide_activated(title, activated_url, thumbnail_url, category_id, source_name);
        });

        if (widgets.size == 0) {
            add_initial_slide(hero.root);
        } else {
            add_slide(hero.root);
        }

        return new SlideComponents(hero.root, hero.image);
    }

    public void update_dots() {
        if (dot_rows == null || widgets == null) return;
        int total = widgets.size;
        foreach (var row in dot_rows) {
            for (int i = 0; i < row.size; i++) {
                var dot = row[i];
                if (i >= total) {
                    dot.add_css_class("inactive");
                    dot.remove_css_class("active");
                } else {
                    dot.remove_css_class("inactive");
                    if (i == index) dot.add_css_class("active"); else dot.remove_css_class("active");
                }
            }
        }
    }

    private bool on_carousel_scroll(double dx, double dy) {
        // Only treat clearly horizontal gestures as navigation; let
        // vertical scrolls bubble up to scroll the page instead.
        if (dx.abs() <= dy.abs()) {
            return false;
        }

        if (!scroll_cooldown) {
            scroll_accum_x += dx;
            double threshold = 40.0;
            if (scroll_accum_x > threshold) {
                next();
                start_scroll_cooldown();
            } else if (scroll_accum_x < -threshold) {
                prev();
                start_scroll_cooldown();
            }
        }
        return true;
    }

    private void start_scroll_cooldown() {
        scroll_accum_x = 0;
        scroll_cooldown = true;
        Timeout.add(450, () => {
            scroll_cooldown = false;
            return false;
        });
    }

    public void next() {
        if (widgets == null) return;
        int total = widgets.size;
        if (total <= 1) return;
        index = (index + 1) % total;
        show_slide(widgets.get(index), true);
        update_dots();
    }

    public void prev() {
        if (widgets == null) return;
        int total = widgets.size;
        if (total <= 1) return;
        index = (index - 1 + total) % total;
        show_slide(widgets.get(index), true);
        update_dots();
    }

    public void start_timer(int seconds) {
        if (timeout_id != 0) { Source.remove(timeout_id); timeout_id = 0; }
        timeout_id = Timeout.add_seconds(seconds, () => {
            int total = widgets != null ? widgets.size : 0;
            if (total <= 1) return true;
            index = (index + 1) % total;
            show_slide(widgets.get(index), true);
            update_dots();
            return true;
        });
    }

    public void stop_timer() {
        if (timeout_id != 0) { Source.remove(timeout_id); timeout_id = 0; }
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
    
    public SlideComponents(Gtk.Widget slide, Gtk.Picture image) {
        this.slide = slide;
        this.image = image;
    }
}