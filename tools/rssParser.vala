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


using Soup;
using Xml;
using Gee;

public class RssParser {
    // Cap for number of items to process per LOCAL feed; this prevents a
    // single local RSS feed from adding an unbounded number of articles
    // which can cause memory to grow quickly when many local feeds exist.
    private const int LOCAL_FEED_MAX_ITEMS = 12;
    
    public static void parse_rss_and_display(
        string body,
        string source_name,
        string category_name,
        string category_id,
        string current_search_query,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item,
        Soup.Session session
    ) {
        try {
            Xml.Doc* doc = Xml.Parser.parse_memory(body, (int) body.length);
            if (doc == null) {
                warning("RSS parse failed");
                return;
            }

            var items = new Gee.ArrayList<Gee.ArrayList<string?>>();
            // Respect runtime feature flag to enable/disable BBC-specific extraction/normalization.
            bool bbc_enabled = false;
            try { string? env = GLib.Environment.get_variable("PAPERBOY_ENABLE_BBC_EXTRACT"); if (env == null) bbc_enabled = true; else bbc_enabled = env != "0"; } catch (GLib.Error e) { bbc_enabled = true; }
            Xml.Node* root = doc->get_root_element();
            for (Xml.Node* ch = root->children; ch != null; ch = ch->next) {
                if (ch->type == Xml.ElementType.ELEMENT_NODE && (ch->name == "channel" || ch->name == "feed")) {
                    for (Xml.Node* it = ch->children; it != null; it = it->next) {
                        if (it->type == Xml.ElementType.ELEMENT_NODE && (it->name == "item" || it->name == "entry")) {
                            string? title = null;
                            string? link = null;
                            string? thumb = null;
                            for (Xml.Node* c = it->children; c != null; c = c->next) {
                                if (c->type == Xml.ElementType.ELEMENT_NODE) {
                                    if (c->name == "title") {
                                        title = c->get_content();
                                    } else if (c->name == "link") {
                                        Xml.Attr* href = c->properties;
                                        while (href != null) {
                                            if (href->name == "href") {
                                                link = href->children != null ? (string) href->children->content : null;
                                                break;
                                            }
                                            href = href->next;
                                        }
                                        if (link == null) {
                                            link = c->get_content();
                                        }
                                    } else if (c->name == "enclosure") {
                                        Xml.Attr* a = c->properties;
                                        while (a != null) {
                                            if (a->name == "url") {
                                                        thumb = a->children != null ? (string) a->children->content : null;
                                                        // Normalize protocol-relative URLs and HTML entities
                                                        if (thumb != null) {
                                                            if (thumb.has_prefix("//")) thumb = "https:" + thumb;
                                                            thumb = thumb.replace("&amp;", "&");
                                                        }
                                                break;
                                            }
                                            a = a->next;
                                        }
                                    } else if (c->name == "thumbnail" && c->ns != null && c->ns->prefix == "media") {
                                        Xml.Attr* a2 = c->properties;
                                        while (a2 != null) {
                                            if (a2->name == "url") {
                                                        thumb = a2->children != null ? (string) a2->children->content : null;
                                                        // Normalize protocol-relative URLs and HTML entities
                                                        if (thumb != null) {
                                                            if (thumb.has_prefix("//")) thumb = "https:" + thumb;
                                                            thumb = thumb.replace("&amp;", "&");
                                                        }
                                                break;
                                            }
                                            a2 = a2->next;
                                        }
                                    } else if (c->name == "content" && c->ns != null && c->ns->prefix == "media") {
                                        // media:content may provide url, type and medium attributes. Some feeds
                                        // (like WSJ) use image URLs without a file extension (eg. /im-12345).
                                        // Accept those when the type or medium indicates an image.
                                        Xml.Attr* a3 = c->properties;
                                        string? media_url = null;
                                        string? media_type = null;
                                        string? media_medium = null;
                                        while (a3 != null) {
                                            if (a3->name == "url") {
                                                media_url = a3->children != null ? (string) a3->children->content : null;
                                            } else if (a3->name == "type") {
                                                media_type = a3->children != null ? (string) a3->children->content : null;
                                            } else if (a3->name == "medium") {
                                                media_medium = a3->children != null ? (string) a3->children->content : null;
                                            }
                                            a3 = a3->next;
                                        }
                                        if (media_url != null && thumb == null) {
                                            bool is_image = false;
                                            if (media_type != null && media_type.has_prefix("image")) is_image = true;
                                            if (media_medium != null && media_medium == "image") is_image = true;
                                            string mu_lower = media_url.down();
                                            if (mu_lower.has_suffix(".jpg") || mu_lower.has_suffix(".jpeg") || mu_lower.has_suffix(".png") || mu_lower.has_suffix(".webp") || mu_lower.has_suffix(".gif")) is_image = true;
                                            // Heuristic: WSJ image host uses /im-... paths without extensions
                                            if (!is_image && media_url.contains("images.wsj.net/im-")) is_image = true;
                                            if (is_image) {
                                                thumb = media_url.has_prefix("//") ? "https:" + media_url : media_url;
                                            }
                                        }
                                    } else if (c->name == "description" && thumb == null) {
                                        // Sometimes images are in the description as HTML
                                        string? desc = c->get_content();
                                        if (desc != null) {
                                            thumb = Tools.ImageParser.extract_image_from_html_snippet(desc);
                                        }
                                    } else if (c->name == "encoded" && c->ns != null && c->ns->prefix == "content" && thumb == null) {
                                        // Check content:encoded for images (used by NPR and others)
                                        string? content = c->get_content();
                                        if (content != null) {
                                            thumb = Tools.ImageParser.extract_image_from_html_snippet(content);
                                        }
                                    }
                                }
                            }
                            if (title != null && link != null) {
                                // If this is a Local News feed, cap the number of
                                // items we track from this single feed. This helps
                                // control memory growth for users that have large
                                // numbers of local feeds configured.
                                if (category_id == "local_news" && items.size >= LOCAL_FEED_MAX_ITEMS) {
                                    try {
                                        if (GLib.Environment.get_variable("PAPERBOY_DEBUG") != null) {
                                            warning("rssParser: local feed cap reached (%d): %s", LOCAL_FEED_MAX_ITEMS, source_name);
                                        }
                                    } catch (GLib.Error e) { }
                                    continue;
                                }
                                var row = new Gee.ArrayList<string?>();
                                // If the feed provided a BBC thumbnail, try normalizing it to a larger CDN variant
                                if (thumb != null && bbc_enabled) {
                                    string thumb_l = thumb.down();
                                    if (thumb_l.contains("bbc.") || thumb_l.contains("bbci.co.uk")) {
                                        string before = thumb;
                                        thumb = Tools.ImageParser.normalize_bbc_image_url(thumb);
                                        try { if (GLib.Environment.get_variable("PAPERBOY_DEBUG") != null) warning("rssParser: normalized thumb %s -> %s", before, thumb); } catch (GLib.Error e) { }
                                    }
                                }
                                row.add(title);
                                row.add(link);
                                row.add(thumb);
                                items.add(row);
                            }
                        }
                    }
                }
            }

                Idle.add(() => {
                if (current_search_query.length > 0) {
                    set_label(@"Search Results: \"$(current_search_query)\" in $(category_name) — $(source_name)");
                } else {
                    set_label(@"$(category_name) — $(source_name)");
                }

                clear_items();
                foreach (var row in items) {
                    add_item(row[0] ?? "No title", row[1] ?? "", row[2], category_id, source_name);
                }
                return false;
            });

                // Background: for BBC links, try to fetch higher-resolution images using
                // `Tools.ImageParser.fetch_bbc_highres_image`. Limit to a small number to
                // avoid hammering article pages. This background pass is gated by the
                // PAPERBOY_ENABLE_BBC_EXTRACT feature flag.
                if (bbc_enabled) {
                    new Thread<void*>("bbc-image-upgrade", () => {
                        try {
                            int upgrades = 0;
                            foreach (var row in items) {
                                if (upgrades >= 8) break;
                                string? link = row[1];
                                string? thumb = row[2];
                                if (link == null) continue;
                                string link_l = link.down();
                                if ((link_l.contains("bbc.") || link_l.contains("bbci.co.uk"))) {
                                    // If there's no thumbnail or it looks like a tiny thumbnail, try upgrade
                                    if (thumb == null || thumb.length < 50) {
                                        Tools.ImageParser.fetch_bbc_highres_image(link, session, add_item, category_id, source_name);
                                        upgrades++;
                                    }
                                }
                            }
                        } catch (GLib.Error e) {
                        }
                        return null;
                    });
                }
        } catch (GLib.Error e) {
            warning("RSS parse/display error: %s", e.message);
        }
    }

    public static void fetch_rss_url(
        string url,
        string source_name,
        string category_name,
        string category_id,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        new Thread<void*>("fetch-rss", () => {
            try {
                var msg = new Soup.Message("GET", url);
                msg.request_headers.append("User-Agent", "news-vala-gnome/0.1");
                session.send_message(msg);
                if (msg.status_code != 200) {
                    warning("HTTP %u for RSS", msg.status_code);
                    return null;
                }
                string body = (string) msg.response_body.flatten().data;
                parse_rss_and_display(body, source_name, category_name, category_id, current_search_query, set_label, clear_items, add_item, session);
            } catch (GLib.Error e) {
                warning("RSS fetch error: %s", e.message);
            }
            return null;
        });
    }

    
}