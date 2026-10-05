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

public class PaperboyFetcher : BaseFetcher {
    private const string BASE_URL = "https://paperboybackend.onrender.com";

    public PaperboyFetcher(FetchSink sink) {
        base(sink);
    }

    public override void fetch(string category, string search_query, Soup.Session session) {
        if (category == "frontpage") {
            fetch_paperboy_frontpage(search_query, session);
        } else if (category == "topten") {
            fetch_paperboy_topten(search_query, session);
        } else if (category == "sports") {
            fetch_paperboy_sports(search_query, session);
        } else {
            fetch_paperboy_category(category, search_query);
        }
    }

    // Front page is cached under frontpage_cache_key() by this fetcher itself.
    protected override bool caches_for_search { get { return false; } }

    // Outside US English the backend sends at most 10 Front Page articles
    // (none on a country's first request), so Google News fills each row:
    // up to this many per row, enough for its visible cards plus its arrow.
    private const int PAD_PER_ROW = 8;
    // Google News sections the Front Page pads from, after NATION, and the
    // Front Page row each fills (see LayoutManager.FRONTPAGE_SECTION_CATEGORIES).
    private const string[] PAD_TOPICS = { "WORLD", "BUSINESS", "TECHNOLOGY", "SCIENCE", "HEALTH", "SPORTS", "ENTERTAINMENT" };
    private const string[] PAD_ROWS = { "world", "business", "technology", "science", "health", "sports", "entertainment" };
    // Trending candidates sent before ArticleManager drops hero duplicates
    // and caps it, matching the Front Page backfill below.
    private const int TOPTEN_CANDIDATES = 20;

    // On-disk Front Page cache key, per edition so switching country doesn't
    // show the previous one's articles. US English keeps the original key so
    // existing caches still load.
    private static string frontpage_cache_key() {
        if (GoogleNewsUtils.is_us_english()) return Paperboy.RssArticleCache.FRONTPAGE_KEY;
        return Paperboy.RssArticleCache.FRONTPAGE_KEY + ":" + GoogleNewsUtils.ceid();
    }

    public delegate void PadDone();

    // Outside US English, fills the Front Page's rows from Google News: the
    // national section first, so the hero carousel leads with the country's
    // top stories when the backend sent none, then the other sections at
    // once. Calls `then` when all are in.
    private void pad_frontpage_from_google_news(Gee.HashSet<string> seen_urls, Gee.HashSet<string> seen_titles,
                                                string current_search_query, Soup.Session session, owned PadDone then) {
        if (GoogleNewsUtils.is_us_english()) {
            then();
            return;
        }
        pad_from_google_news(GoogleNewsUtils.national_url(), "frontpage", "nation", PAD_PER_ROW,
                             seen_urls, seen_titles, current_search_query, session, () => {
            int pending = PAD_TOPICS.length;
            for (int i = 0; i < PAD_TOPICS.length; i++) {
                pad_from_google_news(GoogleNewsUtils.topic_url(PAD_TOPICS[i]), "frontpage", PAD_ROWS[i], PAD_PER_ROW,
                                     seen_urls, seen_titles, current_search_query, session, () => {
                    if (--pending == 0) then();
                });
            }
        });
    }

    // Outside US English, adds up to `max` articles from a Google News feed
    // that aren't already shown (by URL or title), then calls `then` once -
    // also if the feed fails. `row` tags them with a Front Page row category
    // ("world"), as the backend's articles are; null leaves them untagged.
    // Their missing images are fetched once they're on screen.
    private void pad_from_google_news(string feed_url, string category_id, string? row, int max,
                                      Gee.HashSet<string> seen_urls, Gee.HashSet<string> seen_titles,
                                      string current_search_query, Soup.Session session, owned PadDone then) {
        if (GoogleNewsUtils.is_us_english() || max <= 0) {
            then();
            return;
        }
        int added = 0;
        bool finished = false;
        uint timeout_id = 0;
        PadDone finish = () => {
            if (finished) return;
            finished = true;
            if (timeout_id != 0) GLib.Source.remove(timeout_id);
            timeout_id = 0;
            then();
        };
        // RssFeedProcessor signals no completion, but on success it sets the
        // label "<category> — <source>", clears, then queues every item in
        // order on the main loop - so an idle queued from the clear runs after
        // the last item. Failures set any other label - translated, so check
        // for the success form rather than the word "Error". The timeout
        // covers anything else.
        var pad_sink = new FetchSink(null,
            (item) => {
                if (finished || added >= max) return;
                string norm = UrlUtils.normalize_article_url(item.url);
                string norm_title = item.title.down().strip();
                if ((norm.length > 0 && seen_urls.contains(norm)) || (norm_title.length > 0 && seen_titles.contains(norm_title))) return;
                if (norm.length > 0) seen_urls.add(norm);
                if (norm_title.length > 0) seen_titles.add(norm_title);
                string? source = item.source_name;
                if (row != null) {
                    var label = SourceLabel.parse(source);
                    source = SourceLabel.encode(label.name, label.logo_url, row);
                }
                add_item(item.title, item.url, item.thumbnail_url, category_id, source, item.published);
                added++;
            },
            (label) => { if (!label.has_suffix(" — " + GoogleNewsUtils.AGGREGATOR_NAME)) finish(); },
            () => { GLib.Idle.add(() => { finish(); return false; }); });
        timeout_id = GLib.Timeout.add_seconds(20, () => {
            timeout_id = 0;
            finish();
            return false;
        });
        RssFeedProcessor.fetch_rss_url(feed_url, GoogleNewsUtils.AGGREGATOR_NAME, _("Front Page"), category_id,
                                       current_search_query, session, pad_sink);
    }

