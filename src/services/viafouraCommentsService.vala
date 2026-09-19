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

// Fetches comments from a Viafoura-powered comments widget. Unlike Coral,
// Viafoura has no single uniform way publishers embed the article's
// container id - Future plc sites (space.com, techradar.com, ...) bake an
// opaque id straight into a ViafouraArticleCommentCount(...) call, while
// WordPress-based installs (dailykos.com) only expose a numeric
// data-post-id, from which Viafoura's own "post_<id>" convention has to be
// built. Both are handled here; an install using neither is treated as
// not-Viafoura. The site's tenant uuid, by contrast, is uniform: it's
// resolved from the bare domain via Viafoura's own public lookup, no HTML
// scraping needed. Every endpoint used here is unauthenticated.
namespace Paperboy {
    private delegate void ViafouraSiteUuidCallback(string? site_uuid);
    private delegate void ViafouraAuthorNamesCallback(Gee.HashMap<string, string> names);

    public class ViafouraCommentsService {
        private const int LIMIT = 20;
        private const int REPLY_LIMIT = 3;

        public static void fetch_for_url(string article_url, owned CommentsFetchedCallback callback) {
            var options = new HttpClientUtils.RequestOptions().with_browser_headers();
            HttpClientUtils.get_default().fetch_string(article_url, options, (response) => {
                var comments = new Gee.ArrayList<FeedComment>();
                if (!response.is_success()) {
                    callback(comments, false);
                    return;
                }

                string? html = response.get_body_string();
                if (html == null || !html.down().contains("viafoura")) {
                    callback(comments, false);
                    return;
                }

                string? container_id = detect_container_id(html);
                string host = UrlUtils.extract_host_from_url(article_url);
                if (container_id == null || host.length == 0) {
                    callback(comments, false);
                    return;
                }

                fetch_site_uuid(host, (site_uuid) => {
                    if (site_uuid == null) {
                        callback(comments, false);
                        return;
                    }
                    fetch_conversation(site_uuid, container_id, (owned) callback);
                });
            });
        }

        private static string? detect_container_id(string html) {
            try {
                MatchInfo mi;
                var re = new Regex("ViafouraArticleCommentCount\\('([^']+)'");
                if (re.match(html, 0, out mi)) return mi.fetch(1);
            } catch (RegexError e) { }

            // WordPress-style installs (e.g. Daily Kos): no direct container
            // id, but Viafoura's own "post_<id>" convention can be built
            // from the numeric post id the theme already embeds.
            try {
                MatchInfo mi;
                var re = new Regex("data-post-id=[\"'](\\d+)[\"']");
                if (re.match(html, 0, out mi)) return "post_" + mi.fetch(1);
            } catch (RegexError e) { }

            return null;
        }

        private static void fetch_site_uuid(string host, owned ViafouraSiteUuidCallback callback) {
            var options = new HttpClientUtils.RequestOptions();
            options.user_agent = HttpClientUtils.USER_AGENT_BROWSER;

            HttpClientUtils.get_default().fetch_string("https://tyrion.viafoura.co/v3/sections/sites/%s".printf(host), options, (response) => {
                string? body = response.is_success() ? response.get_body_string() : null;
                if (body == null) {
                    callback(null);
                    return;
                }
                try {
                    var parser = new Json.Parser();
                    parser.load_from_data(body);
                    var root = parser.get_root();
                    if (root == null || root.get_node_type() != Json.NodeType.OBJECT) {
                        callback(null);
                        return;
                    }
                    callback(get_str(root.get_object(), "uuid"));
                } catch (Error e) {
                    callback(null);
                }
            });
        }

        private static void fetch_conversation(string site_uuid, string container_id, owned CommentsFetchedCallback callback) {
            var raw_items = new Gee.ArrayList<Json.Object>();
            var unique_actor_ids = new Gee.HashSet<string>();
            fetch_conversation_page(site_uuid, container_id, null, raw_items, unique_actor_ids, (success) => {
                var comments = new Gee.ArrayList<FeedComment>();
                if (!success || raw_items.size == 0) {
                    callback(comments, success);
                    return;
                }

                resolve_authors(site_uuid, unique_actor_ids, (names) => {
                    foreach (var obj in raw_items) {
                        string? body_html = get_str(obj, "content");
                        string plain = body_html != null ? stripHtmlUtils.strip_html(body_html).strip() : "";
                        if (plain.length == 0) continue;

                        string? actor_id = get_str(obj, "actor_uuid");
                        string author = (actor_id != null && names.has_key(actor_id)) ? names.get(actor_id) : "Anonymous";

                        string? published = null;
                        if (obj.has_member("time") && obj.get_member("time").get_node_type() == Json.NodeType.VALUE) {
                            published = (obj.get_int_member("time") / 1000).to_string();
                        }

                        comments.add(new FeedComment(author, published, plain));
                    }
                    callback(comments, true);
                });
            });
        }

