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

// Removed xmlDisableEntityLoader binding: global state, not thread-safe, and unused.

// Bind xmlFreeDoc so we can reliably free parser allocations for Xml.Doc*
[CCode (cname = "xmlFreeDoc")]
private static extern void xml_free_doc (Xml.Doc* doc);

public class RssFeedProcessor {
    // Maximum items to parse from local news RSS feeds (prevents memory bloat from large feeds)
    // TODO: Make this configurable via preferences to allow power users to increase the limit
    // Currently hardcoded to prevent UI slowdowns, but users may want more items for archival feeds
    private const int LOCAL_FEED_MAX_ITEMS = 12;

    // Sanitize XML by removing invalid control characters and fixing encoding issues
    private static string sanitize_xml(string input) {
        var result = new StringBuilder();
        unowned string str = input;

        for (int i = 0; i < input.length; ) {
            unichar c;
            int prev_i = i;
            if (!input.get_next_char(ref i, out c)) {
                // Invalid UTF-8 sequence - skip this byte
                i = prev_i + 1;
                continue;
            }

            if (!c.validate()) {
                continue;
            }

            // Allow valid XML characters: Tab, LF, CR, printable chars
            if (c == 0x09 || c == 0x0A || c == 0x0D || c >= 0x20) {
                result.append_unichar(c);
            }
        }
        return result.str;
    }

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
        // SECURITY FIX: Do NOT use NOENT (it substitutes entities and can enable XXE/Billion-laughs).
        // Use NONET to forbid network access and disable entity substitution/DTD processing by
        // avoiding NOENT and enabling safe options instead.
        // NOCDATA: merge CDATA sections to text nodes
        // NOBLANKS: remove ignorable whitespace
        // RECOVER: try to recover from malformed XML where possible
        var parser_options = Xml.ParserOption.NONET | Xml.ParserOption.NOCDATA | Xml.ParserOption.NOBLANKS | Xml.ParserOption.RECOVER;
        Xml.Doc* doc = null;
        try {
            // Sanitize the body to remove invalid control characters and bad UTF-8
            string sanitized_body = sanitize_xml(body);
            doc = Xml.Parser.read_memory(
                sanitized_body,
                (int) sanitized_body.length,
                null,  // URL (not needed for memory parsing)
                "UTF-8",
                (int) parser_options
            );
            if (doc == null) {
                warning("RSS parse failed");
                return;
            }

            var items = new Gee.ArrayList<Gee.ArrayList<string?>>();
            // Respect runtime feature flag to enable/disable BBC-specific extraction/normalization.
            bool bbc_enabled = false;
            try { string? env = GLib.Environment.get_variable("PAPERBOY_ENABLE_BBC_EXTRACT"); if (env == null) bbc_enabled = true; else bbc_enabled = env != "0"; } catch (GLib.Error e) { bbc_enabled = true; }

            Xml.Node* root = doc->get_root_element();
            string? favicon_url = null;

            // Support Atom feeds where <entry> elements are direct children of the root <feed>
            if (root != null && root->type == Xml.ElementType.ELEMENT_NODE && root->name == "feed") {
                for (Xml.Node* it = root->children; it != null; it = it->next) {
                    if (it->type == Xml.ElementType.ELEMENT_NODE) {
                        if (it->name == "image") { // unlikely in Atom, but keep for parity
                            for (Xml.Node* img_child = it->children; img_child != null; img_child = img_child->next) {
                                if (img_child->type == Xml.ElementType.ELEMENT_NODE && img_child->name == "url") {
                                    favicon_url = img_child->get_content();
                                    break;
                                }
                            }
                        } else if (it->name == "link") {
                            Xml.Attr* rel_attr = null;
                            Xml.Attr* href_attr = null;
                            for (Xml.Attr* a = it->properties; a != null; a = a->next) {
                                if (a->name == "rel") rel_attr = a;
                                if (a->name == "href") href_attr = a;
                            }
                            if (rel_attr != null && rel_attr->children != null && (string)rel_attr->children->content == "icon" && href_attr != null && href_attr->children != null) {
                                favicon_url = (string)href_attr->children->content;
                            }
                        }

                        if (it->type == Xml.ElementType.ELEMENT_NODE && (it->name == "item" || it->name == "entry")) {
                            string? title = null;
                            string? link = null;
                            string? thumb = null;
                            for (Xml.Node* c = it->children; c != null; c = c->next) {
                                if (c->type != Xml.ElementType.ELEMENT_NODE) continue;
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
                                    if (link == null) link = c->get_content();
                                } else if (c->name == "enclosure") {
                                    Xml.Attr* a = c->properties;
                                    while (a != null) {
                                        if (a->name == "url") {
                                            thumb = a->children != null ? (string) a->children->content : null;
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
                                            if (thumb != null) {
                                                if (thumb.has_prefix("//")) thumb = "https:" + thumb;
                                            }
                                            break;
                                        }
                                        a2 = a2->next;
                                    }
                                } else if (c->name == "content" && c->ns != null && c->ns->prefix == "media") {
                                    Xml.Attr* a3 = c->properties;
                                    string? media_url = null;
                                    string? media_type = null;
                                    string? media_medium = null;
                                    while (a3 != null) {
                                        if (a3->name == "url") media_url = a3->children != null ? (string) a3->children->content : null;
                                        else if (a3->name == "type") media_type = a3->children != null ? (string) a3->children->content : null;
                                        else if (a3->name == "medium") media_medium = a3->children != null ? (string) a3->children->content : null;
                                        a3 = a3->next;
                                    }
                                    if (media_url != null && thumb == null) {
                                        bool is_image = false;
                                        if (media_type != null && media_type.has_prefix("image")) is_image = true;
                                        if (media_medium != null && media_medium == "image") is_image = true;
                                        string mu_lower = media_url.down();
                                        if (mu_lower.has_suffix(".jpg") || mu_lower.has_suffix(".jpeg") || mu_lower.has_suffix(".png") || mu_lower.has_suffix(".webp") || mu_lower.has_suffix(".gif")) is_image = true;
                                        if (!is_image && media_url.contains("images.wsj.net/im-")) is_image = true;
                                        if (is_image) thumb = media_url.has_prefix("//") ? "https:" + media_url : media_url;
                                    }
                                } else if (c->name == "description" && thumb == null) {
                                    string? desc = c->get_content();
                                    if (desc != null) thumb = Tools.ImageProcessor.extract_image_from_html_snippet(desc);
                                } else if (c->name == "content" && thumb == null) {
                                    // Atom <content type="html"> often contains HTML with <img>
                                    string? content_html = c->get_content();
                                    if (content_html != null) {
                                        thumb = Tools.ImageProcessor.extract_image_from_html_snippet(content_html);
                                        if (thumb != null && thumb.has_prefix("//")) thumb = "https:" + thumb;
                                    }
                                } else if (c->name == "summary" && thumb == null) {
                                    // Atom <summary> can also include an image snippet
                                    string? summary_html = c->get_content();
                                    if (summary_html != null) {
                                        thumb = Tools.ImageProcessor.extract_image_from_html_snippet(summary_html);
                                        if (thumb != null && thumb.has_prefix("//")) thumb = "https:" + thumb;
                                    }
                                } else if (c->name == "encoded" && c->ns != null && c->ns->prefix == "content" && thumb == null) {
                                    string? content = c->get_content();
                                    if (content != null) thumb = Tools.ImageProcessor.extract_image_from_html_snippet(content);
                                }
                            }

                            if (title != null && link != null) {
                                if (category_id == "local_news" && items.size >= LOCAL_FEED_MAX_ITEMS) {
                                    try { if (GLib.Environment.get_variable("PAPERBOY_DEBUG") != null) warning("rssFeedProcessor: local feed cap reached (%d): %s", LOCAL_FEED_MAX_ITEMS, source_name); } catch (GLib.Error e) { }
                                    continue;
                                }

                                var row = new Gee.ArrayList<string?>();
                                if (thumb != null && bbc_enabled) {
                                    string thumb_l = thumb.down();
                                    if (thumb_l.contains("bbc.") || thumb_l.contains("bbci.co.uk")) {
                                        string before = thumb;
                                        thumb = Tools.ImageProcessor.normalize_bbc_image_url(thumb);
                                        try { if (GLib.Environment.get_variable("PAPERBOY_DEBUG") != null) warning("rssFeedProcessor: normalized thumb %s -> %s", before, thumb); } catch (GLib.Error e) { }
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
            } else {
                // RSS-style parsing: look for <channel> or nested <feed> containers
                for (Xml.Node* ch = root->children; ch != null; ch = ch->next) {
                    if (ch->type == Xml.ElementType.ELEMENT_NODE && (ch->name == "channel" || ch->name == "feed")) {
                        for (Xml.Node* it = ch->children; it != null; it = it->next) {
                            if (it->type == Xml.ElementType.ELEMENT_NODE) {
                                if (it->name == "image") { // RSS 2.0 <image>
                                    for (Xml.Node* img_child = it->children; img_child != null; img_child = img_child->next) {
                                        if (img_child->type == Xml.ElementType.ELEMENT_NODE && img_child->name == "url") {
                                            favicon_url = img_child->get_content();
                                            break;
                                        }
                                    }
                                } else if (it->name == "link") { // Atom <link rel="icon"> or RSS 2.0 <link>
                                    Xml.Attr* rel_attr = null;
                                    Xml.Attr* href_attr = null;
                                    for (Xml.Attr* a = it->properties; a != null; a = a->next) {
                                        if (a->name == "rel") rel_attr = a;
                                        if (a->name == "href") href_attr = a;
                                    }
                                    if (rel_attr != null && rel_attr->children != null && (string)rel_attr->children->content == "icon" && href_attr != null && href_attr->children != null) {
                                        favicon_url = (string)href_attr->children->content;
                                    }
                                }
                            }

                            if (it->type == Xml.ElementType.ELEMENT_NODE && (it->name == "item" || it->name == "entry")) {
                                string? title = null;
                                string? link = null;
                                string? thumb = null;
                                for (Xml.Node* c = it->children; c != null; c = c->next) {
                                    if (c->type != Xml.ElementType.ELEMENT_NODE) continue;
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
                                        if (link == null) link = c->get_content();
                                    } else if (c->name == "enclosure") {
                                        Xml.Attr* a = c->properties;
                                        while (a != null) {
                                            if (a->name == "url") {
                                                thumb = a->children != null ? (string) a->children->content : null;
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
                                                if (thumb != null) {
                                                    if (thumb.has_prefix("//")) thumb = "https:" + thumb;
                                                }
                                                break;
                                            }
                                            a2 = a2->next;
                                        }
                                    } else if (c->name == "content" && c->ns != null && c->ns->prefix == "media") {
                                        Xml.Attr* a3 = c->properties;
                                        string? media_url = null;
                                        string? media_type = null;
                                        string? media_medium = null;
                                        while (a3 != null) {
                                            if (a3->name == "url") media_url = a3->children != null ? (string) a3->children->content : null;
                                            else if (a3->name == "type") media_type = a3->children != null ? (string) a3->children->content : null;
                                            else if (a3->name == "medium") media_medium = a3->children != null ? (string) a3->children->content : null;
                                            a3 = a3->next;
                                        }
                                        if (media_url != null && thumb == null) {
                                            bool is_image = false;
                                            if (media_type != null && media_type.has_prefix("image")) is_image = true;
                                            if (media_medium != null && media_medium == "image") is_image = true;
                                            string mu_lower = media_url.down();
                                            if (mu_lower.has_suffix(".jpg") || mu_lower.has_suffix(".jpeg") || mu_lower.has_suffix(".png") || mu_lower.has_suffix(".webp") || mu_lower.has_suffix(".gif")) is_image = true;
                                            if (!is_image && media_url.contains("images.wsj.net/im-")) is_image = true;
                                            if (is_image) thumb = media_url.has_prefix("//") ? "https:" + media_url : media_url;
                                        }
                                    } else if (c->name == "description" && thumb == null) {
                                        string? desc = c->get_content();
                                        if (desc != null) thumb = Tools.ImageProcessor.extract_image_from_html_snippet(desc);
                                    } else if (c->name == "content" && thumb == null) {
                                        string? content_html = c->get_content();
                                        if (content_html != null) {
                                            thumb = Tools.ImageProcessor.extract_image_from_html_snippet(content_html);
                                            if (thumb != null && thumb.has_prefix("//")) thumb = "https:" + thumb;
                                        }
                                    } else if (c->name == "summary" && thumb == null) {
                                        string? summary_html = c->get_content();
                                        if (summary_html != null) {
                                            thumb = Tools.ImageProcessor.extract_image_from_html_snippet(summary_html);
                                            if (thumb != null && thumb.has_prefix("//")) thumb = "https:" + thumb;
                                        }
                                    } else if (c->name == "encoded" && c->ns != null && c->ns->prefix == "content" && thumb == null) {
                                        string? content = c->get_content();
                                        if (content != null) thumb = Tools.ImageProcessor.extract_image_from_html_snippet(content);
                                    }
                                }

                                if (title != null && link != null) {
                                    if (category_id == "local_news" && items.size >= LOCAL_FEED_MAX_ITEMS) {
                                        try { if (GLib.Environment.get_variable("PAPERBOY_DEBUG") != null) warning("rssFeedProcessor: local feed cap reached (%d): %s", LOCAL_FEED_MAX_ITEMS, source_name); } catch (GLib.Error e) { }
                                        continue;
                                    }

                                    var row = new Gee.ArrayList<string?>();
                                    if (thumb != null && bbc_enabled) {
                                        string thumb_l = thumb.down();
                                        if (thumb_l.contains("bbc.") || thumb_l.contains("bbci.co.uk")) {
                                            string before = thumb;
                                            thumb = Tools.ImageProcessor.normalize_bbc_image_url(thumb);
                                            try { if (GLib.Environment.get_variable("PAPERBOY_DEBUG") != null) warning("rssFeedProcessor: normalized thumb %s -> %s", before, thumb); } catch (GLib.Error e) { }
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
            }

            // Update UI on main thread
            Idle.add(() => {
                if (current_search_query.length > 0) {
                    set_label(@"Search Results: \"$(current_search_query)\" in $(category_name) — $(source_name)");
                } else {
                    set_label(@"$(category_name) — $(source_name)");
                }

                clear_items();
                foreach (var row in items) {
                    string title = row[0] ?? "No title";
                    string url = row[1] ?? "";

                    // Filter by search query if provided (case-insensitive substring match)
                    if (current_search_query.length > 0) {
                        string query_lower = current_search_query.down();
                        string title_lower = title.down();
                        string url_lower = url.down();

                        if (!title_lower.contains(query_lower) && !url_lower.contains(query_lower)) {
                            continue;
                        }
                    }

                    add_item(title, url, row[2], category_id, source_name);
                }

                return false;
            });

            // Update favicon asynchronously in background thread to avoid SQLite lock contention
            // Don't block the main thread or article display for favicon updates
            if (category_id == "myfeed" && favicon_url != null && favicon_url.length > 0) {
                string captured_source_name = source_name;
                string captured_favicon = favicon_url;
                new Thread<void*>("favicon-update", () => {
                    try {
                        var rss_store = Paperboy.RssSourceStore.get_instance();
                        var all_sources = rss_store.get_all_sources();
                        foreach (var src in all_sources) {
                            if (src.name == captured_source_name) {
                                if (src.favicon_url == null || src.favicon_url.length == 0) {
                                    rss_store.update_favicon_url(src.url, captured_favicon);
                                }
                                break;
                            }
                        }
                    } catch (GLib.Error e) { }
                    return null;
                });
            }

            // Background: for BBC links, try to fetch higher-resolution images
            if (bbc_enabled) {
                AddItemFunc safe_add = (title, url, thumbnail, cid, sname) => {
                    Idle.add(() => { add_item(title, url, thumbnail, cid, sname); return false; });
                };

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
                                if (thumb == null || thumb.length < 50) {
                                    Tools.ImageProcessor.fetch_bbc_highres_image(link, session, safe_add, category_id, source_name);
                                    upgrades++;
                                }
                            }
                        }
                    } catch (GLib.Error e) { }
                    return null;
                });
            }

        } catch (GLib.Error e) {
            warning("RSS parse/display error: %s", e.message);
        } finally {
            if (doc != null) {
                xml_free_doc(doc);
            }
        }
    }

    // Remove a dead URL from the user's `local_feeds` list. This is best-effort
    // and will log warnings on failure. Kept as a static method so it can be
    // called from worker threads safely (it performs file I/O synchronously).
    private static void prune_local_feed(string bad_url) {
        try {
            string config_dir = GLib.Environment.get_user_config_dir() + "/paperboy";
            string file_path = config_dir + "/local_feeds";
            string contents = "";
            bool ok = false;
            try { ok = GLib.FileUtils.get_contents(file_path, out contents); } catch (GLib.Error ee) { contents = ""; ok = false; }
            if (!ok || contents == null) return;
            string[] lines = contents.split("\n");
            var kept = new Gee.ArrayList<string>();
            foreach (var l in lines) {
                string t = l.strip();
                if (t.length == 0) continue;
                if (t == bad_url) continue;
                kept.add(t);
            }
            string new_contents = "";
            foreach (var e in kept) new_contents += e + "\n";
            try { GLib.FileUtils.set_contents(file_path, new_contents); } catch (GLib.Error eee) { warning("Failed to update local_feeds: %s", eee.message); }
            warning("Pruned dead local feed: %s", bad_url);
        } catch (GLib.Error e) {
            warning("Error pruning local feed: %s", e.message);
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
            // Keep references to the provided callbacks for the lifetime
            // of this worker thread. Vala's generated closure refcounting
            // sometimes frees caller-side temporary delegates when the
            // caller's scope returns; holding explicit local references
            // in the thread ensures the delegates remain alive until the
            // thread completes and avoids use-after-free when the
            // callbacks are invoked later on the main loop.
            var _set_label_ref = set_label;
            var _clear_items_ref = clear_items;
            var _add_item_ref = add_item;
            try {

                // Basic validation: ensure the URL is a non-empty, sane string
                // (avoid passing malformed URLs into HttpClient which may return
                // errors or a null body that propagate back into FetchContext).
                string trimmed = url.strip();
                if (trimmed.length == 0) {
                    warning("RSS fetch called with empty URL for source '%s'", source_name);
                    try { set_label("Error loading feed — invalid (empty) URL"); } catch (GLib.Error e) { }
                    return null;
                }
                // Disallow obvious invalid schemes or whitespace in the URL.
                if (trimmed.contains(" ") || !(trimmed.has_prefix("http://") || trimmed.has_prefix("https://") || trimmed.has_prefix("file://"))) {
                    warning("RSS fetch called with malformed/unsupported URL for source '%s': %s", source_name, url);
                    try { set_label("Error loading feed — invalid URL"); } catch (GLib.Error e) { }
                    return null;
                }
                // Support local file:// feeds by reading the file directly
                if (url.has_prefix("file://")) {
                    try {
                        string path = url.substring(7);
                        var f = GLib.File.new_for_path(path);
                        if (!f.query_exists(null)) {
                            // File doesn't exist - trigger background regeneration
                            warning("Local RSS file not found, will need regeneration: %s", path);
                            try { set_label("Generating feed... (this may take 30-40 seconds)"); } catch (GLib.Error e) { }
                            // TODO: Trigger async regeneration here
                            // For now, just show an error since regeneration is handled by FeedUpdateManager
                            return null;
                        }
                        // Use FileUtils.get_contents to safely read the whole file into memory
                        string body = "";
                        bool ok = GLib.FileUtils.get_contents(path, out body);
                        if (!ok || body.length == 0) {
                            warning("Failed to read local RSS file: %s", path);
                            try { set_label("Failed to read local RSS file"); } catch (GLib.Error e) { }
                            return null;
                        }
                        parse_rss_and_display(body, source_name, category_name, category_id, current_search_query, set_label, clear_items, add_item, session);
                        return null;
                    } catch (GLib.Error e) {
                        warning("Error reading local RSS file: %s", e.message);
                        return null;
                    }
                }

                var client = Paperboy.HttpClientUtils.get_default();
                var http_response = client.fetch_sync(url, null);

                // Defensive handling for network-level failures (status_code == 0)
                if (http_response.status_code == 0) {
                    // Prefer the error message provided by the HttpClient (GLib.Error.message)
                    if (http_response.error_message != null && http_response.error_message.length > 0) {
                        // Surface DNS resolution failures more clearly
                        if (http_response.error_message.contains("Name or service not known") ||
                            http_response.error_message.contains("Temporary failure in name resolution") ||
                            http_response.error_message.contains("No address associated with hostname")) {
                            warning("Network/DNS error fetching RSS for '%s' (%s): %s", source_name, url, http_response.error_message);
                        } else {
                            warning("Network error fetching RSS for '%s' (%s): %s", source_name, url, http_response.error_message);
                        }
                    } else {
                        warning("Network error fetching RSS for '%s' (%s): unknown error", source_name, url);
                    }
                    try { set_label("Error loading feed — network/DNS error"); } catch (GLib.Error e) { }
                    if (category_id == "local_news") prune_local_feed(url);
                    return null;
                }

                if (!http_response.is_success()) {
                    warning("HTTP %u fetching RSS for '%s' (%s)", http_response.status_code, source_name, url);
                    try { set_label(("Error loading feed — HTTP %u").printf(http_response.status_code)); } catch (GLib.Error e) { }
                    if (category_id == "local_news") prune_local_feed(url);
                    return null;
                }

                if (http_response.body == null) {
                    warning("Empty response for RSS from '%s' (%s)", source_name, url);
                    try { set_label("Error loading feed — empty response"); } catch (GLib.Error e) { }
                    if (category_id == "local_news") prune_local_feed(url);
                    return null;
                }

                string body = http_response.get_body_string();
                parse_rss_and_display(body, source_name, category_name, category_id, current_search_query, set_label, clear_items, add_item, session);
            } catch (GLib.Error e) {
                warning("RSS fetch error: %s", e.message);
                try { set_label("Error loading feed"); } catch (GLib.Error _) { }
                if (category_id == "local_news") prune_local_feed(url);
            }
            // Drop our explicit references so they can be freed.
            _set_label_ref = null;
            _clear_items_ref = null;
            _add_item_ref = null;
            return null;
        });
    }


}
