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

// Fetches Disqus comments for an article via paperboyBackend's
// /comments/disqus endpoint (same BASE_URL PaperboyFetcher already calls -
// see src/services/fetchers/paperboyFetcher.vala), never disqus.com
// directly: the backend resolves the site's Disqus forum shortname, looks
// up the thread for this URL, and fetches its posts, so the Disqus public
// key lives entirely server-side.
namespace Paperboy {
    public class DisqusCommentsService {
        private const string BASE_URL = "https://paperboybackend.onrender.com";
        private const string PATH_COMMENTS = "/comments/disqus";

        public static void fetch_for_url(string article_url, owned CommentsFetchedCallback callback) {
            string url = "%s%s?url=%s".printf(BASE_URL, PATH_COMMENTS, GLib.Uri.escape_string(article_url, null, true));

            HttpClientUtils.get_default().fetch_json(url, (response, parser, root) => {
                var comments = new Gee.ArrayList<FeedComment>();
                var posts = get_response_array(root);
                if (posts == null) {
                    callback(comments, response.is_success());
                    return;
                }

                foreach (var post_node in posts.get_elements()) {
                    if (post_node.get_node_type() != Json.NodeType.OBJECT) continue;
                    var post = post_node.get_object();

                    string? message = get_str(post, "message");
                    if (message == null) continue;
                    string plain = stripHtmlUtils.strip_html(message).strip();
                    if (plain.length == 0) continue;

                    string author = "Anonymous";
                    var author_node = post.get_member("author");
                    if (author_node != null && author_node.get_node_type() == Json.NodeType.OBJECT) {
                        author = get_str(author_node.get_object(), "name") ?? author;
                    }

                    comments.add(new FeedComment(author, get_str(post, "createdAt"), plain));
                }

                callback(comments, true);
            });
        }

        private static Json.Array? get_response_array(Json.Node? root) {
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return null;
            var node = root.get_object().get_member("response");
            if (node == null || node.get_node_type() != Json.NodeType.ARRAY) return null;
            return node.get_array();
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