        private delegate void FetchPageCallback(bool success);

        private static void fetch_conversation_page(string site_uuid, string container_id, string? starting_from,
                                                    Gee.ArrayList<Json.Object> accumulated_items, Gee.HashSet<string> unique_actor_ids,
                                                    owned FetchPageCallback callback) {
            var url_parts = "https://livecomments.viafoura.co/v4/livecomments/%s?limit=%d&container_id=%s&reply_limit=%d&sorted_by=newest"
                .printf(site_uuid, LIMIT, GLib.Uri.escape_string(container_id, null, true), REPLY_LIMIT);

            if (starting_from != null && starting_from.length > 0) {
                url_parts += "&starting_from=" + GLib.Uri.escape_string(starting_from, null, true);
            }

            var options = new HttpClientUtils.RequestOptions().without_deduplication();
            options.user_agent = HttpClientUtils.USER_AGENT_BROWSER;

            HttpClientUtils.get_default().fetch_string(url_parts, options, (response) => {
                string? body = response.is_success() ? response.get_body_string() : null;
                if (body == null) {
                    callback(false);
                    return;
                }

                try {
                    var parser = new Json.Parser();
                    parser.load_from_data(body);
                    var root = parser.get_root();
                    if (root == null || root.get_node_type() != Json.NodeType.OBJECT) {
                        callback(false);
                        return;
                    }
                    var top = root.get_object();
                    if (!top.has_member("contents") || top.get_member("contents").get_node_type() != Json.NodeType.ARRAY) {
                        callback(true);
                        return;
                    }

                    var contents = top.get_array_member("contents");
                    bool more_available = top.has_member("more_available") && top.get_boolean_member("more_available");
                    string? next_cursor = null;

                    // Accumulate all items from this page, track unique authors,
                    // and extract the UUID of the last comment for pagination.
                    foreach (var node in contents.get_elements()) {
                        if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                        var obj = node.get_object();
                        string? state = get_str(obj, "simplified_state");
                        if (state != null && state != "visible") continue;
                        accumulated_items.add(obj);
                        string? actor_id = get_str(obj, "actor_uuid");
                        if (actor_id != null) unique_actor_ids.add(actor_id);
                        next_cursor = get_str(obj, "content_uuid");
                    }

                    // If there are more pages, fetch the next one recursively.
                    if (more_available && next_cursor != null && next_cursor.length > 0) {
                        fetch_conversation_page(site_uuid, container_id, next_cursor, accumulated_items, unique_actor_ids, (owned) callback);
                    } else {
                        callback(true);
                    }
                } catch (Error e) {
                    callback(false);
                }
            });
        }

        // Comment bodies only carry an actor_uuid, not a display name - one
        // lookup per unique commenter is the same cost the real widget
        // pays. Every lookup runs on the HttpClientUtils thread pool but
        // completes back on the main loop (see HttpClientUtils.
        // process_http_task's Idle.add), so this counter is never touched
        // from two threads at once.
        private static void resolve_authors(string site_uuid, Gee.HashSet<string> actor_ids, owned ViafouraAuthorNamesCallback callback) {
            var names = new Gee.HashMap<string, string>();
            int remaining = actor_ids.size;
            if (remaining == 0) {
                callback(names);
                return;
            }

            var options = new HttpClientUtils.RequestOptions();
            options.user_agent = HttpClientUtils.USER_AGENT_BROWSER;

            foreach (var actor_id in actor_ids) {
                string url = "https://iam.viafoura.co/v3/sections/%s/users/%s".printf(site_uuid, actor_id);
                HttpClientUtils.get_default().fetch_string(url, options, (response) => {
                    string? body = response.is_success() ? response.get_body_string() : null;
                    if (body != null) {
                        try {
                            var parser = new Json.Parser();
                            parser.load_from_data(body);
                            var root = parser.get_root();
                            if (root != null && root.get_node_type() == Json.NodeType.OBJECT) {
                                string? username = get_str(root.get_object(), "preferred_username");
                                if (username != null && username.strip().length > 0) {
                                    names.set(actor_id, username);
                                }
                            }
                        } catch (Error e) { }
                    }
                    remaining--;
                    if (remaining <= 0) callback(names);
                });
            }
        }

        private static string? get_str(Json.Object obj, string key) {
            if (!obj.has_member(key)) return null;
            var node = obj.get_member(key);
            if (node == null || node.get_node_type() != Json.NodeType.VALUE) return null;
            if (node.get_value_type() != typeof(string)) return null;
            return node.get_string();
        }
    }
}
