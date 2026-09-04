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
using Adw;

/*
 * First-run welcome flow. A short multi-page carousel that introduces the
 * app, lets the user pick a few built-in sources, and points them at
 * local news. Shown automatically the first time the app runs, and can be
 * re-opened later from the main menu ("Welcome to Paperboy").
 */
public class OnboardingDialog : GLib.Object {

    public static void show(Gtk.Window parent) {
        var prefs = NewsPreferences.get_instance();

        var dialog = new Adw.Dialog();
        dialog.set_content_width(500);
        dialog.set_content_height(600);
        dialog.set_can_close(true);

        var root = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);

        var carousel = new Adw.Carousel();
        carousel.set_vexpand(true);
        carousel.set_interactive(true);
        carousel.append(build_welcome_page());
        carousel.append(build_theme_page(prefs));
        carousel.append(build_sources_page(prefs));
        carousel.append(build_finish_page(parent));
        root.append(carousel);

        var dots = new Adw.CarouselIndicatorDots();
        dots.set_carousel(carousel);
        dots.set_margin_top(6);
        dots.set_margin_bottom(6);
        root.append(dots);

        // Bottom navigation bar
        var nav_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
        nav_box.set_margin_start(24);
        nav_box.set_margin_end(24);
        nav_box.set_margin_bottom(20);
        nav_box.set_margin_top(4);

        var skip_btn = new Gtk.Button.with_label("Skip");
        skip_btn.add_css_class("flat");
        nav_box.append(skip_btn);

        var spacer = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        spacer.set_hexpand(true);
        nav_box.append(spacer);

        var back_btn = new Gtk.Button.with_label("Back");
        back_btn.set_visible(false);
        nav_box.append(back_btn);

        var next_btn = new Gtk.Button.with_label("Next");
        next_btn.add_css_class("suggested-action");
        nav_box.append(next_btn);

        root.append(nav_box);
        dialog.set_child(root);

        void finish() {
            prefs.onboarding_completed = true;
            prefs.save_config();
            dialog.close();
        }

        skip_btn.clicked.connect(() => finish());

        back_btn.clicked.connect(() => {
            uint idx = (uint) Math.round(carousel.get_position());
            if (idx > 0) carousel.scroll_to(carousel.get_nth_page(idx - 1), true);
        });

        next_btn.clicked.connect(() => {
            uint idx = (uint) Math.round(carousel.get_position());
            if (idx + 1 < carousel.get_n_pages()) {
                carousel.scroll_to(carousel.get_nth_page(idx + 1), true);
            } else {
                finish();
            }
        });

        void update_nav_for_page(uint index) {
            bool is_last = (index + 1 == carousel.get_n_pages());
            back_btn.set_visible(index > 0);
            skip_btn.set_visible(!is_last);
            next_btn.set_label(is_last ? "Get Started" : "Next");
        }

        carousel.page_changed.connect((index) => update_nav_for_page(index));
        update_nav_for_page(0);

        // If the user closes the dialog (e.g. via Escape) without going
        // through Skip/Get Started, still mark onboarding as seen so it
        // doesn't reappear unexpectedly on next launch.
        dialog.closed.connect(() => {
            if (!prefs.onboarding_completed) {
                prefs.onboarding_completed = true;
                prefs.save_config();
            }
        });

