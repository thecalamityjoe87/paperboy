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
private static extern void opml_xml_free_doc(Xml.Doc* doc);

private delegate void VoidCallback();

namespace Paperboy {
    // Exports/imports custom RSS sources and podcast subscriptions as a
    // single OPML file, grouped under "Feeds" and "Podcasts" outline
    // categories - the standard interchange format other feed/podcast
    // apps also read and write.
    public class OpmlService : GLib.Object {
        public class ImportResult : GLib.Object {
            public int feeds_added = 0;
            public int podcasts_added = 0;
        }

        private class FeedEntry : GLib.Object {
            public string name;
            public string url;
            public string? html_url;
            public string? icon_url;
        }

        public delegate void ImportCallback(ImportResult result);

        public static bool export_to_file(string path) throws GLib.Error {
            Xml.Doc* doc = new Xml.Doc("1.0");
            Xml.Node* root = doc->new_node(null, "opml");
            root->set_prop("version", "2.0");
            doc->set_root_element(root);

            Xml.Node* head = root->new_child(null, "head");
            head->new_text_child(null, "title", "Paperboy Export");

            Xml.Node* body = root->new_child(null, "body");

            Xml.Node* feeds_outline = body->new_child(null, "outline");
            feeds_outline->set_prop("text", "Feeds");
            feeds_outline->set_prop("title", "Feeds");

            var sources = RssSourceStore.get_instance().get_all_sources();
            foreach (var source in sources) {
                Xml.Node* entry = feeds_outline->new_child(null, "outline");
                entry->set_prop("type", "rss");
                entry->set_prop("text", source.name);
                entry->set_prop("title", source.name);
                entry->set_prop("xmlUrl", source.url);
                if (source.original_url != null) {
                    entry->set_prop("htmlUrl", source.original_url);
                }
                // Non-standard attribute (ignored by other OPML readers) so a
                // re-import can resolve the same icon instead of guessing via
                // a bare favicon.ico request.
                string? icon_url = SourceMetadata.get_logo_url_for_source(source.name);
                if (icon_url != null && icon_url.length > 0) {
                    entry->set_prop("paperboyIconUrl", icon_url);
                }
            }

            Xml.Node* podcasts_outline = body->new_child(null, "outline");
            podcasts_outline->set_prop("text", "Podcasts");
            podcasts_outline->set_prop("title", "Podcasts");

            var subscriptions = PodcastSubscriptionStore.get_instance().get_all_subscriptions();
            foreach (var sub in subscriptions) {
                Xml.Node* entry = podcasts_outline->new_child(null, "outline");
                entry->set_prop("type", "rss");
                entry->set_prop("text", sub.title);
                entry->set_prop("title", sub.title);
                entry->set_prop("xmlUrl", sub.feed_url);
            }

            int rc = doc->save_format_file(path, 1);
            opml_xml_free_doc(doc);
            return rc >= 0;
        }

        // Parses the OPML file, then adds each feed/podcast through the same
        // discovery pipeline as the normal "Add RSS Feed"/"Add a Podcast"
        // flows (SourceManager.add_rss_feed_with_discovery,
        // PodcastFeedResolver.resolve_show), so icons and cover art get
        // fetched just like a manual add instead of being left blank.
        // Those pipelines are callback-based (not yield-able), so feeds and
        // podcasts are each processed one at a time via recursion, with
        // `callback` firing once every entry has been attempted.
        public static void import_from_file(
            string path,
            SourceManager source_manager,
            Soup.Session session,
            FeedUpdateManager? feed_updater,
            owned ImportCallback callback
        ) throws GLib.Error {
            var feed_entries = new Gee.ArrayList<FeedEntry>();
            var podcast_entries = new Gee.ArrayList<FeedEntry>();

            var parser_options = Xml.ParserOption.NONET | Xml.ParserOption.NOCDATA | Xml.ParserOption.NOBLANKS | Xml.ParserOption.RECOVER | Xml.ParserOption.NOERROR | Xml.ParserOption.NOWARNING;
            Xml.Doc* doc = Xml.Parser.read_file(path, null, (int) parser_options);
            if (doc == null) {
                throw new GLib.IOError.INVALID_DATA("Could not parse OPML file");
            }

            Xml.Node* root = doc->get_root_element();
            if (root == null || root->name != "opml") {
                opml_xml_free_doc(doc);
                throw new GLib.IOError.INVALID_DATA("Not a valid OPML file");
            }

            for (Xml.Node* section = root->children; section != null; section = section->next) {
                if (section->type != Xml.ElementType.ELEMENT_NODE || section->name != "body") continue;
                collect_outline_children(section, false, feed_entries, podcast_entries);
            }

            opml_xml_free_doc(doc);

            var result = new ImportResult();
            import_next_feed(feed_entries, 0, source_manager, feed_updater, result, () => {
                var resolver = PodcastFeedResolver.get_instance();
                var podcast_store = PodcastSubscriptionStore.get_instance();
                import_next_podcast(podcast_entries, 0, resolver, podcast_store, session, result, () => {
                    callback(result);
                });
            });
        }

