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
using Gdk;
using Cairo;

public class CardBuilder : GLib.Object {

    public CardBuilder() {
        GLib.Object();
    }

    public static string category_display_text(NewsWindow win, string category_id) {
        if (category_id != null && category_id.has_prefix("rssfeed:")) {
            return "Feeds";
        }
        return win.category_display_name_for(category_id);
    }

    public static Gtk.Widget build_category_label(string display_text) {
        var lbl = new Gtk.Label(display_text.up());
        lbl.add_css_class("card-category-label");
        lbl.set_xalign(0);
        lbl.set_valign(Gtk.Align.START);
        lbl.set_ellipsize(Pango.EllipsizeMode.END);
        return lbl;
    }

    private static Gtk.Box create_badge_box() {
        var box = new Gtk.Box(Orientation.HORIZONTAL, 6);
        box.add_css_class("source-badge");
        box.set_margin_bottom(8);
        box.set_margin_end(8);
        box.set_valign(Gtk.Align.END);
        box.set_halign(Gtk.Align.END);
        return box;
    }

    private static Gtk.Box create_logo_wrapper() {
        var logo_wrapper = new Gtk.Box(Orientation.HORIZONTAL, 0);
        logo_wrapper.add_css_class("circular-logo");
        logo_wrapper.set_valign(Gtk.Align.CENTER);
        logo_wrapper.set_halign(Gtk.Align.CENTER);

        // Pin to 24 logical px - a Gtk.Picture's natural size is its texture's pixel
        // size, so HiDPI textures (24 * scale factor) would otherwise grow the badge.
        logo_wrapper.set_layout_manager(new Gtk.CustomLayout(null,
            (w, orientation, for_size, out minimum, out natural, out min_baseline, out nat_baseline) => {
                minimum = natural = 24;
                min_baseline = nat_baseline = -1;
            },
            (w, width, height, baseline) => {
                for (var c = w.get_first_child(); c != null; c = c.get_next_sibling()) {
                    c.allocate(width, height, baseline, null);
                }
            }));

        return logo_wrapper;
    }

    // Fits the icon into a (24 * scale)px square, preserving aspect.
    private static Gdk.Pixbuf? load_scaled_icon_pixbuf(string icon_path, int scale) {
        Gdk.Pixbuf? probe = ImageCache.get_global().get_or_load_file(
            "pixbuf::file:%s::%dx%d".printf(icon_path, 0, 0),
            icon_path,
            0,
            0
        );

        if (probe == null) {
            return null;
        }

        int orig_w = probe.get_width();
        int orig_h = probe.get_height();
        double target = 24.0 * scale;

        double factor = 1.0;
        if (orig_w > 0 && orig_h > 0) {
            factor = double.min(target / orig_w, target / orig_h);
        }

        int sw = int.max(1, (int)(orig_w * factor));
        int sh = int.max(1, (int)(orig_h * factor));

        string key = "pixbuf::file:%s::%dx%d".printf(icon_path, sw, sh);
        return ImageCache.get_global().get_or_load_file(key, icon_path, sw, sh);
    }

    private static Gtk.Picture? load_and_scale_icon(string icon_path) {
        if (icon_path == null || !GLib.FileUtils.test(icon_path, GLib.FileTest.EXISTS)) {
            return null;
        }

        Gdk.Pixbuf? scaled_pb = load_scaled_icon_pixbuf(icon_path, 1);
        if (scaled_pb == null) {
            return null;
        }

        var pic = new Gtk.Picture();
        pic.set_paintable(Gdk.Texture.for_pixbuf(scaled_pb));
        pic.set_content_fit(Gtk.ContentFit.CONTAIN);
        pic.set_halign(Gtk.Align.CENTER);
        pic.set_valign(Gtk.Align.CENTER);

        // Scale factor is only known once realized; re-render so HiDPI logos stay sharp.
        pic.realize.connect(() => {
            int scale = pic.get_scale_factor();
            if (scale <= 1) return;
            Gdk.Pixbuf? hi_pb = load_scaled_icon_pixbuf(icon_path, scale);
            if (hi_pb != null) pic.set_paintable(Gdk.Texture.for_pixbuf(hi_pb));
        });

        return pic;
    }