    public override string get_source_name() {
        return "Paperboy";
    }

    private void fetch_paperboy_frontpage(string current_search_query, Soup.Session session) {
        // First, load cached articles to show immediately (up to 120 articles from last 48 hours)
        var frontpage_cache = Paperboy.RssArticleCache.get_instance();
        string cache_key = frontpage_cache_key();
        var cached_articles = frontpage_cache.get_cached_articles(cache_key, Paperboy.RssArticleCache.MAX_FRONTPAGE_ARTICLES);

        Idle.add(() => {
            if (current_search_query.length > 0) {
                set_label(@"Search Results: \"$(current_search_query)\" in The Frontpage — Paperboy");
            } else {
                set_label("The Frontpage — Paperboy");
            }
            clear_items();

            // Add cached articles first for instant display
            foreach (var article in cached_articles) {
                if (article.url == null || article.title == null) continue;

                // Apply search filter if needed
                if (current_search_query.length > 0) {
                    string query_lower = current_search_query.down();
                    string title_lower = article.title.down();
                    string url_lower = article.url.down();
                    if (!title_lower.contains(query_lower) && !url_lower.contains(query_lower)) continue;
                }

                // Rebuild the source label from cached metadata
                string cached_name = (article.source_name != null && article.source_name.length > 0) ? article.source_name : "Paperboy";
                string cached_display_source = SourceLabel.encode(cached_name, article.logo_url, article.category_id ?? "news");
                add_item(article.title, article.url, article.thumbnail_url, "frontpage", cached_display_source, article.published_date);
            }
            return false;
        });

        // Then fetch fresh articles from API to update cache
        var client = Paperboy.HttpClientUtils.get_default();
        string url = BASE_URL + "/news/frontpage" + GoogleNewsUtils.backend_region_query();

        // The backend's articles, so Google News padding skips them
        var seen_urls = new Gee.HashSet<string>();
        var seen_titles = new Gee.HashSet<string>();
        // Outside US English, fill the rows from Google News, then finish
        void finish() {
            pad_frontpage_from_google_news(seen_urls, seen_titles, current_search_query, session, () => { done(); });
        }

        client.fetch_json_with(url, cancellable, (response, parser, root) => {
            if (!response.is_success() || root == null) {
                warning("Paperboy API HTTP error: %u", response.status_code);
                if (!GoogleNewsUtils.is_us_english()) {
                    finish();
                    return;
                }
                // Don't show error if we have cached articles
                if (cached_articles.size == 0) {
                    set_label("Paperboy: Error loading frontpage");
                }
                done();
                return;
            }

            try {
                Json.Array articles = null;
                if (root.get_node_type() == Json.NodeType.ARRAY) {
                    articles = root.get_array();
                } else {
                    var obj = root.get_object();
                    if (obj.has_member("articles")) {
                        articles = obj.get_array_member("articles");
                    } else if (obj.has_member("data")) {
                        var data = obj.get_object_member("data");
                        if (data.has_member("articles"))
                            articles = data.get_array_member("articles");
                    }
                }

                if (articles == null) {
                    finish();
                    return;
                }


                record_reading_times(articles);

                Idle.add(() => {
                    // Don't clear items or update label - we already showed cached articles
                    // Just add fresh articles that aren't in cache
                    uint len = articles.get_length();
                    for (uint i = 0; i < len; i++) {
                        var art = articles.get_element(i).get_object();
                        // Note: previously this skipped all further processing for
                        // URLs already shown from cache (`if (shown_urls.contains(...))
                        // continue;`). That silently prevented ever refreshing the
                        // on-disk cache row (so a dateless cached article stayed
                        // dateless forever) and, worse, prevented the duplicate
                        // add_item() call below that ArticleManager relies on to
                        // backfill an already-rendered card's time label in place.
                        // Both cache_article() and add_item() below now always run;
                        // add_item()'s own URL dedup already prevents a second visible
                        // card from being created.

                        var a = parse_frontpage_article(art);

                        if (current_search_query.length > 0 && !matches_search(a, current_search_query)) continue;

                        // Cache frontpage article for offline access and better performance
                        // Store source_name (without logo), logo_url separately, and category_id
                        frontpage_cache.cache_article(a.url, a.title, a.thumbnail, a.published, cache_key, a.source_name, a.logo_url, a.category_id);

                        // Always call add_item, even for articles already shown from
                        // cache: ArticleManager.add_item() dedupes by URL itself and
                        // won't create a second card, but a duplicate call carrying a
                        // published date is exactly what lets it backfill an
                        // already-rendered (cache-sourced, dateless) card's time label
                        // in place. Skipping this call for already_shown articles was
                        // silently defeating that backfill.
                        add_item(a.title, a.url, a.thumbnail, "frontpage", SourceLabel.encode(a.source_name, a.logo_url, a.category_id), a.published);
                        string norm = UrlUtils.normalize_article_url(a.url);
                        if (norm.length > 0) seen_urls.add(norm);
                        if (a.title.length > 0) seen_titles.add(a.title.down().strip());
                    }
                    finish();
                    return false;
                });
            } catch (GLib.Error e) {
                warning("Paperboy frontpage fetch error: %s", e.message);
                finish();
            }
        });
    }

