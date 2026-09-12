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

public enum ArticleBlockKind { TEXT, IMAGE, VIDEO_FILE, VIDEO_EMBED, VIDEO_LINK }

// One piece of article body content in document order. TEXT carries
// `text`; IMAGE carries `image_url`; VIDEO_FILE carries `video_url` (the
// playable media file) and optionally `image_url` as its poster;
// VIDEO_EMBED carries `video_url` (the provider's embed page URL);
// VIDEO_LINK carries `video_url` (a watch-page URL for a proprietary
// in-house player we can't play inline) and optionally `image_url` as its
// thumbnail - rendered as a "watch on site" card that opens the live page.
public class ArticleBlock : GLib.Object {
    public ArticleBlockKind kind;
    public string? text;
    public string? image_url;
    public string? video_url;
}

public class ExtractedArticle : GLib.Object {
    public string title { get; set; default = ""; }
    public string? author { get; set; default = null; }
    public string? published { get; set; default = null; }
    public string? hero_image_url { get; set; default = null; }
    public string? site_name { get; set; default = null; }
    public Gee.ArrayList<ArticleBlock> blocks;
    public bool success { get; set; default = false; }

    public ExtractedArticle() {
        blocks = new Gee.ArrayList<ArticleBlock>();
    }
}

public delegate void ArticleExtractedCallback(ExtractedArticle article);

public class ArticleExtractorService : GLib.Object {

    public static void extract_async(string url, owned ArticleExtractedCallback on_done) {
        new Thread<void*>("article-extract", () => {
            string? html = fetch_html_sync(url);
            var result = html != null ? parse_html(html, url) : new ExtractedArticle();

            Idle.add(() => {
                if (result.success) {
                    on_done(result);
                    return false;
                }

                // The plain fetch didn't get us a readable article - this
                // is what a consent wall/interstitial, a JS-only-hydrated
                // page, an active anti-bot challenge (e.g. DataDome), or
                // our own density heuristic picking the wrong container
                // all look like from here. Rather than guess which one it
                // is, fall back to actually loading the page in a hidden
                // WebKit view and running Mozilla's real Readability
                // algorithm against the live rendered DOM.
                RenderedPageFetcher.fetch_async(url, (readability_result) => {
                    var rendered_result = readability_result != null ? build_article_from_readability(readability_result, url) : null;
                    on_done(rendered_result != null && rendered_result.success ? rendered_result : result);
                });
                return false;
            });
            return null;
        });
    }

    private static string? fetch_html_sync(string url) {
        var client = Paperboy.HttpClientUtils.get_default();
        var options = new Paperboy.HttpClientUtils.RequestOptions().with_browser_headers().with_timeout(Paperboy.HttpClientUtils.TIMEOUT_SLOW);
        var response = client.fetch_sync(url, options);
        if (!response.is_success() || response.body == null) return null;

        string html = response.get_body_string() ?? "";
        return html.length > 0 ? html : null;
    }

