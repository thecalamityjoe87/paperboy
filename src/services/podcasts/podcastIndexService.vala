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

/**
 * Calls paperboyBackend's podcast endpoints (the same backend
 * PaperboyFetcher already calls for Top Ten/Front Page - see
 * src/services/fetchers/paperboyFetcher.vala's BASE_URL), never
 * api.podcastindex.org directly: PodcastIndex's API key/secret and its
 * request-auth hashing live entirely server-side, so this client never
 * sees or sends either.
 *
 * Backend contract (confirmed):
 *   GET /podcasts/search?q=<term>                 - not cached, hits PodcastIndex every call
 *   GET /podcasts/trending?cat=<category>&max=<n>  - cat optional (omit for all categories),
 *                                                     max optional (default 40, max 1000),
 *                                                     cached 15 min per (category, max)
 *   GET /podcasts/categories                       - valid category names for the picker/discovery
 *                                                     rows; cached 24h. Use this instead of a
 *                                                     hardcoded category list.
 *   GET /podcasts/{feed_id}/episodes?max=<n>       - a show's episodes, most recent first; feed_id
 *                                                     is the "id" from a search/trending result,
 *                                                     max optional (default 20, max 1000), cached
 *                                                     30 min per (feed_id, max). Each item's
 *                                                     enclosureUrl is a direct, playable audio URL -
 *                                                     hand it straight to PodcastPlaybackManager.
 *                                                     Playback streams from the podcast's own host,
 *                                                     not through paperboyBackend.
 *   GET /podcasts/byitunesid?id=<itunes_id>        - resolves an Apple Podcasts numeric id (e.g.
 *                                                     scraped from a site's own "Subscribe on Apple
 *                                                     Podcasts" link - see FeedUpdateManager's
 *                                                     podcast-feed discovery) to the podcast's real
 *                                                     feed url, via PodcastIndex's own already-built
 *                                                     database (not a live Apple API call). Response
 *                                                     is a single "feed" object, not an array; cached
 *                                                     24h per id on the backend.
 * All five return the PodcastIndex response body verbatim (minus auth
 * fields) with normal status codes: 200 success, 503 podcast feature not
 * configured on the backend, 502 PodcastIndex unreachable, other 4xx/5xx
 * passed through from PodcastIndex.
 */
namespace Paperboy {

    public class PodcastIndexService : GLib.Object {
        private const string BASE_URL = "https://paperboybackend.onrender.com";
        private const string PATH_SEARCH = "/podcasts/search";
        private const string PATH_TRENDING = "/podcasts/trending";
        private const string PATH_CATEGORIES = "/podcasts/categories";
        private const string PATH_BY_ITUNES_ID = "/podcasts/byitunesid";
        private const int DEFAULT_EPISODES_MAX = 20;

        private static PodcastIndexService? instance = null;

        public static PodcastIndexService get_instance() {
            if (instance == null) {
                instance = new PodcastIndexService();
            }
            return instance;
        }

        public delegate void ShowListCallback(Gee.ArrayList<Paperboy.PodcastShow> shows);
        public delegate void CategoryListCallback(Gee.ArrayList<string> categories);
        public delegate void EpisodeListCallback(Gee.ArrayList<Paperboy.PodcastEpisode> episodes);
        public delegate void ShowCallback(Paperboy.PodcastShow? show);

        public void search_podcasts(string term, owned ShowListCallback callback) {
            string url = "%s%s?q=%s".printf(BASE_URL, PATH_SEARCH, GLib.Uri.escape_string(term));
            fetch_show_list(url, (owned) callback);
        }

        // Searches PodcastIndex by a followed site's own name (e.g.
        // "Wccftech") and returns the first result whose own "link" field
        // (the podcast's associated website, as PodcastIndex's crawler
        // already recorded it) matches site_domain - far more reliable than
        // scraping the site's homepage for a hint, since it works even when
        // the site never links its podcast from its homepage at all (see
        // FeedUpdateManager.maybe_check_for_podcast_feed()'s doc comment).
        // exclude_url filters out a result that's actually just the site's
        // own article feed re-indexed under a "podcast" medium by mistake -
        // never treat the followed feed itself as its own "discovery".
        public void find_podcast_by_site(string site_name, string site_domain, string exclude_url, owned ShowCallback callback) {
            find_podcasts_by_site(site_name, site_domain, exclude_url, (shows) => {
                callback(shows.size > 0 ? shows[0] : null);
            });
        }