    private static Gtk.Box? create_logo_wrapper_from_url(NewsWindow win, string image_url) {
        if (win.image_manager == null) {
            return null;
        }

        var logo_wrapper = create_logo_wrapper();

        var pic = new Gtk.Picture();
        pic.set_valign(Gtk.Align.CENTER);
        pic.set_halign(Gtk.Align.CENTER);
        pic.set_content_fit(Gtk.ContentFit.CONTAIN);
        pic.set_size_request(24, 24);

        win.image_manager.load_image_async(pic, image_url, 24, 24);

        logo_wrapper.append(pic);

        return logo_wrapper;
    }



    private static Gtk.Label create_source_badge_label(string text, int max_width_chars = 14) {
        var lbl = new Gtk.Label(text);
        lbl.add_css_class("source-badge-label");
        lbl.set_valign(Gtk.Align.CENTER);
        lbl.set_xalign(0.5f);
        lbl.set_ellipsize(Pango.EllipsizeMode.END);
        lbl.set_max_width_chars(max_width_chars);
        return lbl;
    }

    private static Gtk.Box? create_logo_wrapper_from_file(string? icon_path) {
        if (icon_path == null) {
            return null;
        }
        Gtk.Picture? pic = load_and_scale_icon(icon_path);
        if (pic == null) {
            return null;
        }
        var logo_wrapper = create_logo_wrapper();
        logo_wrapper.append(pic);
        return logo_wrapper;
    }

    public static Gtk.Widget build_source_badge(NewsSource source) {
        var box = create_badge_box();

        string? path = BuiltinSources.logo_path(source);
        if (path != null) {
            Gtk.Box? logo_wrapper = create_logo_wrapper_from_file(path);
            if (logo_wrapper != null) {
                box.append(logo_wrapper);
            }
        }

        var lbl = create_source_badge_label(BuiltinSources.short_name(source), 12);
        box.append(lbl);

        return box;
    }

    private static Gtk.Widget build_badge_with_optional_logo(string display_text, Gtk.Box? logo_wrapper) {
        var box = create_badge_box();
        if (logo_wrapper != null) {
            box.append(logo_wrapper);
        }
        var lbl = create_source_badge_label(display_text);
        box.append(lbl);
        return box;
    }

    // Tries to load a source logo in order: saved local file -> metadata logo URL -> Google favicon -> RSS favicon.
    private static Gtk.Box? try_load_icon_from_metadata(NewsWindow win, string? meta_filename, string? meta_logo_url, string? rss_url, string? rss_favicon_url) {
        if (meta_filename != null) {
            var data_dir = GLib.Environment.get_user_data_dir();
            var icon_path = GLib.Path.build_filename(data_dir, "paperboy", "source_logos", meta_filename);
            Gtk.Box? wrapper = create_logo_wrapper_from_file(icon_path);
            if (wrapper != null) {
                return wrapper;
            }
        }

        string? logo_url = SourceMetadata.pick_logo_url(meta_logo_url, rss_url, rss_favicon_url);
        if (logo_url != null) return create_logo_wrapper_from_url(win, logo_url);

        return null;
    }

    private static string get_final_display_name(string? display_name, string? source_name) {
        if (display_name != null && display_name.length > 0) {
            return display_name;
        }
        if (source_name != null && source_name.length > 0) {
            return source_name;
        }
        return "News";
    }

    // Adds a card's source badge. With `followable` (Front Page and search, where you find
    // sources you may not follow), a follow button or check slides out of it on hover.
    public static void attach_source_badge(NewsWindow win, Gtk.Widget card_root, Gtk.Overlay overlay, Gtk.Widget badge, string url, string? source_name, bool followable) {
        overlay.add_overlay(badge);
        if (followable) make_badge_followable(win, card_root, badge, url, source_name);
    }