    // One frontpage API article, normalized. category_id is the API's own
    // category ("world", "football", ...), or "frontpage" if it sent none.
    private class FrontpageArticle {
        public string title;
        public string url;
        public string? thumbnail;
        public string? published;
        public string source_name;
        public string? logo_url;
        public string display_source; // SourceLabel-encoded name and logo, for card badges
        public string category_id;
    }

    private FrontpageArticle parse_frontpage_article(Json.Object art) {
        string title = json_get_string_safe(art, "title") != null ? json_get_string_safe(art, "title") : (json_get_string_safe(art, "headline") != null ? json_get_string_safe(art, "headline") : "No title");
        string article_url = json_get_string_safe(art, "url") != null ? json_get_string_safe(art, "url") : (json_get_string_safe(art, "link") != null ? json_get_string_safe(art, "link") : "");

        string? thumbnail = null;
        if (json_get_string_safe(art, "thumbnail") != null) thumbnail = json_get_string_safe(art, "thumbnail");
        else if (json_get_string_safe(art, "image") != null) thumbnail = json_get_string_safe(art, "image");
        else if (json_get_string_safe(art, "image_url") != null) thumbnail = json_get_string_safe(art, "image_url");

        string? published = json_get_string_safe(art, "publishedAt");

        string source_name = "Paperboy API";
        string? logo_url = null;

        if (art.has_member("source")) {
            var src_node = art.get_member("source");
            if (src_node != null && src_node.get_node_type() == Json.NodeType.OBJECT) {
                var src_obj = src_node.get_object();
                string? n = json_get_string_safe(src_obj, "name");
                if (n == null) n = json_get_string_safe(src_obj, "title");
                if (n != null) source_name = n;

                if (json_get_string_safe(src_obj, "logo_url") != null) logo_url = json_get_string_safe(src_obj, "logo_url");
                else if (json_get_string_safe(src_obj, "logo") != null) logo_url = json_get_string_safe(src_obj, "logo");
                else if (json_get_string_safe(src_obj, "favicon") != null) logo_url = json_get_string_safe(src_obj, "favicon");

                string? provurl = json_get_string_safe(src_obj, "url");
                if (provurl != null) {
                    if (source_name == null || source_name.length == 0) {
                        string inferred = infer_display_name_from_url(provurl);
                        if (inferred.length > 0) source_name = inferred;
                    }
                }
            } else {
                string? s = json_get_string_safe(art, "source");
                if (s != null) source_name = s;
            }
        } else {
            if (json_get_string_safe(art, "source") != null) source_name = json_get_string_safe(art, "source");
            else if (json_get_string_safe(art, "provider") != null) source_name = json_get_string_safe(art, "provider");
        }

        if (source_name == null || source_name.length == 0 || source_name == "Paperboy API") {
            string inferred = infer_display_name_from_url(article_url);
            if (inferred != null && inferred.length > 0) source_name = inferred;
        }

        if (logo_url == null) {
            if (json_get_string_safe(art, "logo") != null) logo_url = json_get_string_safe(art, "logo");
            else if (json_get_string_safe(art, "favicon") != null) logo_url = json_get_string_safe(art, "favicon");
            else if (json_get_string_safe(art, "logo_url") != null) logo_url = json_get_string_safe(art, "logo_url");
            else if (json_get_string_safe(art, "site_icon") != null) logo_url = json_get_string_safe(art, "site_icon");
        }

        if (logo_url != null) {
            logo_url = logo_url.strip();
            if (logo_url.has_prefix("//")) {
                logo_url = "https:" + logo_url;
            }
        }

        string display_source = SourceLabel.encode(source_name, logo_url);

        string category_id = "frontpage";
        string? cat_raw = null;

        string? extract_from_node(Json.Node? node) {
            if (node == null) return null;
            try {
                if (node.get_node_type() == Json.NodeType.VALUE) {
                    try { return node.get_string(); } catch (GLib.Error e) { return null; }
                } else if (node.get_node_type() == Json.NodeType.OBJECT) {
                    var o = node.get_object();
                    string? v = json_get_string_safe(o, "id");
                    if (v != null) return v;
                    v = json_get_string_safe(o, "slug");
                    if (v != null) return v;
                    v = json_get_string_safe(o, "name");
                    if (v != null) return v;
                    v = json_get_string_safe(o, "title");
                    if (v != null) return v;
                }
            } catch (GLib.Error e) { }
            return null;
        }

        if (art.has_member("category")) cat_raw = extract_from_node(art.get_member("category"));
        if (cat_raw == null && art.has_member("section")) cat_raw = extract_from_node(art.get_member("section"));
        if (cat_raw == null && art.has_member("type")) cat_raw = extract_from_node(art.get_member("type"));
        if (cat_raw == null && art.has_member("category_id")) cat_raw = extract_from_node(art.get_member("category_id"));

        if (cat_raw == null && art.has_member("tags")) {
            var tags_node = art.get_member("tags");
            if (tags_node != null && tags_node.get_node_type() == Json.NodeType.ARRAY) {
                var tags_arr = tags_node.get_array();
                if (tags_arr.get_length() > 0) {
                    var first = tags_arr.get_element(0);
                    cat_raw = extract_from_node(first);
                }
            }
        }

        if (cat_raw != null && cat_raw.length > 0) {
            string s_raw = (string) cat_raw;
            category_id = s_raw.down().replace(" ", "_").replace("-", "_").strip();
        }

        var a = new FrontpageArticle();
        a.title = title;
        a.url = article_url;
        a.thumbnail = thumbnail;
        a.published = published;
        a.source_name = source_name;
        a.logo_url = logo_url;
        a.display_source = display_source;
        a.category_id = category_id;
        return a;
    }