        // Same matching rule as find_podcast_by_site() (a search result's
        // own "link" field, as PodcastIndex's crawler recorded it, must
        // match site_domain) but collects every match instead of stopping
        // at the first - a site can genuinely run several podcasts (e.g.
        // USA Today has ~7 in PodcastIndex), and the "Add podcast" picker
        // (see HeaderManager) needs the full list to let the user choose.
        public void find_podcasts_by_site(string site_name, string site_domain, string exclude_url, owned ShowListCallback callback) {
            string url = "%s%s?q=%s".printf(BASE_URL, PATH_SEARCH, GLib.Uri.escape_string(site_name));
            var client = Paperboy.HttpClientUtils.get_default();
            client.fetch_json(url, (response, parser, root) => {
                var matches = new Gee.ArrayList<Paperboy.PodcastShow>();
                if (response.is_success() && root != null) {
                    try {
                        Json.Array? items = extract_array(root, "feeds", "podcasts");
                        if (items != null) {
                            uint len = items.get_length();
                            for (uint i = 0; i < len; i++) {
                                var obj = items.get_element(i).get_object();
                                if (obj == null) continue;

                                string? feed_url = json_get_string(obj, "url");
                                if (feed_url != null && feed_url == exclude_url) continue;

                                string? link = json_get_string(obj, "link");
                                if (link == null || link.length == 0) continue;
                                if (UrlUtils.extract_host_from_url(link) != site_domain) continue;

                                matches.add(parse_show(obj));
                            }
                        }
                    } catch (GLib.Error e) {
                        GLib.warning("PodcastIndexService: failed to parse site search results: %s", e.message);
                    }
                } else {
                    log_http_error(url, response.status_code);
                }

                Idle.add(() => { callback(matches); return false; });
            });
        }

        // category: pass null (or empty) for all categories - matches the
        // backend's "cat is optional" contract.
        public void trending_podcasts(int max, string? category, owned ShowListCallback callback) {
            string url = "%s%s?max=%d".printf(BASE_URL, PATH_TRENDING, max);
            if (category != null && category.length > 0) {
                url += "&cat=%s".printf(GLib.Uri.escape_string(category));
            }
            fetch_show_list(url, (owned) callback);
        }

        // Resolves an Apple Podcasts numeric id to the podcast's real feed
        // url - see FeedUpdateManager.maybe_check_for_podcast_feed(), which
        // scrapes that id off a followed site's own "Subscribe on Apple
        // Podcasts" link when the site doesn't advertise a podcast feed via
        // a plain <link rel="alternate"> tag.
        public void podcast_by_itunes_id(int64 itunes_id, owned ShowCallback callback) {
            string url = "%s%s?id=%lld".printf(BASE_URL, PATH_BY_ITUNES_ID, itunes_id);
            var client = Paperboy.HttpClientUtils.get_default();
            client.fetch_json(url, (response, parser, root) => {
                if (!response.is_success() || root == null) {
                    log_http_error(url, response.status_code);
                    Idle.add(() => { callback(null); return false; });
                    return;
                }

                Paperboy.PodcastShow? show = null;
                try {
                    if (root.get_node_type() == Json.NodeType.OBJECT) {
                        var obj = root.get_object();
                        if (obj.has_member("feed")) {
                            var feed_node = obj.get_member("feed");
                            if (feed_node != null && feed_node.get_node_type() == Json.NodeType.OBJECT) {
                                var feed_obj = feed_node.get_object();
                                // A "not found" result comes back as an empty
                                // feed object ({} - no id/url) rather than an
                                // HTTP error - a real match always has a url.
                                if (feed_obj.has_member("url") && json_get_string(feed_obj, "url") != null) {
                                    show = parse_show(feed_obj);
                                }
                            }
                        }
                    }
                } catch (GLib.Error e) {
                    GLib.warning("PodcastIndexService: failed to parse byitunesid response: %s", e.message);
                }

                Idle.add(() => { callback(show); return false; });
            });
        }

        public void get_categories(owned CategoryListCallback callback) {
            string url = BASE_URL + PATH_CATEGORIES;
            var client = Paperboy.HttpClientUtils.get_default();
            client.fetch_json(url, (response, parser, root) => {
                var categories = new Gee.ArrayList<string>();
                if (!response.is_success() || root == null) {
                    log_http_error("categories", response.status_code);
                    Idle.add(() => { callback(categories); return false; });
                    return;
                }

                try {
                    Json.Array? items = extract_array(root, "categories", "feeds");
                    if (items != null) {
                        uint len = items.get_length();
                        for (uint i = 0; i < len; i++) {
                            var element = items.get_element(i);
                            // Category list entries may be plain strings or
                            // {id, name} objects depending on how the
                            // backend passes PodcastIndex's response through.
                            if (element.get_node_type() == Json.NodeType.VALUE) {
                                string? name = element.get_string();
                                if (name != null) categories.add(name);
                            } else if (element.get_node_type() == Json.NodeType.OBJECT) {
                                var obj = element.get_object();
                                string? name = json_get_string(obj, "name");
                                if (name != null) categories.add(name);
                            }
                        }
                    }
                } catch (GLib.Error e) {
                    GLib.warning("PodcastIndexService: failed to parse categories: %s", e.message);
                }

                Idle.add(() => { callback(categories); return false; });
            });
        }

