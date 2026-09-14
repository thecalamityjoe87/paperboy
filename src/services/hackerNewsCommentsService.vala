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

// Falls back to Hacker News discussion of an article's URL when the site
// itself doesn't expose a native comment feed (wfw:commentRss) - most
// commercial news sites use a closed platform (Disqus, Coral, OpenWeb, etc.)
// with no public, key-free API, but HN's own Algolia-backed search API is
// public and unauthenticated, and works for any URL regardless of what
// commenting system the publisher uses.
namespace Paperboy {
    public class HackerNewsCommentsService {
        private const int MAX_COMMENTS = 60;

        public static void fetch_for_url(string article_url, owned CommentsFetchedCallback callback) {
            string encoded = GLib.Uri.escape_string(article_url, null, true);
            string search_url = "https://hn.algolia.com/api/v1/search?query=%s&restrictSearchableAttributes=url&tags=story&hitsPerPage=1".printf(encoded);

            HttpClientUtils.get_default().fetch_json(search_url, (response, parser, root) => {
                var empty = new Gee.ArrayList<FeedComment>();
                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) {
                    callback(empty, false);
                    return;
                }

                var hits_node = root.get_object().get_member("hits");
                if (hits_node == null || hits_node.get_node_type() != Json.NodeType.ARRAY || hits_node.get_array().get_length() == 0) {
                    // No HN discussion of this URL - a legitimate "nothing found", not a fetch error.
                    callback(empty, true);
                    return;
                }

                var hit_node = hits_node.get_array().get_element(0);
                string? story_id = (hit_node.get_node_type() == Json.NodeType.OBJECT) ? get_str(hit_node.get_object(), "objectID") : null;
                if (story_id == null) {
                    callback(empty, true);
                    return;
                }

                fetch_item(story_id, (owned) callback);
            });
        }

        private static void fetch_item(string story_id, owned CommentsFetchedCallback callback) {
            string item_url = "https://hn.algolia.com/api/v1/items/%s".printf(story_id);
            HttpClientUtils.get_default().fetch_json(item_url, (response, parser, root) => {
                var comments = new Gee.ArrayList<FeedComment>();
                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) {
                    callback(comments, false);
                    return;
                }
                collect_comments(root.get_object(), comments);
                callback(comments, true);
            });
        }

        private static void collect_comments(Json.Object node, Gee.ArrayList<FeedComment> out_list) {
            if (out_list.size >= MAX_COMMENTS) return;

            string? type = get_str(node, "type");
            string? text = get_str(node, "text");
            if (type == "comment" && text != null) {
                string plain = stripHtmlUtils.strip_html(text).strip();
                if (plain.length > 0) {
                    string author = get_str(node, "author") ?? "Anonymous";
                    out_list.add(new FeedComment(author, get_str(node, "created_at"), plain));
                }
            }

            var children_node = node.get_member("children");
            if (children_node == null || children_node.get_node_type() != Json.NodeType.ARRAY) return;
            foreach (var child in children_node.get_array().get_elements()) {
                if (out_list.size >= MAX_COMMENTS) return;
                if (child.get_node_type() != Json.NodeType.OBJECT) continue;
                collect_comments(child.get_object(), out_list);
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