    private static bool matches_search(FrontpageArticle a, string query) {
        string query_lower = query.down();
        return a.title.down().contains(query_lower) || a.url.down().contains(query_lower);
    }

    // A regular category view's share of the frontpage: the articles in the
    // Front Page row whose "..." button leads to `view_category`. Layered
    // onto the built-in sources' fetches for that view, so it never clears
    // the view or sets its label - a failure here just means fewer articles.
    private void fetch_paperboy_category(string view_category, string current_search_query) {
        // Cached frontpage articles first, for instant display
        var cached_articles = Paperboy.RssArticleCache.get_instance().get_cached_articles(
            frontpage_cache_key(), Paperboy.RssArticleCache.MAX_FRONTPAGE_ARTICLES);
        Idle.add(() => {
            foreach (var article in cached_articles) {
                if (article.url == null || article.title == null) continue;
                if (Managers.LayoutManager.sidebar_category_for(article.category_id ?? "") != view_category) continue;
                if (current_search_query.length > 0) {
                    string query_lower = current_search_query.down();
                    if (!article.title.down().contains(query_lower) && !article.url.down().contains(query_lower)) continue;
                }
                // A logo only means something next to a name
                string? cached_logo = (article.source_name != null && article.source_name.length > 0) ? article.logo_url : null;
                string display_source = SourceLabel.encode(article.source_name, cached_logo);
                add_item(article.title, article.url, article.thumbnail_url, view_category, display_source, article.published_date);
            }
            return false;
        });

        string url = BASE_URL + "/news/frontpage" + GoogleNewsUtils.backend_region_query();
        Paperboy.HttpClientUtils.get_default().fetch_json_with(url, cancellable, (response, parser, root) => {
            Json.Array? articles = null;
            if (response.is_success() && root != null) {
                if (root.get_node_type() == Json.NodeType.ARRAY) {
                    articles = root.get_array();
                } else if (root.get_node_type() == Json.NodeType.OBJECT) {
                    var obj = root.get_object();
                    if (obj.has_member("articles")) {
                        articles = obj.get_array_member("articles");
                    } else if (obj.has_member("data")) {
                        var data = obj.get_object_member("data");
                        if (data.has_member("articles")) articles = data.get_array_member("articles");
                    }
                }
            }
            if (articles == null) {
                done();
                return;
            }

            record_reading_times(articles);
            Idle.add(() => {
                uint len = articles.get_length();
                for (uint i = 0; i < len; i++) {
                    var a = parse_frontpage_article(articles.get_element(i).get_object());
                    if (Managers.LayoutManager.sidebar_category_for(a.category_id) != view_category) continue;
                    if (current_search_query.length > 0 && !matches_search(a, current_search_query)) continue;
                    add_item(a.title, a.url, a.thumbnail, view_category, a.display_source, a.published);
                }
                done();
                return false;
            });
        });
    }

