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

// Fetches comments from an OpenWeb (Spot.im)-powered comments widget.
// Scrapes the spot_id/post_id OpenWeb's own launcher script embeds in an
// article's HTML, then replicates the widget's anonymous-guest API calls:
// a guest token from /v1.0.0/guests/token, then the thread itself from
// /v1.0.0/conversation/read. Both are undocumented but were reverse
// engineered against a live OpenWeb install and confirmed working with
// nothing more than a browser-like User-Agent - no session cookies,
// Origin/Referer, or JS execution required.
namespace Paperboy {
    private delegate void OpenWebTokenCallback(string? access_token);

    public class OpenWebCommentsService {
        private const string API_BASE = "https://api-2-0.spot.im/v1.0.0";
        private const int TOP_LEVEL_COUNT = 50;
        private const int MAX_DEPTH = 10;

        public static void fetch_for_url(string article_url, owned CommentsFetchedCallback callback) {
            var options = new HttpClientUtils.RequestOptions().with_browser_headers();
            HttpClientUtils.get_default().fetch_string(article_url, options, (response) => {
                var comments = new Gee.ArrayList<FeedComment>();
                if (!response.is_success()) {
                    callback(comments, false);
                    return;
                }

                string? spot_id, post_id;
                if (!detect(response.get_body_string(), out spot_id, out post_id)) {
                    callback(comments, false);
                    return;
                }

                fetch_guest_token(spot_id, (token) => {
                    if (token == null) {
                        callback(comments, false);
                        return;
                    }
                    fetch_conversation(spot_id, post_id, token, (owned) callback);
                });
            });
        }

        // spot_id lives in the launcher script URL, post_id on the
        // conversation div's data-post-id attribute.
        private static bool detect(string? html, out string? spot_id, out string? post_id) {
            spot_id = null;
            post_id = null;
            if (html == null) return false;

            try {
                MatchInfo mi;
                var spot_re = new Regex("launcher\\.spot\\.im/spot/(sp_[A-Za-z0-9]+)");
                if (spot_re.match(html, 0, out mi)) spot_id = mi.fetch(1);
            } catch (RegexError e) { }
            if (spot_id == null) return false;

            try {
                MatchInfo mi;
                var post_re = new Regex("data-post-id=[\"']([0-9]+)[\"']");
                if (post_re.match(html, 0, out mi)) post_id = mi.fetch(1);
            } catch (RegexError e) { }

            return post_id != null;
        }

        private static void fetch_guest_token(string spot_id, owned OpenWebTokenCallback callback) {
            var options = new HttpClientUtils.RequestOptions().with_body("{}").without_deduplication();
            options.user_agent = HttpClientUtils.USER_AGENT_BROWSER;
            options.headers = new Gee.HashMap<string, string>();
            options.headers["x-spot-id"] = spot_id;

            HttpClientUtils.get_default().fetch_string(API_BASE + "/guests/token", options, (response) => {
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
                    callback(get_str(root.get_object(), "accessToken"));
                } catch (Error e) {
                    callback(null);
                }
            });
        }

        private static void fetch_conversation(string spot_id, string post_id, string access_token, owned CommentsFetchedCallback callback) {
            string body = "{\"sort_by\":\"best\",\"offset\":0,\"count\":%d,\"depth\":%d}".printf(TOP_LEVEL_COUNT, MAX_DEPTH);
            var options = new HttpClientUtils.RequestOptions().with_body(body).without_deduplication();
            options.user_agent = HttpClientUtils.USER_AGENT_BROWSER;
            options.headers = new Gee.HashMap<string, string>();
            options.headers["x-spot-id"] = spot_id;
            options.headers["x-post-id"] = post_id;
            options.headers["x-access-token"] = access_token;

            HttpClientUtils.get_default().fetch_string(API_BASE + "/conversation/read", options, (response) => {
                var comments = new Gee.ArrayList<FeedComment>();
                string? body_str = response.is_success() ? response.get_body_string() : null;
                if (body_str == null) {
                    callback(comments, false);
                    return;
                }

                try {
                    var parser = new Json.Parser();
                    parser.load_from_data(body_str);
                    var root = parser.get_root();
                    if (root == null || root.get_node_type() != Json.NodeType.OBJECT) {
                        callback(comments, false);
                        return;
                    }
                    var top = root.get_object();
                    if (!top.has_member("conversation") || top.get_member("conversation").get_node_type() != Json.NodeType.OBJECT) {
                        callback(comments, false);
                        return;
                    }
                    var conversation = top.get_object_member("conversation");

                    Json.Object? users = null;
                    if (conversation.has_member("users") && conversation.get_member("users").get_node_type() == Json.NodeType.OBJECT) {
                        users = conversation.get_object_member("users");
                    }

                    if (conversation.has_member("comments") && conversation.get_member("comments").get_node_type() == Json.NodeType.ARRAY) {
                        foreach (var node in conversation.get_array_member("comments").get_elements()) {
                            collect(node, users, comments);
                        }
                    }

                    callback(comments, true);
                } catch (Error e) {
                    callback(comments, false);
                }
            });
        }

        // Flattens a comment and its nested replies into out_list - the
        // existing FeedComment model has no threading, matching how the
        // other providers (Disqus, native RSS) already render comments.
        private static void collect(Json.Node node, Json.Object? users, Gee.ArrayList<FeedComment> out_list) {
            if (node.get_node_type() != Json.NodeType.OBJECT) return;
            var obj = node.get_object();

            string author = "Anonymous";
            string? user_id = get_str(obj, "user_id");
            if (user_id != null && users != null && users.has_member(user_id)) {
                var user_node = users.get_member(user_id);
                if (user_node.get_node_type() == Json.NodeType.OBJECT) {
                    string? display_name = get_str(user_node.get_object(), "display_name");
                    if (display_name != null && display_name.strip().length > 0) author = display_name;
                }
            }

            string plain = "";
            if (obj.has_member("content") && obj.get_member("content").get_node_type() == Json.NodeType.ARRAY) {
                var builder = new StringBuilder();
                foreach (var item_node in obj.get_array_member("content").get_elements()) {
                    if (item_node.get_node_type() != Json.NodeType.OBJECT) continue;
                    var item = item_node.get_object();
                    if (get_str(item, "type") != "text") continue;
                    string? text = get_str(item, "text");
                    if (text != null) builder.append(text);
                }
                plain = stripHtmlUtils.strip_html(builder.str).strip();
            }

            if (plain.length > 0) {
                string? published = null;
                if (obj.has_member("written_at") && obj.get_member("written_at").get_node_type() == Json.NodeType.VALUE) {
                    published = obj.get_int_member("written_at").to_string();
                }
                out_list.add(new FeedComment(author, published, plain));
            }

            if (obj.has_member("replies") && obj.get_member("replies").get_node_type() == Json.NodeType.ARRAY) {
                foreach (var reply_node in obj.get_array_member("replies").get_elements()) {
                    collect(reply_node, users, out_list);
                }
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
