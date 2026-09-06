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
using Soup;

public class RedditFetcher : BaseFetcher {
    public RedditFetcher(SetLabelFunc set_label_func, ClearItemsFunc clear_items_func, AddItemFunc add_item_func) {
        base(set_label_func, clear_items_func, add_item_func);
    }

    public override void fetch(string category, string search_query, Soup.Session session) {
        var client = Paperboy.HttpClientUtils.get_default();
        string subreddit = "";
        string category_name = "";
        switch (category) {
            case "general":
                subreddit = "worldnews";
                category_name = "World News";
                break;
            case "us":
                subreddit = "news";
                category_name = "US News";
                break;
            case "technology":
                subreddit = "technology";
                category_name = "Technology";
                break;
            case "business":
                subreddit = "business";
                category_name = "Business";
                break;
            case "science":
                subreddit = "science";
                category_name = "Science";
                break;
            case "sports":
                subreddit = "sports";
                category_name = "Sports";
                break;
            case "health":
                subreddit = "health";
                category_name = "Health";
                break;
            case "entertainment":
                subreddit = "entertainment";
                category_name = "Entertainment";
                break;
            case "politics":
                subreddit = "politics";
                category_name = "Politics";
                break;
            default:
                subreddit = "worldnews";
                category_name = "World News";
                break;
        }
        // Reddit closed off unauthenticated access to the old .json
        // endpoints (they now return 403 regardless of User-Agent, even a
        // real browser one - confirmed by hand). Their per-subreddit Atom
        // feed (.rss) is still open with no auth required, so that's what
        // we fetch and parse here instead. Needs a real browser-looking
        // User-Agent - Reddit blocks the generic default one on this
        // endpoint too.
        string url = @"https://www.reddit.com/r/$(subreddit)/.rss";
        if (search_query.length > 0) {
            url = @"https://www.reddit.com/r/$(subreddit)/search.rss?q=$(Uri.escape_string(search_query))&restrict_sr=1&limit=30";
        }

        var options = new Paperboy.HttpClientUtils.RequestOptions().with_browser_headers();
        client.fetch_async(url, options, (response) => {
            if (!response.is_success() || response.body == null) {
                warning("Reddit RSS HTTP error: %u", response.status_code);
                return;
            }

            string? body = response.get_body_string();
            if (body == null) return;

            var entries = parse_atom_entries(body);

            Idle.add(() => {
                if (search_query.length > 0) {
                    set_label(@"Search Results: \"$(search_query)\" in $(category_name)");
                } else {
                    set_label(category_name);
                }
                foreach (var entry in entries) {
                    add_item(entry.title, entry.article_url, entry.thumbnail, category, "Reddit", entry.published);
                }
                return false;
            });
        });
    }

    private class RedditEntry {
        public string title;
        public string article_url;
        public string? thumbnail;
        public string? published;
    }

    // Parse a subreddit's Atom feed into a list of entries. Done with plain
    // regexes rather than the libxml DOM parsing rssFeedProcessor.vala uses -
    // Atom entries here are flat (their inner HTML is XML-entity-escaped,
    // not raw nested tags), so there's no risk of a nested "<entry>" or
    // "</entry>" confusing the non-greedy match below.
    private Gee.ArrayList<RedditEntry> parse_atom_entries(string xml) {
        var results = new Gee.ArrayList<RedditEntry>();
        try {
            var entry_regex = new Regex("<entry>(.*?)</entry>", RegexCompileFlags.DOTALL);
            MatchInfo m;
            if (!entry_regex.match(xml, 0, out m)) return results;
            do {
                string entry_xml = m.fetch(1);
                var entry = new RedditEntry();

                entry.title = xml_unescape(extract_tag(entry_xml, "title"));
                if (entry.title.length == 0) continue;

                string content_html = xml_unescape(extract_tag(entry_xml, "content"));

                // The real external article URL (when there is one) is the
                // href of the "[link]" anchor in the content body - the
                // feed's own top-level <link> always points at Reddit's own
                // comments page instead. Self-posts/meta threads don't have
                // a "[link]" anchor at all, so fall back to Reddit's page.
                string? link_href = extract_href_before_text(content_html, "[link]");
                entry.article_url = link_href ?? extract_attr_value(entry_xml, "link", "href") ?? "";
                if (entry.article_url.length == 0) continue;

                entry.thumbnail = Tools.ImageProcessor.extract_image_from_html_snippet(content_html);
                entry.published = extract_tag(entry_xml, "published");

                results.add(entry);
            } while (m.next());
        } catch (GLib.Error e) {
            warning("Reddit RSS parse error: %s", e.message);
        }
        return results;
    }

    // Extract the text content of the first <tag>...</tag> in `xml`.
    private string extract_tag(string xml, string tag) {
        try {
            var regex = new Regex("<" + tag + "[^>]*>(.*?)</" + tag + ">", RegexCompileFlags.DOTALL);
            MatchInfo m;
            if (regex.match(xml, 0, out m)) {
                return m.fetch(1);
            }
        } catch (GLib.Error e) { }
        return "";
    }

    // Extract the value of `attr` from the first self-closing <tag .../> in `xml`
    // (used for Atom's <link href="..." /> element).
    private string? extract_attr_value(string xml, string tag, string attr) {
        try {
            var regex = new Regex("<" + tag + "\\s+[^>]*" + attr + "=\"([^\"]*)\"", RegexCompileFlags.DOTALL);
            MatchInfo m;
            if (regex.match(xml, 0, out m)) {
                return m.fetch(1);
            }
        } catch (GLib.Error e) { }
        return null;
    }

    // Find the href of the <a href="...">LABEL</a> anchor whose text is
    // exactly `label` (e.g. "[link]"). Reddit's Atom content wraps the real
    // external article URL this way.
    private string? extract_href_before_text(string html, string label) {
        try {
            string escaped_label = Regex.escape_string(label);
            var regex = new Regex("<a href=\"([^\"]+)\">\\s*" + escaped_label + "\\s*</a>", RegexCompileFlags.DOTALL);
            MatchInfo m;
            if (regex.match(html, 0, out m)) {
                return m.fetch(1);
            }
        } catch (GLib.Error e) { }
        return null;
    }

    // Undo one level of XML escaping (Reddit's Atom feed escapes each
    // entry's embedded HTML this way) - not the fuller HTML-entity/tag
    // stripping stripHtmlUtils.strip_html does, since callers here still
    // need real "<" / ">" characters to regex the embedded HTML for hrefs
    // and image URLs before any stripping happens.
    private string xml_unescape(string s) {
        string out_str = s;
        out_str = out_str.replace("&lt;", "<");
        out_str = out_str.replace("&gt;", ">");
        out_str = out_str.replace("&quot;", "\"");
        out_str = out_str.replace("&#39;", "'");
        out_str = out_str.replace("&apos;", "'");
        out_str = out_str.replace("&amp;", "&");
        return out_str.strip();
    }

    public override string get_source_name() {
        return "Reddit";
    }
}