    private void fetch_paperboy_topten(string current_search_query, Soup.Session session) {
        var client = Paperboy.HttpClientUtils.get_default();
        string region = GoogleNewsUtils.backend_region_query();
        string url = BASE_URL + "/news/headlines" + region;

        client.fetch_json_with(url, cancellable, (response, parser, root) => {
            bool failed = !response.is_success() || root == null;
            if (failed) {
                warning("Paperboy API HTTP error: %u", response.status_code);
                if (GoogleNewsUtils.is_us_english()) {
                    set_label("Paperboy: Error loading Top Ten");
                    done();
                    return;
                }
            }

            try {
                Json.Array articles = null;
                if (failed) {
                    // Handled below, like an empty response
                } else if (root.get_node_type() == Json.NodeType.ARRAY) {
                    articles = root.get_array();
                } else {
                    var obj = root.get_object();
                    if (obj.has_member("articles")) {
                        articles = obj.get_array_member("articles");
                    } else if (obj.has_member("data")) {
                        var data = obj.get_object_member("data");
                        if (data.has_member("articles"))
                            articles = data.get_array_member("articles");
                    }
                }

                if (articles == null) {
                    if (GoogleNewsUtils.is_us_english()) {
                        done();
                        return;
                    }
                    // Outside US English, carry on with no headlines: the
                    // backfill and Google News padding below still fill Trending.
                    articles = new Json.Array();
                }


                record_reading_times(articles);

                Idle.add(() => {
                    if (current_search_query.length > 0) {
                        set_label(@"Search Results: \"$(current_search_query)\" in Top Ten — Paperboy");
                    } else {
                        set_label("Top Ten — Paperboy");
                    }
                    clear_items();
                    uint len = articles.get_length();

                    var seen_urls = new Gee.HashSet<string>();
                    var seen_titles = new Gee.HashSet<string>();
                    int added_count = 0;

                    // ArticleManager drops these (and URL duplicates) after the
                    // fact, so skip them here too - otherwise they count toward
                    // the 10 and leave empty slots in the Trending grid.
                    var enabled_sources = NewsPreferences.get_instance().preferred_sources;

                    for (uint i = 0; i < len && added_count < 10; i++) {
                        var art = articles.get_element(i).get_object();
                        string title = json_get_string_safe(art, "title") != null ? json_get_string_safe(art, "title") : (json_get_string_safe(art, "headline") != null ? json_get_string_safe(art, "headline") : "No title");
                        string article_url = json_get_string_safe(art, "url") != null ? json_get_string_safe(art, "url") : (json_get_string_safe(art, "link") != null ? json_get_string_safe(art, "link") : "");
                        string? thumbnail = null;
                        if (json_get_string_safe(art, "thumbnail") != null) thumbnail = json_get_string_safe(art, "thumbnail");
                        else if (json_get_string_safe(art, "image") != null) thumbnail = json_get_string_safe(art, "image");
                        else if (json_get_string_safe(art, "image_url") != null) thumbnail = json_get_string_safe(art, "image_url");

                        string? published = json_get_string_safe(art, "publishedAt");

                        string source_name = "Paperboy API";
                        string? logo_url = null;
                        string provider_key = "";
                        string? provider_url = null;

                        if (art.has_member("source")) {
                            var src_node = art.get_member("source");
                            if (src_node != null && src_node.get_node_type() == Json.NodeType.OBJECT) {
                                var src_obj = src_node.get_object();
                                string? n = json_get_string_safe(src_obj, "name");
                                if (n == null) n = json_get_string_safe(src_obj, "title");
                                if (n != null) source_name = n;
                                string? sid = json_get_string_safe(src_obj, "id");
                                if (sid != null && sid.length > 0) provider_key = sid;
                                else if (n != null && n.length > 0) provider_key = n;

                                if (json_get_string_safe(src_obj, "logo_url") != null) logo_url = json_get_string_safe(src_obj, "logo_url");
                                else if (json_get_string_safe(src_obj, "logo") != null) logo_url = json_get_string_safe(src_obj, "logo");
                                else if (json_get_string_safe(src_obj, "favicon") != null) logo_url = json_get_string_safe(src_obj, "favicon");

                                string? provurl = json_get_string_safe(src_obj, "url");
                                if (provurl != null) {
                                    provider_url = provurl;
                                    if (source_name == null || source_name.length == 0) {
                                        string inferred = infer_display_name_from_url(provurl);
                                        if (inferred.length > 0) source_name = inferred;
                                    }
                                }
                            } else {
                                string? s = json_get_string_safe(art, "source");
                                if (s != null) source_name = s;
                                if (source_name != null) provider_key = source_name;
                            }
                        } else {
                            if (json_get_string_safe(art, "source") != null) source_name = json_get_string_safe(art, "source");
                            else if (json_get_string_safe(art, "provider") != null) source_name = json_get_string_safe(art, "provider");
                            if (source_name != null) provider_key = source_name;
                        }

                        if (source_name == null || source_name.length == 0 || source_name == "Paperboy API") {
                            string inferred = infer_display_name_from_url(article_url);
                            if (inferred != null && inferred.length > 0) source_name = inferred;
                        }

                        if (logo_url == null) {
                            if (json_get_string_safe(art, "logo") != null) logo_url = json_get_string_safe(art, "logo");
                            else if (json_get_string_safe(art, "favicon") != null) logo_url = json_get_string_safe(art, "favicon");
                            else if (json_get_string_safe(art, "logo_url") != null) logo_url = json_get_string_safe(art, "logo_url");
                            else if (json_get_string_safe(art, "site_icon") != null) logo_url = json_get_string_safe(art, "site_icon");
                        }

                        if (logo_url != null) {
                            logo_url = logo_url.strip();
                            if (logo_url.has_prefix("//")) {
                                logo_url = "https:" + logo_url;
                            }
                        }

                        string category_id = "topten";
                        string? cat_raw = null;

                        string? extract_from_node(Json.Node? node) {
                            if (node == null) return null;
                            try {
                                if (node.get_node_type() == Json.NodeType.VALUE) {
                                    try { return node.get_string(); } catch (GLib.Error e) { return null; }
                                } else if (node.get_node_type() == Json.NodeType.OBJECT) {
                                    var o = node.get_object();
                                    string? v = json_get_string_safe(o, "id");
                                    if (v != null) return v;
                                    v = json_get_string_safe(o, "slug");
                                    if (v != null) return v;
                                    v = json_get_string_safe(o, "name");
                                    if (v != null) return v;
                                    v = json_get_string_safe(o, "title");
                                    if (v != null) return v;
                                }
                            } catch (GLib.Error e) { }
                            return null;
                        }

                        if (art.has_member("category")) cat_raw = extract_from_node(art.get_member("category"));
                        if (cat_raw == null && art.has_member("section")) cat_raw = extract_from_node(art.get_member("section"));
                        if (cat_raw == null && art.has_member("type")) cat_raw = extract_from_node(art.get_member("type"));
                        if (cat_raw == null && art.has_member("category_id")) cat_raw = extract_from_node(art.get_member("category_id"));

                        if (cat_raw == null && art.has_member("tags")) {
                            var tags_node = art.get_member("tags");
                            if (tags_node != null && tags_node.get_node_type() == Json.NodeType.ARRAY) {
                                var tags_arr = tags_node.get_array();
                                if (tags_arr.get_length() > 0) {
                                    var first = tags_arr.get_element(0);
                                    cat_raw = extract_from_node(first);
                                }
                            }
                        }

                        if (cat_raw != null && cat_raw.length > 0) {
                            string s_raw = (string) cat_raw;
                            category_id = s_raw.down().replace(" ", "_").replace("-", "_").strip();
                        }

                        string display_source = SourceLabel.encode(source_name, logo_url, category_id);

                        // Filter by search query if provided
                        if (current_search_query.length > 0) {
                            if (!title.contains(current_search_query) && !article_url.contains(current_search_query)) {
                                continue;
                            }
                        }

                        if (SourceManager.is_from_disabled_builtin(article_url, enabled_sources)) continue;

                        string norm = UrlUtils.normalize_article_url(article_url);
                        string norm_title = title != null ? title.down().strip() : "";
                        if ((norm.length > 0 && seen_urls.contains(norm)) || (norm_title.length > 0 && seen_titles.contains(norm_title))) {
                            continue;
                        }
                        if (norm.length > 0) seen_urls.add(norm);
                        if (norm_title.length > 0) seen_titles.add(norm_title);
                        add_item(title, article_url, thumbnail, "topten", display_source, published);
                        added_count++;
                    }

                    // Always send Front Page backfill after the headlines: ArticleManager
                    // drops any that duplicate the hero carousel and caps Trending,
                    // so these only fill slots the headlines couldn't.
                    // Async: this runs on the main thread, and a sync fetch froze the UI while the backend cold-starts.
                    client.fetch_json_with(BASE_URL + "/news/frontpage" + region, cancellable, (fp_response, p2, r2) => {
                        if (fp_response.is_success() && r2 != null) {
                            Json.Array front_articles = null;
                            if (r2.get_node_type() == Json.NodeType.ARRAY) {
                                front_articles = r2.get_array();
                            } else {
                                var o2 = r2.get_object();
                                if (o2.has_member("articles")) front_articles = o2.get_array_member("articles");
                                else if (o2.has_member("data")) {
                                    var d2 = o2.get_object_member("data");
                                    if (d2.has_member("articles")) front_articles = d2.get_array_member("articles");
                                }
                            }
                            if (front_articles != null) {
                                record_reading_times(front_articles);
                                uint total_candidates = front_articles.get_length();
                                uint max_candidates = 20;
                                uint len2 = total_candidates;
                                if (len2 > max_candidates) len2 = max_candidates;
                                for (uint j = 0; j < len2; j++) {
                                    var a = front_articles.get_element(j).get_object();
                                    string t = json_get_string_safe(a, "title") != null ? json_get_string_safe(a, "title") : (json_get_string_safe(a, "headline") != null ? json_get_string_safe(a, "headline") : "No title");
                                    string u = json_get_string_safe(a, "url") != null ? json_get_string_safe(a, "url") : (json_get_string_safe(a, "link") != null ? json_get_string_safe(a, "link") : "");
                                    string? thumb = null;
                                    if (json_get_string_safe(a, "thumbnail") != null) thumb = json_get_string_safe(a, "thumbnail");
                                    else if (json_get_string_safe(a, "image") != null) thumb = json_get_string_safe(a, "image");
                                    else if (json_get_string_safe(a, "image_url") != null) thumb = json_get_string_safe(a, "image_url");
                                    string? pub = json_get_string_safe(a, "publishedAt");

                                    // Filter by search query if provided
                                    if (current_search_query.length > 0) {
                                        if (!t.contains(current_search_query) && !u.contains(current_search_query)) {
                                            continue;
                                        }
                                    }

                                    if (SourceManager.is_from_disabled_builtin(u, enabled_sources)) continue;

                                    string n = UrlUtils.normalize_article_url(u);
                                    string nt = t != null ? t.down().strip() : "";
                                    if ((n.length > 0 && seen_urls.contains(n)) || (nt.length > 0 && seen_titles.contains(nt))) continue;
                                    if (n.length > 0) seen_urls.add(n);
                                    if (nt.length > 0) seen_titles.add(nt);

                                    string ds = "Paperboy API";
                                    string? logo = null;
                                    if (a.has_member("source")) {
                                        var s_node = a.get_member("source");
                                        if (s_node != null && s_node.get_node_type() == Json.NodeType.OBJECT) {
                                            var s_obj = s_node.get_object();
                                            string? nname = json_get_string_safe(s_obj, "name");
                                            if (nname == null) nname = json_get_string_safe(s_obj, "title");
                                            if (nname != null) ds = nname;
                                            if (json_get_string_safe(s_obj, "logo_url") != null) logo = json_get_string_safe(s_obj, "logo_url");
                                            else if (json_get_string_safe(s_obj, "logo") != null) logo = json_get_string_safe(s_obj, "logo");
                                            else if (json_get_string_safe(s_obj, "favicon") != null) logo = json_get_string_safe(s_obj, "favicon");
                                        } else {
                                            string? s2 = json_get_string_safe(a, "source");
                                            if (s2 != null) ds = s2;
                                        }
                                    }
                                    add_item(t, u, thumb, "topten", SourceLabel.encode(ds, logo), pub);
                                    added_count++;
                                }
                            }
                        }
                        // Outside US English, top Trending up from Google News' top
                        // stories - not the national feed the Front Page pads from,
                        // so the two don't repeat each other.
                        pad_from_google_news(GoogleNewsUtils.top_stories_url(), "topten", null, TOPTEN_CANDIDATES - added_count,
                                             seen_urls, seen_titles, current_search_query, session, () => { done(); });
                    });
                    return false;
                });
            } catch (GLib.Error e) {
                warning("Paperboy Top Ten fetch error: %s", e.message);
                done();
            }
        });
    }

