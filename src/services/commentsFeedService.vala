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

using Xml;

[CCode (cname = "xmlFreeDoc")]
private static extern void comments_xml_free_doc (Xml.Doc* doc);

// Fetches a feed-provided comments RSS (wfw:commentRss) and parses it into
// FeedComment rows using the same libxml2 plumbing RssFeedProcessor uses for
// the main article feed, so comments render as native widgets instead of an
// embedded webpage.
namespace Paperboy {
    public delegate void CommentsFetchedCallback(Gee.ArrayList<FeedComment> comments, bool success);

    public class CommentsFeedService {
        public static void fetch(string feed_url, owned CommentsFetchedCallback callback) {
            var options = new HttpClientUtils.RequestOptions().with_browser_headers();
            HttpClientUtils.get_default().fetch_string(feed_url, options, (response) => {
                var comments = new Gee.ArrayList<FeedComment>();
                if (!response.is_success()) {
                    callback(comments, false);
                    return;
                }
                string? body = response.get_body_string();
                if (body == null || body.strip().length == 0) {
                    callback(comments, false);
                    return;
                }
                // Guard against a wfw:commentRss URL that (e.g. via a
                // redirect) resolves to an HTML error page rather than a
                // feed - feeding that to the XML parser just produces a
                // wall of libxml2 stderr noise for a result we can't use.
                string sniff = body.strip();
                if (!sniff.has_prefix("<?xml") && !sniff.has_prefix("<rss") && !sniff.has_prefix("<feed")) {
                    callback(comments, false);
                    return;
                }
                bool ok = parse(body, comments);
                callback(comments, ok);
            });
        }

        private static bool parse(string xml_body, Gee.ArrayList<FeedComment> out_list) {
            var parser_options = Xml.ParserOption.NONET | Xml.ParserOption.NOCDATA | Xml.ParserOption.NOBLANKS | Xml.ParserOption.RECOVER;
            Xml.Doc* doc = Xml.Parser.read_memory(xml_body, (int) xml_body.length, null, "UTF-8", (int) parser_options);
            if (doc == null) return false;

            Xml.Node* root = doc->get_root_element();
            if (root == null) {
                comments_xml_free_doc(doc);
                return false;
            }

            for (Xml.Node* ch = root->children; ch != null; ch = ch->next) {
                if (ch->type != Xml.ElementType.ELEMENT_NODE) continue;
                if (ch->name != "channel" && ch->name != "feed") continue;

                for (Xml.Node* it = ch->children; it != null; it = it->next) {
                    if (it->type != Xml.ElementType.ELEMENT_NODE) continue;
                    if (it->name != "item" && it->name != "entry") continue;

                    string? title = null;
                    string? creator = null;
                    string? pub_date = null;
                    string? body_html = null;

                    for (Xml.Node* c = it->children; c != null; c = c->next) {
                        if (c->type != Xml.ElementType.ELEMENT_NODE) continue;
                        if (c->name == "title") {
                            title = c->get_content();
                        } else if (c->name == "creator" && c->ns != null && c->ns->prefix == "dc") {
                            creator = c->get_content();
                        } else if ((c->name == "pubDate" || c->name == "published") && pub_date == null) {
                            pub_date = c->get_content();
                        } else if (c->name == "encoded" && c->ns != null && c->ns->prefix == "content") {
                            body_html = c->get_content();
                        } else if ((c->name == "description" || c->name == "summary") && body_html == null) {
                            body_html = c->get_content();
                        }
                    }

                    string author = (creator != null && creator.strip().length > 0)
                        ? creator.strip()
                        : (extract_author_from_title(title) ?? "Anonymous");
                    string plain = body_html != null ? stripHtmlUtils.strip_html(body_html).strip() : "";
                    if (plain.length == 0) continue;

                    out_list.add(new FeedComment(author, pub_date, plain));
                }
            }

            comments_xml_free_doc(doc);
            // A well-formed feed with zero items is a legitimate "no
            // comments yet" result, not a parse failure.
            return true;
        }

        // WordPress comment-feed items are typically titled "Comment on
        // POST TITLE by AUTHOR" when there's no dc:creator element.
        private static string? extract_author_from_title(string? title) {
            if (title == null) return null;
            int idx = title.last_index_of(" by ");
            if (idx < 0) return null;
            string author = title.substring(idx + 4).strip();
            return author.length > 0 ? author : null;
        }
    }
}
