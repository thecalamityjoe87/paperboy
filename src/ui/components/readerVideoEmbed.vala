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
 * A poster + play button that swaps itself for a real player on click -
 * a direct-file Gtk.Video (GStreamer) or a WebKit.WebView for a known
 * embed provider - so reader view stays free of any media engine until
 * the user actually presses play.
 */
public class ReaderVideoEmbed : Gtk.Box {
    private ArticleBlockKind kind;
    private string? video_url;
    private NewsWindow? parent_window;
    private Gtk.Overlay overlay;
    private Gtk.Button play_btn;
    private bool playing = false;
    private Gtk.Widget? player_widget;

    // Loading a YouTube/Vimeo/etc "/embed/..." URL directly as the
    // WebView's own top-level page throws YouTube's "Error 153" - its
    // player validates that it's genuinely embedded in a page whose origin
    // it can check, which a bare load_uri() never provides. Serving a
    // one-line HTML wrapper with a real <iframe> from an actual local HTTP
    // origin (and a matching `origin=` param) is the standard fix used by
    // other embedded-WebView apps for the same issue. One server is shared
    // for the app's lifetime rather than one per embed.
    private static Soup.Server? embed_server = null;
    private static uint16 embed_server_port = 0;

    private static void ensure_embed_server() {
        if (embed_server != null) return;

        embed_server = new Soup.Server(null);
        embed_server.add_handler("/embed-wrapper", (server, msg, path, query) => {
            string? target = query != null ? query.lookup("v") : null;
            if (target == null || target.length == 0) {
                msg.set_status(404, null);
                return;
            }
            string origin = "http://127.0.0.1:%u".printf(embed_server_port);
            string sep = target.contains("?") ? "&" : "?";
            string html =
                "<!DOCTYPE html><html><head><style>*{margin:0;padding:0}html,body{width:100%;height:100%;background:#000}iframe{width:100%;height:100%;border:0}</style></head><body><iframe src=\"%s%sorigin=%s\" allow=\"autoplay; encrypted-media; fullscreen\" allowfullscreen></iframe></body></html>"
                    .printf(target, sep, GLib.Uri.escape_string(origin, null, false));
            msg.get_response_headers().set_content_type("text/html", null);
            msg.get_response_body().append(Soup.MemoryUse.COPY, html.data);
            msg.set_status(200, null);
        });

        try {
            embed_server.listen_local(0, 0);
        } catch (GLib.Error e) {
            embed_server = null;
            return;
        }

        foreach (var uri in embed_server.get_uris()) {
            embed_server_port = (uint16) uri.get_port();
            break;
        }
    }

    public ReaderVideoEmbed(ArticleBlockKind kind, string? video_url, string? poster_url, NewsWindow? parent_window) {
        Object(orientation: Gtk.Orientation.VERTICAL);
        this.kind = kind;
        this.video_url = video_url;
        this.parent_window = parent_window;

        add_css_class("reader-video-embed");
        set_size_request(-1, 405);

        overlay = new Gtk.Overlay();
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

        play_btn = new Gtk.Button.from_icon_name("media-playback-start-symbolic");
        play_btn.add_css_class("reader-video-play-button");
        play_btn.add_css_class("circular");
        play_btn.set_halign(Gtk.Align.CENTER);
        play_btn.set_valign(Gtk.Align.CENTER);
        play_btn.clicked.connect(start_playback);
        overlay.add_overlay(play_btn);

        // VIDEO_LINK is a proprietary in-house player we can't play inline
        // (no real stream/iframe URL exists in the page's HTML) - label it
        // so tapping it reads as "leaves the reader" rather than "broken".
        if (kind == ArticleBlockKind.VIDEO_LINK) {
            var watch_label = new Gtk.Label("Watch on site");
            watch_label.add_css_class("reader-video-watch-label");
            watch_label.set_halign(Gtk.Align.START);
            watch_label.set_valign(Gtk.Align.END);
            overlay.add_overlay(watch_label);
        }
    }

    private void start_playback() {
        if (video_url == null) return;

        if (kind == ArticleBlockKind.VIDEO_LINK) {
            if (parent_window == null) return;
            var sheet = new ArticleSheet(parent_window);
            parent_window.root_overlay.add_overlay(sheet.get_widget());
            sheet.closed.connect(() => {
                parent_window.root_overlay.remove_overlay(sheet.get_widget());
                sheet.destroy();
            });
            // Force web view, not reader view - a proprietary player widget
            // like this one won't render at all through the reader-view
            // extractor, which is why we're here in the first place.
            sheet.open(video_url, false);
            return;
        }

        if (playing) return;
        playing = true;
        overlay.remove_overlay(play_btn);

        Gtk.Widget player;
        if (kind == ArticleBlockKind.VIDEO_FILE) {
            var video = new Gtk.Video();
            video.set_file(GLib.File.new_for_uri(video_url));
            video.set_autoplay(true);
            video.set_hexpand(true);
            video.set_vexpand(true);
            player = video;
        } else {
            var webview = new WebKit.WebView();
            webview.set_hexpand(true);
            webview.set_vexpand(true);

            ensure_embed_server();
            if (embed_server != null) {
                string wrapper_uri = "http://127.0.0.1:%u/embed-wrapper?v=%s".printf(embed_server_port, GLib.Uri.escape_string(video_url, null, false));
                webview.load_uri(wrapper_uri);
            } else {
                // Local server failed to start - fall back to a direct
                // load rather than showing nothing at all.
                webview.load_uri(video_url);
            }
            player = webview;
        }

        overlay.set_child(player);
        player_widget = player;
    }

    public void stop_playback() {
        if (!playing || player_widget == null) return;
        if (player_widget is Gtk.Video) {
            ((Gtk.Video) player_widget).set_file(null);
        } else if (player_widget is WebKit.WebView) {
            var wv = (WebKit.WebView) player_widget;
            wv.stop_loading();
            wv.load_uri("about:blank");
        }
        playing = false;
        player_widget = null;
    }
}