    // Persistent Sports supplement: unlike frontpage/topten this does not
    // clear existing items or set the header label - it is called
    // additively alongside the normal per-source Sports fetch (see
    // FetchNewsController.fetch_news_impl) so it fills gaps for built-in
    // sources that have no dedicated sports desk, without disturbing
    // whatever those sources already contributed. Not user-configurable:
    // there is intentionally no source toggle for it in preferences.
    private void fetch_paperboy_sports(string current_search_query, Soup.Session session) {
        var client = Paperboy.HttpClientUtils.get_default();
        // Backend defaults to only 10 results with no max_results param;
        // request a generously high value so we always get everything it has.
        string url = BASE_URL + "/news/sports?max_results=100";

        client.fetch_json_with(url, cancellable, (response, parser, root) => {
            if (!response.is_success() || root == null) {
                warning("Paperboy API HTTP error: %u", response.status_code);
                return;
            }

            try {
                Json.Array articles = null;
                if (root.get_node_type() == Json.NodeType.ARRAY) {
                    articles = root.get_array();
                } else {
                    var obj = root.get_object();
                    if (obj.has_member("articles")) {
                        articles = obj.get_array_member("articles");
                    } else if (obj.has_member("data")) {
                        var data = obj.get_object_member("data");
                        if (data.has_member("articles"))
                            articles = data.get_array_member("articles");
                    }
                }

                if (articles == null) {
                    return;
                }

                record_reading_times(articles);

                Idle.add(() => {
                    uint len = articles.get_length();
                    for (uint i = 0; i < len; i++) {
                        var art = articles.get_element(i).get_object();
                        string title = json_get_string_safe(art, "title") != null ? json_get_string_safe(art, "title") : (json_get_string_safe(art, "headline") != null ? json_get_string_safe(art, "headline") : "No title");
                        string article_url = json_get_string_safe(art, "url") != null ? json_get_string_safe(art, "url") : (json_get_string_safe(art, "link") != null ? json_get_string_safe(art, "link") : "");
                        if (article_url.length == 0) continue;

                        string? thumbnail = null;
                        if (json_get_string_safe(art, "thumbnail") != null) thumbnail = json_get_string_safe(art, "thumbnail");
                        else if (json_get_string_safe(art, "image") != null) thumbnail = json_get_string_safe(art, "image");
                        else if (json_get_string_safe(art, "image_url") != null) thumbnail = json_get_string_safe(art, "image_url");

                        string? published = json_get_string_safe(art, "publishedAt");

                        string source_name = "Paperboy API";
                        string? logo_url = null;

                        if (art.has_member("source")) {
                            var src_node = art.get_member("source");
                            if (src_node != null && src_node.get_node_type() == Json.NodeType.OBJECT) {
                                var src_obj = src_node.get_object();
                                string? n = json_get_string_safe(src_obj, "name");
                                if (n == null) n = json_get_string_safe(src_obj, "title");
                                if (n != null) source_name = n;

                                if (json_get_string_safe(src_obj, "logo_url") != null) logo_url = json_get_string_safe(src_obj, "logo_url");
                                else if (json_get_string_safe(src_obj, "logo") != null) logo_url = json_get_string_safe(src_obj, "logo");
                                else if (json_get_string_safe(src_obj, "favicon") != null) logo_url = json_get_string_safe(src_obj, "favicon");
                            } else {
                                string? s = json_get_string_safe(art, "source");
                                if (s != null) source_name = s;
                            }
                        } else {
                            if (json_get_string_safe(art, "source") != null) source_name = json_get_string_safe(art, "source");
                            else if (json_get_string_safe(art, "provider") != null) source_name = json_get_string_safe(art, "provider");
                        }

                        if (source_name == null || source_name.length == 0 || source_name == "Paperboy API") {
                            string inferred = infer_display_name_from_url(article_url);
                            if (inferred != null && inferred.length > 0) source_name = inferred;
                        }

                        if (logo_url == null) {
                            if (json_get_string_safe(art, "logo") != null) logo_url = json_get_string_safe(art, "logo");
                            else if (json_get_string_safe(art, "favicon") != null) logo_url = json_get_string_safe(art, "favicon");
                            else if (json_get_string_safe(art, "logo_url") != null) logo_url = json_get_string_safe(art, "logo_url");
                            else if (json_get_string_safe(art, "site_icon") != null) logo_url = json_get_string_safe(art, "site_icon");
                        }

                        if (logo_url != null) {
                            logo_url = logo_url.strip();
                            if (logo_url.has_prefix("//")) {
                                logo_url = "https:" + logo_url;
                            }
                        }

                        if (current_search_query.length > 0) {
                            string query_lower = current_search_query.down();
                            string title_lower = title.down();
                            string url_lower = article_url.down();
                            if (!title_lower.contains(query_lower) && !url_lower.contains(query_lower)) continue;
                        }

                        string display_source = SourceLabel.encode(source_name, logo_url, "sports");

                        add_item(title, article_url, thumbnail, "sports", display_source, published);
                    }
                    return false;
                });
            } catch (GLib.Error e) {
                warning("Paperboy Sports fetch error: %s", e.message);
            }
        });
    }

