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

/**
 * A video clip card for the Sports "Highlights" row. Built once and reused
 * across polls via update(), same as ScoreCard. Clicking opens
 * VideoPlayerDialog.
 */
public class HighlightCard : GLib.Object {
    public Gtk.Box root;

    private weak NewsWindow? window;
    private int col_w;
    private int img_h;
    private Gtk.Picture thumbnail;
    private Gtk.Label duration_label;
    private Gtk.Label headline_label;
    private Gtk.Label caption_label;

    // Same structure and sizing as ArticleCard, so the row fits these exactly like article rows.
    public HighlightCard(VideoHighlight highlight, NewsWindow window) {
        GLib.Object();
        this.window = window;

        var lm = window.layout_manager;
        col_w = lm == null ? 400 : (lm.cached_col_w > 0 ? lm.cached_col_w : lm.estimate_column_width(lm.columns_count));
        img_h = Managers.ArticleManager.CARD_IMAGE_HEIGHT;

        root = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        root.add_css_class("card");
        root.set_hexpand(true);
        root.set_halign(Gtk.Align.FILL);
        root.set_size_request(col_w, -1);

        thumbnail = new Gtk.Picture();
        thumbnail.set_halign(Gtk.Align.FILL);
        thumbnail.set_valign(Gtk.Align.START);
        thumbnail.set_hexpand(true);
        thumbnail.set_vexpand(false);
        thumbnail.set_size_request(col_w, img_h);
        thumbnail.set_content_fit(Gtk.ContentFit.COVER);
        thumbnail.set_can_shrink(true);

        var play_icon = new Gtk.Image.from_icon_name("media-playback-start-symbolic");
        play_icon.add_css_class("highlight-card-play");
        play_icon.set_halign(Gtk.Align.CENTER);
        play_icon.set_valign(Gtk.Align.CENTER);
        play_icon.set_can_target(false);

        duration_label = new Gtk.Label("");
        duration_label.add_css_class("highlight-card-duration");
        duration_label.set_halign(Gtk.Align.END);
        duration_label.set_valign(Gtk.Align.END);
        duration_label.set_can_target(false);

        var overlay = new Gtk.Overlay();
        overlay.set_child(thumbnail);
        overlay.add_overlay(play_icon);
        overlay.add_overlay(duration_label);
        overlay.set_valign(Gtk.Align.START);
        overlay.set_vexpand(false);
        overlay.set_size_request(-1, img_h);
        root.append(overlay);

        var title_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
        title_box.set_margin_start(12);
        title_box.set_margin_end(12);
        title_box.set_margin_top(12);
        title_box.set_margin_bottom(12);
        title_box.set_vexpand(false);
        title_box.set_valign(Gtk.Align.START);
        title_box.set_size_request(-1, ArticleCard.TITLE_AREA_HEIGHT);

        headline_label = new Gtk.Label("");
        headline_label.add_css_class("article-card-title");
        headline_label.set_ellipsize(Pango.EllipsizeMode.END);
        headline_label.set_xalign(0);
        headline_label.set_valign(Gtk.Align.START);
        headline_label.set_wrap(true);
        headline_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        headline_label.set_size_request(col_w - 24, -1);
        headline_label.set_lines(3);
        title_box.append(headline_label);

        caption_label = new Gtk.Label("");
        caption_label.add_css_class("article-card-time");
        caption_label.set_xalign(0);
        caption_label.set_ellipsize(Pango.EllipsizeMode.END);
        caption_label.set_valign(Gtk.Align.END);
        caption_label.set_vexpand(true);
        title_box.append(caption_label);

        root.append(title_box);

        update(highlight);
        wire_interactions(root, window);
    }

    public void update(VideoHighlight highlight) {
        root.set_data<VideoHighlight>("highlight", highlight);

        headline_label.set_text(highlight.headline);
        root.set_tooltip_text(highlight.description);

        string league = SportsScoresService.display_name_for(highlight.league_key);
        string ago = highlight.published != null ? DateUtils.time_ago(highlight.published.format_iso8601()) : "";
        caption_label.set_text(ago.length > 0 ? _("%s · %s").printf(league, ago) : league);

        duration_label.set_text(format_duration(highlight.duration_seconds));
        duration_label.set_visible(highlight.duration_seconds > 0);

        if (highlight.thumbnail_url != null && window != null && window.image_manager != null) {
            window.image_manager.load_image_async(thumbnail, highlight.thumbnail_url, col_w, img_h, false, true);
        }
    }

    private static string format_duration(int seconds) {
        return "%d:%02d".printf(seconds / 60, seconds % 60);
    }

    // Static with unowned aliases so the controllers' closures can't form a ref cycle with root.
    private static void wire_interactions(Gtk.Box root_widget, NewsWindow parent) {
        unowned Gtk.Box r = root_widget;
        unowned NewsWindow w = parent;

        var gesture = new Gtk.GestureClick();
        gesture.set_button(1);
        gesture.released.connect(() => {
            var h = r.get_data<VideoHighlight>("highlight");
            if (h != null) VideoPlayerDialog.show(w, VideoEmbedResolver.espn_clip(h.clip_id), h.headline);
        });
        root_widget.add_controller(gesture);

        var motion = new Gtk.EventControllerMotion();
        motion.enter.connect(() => { r.add_css_class("card-hover"); });
        motion.leave.connect(() => { r.remove_css_class("card-hover"); });
        root_widget.add_controller(motion);
    }
}
