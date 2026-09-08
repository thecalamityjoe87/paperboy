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

using Xml;

/**
 * Resolves a podcast directly from its own RSS/Atom feed URL - no
 * PodcastIndex or paperboyBackend involved at all. A podcast feed is just
 * RSS with iTunes-namespace tags and per-item <enclosure> audio URLs, so
 * this mirrors SourceManager.add_rss_feed_with_discovery's exact fetch
 * approach (background Thread doing a plain Soup.Message GET, GLib.Idle.add
 * back to the main loop) for regular RSS feeds, just parsing podcast-shaped
 * fields instead of article-shaped ones.
 *
 * Shows added this way get feed_id = 0 and from_direct_feed = true (see
 * Paperboy.PodcastShow) since they have no PodcastIndex identity - episode
 * lookups for them go through fetch_episodes() here (re-parsing the same
 * feed) instead of PodcastIndexService.episodes_for_feed(), which needs a
 * real PodcastIndex feed_id.
 */
namespace Paperboy {
    public class PodcastFeedResolver : GLib.Object {
        public delegate void ResolveCallback(bool success, Paperboy.PodcastShow? show, string? error_message);
        public delegate void EpisodesCallback(Gee.ArrayList<Paperboy.PodcastEpisode> episodes);

        private static PodcastFeedResolver? instance = null;
        public static PodcastFeedResolver get_instance() {
            if (instance == null) instance = new PodcastFeedResolver();
            return instance;
        }

        public void resolve_show(string feed_url, Soup.Session session, owned ResolveCallback callback) {
            new GLib.Thread<void*>("podcast-resolve", () => {
                Paperboy.PodcastShow? show = null;
                string? error = null;
                try {
                    string? body = fetch(feed_url, session);
                    if (body == null) {
                        error = "Couldn't reach that feed";
                    } else {
                        show = parse_show(body, feed_url);
                        if (show == null) error = "That doesn't look like a valid podcast feed";
                    }
                } catch (GLib.Error e) {
                    error = e.message;
                }

                GLib.Idle.add(() => {
                    callback(show != null, show, error);
                    return false;
                });
                return null;
            });
        }

        public void fetch_episodes(string feed_url, string show_title, string? show_image_url, Soup.Session session, owned EpisodesCallback callback) {
            new GLib.Thread<void*>("podcast-episodes-direct", () => {
                var episodes = new Gee.ArrayList<Paperboy.PodcastEpisode>();
                try {
                    string? body = fetch(feed_url, session);
                    if (body != null) parse_episodes(body, show_title, show_image_url, episodes);
                } catch (GLib.Error e) {
                    GLib.warning("PodcastFeedResolver: failed to fetch episodes for %s: %s", feed_url, e.message);
                }

                GLib.Idle.add(() => {
                    callback(episodes);
                    return false;
                });
                return null;
            });
        }

        private string? fetch(string url, Soup.Session session) throws GLib.Error {
            var msg = new Soup.Message("GET", url);
            msg.get_request_headers().append("User-Agent", "paperboy/0.8");
            GLib.Bytes? response = session.send_and_read(msg, null);
            if (msg.get_status() != Soup.Status.OK || response == null) return null;
            return (string) response.get_data();
        }

        // Negative and deterministic - the same feed_url always yields the
        // same id across app restarts (so subscribe/unsubscribe/
        // is_subscribed keep finding the same row), and it can never
        // collide with a real PodcastIndex feed_id (always positive).
        public int64 compute_synthetic_feed_id(string feed_url) {
            uint h = str_hash(feed_url);
            return -((int64) h);
        }

        private Xml.Node* find_channel(Xml.Doc* doc) {
            Xml.Node* root = doc->get_root_element();
            if (root == null) return null;
            if (root->name == "channel") return root;
            for (Xml.Node* n = root->children; n != null; n = n->next) {
                if (n->type == Xml.ElementType.ELEMENT_NODE && n->name == "channel") return n;
            }
            return null;
        }

        private string? attr(Xml.Node* node, string attr_name) {
            for (Xml.Attr* a = node->properties; a != null; a = a->next) {
                if (a->name == attr_name) {
                    return a->children != null ? (string) a->children->content : null;
                }
            }
            return null;
        }

