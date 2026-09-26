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

// Scans a user-supplied website URL for links to PDF files - the discovery
// step behind a MagazineSource. Same background-Thread + GLib.Idle.add
// idiom as PodcastFeedResolver; the actual scan is a plain <a href> scrape
// (FeedUpdateManager.extract_alternate_feed_links is the same idea for
// <link> tags), not a crawl - only the one page the user pointed at is read.
namespace Paperboy {
    public class MagazineLink : GLib.Object {
        public string url;
        public string? link_text;

        public MagazineLink(string url, string? link_text) {
            this.url = url;
            this.link_text = link_text;
        }
    }

    public class MagazineSourceScanner : GLib.Object {
        public delegate void ScanCallback(bool success, Gee.ArrayList<Paperboy.MagazineLink> links, string? error_message);

        private static MagazineSourceScanner? instance = null;
        public static MagazineSourceScanner get_instance() {
            if (instance == null) instance = new MagazineSourceScanner();
            return instance;
        }

        // A page with nothing to find should never take long to say so -
        // real listing pages are at most a few hundred KB. Capping how
        // much of the response is actually read (rather than trusting
        // send_and_read() to pull the whole body into memory, how this
        // used to work) keeps an unusually large or slow-to-finish page
        // - a search results page, for instance - from making the scan
        // take a very long time or use a lot of memory before it ever
        // gets to the regex.
        private const int64 MAX_HTML_BYTES = 5 * 1024 * 1024;

        public void scan(string website_url, Soup.Session session, owned ScanCallback callback) {
            new GLib.Thread<void*>("magazine-source-scan", () => {
                var links = new Gee.ArrayList<Paperboy.MagazineLink>();
                string? error = null;
                try {
                    var msg = new Soup.Message("GET", website_url);
                    msg.get_request_headers().append("User-Agent", "paperboy/0.11");
                    GLib.InputStream? input_stream = session.send(msg, null);
                    if (msg.get_status() != Soup.Status.OK || input_stream == null) {
                        error = "Couldn't reach that page";
                    } else {
                        var buffer = new GLib.ByteArray();
                        uint8[] chunk = new uint8[65536];
                        while (buffer.len < MAX_HTML_BYTES) {
                            size_t bytes_read;
                            bool ok = input_stream.read_all(chunk, out bytes_read, null);
                            if (!ok || bytes_read == 0) break;
                            buffer.append(chunk[0:(int) bytes_read]);
                        }
                        input_stream.close(null);
                        buffer.append({0}); // (string) below needs a NUL terminator

                        string html = (string) buffer.data;
                        links = extract_pdf_links(html, website_url);
                        if (links.size == 0) error = "No PDF links found on that page";
                    }
                } catch (GLib.Error e) {
                    error = e.message;
                }

                GLib.Idle.add(() => {
                    callback(links.size > 0, links, error);
                    return false;
                });
                return null;
            });
        }

        // Plain <a href="...pdf"> scrape - deliberately simple (no JS
        // execution, no crawling beyond this one page). Also picks up an
        // explicit link title attribute or the anchor's own text as a title
        // candidate for the picker dialog.
        private Gee.ArrayList<Paperboy.MagazineLink> extract_pdf_links(string html, string base_url) {
            var results = new Gee.ArrayList<Paperboy.MagazineLink>();
            var seen = new Gee.HashSet<string>();

            try {
                // href=[quote] allows surrounding whitespace around "=" (some
                // generated markup writes `href = "..."`). A trailing
                // fragment after the query string (e.g. "file.pdf#page=3",
                // common for PDF viewers that deep-link to a page) is
                // matched but deliberately left out of the captured URL,
                // same as the query-less case - it's never sent to the
                // server anyway. Previously a fragment made the whole
                // match fail, since nothing accounted for it before the
                // closing quote.
                var anchor_regex = new GLib.Regex(
                    "<a\\s+[^>]*href\\s*=\\s*[\"']([^\"'#]+\\.pdf(?:\\?[^\"'#]*)?)(?:#[^\"']*)?[\"'][^>]*>(.*?)</a>",
                    GLib.RegexCompileFlags.CASELESS | GLib.RegexCompileFlags.DOTALL);
                GLib.MatchInfo match_info;
                anchor_regex.match(html, 0, out match_info);
                while (match_info.matches()) {
                    // href attribute values commonly HTML-encode "&" as
                    // "&amp;" in real markup (e.g. a query string like
                    // "id=1&amp;fmt=pdf") - left undecoded, that's a
                    // literally different, likely-broken URL.
                    string href = global::stripHtmlUtils.strip_html(match_info.fetch(1));
                    string inner_html = match_info.fetch(2) ?? "";
                    string? resolved = resolve_relative_url(href, base_url);
                    if (resolved != null && !seen.contains(resolved)) {
                        seen.add(resolved);
                        results.add(new Paperboy.MagazineLink(resolved, extract_link_text(inner_html)));
                    }
                    match_info.next();
                }
            } catch (GLib.RegexError e) {
                GLib.warning("MagazineSourceScanner: failed to scan for PDF links: %s", e.message);
            }

            return results;
        }

        // Real-world link markup (archive.org's download list in
        // particular) wraps a title in nested block elements right next to
        // a file-size span with no whitespace between them in the source -
        // e.g. "<div>Title</div><div>4.2M</div>" - stripHtmlUtils.strip_html
        // just deletes tags, so those would otherwise run together as
        // "Title4.2M". Replacing each tag with a space first keeps word
        // boundaries intact; strip_html's own whitespace collapsing then
        // cleans up the resulting extra spaces and decodes entities.
        private string? extract_link_text(string inner_html) {
            try {
                var tag_regex = new GLib.Regex("<[^>]+>");
                string spaced = tag_regex.replace(inner_html, -1, 0, " ");
                string text = global::stripHtmlUtils.strip_html(spaced).strip();
                if (text.length == 0) return null;
                return global::stripHtmlUtils.truncate_snippet(text, 120);
            } catch (GLib.RegexError e) {
                return null;
            }
        }

        private string? resolve_relative_url(string href, string base_url) {
            try {
                string resolved = GLib.Uri.resolve_relative(base_url, href, GLib.UriFlags.NONE);
                var resolved_uri = GLib.Uri.parse(resolved, GLib.UriFlags.NONE);
                if (resolved_uri.get_scheme() != "https" && resolved_uri.get_scheme() != "http") return null;
                return resolved;
            } catch (GLib.Error e) {
                return null;
            }
        }
    }
}
