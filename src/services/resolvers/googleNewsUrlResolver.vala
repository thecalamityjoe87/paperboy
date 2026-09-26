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


/*
 * Decodes news.google.com/rss/articles/... links to the publisher's real
 * URL via the same batchexecute call Google's own redirect page makes.
 */
public class GoogleNewsUrlResolver : GLib.Object {
    private const string BATCH_URL = "https://news.google.com/_/DotsSplashUi/data/batchexecute";

    private static Gee.HashMap<string, string>? _cache = null;
    private static GLib.Mutex cache_mutex;

    private static Gee.HashMap<string, string> cache {
        get {
            if (_cache == null) _cache = new Gee.HashMap<string, string>();
            return _cache;
        }
    }

    public static bool is_google_news_url(string url) {
        string? host = UrlUtils.extract_host_from_url(url);
        return host != null && host.down() == "news.google.com" && url.contains("/articles/");
    }

    // Blocking - call off the main thread. Returns null if decoding fails.
    public static string? resolve_sync(string url) {
        string? id = extract_article_id(url);
        if (id == null) return null;

        cache_mutex.lock();
        string? cached = cache.get(id);
        cache_mutex.unlock();
        if (cached != null) return cached;

        var client = Paperboy.HttpClientUtils.get_default();
        var page_opts = new Paperboy.HttpClientUtils.RequestOptions()
            .with_browser_headers()
            .with_timeout(Paperboy.HttpClientUtils.TIMEOUT_FAST);
        var page = client.fetch_sync("https://news.google.com/rss/articles/" + id, page_opts);
        if (!page.is_success()) return null;

        string html = page.get_body_string() ?? "";
        string? sig = match_attr(html, "data-n-a-sg");
        string? ts = match_attr(html, "data-n-a-ts");
        if (sig == null || ts == null) return null;

        string inner = "[\"garturlreq\",[[\"X\",\"X\",[\"X\",\"X\"],null,null,1,1,\"US:en\",null,1,null,null,null,null,null,0,1],\"X\",\"X\",1,[1,1,1],1,1,null,0,0,null,0],\"%s\",%s,\"%s\"]".printf(id, ts, sig);
        string freq = "[[[\"Fbv4je\",%s,null,\"generic\"]]]".printf(json_string(inner));
        string body = "f.req=" + GLib.Uri.escape_string(freq, null, false);

        var post_opts = new Paperboy.HttpClientUtils.RequestOptions()
            .with_body(body, "application/x-www-form-urlencoded;charset=UTF-8")
            .with_timeout(Paperboy.HttpClientUtils.TIMEOUT_FAST)
            .without_deduplication();
        post_opts.user_agent = Paperboy.HttpClientUtils.USER_AGENT_BROWSER;
        var resp = client.fetch_sync(BATCH_URL, post_opts);
        if (!resp.is_success()) return null;

        string? decoded = parse_batch_response(resp.get_body_string() ?? "");
        if (decoded == null) return null;

        cache_mutex.lock();
        cache.set(id, decoded);
        cache_mutex.unlock();
        return decoded;
    }

    private static string? extract_article_id(string url) {
        int start = url.index_of("/articles/");
        if (start < 0) return null;
        string rest = url.substring(start + "/articles/".length);
        int end = 0;
        while (end < rest.length && (rest[end].isalnum() || rest[end] == '-' || rest[end] == '_')) end++;
        return end > 0 ? rest.substring(0, end) : null;
    }

    private static string? match_attr(string html, string attr) {
        try {
            var re = new GLib.Regex(attr + "=\"([A-Za-z0-9_-]+)\"");
            GLib.MatchInfo info;
            if (re.match(html, 0, out info)) return info.fetch(1);
        } catch (GLib.RegexError e) {}
        return null;
    }

    private static string json_string(string s) {
        var node = new Json.Node(Json.NodeType.VALUE);
        node.set_string(s);
        return Json.to_string(node, false);
    }

    // Response is ")]}'" then JSON: [["wrb.fr","Fbv4je","[\"garturlres\",\"<url>\",1]",...],...]
    private static string? parse_batch_response(string text) {
        int json_start = text.index_of("[");
        if (json_start < 0) return null;
        try {
            var parser = new Json.Parser();
            parser.load_from_data(text.substring(json_start));
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.ARRAY) return null;

            foreach (var entry in root.get_array().get_elements()) {
                if (entry.get_node_type() != Json.NodeType.ARRAY) continue;
                var arr = entry.get_array();
                if (arr.get_length() < 3 || arr.get_string_element(0) != "wrb.fr") continue;
                var payload_node = arr.get_element(2);
                if (payload_node.get_node_type() != Json.NodeType.VALUE) continue;

                var inner = new Json.Parser();
                inner.load_from_data(payload_node.get_string());
                var inner_root = inner.get_root();
                if (inner_root == null || inner_root.get_node_type() != Json.NodeType.ARRAY) continue;
                var inner_arr = inner_root.get_array();
                if (inner_arr.get_length() < 2) continue;

                string? decoded = inner_arr.get_string_element(1);
                if (decoded != null && (decoded.has_prefix("https://") || decoded.has_prefix("http://"))) return decoded;
            }
        } catch (GLib.Error e) {}
        return null;
    }
}