        private static void import_next_feed(
            Gee.ArrayList<FeedEntry> entries,
            int index,
            SourceManager source_manager,
            FeedUpdateManager? feed_updater,
            ImportResult result,
            owned VoidCallback done
        ) {
            if (index >= entries.size) {
                done();
                return;
            }

            var entry = entries.get(index);

            // Locally-generated feeds (output for sites with no native RSS)
            // have no host to run favicon/title discovery against, and need
            // `original_url` preserved so the app still knows the real site
            // behind them - insert them directly
            // instead of routing through the network discovery pipeline.
            if (entry.url.has_prefix("file://")) {
                var prefs = NewsPreferences.get_instance();
                var source_store = RssSourceStore.get_instance();
                bool success = source_store.add_source_with_original_url(entry.name, entry.url, entry.html_url);
                if (success) {
                    prefs.set_preferred_source_enabled("custom:" + entry.url, true);
                    prefs.save_config();
                    result.feeds_added++;

                    // add_source_with_original_url() only tries a bare
                    // favicon.ico guess internally, which frequently fails -
                    // prefer the icon URL captured at export time, falling
                    // back to Google's favicon service like the normal
                    // WebKit-generated-feed flow does.
                    string? host_for_icon = entry.html_url != null ? UrlUtils.extract_host_from_url(entry.html_url) : null;
                    if (host_for_icon != null && host_for_icon.length > 0) {
                        string icon_url = (entry.icon_url != null && entry.icon_url.length > 0)
                            ? entry.icon_url
                            : "https://www.google.com/s2/favicons?domain=" + host_for_icon + "&sz=128";
                        SourceMetadata.update_index_and_fetch(host_for_icon, entry.name, icon_url, entry.html_url, null, entry.url);
                    }

                    // The imported file:// path almost certainly doesn't
                    // exist in this profile (it's wherever it was generated
                    // on the machine the OPML was exported from) - regenerate
                    // it now instead of waiting for the next periodic cycle.
                    if (feed_updater != null) {
                        var added_source = source_store.get_source_by_url(entry.url);
                        if (added_source != null) {
                            GLib.print("OPML import: triggering regeneration for '%s' (%s)\n", entry.name, entry.url);
                            feed_updater.regenerate_single_feed_async(added_source);
                        } else {
                            GLib.warning("OPML import: added '%s' but could not look it back up by URL to regenerate", entry.name);
                        }
                    } else {
                        GLib.warning("OPML import: no feed_updater available, '%s' won't be regenerated until the next periodic cycle", entry.name);
                    }
                } else {
                    GLib.warning("OPML import: add_source_with_original_url failed for '%s' (%s) - already exists?", entry.name, entry.url);
                }
                import_next_feed(entries, index + 1, source_manager, feed_updater, result, (owned) done);
                return;
            }

            source_manager.add_rss_feed_with_discovery(entry.url, entry.name, (success, name) => {
                if (success) result.feeds_added++;
                import_next_feed(entries, index + 1, source_manager, feed_updater, result, (owned) done);
            });
        }

        private static void import_next_podcast(
            Gee.ArrayList<FeedEntry> entries,
            int index,
            Paperboy.PodcastFeedResolver resolver,
            Paperboy.PodcastSubscriptionStore podcast_store,
            Soup.Session session,
            ImportResult result,
            owned VoidCallback done
        ) {
            if (index >= entries.size) {
                done();
                return;
            }

            var entry = entries.get(index);
            resolver.resolve_show(entry.url, session, (success, show, error_message) => {
                if (success && show != null && podcast_store.subscribe(show)) {
                    result.podcasts_added++;
                }
                import_next_podcast(entries, index + 1, resolver, podcast_store, session, result, (owned) done);
            });
        }

        // Recurses through outline elements, treating any category whose
        // text/title contains "podcast" as the podcasts group and every
        // other leaf outline (one with an xmlUrl) as a feed. Only collects
        // entries here - network/DB work happens afterward in the caller.
        private static void collect_outline_children(
            Xml.Node* parent,
            bool in_podcasts_category,
            Gee.ArrayList<FeedEntry> feed_entries,
            Gee.ArrayList<FeedEntry> podcast_entries
        ) {
            for (Xml.Node* node = parent->children; node != null; node = node->next) {
                if (node->type != Xml.ElementType.ELEMENT_NODE || node->name != "outline") continue;

                string? xml_url = node->get_prop("xmlUrl");
                string? text = node->get_prop("text") ?? node->get_prop("title") ?? xml_url;

                if (xml_url == null) {
                    // Category outline (Feeds/Podcasts/etc) - recurse into it.
                    bool is_podcasts = in_podcasts_category || (text != null && text.down().contains("podcast"));
                    collect_outline_children(node, is_podcasts, feed_entries, podcast_entries);
                    continue;
                }

                var entry = new FeedEntry();
                entry.name = text ?? xml_url;
                entry.url = xml_url;
                entry.html_url = node->get_prop("htmlUrl");
                entry.icon_url = node->get_prop("paperboyIconUrl");

                if (in_podcasts_category) {
                    podcast_entries.add(entry);
                } else {
                    feed_entries.add(entry);
                }
            }
        }
    }
}
