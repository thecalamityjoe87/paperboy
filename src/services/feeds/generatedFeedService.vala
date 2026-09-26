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

[CCode (cname = "xmlFreeDoc")]
private static extern void generated_feed_xml_free_doc(Xml.Doc* doc);

namespace Paperboy {
    public class GeneratedFeedItem : GLib.Object {
        public string title;
        public string link;
        public string? description;
        public string? pub_date;
        public string? image;
    }

    public delegate void GenerateFeedCallback(bool success, string? rss_xml, string? error_message);

    // Replaces html2rss: renders `url` in a hidden WebView (so JS-hydrated
    // sites work same as any other), extracts candidate articles with a JS
    // query against the already-rendered DOM, and writes RSS/XML directly -
    // no separate compiled binary, no subprocess I/O, no re-parsing HTML
    // text with a second parser.
    public class GeneratedFeedService : GLib.Object {
        private class PendingJob {
            public string url;
            public GenerateFeedCallback on_done;
            public PendingJob(string url, owned GenerateFeedCallback on_done) {
                this.url = url;
                this.on_done = (owned) on_done;
            }
        }

        // One WebView at a time. Queued rather than mutex-locked, since callers
        // run on the main thread and a blocking lock there deadlocks the app.
        private static bool busy = false;
        private static Gee.ArrayQueue<PendingJob>? _pending = null;
        private static Gee.ArrayQueue<PendingJob> pending() {
            if (_pending == null) _pending = new Gee.ArrayQueue<PendingJob>();
            return _pending;
        }

        private static void start_next() {
            var job = pending().poll();
            if (job == null) {
                busy = false;
                return;
            }
            run(job.url, (owned) job.on_done);
        }
        // Bump when extraction improves; older feed files get regenerated once (see FeedUpdateManager).
        public const string GENERATOR_VERSION = "Paperboy 2";

        private const uint SETTLE_DELAY_MS = 2000;
        // Generous enough to cover heavier/slower homepages plus the
        // per-candidate title-verification fetches (up to 20, in parallel)
        // that run after the page settles.
        private const uint OVERALL_TIMEOUT_MS = 35000;
        // Heavy homepages (e.g. AP News) take 11-13s to extract.
        private const uint JS_TIMEOUT_MS = 20000;