    // Adds the hover follow button to a badge wherever it's placed (on the image or in a card's text area).
    public static void make_badge_followable(NewsWindow win, Gtk.Widget card_root, Gtk.Widget badge, string url, string? source_name) {
        var badge_box = badge as Gtk.Box;
        if (badge_box == null) return;

        Gtk.Label? name_label = null;
        for (var c = badge_box.get_first_child(); c != null; c = c.get_next_sibling()) {
            if (c is Gtk.Label) name_label = (Gtk.Label) c;
        }
        string? source_label = name_label != null ? name_label.get_text() : null;

        var follow_btn = new Gtk.Button.from_icon_name("list-add-symbolic");
        follow_btn.add_css_class("source-badge-follow-btn");
        follow_btn.set_valign(Gtk.Align.CENTER);
        follow_btn.clicked.connect(() => {
            if (is_source_followed(url)) return;
            if (!SourceManager.is_article_from_builtin(url)) win.show_persistent_toast("Searching for feed...");
            win.source_manager.follow_rss_source(url, source_name);
        });

        var divider = new Gtk.Separator(Gtk.Orientation.VERTICAL);
        divider.add_css_class("source-badge-divider");

        var follow_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        follow_row.append(follow_btn);
        follow_row.append(divider);

        var revealer = new Gtk.Revealer();
        revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_LEFT);
        revealer.set_transition_duration(200);
        revealer.set_child(follow_row);
        // Hidden once collapsed, so the badge's spacing doesn't leave a gap.
        revealer.set_visible(false);
        revealer.notify["child-revealed"].connect((obj, pspec) => {
            var r = (Gtk.Revealer) obj;
            if (!r.get_reveal_child() && !r.get_child_revealed()) {
                r.set_visible(false);
                // Undo fit_badge_for_follow()'s trim once the slide back has finished.
                if (name_label != null && source_label != null) name_label.set_text(source_label);
            }
        });
        badge_box.prepend(revealer);

