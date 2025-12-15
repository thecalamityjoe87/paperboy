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

/*
 * Article preview helper service
 */

public class ArticlePreview : GLib.Object {
    public string snippet { get; set; }
    public string? published { get; set; }

    public ArticlePreview() {
        snippet = "";
        published = null;
    }
}

public delegate void ArticlePreviewCallback(ArticlePreview preview);

public class ArticlePreviewService : GLib.Object {
    // Fetch a short snippet from an article URL using common meta tags or first paragraph
    // This service is UI-agnostic and does not touch GTK widgets. It returns
    // an ArticlePreview object via the callback containing snippet and
    // optional published date string.
    public static void fetch_snippet_async(string url, ArticlePreviewCallback on_done, NewsSource source, string? display_source) {
        new Thread<void*>("snippet-fetch", () => {
            string result = "";
            string published = "";
                var client = Paperboy.HttpClientUtils.get_default();
                var options = new Paperboy.HttpClientUtils.RequestOptions().with_browser_headers();
                var http_response = client.fetch_sync(url, options);

                if (http_response.is_success() && http_response.body != null && http_response.body.get_size() > 0) {
                    // Get response data from GLib.Bytes
                    unowned uint8[] body_data = http_response.body.get_data();

                    // Copy to a null-terminated buffer
                    uint8[] buf = new uint8[body_data.length + 1];
                    Memory.copy(buf, body_data, body_data.length);
                    buf[body_data.length] = 0;
                    string html = (string) buf;

                    // Use centralized stripHtmlUtils for snippet extraction
                    result = stripHtmlUtils.extract_snippet_from_html(html);

                    // Try to extract published date/time from common meta tags or <time>
                    string lower = html.down();
                    int pos = 0;
                    while ((pos = lower.index_of("<meta", pos)) >= 0) {
                        int end = lower.index_of(">", pos);
                        if (end < 0 || end <= pos) break;
                        if (html.length < end + 1 || lower.length < end + 1) break;
                        string tag = html.substring(pos, end - pos + 1);
                        string tl = lower.substring(pos, end - pos + 1);
                        if (tl.index_of("datepublished") >= 0 || tl.index_of("article:published_time") >= 0 || tl.index_of("property=\"article:published_time\"") >= 0 || tl.index_of("name=\"pubdate\"") >= 0 || tl.index_of("itemprop=\"datePublished\"") >= 0) {
                            string content = stripHtmlUtils.extract_attr(tag, "content");
                            if (content != null && content.strip().length > 0) { published = content.strip(); break; }
                        }
                        pos = end + 1;
                    }
                    if (published.length == 0) {
                        // search for <time datetime=\"...\">
                        int tpos = lower.index_of("<time");
                        if (tpos >= 0) {
                            int tend = lower.index_of(">", tpos);
                            if (tend > tpos && html.length >= tend + 1) {
                                string ttag = html.substring(tpos, tend - tpos + 1);
                                string dt = stripHtmlUtils.extract_attr(ttag, "datetime");
                                if (dt != null && dt.strip().length > 0) published = dt.strip();
                                else {
                                    // fallback inner text
                                    int close = lower.index_of("</time>", tend);
                                    if (close > tend && html.length >= close && close > tend + 1) {
                                        string inner = html.substring(tend + 1, close - (tend + 1));
                                        inner = stripHtmlUtils.strip_html(inner).strip();
                                        if (inner.length > 0) published = inner;
                                    }
                                }
                            }
                        }
                    }
                }
            string final = result;
            Idle.add(() => {
                var preview = new ArticlePreview();
                preview.snippet = final;
                preview.published = (published.length > 0) ? published : null;
                on_done(preview);
                return false;
            });
            return null;
        });
    }
}