        // Mirrors html2rss's own priority order: JSON-LD article data first
        // (most sites that have it give clean title/link/image/date),
        // falling back to heading/card links scraped from the rendered DOM.
        // Runs against `document` directly, so no HTML-parsing library is
        // needed on the Vala side at all - WebKit already parsed it.
        private const string EXTRACT_JS = """
            function absUrl(u) {
                if (!u) return null;
                try { return new URL(u, document.baseURI).href; } catch (e) { return null; }
            }
            function imageFromJsonLd(img) {
                if (!img) return null;
                if (typeof img === 'string') return img;
                if (Array.isArray(img)) return imageFromJsonLd(img[0]);
                if (typeof img === 'object') return img.url || null;
                return null;
            }

            // Same non-article keyword list html2rss's is_blacklisted_url used.
            var BAD_PATH_WORDS = ['newsletter', 'subscribe', 'signup', 'quizzes', 'quiz',
                'jobs', 'careers', 'advert', 'ads', 'promo', 'privacy', 'terms', '/about',
                'login', 'signin', '/store', '/subscriptions', '/donate'];
            function isBlacklistedUrl(u) {
                var path = u.pathname.toLowerCase();
                for (var i = 0; i < BAD_PATH_WORDS.length; i++) {
                    if (path.indexOf(BAD_PATH_WORDS[i]) !== -1) return true;
                }
                var q = u.search.toLowerCase();
                return q.indexOf('newsletter') !== -1 || q.indexOf('subscribe') !== -1 || q.indexOf('signup') !== -1;
            }

            var RE_DATE_PATH = /\/\d{4}\/\d{1,2}\/\d{1,2}\//;
            var RE_ARTICLE_PATH = /\/(article|articles|story|stories|entry)\/|\/\d{4}-\d{2}-\d{2}/i;
            var SECTION_KEYWORDS = ['/news', '/section/', '/category/', '/topic/', '/topics/', '/tag/', '/tags/'];
            // Same shape html2rss's is_listing_page used: reject the
            // homepage, section/category index pages, and any short (<=2
            // segment) path that doesn't look like an article/dated URL -
            // this is what keeps nav links and section fronts out of the feed.
            function isListingPage(u, baseHost) {
                if (u.hostname !== baseHost) return false;
                var path = u.pathname;
                if (path === '/' || path === '') return true;
                var lower = path.toLowerCase();
                for (var i = 0; i < SECTION_KEYWORDS.length; i++) {
                    if (lower.indexOf(SECTION_KEYWORDS[i]) !== -1) return true;
                }
                var segs = path.split('/').filter(function(s) { return s.length > 0; });
                if (segs.length <= 2 && !RE_DATE_PATH.test(path) && !RE_ARTICLE_PATH.test(path)) return true;
                return false;
            }

            // Same error/login-page title check html2rss's is_error_page used.
            function looksLikeErrorTitle(title) {
                var t = title.toLowerCase();
                var bad = ['uh-oh', 'uh oh', 'error', '404', 'page not found', 'not found',
                    "we're sorry", 'sorry', 'login', 'log in', 'sign in', 'sign-in'];
                for (var i = 0; i < bad.length; i++) {
                    if (t.indexOf(bad[i]) !== -1) return true;
                }
                return false;
            }

            var items = [];
            var seen = {};
            var baseHost = document.location.hostname;

            // Compared without scheme - a page's JSON-LD "url" field commonly
            // says http:// while the live document was actually served over
            // https://, so an exact string match against location.href can
            // fail to recognize the current page as itself.
            function withoutScheme(link) {
                return link.replace(/^https?:\/\//, '');
            }
            var currentUrlNoScheme = withoutScheme(absUrl(document.location.href) || '');

            function addItem(title, link, description, pubDate, image) {
                title = (title || '').trim();
                link = absUrl(link);
                if (!title || !link || seen[link] || title.length < 6 || looksLikeErrorTitle(title)) return;
                // Excludes the current page itself - if we were called on a
                // single article's URL (the normal case: "follow this
                // source" from an article card), that article's own self-
                // describing JSON-LD isn't "other content from this site".
                if (withoutScheme(link) === currentUrlNoScheme) return;

                var u;
                try { u = new URL(link); } catch (e) { return; }
                if (isBlacklistedUrl(u) || isListingPage(u, baseHost)) return;

                seen[link] = true;
                items.push({ title: title, link: link, description: description || null,
                    pubDate: pubDate || null, image: image ? absUrl(image) : null });
            }

            var ldNodes = document.querySelectorAll('script[type="application/ld+json"]');
            for (var i = 0; i < ldNodes.length; i++) {
                var data;
                try { data = JSON.parse(ldNodes[i].textContent); } catch (e) { continue; }
                var nodes = Array.isArray(data) ? data : (data['@graph'] || [data]);
                nodes.forEach(function(n) {
                    if (!n || typeof n !== 'object') return;
                    var type = (n['@type'] || n.type || '').toString().toLowerCase();
                    if (type.indexOf('article') === -1 && type.indexOf('report') === -1) return;
                    var link = (n.url) || (n.mainEntityOfPage && n.mainEntityOfPage.url);
                    addItem(n.headline || n.name, link, n.description, n.datePublished, imageFromJsonLd(n.image));
                });
                if (items.length >= 20) break;
            }

            // A real listing/homepage's JSON-LD alone is usually enough; a
            // single article page's JSON-LD (after excluding itself above)
            // rarely yields more than a couple, so always supplement with
            // the link scan below unless JSON-LD already gave a solid list.
            if (items.length < 5) {
                // Ports html2rss's build_candidate_list: score every link on
                // the page rather than relying on specific tags/class names
                // (which modern SPA sites often don't use, or hide behind
                // auto-generated CSS-module class names) - a link counts as
                // a candidate worth checking if its URL matches a date/
                // article path, its text is long enough to be a headline,
                // it wraps an image, or any nearby ancestor's class hints
                // at a card/teaser layout (a plain substring check, so it
                // still matches generated names like "ArticleCard_root__x7q2f").
                // This only decides what's worth fetching below - it never
                // trusts the anchor text itself as the title, since inline
                // citation links ("...said Robert Kraft, who...") or byline
                // links can satisfy these same signals without actually
                // being headlines.
                function ancestorLooksLikeCard(el) {
                    var node = el.parentElement;
                    var depth = 0;
                    while (node && depth < 4) {
                        var cls = (node.getAttribute('class') || '').toLowerCase();
                        if (cls.indexOf('card') !== -1 || cls.indexOf('teaser') !== -1 ||
                            cls.indexOf('promo') !== -1 || cls.indexOf('headline') !== -1 ||
                            cls.indexOf('story') !== -1 || cls.indexOf('article') !== -1) {
                            return true;
                        }
                        node = node.parentElement;
                        depth++;
                    }
                    return false;
                }

                var candidates = [];
                var candidateSeen = {};
                var allLinks = document.querySelectorAll('a[href]');
                for (var k = 0; k < allLinks.length && candidates.length < 20; k++) {
                    var linkEl = allLinks[k];
                    var href = linkEl.getAttribute('href');
                    var absHref = absUrl(href);
                    if (!absHref || candidateSeen[absHref] || withoutScheme(absHref) === currentUrlNoScheme) continue;

                    var u2;
                    try { u2 = new URL(absHref); } catch (e) { continue; }
                    if (u2.hostname !== baseHost || isBlacklistedUrl(u2) || isListingPage(u2, baseHost)) continue;

                    var linkText = (linkEl.textContent || '').trim();
                    var img3 = linkEl.querySelector('img');
                    var hasImg = !!img3;
                    var urlLooksLikeArticle = RE_DATE_PATH.test(u2.pathname) || RE_ARTICLE_PATH.test(u2.pathname);

                    if (!(hasImg || ancestorLooksLikeCard(linkEl) || urlLooksLikeArticle || linkText.length > 25)) continue;

                    candidateSeen[absHref] = true;
                    var imgUrl3 = img3 ? (img3.getAttribute('src') || img3.getAttribute('data-src')) : null;
                    candidates.push({ link: absHref, fallbackTitle: linkText, fallbackImage: imgUrl3 });
                }

                function extractPageMeta(html) {
                    var doc;
                    try { doc = new DOMParser().parseFromString(html, 'text/html'); } catch (e) { return null; }
                    var titleEl = doc.querySelector('meta[property="og:title"]') || doc.querySelector('meta[name="twitter:title"]');
                    var title = titleEl ? titleEl.getAttribute('content') : (doc.querySelector('title') ? doc.querySelector('title').textContent : null);
                    var descEl = doc.querySelector('meta[property="og:description"]') || doc.querySelector('meta[name="description"]');
                    var imgEl = doc.querySelector('meta[property="og:image"]');
                    return {
                        title: title ? title.trim() : null,
                        description: descEl ? descEl.getAttribute('content') : null,
                        image: imgEl ? imgEl.getAttribute('content') : null,
                        pubDate: extractPubDate(doc)
                    };
                }

                // Sites expose the publish date in many different places, so try the common ones in order.
                function extractPubDate(doc) {
                    function metaValue(selectors) {
                        for (var i = 0; i < selectors.length; i++) {
                            var el = doc.querySelector(selectors[i]);
                            var v = el ? (el.getAttribute('content') || el.getAttribute('datetime') || '').trim() : '';
                            if (v && !isNaN(Date.parse(v))) return v;
                        }
                        return null;
                    }

                    // Breadth-first, since some sites nest it (e.g. Product.review.datePublished).
                    function jsonLdDate() {
                        var ld = doc.querySelectorAll('script[type="application/ld+json"]');
                        for (var j = 0; j < ld.length; j++) {
                            var queue;
                            try { queue = [JSON.parse(ld[j].textContent)]; } catch (e) { continue; }
                            for (var q = 0; q < queue.length && q < 500; q++) {
                                var n = queue[q];
                                if (!n || typeof n !== 'object') continue;
                                if (typeof n.datePublished === 'string' && !isNaN(Date.parse(n.datePublished))) return n.datePublished;
                                for (var key in n) queue.push(n[key]);
                            }
                        }
                        return null;
                    }

                    var v = metaValue([
                            'meta[property="article:published_time"]', 'meta[property="og:published_time"]',
                            'meta[itemprop="datePublished"]', 'meta[name="parsely-pub-date"]', 'meta[name="sailthru.date"]'])
                        || jsonLdDate()
                        || metaValue([
                            'meta[name="pubdate"]', 'meta[name="publish-date"]', 'meta[name="date"]',
                            'meta[name="dc.date"]', 'meta[name="DC.date.issued"]',
                            'time[itemprop="datePublished"]', 'time[pubdate]', 'article time[datetime]']);
                    // Normalized to ISO so the Vala side's parser always understands it.
                    return v ? new Date(v).toISOString() : null;
                }

                // Verifies each candidate against its own page's real title
                // instead of trusting the citing link's anchor text - a
                // lightweight text fetch (no JS execution needed, just the
                // static <head> metadata), run in parallel so this stays
                // fast even for ~20 candidates.
                await Promise.all(candidates.map(function(cand) {
                    return fetch(cand.link).then(function(resp) {
                        if (!resp.ok) throw new Error('bad status ' + resp.status);
                        return resp.text();
                    }).then(function(html) {
                        var meta = extractPageMeta(html);
                        var title = (meta && meta.title) ? meta.title : cand.fallbackTitle;
                        var image = (meta && meta.image) ? meta.image : cand.fallbackImage;
                        addItem(title, cand.link, meta ? meta.description : null, meta ? meta.pubDate : null, image);
                    }).catch(function(e) {
                        // Couldn't verify (network hiccup, blocked, etc.) -
                        // fall back to the anchor text rather than dropping
                        // the candidate entirely.
                        addItem(cand.fallbackTitle, cand.link, null, null, cand.fallbackImage);
                    });
                }));
            }

            return JSON.stringify(items);
        """;

