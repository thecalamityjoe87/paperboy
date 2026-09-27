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

// Plays a Sports highlight clip in a 16:9 dialog sized to fit the window.
public class HighlightPlayerDialog : GLib.Object {
    private const int MAX_VIDEO_WIDTH = 960;
    private const int WINDOW_MARGIN = 96;
    private const int BTN_MARGIN = 8;

    private class DialogHandle : GLib.Object {
        public weak Adw.Dialog? target;
    }

    // Moves the video into its own fullscreen window, so WebKit doesn't fullscreen the app.
    // Owned by the WebView (set_data) and connected via instance methods, so there's no ref cycle.
    private class FullscreenController : GLib.Object {
        private weak WebKit.WebView? view;
        private weak Gtk.Fixed? home;
        private weak Gtk.Window? parent_window;
        private Gtk.Window? fullscreen_window = null;

        public FullscreenController(WebKit.WebView view, Gtk.Fixed home, Gtk.Window parent_window) {
            this.view = view;
            this.home = home;
            this.parent_window = parent_window;
            view.enter_fullscreen.connect(on_enter_fullscreen);
            view.leave_fullscreen.connect(on_leave_fullscreen);
        }

        private bool on_enter_fullscreen(WebKit.WebView web_view) {
            var v = view;
            var h = home;
            if (fullscreen_window != null || v == null || h == null) return true;

            h.remove(v);
            fullscreen_window = new Gtk.Window();
            fullscreen_window.set_transient_for(parent_window);
            fullscreen_window.set_child(v);
            // Closing the window directly (e.g. Alt+F4) should drop back to the dialog too.
            fullscreen_window.close_request.connect(on_window_close_request);
            fullscreen_window.fullscreen();
            fullscreen_window.present();
            return true;
        }

        private bool on_leave_fullscreen(WebKit.WebView web_view) {
            restore();
            return true;
        }

        private bool on_window_close_request(Gtk.Window window) {
            var v = view;
            restore();
            if (v != null) v.evaluate_javascript.begin("document.fullscreenElement && document.exitFullscreen()", -1, null, null, null);
            return true;
        }

        // Puts the video back in the dialog, underneath the close button.
        public void restore() {
            var v = view;
            var h = home;
            if (fullscreen_window == null || v == null) return;

            fullscreen_window.set_child(null);
            fullscreen_window.destroy();
            fullscreen_window = null;
            if (h != null) {
                h.put(v, 0, 0);
                v.insert_before(h, h.get_first_child());
            }
        }
    }

    public static void show(Gtk.Window parent_window, VideoHighlight highlight) {
        if (highlight.stream_url == null) {
            if (highlight.web_url != null) BrowserUtils.open_url_in_browser(highlight.web_url);
            return;
        }

        int area_w, area_h;
        DialogUtils.available_size(parent_window, out area_w, out area_h);
        int w = int.min(MAX_VIDEO_WIDTH, area_w - WINDOW_MARGIN);
        int h = w * 9 / 16;
        int max_h = area_h - WINDOW_MARGIN;
        if (h > max_h) {
            h = max_h;
            w = h * 16 / 9;
        }
        if (w < 320 || h < 180) { w = 320; h = 180; }

        // WebKit, not Gtk.Video: GTK streams remote files through giostreamsrc, which stalls on 60fps clips.
        var video = WebViewUtils.create(true);
        var settings = video.get_settings();
        settings.set_media_playback_requires_user_gesture(false);
        video.set_size_request(w, h);
        video.load_html(
            "<!DOCTYPE html><html><head><style>*{margin:0;padding:0}html,body{width:100%%;height:100%%;background:#000;overflow:hidden}video{width:100%%;height:100%%;object-fit:contain}</style></head><body><video src=\"%s\" controls autoplay playsinline></video></body></html>"
                .printf(GLib.Markup.escape_text(highlight.stream_url)),
            "https://www.espn.com/");

        var dialog = new Adw.Dialog();
        dialog.add_css_class("highlight-player");
        dialog.set_title(highlight.headline);
        var handle = new DialogHandle();
        handle.target = dialog;

        var close_button = new Gtk.Button.from_icon_name("window-close-symbolic");
        close_button.add_css_class("osd");
        close_button.add_css_class("circular");
        close_button.set_tooltip_text("Close");
        close_button.clicked.connect(() => { handle.target?.close(); });

        int btn_w;
        close_button.measure(Gtk.Orientation.HORIZONTAL, -1, null, out btn_w, null, null);

        var content = new Gtk.Fixed();
        content.put(video, 0, 0);
        content.put(close_button, w - btn_w - BTN_MARGIN, BTN_MARGIN);
        video.set_data<FullscreenController>("fullscreen-controller", new FullscreenController(video, content, parent_window));

        // Kill the web process on close; dropping the view alone doesn't stop playback.
        unowned WebKit.WebView v = video;
        dialog.closed.connect(() => {
            var fs = v.get_data<FullscreenController>("fullscreen-controller");
            if (fs != null) fs.restore();
            WebViewUtils.terminate_process(v);
        });

        dialog.set_follows_content_size(false);
        dialog.set_content_width(w);
        dialog.set_content_height(h);
        dialog.set_child(content);
        dialog.present(DialogUtils.parent_for(parent_window));
    }
}
