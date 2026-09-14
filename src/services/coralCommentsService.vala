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

// Fetches comments from a Coral (coralproject.net)-powered comments widget.
// Detects the publisher's Coral tenant host from the <script class="coral-
// script"> tag every install embeds, then calls Coral's own public GraphQL
// endpoint with a persisted query (a hash id in place of query text, which
// is how the stream widget itself calls it - no admin access token needed,
// unlike Coral's documented GraphQL API). Coral resolves the story purely
// from its URL, so no separate story-id lookup is required either.
//
// QUERY_ID is a hash of the exact query text baked into Coral's stream.js
// bundle for the version this was reverse engineered against (9.9.7,
// confirmed identical across two independent installs). A publisher on a
// different Coral version could have a different hash, which would break
// this silently - same caveat as the OpenWeb integration.
namespace Paperboy {
    public class CoralCommentsService {
        private const string QUERY_ID = "72fb962160f4024e41596efd0aa7a172";

        public static void fetch_for_url(string article_url, owned CommentsFetchedCallback callback) {
            var options = new HttpClientUtils.RequestOptions().with_browser_headers();
            HttpClientUtils.get_default().fetch_string(article_url, options, (response) => {
                var comments = new Gee.ArrayList<FeedComment>();
                if (!response.is_success()) {
                    callback(comments, false);
                    return;
                }

                string? tenant_host = detect(response.get_body_string());
                if (tenant_host == null) {
                    callback(comments, false);
                    return;
                }

                fetch_conversation(tenant_host, article_url, (owned) callback);
            });
        }

        // Every Coral install embeds a <script class="coral-script"
        // src="https://<tenant>.coralproject.net/assets/js/count.js"> tag.
        private static string? detect(string? html) {
            if (html == null) return null;
            try {
                MatchInfo mi;
                var re = new Regex("https?://([a-zA-Z0-9.-]+\\.coralproject\\.net)/assets/js/");
                if (re.match(html, 0, out mi)) return mi.fetch(1);
            } catch (RegexError e) { }
            return null;
        }

        private static void fetch_conversation(string tenant_host, string article_url, owned CommentsFetchedCallback callback) {
            string variables_json = "{\"storyID\":null,\"storyURL\":\"%s\",\"commentsOrderBy\":\"CREATED_AT_DESC\",\"tag\":null,\"storyMode\":null,\"flattenReplies\":false,\"ratingFilter\":null,\"refreshStream\":false}"
                .printf(article_url.replace("\\", "\\\\").replace("\"", "\\\""));
            string url = "https://%s/api/graphql?query=&id=%s&variables=%s"
                .printf(tenant_host, QUERY_ID, GLib.Uri.escape_string(variables_json, null, true));

            var options = new HttpClientUtils.RequestOptions().without_deduplication();
            options.user_agent = HttpClientUtils.USER_AGENT_BROWSER;

            HttpClientUtils.get_default().fetch_string(url, options, (response) => {
                var comments = new Gee.ArrayList<FeedComment>();
                string? body = response.is_success() ? response.get_body_string() : null;
                if (body == null) {
                    callback(comments, false);
                    return;
                }

                try {
                    var parser = new Json.Parser();
                    parser.load_from_data(body);
                    var root = parser.get_root();
                    if (root == null || root.get_node_type() != Json.NodeType.OBJECT) {
                        callback(comments, false);
                        return;
                    }

                    var top = root.get_object();
                    if (!top.has_member("data") || top.get_member("data").get_node_type() != Json.NodeType.OBJECT) {
                        callback(comments, false);
                        return;
                    }
                    var data = top.get_object_member("data");
                    if (!data.has_member("story") || data.get_member("story").get_node_type() != Json.NodeType.OBJECT) {
                        callback(comments, false);
                        return;
                    }
                    var story = data.get_object_member("story");
                    if (story.has_member("comments") && story.get_member("comments").get_node_type() == Json.NodeType.OBJECT) {
                        var story_comments = story.get_object_member("comments");
                        if (story_comments.has_member("edges") && story_comments.get_member("edges").get_node_type() == Json.NodeType.ARRAY) {
                            foreach (var edge in story_comments.get_array_member("edges").get_elements()) {
                                collect(edge, comments);
                            }
                        }
                    }

                    callback(comments, true);
                } catch (Error e) {
                    callback(comments, false);
                }
            });
        }

        // Flattens a comment edge and its nested replies into out_list -
        // the existing FeedComment model has no threading, matching how
        // the other providers already render comments.
        private static void collect(Json.Node edge_node, Gee.ArrayList<FeedComment> out_list) {
            if (edge_node.get_node_type() != Json.NodeType.OBJECT) return;
            var edge = edge_node.get_object();
            if (!edge.has_member("node") || edge.get_member("node").get_node_type() != Json.NodeType.OBJECT) return;
            var node = edge.get_object_member("node");

            bool deleted = node.has_member("deleted") && node.get_member("deleted").get_node_type() == Json.NodeType.VALUE && node.get_boolean_member("deleted");
            if (!deleted) {
                string? body_html = get_str(node, "body");
                string plain = body_html != null ? stripHtmlUtils.strip_html(body_html).strip() : "";
                if (plain.length > 0) {
                    string author = "Anonymous";
                    if (node.has_member("author") && node.get_member("author").get_node_type() == Json.NodeType.OBJECT) {
                        string? username = get_str(node.get_object_member("author"), "username");
                        if (username != null && username.strip().length > 0) author = username;
                    }
                    string? published = get_str(node, "createdAt");
                    out_list.add(new FeedComment(author, published, plain));
                }
            }

            if (node.has_member("replies") && node.get_member("replies").get_node_type() == Json.NodeType.OBJECT) {
                var replies = node.get_object_member("replies");
                if (replies.has_member("edges") && replies.get_member("edges").get_node_type() == Json.NodeType.ARRAY) {
                    foreach (var reply_edge in replies.get_array_member("edges").get_elements()) {
                        collect(reply_edge, out_list);
                    }
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
