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
 * Reader-view article extraction: fetches an article's HTML and pulls out
 * its title/byline/hero image/body text using a small Readability-style
 * heuristic (find the DOM container with the highest paragraph-text
 * density, low link density) rather than a full browser render.
 */

public class ExtractedArticle : GLib.Object {
    public string title { get; set; default = ""; }
    public string? author { get; set; default = null; }
    public string? published { get; set; default = null; }
    public string? hero_image_url { get; set; default = null; }
    public string? site_name { get; set; default = null; }
    public Gee.ArrayList<string> paragraphs;
    public bool success { get; set; default = false; }

    public ExtractedArticle() {
        paragraphs = new Gee.ArrayList<string>();
    }
}

public delegate void ArticleExtractedCallback(ExtractedArticle article);

public class ArticleExtractorService : GLib.Object {

    public static void extract_async(string url, owned ArticleExtractedCallback on_done) {
        new Thread<void*>("article-extract", () => {
            var result = extract_sync(url);
            Idle.add(() => { on_done(result); return false; });
            return null;
        });
    }

    private static ExtractedArticle extract_sync(string url) {
        var article = new ExtractedArticle();

        var client = Paperboy.HttpClientUtils.get_default();
        var options = new Paperboy.HttpClientUtils.RequestOptions().with_browser_headers().with_timeout(Paperboy.HttpClientUtils.TIMEOUT_SLOW);
        var response = client.fetch_sync(url, options);
        if (!response.is_success() || response.body == null) return article;

        string html = response.get_body_string() ?? "";
        if (html.length == 0) return article;

        extract_meta(html, article);

        int opts = Html.ParserOption.RECOVER | Html.ParserOption.NOERROR | Html.ParserOption.NOWARNING | Html.ParserOption.NONET;
        // Force UTF-8 explicitly rather than letting libxml2 auto-detect
        // from the page's own (sometimes wrong, or absent) <meta charset>
        // declaration - HttpClientUtils/our own string handling already
        // treat the raw response as UTF-8, so if the parser second-guesses
        // that based on a stale/incorrect in-page declaration it can
        // mis-decode already-correct UTF-8 bytes (typical symptom: curly
        // quotes/apostrophes turning into "â€œ"/"â€™"-style mojibake).
        Html.Doc* doc = Html.Doc.read_memory(html.to_utf8(), (int) html.length, url, "UTF-8", opts);
        if (doc == null) {
            article.success = article.title.length > 0;
            return article;
        }

        Xml.Node* root = doc->get_root_element();
        if (root != null) {
            var scores = new Gee.HashMap<string, double?>();
            score_pass(root, scores);

            string? best_path = null;
            double best_score = 0;
            foreach (var entry in scores.entries) {
                if (entry.value > best_score) {
                    best_score = entry.value;
                    best_path = entry.key;
                }
            }

            if (best_path != null) {
                Xml.Node* container = find_node_by_path(root, best_path);
                if (container != null && container->children != null) {
                    extract_content_nodes(container->children, article.paragraphs);
                }
            }
        }

        delete doc;

        if (article.title.length == 0 && article.paragraphs.size == 0) {
            article.success = false;
        } else {
            article.success = article.paragraphs.size > 0;
        }
        return article;
    }

    // ---- Meta tag extraction (title/author/date/image/site name) ----

    private static void extract_meta(string html, ExtractedArticle article) {
        string lower = html.down();
        int pos = 0;
        string? title_fallback = null;

        while ((pos = lower.index_of("<meta", pos)) >= 0) {
            int end = lower.index_of(">", pos);
            if (end < 0) break;
            string tag = html.substring(pos, end - pos + 1);

            string name_attr = stripHtmlUtils.extract_attr(tag, "name").down();
            string prop_attr = stripHtmlUtils.extract_attr(tag, "property").down();
            string content = stripHtmlUtils.extract_attr(tag, "content").strip();

            if (content.length > 0) {
                if (article.title.length == 0 && (prop_attr == "og:title" || name_attr == "twitter:title")) {
                    article.title = stripHtmlUtils.strip_html(content);
                }
                if (article.author == null && (name_attr == "author" || prop_attr == "article:author" || name_attr == "twitter:creator")) {
                    string a = stripHtmlUtils.strip_html(content);
                    if (a.has_prefix("http://") == false && a.has_prefix("https://") == false && a.length > 0) {
                        article.author = a.has_prefix("@") ? a.substring(1) : a;
                    }
                }
                if (article.published == null && (prop_attr == "article:published_time" || name_attr == "pubdate" || name_attr == "publish-date" || name_attr == "date")) {
                    article.published = content;
                }
                if (article.hero_image_url == null && (prop_attr == "og:image" || name_attr == "twitter:image" || name_attr == "twitter:image:src")) {
                    article.hero_image_url = content;
                }
                if (article.site_name == null && prop_attr == "og:site_name") {
                    article.site_name = stripHtmlUtils.strip_html(content);
                }
            }

            pos = end + 1;
        }

        if (article.title.length == 0) {
            int t1 = lower.index_of("<title");
            if (t1 >= 0) {
                int t1end = lower.index_of(">", t1);
                int t2 = lower.index_of("</title>", t1end);
                if (t1end > t1 && t2 > t1end) {
                    title_fallback = stripHtmlUtils.strip_html(html.substring(t1end + 1, t2 - (t1end + 1))).strip();
                }
            }
            if (title_fallback != null) article.title = title_fallback;
        }

        if (article.published == null) {
            int jpos = lower.index_of("\"datepublished\"");
            if (jpos >= 0) {
                int colon = lower.index_of(":", jpos);
                if (colon > jpos) {
                    int qstart = lower.index_of("\"", colon);
                    if (qstart > colon) {
                        int qend = lower.index_of("\"", qstart + 1);
                        if (qend > qstart && html.length >= qend) {
                            string val = html.substring(qstart + 1, qend - (qstart + 1)).strip();
                            if (val.length > 0) article.published = val;
                        }
                    }
                }
            }
        }
    }

