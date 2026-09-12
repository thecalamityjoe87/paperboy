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

/*
 * Distraction-free article view: renders an ExtractedArticle (title,
 * byline, hero image, body paragraphs) instead of the live webpage.
 */
public class ReaderView : GLib.Object {
    private Gtk.Stack stack;
    private Gtk.Box content_box;
    private Gtk.ScrolledWindow scroller;
    private Gtk.Spinner spinner;
    private NewsWindow? parent_window;
    private Gtk.MenuButton settings_btn;

    private double font_scale = 1.0;
    private string font_family = "sans";
    private string color_scheme = "auto";

    // One provider shared by every ReaderView instance - the settings are
    // global (backed by gschema), so there's no need for per-instance CSS.
    private static Gtk.CssProvider? style_provider = null;

    public ReaderView(NewsWindow? window) {
        parent_window = window;

        if (parent_window != null && parent_window.prefs != null) {
            font_scale = parent_window.prefs.reader_font_scale;
            font_family = parent_window.prefs.reader_font_family;
            color_scheme = parent_window.prefs.reader_color_scheme;
        }

        if (style_provider == null) {
            style_provider = new Gtk.CssProvider();
            Gtk.StyleContext.add_provider_for_display(
                Gdk.Display.get_default(),
                style_provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            );
        }
        apply_style();

        stack = new Gtk.Stack();
        stack.set_hexpand(true);
        stack.set_vexpand(true);

        var spinner_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
        spinner_box.set_valign(Gtk.Align.CENTER);
        spinner_box.set_halign(Gtk.Align.CENTER);
        spinner = new Gtk.Spinner();
        spinner.set_size_request(32, 32);
        spinner_box.append(spinner);
        var loading_label = new Gtk.Label("Loading reader view…");
        loading_label.add_css_class("dim-label");
        spinner_box.append(loading_label);
        stack.add_named(spinner_box, "loading");

        var error_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
        error_box.set_valign(Gtk.Align.CENTER);
        error_box.set_halign(Gtk.Align.CENTER);
        var error_label = new Gtk.Label("Couldn't extract a reader view for this article.\nTurn off reader view above to read it on the live webpage instead.");
        error_label.add_css_class("dim-label");
        error_label.set_wrap(true);
        error_label.set_justify(Gtk.Justification.CENTER);
        error_label.set_max_width_chars(40);
        error_box.append(error_label);
        stack.add_named(error_box, "error");

        scroller = new Gtk.ScrolledWindow();
        scroller.set_hexpand(true);
        scroller.set_vexpand(true);
        // Same class as content_box, so a custom color scheme's background
        // also covers the side gutters the Adw.Clamp leaves showing on wide
        // windows, instead of just the clamped text column.
        scroller.add_css_class("reader-view");

        var clamp = new Adw.Clamp();
        clamp.set_maximum_size(720);
        clamp.set_tightening_threshold(600);

        content_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 14);
        content_box.add_css_class("reader-view");
        content_box.set_margin_top(24);
        content_box.set_margin_bottom(48);
        content_box.set_margin_start(16);
        content_box.set_margin_end(16);

        clamp.set_child(content_box);
        scroller.set_child(clamp);
        stack.add_named(scroller, "content");