        public void episodes_for_feed(int64 feed_id, int max, owned EpisodeListCallback callback) {
            string url = "%s/podcasts/%lld/episodes?max=%d".printf(BASE_URL, feed_id, max > 0 ? max : DEFAULT_EPISODES_MAX);
            var client = Paperboy.HttpClientUtils.get_default();
            client.fetch_json(url, (response, parser, root) => {
                var episodes = new Gee.ArrayList<Paperboy.PodcastEpisode>();
                if (!response.is_success() || root == null) {
                    log_http_error(url, response.status_code);
                    Idle.add(() => { callback(episodes); return false; });
                    return;
                }

                try {
                    Json.Array? items = extract_array(root, "items", "episodes");
                    if (items != null) {
                        uint len = items.get_length();
                        for (uint i = 0; i < len; i++) {
                            var obj = items.get_element(i).get_object();
                            if (obj != null) episodes.add(parse_episode(obj, feed_id));
                        }
                    }
                } catch (GLib.Error e) {
                    GLib.warning("PodcastIndexService: failed to parse episode list: %s", e.message);
                }

                Idle.add(() => { callback(episodes); return false; });
            });
        }

        private void fetch_show_list(string url, owned ShowListCallback callback) {
            var client = Paperboy.HttpClientUtils.get_default();
            client.fetch_json(url, (response, parser, root) => {
                var shows = new Gee.ArrayList<Paperboy.PodcastShow>();
                if (!response.is_success() || root == null) {
                    log_http_error(url, response.status_code);
                    Idle.add(() => { callback(shows); return false; });
                    return;
                }

                try {
                    Json.Array? items = extract_array(root, "feeds", "podcasts");
                    if (items != null) {
                        uint len = items.get_length();
                        for (uint i = 0; i < len; i++) {
                            var obj = items.get_element(i).get_object();
                            if (obj != null) shows.add(parse_show(obj));
                        }
                    }
                } catch (GLib.Error e) {
                    GLib.warning("PodcastIndexService: failed to parse show list: %s", e.message);
                }

                Idle.add(() => { callback(shows); return false; });
            });
        }

        private void log_http_error(string what, uint status_code) {
            switch (status_code) {
                case 503:
                    GLib.warning("PodcastIndexService: podcast search isn't configured on the backend yet (%s)", what);
                    break;
                case 502:
                    GLib.warning("PodcastIndexService: PodcastIndex is unreachable (%s)", what);
                    break;
                default:
                    GLib.warning("PodcastIndexService: HTTP error %u for %s", status_code, what);
                    break;
            }
        }

        // Accepts either a bare top-level JSON array or an object with one
        // of the given member names holding the array - mirrors
        // PaperboyFetcher's own tolerant root-shape handling.
        private Json.Array? extract_array(Json.Node root, string primary_member, string fallback_member) {
            if (root.get_node_type() == Json.NodeType.ARRAY) {
                return root.get_array();
            }
            if (root.get_node_type() != Json.NodeType.OBJECT) return null;

            var obj = root.get_object();
            if (obj.has_member(primary_member)) return obj.get_array_member(primary_member);
            if (obj.has_member(fallback_member)) return obj.get_array_member(fallback_member);
            return null;
        }

        private string? json_get_string(Json.Object obj, string member) {
            if (!obj.has_member(member)) return null;
            var node = obj.get_member(member);
            if (node == null || node.get_node_type() != Json.NodeType.VALUE) return null;
            return node.get_string();
        }

        private Paperboy.PodcastShow parse_show(Json.Object obj) {
            var show = new Paperboy.PodcastShow();
            show.feed_id = obj.has_member("id") ? obj.get_int_member("id") : 0;
            show.title = json_get_string(obj, "title") ?? "";
            show.author = json_get_string(obj, "author");
            show.description = json_get_string(obj, "description");
            show.image_url = json_get_string(obj, "image") ?? json_get_string(obj, "artwork");
            show.feed_url = json_get_string(obj, "url") ?? "";
            show.category = json_get_string(obj, "category");
            show.episode_count = obj.has_member("episodeCount") ? (int) obj.get_int_member("episodeCount") : 0;
            show.language = json_get_string(obj, "language");
            return show;
        }

        private Paperboy.PodcastEpisode parse_episode(Json.Object obj, int64 feed_id) {
            var episode = new Paperboy.PodcastEpisode();
            episode.episode_id = obj.has_member("id") ? obj.get_int_member("id") : 0;
            episode.feed_id = feed_id;
            episode.title = json_get_string(obj, "title") ?? "";
            episode.description = json_get_string(obj, "description");
            episode.audio_url = json_get_string(obj, "enclosureUrl") ?? "";
            episode.duration_seconds = obj.has_member("duration") ? obj.get_int_member("duration") : 0;
            episode.published = obj.has_member("datePublished") ? obj.get_int_member("datePublished").to_string() : null;
            episode.image_url = json_get_string(obj, "image") ?? json_get_string(obj, "feedImage");
            return episode;
        }
    }
}
