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
        // Some sites (e.g. The Verge) load this dynamically, so the tag
        // won't be in the static HTML. Fallback: check if the page mentions
        // "coral" anywhere, then try to guess the tenant from the domain.
        private static string? detect(string? html) {
            if (html == null) return null;
            try {
                MatchInfo mi;
                var re = new Regex("https?://([a-zA-Z0-9.-]+\\.coralproject\\.net)/assets/js/");
                if (re.match(html, 0, out mi)) return mi.fetch(1);
            } catch (RegexError e) { }

            // Fallback: if the page mentions "coral", try guessing the tenant
            // from the domain (e.g. theverge.com -> theverge.coral.coralproject.net,
            // www.theverge.com -> theverge.coral.coralproject.net)
            if (html.down().contains("coral")) {
                try {
                    var re = new Regex("https?://(?:www\\.)?([a-zA-Z0-9-]+)\\.([a-zA-Z0-9.-]+)");
                    MatchInfo mi;
                    if (re.match(html, 0, out mi)) {
                        string domain = mi.fetch(1);
                        if (domain != null && domain.length > 0 && domain != "www") {
                            return "%s.coral.coralproject.net".printf(domain);
                        }
                    }
                } catch (RegexError e) { }
            }
            return null;
        }

        private static void fetch_conversation(string tenant_host, string article_url, owned CommentsFetchedCallback callback) {
            var comments = new Gee.ArrayList<FeedComment>();
            fetch_conversation_page(tenant_host, article_url, null, comments, (success) => {
                callback(comments, success);
            });
        }

        private delegate void FetchPageCallback(bool success);

        private static void fetch_conversation_page(string tenant_host, string article_url, string? after_cursor,
                                                    Gee.ArrayList<FeedComment> accumulated_comments, owned FetchPageCallback callback) {
            var variables_parts = new Gee.ArrayList<string>();
            variables_parts.add("\"storyID\":null");
            variables_parts.add("\"storyURL\":\"%s\"".printf(article_url.replace("\\", "\\\\").replace("\"", "\\\"")));
            variables_parts.add("\"commentsOrderBy\":\"CREATED_AT_DESC\"");
            variables_parts.add("\"tag\":null");
            variables_parts.add("\"storyMode\":null");
            variables_parts.add("\"flattenReplies\":false");
            variables_parts.add("\"ratingFilter\":null");
            variables_parts.add("\"refreshStream\":false");
            variables_parts.add("\"first\":20");
            if (after_cursor != null && after_cursor.length > 0) {
                variables_parts.add("\"after\":\"%s\"".printf(after_cursor.replace("\\", "\\\\").replace("\"", "\\\"")));
            }

            string variables_json = "{%s}".printf(string.joinv(",", (string[])variables_parts.to_array()));
            string url = "https://%s/api/graphql?query=&id=%s&variables=%s"
                .printf(tenant_host, QUERY_ID, GLib.Uri.escape_string(variables_json, null, true));

            var options = new HttpClientUtils.RequestOptions().without_deduplication();
            options.user_agent = HttpClientUtils.USER_AGENT_BROWSER;

            HttpClientUtils.get_default().fetch_string(url, options, (response) => {
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
                        GLib.debug("Coral: root is null or not an object");
                        callback(false);
                        return;
                    }

                    var top = root.get_object();
                    if (!top.has_member("data") || top.get_member("data").get_node_type() != Json.NodeType.OBJECT) {
                        GLib.debug("Coral: no data object in response");
                        if (top.has_member("errors")) {
                            GLib.debug("Coral: response has errors: %s", Json.to_string(root, false));
                        }
                        GLib.debug("Coral: full response (first 1000 chars): %s", body.substring(0, body.length > 1000 ? 1000 : body.length));
                        callback(false);
                        return;
                    }
                    var data = top.get_object_member("data");
                    if (!data.has_member("story") || data.get_member("story").get_node_type() != Json.NodeType.OBJECT) {
                        GLib.debug("Coral: no story object in response");
                        callback(false);
                        return;
                    }
                    var story = data.get_object_member("story");
                    GLib.debug("Coral: full response: %s", Json.to_string(root, false));
                    if (story.has_member("comments") && story.get_member("comments").get_node_type() == Json.NodeType.OBJECT) {
                        var story_comments = story.get_object_member("comments");
                        int edge_count = 0;
                        if (story_comments.has_member("edges") && story_comments.get_member("edges").get_node_type() == Json.NodeType.ARRAY) {
                            foreach (var edge in story_comments.get_array_member("edges").get_elements()) {
                                collect(edge, accumulated_comments);
                                edge_count++;
                            }
                        } else {
                            GLib.debug("Coral: story_comments has no edges array, edges type=%d",
                                story_comments.has_member("edges") ? story_comments.get_member("edges").get_node_type() : -1);
                            var members = story_comments.get_members();
                            foreach (var key in members) {
                                GLib.debug("Coral: story_comments key: %s", key);
                            }
                        }
                        GLib.debug("Coral: fetched %d edges, total accumulated=%d", edge_count, accumulated_comments.size);

                        bool has_next_page = false;
                        string? next_cursor = null;
                        if (story_comments.has_member("pageInfo") && story_comments.get_member("pageInfo").get_node_type() == Json.NodeType.OBJECT) {
                            var page_info = story_comments.get_object_member("pageInfo");
                            has_next_page = page_info.has_member("hasNextPage") && page_info.get_boolean_member("hasNextPage");
                            if (has_next_page) {
                                next_cursor = get_str(page_info, "endCursor");
                                GLib.debug("Coral: hasNextPage=true, endCursor=%s", next_cursor);
                            } else {
                                GLib.debug("Coral: hasNextPage=false, done paginating");
                            }
                        } else {
                            GLib.debug("Coral: no pageInfo in response");
                        }

                        // If there are more pages, fetch the next one recursively.
                        if (has_next_page && next_cursor != null && next_cursor.length > 0) {
                            fetch_conversation_page(tenant_host, article_url, next_cursor, accumulated_comments, (owned) callback);
                        } else {
                            callback(true);
                        }
                    } else {
                        GLib.debug("Coral: no comments object in story");
                        callback(true);
                    }
                } catch (Error e) {
                    GLib.debug("Coral: error parsing response: %s", e.message);
                    callback(false);
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
