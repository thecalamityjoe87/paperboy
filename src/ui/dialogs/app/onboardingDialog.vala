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
 * re-opened later from the main menu (_("Welcome to Paperboy")).
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
        carousel.append(build_country_page(prefs));
        carousel.append(build_theme_page(prefs));
        carousel.append(build_categories_page(prefs, parent as NewsWindow));
        carousel.append(build_sources_page(prefs));
        carousel.append(build_sports_page(prefs));
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

        var skip_btn = new Gtk.Button.with_label(_("Skip"));
        skip_btn.add_css_class("flat");
        nav_box.append(skip_btn);

        var spacer = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        spacer.set_hexpand(true);
        nav_box.append(spacer);

        var back_btn = new Gtk.Button.with_label(_("Back"));
        back_btn.set_visible(false);
        nav_box.append(back_btn);

        var next_btn = new Gtk.Button.with_label(_("Next"));
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
            next_btn.set_label(is_last ? _("Get Started") : _("Next"));
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

            // Show the chosen categories and sources right away
            var win = parent as NewsWindow;
            if (win != null) {
                if (win.sidebar_manager != null) win.sidebar_manager.rebuild_sidebar();
                win.fetch_news();
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

        // Same banner as the About dialog, instead of the plain app icon.
        string? banner_path = DataPathsUtils.find_data_file("images/paperboy-banner.png");
        if (banner_path != null) {
            var banner = new Gtk.Picture.for_filename(banner_path);
            banner.set_keep_aspect_ratio(true);
            banner.set_size_request(300, 80);
            banner.set_halign(Gtk.Align.CENTER);
            box.append(banner);
        } else {
            var icon = new Gtk.Image.from_icon_name("paperboy");
            icon.set_pixel_size(96);
            icon.set_halign(Gtk.Align.CENTER);
            box.append(icon);
        }

        var title = new Gtk.Label(_("Welcome to Paperboy"));
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

    // Detected from the system, so most people just check it's right.
    // Closing onboarding refetches, so a change needs nothing else here.
    private static Gtk.Widget build_country_page(NewsPreferences prefs) {
        var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
        box.set_valign(Gtk.Align.CENTER);
        box.set_margin_start(36);
        box.set_margin_end(36);
        box.set_margin_top(36);
        box.set_margin_bottom(18);

        // Bundled icon (black and white versions), sized and dimmed like the
        // theme icons on the other pages. The Theme page can switch light and
        // dark while this page exists, so follow it.
        var icon = new Gtk.Image();
        icon.set_pixel_size(64);
        icon.set_halign(Gtk.Align.CENTER);
        icon.add_css_class("dim-label");
        void apply_icon() {
            string? path = CategoryIconsUtils.resolve_themed_icon_path("country-mono.svg");
            if (path != null) icon.set_from_gicon(new GLib.FileIcon(GLib.File.new_for_path(path)));
            else icon.set_from_icon_name("mark-location-symbolic");
        }
        apply_icon();
        var style_manager = Adw.StyleManager.get_default();
        ulong dark_handler = style_manager.notify["dark"].connect(() => apply_icon());
        icon.destroy.connect(() => style_manager.disconnect(dark_handler));
        box.append(icon);

        var title = new Gtk.Label("Where Are You Reading From?");
        title.add_css_class("title-2");
        title.set_halign(Gtk.Align.CENTER);
        title.set_margin_top(12);
        box.append(title);

        var subtitle = new Gtk.Label("Your national news and Front Page come from this country. We've picked it from your system settings - change it if it's not right. You can change this anytime from Preferences.");
        subtitle.set_wrap(true);
        subtitle.set_justify(Gtk.Justification.CENTER);
        subtitle.set_halign(Gtk.Align.CENTER);
        subtitle.add_css_class("dim-label");
        box.append(subtitle);

        var list = new Gtk.ListBox();
        list.set_selection_mode(Gtk.SelectionMode.NONE);
        list.add_css_class("boxed-list");
        list.set_margin_top(16);
        list.append(PrefsRows.country_row(prefs));
        box.append(list);

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

        var title = new Gtk.Label(_("Pick a Theme"));
        title.add_css_class("title-2");
        title.set_halign(Gtk.Align.CENTER);
        title.set_margin_top(12);
        box.append(title);

        var subtitle = new Gtk.Label(_("You can change this anytime from Preferences."));
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

            var badge = CheckIconUtils.new_image(14, true);
            badge.add_css_class("onboarding-source-badge");
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

        swatch_row.append(make_theme_tile("system", _("Follow System")));
        swatch_row.append(make_theme_tile("light", _("Light")));
        swatch_row.append(make_theme_tile("dark", _("Dark")));

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

    private delegate bool TileToggleFunc();

    // A tappable tile with a check badge in its corner, for the onboarding
    // pickers' independent on/off choices. on_toggle flips the choice and
    // returns the new state.
    private static Gtk.Widget make_toggle_tile(Gtk.Widget art, string title_text, bool initially_on, owned TileToggleFunc on_toggle, int tile_height = 96) {
        var tile_frame = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        tile_frame.add_css_class("onboarding-source-tile");
        tile_frame.set_halign(Gtk.Align.CENTER);
        tile_frame.set_valign(Gtk.Align.CENTER);
        tile_frame.set_size_request(96, tile_height);

        tile_frame.append(art);

        var badge = CheckIconUtils.new_image(14, true);
        badge.add_css_class("onboarding-source-badge");
        badge.set_halign(Gtk.Align.END);
        badge.set_valign(Gtk.Align.START);
        badge.set_margin_end(-4);
        badge.set_margin_top(-4);
        badge.set_visible(initially_on);

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
        btn.clicked.connect(() => badge.set_visible(on_toggle()));

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

    private static Gtk.Widget build_categories_page(NewsPreferences prefs, NewsWindow? win) {
        var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
        box.set_margin_start(36);
        box.set_margin_end(36);
        box.set_margin_top(36);
        box.set_margin_bottom(18);

        var title = new Gtk.Label("What Do You Want to Read?");
        title.add_css_class("title-2");
        title.set_halign(Gtk.Align.CENTER);
        box.append(title);

        var subtitle = new Gtk.Label("Pick the topics you care about. They show up in the sidebar and make up My Feed - you can change them anytime from Preferences.");
        subtitle.set_wrap(true);
        subtitle.set_justify(Gtk.Justification.CENTER);
        subtitle.set_halign(Gtk.Align.CENTER);
        subtitle.add_css_class("dim-label");
        box.append(subtitle);

        var grid = new Gtk.FlowBox();
        grid.add_css_class("onboarding-sources-grid");
        grid.set_selection_mode(Gtk.SelectionMode.NONE);
        grid.set_homogeneous(true);
        grid.set_row_spacing(12);
        grid.set_column_spacing(16);
        grid.set_valign(Gtk.Align.START);
        // Room for the top row's badge, which pokes above its tile
        grid.set_margin_top(18);
        grid.set_max_children_per_line(3);
        grid.set_min_children_per_line(3);

        foreach (var cat in NewsPreferences.ALL_CATEGORIES) {
            // The sidebar's names for these categories ("World News", not "General")
            string display_name = win != null ? win.category_display_name_for(cat) : FetcherUtils.category_display_name(cat);

            var art = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
            art.set_valign(Gtk.Align.CENTER);
            var icon = new Gtk.Image();
            icon.set_pixel_size(28);
            string? icon_file = CategoryIconsUtils.icon_file_for(cat);
            string? icon_path = icon_file != null ? CategoryIconsUtils.resolve_themed_icon_path(icon_file) : null;
            if (icon_path != null) icon.set_from_file(icon_path);
            art.append(icon);
            var label = new Gtk.Label(display_name);
            label.add_css_class("caption");
            label.set_wrap(true);
            label.set_justify(Gtk.Justification.CENTER);
            art.append(label);

            string category_id = cat;
            grid.append(make_toggle_tile(art, display_name, prefs.category_enabled(category_id), () => {
                // Keep the user's order: a newly chosen category goes last
                var chosen = prefs.categories;
                bool now_on = !chosen.contains(category_id);
                if (now_on) chosen.add(category_id);
                else chosen.remove(category_id);
                prefs.categories = chosen;
                return now_on;
            }, 72));
        }

        box.append(grid);

        return box;
    }

    private static Gtk.Widget build_sources_page(NewsPreferences prefs) {
        var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
        box.set_margin_start(36);
        box.set_margin_end(36);
        box.set_margin_top(36);
        box.set_margin_bottom(18);

        var title = new Gtk.Label(_("Choose Your Sources"));
        title.add_css_class("title-2");
        title.set_halign(Gtk.Align.CENTER);
        box.append(title);

        var subtitle = new Gtk.Label("Paperboy pulls articles from across the web, including these outlets. Tap any you'd rather not see to hide their articles everywhere - you can change these anytime from Preferences.");
        subtitle.set_wrap(true);
        subtitle.set_justify(Gtk.Justification.CENTER);
        subtitle.set_halign(Gtk.Align.CENTER);
        subtitle.add_css_class("dim-label");
        box.append(subtitle);

        var grid = new Gtk.FlowBox();
        grid.add_css_class("onboarding-sources-grid");
        grid.set_selection_mode(Gtk.SelectionMode.NONE);
        grid.set_homogeneous(true);
        grid.set_row_spacing(16);
        grid.set_column_spacing(16);
        grid.set_valign(Gtk.Align.START);
        // Room for the top row's badge, which pokes above its tile
        grid.set_margin_top(18);
        grid.set_max_children_per_line(3);
        grid.set_min_children_per_line(3);

        foreach (unowned BuiltinSource s in BuiltinSources.ALL) {
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
            string? logo_path = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", s.logo_file));
            if (logo_path != null) picture.set_from_file(logo_path);

            string source_id = s.id;
            grid.append(make_toggle_tile(picture, s.name, prefs.preferred_source_enabled(source_id), () => {
                bool now_enabled = !prefs.preferred_source_enabled(source_id);
                prefs.set_preferred_source_enabled(source_id, now_enabled);
                prefs.save_config();
                return now_enabled;
            }));
        }

        box.append(grid);

        return box;
    }

    // No NewsWindow exists yet during onboarding, so this reuses
    // SportsPrefsGroup.build_league_list_box(prefs, null) - the same
    // drag-reorderable list Preferences shows later - rather than
    // duplicating its enable/reorder logic here.
    private static Gtk.Widget build_sports_page(NewsPreferences prefs) {
        var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
        box.set_margin_start(36);
        box.set_margin_end(36);
        box.set_margin_top(36);
        box.set_margin_bottom(18);

        var title = new Gtk.Label(_("Live Sports Scores"));
        title.add_css_class("title-2");
        title.set_halign(Gtk.Align.CENTER);
        box.append(title);

        var subtitle = new Gtk.Label("See live scores from your favorite leagues right in the Sports category. Choose which leagues to follow and drag to set their order - you can change this anytime from Preferences.");
        subtitle.set_wrap(true);
        subtitle.set_justify(Gtk.Justification.CENTER);
        subtitle.set_halign(Gtk.Align.CENTER);
        subtitle.add_css_class("dim-label");
        box.append(subtitle);

        var master_row = new Adw.SwitchRow();
        master_row.set_title(_("Show Score Cards"));
        master_row.set_active(prefs.sports_scores_enabled);

        var master_list_box = new Gtk.ListBox();
        master_list_box.set_selection_mode(Gtk.SelectionMode.NONE);
        master_list_box.add_css_class("boxed-list");
        master_list_box.set_margin_top(16);
        master_list_box.append(master_row);

        var scroller = new Gtk.ScrolledWindow();
        scroller.set_vexpand(true);
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        scroller.set_margin_top(12);

        var sports_list_box = SportsPrefsGroup.build_league_list_box(prefs, null);
        sports_list_box.set_sensitive(prefs.sports_scores_enabled);
        scroller.set_child(sports_list_box);

        master_row.notify["active"].connect(() => {
            bool enabled = master_row.get_active();
            prefs.sports_scores_enabled = enabled;
            sports_list_box.set_sensitive(enabled);
        });

        box.append(master_list_box);
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

        var title = new Gtk.Label(_("Local News, Too"));
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

        var location_btn = new Gtk.Button.with_label(_("Set My Location"));
        location_btn.set_halign(Gtk.Align.CENTER);
        location_btn.set_margin_top(12);
        location_btn.clicked.connect(() => {
            LocationDialog.show(parent);
        });
        box.append(location_btn);

        return box;
    }
}