    // The API's `content` is the article's full text; stored before any cards are built.
    private static void record_reading_times(Json.Array articles) {
        var minutes = new Gee.HashMap<string, int>();
        for (uint i = 0; i < articles.get_length(); i++) {
            var node = articles.get_element(i);
            if (node.get_node_type() != Json.NodeType.OBJECT) continue;
            var art = node.get_object();
            string? url = json_get_string_safe(art, "url") ?? json_get_string_safe(art, "link");
            string? content = json_get_string_safe(art, "content");
            if (url == null || content == null) continue;
            int words = ArticleReadingTimeCache.count_words(stripHtmlUtils.strip_html(content));
            if (words >= ArticleReadingTimeCache.MIN_FULL_TEXT_WORDS) minutes.set(url, ArticleReadingTimeCache.minutes_for_words(words));
        }
        ArticleReadingTimeCache.get_instance().set_many(minutes);
    }

    private static string? json_get_string_safe(Json.Object obj, string member) {
        try {
            if (!obj.has_member(member)) return null;
            var node = obj.get_member(member);
            if (node == null) return null;
            if (node.get_node_type() != Json.NodeType.VALUE) return null;
            try {
                return node.get_string();
            } catch (GLib.Error e) {
                return null;
            }
        } catch (GLib.Error e) {
            return null;
        }
    }

