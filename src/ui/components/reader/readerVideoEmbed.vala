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
 * A poster + play button for a video in reader view. Pressing play opens it in
 * VideoPlayerDialog (see VideoEmbedResolver.for_block); a watch-page link we have
 * no player for opens the page itself instead.
 */
public class ReaderVideoEmbed : Gtk.Box {
    private ArticleBlockKind kind;
    private string? video_url;
    private NewsWindow? parent_window;

    public ReaderVideoEmbed(ArticleBlockKind kind, string? video_url, string? poster_url, NewsWindow? parent_window) {
        Object(orientation: Gtk.Orientation.VERTICAL);
        this.kind = kind;
        this.video_url = video_url;
        this.parent_window = parent_window;

        add_css_class("reader-video-embed");
        set_size_request(-1, 405);

        var overlay = new Gtk.Overlay();
        overlay.set_hexpand(true);
        overlay.set_vexpand(true);
        append(overlay);

        if (poster_url != null && poster_url.length > 0 && parent_window != null && parent_window.image_manager != null) {
            var poster_pic = new Gtk.Picture();
            poster_pic.set_content_fit(Gtk.ContentFit.COVER);
            poster_pic.add_css_class("reader-video-poster");
            parent_window.image_manager.load_image_async(poster_pic, poster_url, 720, 405);
            overlay.set_child(poster_pic);
        } else {
            var placeholder = new Gtk.Image.from_icon_name("video-x-generic-symbolic");
            placeholder.add_css_class("reader-video-poster");
            placeholder.set_pixel_size(64);
            placeholder.set_halign(Gtk.Align.CENTER);
            placeholder.set_valign(Gtk.Align.CENTER);
            placeholder.set_hexpand(true);
            placeholder.set_vexpand(true);
            overlay.set_child(placeholder);
        }

        var play_btn = new Gtk.Button.from_icon_name("media-playback-start-symbolic");
        play_btn.add_css_class("reader-video-play-button");
        play_btn.add_css_class("circular");
        play_btn.set_halign(Gtk.Align.CENTER);
        play_btn.set_valign(Gtk.Align.CENTER);
        play_btn.clicked.connect(start_playback);
        overlay.add_overlay(play_btn);

        // Labelled so tapping it reads as "leaves the reader" rather than "broken".
        if (kind == ArticleBlockKind.VIDEO_LINK && (video_url == null || VideoEmbedResolver.for_url(video_url) == null)) {
            var watch_label = new Gtk.Label(_("Watch on site"));
            watch_label.add_css_class("reader-video-watch-label");
            watch_label.set_halign(Gtk.Align.START);
            watch_label.set_valign(Gtk.Align.END);
            overlay.add_overlay(watch_label);
        }
    }

    private void start_playback() {
        if (video_url == null || parent_window == null) return;

        var embed = VideoEmbedResolver.for_block(kind, video_url);
        if (embed != null) {
            VideoPlayerDialog.show(parent_window, embed, "Video");
            return;
        }

        var sheet = new ArticleSheet(parent_window);
        parent_window.root_overlay.add_overlay(sheet.get_widget());
        sheet.closed.connect(() => {
            parent_window.root_overlay.remove_overlay(sheet.get_widget());
            sheet.destroy();
        });
        // Web view, not reader view: an in-house player won't survive the reader extractor.
        sheet.open(video_url, false);
    }
}