    // ---- DOM-based content extraction ----

    private static bool is_skip_tag(string tag) {
        switch (tag) {
            case "script": case "style": case "noscript": case "nav": case "footer":
            case "aside": case "form": case "iframe": case "svg": case "button":
            case "select": case "option": case "header": case "figcaption":
                return true;
            default:
                return false;
        }
    }

    private static bool has_boilerplate_hint(Xml.Node* n) {
        string cls = (n->get_prop("class") ?? "").down();
        string id = (n->get_prop("id") ?? "").down();
        string combined = cls + " " + id;
        string[] bad = {
            "nav", "menu", "sidebar", "footer", "comment", "share", "social",
            "related", "promo", "subscribe", "newsletter", "advert", "ad-",
            "popup", "cookie", "breadcrumb", "tag-list", "byline-social"
        };
        foreach (var b in bad) {
            if (combined.index_of(b) >= 0) return true;
        }
        return false;
    }

    private static string node_text(Xml.Node* n) {
        string? c = n->get_content();
        return c != null ? stripHtmlUtils.strip_html(c) : "";
    }

    private static int sum_link_text(Xml.Node* node) {
        int sum = 0;
        for (Xml.Node* n = node->children; n != null; n = n->next) {
            if (n->type != Xml.ElementType.ELEMENT_NODE) continue;
            if (n->name.down() == "a") {
                sum += node_text(n).length;
            } else if (n->children != null) {
                sum += sum_link_text(n);
            }
        }
        return sum;
    }

    private static double link_density(Xml.Node* n) {
        string total = node_text(n);
        if (total.length == 0) return 0.0;
        return (double) sum_link_text(n) / (double) total.length;
    }

    // Scores every element that has a real <p> child, keyed by that
    // element's DOM path, so the container with the most substantial,
    // least link-heavy paragraphs (the actual article body) wins over
    // nav/sidebar/related-links blocks that also happen to contain text.
    private static void score_pass(Xml.Node* node, Gee.HashMap<string, double?> scores) {
        for (Xml.Node* n = node; n != null; n = n->next) {
            if (n->type != Xml.ElementType.ELEMENT_NODE) continue;
            string tag = n->name.down();
            if (is_skip_tag(tag)) continue;
            if (has_boilerplate_hint(n)) continue;

            if (tag == "p") {
                string text = node_text(n);
                if (text.length >= 25 && link_density(n) < 0.5 && n->parent != null) {
                    double add = text.length + 40;
                    // Credit the parent and a couple of ancestor levels above
                    // it (with diminishing weight) rather than just the
                    // immediate parent - sites that wrap every paragraph in
                    // its own container (e.g. BBC's one-<div>-per-<p>
                    // markup) would otherwise split each paragraph's score
                    // across a different single-paragraph "container" and
                    // never let the real, shared article body win.
                    Xml.Node* ancestor = n->parent;
                    double weight = 1.0;
                    int levels = 0;
                    while (ancestor != null && levels < 8) {
                        string path = ancestor->get_path();
                        double current = scores.has_key(path) ? scores.get(path) : 0.0;
                        scores.set(path, current + add * weight);
                        ancestor = ancestor->parent;
                        weight *= 0.75;
                        levels++;
                    }
                }
            }

            if (n->children != null) score_pass(n->children, scores);
        }
    }

    private static Xml.Node* find_node_by_path(Xml.Node* node, string path) {
        for (Xml.Node* n = node; n != null; n = n->next) {
            if (n->type != Xml.ElementType.ELEMENT_NODE) continue;
            if (n->get_path() == path) return n;
            if (n->children != null) {
                Xml.Node* found = find_node_by_path(n->children, path);
                if (found != null) return found;
            }
        }
        return null;
    }

    // Walks the winning container in document order, pulling paragraph-like
    // text out and recursing into plain wrapper elements (div/section/etc)
    // so paragraphs nested a level or two deep are still picked up.
    private static void extract_content_nodes(Xml.Node* node, Gee.ArrayList<string> paragraphs) {
        for (Xml.Node* n = node; n != null; n = n->next) {
            if (n->type != Xml.ElementType.ELEMENT_NODE) continue;
            string tag = n->name.down();
            if (is_skip_tag(tag)) continue;
            if (has_boilerplate_hint(n)) continue;

            if (tag == "p" || tag == "h2" || tag == "h3" || tag == "h4" || tag == "blockquote" || tag == "li") {
                string text = node_text(n);
                if (text.length >= 20 && link_density(n) < 0.6) {
                    paragraphs.add(text);
                }
            } else if (tag == "div" || tag == "section" || tag == "article" || tag == "ul" || tag == "ol" || tag == "span") {
                if (n->children != null) extract_content_nodes(n->children, paragraphs);
            }
        }
    }
}