    private static string infer_display_name_from_url(string? url) {
        if (url == null) return "Paperboy";
        string u = url.strip();
        if (u.length == 0) return "Paperboy";
        int pos = u.index_of("://");
        if (pos >= 0 && u.length > pos + 3) u = u.substring(pos + 3);
        int slash = u.index_of("/");
        if (slash >= 0 && u.length > slash) u = u.substring(0, slash);
        int colon = u.index_of(":");
        if (colon >= 0 && u.length > colon) u = u.substring(0, colon);
        if (u.has_prefix("www.") && u.length > 4) u = u.substring(4);
        if (u.length == 0) return "Paperboy";
        string[] parts = u.split(".");
        string label = parts.length > 0 ? parts[0] : u;
        label = label.replace("-", " ").replace("_", " ");
        string[] words = label.split(" ");
        string out = "";
        for (int i = 0; i < words.length; i++) {
            string w = words[i].strip();
            if (w.length == 0) continue;
            if (w.length < 1) continue; // Extra safety
            // .up() was missing here, so this silently passed the raw
            // lowercase domain word straight through instead of actually
            // capitalizing it (e.g. "businessinsider" instead of
            // "Businessinsider") - affects every caller of this helper
            // (frontpage/topten/sports), not just the Stocks supplement.
            string head = w.substring(0, 1).up();
            string tail = w.length > 1 ? w.substring(1) : "";
            if (out.length > 0) out += " ";
            out += head + tail;
        }
        if (out.length == 0) out = u;
        return out;
    }
}