        private Paperboy.PodcastShow? parse_show(string xml, string feed_url) {
            var parser_options = Xml.ParserOption.NONET | Xml.ParserOption.NOCDATA | Xml.ParserOption.NOBLANKS | Xml.ParserOption.RECOVER;
            Xml.Doc* doc = Xml.Parser.read_memory(xml, xml.length, null, null, parser_options);
            if (doc == null) return null;

            Xml.Node* channel = find_channel(doc);
            if (channel == null) { delete doc; return null; }

            var show = new Paperboy.PodcastShow();
            show.feed_id = compute_synthetic_feed_id(feed_url);
            show.feed_url = feed_url;
            show.from_direct_feed = true;
            show.title = "";

            for (Xml.Node* n = channel->children; n != null; n = n->next) {
                if (n->type != Xml.ElementType.ELEMENT_NODE) continue;

                if (n->name == "title" && show.title.length == 0) {
                    string? content = n->get_content();
                    if (content != null) show.title = content.strip();
                } else if (n->name == "description" && show.description == null) {
                    string? content = n->get_content();
                    if (content != null) show.description = content.strip();
                } else if (n->name == "author") {
                    // <itunes:author> (show/publisher name) - <author> alone
                    // (plain RSS, usually an email) is not useful here, so
                    // only accept it from the itunes namespace.
                    if (n->ns != null && n->ns->prefix == "itunes" && show.author == null) {
                        string? content = n->get_content();
                        if (content != null) show.author = content.strip();
                    }
                } else if (n->name == "image") {
                    if (n->ns != null && n->ns->prefix == "itunes") {
                        // <itunes:image href="..."/>
                        string? href = attr(n, "href");
                        if (href != null && href.length > 0) show.image_url = href;
                    } else if (show.image_url == null) {
                        // Plain RSS <image><url>...</url></image>
                        for (Xml.Node* c = n->children; c != null; c = c->next) {
                            if (c->type == Xml.ElementType.ELEMENT_NODE && c->name == "url") {
                                string? content = c->get_content();
                                if (content != null) show.image_url = content.strip();
                            }
                        }
                    }
                }
            }

            delete doc;

            if (show.title.length == 0) return null;
            return show;
        }

        private void parse_episodes(string xml, string show_title, string? show_image_url, Gee.ArrayList<Paperboy.PodcastEpisode> episodes) {
            var parser_options = Xml.ParserOption.NONET | Xml.ParserOption.NOCDATA | Xml.ParserOption.NOBLANKS | Xml.ParserOption.RECOVER;
            Xml.Doc* doc = Xml.Parser.read_memory(xml, xml.length, null, null, parser_options);
            if (doc == null) return;

            Xml.Node* channel = find_channel(doc);
            if (channel == null) { delete doc; return; }

            for (Xml.Node* it = channel->children; it != null; it = it->next) {
                if (it->type != Xml.ElementType.ELEMENT_NODE || it->name != "item") continue;

                var episode = new Paperboy.PodcastEpisode();
                episode.episode_id = 0;
                episode.feed_id = 0;
                episode.show_title = show_title;
                episode.image_url = show_image_url;
                episode.title = "";

                for (Xml.Node* c = it->children; c != null; c = c->next) {
                    if (c->type != Xml.ElementType.ELEMENT_NODE) continue;

                    if (c->name == "title" && episode.title.length == 0) {
                        string? content = c->get_content();
                        if (content != null) episode.title = content.strip();
                    } else if (c->name == "description" && episode.description == null) {
                        string? content = c->get_content();
                        if (content != null) episode.description = content.strip();
                    } else if (c->name == "pubDate" && episode.published == null) {
                        string? content = c->get_content();
                        if (content != null && content.strip().length > 0) episode.published = content.strip();
                    } else if (c->name == "enclosure") {
                        string? url = attr(c, "url");
                        if (url != null && url.length > 0) episode.audio_url = url;
                    } else if (c->name == "duration" && c->ns != null && c->ns->prefix == "itunes") {
                        string? content = c->get_content();
                        if (content != null) episode.duration_seconds = parse_duration(content.strip());
                    } else if (c->name == "image" && c->ns != null && c->ns->prefix == "itunes") {
                        string? href = attr(c, "href");
                        if (href != null && href.length > 0) episode.image_url = href;
                    }
                }

                if (episode.title.length > 0 && episode.audio_url != null && episode.audio_url.length > 0) {
                    episodes.add(episode);
                }
            }

            delete doc;
        }

        // itunes:duration is either a plain seconds count ("1830") or
        // HH:MM:SS/MM:SS ("00:30:30" / "30:30").
        private int64 parse_duration(string raw) {
            if (raw.length == 0) return 0;
            if (!raw.contains(":")) {
                int64 seconds = int64.parse(raw);
                return seconds > 0 ? seconds : 0;
            }
            string[] parts = raw.split(":");
            int64 total = 0;
            foreach (var part in parts) {
                total = total * 60 + int64.parse(part.strip());
            }
            return total;
        }
    }
}
