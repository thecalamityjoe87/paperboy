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

public class ArticleScraper {
    // Scrape a list of section URLs and return a list of discovered articles.
    public static Gee.ArrayList<Paperboy.NewsArticle> scrape_section_urls(
        Gee.ArrayList<string> section_urls,
        string base_origin,
        string current_search_query,
        Soup.Session session
    ) {
        var articles = new Gee.ArrayList<Paperboy.NewsArticle>();

        int max_sections = 2; // keep caller's intent: limit to 2 sections
        int section_count = 0;
        foreach (string candidate_url in section_urls) {
            if (section_count >= max_sections) break;
            section_count++;
            var client = Paperboy.HttpClientUtils.get_default();
            var options = new Paperboy.HttpClientUtils.RequestOptions()
                .with_browser_headers()
                .with_timeout(8);
            var http_response = client.fetch_sync(candidate_url, options);

            if (!http_response.is_success() || http_response.body == null) continue;
            string body = http_response.get_body_string();

            // Try to parse JSON-LD structured data first
            var ld_regex = new Regex("<script[^>]*type=\\\"application/ld\\+json\\\"[^>]*>([\\s\\S]*?)</script>", RegexCompileFlags.DEFAULT);
            MatchInfo ld_info;
            if (ld_regex.match(body, 0, out ld_info)) {
                do {
                    string json_ld = ld_info.fetch(1);
                    parse_json_ld(json_ld, articles);
                } while (ld_info.next());
            }

            // Fallback: look for article blocks and extract anchors/images/snippets
            if (articles.size == 0) {
                var article_block_regex = new Regex("<article[\\s\\S]*?</article>", RegexCompileFlags.DEFAULT);
                MatchInfo block_info;
                if (article_block_regex.match(body, 0, out block_info)) {
                    int batch_limit = 18;
                    int batch_count = 0;
                    do {
                        if (batch_count >= batch_limit) break;
                        batch_count++;
                        string block = block_info.fetch(0);
                        var headline_regex = new Regex("<h2[^>]*>\\s*<a[^>]*href=\\\"(/[^\\\"]+)\\\"[^>]*>(.*?)</a>\\s*</h2>", RegexCompileFlags.DEFAULT);
                        var headline_h_regex = new Regex("<h[1-4][^>]*>\\s*<a[^>]*href=\\\"(/[^\\\"]+)\\\"[^>]*>(.*?)</a>\\s*</h[1-4]>", RegexCompileFlags.DEFAULT);
                        var anchor_class_regex = new Regex("<a[^>]*href=\\\"(/[^\\\"]+)\\\"[^>]*class=\\\"[^\\\"]*(?:title|headline|story|article)[^\\\"]*\\\"[^>]*>(.*?)</a>", RegexCompileFlags.DEFAULT);
                        MatchInfo headline_info;
                        string rel_url = null;
                        string title = null;
                        if (headline_regex.match(block, 0, out headline_info)) {
                            rel_url = headline_info.fetch(1);
                            title = headline_info.fetch(2).strip();
                        } else if (headline_h_regex.match(block, 0, out headline_info)) {
                            rel_url = headline_info.fetch(1);
                            title = headline_info.fetch(2).strip();
                        } else if (anchor_class_regex.match(block, 0, out headline_info)) {
                            rel_url = headline_info.fetch(1);
                            title = headline_info.fetch(2).strip();
                        } else {
                            var anchor_fallback = new Regex("<a[^>]*href=\\\"(/[^\\\"]+)\\\"[^>]*>([^<]{30,}?)</a>", RegexCompileFlags.DEFAULT);
                            MatchInfo af_info;
                            if (anchor_fallback.match(block, 0, out af_info)) {
                                rel_url = af_info.fetch(1);
                                title = af_info.fetch(2).strip();
                            }
                        }
                        if (rel_url != null && title != null) {
                            string url = rel_url.has_prefix("http") ? rel_url : base_origin + rel_url;
                            if (title.length > 10 && !is_duplicate_url(articles, url)) {
                                var article = new Paperboy.NewsArticle();
                                article.title = title;
                                article.url = url;
                                var img_regex = new Regex("<img[^>]*src=\\\"(https://static\\.[^\\\"]+)\\\"[^>]*alt=\\\"([^\\\"]*)\\\"[^>]*>", RegexCompileFlags.DEFAULT);
                                MatchInfo img_info;
                                if (img_regex.match(block, 0, out img_info)) {
                                    do {
                                        string img_url = img_info.fetch(1);
                                        string alt_text = img_info.fetch(2);
                                        if (!(img_url.contains("og-fox-news.png") || img_url.contains("logo") || img_url.contains("favicon") || alt_text.contains("Fox News"))) {
                                            article.image_url = img_url;
                                            break;
                                        }
                                    } while (img_info.next());
                                }
                                var p_regex = new Regex("<p[^>]*>(.*?)</p>", RegexCompileFlags.DEFAULT);
                                MatchInfo p_info;
                                if (p_regex.match(block, 0, out p_info)) {
                                    string snippet = p_info.fetch(1).strip();
                                    if (snippet.length > 0) {
                                        article.snippet = strip_html(snippet);
                                    }
                                }
                                // Try to extract a time/datetime from the article block
                                var time_dt_regex = new Regex("<time[^>]*datetime=\\\"([^\\\"]+)\\\"[^>]*>(.*?)</time>", RegexCompileFlags.DEFAULT);
                                MatchInfo time_info;
                                if (time_dt_regex.match(block, 0, out time_info)) {
                                    // prefer datetime attribute if present
                                    string dt_attr = time_info.fetch(1).strip();
                                    if (dt_attr.length > 0) {
                                        article.published = dt_attr;
                                    } else {
                                        string inner = time_info.fetch(2).strip();
                                        if (inner.length > 0) article.published = strip_html(inner);
                                    }
                                } else {
                                    // fallback: <time> without datetime attr
                                    var time_simple = new Regex("<time[^>]*>(.*?)</time>", RegexCompileFlags.DEFAULT);
                                    MatchInfo ts;
                                    if (time_simple.match(block, 0, out ts)) {
                                        string inner = ts.fetch(1).strip();
                                        if (inner.length > 0) article.published = strip_html(inner);
                                    }
                                }
                                articles.add(article);
                            }
                        }
                    } while (block_info.next());
                }
            }

            if (articles.size > 0) break;
        }

        return articles;
    }