        build_settings_button();
    }

    public Gtk.Widget get_widget() {
        return stack;
    }

    // Placed in ArticleSheet's header, next to the reader-view toggle -
    // only meaningful while reader view is showing, so ArticleSheet toggles
    // its visibility alongside the view itself.
    public Gtk.Widget get_settings_button() {
        return settings_btn;
    }

    private void build_settings_button() {
        settings_btn = new Gtk.MenuButton();
        settings_btn.set_icon_name("font-x-generic-symbolic");
        settings_btn.set_tooltip_text("Reader view settings");
        settings_btn.set_can_focus(false);
        settings_btn.set_visible(false);

        var popover_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 16);
        popover_box.set_margin_top(12);
        popover_box.set_margin_bottom(12);
        popover_box.set_margin_start(12);
        popover_box.set_margin_end(12);
        popover_box.set_size_request(230, -1);

        // ---- Text size ----
        var size_heading = new Gtk.Label("Text size");
        size_heading.add_css_class("heading");
        size_heading.set_xalign(0);
        popover_box.append(size_heading);

        var size_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
        var decrease_btn = new Gtk.Button.from_icon_name("value-decrease-symbolic");
        decrease_btn.set_tooltip_text("Decrease text size");
        var size_pct_label = new Gtk.Label(font_scale_label());
        size_pct_label.set_hexpand(true);
        size_pct_label.set_halign(Gtk.Align.CENTER);
        var increase_btn = new Gtk.Button.from_icon_name("value-increase-symbolic");
        increase_btn.set_tooltip_text("Increase text size");

        decrease_btn.clicked.connect(() => {
            font_scale = double.max(0.8, Math.round((font_scale - 0.1) * 10) / 10.0);
            size_pct_label.set_text(font_scale_label());
            save_and_apply();
        });
        increase_btn.clicked.connect(() => {
            font_scale = double.min(1.6, Math.round((font_scale + 0.1) * 10) / 10.0);
            size_pct_label.set_text(font_scale_label());
            save_and_apply();
        });

        size_row.append(decrease_btn);
        size_row.append(size_pct_label);
        size_row.append(increase_btn);
        popover_box.append(size_row);

        // ---- Font family ----
        var family_heading = new Gtk.Label("Font");
        family_heading.add_css_class("heading");
        family_heading.set_xalign(0);
        popover_box.append(family_heading);

        var family_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        family_row.add_css_class("linked");
        var sans_btn = new Gtk.ToggleButton() { label = "Sans" };
        var serif_btn = new Gtk.ToggleButton() { label = "Serif" };
        var mono_btn = new Gtk.ToggleButton() { label = "Mono" };
        serif_btn.set_group(sans_btn);
        mono_btn.set_group(sans_btn);
        sans_btn.set_active(font_family == "sans");
        serif_btn.set_active(font_family == "serif");
        mono_btn.set_active(font_family == "monospace");
        sans_btn.set_hexpand(true);
        serif_btn.set_hexpand(true);
        mono_btn.set_hexpand(true);

        sans_btn.toggled.connect(() => { if (sans_btn.get_active()) { font_family = "sans"; save_and_apply(); } });
        serif_btn.toggled.connect(() => { if (serif_btn.get_active()) { font_family = "serif"; save_and_apply(); } });
        mono_btn.toggled.connect(() => { if (mono_btn.get_active()) { font_family = "monospace"; save_and_apply(); } });

        family_row.append(sans_btn);
        family_row.append(serif_btn);
        family_row.append(mono_btn);
        popover_box.append(family_row);

        // ---- Color scheme ----
        var color_heading = new Gtk.Label("Color");
        color_heading.add_css_class("heading");
        color_heading.set_xalign(0);
        popover_box.append(color_heading);

        var color_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
        color_row.set_halign(Gtk.Align.START);

        Gtk.ToggleButton? first_swatch = null;
        foreach (var scheme in new string[] { "auto", "light", "sepia", "gray", "dark", "night" }) {
            var swatch = build_color_swatch(scheme);
            if (first_swatch == null) {
                first_swatch = swatch;
            } else {
                swatch.set_group(first_swatch);
            }
            swatch.set_active(color_scheme == scheme);
            swatch.toggled.connect(() => {
                if (swatch.get_active()) { color_scheme = scheme; save_and_apply(); }
            });
            color_row.append(swatch);
        }
        popover_box.append(color_row);

        var popover = new Gtk.Popover();
        popover.set_child(popover_box);
        settings_btn.set_popover(popover);
    }

    private Gtk.ToggleButton build_color_swatch(string scheme) {
        var swatch = new Gtk.ToggleButton();
        swatch.add_css_class("reader-color-swatch");
        swatch.set_tooltip_text(scheme_label(scheme));
        var provider = new Gtk.CssProvider();
        string bg_css = scheme == "auto"
            ? "background-image: linear-gradient(135deg, #ffffff 50%, #1c1c1e 50%);"
            : "background-color: %s;".printf(swatch_css_color(scheme));
        provider.load_from_string(".reader-color-swatch { min-width: 24px; min-height: 24px; border-radius: 50%; padding: 0; border: 1px solid alpha(currentColor, 0.35); %s }".printf(bg_css));
        swatch.get_style_context().add_provider(provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        return swatch;
    }

    private string scheme_label(string scheme) {
        switch (scheme) {
            case "light": return "Light";
            case "sepia": return "Sepia";
            case "gray": return "Gray";
            case "dark": return "Dark";
            case "night": return "Night";
            default: return "Auto (match app theme)";
        }
    }

    private string swatch_css_color(string scheme) {
        switch (scheme) {
            case "light": return "#ffffff";
            case "sepia": return "#f4ecd8";
            case "gray": return "#e8e8e8";
            case "dark": return "#1c1c1e";
            case "night": return "#173a5e";
            default: return "linear-gradient(135deg, #ffffff 50%, #1c1c1e 50%)";
        }
    }

    private string font_scale_label() {
        return "%d%%".printf((int) Math.round(font_scale * 100));
    }

    private void save_and_apply() {
        if (parent_window != null && parent_window.prefs != null) {
            parent_window.prefs.reader_font_scale = font_scale;
            parent_window.prefs.reader_font_family = font_family;
            parent_window.prefs.reader_color_scheme = color_scheme;
        }
        apply_style();
    }

    // Regenerates the shared CSS provider from the current settings.
    // "auto" leaves background/foreground unset so the reader inherits the
    // app's normal theme colors (see .reader-view in style.css); the named
    // schemes override both to a fixed e-reader-style palette.
    private void apply_style() {
        if (style_provider == null) return;

        string bg = "";
        string fg = "";
        string dim_fg = "";
        switch (color_scheme) {
            case "light":
                bg = "#ffffff"; fg = "#1a1a1a"; dim_fg = "rgba(26,26,26,0.6)";
                break;
            case "sepia":
                bg = "#f4ecd8"; fg = "#5b4636"; dim_fg = "rgba(91,70,54,0.65)";
                break;
            case "gray":
                bg = "#e8e8e8"; fg = "#2b2b2b"; dim_fg = "rgba(43,43,43,0.6)";
                break;
            case "dark":
                // Pure white, not a dimmer off-white - that read as flat
                // gray and was hard to read against #1c1c1e.
                bg = "#1c1c1e"; fg = "#ffffff"; dim_fg = "rgba(255,255,255,0.65)";
                break;
            case "night":
                // Swatch stays a vivid navy so the option reads clearly as
                // "blue" in the picker, but the actual reading background is
                // desaturated further so it's easier on the eyes than the
                // swatch's own more saturated preview color. Text is pure
                // white for the same reason as "dark" above.
                bg = "#1a2332"; fg = "#ffffff"; dim_fg = "rgba(255,255,255,0.65)";
                break;
        }

        string family_css;
        switch (font_family) {
            case "serif": family_css = "serif"; break;
            case "monospace": family_css = "monospace"; break;
            default: family_css = "sans-serif"; break;
        }

        double title_size = 1.8 * font_scale;
        double byline_size = 0.95 * font_scale;
        double para_size = 1.15 * font_scale;

        var sb = new StringBuilder();
        if (bg.length > 0) {
            sb.append_printf(".reader-view { background-color: %s; }\n", bg);
        }
        sb.append_printf(
            ".reader-view .reader-title { font-family: %s; font-size: %.2fem; font-weight: 800; line-height: 1.25; %s }\n",
            family_css, title_size, fg.length > 0 ? ("color: " + fg + ";") : ""
        );
        sb.append_printf(
            ".reader-view .reader-byline { font-family: %s; font-size: %.2fem; %s }\n",
            family_css, byline_size, dim_fg.length > 0 ? ("color: " + dim_fg + ";") : "color: alpha(currentColor, 0.6);"
        );
        sb.append_printf(
            // background: none - a bare Gtk.TextView otherwise paints its
            // own opaque page-colored background instead of blending into
            // .reader-view's background like the old per-paragraph labels did.
            ".reader-view .reader-paragraph { font-family: %s; font-size: %.2fem; line-height: 1.6; background: none; %s }\n",
            family_css, para_size, fg.length > 0 ? ("color: " + fg + ";") : ""
        );
        sb.append_printf(
            ".reader-view .reader-source-name { %s }\n",
            fg.length > 0 ? ("color: " + fg + ";") : ""
        );

        style_provider.load_from_string(sb.str);
    }

    public void show_loading() {
        spinner.start();
        stack.set_visible_child_name("loading");
    }

    public void show_error() {
        spinner.stop();
        stack.set_visible_child_name("error");
    }

    // Stops any playing video, clears the article out, and scrolls back to
    // the top - called on close and before loading a new article so state
    // never leaks from one article into the next.
    public void reset() {
        clear_content();
        show_loading();
    }

    private void clear_content() {
        Gtk.Widget? child = content_box.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            if (child is ReaderVideoEmbed) ((ReaderVideoEmbed) child).stop_playback();
            content_box.remove(child);
            child = next;
        }
        scroller.get_vadjustment().set_value(0);
    }

    public void show_article(ExtractedArticle article, string article_url, string? source_name_encoded = null) {
        spinner.stop();

        clear_content();

        string? src_display_name;
        string? src_logo_url;
        string? local_logo_path;
        SourceMetadata.resolve_source_icon(source_name_encoded, article_url, null, out src_display_name, out src_logo_url, out local_logo_path);
        if (src_display_name == null || src_display_name.length == 0) src_display_name = article.site_name;

        if ((src_display_name != null && src_display_name.length > 0) || local_logo_path != null || (src_logo_url != null && src_logo_url.length > 0)) {
            var source_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            source_row.set_margin_bottom(4);

            if (local_logo_path != null || (src_logo_url != null && src_logo_url.length > 0)) {
                var logo_wrapper = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
                logo_wrapper.add_css_class("circular-logo");
                logo_wrapper.set_size_request(44, 44);
                logo_wrapper.set_valign(Gtk.Align.CENTER);

                var logo_pic = new Gtk.Picture();
                logo_pic.set_content_fit(Gtk.ContentFit.COVER);
                logo_pic.set_size_request(44, 44);
                logo_wrapper.append(logo_pic);
                source_row.append(logo_wrapper);

                if (local_logo_path != null) {
                    logo_pic.set_filename(local_logo_path);
                } else if (parent_window != null && parent_window.image_manager != null) {
                    parent_window.image_manager.load_image_async(logo_pic, src_logo_url, 44, 44);
                }
            }

            if (src_display_name != null && src_display_name.length > 0) {
                var source_label = new Gtk.Label(src_display_name);
                source_label.add_css_class("reader-source-name");
                source_label.set_valign(Gtk.Align.CENTER);
                source_row.append(source_label);
            }

            content_box.append(source_row);
        }

        if (article.hero_image_url != null && article.hero_image_url.length > 0) {
            var hero_image = new Gtk.Picture();
            hero_image.set_content_fit(Gtk.ContentFit.COVER);
            hero_image.set_size_request(-1, 320);
            hero_image.add_css_class("reader-hero-image");
            content_box.append(hero_image);
            if (parent_window != null && parent_window.image_manager != null) {
                parent_window.image_manager.load_image_async(hero_image, article.hero_image_url, 720, 320);
            }
        }

        var title_label = new Gtk.Label(article.title.length > 0 ? article.title : "Untitled article");
        title_label.add_css_class("reader-title");
        title_label.set_wrap(true);
        title_label.set_xalign(0);
        title_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        content_box.append(title_label);

        string byline_text = build_byline(article);
        if (byline_text.length > 0) {
            var byline_label = new Gtk.Label(byline_text);
            byline_label.add_css_class("reader-byline");
            byline_label.set_xalign(0);
            content_box.append(byline_label);
        }

        var sep = new Gtk.Separator(Gtk.Orientation.HORIZONTAL);
        sep.set_margin_top(6);
        sep.set_margin_bottom(6);
        content_box.append(sep);

        // Blocks are walked in document order; runs of consecutive TEXT
        // blocks are batched into one Gtk.TextView (not one Gtk.Label per
        // paragraph) so a mouse drag can select continuously within a run -
        // GTK has no way to select text spanning separate widgets, which is
        // why each run still gets its own TextView rather than one shared
        // across an inline image/video. Blank lines between paragraphs
        // stand in for the vertical spacing/wrap-mode labels used to
        // provide.
        var text_run = new Gee.ArrayList<string>();
        foreach (var block in article.blocks) {
            if (block.kind == ArticleBlockKind.TEXT) {
                text_run.add(block.text);
                continue;
            }

            flush_text_run(text_run);

            if (block.kind == ArticleBlockKind.IMAGE && block.image_url != null) {
                var body_image = new Gtk.Picture();
                body_image.set_content_fit(Gtk.ContentFit.COVER);
                body_image.set_size_request(-1, 320);
                body_image.add_css_class("reader-hero-image");
                content_box.append(body_image);
                if (parent_window != null && parent_window.image_manager != null) {
                    parent_window.image_manager.load_image_async(body_image, block.image_url, 720, 320);
                }
            } else if (block.kind == ArticleBlockKind.VIDEO_FILE || block.kind == ArticleBlockKind.VIDEO_EMBED || block.kind == ArticleBlockKind.VIDEO_LINK) {
                if (block.video_url != null) {
                    var embed = new ReaderVideoEmbed(block.kind, block.video_url, block.image_url, parent_window);
                    content_box.append(embed);
                }
            }
        }
        flush_text_run(text_run);

        stack.set_visible_child_name("content");
    }

    private void flush_text_run(Gee.ArrayList<string> text_run) {
        if (text_run.size == 0) return;

        var body_view = new Gtk.TextView();
        body_view.add_css_class("reader-paragraph");
        body_view.set_editable(false);
        body_view.set_cursor_visible(false);
        body_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR);
        body_view.set_hexpand(true);
        body_view.set_left_margin(0);
        body_view.set_right_margin(0);
        var body_buffer = body_view.get_buffer();
        body_buffer.set_text(string.joinv("\n\n", text_run.to_array()));
        content_box.append(body_view);

        text_run.clear();
    }

    private string build_byline(ExtractedArticle article) {
        var parts = new Gee.ArrayList<string>();
        if (article.author != null && article.author.length > 0) parts.add("By " + article.author);
        if (article.published != null && article.published.length > 0) {
            string rel = DateUtils.time_ago(article.published);
            parts.add(rel.length > 0 ? rel : article.published);
        }
        if (article.site_name != null && article.site_name.length > 0) parts.add(article.site_name);
        return string.joinv(" · ", parts.to_array());
    }
}