        public static void generate_async(string url, owned GenerateFeedCallback on_done) {
            if (busy) {
                GLib.print("GeneratedFeedService: queued %s\n", url);
                pending().offer(new PendingJob(url, (owned) on_done));
                return;
            }
            busy = true;
            run(url, (owned) on_done);
        }

        private static void run(string url, owned GenerateFeedCallback on_done) {
            GLib.print("GeneratedFeedService: starting generation for %s\n", url);

            GLib.print("GeneratedFeedService: creating window\n");
            var win = new Gtk.Window();
            GLib.print("GeneratedFeedService: creating webview\n");
            var webview = WebViewUtils.create();
            GLib.print("GeneratedFeedService: adding webview to window\n");
            win.set_child(webview);
            GLib.print("GeneratedFeedService: window setup complete\n");

            bool done = false;
            GenerateFeedCallback? callback = (owned) on_done;
            ulong load_changed_id = 0;
            ulong load_failed_id = 0;
            // Cancelled before the webview is torn down whenever finish() runs
            // while call_async_javascript_function() may still be in flight -
            // terminating the web process out from under a pending JS call
            // (instead of letting WebKit unwind it via cancellation) is what
            // crashed on Reuters-style timeouts.
            var js_cancellable = new GLib.Cancellable();

            void finish(bool success, string? rss_xml, string? error) {
                GLib.print("GeneratedFeedService: finish() called (success=%s, error=%s)\n", success.to_string(), error ?? "none");
                if (done) return;
                done = true;
                js_cancellable.cancel();
                GLib.print("GeneratedFeedService: invoking callback\n");
                callback(success, rss_xml, error);
                callback = null;
                GLib.print("GeneratedFeedService: disconnecting signals\n");
                if (load_changed_id != 0) webview.disconnect(load_changed_id);
                if (load_failed_id != 0) webview.disconnect(load_failed_id);
                GLib.print("GeneratedFeedService: terminating webview process\n");
                WebViewUtils.terminate_process(webview);
                GLib.print("GeneratedFeedService: removing child and destroying window\n");
                win.set_child(null);
                win.destroy();
                GLib.print("GeneratedFeedService: trimming malloc\n");
                malloc_trim(0);
                GLib.Idle.add(() => { start_next(); return false; });
                GLib.print("GeneratedFeedService: finish() complete\n");
            }

            uint timeout_id = 0;
            timeout_id = Timeout.add(OVERALL_TIMEOUT_MS, () => {
                timeout_id = 0;
                finish(false, null, "Timed out waiting for page to load");
                return false;
            });

            bool started = false;
            load_changed_id = webview.load_changed.connect((ev) => {
                if (done || started || ev != WebKit.LoadEvent.COMMITTED) return;
                started = true;

                Timeout.add(SETTLE_DELAY_MS, () => {
                    if (done) return false;

                    // call_async_javascript_function() wraps `body` in an async
                    // function and awaits its returned Promise itself -
                    // evaluate_javascript() does not: it hands back the Promise
                    // object as-is, which fails with "Unsupported result type".
                    GLib.print("GeneratedFeedService: calling JS extraction for %s\n", url);
                    // The page has loaded; from here only the JS timeout applies.
                    if (timeout_id != 0) {
                        Source.remove(timeout_id);
                        timeout_id = 0;
                    }
                    uint js_timeout_id = Timeout.add(JS_TIMEOUT_MS, () => {
                        if (!done) {
                            GLib.warning("GeneratedFeedService: JS timeout for %s", url);
                            finish(false, null, "JavaScript execution timeout");
                        }
                        return false;
                    });

                    webview.call_async_javascript_function.begin(EXTRACT_JS, -1, null, null, null, js_cancellable, (obj, res) => {
                        GLib.print("GeneratedFeedService: JS extraction callback fired\n");
                        if (done) return;

                        string? json_str = null;
                        try {
                            GLib.print("GeneratedFeedService: ending JS call\n");
                            var value = webview.call_async_javascript_function.end(res);
                            GLib.print("GeneratedFeedService: converting to string\n");
                            json_str = value.to_string();
                            GLib.print("GeneratedFeedService: JSON string obtained: %s\n", json_str.substring(0, int.min(100, json_str.length)));
                        } catch (GLib.Error e) {
                            GLib.warning("GeneratedFeedService: JS evaluation failed for %s: %s", url, e.message);
                        }

                        GLib.print("GeneratedFeedService: removing timeouts\n");
                        Source.remove(js_timeout_id);

                        GLib.print("GeneratedFeedService: parsing items\n");
                        var items = parse_items(json_str);
                        GLib.print("GeneratedFeedService: extracted %d item(s) from %s\n", items.size, url);
                        if (items.size == 0) {
                            finish(false, null, "No articles found");
                            return;
                        }

                        GLib.print("GeneratedFeedService: building RSS\n");
                        var rss = build_rss(url, items);
                        GLib.print("GeneratedFeedService: RSS built, finishing\n");
                        finish(true, rss, null);
                    });
                    return false;
                });
            });

            load_failed_id = webview.load_failed.connect((ev, failing_uri, error) => {
                if (!done) {
                    if (timeout_id != 0) Source.remove(timeout_id);
                    timeout_id = 0;
                    finish(false, null, "Failed to load page: %s".printf(error != null ? error.message : "unknown"));
                }
                return true;
            });

            webview.load_uri(url);
        }

