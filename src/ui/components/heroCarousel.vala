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

public class HeroCarousel : GLib.Object {
    public Gtk.Stack? stack;
    public Box? container;
    // Each slide gets its own copy of the dot indicators, injected into that
    // slide's text pane (see build_dots_row), since the picture now runs the
    // full height of the card and there's no shared strip below it anymore
    // to hold a single external row. One list of labels per slide.
    public ArrayList<ArrayList<Label>>? dot_rows;
    public ArrayList<Widget>? widgets;
    public int index = 0;
    public uint timeout_id = 0;
    
    // Layout constants
    // Kept equal since HeroCard's picture now spans the full card height
    // (side-by-side layout) rather than just a stacked-on-top portion.
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
        // Use Pango markup to match the subtitle sizing used elsewhere.
        top_stories_title.set_markup("<span size='11000'><b>TOP STORIES</b></span>");
        top_stories_title.set_margin_bottom(6);
        parent.append(top_stories_title);
        widgets = new ArrayList<Widget>();
        dot_rows = new ArrayList<ArrayList<Label>>();

        stack = new Gtk.Stack();
        stack.set_transition_type(Gtk.StackTransitionType.SLIDE_LEFT_RIGHT);
        stack.set_halign(Gtk.Align.FILL);
        stack.set_hexpand(true);

        // No "card" class here: the visible card look (background, border,
        // rounded corners) now comes entirely from the HeroCard slide inside
        // the stack. Adding it here too used to nest a second card behind
        // it, showing as a double-layered edge and keeping the slide's own
        // content from reaching the true outer edge.
        var carousel_container = new Gtk.Box(Orientation.VERTICAL, 0);
        carousel_container.add_css_class("card-featured");
        carousel_container.set_halign(Gtk.Align.FILL);
        carousel_container.set_hexpand(true);

        var carousel_overlay = new Gtk.Overlay();
        carousel_overlay.set_child(stack);

        var left_btn = new Gtk.Button.from_icon_name("go-previous-symbolic");
        left_btn.add_css_class("carousel-nav");
        left_btn.add_css_class("carousel-nav-left");
        left_btn.set_halign(Gtk.Align.START);
        left_btn.set_valign(Gtk.Align.CENTER);
        left_btn.set_margin_start(8);
        left_btn.set_margin_end(8);
        carousel_overlay.add_overlay(left_btn);
        left_btn.clicked.connect(() => { prev(); });

        var right_btn = new Gtk.Button.from_icon_name("go-next-symbolic");
        right_btn.add_css_class("carousel-nav");
        right_btn.add_css_class("carousel-nav-right");
        right_btn.set_halign(Gtk.Align.END);
        right_btn.set_valign(Gtk.Align.CENTER);
        right_btn.set_margin_start(8);
        right_btn.set_margin_end(8);
        carousel_overlay.add_overlay(right_btn);
        right_btn.clicked.connect(() => { next(); });

        // Show only whichever nav button is on the side the pointer is
        // currently over, rather than both together for any hover on the
        // card. A CSS hover-zone split (half-width boxes relying on
        // hexpand to stretch across the overlay) turned out unreliable -
        // Gtk.Overlay didn't stretch them to the full card width, leaving
        // the buttons sitting near the middle instead of the true edges.
        // Tracking pointer position directly against the overlay's actual
        // allocated width sidesteps that entirely.
        var nav_motion = new Gtk.EventControllerMotion();
        nav_motion.motion.connect((x, y) => {
            int w = carousel_overlay.get_width();
            if (w <= 0) return;
            bool left_side = x < (w / 2.0);
            if (left_side) {
                left_btn.add_css_class("carousel-nav-active");
                right_btn.remove_css_class("carousel-nav-active");
            } else {
                right_btn.add_css_class("carousel-nav-active");
                left_btn.remove_css_class("carousel-nav-active");
            }
        });
        nav_motion.leave.connect(() => {
            left_btn.remove_css_class("carousel-nav-active");
            right_btn.remove_css_class("carousel-nav-active");
        });
        carousel_overlay.add_controller(nav_motion);

        carousel_container.append(carousel_overlay);

        container = carousel_container;
        parent.append(carousel_container);
    }

    public void add_initial_slide(Gtk.Widget slide) {
        if (stack == null) return;
        stack.add_named(slide, "0");
        widgets.add(slide);
        add_dots_row_for(slide);
        index = 0;
        update_dots();
    }

    public void add_slide(Gtk.Widget slide) {
        if (stack == null || widgets == null) return;
        int new_index = widgets.size;
        stack.add_named(slide, "%d".printf(new_index));
        widgets.add(slide);
        add_dots_row_for(slide);
        update_dots();
    }

    // Build a dot-indicator row and place it in the slide's own text pane
    // (bottom-aligned, via HeroCard's vexpand text_box) instead of in a
    // shared strip below the picture, so the picture can run the card's
    // full height. Every slide gets its own row since only one HeroCard is
    // visible at a time (they're Stack children); update_dots keeps all of
    // them in sync so whichever one is showing is always current.
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
     * Create and add an article slide to the carousel.
     * This encapsulates all slide widget construction that was previously in ArticleManager.
     * Returns the slide widget and its image for external image loading.
     */
    public SlideComponents create_article_slide(string title, string url, string? thumbnail_url,
                                                  string category_id, string? source_name,
                                                  Gtk.Widget? category_chip) {
        // Build the slide from the same HeroCard used for topten/featured
        // heroes, so every hero instance (carousel included) shares one
        // layout and stays in sync automatically.
        var hero = new HeroCard(title, url, SLIDE_MAX_HEIGHT, SLIDE_IMAGE_HEIGHT, category_chip, false, null, null);
        hero.source_name = source_name;
        hero.category_id = category_id;
        hero.activated.connect((activated_url) => {
            slide_activated(title, activated_url, thumbnail_url, category_id, source_name);
        });

        // Add to carousel
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

    public void next() {
        if (stack == null || widgets == null) return;
        int total = widgets.size;
        if (total <= 1) return;
        index = (index + 1) % total;
        for (int i = 0; i < total; i++) {
            var child = widgets.get(index) as Gtk.Widget;
            if (child != null && child.get_parent() == stack) {
                stack.set_visible_child(child);
                update_dots();
                return;
            }
            index = (index + 1) % total;
        }
    }

    public void prev() {
        if (stack == null || widgets == null) return;
        int total = widgets.size;
        if (total <= 1) return;
        index = (index - 1 + total) % total;
        for (int i = 0; i < total; i++) {
            var child = widgets.get(index) as Gtk.Widget;
            if (child != null && child.get_parent() == stack) {
                stack.set_visible_child(child);
                update_dots();
                return;
            }
            index = (index - 1 + total) % total;
        }
    }

    public void start_timer(int seconds) {
        if (timeout_id != 0) { Source.remove(timeout_id); timeout_id = 0; }
        timeout_id = Timeout.add_seconds(seconds, () => {
            if (stack == null) return true;
            int total = widgets != null ? widgets.size : 0;
            if (total <= 1) return true;
            index = (index + 1) % total;
            for (int i = 0; i < total; i++) {
                var child = widgets.get(index) as Gtk.Widget;
                if (child != null && child.get_parent() == stack) {
                    stack.set_visible_child(child);
                    update_dots();
                    return true;
                }
                index = (index + 1) % total;
            }
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