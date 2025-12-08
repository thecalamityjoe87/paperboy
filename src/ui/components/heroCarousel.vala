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
    public Box? dots_box;
    public ArrayList<Label>? dot_widgets;
    public ArrayList<Widget>? widgets;
    public int index = 0;
    public uint timeout_id = 0;
    
    // Layout constants
    public const int SLIDE_MAX_HEIGHT = 350;
    public const int SLIDE_IMAGE_HEIGHT = 250;
    
    // Signal emitted when a slide is activated (clicked)
    public signal void slide_activated(string title, string url, string? thumbnail_url, string category_id, string? source_name);

    public HeroCarousel(Gtk.Box parent) {
        GLib.Object();
        // Create title and container
        var top_stories_title = new Gtk.Label("");
        top_stories_title.set_xalign(0);
        top_stories_title.add_css_class("caption");
        // Use Pango markup to match the subtitle sizing used elsewhere.
        try { top_stories_title.set_markup("<span size='11000'><b>TOP STORIES</b></span>"); } catch (GLib.Error e) { top_stories_title.set_text("TOP STORIES"); }
        top_stories_title.set_margin_bottom(6);
        try { parent.append(top_stories_title); } catch (GLib.Error e) { }
        widgets = new ArrayList<Widget>();
        dot_widgets = new ArrayList<Label>();

        stack = new Gtk.Stack();
        stack.set_transition_type(Gtk.StackTransitionType.SLIDE_LEFT_RIGHT);
        stack.set_halign(Gtk.Align.FILL);
        stack.set_hexpand(true);

        var carousel_container = new Gtk.Box(Orientation.VERTICAL, 0);
        carousel_container.add_css_class("card");
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

        carousel_container.append(carousel_overlay);

        var global_dots = new Gtk.Box(Orientation.HORIZONTAL, 6);
        global_dots.set_halign(Gtk.Align.CENTER);
        global_dots.set_margin_top(6);
        for (int d = 0; d < 5; d++) {
            var dot = new Gtk.Label("•");
            dot.add_css_class("carousel-dot");
            if (d == 0) dot.add_css_class("active");
            dot.set_valign(Gtk.Align.CENTER);
            var dot_attrs = new Pango.AttrList();
            dot_attrs.insert(Pango.attr_scale_new(1.35));
            dot.set_attributes(dot_attrs);
            global_dots.append(dot);
            dot_widgets.add(dot);
        }
        dots_box = global_dots;
        carousel_container.append(global_dots);

        container = carousel_container;
        try { parent.append(carousel_container); } catch (GLib.Error e) { }
    }

    public void add_initial_slide(Gtk.Widget slide) {
        if (stack == null) return;
        stack.add_named(slide, "0");
        widgets.add(slide);
        index = 0;
        update_dots();
    }

    public void add_slide(Gtk.Widget slide) {
        if (stack == null || widgets == null) return;
        int new_index = widgets.size;
        stack.add_named(slide, "%d".printf(new_index));
        widgets.add(slide);
        update_dots();
    }

    /**
     * Create and add an article slide to the carousel.
     * This encapsulates all slide widget construction that was previously in ArticleManager.
     * Returns the slide widget and its image for external image loading.
     */
    public SlideComponents create_article_slide(string title, string url, string? thumbnail_url, 
                                                  string category_id, string? source_name,
                                                  Gtk.Widget? category_chip) {
        var slide = new Gtk.Box(Orientation.VERTICAL, 0);
        slide.set_size_request(-1, SLIDE_MAX_HEIGHT);
        slide.set_hexpand(true);
        slide.set_vexpand(false);
        slide.set_halign(Gtk.Align.FILL);
        slide.set_valign(Gtk.Align.START);
        slide.set_margin_start(0);
        slide.set_margin_end(0);

        var slide_image = new Gtk.Picture();
        slide_image.set_halign(Gtk.Align.FILL);
        slide_image.set_hexpand(true);
        slide_image.set_size_request(-1, SLIDE_IMAGE_HEIGHT);
        slide_image.set_content_fit(Gtk.ContentFit.COVER);
        slide_image.set_can_shrink(true);

        var slide_overlay = new Gtk.Overlay();
        slide_overlay.set_child(slide_image);
        
        if (category_chip != null) {
            slide_overlay.add_overlay(category_chip);
        }
        
        slide.append(slide_overlay);

        var slide_title_box = new Gtk.Box(Orientation.VERTICAL, 8);
        slide_title_box.set_margin_start(16);
        slide_title_box.set_margin_end(16);
        slide_title_box.set_margin_top(16);
        slide_title_box.set_margin_bottom(16);
        slide_title_box.set_vexpand(true);

        var slide_label = new Gtk.Label(title);
        slide_label.set_ellipsize(Pango.EllipsizeMode.END);
        slide_label.set_xalign(0);
        slide_label.set_wrap(true);
        slide_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        slide_label.set_lines(8);
        slide_label.set_max_width_chars(88);
        slide_title_box.append(slide_label);
        slide.append(slide_title_box);

        // Connect click handler - emit signal with article details
        var slide_click = new Gtk.GestureClick();
        slide_click.released.connect(() => {
            slide_activated(title, url, thumbnail_url, category_id, source_name);
        });
        slide.add_controller(slide_click);

        // Add to carousel
        if (widgets.size == 0) {
            add_initial_slide(slide);
        } else {
            add_slide(slide);
        }

        return new SlideComponents(slide, slide_image);
    }

    public void update_dots() {
        if (dot_widgets == null || widgets == null) return;
        int total = widgets.size;
        for (int i = 0; i < dot_widgets.size; i++) {
            var dot = dot_widgets[i];
            if (i >= total) {
                dot.add_css_class("inactive");
                dot.remove_css_class("active");
            } else {
                dot.remove_css_class("inactive");
                if (i == index) dot.add_css_class("active"); else dot.remove_css_class("active");
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