        private static Gee.ArrayList<GeneratedFeedItem> parse_items(string? json_str) {
            var items = new Gee.ArrayList<GeneratedFeedItem>();
            if (json_str == null) return items;

            try {
                var parser = new Json.Parser();
                parser.load_from_data(json_str);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.ARRAY) return items;

                foreach (var el in root.get_array().get_elements()) {
                    if (el.get_node_type() != Json.NodeType.OBJECT) continue;
                    var obj = el.get_object();
                    if (!obj.has_member("title") || !obj.has_member("link")) continue;

                    var item = new GeneratedFeedItem();
                    item.title = obj.get_string_member("title");
                    item.link = obj.get_string_member("link");
                    item.description = (obj.has_member("description") && !obj.get_null_member("description"))
                        ? obj.get_string_member("description") : null;
                    item.pub_date = (obj.has_member("pubDate") && !obj.get_null_member("pubDate"))
                        ? obj.get_string_member("pubDate") : null;
                    item.image = (obj.has_member("image") && !obj.get_null_member("image"))
                        ? obj.get_string_member("image") : null;
                    items.add(item);
                }
            } catch (GLib.Error e) {
                GLib.warning("GeneratedFeedService: failed to parse extracted items: %s", e.message);
            }
            return items;
        }

        // libxml2's new_text_child()/set_prop() escape their content and
        // attribute values automatically, so titles/descriptions/URLs
        // containing "&", quotes, etc. can't produce malformed XML.
        private static string build_rss(string source_url, Gee.ArrayList<GeneratedFeedItem> items) {
            Xml.Doc* doc = new Xml.Doc("1.0");
            Xml.Node* rss = doc->new_node(null, "rss");
            rss->set_prop("version", "2.0");
            doc->set_root_element(rss);

            Xml.Node* channel = rss->new_child(null, "channel");
            channel->new_text_child(null, "title", "Feed for %s".printf(source_url));
            channel->new_text_child(null, "link", source_url);
            channel->new_text_child(null, "description", "Generated by Paperboy");
            channel->new_text_child(null, "generator", GENERATOR_VERSION);

            foreach (var it in items) {
                Xml.Node* item = channel->new_child(null, "item");
                item->new_text_child(null, "title", it.title);
                item->new_text_child(null, "link", it.link);
                if (it.description != null) item->new_text_child(null, "description", it.description);
                if (it.pub_date != null) item->new_text_child(null, "pubDate", it.pub_date);
                if (it.image != null) {
                    Xml.Node* enc = item->new_child(null, "enclosure");
                    enc->set_prop("url", it.image);
                }
            }

            string mem;
            int len;
            doc->dump_memory_format(out mem, out len, true);
            generated_feed_xml_free_doc(doc);
            return mem;
        }
    }
}