    private static ExtractedArticle parse_html(string html, string url) {
        var article = new ExtractedArticle();

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
                    var seen_video_urls = new Gee.HashSet<string>();
                    extract_content_nodes(container->children, article.blocks, url, article.hero_image_url, seen_video_urls);
                }
            }
        }

        delete doc;

        int text_block_count = count_text_blocks(article);

        // A near-empty result here usually isn't a truly empty page - it's
        // a consent wall/interstitial replacing the real page, or a
        // JS-hydrated site that never puts real <p> text in the raw HTML
        // at all. Most sites doing either still publish the clean article
        // text as schema.org JSON-LD for search engines regardless, so try
        // that before giving up and showing the reader-view error screen.
        if (text_block_count < 2) {
            if (try_extract_from_json_ld(html, article)) {
                text_block_count = count_text_blocks(article);
            }
        }

        if (article.title.length == 0 && text_block_count == 0) {
            article.success = false;
        } else {
            article.success = text_block_count > 0;
        }
        return article;
    }

    private static int count_text_blocks(ExtractedArticle article) {
        int count = 0;
        foreach (var b in article.blocks) {
            if (b.kind == ArticleBlockKind.TEXT) count++;
        }
        return count;
    }

    // Readability.js already found the right container and stripped the
    // boilerplate around it, so this skips score_pass/find_node_by_path
    // entirely and reuses extract_content_nodes directly on its cleaned
    // output - the same image/video/data-video-id handling as the normal
    // path, just fed a different (already-narrowed) piece of DOM.
    private static ExtractedArticle build_article_from_readability(ReadabilityResult result, string url) {
        var article = new ExtractedArticle();

        string? title = result.title;
        article.title = title != null ? stripHtmlUtils.strip_html(title) : "";
        // Readability's byline sometimes pulls in surrounding nav/social
        // markup as extra whitespace-separated lines (e.g. a "Social Links
        // Navigation" chunk) - keep only the first line, which is
        // consistently the real byline text in practice.
        if (result.byline != null) {
            string first_line = stripHtmlUtils.strip_html(result.byline.split("\n")[0]);
            article.author = first_line.length > 0 ? first_line : null;
        }
        article.site_name = result.site_name != null ? stripHtmlUtils.strip_html(result.site_name) : null;
        article.published = result.published;

        if (result.content_html.length == 0) {
            article.success = false;
            return article;
        }

        int opts = Html.ParserOption.RECOVER | Html.ParserOption.NOERROR | Html.ParserOption.NOWARNING | Html.ParserOption.NONET;
        Html.Doc* doc = Html.Doc.read_memory(result.content_html.to_utf8(), (int) result.content_html.length, url, "UTF-8", opts);
        if (doc == null) {
            article.success = article.title.length > 0;
            return article;
        }

        Xml.Node* root = doc->get_root_element();
        if (root != null && root->children != null) {
            var seen_video_urls = new Gee.HashSet<string>();
            extract_content_nodes(root->children, article.blocks, url, null, seen_video_urls);
        }
        delete doc;

        // Promote the lead image out of the body flow into the dedicated
        // hero slot, matching how the normal (non-Readability) path shows
        // a hero image up top rather than as the first inline body image.
        for (int i = 0; i < article.blocks.size; i++) {
            if (article.blocks[i].kind == ArticleBlockKind.IMAGE) {
                article.hero_image_url = article.blocks[i].image_url;
                article.blocks.remove_at(i);
                break;
            }
        }

        article.success = count_text_blocks(article) > 0;
        return article;
    }

    // ---- JSON-LD fallback (schema.org Article/NewsArticle) ----

    // Finds every <script type="application/ld+json"> block's raw content.
    // Manual scanning (matching extract_meta's approach above) rather than
    // an XPath query, since some sites emit malformed JSON-LD that would
    // otherwise need its own separate lenient parser pass.
    private static Gee.ArrayList<string> find_json_ld_scripts(string html) {
        var results = new Gee.ArrayList<string>();
        string lower = html.down();
        int pos = 0;
        while ((pos = lower.index_of("application/ld+json", pos)) >= 0) {
            int tag_start = lower.last_index_of("<script", pos);
            int tag_end = lower.index_of(">", pos);
            if (tag_start < 0 || tag_end < 0) { pos += 1; continue; }
            int close = lower.index_of("</script>", tag_end);
            if (close < 0) { pos = tag_end + 1; continue; }
            string content = html.substring(tag_end + 1, close - (tag_end + 1)).strip();
            if (content.length > 0) results.add(content);
            pos = close + 9;
        }
        return results;
    }

    private static bool is_article_type(Json.Object obj) {
        if (!obj.has_member("@type")) return false;
        var type_node = obj.get_member("@type");
        var candidates = new Gee.ArrayList<string>();
        if (type_node.get_node_type() == Json.NodeType.VALUE) {
            string? v = type_node.get_string();
            if (v != null) candidates.add(v);
        } else if (type_node.get_node_type() == Json.NodeType.ARRAY) {
            foreach (var el in type_node.get_array().get_elements()) {
                if (el.get_node_type() == Json.NodeType.VALUE) {
                    string? v = el.get_string();
                    if (v != null) candidates.add(v);
                }
            }
        }
        foreach (var c in candidates) {
            string lower = c.down();
            if (lower.contains("article") || lower == "blogposting" || lower == "report") return true;
        }
        return false;
    }

    // JSON-LD publishers sometimes wrap the Article object in an array, or
    // in a top-level "@graph" list alongside unrelated schema (Organization,
    // BreadcrumbList, etc.) - walk whichever shape shows up for the first
    // object whose @type matches.
    private static Json.Object? find_article_object_in_node(Json.Node? node) {
        if (node == null) return null;
        if (node.get_node_type() == Json.NodeType.OBJECT) {
            var obj = node.get_object();
            if (is_article_type(obj)) return obj;
            if (obj.has_member("@graph")) {
                var found = find_article_object_in_node(obj.get_member("@graph"));
                if (found != null) return found;
            }
            return null;
        } else if (node.get_node_type() == Json.NodeType.ARRAY) {
            foreach (var el in node.get_array().get_elements()) {
                var found = find_article_object_in_node(el);
                if (found != null) return found;
            }
        }
        return null;
    }

    private static string? json_ld_author_name(Json.Node? node) {
        if (node == null) return null;
        if (node.get_node_type() == Json.NodeType.VALUE) return node.get_string();
        if (node.get_node_type() == Json.NodeType.OBJECT) {
            var obj = node.get_object();
            if (obj.has_member("name")) return obj.get_string_member("name");
        } else if (node.get_node_type() == Json.NodeType.ARRAY) {
            var arr = node.get_array();
            if (arr.get_length() > 0) return json_ld_author_name(arr.get_element(0));
        }
        return null;
    }

    private static string? json_ld_image_url(Json.Node? node) {
        if (node == null) return null;
        if (node.get_node_type() == Json.NodeType.VALUE) return node.get_string();
        if (node.get_node_type() == Json.NodeType.OBJECT) {
            var obj = node.get_object();
            if (obj.has_member("url")) return obj.get_string_member("url");
        } else if (node.get_node_type() == Json.NodeType.ARRAY) {
            var arr = node.get_array();
            if (arr.get_length() > 0) return json_ld_image_url(arr.get_element(0));
        }
        return null;
    }

    private static bool try_extract_from_json_ld(string html, ExtractedArticle article) {
        foreach (var raw in find_json_ld_scripts(html)) {
            Json.Object? candidate = null;
            try {
                var parser = new Json.Parser();
                parser.load_from_data(raw);
                candidate = find_article_object_in_node(parser.get_root());
            } catch (GLib.Error e) {
                continue;
            }
            if (candidate == null || !candidate.has_member("articleBody")) continue;

            string body = (candidate.get_string_member("articleBody") ?? "").strip();
            if (body.length < 100) continue;

            // articleBody is meant to be plain text per schema.org, but in
            // practice plenty of CMS pipelines populate it from the same
            // rich-text field as the live page without decoding it first -
            // strip_html both decodes any leftover entities (&rsquo; etc)
            // and drops any literal markup some sites do leave in there.
            var paragraphs = Regex.split_simple("\r\n\r\n|\n\n|\r\n|\n", body);
            bool added_any = false;
            foreach (var p in paragraphs) {
                string trimmed = stripHtmlUtils.strip_html(p);
                if (trimmed.length >= 20) {
                    article.blocks.add(new ArticleBlock() { kind = ArticleBlockKind.TEXT, text = trimmed });
                    added_any = true;
                }
            }
            if (!added_any) continue;

            if (article.title.length == 0 && candidate.has_member("headline")) {
                string? headline = candidate.get_string_member("headline");
                if (headline != null && headline.length > 0) article.title = stripHtmlUtils.strip_html(headline);
            }
            if (article.author == null && candidate.has_member("author")) {
                string? author_name = json_ld_author_name(candidate.get_member("author"));
                article.author = author_name != null ? stripHtmlUtils.strip_html(author_name) : null;
            }
            if (article.published == null && candidate.has_member("datePublished")) {
                article.published = candidate.get_string_member("datePublished");
            }
            if (article.hero_image_url == null && candidate.has_member("image")) {
                article.hero_image_url = json_ld_image_url(candidate.get_member("image"));
            }
            return true;
        }
        return false;
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
            case "aside": case "form": case "svg": case "button":
            case "select": case "option": case "header": case "figcaption":
                return true;
            default:
                return false;
        }
    }

    // Only these hosts get their iframe kept as a playable video embed -
    // everything else (ads, social widgets, unknown trackers) is still
    // dropped, same as the old blanket iframe skip.
    private static bool is_video_embed_host(string src) {
        string lower = src.down();
        return lower.contains("youtube.com/embed") || lower.contains("youtube-nocookie.com/embed")
            || lower.contains("player.vimeo.com") || lower.contains("dailymotion.com/embed");
    }

    // Site chrome (logos/icons) is almost always SVG, and known ad/content-
    // recommendation widgets (Taboola/Outbrain/ex.co-style "related video"
    // strips) surface as ordinary <img> tags indistinguishable from real
    // photos by tag alone - filter both out by URL rather than by class
    // name, since publishers name their wrapper classes differently.
    // Author headshots/avatars follow the same pattern - a consistent URL
    // path segment (gravatar.com, "/avatar/", "/authors/") regardless of
    // the surrounding markup's own class names.
    private static bool is_non_content_image(string url) {
        string lower = url.down();
        if (lower.has_suffix(".svg") || lower.contains(".svg?")) return true;
        string[] bad_hosts = {
            "cdn.ex.co", "taboola.com", "outbrain.com", "doubleclick.net",
            "googlesyndication.com", "content.ad", "revcontent.com", "zergnet.com",
            "gravatar.com"
        };
        foreach (var h in bad_hosts) {
            if (lower.contains(h)) return true;
        }
        string[] bad_path_hints = {
            "/avatar/", "/avatars/", "avatar-", "/authors/", "/author/",
            "headshot", "/profile-pic", "profilepic",
            "placeholder", "/blank.gif", "/blank.png", "lqip", "1x1.png", "1x1.gif"
        };
        foreach (var h in bad_path_hints) {
            if (lower.contains(h)) return true;
        }
        return false;
    }

    // Sites that lazy-load images often render two <img> tags for one
    // photo: a stub shown only without JS/CSS (hidden once real styles or
    // scripts run) plus the real, srcset-bearing image. We don't run
    // CSS/JS in the fast extraction path, so both would otherwise show up
    // as separate pictures - catch the stub by its own markup instead.
    private static bool is_lazyload_stub(Xml.Node* n) {
        string cls = (n->get_prop("class") ?? "").down();
        string aria_label = (n->get_prop("aria-label") ?? "").down();
        string[] bad = { "hide-when-no-script", "no-script-only", "lazy-placeholder", "image-placeholder", "loading-placeholder", "skeleton" };
        foreach (var b in bad) {
            if (cls.index_of(b) >= 0) return true;
        }
        return aria_label == "image unavailable";
    }

    // Many CDNs serve the same photo at several sizes/formats via
    // otherwise-different URLs (a resize width in the path, a format
    // suffix like .webp, a different folder for a "branded" crop) but
    // still embed one stable identifier for the underlying asset - a UUID,
    // or failing that a long hex hash. Comparing that instead of the raw
    // URL catches the hero image reappearing as a differently-sized body
    // image, which an exact string match misses.
    private static string? extract_asset_identifier(string url) {
        try {
            var uuid_regex = new GLib.Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}");
            GLib.MatchInfo mi;
            if (uuid_regex.match(url, 0, out mi)) return mi.fetch(0).down();

            var hash_regex = new GLib.Regex("[0-9a-fA-F]{16,}");
            if (hash_regex.match(url, 0, out mi)) return mi.fetch(0).down();
        } catch (GLib.RegexError e) {
            // fall through
        }
        return null;
    }

    private static bool is_same_image_as_hero(string? resolved, string? hero_image_url) {
        if (resolved == null || hero_image_url == null) return false;
        if (resolved == hero_image_url) return true;
        string? id1 = extract_asset_identifier(resolved);
        string? id2 = extract_asset_identifier(hero_image_url);
        return id1 != null && id2 != null && id1 == id2;
    }

    // Author photos and icons are usually declared at a small, roughly
    // square size even when the CDN URL itself gives no hint - real
    // editorial photos are essentially never this small. Catches what the
    // URL/keyword checks above miss.
    private static bool is_icon_sized(Xml.Node* n) {
        int w = int.parse(n->get_prop("width") ?? "");
        int h = int.parse(n->get_prop("height") ?? "");
        if (w > 0 && h > 0) return w <= 120 && h <= 120;
        if (w > 0) return w <= 80;
        if (h > 0) return h <= 80;
        return false;
    }

    // Author bylines and card-style "related" strips give the image itself
    // (or its alt text) an obvious role hint even when the URL doesn't.
    private static bool has_avatar_hint(Xml.Node* n) {
        string cls = (n->get_prop("class") ?? "").down();
        string id = (n->get_prop("id") ?? "").down();
        string alt = (n->get_prop("alt") ?? "").down();
        string combined = cls + " " + id + " " + alt;
        string[] bad = { "avatar", "headshot", "author-photo", "author-image", "profile-pic", "byline-photo" };
        foreach (var b in bad) {
            if (combined.index_of(b) >= 0) return true;
        }
        return false;
    }

    // Publishers often link out to a video (youtube.com/watch, youtu.be,
    // /shorts/, vimeo.com/<id>) rather than truly embedding it - recognize
    // those and return the equivalent embeddable player URL so they still
    // render as a playable card instead of a plain text link.
    private static string? to_video_embed_url(string href) {
        string lower = href.down();
        try {
            if (lower.contains("youtube.com/watch")) {
                var regex = new GLib.Regex("[?&]v=([A-Za-z0-9_-]{6,})");
                GLib.MatchInfo mi;
                if (regex.match(href, 0, out mi)) return "https://www.youtube.com/embed/" + mi.fetch(1);
            } else if (lower.contains("youtu.be/")) {
                var regex = new GLib.Regex("youtu\\.be/([A-Za-z0-9_-]{6,})");
                GLib.MatchInfo mi;
                if (regex.match(href, 0, out mi)) return "https://www.youtube.com/embed/" + mi.fetch(1);
            } else if (lower.contains("youtube.com/shorts/")) {
                var regex = new GLib.Regex("shorts/([A-Za-z0-9_-]{6,})");
                GLib.MatchInfo mi;
                if (regex.match(href, 0, out mi)) return "https://www.youtube.com/embed/" + mi.fetch(1);
            } else if (lower.contains("vimeo.com/") && !lower.contains("player.vimeo.com")) {
                var regex = new GLib.Regex("vimeo\\.com/(?:video/)?(\\d+)");
                GLib.MatchInfo mi;
                if (regex.match(href, 0, out mi)) return "https://player.vimeo.com/video/" + mi.fetch(1);
            } else if (lower.contains("dailymotion.com/video/")) {
                var regex = new GLib.Regex("dailymotion\\.com/video/([A-Za-z0-9]+)");
                GLib.MatchInfo mi;
                if (regex.match(href, 0, out mi)) return "https://www.dailymotion.com/embed/video/" + mi.fetch(1);
            }
        } catch (GLib.RegexError e) {
            return null;
        }
        return null;
    }

    // Walks a node's subtree for <a href> links pointing at a known video
    // host, converting each to its embeddable player URL.
    private static void find_video_links(Xml.Node* node, Gee.ArrayList<string> found) {
        for (Xml.Node* n = node; n != null; n = n->next) {
            if (n->type != Xml.ElementType.ELEMENT_NODE) continue;
            if (n->name.down() == "a") {
                string href = (n->get_prop("href") ?? "").strip();
                string? embed_url = href.length > 0 ? to_video_embed_url(href) : null;
                if (embed_url != null) found.add(embed_url);
            }
            if (n->children != null) find_video_links(n->children, found);
        }
    }

    // Many publishers' in-house video players (Fox News, various JW
    // Player/Brightcove-style integrations) mark their widget root with a
    // "data-video-id" attribute regardless of vendor, but never expose a
    // real playable stream or iframe URL in the static HTML - only a
    // regular watch-page link and a thumbnail. Pulls the first of each
    // found in the widget's subtree so it can still be shown as a
    // "watch on site" card rather than a dead thumbnail.
    private static void find_first_link_and_image(Xml.Node* node, ref string? href, ref string? img_src) {
        for (Xml.Node* n = node; n != null && (href == null || img_src == null); n = n->next) {
            if (n->type != Xml.ElementType.ELEMENT_NODE) continue;
            string t = n->name.down();
            if (href == null && t == "a") {
                string h = (n->get_prop("href") ?? "").strip();
                if (h.length > 0) href = h;
            }
            if (img_src == null && t == "img") {
                string? s = extract_media_src(n);
                if (s != null) img_src = s;
            }
            if (n->children != null) find_first_link_and_image(n->children, ref href, ref img_src);
        }
    }

    private static string? resolve_url(string? raw, string base_url) {
        if (raw == null) return null;
        string trimmed = raw.strip();
        if (trimmed.length == 0) return null;
        try {
            return GLib.Uri.resolve_relative(base_url, trimmed, GLib.UriFlags.NONE);
        } catch (GLib.Error e) {
            return trimmed.has_prefix("http://") || trimmed.has_prefix("https://") ? trimmed : null;
        }
    }

    // Prefers the real src, falling back to common lazy-load attributes
    // many news sites use to defer body-image/iframe loading (including
    // "data-image-loader", seen on sites that swap in a blank data: URI
    // placeholder as the literal src until JS hydrates it), then the first
    // URL in a srcset. A data: URI is never a usable result - it's always
    // a placeholder, never the real asset - so it's skipped like an empty
    // attribute rather than returned.
    private static string? extract_media_src(Xml.Node* n) {
        string[] attrs = { "src", "data-src", "data-original", "data-lazy-src", "data-image-loader" };
        foreach (var a in attrs) {
            string v = (n->get_prop(a) ?? "").strip();
            if (v.length > 0 && !v.has_prefix("data:")) return v;
        }
        string srcset = (n->get_prop("srcset") ?? "").strip();
        if (srcset.length > 0) {
            string first = srcset.split(",")[0].strip();
            string url_part = first.split(" ")[0].strip();
            if (url_part.length > 0 && !url_part.has_prefix("data:")) return url_part;
        }
        return null;
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

    // Looks only for img/video/iframe within a text-tag's own subtree (a
    // paragraph that wraps just an image rather than sitting beside one) -
    // recurses through the same container tags extract_content_nodes does,
    // but never matches p/h2/h3/h4/blockquote/li itself, so a paragraph
    // nested inside another text tag can't produce a second TEXT block.
    private static void find_nested_media(Xml.Node* node, Gee.ArrayList<ArticleBlock> blocks, string base_url, string? hero_image_url, Gee.HashSet<string> seen_video_urls) {
        for (Xml.Node* n = node; n != null; n = n->next) {
            if (n->type != Xml.ElementType.ELEMENT_NODE) continue;
            string tag = n->name.down();
            if (is_skip_tag(tag)) continue;
            if (has_boilerplate_hint(n)) continue;

            if (tag == "img") {
                if (is_icon_sized(n)) continue;
                if (has_avatar_hint(n)) continue;
                if (is_lazyload_stub(n)) continue;
                string? raw_src = extract_media_src(n);
                if (raw_src != null && is_non_content_image(raw_src)) continue;
                string? resolved = resolve_url(raw_src, base_url);
                if (resolved != null && !is_same_image_as_hero(resolved, hero_image_url)) {
                    blocks.add(new ArticleBlock() { kind = ArticleBlockKind.IMAGE, image_url = resolved });
                }
            } else if (tag == "video") {
                string? raw_src = extract_media_src(n);
                if (raw_src == null) {
                    for (Xml.Node* c = n->children; c != null; c = c->next) {
                        if (c->type == Xml.ElementType.ELEMENT_NODE && c->name.down() == "source") {
                            raw_src = extract_media_src(c);
                            if (raw_src != null) break;
                        }
                    }
                }
                string? resolved = resolve_url(raw_src, base_url);
                if (resolved != null) {
                    string? poster = resolve_url(n->get_prop("poster"), base_url);
                    blocks.add(new ArticleBlock() { kind = ArticleBlockKind.VIDEO_FILE, video_url = resolved, image_url = poster });
                }
            } else if (tag == "iframe") {
                string? resolved = resolve_url(extract_media_src(n), base_url);
                if (resolved != null && is_video_embed_host(resolved) && seen_video_urls.add(resolved)) {
                    blocks.add(new ArticleBlock() { kind = ArticleBlockKind.VIDEO_EMBED, video_url = resolved });
                }
            } else if (tag == "div" || tag == "section" || tag == "article" || tag == "ul" || tag == "ol" || tag == "span" || tag == "figure" || tag == "picture") {
                if (n->children != null) find_nested_media(n->children, blocks, base_url, hero_image_url, seen_video_urls);
            }
        }
    }

    // Walks the winning container in document order, pulling paragraph-like
    // text and inline media out (in document order, so images/video land
    // between the paragraphs they originally sat between) and recursing
    // into plain wrapper elements (div/section/etc) so content nested a
    // level or two deep is still picked up.
    private static void extract_content_nodes(Xml.Node* node, Gee.ArrayList<ArticleBlock> blocks, string base_url, string? hero_image_url, Gee.HashSet<string> seen_video_urls) {
        for (Xml.Node* n = node; n != null; n = n->next) {
            if (n->type != Xml.ElementType.ELEMENT_NODE) continue;
            string tag = n->name.down();
            if (is_skip_tag(tag)) continue;
            if (has_boilerplate_hint(n)) continue;

            // Checked ahead of the tag dispatch below since the widget
            // marker can land on any element (usually a div) - once found,
            // the whole subtree is just player chrome, so it's handled here
            // instead of falling through to the generic container recursion.
            if (n->get_prop("data-video-id") != null) {
                string? href = null;
                string? img_src = null;
                find_first_link_and_image(n->children, ref href, ref img_src);
                string? resolved_href = resolve_url(href, base_url);
                string? resolved_img = resolve_url(img_src, base_url);
                if (resolved_href != null && seen_video_urls.add(resolved_href)) {
                    blocks.add(new ArticleBlock() { kind = ArticleBlockKind.VIDEO_LINK, video_url = resolved_href, image_url = resolved_img });
                }
                continue;
            }

            if (tag == "p" || tag == "h2" || tag == "h3" || tag == "h4" || tag == "blockquote" || tag == "li") {
                string text = node_text(n);
                if (text.length >= 20 && link_density(n) < 0.6) {
                    blocks.add(new ArticleBlock() { kind = ArticleBlockKind.TEXT, text = text });
                }

                // A publisher may link out to a video instead of truly
                // embedding it - surface those as playable cards too.
                var video_links = new Gee.ArrayList<string>();
                find_video_links(n, video_links);
                foreach (var embed_url in video_links) {
                    if (seen_video_urls.add(embed_url)) {
                        blocks.add(new ArticleBlock() { kind = ArticleBlockKind.VIDEO_EMBED, video_url = embed_url });
                    }
                }

                // Some CMSs wrap a standalone image in a <p> (e.g. a
                // <figure><p><picture><img></picture></p></figure> pattern
                // seen from Tom's Guide's Readability output) rather than
                // ever placing <img>/<picture>/<video> as a direct sibling
                // of real text - node_text() above only sees the (empty)
                // text of such a paragraph. find_nested_media (unlike a
                // full extract_content_nodes recursion) only ever looks for
                // media, never text, so a <li><p>...</p></li>-style nested
                // paragraph can't get counted as a second TEXT block here.
                if (n->children != null) find_nested_media(n->children, blocks, base_url, hero_image_url, seen_video_urls);
            } else if (tag == "img") {
                // Tracking pixels, icons, and author headshots all declare
                // a small size up front - skip them rather than showing a
                // blank sliver or a tiny avatar blown up to article width.
                if (is_icon_sized(n)) continue;
                if (has_avatar_hint(n)) continue;
                if (is_lazyload_stub(n)) continue;

                string? raw_src = extract_media_src(n);
                if (raw_src != null && is_non_content_image(raw_src)) continue;

                string? resolved = resolve_url(raw_src, base_url);
                if (resolved != null && !is_same_image_as_hero(resolved, hero_image_url)) {
                    blocks.add(new ArticleBlock() { kind = ArticleBlockKind.IMAGE, image_url = resolved });
                }
            } else if (tag == "video") {
                string? raw_src = extract_media_src(n);
                if (raw_src == null) {
                    for (Xml.Node* c = n->children; c != null; c = c->next) {
                        if (c->type == Xml.ElementType.ELEMENT_NODE && c->name.down() == "source") {
                            raw_src = extract_media_src(c);
                            if (raw_src != null) break;
                        }
                    }
                }
                string? resolved = resolve_url(raw_src, base_url);
                if (resolved != null) {
                    string? poster = resolve_url(n->get_prop("poster"), base_url);
                    blocks.add(new ArticleBlock() { kind = ArticleBlockKind.VIDEO_FILE, video_url = resolved, image_url = poster });
                }
            } else if (tag == "iframe") {
                string? resolved = resolve_url(extract_media_src(n), base_url);
                if (resolved != null && is_video_embed_host(resolved) && seen_video_urls.add(resolved)) {
                    blocks.add(new ArticleBlock() { kind = ArticleBlockKind.VIDEO_EMBED, video_url = resolved });
                }
            } else if (tag == "div" || tag == "section" || tag == "article" || tag == "ul" || tag == "ol" || tag == "span" || tag == "body" || tag == "figure" || tag == "picture") {
                // "body" only ever shows up here when walking a
                // Readability-cleaned fragment (build_article_from_readability
                // passes the parsed doc's root children, i.e. <head>/<body>,
                // rather than an already-narrowed container) - harmless for
                // the normal DOM-density path, which never hands this
                // function anything above the container it already picked.
                if (n->children != null) extract_content_nodes(n->children, blocks, base_url, hero_image_url, seen_video_urls);
            }
        }
    }
}