    private static void parse_json_ld(string json_content, Gee.ArrayList<Paperboy.NewsArticle> articles) {
        try {
            var parser = new Json.Parser();
            parser.load_from_data(json_content);
            var root = parser.get_root();
            if (root.get_node_type() == Json.NodeType.ARRAY) {
                var array = root.get_array();
                foreach (var element in array.get_elements()) {
                    parse_json_article(element.get_object(), articles);
                }
            } else if (root.get_node_type() == Json.NodeType.OBJECT) {
                parse_json_article(root.get_object(), articles);
            }
        } catch (GLib.Error e) {
            // ignore JSON parse errors
        }
    }

    private static void parse_json_article(Json.Object obj, Gee.ArrayList<Paperboy.NewsArticle> articles) {
        if (obj.has_member("@type") && obj.get_string_member("@type") == "NewsArticle") {
            if (obj.has_member("headline") && obj.has_member("url")) {
                string title = obj.get_string_member("headline");
                string url = obj.get_string_member("url");
                if (title.length > 10 && !is_duplicate_url(articles, url)) {
                    var article = new Paperboy.NewsArticle();
                    article.title = title;
                    article.url = url;
                    if (obj.has_member("image")) {
                        var image_node = obj.get_member("image");
                        if (image_node.get_node_type() == Json.NodeType.OBJECT) {
                            var image_obj = image_node.get_object();
                            if (image_obj.has_member("url")) {
                                article.image_url = image_obj.get_string_member("url");
                            }
                        } else if (image_node.get_node_type() == Json.NodeType.ARRAY) {
                            var image_array = image_node.get_array();
                            if (image_array.get_length() > 0) {
                                var first_image = image_array.get_element(0);
                                if (first_image.get_node_type() == Json.NodeType.OBJECT) {
                                    var img_obj = first_image.get_object();
                                    if (img_obj.has_member("url")) {
                                        article.image_url = img_obj.get_string_member("url");
                                    }
                                }
                            }
                        }
                    }
                    // datePublished is commonly present in JSON-LD for NewsArticle
                    if (obj.has_member("datePublished")) {
                        try {
                            article.published = obj.get_string_member("datePublished");
                        } catch (GLib.Error e) {
                            // ignore non-string datePublished formats for now
                        }
                    }
                    articles.add(article);
                }
            }
        }
    }

    private static bool is_duplicate_url(Gee.ArrayList<Paperboy.NewsArticle> articles, string url) {
        foreach (var article in articles) {
            if (article.url == url) return true;
        }
        return false;
    }

    private static string strip_html(string input) {
        var regex = new Regex("<[^>]+>", RegexCompileFlags.DEFAULT);
        return regex.replace(input, -1, 0, "");
    }
}