        badge_box.set_data("follow-source-btn", follow_btn);
        badge_box.set_data("follow-source-revealer", revealer);
        badge_box.set_data<string>("follow-source-name", source_label ?? "this source");
        badge_box.set_data<string>("follow-source-url", url);
        if (name_label != null) badge_box.set_data("follow-source-label", name_label);
        card_root.set_data("source-badge", badge_box);
    }

    // Hover "reader view" / "preview" buttons for a card image's top-right corner, connected by
    // ArticleCard.wire_interactions(). Always built so the hover-actions pref can toggle them live.
    public static Gtk.Box build_hover_actions(Gtk.Widget root, NewsWindow? window) {
        bool enabled = window == null || window.prefs == null || window.prefs.card_hover_actions_enabled;
        var hover_actions = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 2);
        hover_actions.add_css_class("card-hover-actions");
        hover_actions.set_halign(Gtk.Align.END);
        hover_actions.set_valign(Gtk.Align.START);
        hover_actions.set_margin_top(8);
        hover_actions.set_margin_end(8);
        hover_actions.set_visible(enabled);

        var quick_reader_btn = new Gtk.Button();
        quick_reader_btn.add_css_class("card-hover-action-btn");
        quick_reader_btn.set_tooltip_text("Open in reader view");
        var quick_reader_icon = new Gtk.Image.from_icon_name("view-paged-symbolic");
        quick_reader_icon.set_pixel_size(20);
        quick_reader_btn.set_child(quick_reader_icon);
        hover_actions.append(quick_reader_btn);

        var hover_divider = new Gtk.Separator(Gtk.Orientation.VERTICAL);
        hover_divider.add_css_class("source-badge-divider");
        hover_actions.append(hover_divider);

        var quick_pane_btn = new Gtk.Button();
        quick_pane_btn.add_css_class("card-hover-action-btn");
        quick_pane_btn.set_tooltip_text("Preview article");
        var quick_pane_icon = new Gtk.Image.from_icon_name("view-reveal-symbolic");
        quick_pane_icon.set_pixel_size(20);
        quick_pane_btn.set_child(quick_pane_icon);
        hover_actions.append(quick_pane_btn);

        root.set_data("quick-reader-btn", quick_reader_btn);
        root.set_data("quick-pane-btn", quick_pane_btn);
        root.set_data("hover-actions-box", hover_actions);
        return hover_actions;
    }

    // Hover-only thumbs up/down pill in the bottom-left of a Front Page card's image; votes feed InterestProfile.
    public static void attach_feedback_buttons(NewsWindow win, Gtk.Widget card_root, Gtk.Overlay overlay, string url, string title, string? source_name, string? category_id) {
        if (win.prefs == null || win.prefs.category != "frontpage" || win.article_state_store == null) return;

        var box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 2);
        box.add_css_class("card-feedback");
        box.set_halign(Gtk.Align.START);
        box.set_valign(Gtk.Align.END);
        box.set_margin_start(8);
        // Matches the source badge's bottom edge (8px here + 8px from its CSS margin).
        box.set_margin_bottom(16);
        box.set_opacity(0);

        var up = build_feedback_button("thumbs-up", "More like this");
        box.append(up);
        var divider = new Gtk.Separator(Gtk.Orientation.VERTICAL);
        divider.add_css_class("source-badge-divider");
        box.append(divider);
        var down = build_feedback_button("thumbs-down", "Less like this");
        box.append(down);

        string norm = win.normalize_article_url(url);
        // Unowned so the buttons' own handlers don't keep them (or the store) alive.
        unowned ArticleStateStore store = win.article_state_store;
        unowned NewsWindow win_ref = win;
        unowned Gtk.Button up_ref = up;
        unowned Gtk.Button down_ref = down;
        show_feedback_vote(up, down, store.get_feedback(norm));

        up.clicked.connect(() => {
            int vote = store.get_feedback(norm) > 0 ? 0 : 1;
            store.set_feedback(norm, title, source_name, category_id, vote);
            show_feedback_vote(up_ref, down_ref, vote);
            win_ref.show_toast(feedback_toast_text(vote));
        });
        down.clicked.connect(() => {
            int vote = store.get_feedback(norm) < 0 ? 0 : -1;
            store.set_feedback(norm, title, source_name, category_id, vote);
            show_feedback_vote(up_ref, down_ref, vote);
            win_ref.show_toast(feedback_toast_text(vote));
        });

        overlay.add_overlay(box);
        card_root.set_data("feedback-pill", box);
    }

    // Called from a card's hover handler, alongside set_follow_revealed().
    public static void set_feedback_revealed(Gtk.Widget card_root, bool revealed) {
        var pill = card_root.get_data<Gtk.Widget>("feedback-pill");
        if (pill != null) Managers.AnimationManager.fade_opacity(pill, revealed ? 1.0 : 0.0);
    }

    private static Gtk.Button build_feedback_button(string glyph, string tooltip) {
        var btn = new Gtk.Button();
        btn.add_css_class("card-feedback-btn");
        btn.set_tooltip_text(tooltip);
        string? path = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "symbolic", glyph + "-mono-white.svg"));
        if (path != null) {
            // FileIcon so the SVG is rendered at the display's scale.
            var icon = new Gtk.Image.from_gicon(new GLib.FileIcon(GLib.File.new_for_path(path)));
            icon.set_pixel_size(14);
            btn.set_child(icon);
        }
        return btn;
    }

    private static string feedback_toast_text(int vote) {
        if (vote > 0) return "You'll see more articles like this";
        if (vote < 0) return "You'll see fewer articles like this";
        return "Rating removed";
    }

    private static void show_feedback_vote(Gtk.Button up, Gtk.Button down, int vote) {
        if (vote > 0) up.add_css_class("voted"); else up.remove_css_class("voted");
        if (vote < 0) down.add_css_class("voted"); else down.remove_css_class("voted");
    }

    // Called from a card's hover handler. Refreshes the follow state on each
    // reveal, since following finishes asynchronously.
    public static void set_follow_revealed(Gtk.Widget card_root, bool revealed) {
        var badge = card_root.get_data<Gtk.Widget>("source-badge");
        if (badge == null) return;
        var revealer = badge.get_data<Gtk.Revealer>("follow-source-revealer");
        var btn = badge.get_data<Gtk.Button>("follow-source-btn");
        string? url = badge.get_data<string>("follow-source-url");
        if (revealer == null || btn == null || url == null) return;
        if (!revealed) {
            revealer.set_reveal_child(false);
            return;
        }

        bool followed = is_source_followed(url);
        string name = badge.get_data<string>("follow-source-name");
        btn.set_icon_name(followed ? CheckIconUtils.icon_name() : "list-add-symbolic");
        btn.set_tooltip_text(followed ? "Following " + name : "Follow " + name);
        if (followed) {
            btn.add_css_class("following");
        } else {
            btn.remove_css_class("following");
        }

        fit_badge_for_follow(card_root, badge, revealer);
        revealer.set_visible(true);
        revealer.set_reveal_child(true);
    }

    // On narrow cards (e.g. Trending) a long source name plus the revealed follow button would slide
    // the badge under the thumbs pill and make it unclickable. So before the reveal starts, the name is
    // trimmed once to the width it can have with the button open - the slide then plays with a still
    // label, like every other card. The full name comes back after the collapse (see make_badge_followable).
    // Measured on hover since the card's sizes aren't known until it's shown.
    private static void fit_badge_for_follow(Gtk.Widget card_root, Gtk.Widget badge, Gtk.Revealer revealer) {
        var pill = card_root.get_data<Gtk.Widget>("feedback-pill");
        var label = badge.get_data<Gtk.Label>("follow-source-label");
        string? full_name = badge.get_data<string>("follow-source-name");
        var overlay = badge.get_parent();
        // Only a badge on the image, beside the pill, can collide with it - not one in a
        // card's text area (e.g. history cards).
        if (pill == null || label == null || full_name == null || overlay == null || pill.get_parent() != overlay) return;

        label.set_text(full_name);
        badge.set_margin_start(0);
        int pill_w, badge_w, row_w, label_w, unused;
        pill.measure(Gtk.Orientation.HORIZONTAL, -1, out unused, out pill_w, null, null);
        badge.measure(Gtk.Orientation.HORIZONTAL, -1, out unused, out badge_w, null, null);
        revealer.get_child().measure(Gtk.Orientation.HORIZONTAL, -1, out unused, out row_w, null, null);
        label.measure(Gtk.Orientation.HORIZONTAL, -1, out unused, out label_w, null, null);

        int reserved = pill.get_margin_start() + pill_w + 6;
        // Safety net: GtkOverlay never allocates a child wider than itself, so this margin keeps the
        // badge off the pill even if the trim below comes up a pixel short.
        badge.set_margin_start(reserved);

        // The revealed row joins the badge with its 6px box spacing.
        int excess = badge_w + row_w + 6 - (overlay.get_width() - reserved);
        if (excess > 0) label.set_text(ellipsize_to_width(label, full_name, label_w - excess));
    }

    // Longest prefix of `text` (plus "…") that renders within `max_px` in `label`'s font.
    private static string ellipsize_to_width(Gtk.Label label, string text, int max_px) {
        var layout = label.create_pango_layout(null);
        for (int n = text.char_count() - 1; n > 0; n--) {
            string candidate = text.substring(0, text.index_of_nth_char(n)).chomp() + "…";
            layout.set_text(candidate, -1);
            int w, h;
            layout.get_pixel_size(out w, out h);
            if (w <= max_px) return candidate;
        }
        return "…";
    }

    // Built-in sources are followed while switched on in Preferences, others while they're a followed feed.
    public static bool is_source_followed(string url) {
        NewsSource builtin = SourceManager.builtin_source_for_article(url);
        if (builtin != NewsSource.UNKNOWN) {
            return NewsPreferences.get_instance().preferred_source_enabled(BuiltinSources.for_source(builtin).id);
        }
        return Paperboy.RssSourceStore.get_instance().is_article_host_followed(url);
    }

    public static Gtk.Widget build_source_badge_dynamic(NewsWindow win, string? source_name, string? url, string? category_id) {
        var label = SourceLabel.parse(source_name);
        string? display_name = label.name;
        string? provided_logo_url = label.logo_url;

        // For My Feed: first try SourceMetadata, then fall back to matching an RSS source by name or URL/domain.
        if (category_id == "myfeed") {
            string? meta_logo_url = null;
            string? meta_filename = null;
            string? meta_display_name = null;

            if (display_name != null && display_name.length > 0) {
                meta_logo_url = SourceMetadata.get_logo_url_for_source(display_name);
                meta_filename = SourceMetadata.get_saved_filename_for_source(display_name);
                meta_display_name = SourceMetadata.get_display_name_for_source(display_name);
            }

            if (meta_logo_url == null && meta_filename == null && url != null && url.length > 0) {
                string? url_display_name = null;
                string? url_logo_url = null;
                string? url_filename = null;
                SourceMetadata.get_source_info_by_url(url, out url_display_name, out url_logo_url, out url_filename);
                if (url_display_name != null || url_logo_url != null || url_filename != null) {
                    meta_display_name = url_display_name;
                    meta_logo_url = url_logo_url;
                    meta_filename = url_filename;
                }
            }

            if (meta_logo_url != null || meta_filename != null) {
                if (meta_display_name != null && meta_display_name.length > 0) {
                    display_name = meta_display_name;
                }
                Gtk.Box? logo_wrapper = try_load_icon_from_metadata(win, meta_filename, meta_logo_url, null, null);
                return build_badge_with_optional_logo(display_name != null ? display_name : "", logo_wrapper);
            }
        }

        if (provided_logo_url == null && category_id == "myfeed") {
            var rss_store = Paperboy.RssSourceStore.get_instance();
            var all_sources = rss_store.get_all_sources();
            foreach (var src in all_sources) {
                bool is_match = false;

                if (source_name != null && source_name == src.name) {
                    is_match = true;
                }

                if (!is_match && url != null && url.length > 0) {
                    string src_host = UrlUtils.extract_host_from_url(src.url);
                    string article_host = UrlUtils.extract_host_from_url(url);
                    if (src_host != null && article_host != null && src_host == article_host) {
                        is_match = true;
                    }
                }

                if (is_match) {
                    string final_display_name = SourceLabel.name_of(src.name);

                    string? meta_logo_url = SourceMetadata.get_logo_url_for_source(final_display_name);
                    string? meta_filename = SourceMetadata.get_saved_filename_for_source(final_display_name);

                    Gtk.Box? logo_wrapper = try_load_icon_from_metadata(win, meta_filename, meta_logo_url, src.url, src.favicon_url);
                    return build_badge_with_optional_logo(final_display_name, logo_wrapper);
                }
            }
        }

        if (provided_logo_url == null && display_name != null && display_name.length > 0) {
            NewsSource resolved = BuiltinSources.from_name(display_name);
            if (resolved != NewsSource.UNKNOWN) {
                return build_source_badge(resolved);
            }
        }

        if (provided_logo_url == null && display_name != null && display_name.length > 0) {
            string? meta_logo_url = SourceMetadata.get_logo_url_for_source(display_name);
            string? meta_filename = SourceMetadata.get_saved_filename_for_source(display_name);
            
            if (meta_logo_url != null || meta_filename != null) {
                Gtk.Box? logo_wrapper = try_load_icon_from_metadata(win, meta_filename, meta_logo_url, null, null);
                return build_badge_with_optional_logo(display_name, logo_wrapper);
            }
        }

        bool is_aggregated = (category_id != null && (category_id == "frontpage" || category_id == "topten" || category_id == "myfeed"));
        if (is_aggregated && display_name != null && display_name.length > 0 && provided_logo_url == null) {
            return build_badge_with_optional_logo(display_name, null);
        }

        if (provided_logo_url != null) {
            provided_logo_url = provided_logo_url.strip();
            if (provided_logo_url.has_prefix("//")) provided_logo_url = "https:" + provided_logo_url;
        }

        if (provided_logo_url != null && (provided_logo_url.has_prefix("http://") || provided_logo_url.has_prefix("https://"))) {
            Gtk.Box? logo_wrapper = create_logo_wrapper_from_url(win, provided_logo_url);
            string final_display = get_final_display_name(display_name, source_name);
            return build_badge_with_optional_logo(final_display, logo_wrapper);
        }

        if (display_name != null && display_name.length > 0) {
            string low = display_name.down();
            var sb = new StringBuilder();
            for (int i = 0; i < low.length; i++) {
                char c = low[i];
                if (c.isalnum() || c == ' ' || c == '-' || c == '_') sb.append_c(c);
                else sb.append_c(' ');
            }
            string cleaned = sb.str.strip();
            string hyphen = cleaned.replace(" ", "-").replace("--", "-");
            string underscore = cleaned.replace(" ", "_").replace("__", "_");
            string concat = cleaned.replace(" ", "");
            string[] cands = { hyphen, underscore, concat };
            foreach (var cand in cands) {
                string[] paths = {
                    GLib.Path.build_filename("icons", cand + "-logo.png"),
                    GLib.Path.build_filename("icons", cand + "-logo.svg"),
                    GLib.Path.build_filename("icons", "symbolic", cand + "-symbolic.svg"),
                    GLib.Path.build_filename("icons", cand + ".png"),
                    GLib.Path.build_filename("icons", cand + ".svg")
                };
                foreach (var rel in paths) {
                    string? full = DataPathsUtils.find_data_file(rel);
                    if (full != null) {
                        Gtk.Box? logo_wrapper = create_logo_wrapper_from_file(full);
                        string final_display = get_final_display_name(display_name, source_name);
                        return build_badge_with_optional_logo(final_display, logo_wrapper);
                    }
                }
            }
        }

        string final_display = get_final_display_name(display_name, source_name);
        return build_badge_with_optional_logo(final_display, null);
    }

    // Sets a card's time caption, e.g. "7h ago · 5 min read". The base text and
    // URL are kept on the card so refresh_card_time() can redo it later.
    public static void set_card_time(Gtk.Widget card_root, Gtk.Label time_label, string base_text, string url) {
        card_root.set_data("article-time-label", time_label);
        card_root.set_data("article-time-base", base_text);
        card_root.set_data("article-time-url", url);
        refresh_card_time(card_root);
        ReadingTimePrefetchService.enqueue(url);
    }

    public static void refresh_card_time(Gtk.Widget card_root) {
        Gtk.Label? label = card_root.get_data<Gtk.Label>("article-time-label");
        string? base_text = card_root.get_data<string>("article-time-base");
        string? url = card_root.get_data<string>("article-time-url");
        if (label == null || base_text == null || url == null) return;
        string reading = ArticleReadingTimeCache.label_for(ArticleReadingTimeCache.get_instance().get_minutes(url));
        if (reading == "") label.set_text(base_text);
        else if (base_text == "") label.set_text(reading);
        else label.set_text(base_text + " · " + reading);
    }

    // Eye icon represents that the article has been read/viewed.
    public static Gtk.Widget build_viewed_badge() {
        var box = new Gtk.Box(Orientation.HORIZONTAL, 4);
        box.add_css_class("viewed-badge");
        box.set_valign(Gtk.Align.CENTER);

        var icon = new Gtk.Image.from_icon_name("view-reveal-symbolic");
        icon.set_pixel_size(14);
        icon.get_style_context().add_class("viewed-badge-icon");
        icon.set_valign(Gtk.Align.CENTER); icon.set_halign(Gtk.Align.CENTER);
        box.append(icon);

        var lbl = new Gtk.Label("Read");
        lbl.get_style_context().remove_class("dim-label");
        lbl.add_css_class("viewed-badge-label");
        lbl.add_css_class("caption");
        box.append(lbl);
        return box;
    }

    public const int SAVE_RIBBON_HEIGHT = 50;
    public const int SAVE_RIBBON_REST_Y = -8;
    public const int SAVE_RIBBON_HIDDEN_Y = SAVE_RIBBON_REST_Y - SAVE_RIBBON_HEIGHT;

    // Uses Gtk.Fixed with negative Y positioning to poke above the card. Hidden with set_visible(false) when unsaved
    // to avoid reserving space in the layout.
    public static Gtk.Widget build_save_ribbon(bool initially_saved) {
        var tab = new Gtk.Image();
        tab.add_css_class("save-ribbon");
        int icon_px = SAVE_RIBBON_HEIGHT - 6;

        string? asset_path = DataPathsUtils.find_data_file(GLib.Path.build_filename("icons", "symbolic", "save-ribbon.png"));
        if (asset_path != null) {
            var cache = ImageCache.get_global();
            int hi = icon_px * 2;
            string key = "pixbuf::file:%s::%dx%d".printf(asset_path, hi, hi);
            if (cache.get_or_load_file(key, asset_path, hi, hi) != null) {
                var tex = cache.get_texture(key);
                if (tex != null) tab.set_from_paintable(tex);
            }
        }
        if (tab.get_paintable() == null) {
            tab.set_from_icon_name("user-bookmarks-symbolic");
        }
        tab.set_pixel_size(icon_px);
        tab.set_size_request(icon_px, icon_px);
        tab.set_visible(initially_saved);

        var fixed = new Gtk.Fixed();
        //fixed.set_halign(Gtk.Align.END);
        fixed.set_halign(Gtk.Align.START);
        fixed.set_valign(Gtk.Align.START);
        fixed.set_margin_start(8);
        fixed.set_size_request(icon_px, icon_px);
        fixed.put(tab, 0, initially_saved ? SAVE_RIBBON_REST_Y : SAVE_RIBBON_HIDDEN_Y);
        fixed.set_data<Gtk.Widget>("ribbon-image", tab);
        return fixed;
    }

}