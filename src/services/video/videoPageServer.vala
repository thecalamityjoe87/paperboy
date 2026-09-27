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

using GLib;

// Local pages VideoPlayerDialog loads for videos that aren't a standalone player page.
// Served from 127.0.0.1 so they count as a secure context, which Media Source Extensions (hls.js) require.
public class VideoPageServer : GLib.Object {
    private static Soup.Server? server = null;
    private static uint16 port = 0;
    private static string? hls_js = null;

    // A page embedding `embed_url` in an iframe. YouTube's player refuses to load as a top-level page
    // ("Error 153") and checks it's embedded in a real origin, passed as origin=.
    public static string? iframe_page_url(string embed_url) {
        if (!ensure_server()) return null;
        return "http://127.0.0.1:%u/embed-wrapper?v=%s".printf(port, GLib.Uri.escape_string(embed_url, null, false));
    }

    // A page playing a media file (MP4/WebM, or HLS via hls.js) in a plain <video>.
    public static string? media_page_url(string media_url) {
        if (!ensure_server()) return null;
        return "http://127.0.0.1:%u/media?src=%s".printf(port, GLib.Uri.escape_string(media_url, null, false));
    }

    private static bool ensure_server() {
        if (server != null) return true;

        var s = new Soup.Server(null);
        s.add_handler("/embed-wrapper", (srv, msg, path, query) => {
            string? target = query != null ? query.lookup("v") : null;
            if (target == null || target.length == 0) { msg.set_status(404, null); return; }
            string origin = "http://127.0.0.1:%u".printf(port);
            string sep = target.contains("?") ? "&" : "?";
            respond(msg, "text/html",
                "<!DOCTYPE html><html><head><style>*{margin:0;padding:0}html,body{width:100%;height:100%;background:#000;overflow:hidden}iframe{display:block;width:100%;height:100%;border:0}</style></head><body><iframe src=\"%s%sorigin=%s\" allow=\"autoplay; encrypted-media; fullscreen\" allowfullscreen></iframe></body></html>"
                    .printf(GLib.Markup.escape_text(target), sep, GLib.Uri.escape_string(origin, null, false)));
        });
        s.add_handler("/media", (srv, msg, path, query) => {
            string? src = query != null ? query.lookup("src") : null;
            if (src == null || !(src.has_prefix("https://") || src.has_prefix("http://"))) { msg.set_status(404, null); return; }
            respond(msg, "text/html",
                "<!DOCTYPE html><html><head><style>*{margin:0;padding:0}html,body{width:100%;height:100%;background:#000;overflow:hidden}video{width:100%;height:100%;object-fit:contain}</style></head><body><video id=\"v\" controls autoplay playsinline></video><script src=\"/hls.min.js\"></script><script>var v=document.getElementById('v');var src=%s;if(/\\.m3u8(\\?|$)/i.test(src)&&window.Hls&&Hls.isSupported()){var h=new Hls();h.loadSource(src);h.attachMedia(v);h.on(Hls.Events.MANIFEST_PARSED,function(){v.play().catch(function(){});});}else{v.src=src;}</script></body></html>"
                    .printf(js_string(src)));
        });
        s.add_handler("/hls.min.js", (srv, msg, path, query) => {
            if (hls_js == null) {
                string? file = DataPathsUtils.find_data_file("resources/hls.min.js");
                try { if (file != null) FileUtils.get_contents(file, out hls_js); } catch (GLib.FileError e) { }
            }
            if (hls_js == null) { msg.set_status(404, null); return; }
            respond(msg, "application/javascript", hls_js);
        });

        try {
            s.listen_local(0, 0);
        } catch (GLib.Error e) {
            return false;
        }
        foreach (var uri in s.get_uris()) {
            port = (uint16) uri.get_port();
            break;
        }
        server = s;
        return true;
    }

    private static void respond(Soup.ServerMessage msg, string content_type, string body) {
        msg.get_response_headers().set_content_type(content_type, null);
        msg.get_response_body().append_take(body.data);
        msg.set_status(200, null);
    }

    // A JSON-escaped string literal, safe to drop into a <script>.
    private static string js_string(string s) {
        var node = new Json.Node(Json.NodeType.VALUE);
        node.set_string(s);
        return Json.to_string(node, false).replace("</", "<\\/");
    }
}
