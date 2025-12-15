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
using Gee;

/*
 * Article snippet helper service
 */

public class ArticleSnippet : GLib.Object {
    public string snippet { get; set; }
    public string? published { get; set; }

    public ArticleSnippet() {
        snippet = "";
        published = null;
    }
}

public delegate void ArticleSnippetCallback(ArticleSnippet article_snippet);

public class ArticleSnippetService : GLib.Object {
    // Fetch a short snippet from an article URL using common meta tags or first paragraph
    // This service is UI-agnostic and does not touch GTK widgets. It returns
    // an ArticlePreview object via the callback containing snippet and
    // optional published date string.
    public static void fetch_snippet_async(string url, ArticleSnippetCallback on_done, NewsSource source, string? display_source, Gee.ArrayList<ArticleItem>? article_buffer = null) {
        // If caller provided an article buffer, check for a pre-cached snippet
        // for FOX entries (feed-provided NewsArticle objects). If found, return
        // it immediately without performing a network fetch to keep the UI snappy.
        if (article_buffer != null && source == NewsSource.FOX) {
            string? buf_snippet = null;
            string? buf_published = null;
            foreach (var item in article_buffer) {
                if (item.url == url && item.get_type().name() == "Paperboy.NewsArticle") {
                    var na = (Paperboy.NewsArticle) item;
                    buf_snippet = na.snippet;
                    buf_published = na.published;
                    break;
                }
            }
            if (buf_snippet != null && buf_snippet.length > 0) {
                Idle.add(() => {
                    var article_snippet = new ArticleSnippet();
                    article_snippet.snippet = stripHtmlUtils.strip_html(buf_snippet);
                    article_snippet.published = (buf_published != null && buf_published.length > 0) ? buf_published : null;
                    on_done(article_snippet);
                    return false;
                });
                return;
            }
        }

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
                var article_snippet = new ArticleSnippet();
                article_snippet.snippet = final;
                article_snippet.published = (published.length > 0) ? published : null;
                on_done(article_snippet);
                return false;
            });
            return null;
        });
    }




        // Resolve a user-friendly display name for an article given available
        // inputs. This function is UI-agnostic and returns a plain string.
        public static string resolve_display_source(
            string url,
            NewsSource article_src,
            string? explicit_source_name,
            string? homepage_published_any,
            string? category_id,
            NewsPreferences prefs,
            Gee.ArrayList<ArticleItem>? article_buffer = null
        ) {
            string? display_source = null;

            if (explicit_source_name != null && explicit_source_name.length > 0) {
                display_source = explicit_source_name;
            } else {
                string? url_display_name = null;
                string? url_logo_url = null;
                string? url_filename = null;
                try {
                    SourceMetadata.get_source_info_by_url(url, out url_display_name, out url_logo_url, out url_filename);
                } catch (GLib.Error e) { }
                if (url_display_name != null && url_display_name.length > 0) display_source = url_display_name;
            }

            if (display_source == null || display_source.length == 0) {
                if (category_id != null && category_id == "local_news") {
                    if (prefs.user_location_city != null && prefs.user_location_city.length > 0)
                        display_source = prefs.user_location_city;
                    else
                        display_source = "Local News";
                } else {
                    if (article_src == prefs.news_source) {
                        string host = UrlUtils.extract_host_from_url(url);
                        if (host != null && host.length > 0) {
                            string lowhost = host.down();
                            if (lowhost.index_of("bbc") >= 0 || lowhost.index_of("guardian") >= 0 || lowhost.index_of("nytimes") >= 0 || lowhost.index_of("wsj") >= 0 || lowhost.index_of("bloomberg") >= 0 || lowhost.index_of("reuters") >= 0 || lowhost.index_of("npr") >= 0 || lowhost.index_of("fox") >= 0) {
                                display_source = SourceUtils.get_source_name(article_src);
                            } else {
                                display_source = UrlUtils.prettify_host(host);
                            }
                        }
                    }
                    if (display_source == null) display_source = SourceUtils.get_source_name(article_src);
                }
            }

            // Guaranteed non-null result
            if (display_source == null) return "";
            return display_source;
        }

        // Sanitize an encoded per-item `source_name` and optionally extract a
        // published date from the provided article buffer. This keeps UI code
        // free of parsing and buffer-inspection logic.
        public static void sanitize_source_and_lookup_published(
            string url,
            string? raw_explicit_source_name,
            Gee.ArrayList<ArticleItem>? article_buffer,
            out string? explicit_source_name_out,
            out string? homepage_published_any_out
        ) {
            explicit_source_name_out = raw_explicit_source_name;
            homepage_published_any_out = null;

            if (explicit_source_name_out != null && explicit_source_name_out.length > 0) {
                int pipe_idx = explicit_source_name_out.index_of("||");
                if (pipe_idx >= 0 && explicit_source_name_out.length > pipe_idx) {
                    explicit_source_name_out = explicit_source_name_out.substring(0, pipe_idx);
                }
                int cat_idx = explicit_source_name_out.index_of("##category::");
                if (cat_idx >= 0 && explicit_source_name_out.length > cat_idx) {
                    explicit_source_name_out = explicit_source_name_out.substring(0, cat_idx);
                }

                try {
                    string? meta_display_name = SourceMetadata.get_display_name_for_source(explicit_source_name_out);
                    if (meta_display_name == null || meta_display_name.length == 0) {
                        string? url_display_name = null;
                        string? url_logo_url = null;
                        string? url_filename = null;
                        try { SourceMetadata.get_source_info_by_url(url, out url_display_name, out url_logo_url, out url_filename); } catch (GLib.Error e) { }
                        if (url_display_name != null && url_display_name.length > 0) meta_display_name = url_display_name;
                    }
                    if (meta_display_name != null && meta_display_name.length > 0) explicit_source_name_out = meta_display_name;
                } catch (GLib.Error e) { }
            }

            if (article_buffer != null) {
                foreach (var item in article_buffer) {
                    if (item.url == url) {
                        try {
                            if (item.get_type().name() == "Paperboy.NewsArticle") {
                                var na = (Paperboy.NewsArticle) item;
                                if (na.published != null && na.published.length > 0) {
                                    homepage_published_any_out = na.published;
                                    break;
                                }
                            }
                        } catch (GLib.Error e) { }
                    }
                }
            }
        }
}