        dialog.present(parent);
    }

    private static Gtk.Widget build_welcome_page() {
        var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
        box.set_valign(Gtk.Align.CENTER);
        box.set_margin_start(32);
        box.set_margin_end(32);
        box.set_margin_top(32);
        box.set_margin_bottom(32);

        var icon = new Gtk.Image.from_icon_name("paperboy");
        icon.set_pixel_size(96);
        icon.set_halign(Gtk.Align.CENTER);
        box.append(icon);

        var title = new Gtk.Label("Welcome to Paperboy");
        title.add_css_class("title-1");
        title.set_halign(Gtk.Align.CENTER);
        title.set_margin_top(12);
        box.append(title);

        var body = new Gtk.Label(
            "Paperboy brings together news from the sources you trust, into one clean, distraction-free reader.\n\nLet's set a few things up before you get started.");
        body.set_wrap(true);
        body.set_justify(Gtk.Justification.CENTER);
        body.set_halign(Gtk.Align.CENTER);
        body.add_css_class("dim-label");
        box.append(body);

        return box;
    }

    private static Gtk.Widget build_theme_page(NewsPreferences prefs) {
        var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
        box.set_valign(Gtk.Align.CENTER);
        box.set_margin_start(32);
        box.set_margin_end(32);
        box.set_margin_top(32);
        box.set_margin_bottom(32);

        var icon = new Gtk.Image.from_icon_name("weather-clear-night-symbolic");
        icon.set_pixel_size(64);
        icon.set_halign(Gtk.Align.CENTER);
        icon.add_css_class("dim-label");
        box.append(icon);

        var title = new Gtk.Label("Pick a Theme");
        title.add_css_class("title-2");
        title.set_halign(Gtk.Align.CENTER);
        title.set_margin_top(12);
        box.append(title);

        var subtitle = new Gtk.Label("You can change this anytime from Preferences.");
        subtitle.set_wrap(true);
        subtitle.set_justify(Gtk.Justification.CENTER);
        subtitle.set_halign(Gtk.Align.CENTER);
        subtitle.add_css_class("dim-label");
        box.append(subtitle);

        // Three tappable preview swatches rather than a dropdown or plain
        // text toggle buttons - GNOME's own onboarding/first-run surfaces
        // (GNOME Tour, Initial Setup) favor a small set of large, directly
        // tappable options for a single prominent decision like this one,
        // with a miniature rendered preview doing the explaining instead of
        // a text label alone. A dropdown remains the right call in
        // Preferences (prefsDialog.vala's Theme row) - that's a dense list
        // of settings rows where compactness matters more than directness.
        var swatch_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 16);
        swatch_row.set_halign(Gtk.Align.CENTER);
        swatch_row.set_margin_top(20);

        // One shared list of this page's badges so selecting one tile can
        // un-check the other two - these three tiles are mutually
        // exclusive (a radio group), unlike the source-picker page's
        // same-looking tiles, which are independent toggles.
        var badges = new Gee.ArrayList<Gtk.Widget>();
        var variants = new Gee.ArrayList<string>();

        Gtk.Widget make_theme_tile(string variant, string title_text) {
            var tile_frame = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
            tile_frame.add_css_class("onboarding-source-tile");
            tile_frame.set_halign(Gtk.Align.CENTER);
            tile_frame.set_valign(Gtk.Align.CENTER);

            var swatch = new Gtk.Picture();
            swatch.set_content_fit(Gtk.ContentFit.CONTAIN);
            swatch.set_size_request(108, 72);
            swatch.set_paintable(render_theme_swatch(variant));
            // Round just the swatch artwork's own corners, matching the
            // source-picker tiles' logo treatment.
            swatch.add_css_class("onboarding-theme-swatch");
            swatch.set_overflow(Gtk.Overflow.HIDDEN);
            tile_frame.append(swatch);

            var label = new Gtk.Label(title_text);
            label.add_css_class("caption");
            tile_frame.append(label);

            var badge = new Gtk.Image.from_icon_name("object-select-symbolic");
            badge.add_css_class("onboarding-source-badge");
            badge.set_pixel_size(11);
            badge.set_halign(Gtk.Align.END);
            badge.set_valign(Gtk.Align.START);
            badge.set_margin_end(-4);
            badge.set_margin_top(-4);
            badge.set_visible(prefs.color_scheme == variant || (prefs.color_scheme == "" && variant == "system"));

            tile_frame.set_overflow(Gtk.Overflow.HIDDEN);

            var btn = new Gtk.Button();
            btn.add_css_class("onboarding-source-tile-btn");
            btn.set_child(tile_frame);
            btn.set_tooltip_text(title_text);
            btn.set_halign(Gtk.Align.CENTER);
            btn.set_valign(Gtk.Align.CENTER);
            btn.set_hexpand(false);
            btn.set_vexpand(false);
            btn.clicked.connect(() => {
                // Applying immediately (rather than waiting for "Get
                // Started") gives the user a live preview of the theme
                // against the rest of the onboarding dialog itself.
                prefs.color_scheme = variant;
                for (int i = 0; i < badges.size; i++) {
                    badges.get(i).set_visible(variants.get(i) == variant);
                }
            });

            var overlay = new Gtk.Overlay();
            overlay.set_child(btn);
            overlay.add_overlay(badge);
            overlay.set_halign(Gtk.Align.CENTER);
            overlay.set_valign(Gtk.Align.CENTER);
            overlay.set_hexpand(false);
            overlay.set_vexpand(false);

            badges.add(badge);
            variants.add(variant);

            return overlay;
        }

        swatch_row.append(make_theme_tile("system", "Follow System"));
        swatch_row.append(make_theme_tile("light", "Light"));
        swatch_row.append(make_theme_tile("dark", "Dark"));

        box.append(swatch_row);

        return box;
    }

    // Draws a miniature mockup of what the app looks like under `variant`
    // ("light", "dark", or "system" - a light/dark split, the conventional
    // way auto/follow-system options are depicted) - a sidebar strip plus a
    // couple of card blocks and one accent-colored bar, echoing Paperboy's
    // own actual layout rather than a generic swatch.
    private static Gdk.Texture render_theme_swatch(string variant) {
        int w = 108, h = 72;
        var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, w, h);
        var cr = new Cairo.Context(surface);

        void paint_variant(string v, double x0, double x1) {
            bool dark = v == "dark";
            double bg = dark ? 0.15 : 1.0;
            double sidebar = dark ? 0.20 : 0.93;
            double card = dark ? 0.26 : 0.85;

            cr.save();
            cr.rectangle(x0, 0, x1 - x0, h);
            cr.clip();

            cr.set_source_rgb(bg, bg, bg);
            cr.rectangle(x0, 0, x1 - x0, h);
            cr.fill();

            // Sidebar strip along the left edge of this half/whole.
            double sidebar_w = (x1 - x0) * 0.32;
            cr.set_source_rgb(sidebar, sidebar, sidebar);
            cr.rectangle(x0, 0, sidebar_w, h);
            cr.fill();

            // A short accent-colored bar standing in for a hero/highlight.
            cr.set_source_rgb(0.20, 0.45, 0.85);
            cr.rectangle(x0 + sidebar_w + 6, 8, (x1 - x0) - sidebar_w - 12, 10);
            cr.fill();

            // Two card blocks standing in for article cards.
            cr.set_source_rgb(card, card, card);
            cr.rectangle(x0 + sidebar_w + 6, 24, (x1 - x0) - sidebar_w - 12, 16);
            cr.fill();
            cr.rectangle(x0 + sidebar_w + 6, 46, (x1 - x0) - sidebar_w - 12, 16);
            cr.fill();

            cr.restore();
        }

        if (variant == "system") {
            paint_variant("dark", 0, w / 2.0);
            paint_variant("light", w / 2.0, w);
        } else {
            paint_variant(variant, 0, w);
        }

        surface.flush();
        var pixbuf = Gdk.pixbuf_get_from_surface(surface, 0, 0, w, h);
        return Gdk.Texture.for_pixbuf(pixbuf);
    }

    private static Gtk.Widget build_sources_page(NewsPreferences prefs) {
        var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
        box.set_margin_start(36);
        box.set_margin_end(36);
        box.set_margin_top(36);
        box.set_margin_bottom(18);

        var title = new Gtk.Label("Choose Your Sources");
        title.add_css_class("title-2");
        title.set_halign(Gtk.Align.CENTER);
        box.append(title);

        var subtitle = new Gtk.Label("Paperboy comes with a set of prebuilt news sources to get you started. Tap the outlets you'd like to see - you can change these anytime from Preferences.");
        subtitle.set_wrap(true);
        subtitle.set_justify(Gtk.Justification.CENTER);
        subtitle.set_halign(Gtk.Align.CENTER);
        subtitle.add_css_class("dim-label");
        box.append(subtitle);

        var scroller = new Gtk.ScrolledWindow();
        scroller.set_vexpand(true);
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        scroller.set_margin_top(12);

        var grid = new Gtk.FlowBox();
        grid.add_css_class("onboarding-sources-grid");
        grid.set_selection_mode(Gtk.SelectionMode.NONE);
        grid.set_homogeneous(true);
        grid.set_row_spacing(16);
        grid.set_column_spacing(16);
        grid.set_valign(Gtk.Align.START);
        // The badge on the top row's tiles pokes a few px above the tile
        // itself (see make_tile below). scroller's own margin_top sits
        // outside its clipped viewport, so it gives no room *inside* the
        // scrollable area - without this, only the top row's badge (the
        // only one not already buffered by row_spacing) gets clipped by
        // the viewport's top edge.
        grid.set_margin_top(12);
        grid.set_max_children_per_line(3);
        grid.set_min_children_per_line(3);

        Gtk.Widget make_tile(string title_text, string source_id, string logo_file) {
            var tile_frame = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            tile_frame.add_css_class("onboarding-source-tile");
            tile_frame.set_halign(Gtk.Align.CENTER);
            tile_frame.set_valign(Gtk.Align.CENTER);
            tile_frame.set_size_request(96, 96);

            // Gtk.Image with a fixed pixel_size always requests exactly that
            // square, letterboxing the source image within it regardless of
            // its original aspect ratio - unlike Gtk.Picture, whose natural
            // size follows the image's own aspect ratio and would make wider
            // logos (ABC News, WSJ, Fox) blow up their tile bigger than the
            // more square ones.
            var picture = new Gtk.Image();
            picture.set_pixel_size(68);
            picture.set_halign(Gtk.Align.CENTER);
            picture.set_valign(Gtk.Align.CENTER);
            string? logo_path = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", logo_file));
            if (logo_path != null) picture.set_from_file(logo_path);
            tile_frame.append(picture);

            var badge = new Gtk.Image.from_icon_name("object-select-symbolic");
            badge.add_css_class("onboarding-source-badge");
            badge.set_pixel_size(11);
            badge.set_halign(Gtk.Align.END);
            badge.set_valign(Gtk.Align.START);
            badge.set_margin_end(-4);
            badge.set_margin_top(-4);
            badge.set_visible(prefs.preferred_source_enabled(source_id));

            // Clip only the tile artwork (the logo image) to the tile's
            // rounded corners. This lives on tile_frame itself rather than
            // on the button, because an element's own overflow clip does
            // not cut off its own box-shadow (only its children's content
            // that spills past its edge) - so the hover shadow below,
            // which is declared on this same element, still renders in
            // full even though the image inside it is clipped.
            tile_frame.set_overflow(Gtk.Overflow.HIDDEN);

            var btn = new Gtk.Button();
            btn.add_css_class("onboarding-source-tile-btn");
            btn.set_child(tile_frame);
            btn.set_tooltip_text(title_text);
            btn.set_halign(Gtk.Align.CENTER);
            btn.set_valign(Gtk.Align.CENTER);
            btn.set_hexpand(false);
            btn.set_vexpand(false);
            btn.clicked.connect(() => {
                bool now_enabled = !prefs.preferred_source_enabled(source_id);
                prefs.set_preferred_source_enabled(source_id, now_enabled);
                prefs.save_config();
                badge.set_visible(now_enabled);
            });

            // The badge lives in its own overlay wrapped *around* the
            // button rather than inside it, so its corner-hugging negative
            // margin isn't clipped by tile_frame's rounded-corner overflow.
            // This outer overlay must shrink-wrap and center like btn used
            // to (a FlowBoxChild otherwise stretches its child to fill the
            // whole homogeneous cell) - without that, the badge positions
            // itself relative to the overlay's own (much larger) box
            // instead of the tile's actual corner.
            var overlay = new Gtk.Overlay();
            overlay.set_child(btn);
            overlay.add_overlay(badge);
            overlay.set_halign(Gtk.Align.CENTER);
            overlay.set_valign(Gtk.Align.CENTER);
            overlay.set_hexpand(false);
            overlay.set_vexpand(false);

            return overlay;
        }

        grid.append(make_tile("The Guardian", "guardian", "guardian-logo.png"));
        grid.append(make_tile("BBC News", "bbc", "bbc-logo.png"));
        grid.append(make_tile("New York Times", "nytimes", "nytimes-logo.png"));
        grid.append(make_tile("Bloomberg", "bloomberg", "bloomberg-logo.png"));
        grid.append(make_tile("Wall Street Journal", "wsj", "wsj-logo.png"));
        grid.append(make_tile("ABC News", "abc", "abc-logo.png"));
        grid.append(make_tile("NPR", "npr", "npr-logo.png"));
        grid.append(make_tile("Fox News", "fox", "foxnews-logo.png"));
        grid.append(make_tile("PBS NewsHour", "pbs", "pbs-logo.png"));

        scroller.set_child(grid);
        box.append(scroller);

        return box;
    }

    private static Gtk.Widget build_finish_page(Gtk.Window parent) {
        var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
        box.set_valign(Gtk.Align.CENTER);
        box.set_margin_start(32);
        box.set_margin_end(32);
        box.set_margin_top(32);
        box.set_margin_bottom(32);

        var icon = new Gtk.Image.from_icon_name("mark-location-symbolic");
        icon.set_pixel_size(64);
        icon.set_halign(Gtk.Align.CENTER);
        icon.add_css_class("dim-label");
        box.append(icon);

        var title = new Gtk.Label("Local News, Too");
        title.add_css_class("title-2");
        title.set_halign(Gtk.Align.CENTER);
        title.set_margin_top(12);
        box.append(title);

        var body = new Gtk.Label(
            "Set your location to get a Local News feed for your area. You can do this now or anytime later from the main menu.");
        body.set_wrap(true);
        body.set_justify(Gtk.Justification.CENTER);
        body.set_halign(Gtk.Align.CENTER);
        body.add_css_class("dim-label");
        box.append(body);

        var location_btn = new Gtk.Button.with_label("Set My Location");
        location_btn.set_halign(Gtk.Align.CENTER);
        location_btn.set_margin_top(12);
        location_btn.clicked.connect(() => {
            LocationDialog.show(parent);
        });
        box.append(location_btn);

        return box;
    }
}
