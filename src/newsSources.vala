/*
 * Copyright (C) 2025  Isaac Joseph <calamityjoe87@gmail.com>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

using GLib;
using Tools;

public enum NewsSource {
    BBC,
    GUARDIAN,
    NEW_YORK_TIMES,
    WALL_STREET_JOURNAL,
    REDDIT,
    BLOOMBERG,
    REUTERS,
    NPR,
    FOX
}

public delegate void SetLabelFunc(string text);
public delegate void ClearItemsFunc();
public delegate void AddItemFunc(string title, string url, string? thumbnail_url, string category_id, string? source_name);

public class NewsSources {
    // Entry point
    public static void fetch(
        NewsSource source,
        string current_category,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        // Special handling: if the UI requested the unified "frontpage",
        // fetch aggregated frontpage articles from our Paperboy backend API.
        if (current_category == "frontpage") {
            fetch_paperboy_frontpage(current_search_query, session, set_label, clear_items, add_item);
            return;
        }
        // Special handling: if the UI requested "Top Ten",
        // fetch top headlines from our Paperboy backend API.
        if (current_category == "topten") {
            fetch_paperboy_topten(current_search_query, session, set_label, clear_items, add_item);
            return;
        }
        // Handle "all" category by fetching from multiple categories for other sources
        if (current_category == "all") {
            fetch_all_categories(source, current_search_query, session, set_label, clear_items, add_item);
            return;
        }
        switch (source) {
            case NewsSource.GUARDIAN:
                fetch_guardian(current_category, current_search_query, session, set_label, clear_items, add_item);
                break;
            case NewsSource.WALL_STREET_JOURNAL:
                fetch_wsj(current_category, current_search_query, session, set_label, clear_items, add_item);
                break;
            case NewsSource.REDDIT:
                fetch_reddit(current_category, current_search_query, session, set_label, clear_items, add_item);
                break;
            case NewsSource.BBC:
                fetch_bbc(current_category, current_search_query, session, set_label, clear_items, add_item);
                break;
            case NewsSource.NEW_YORK_TIMES:
                fetch_nyt(current_category, current_search_query, session, set_label, clear_items, add_item);
                break;
            case NewsSource.BLOOMBERG:
                fetch_bloomberg(current_category, current_search_query, session, set_label, clear_items, add_item);
                break;
            case NewsSource.REUTERS:
                fetch_reuters(current_category, current_search_query, session, set_label, clear_items, add_item);
                break;
            case NewsSource.NPR:
                fetch_npr(current_category, current_search_query, session, set_label, clear_items, add_item);
                break;
            case NewsSource.FOX:
                fetch_fox(current_category, current_search_query, session, set_label, clear_items, add_item);
                break;
        }
    }

    // Fetch mixed news from all categories
    private static void fetch_all_categories(
        NewsSource source,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        string source_name = get_source_name(source);
        if (current_search_query.length > 0) {
            set_label(@"Search Results: \"$(current_search_query)\" in All Categories — $(source_name)");
        } else {
            set_label(@"All Categories — $(source_name)");
        }
        clear_items();

        // Better randomization: shuffle categories and select a random subset
        string[] all_categories = { "general", 
                                    "technology", 
                                    "us", 
                                    "science", 
                                    "sports", 
                                    "health", 
                                    "entertainment", 
                                    "politics", 
                                    "lifestyle" };

    // If the selected source is Bloomberg, restrict "All Categories" to Bloomberg's available categories
        if (source == NewsSource.BLOOMBERG) {
            all_categories = new string[] { "markets", 
                                            "industries", 
                                            "economics", 
                                            "wealth", 
                                            "green", 
                                            "politics", 
                                            "technology" };
        }
        
        // Shuffle the categories array for random order
        for (int i = all_categories.length - 1; i > 0; i--) {
            int j = Random.int_range(0, i + 1);
            string temp = all_categories[i];
            all_categories[i] = all_categories[j];
            all_categories[j] = temp;
        }
        
        // Select 5-7 categories randomly (not all 9 every time)
        int num_categories = Random.int_range(5, 8);
        string[] selected_categories = new string[num_categories];
        for (int i = 0; i < num_categories; i++) {
            selected_categories[i] = all_categories[i];
        }

        foreach (string category in selected_categories) {
            // Copy loop variable into a local so each timeout closure captures
            // its own category (avoids the common closure-capture bug).
            string cat = category;
            // Use more varied delays between requests (200ms to 2 seconds)
            Timeout.add(Random.int_range(200, 2000), () => {
                switch (source) {
                    case NewsSource.GUARDIAN:
                        fetch_guardian(category, current_search_query, session, 
                            (text) => { /* Keep "All Categories" label */ },
                            () => { /* Don't clear items */ }, 
                            add_item);
                        break;
                    case NewsSource.WALL_STREET_JOURNAL:
                        fetch_google_domain(category, current_search_query, session, 
                            (text) => { /* Keep "All Categories" label */ },
                            () => { /* Don't clear items */ }, 
                            add_item, "wsj.com", "Wall Street Journal");
                        break;
                    case NewsSource.REDDIT:
                        fetch_reddit(category, current_search_query, session, 
                            (text) => { /* Keep "All Categories" label */ },
                            () => { /* Don't clear items */ }, 
                            add_item);
                        break;
                    case NewsSource.BBC:
                        fetch_bbc(category, current_search_query, session, 
                            (text) => { /* Keep "All Categories" label */ },
                            () => { /* Don't clear items */ }, 
                            add_item);
                        break;
                    case NewsSource.NEW_YORK_TIMES:
                        fetch_nyt(category, current_search_query, session, 
                            (text) => { /* Keep "All Categories" label */ },
                            () => { /* Don't clear items */ }, 
                            add_item);
                        break;
                    case NewsSource.BLOOMBERG:
                        // For Bloomberg prefer dedicated feed fetching so categories
                        // match Bloomberg's available sections instead of a generic
                        // Google site search.
                        fetch_bloomberg(cat, current_search_query, session,
                            (text) => { /* Keep "All Categories" label */ },
                            () => { /* Don't clear items */ },
                            add_item);
                        break;
                    case NewsSource.REUTERS:
                        fetch_reuters(category, current_search_query, session, 
                            (text) => { /* Keep "All Categories" label */ },
                            () => { /* Don't clear items */ }, 
                            add_item);
                        break;
                    case NewsSource.NPR:
                        fetch_npr(category, current_search_query, session, 
                            (text) => { /* Keep "All Categories" label */ },
                            () => { /* Don't clear items */ }, 
                            add_item);
                        break;
                    case NewsSource.FOX:
                        fetch_fox(category, current_search_query, session, 
                            (text) => { /* Keep "All Categories" label */ },
                            () => { /* Don't clear items */ }, 
                            add_item);
                        break;
                }
                return false; // Don't repeat the timeout
            });
        }
    }

    // Fetch the unified "frontpage" from the Paperboy backend API.
    // The backend is expected to return a JSON array of article objects or
    // an object with an "articles" array. We tolerate a few common field
    // names when mapping into the UI (title, url/link, thumbnail/image).
    private static void fetch_paperboy_frontpage(
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        new Thread<void*>("fetch-frontpage-api", () => {
            try {
                string base_url = "https://paperboybackend.onrender.com";
                string url = base_url + "/news/frontpage";
                var msg = new Soup.Message("GET", url);
                msg.request_headers.append("User-Agent", "paperboy/0.1");
                session.send_message(msg);
                if (msg.status_code != 200) {
                    warning("Paperboy API HTTP error: %u", msg.status_code);
                    Idle.add(() => {
                        set_label("Paperboy: Error loading frontpage");
                        return false;
                    });
                    return null;
                }
                string body = (string) msg.response_body.flatten().data;

                var parser = new Json.Parser();
                parser.load_from_data(body);
                var root = parser.get_root();

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
                    // Unexpected response shape
                    return null;
                }

                // Note: do simple substring filtering for search queries (case-sensitive).

                Idle.add(() => {
                    if (current_search_query.length > 0) {
                        set_label(@"Search Results: \"$(current_search_query)\" in The Frontpage — Paperboy");
                    } else {
                        set_label("The Frontpage — Paperboy");
                    }
                    clear_items();
                    uint len = articles.get_length();
                    for (uint i = 0; i < len; i++) {
                        var art = articles.get_element(i).get_object();
                            string title = json_get_string_safe(art, "title") != null ? json_get_string_safe(art, "title") : (json_get_string_safe(art, "headline") != null ? json_get_string_safe(art, "headline") : "No title");
                            string article_url = json_get_string_safe(art, "url") != null ? json_get_string_safe(art, "url") : (json_get_string_safe(art, "link") != null ? json_get_string_safe(art, "link") : "");
                            string? thumbnail = null;
                            if (json_get_string_safe(art, "thumbnail") != null) thumbnail = json_get_string_safe(art, "thumbnail");
                            else if (json_get_string_safe(art, "image") != null) thumbnail = json_get_string_safe(art, "image");
                            else if (json_get_string_safe(art, "image_url") != null) thumbnail = json_get_string_safe(art, "image_url");
                            // Prefer a nested `source` object when present (many backends
                            // return provider metadata there). Fall back to the old
                            // top-level fields for compatibility.
                            string source_name = "Paperboy API";
                            string? logo_url = null;
                            string provider_key = "";
                            string? provider_url = null;
                            if (art.has_member("source")) {
                                var src_node = art.get_member("source");
                                if (src_node != null && src_node.get_node_type() == Json.NodeType.OBJECT) {
                                    var src_obj = src_node.get_object();
                                    // typical fields: name, title, url, logo_url, id
                                    string? n = json_get_string_safe(src_obj, "name");
                                    if (n == null) n = json_get_string_safe(src_obj, "title");
                                    if (n != null) source_name = n;
                                    // pick a provider key when available (prefer explicit `id`)
                                    string? sid = json_get_string_safe(src_obj, "id");
                                    if (sid != null && sid.length > 0) provider_key = sid;
                                    else if (n != null && n.length > 0) provider_key = n;
                                    // logo fields on the nested source object
                                    if (json_get_string_safe(src_obj, "logo_url") != null) logo_url = json_get_string_safe(src_obj, "logo_url");
                                    else if (json_get_string_safe(src_obj, "logo") != null) logo_url = json_get_string_safe(src_obj, "logo");
                                    else if (json_get_string_safe(src_obj, "favicon") != null) logo_url = json_get_string_safe(src_obj, "favicon");
                                    // Capture provider URL when present and use it as a
                                    // hint for display name if the provider didn't
                                    // supply an explicit name.
                                    string? provurl = json_get_string_safe(src_obj, "url");
                                    if (provurl != null) {
                                        provider_url = provurl;
                                        if (source_name == null || source_name.length == 0) {
                                            string inferred = infer_display_name_from_url(provurl);
                                            if (inferred.length > 0) source_name = inferred;
                                        }
                                    }
                                } else {
                                    // `source` exists but is not an object: try as string
                                    string? s = json_get_string_safe(art, "source");
                                    if (s != null) source_name = s;
                                    if (source_name != null) provider_key = source_name;
                                }
                            } else {
                                // legacy/top-level provider fields
                                if (json_get_string_safe(art, "source") != null) source_name = json_get_string_safe(art, "source");
                                else if (json_get_string_safe(art, "provider") != null) source_name = json_get_string_safe(art, "provider");
                                if (source_name != null) provider_key = source_name;
                            }

                            // If backend returned a generic placeholder (or nothing),
                            // try to infer a sensible display name from the article URL
                            if (source_name == null || source_name.length == 0 || source_name == "Paperboy API") {
                                string inferred = infer_display_name_from_url(article_url);
                                if (inferred != null && inferred.length > 0) source_name = inferred;
                            }

                            // Also check for logo fields at the article root if not found
                            if (logo_url == null) {
                                if (json_get_string_safe(art, "logo") != null) logo_url = json_get_string_safe(art, "logo");
                                else if (json_get_string_safe(art, "favicon") != null) logo_url = json_get_string_safe(art, "favicon");
                                else if (json_get_string_safe(art, "logo_url") != null) logo_url = json_get_string_safe(art, "logo_url");
                                else if (json_get_string_safe(art, "site_icon") != null) logo_url = json_get_string_safe(art, "site_icon");
                            }

                        // Normalize common forms returned by various backends:
                        // - protocol-relative URLs (//example.com/foo.png) -> https://example.com/foo.png
                        // - trim whitespace
                        if (logo_url != null) {
                            logo_url = logo_url.strip();
                            if (logo_url.has_prefix("//")) {
                                // Prefer https for protocol-relative assets
                                logo_url = "https:" + logo_url;
                            }
                        }

                        // If we were able to derive a provider key/display-name and
                        // the backend supplied a logo URL, record it into the
                        // canonical index and start a background fetch to ensure
                        // the canonical filename exists under user data.
                        try {
                            if (provider_key.length > 0 && logo_url != null && logo_url.length > 0) {
                                SourceLogos.update_index_and_fetch(provider_key, source_name, logo_url, provider_url, session);
                            }
                        } catch (GLib.Error e) { }

                        // If we have a logo URL, encode it into the source_name using
                        // a small delimiter so the UI can detect and download/cache it.
                        // Format: "Display Name||<logo_url>". This avoids changing the
                        // AddItemFunc signature across the codebase.
                        string display_source = source_name;
                        if (logo_url != null && logo_url.length > 0) {
                            display_source = source_name + "||" + logo_url;
                        }

                        // Extract per-article category/type from the JSON when provided
                        // so frontpage items can show the real category chip instead of
                        // a generic "frontpage" label. We try several common field
                        // names returned by different backends and normalize the
                        // resulting string into a slug-like id (lowercase, underscores).
                        string category_id = "frontpage";
                        string? cat_raw = null;
                        // Helper to extract a string from a possible VALUE or OBJECT node
                        // (object may contain id/slug/name fields).
                        string? extract_from_node(Json.Node? node) {
                            if (node == null) return null;
                            try {
                                if (node.get_node_type() == Json.NodeType.VALUE) {
                                    try { return node.get_string(); } catch (GLib.Error e) { return null; }
                                } else if (node.get_node_type() == Json.NodeType.OBJECT) {
                                    var o = node.get_object();
                                    // Try common fields in order of preference
                                    string? v = json_get_string_safe(o, "id");
                                    if (v != null) return v;
                                    v = json_get_string_safe(o, "slug");
                                    if (v != null) return v;
                                    v = json_get_string_safe(o, "name");
                                    if (v != null) return v;
                                    // some providers use 'title'
                                    v = json_get_string_safe(o, "title");
                                    if (v != null) return v;
                                }
                            } catch (GLib.Error e) { }
                            return null;
                        }

                        // Try common simple members first
                        if (art.has_member("category")) cat_raw = extract_from_node(art.get_member("category"));
                        if (cat_raw == null && art.has_member("section")) cat_raw = extract_from_node(art.get_member("section"));
                        if (cat_raw == null && art.has_member("type")) cat_raw = extract_from_node(art.get_member("type"));
                        if (cat_raw == null && art.has_member("category_id")) cat_raw = extract_from_node(art.get_member("category_id"));

                        // If there's a tags array, inspect its first element (may be VALUE or OBJECT)
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
                            // Normalize to a simple slug: lowercase, spaces/dashes -> underscore
                            string s_raw = (string) cat_raw;
                            category_id = s_raw.down().replace(" ", "_").replace("-", "_").strip();
                        }

                        // Debug trace removed: avoid writing to disk during frontpage parsing.

                        if (current_search_query.length > 0) {
                            if (!title.contains(current_search_query) && !article_url.contains(current_search_query)) continue;
                        }

                        // Debug trace removed.

                        // Encode the detected category into the display_source so the UI
                        // can show the real category label while we still pass the
                        // special "frontpage" view token to `add_item` (keeps
                        // filtering/placement logic unchanged).
                        if (display_source == null) display_source = "";
                        display_source = display_source + "##category::" + category_id;

                        add_item(title, article_url, thumbnail, "frontpage", display_source);
                    }
                    return false;
                });
            } catch (GLib.Error e) { warning("Paperboy frontpage fetch error: %s", e.message); }
            return null;
        });
    }

    // Fetch the "Top Ten" headlines from the Paperboy backend API.
    // Same structure as frontpage but from /news/headlines endpoint.
    private static void fetch_paperboy_topten(
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        new Thread<void*>("fetch-topten-api", () => {
            try {
                string base_url = "https://paperboybackend.onrender.com";
                string url = base_url + "/news/headlines";
                var msg = new Soup.Message("GET", url);
                msg.request_headers.append("User-Agent", "paperboy/0.1");
                session.send_message(msg);
                if (msg.status_code != 200) {
                    warning("Paperboy API HTTP error: %u", msg.status_code);
                    Idle.add(() => {
                        set_label("Paperboy: Error loading Top Ten");
                        return false;
                    });
                    return null;
                }
                string body = (string) msg.response_body.flatten().data;

                var parser = new Json.Parser();
                parser.load_from_data(body);
                var root = parser.get_root();

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
                    return null;
                }

                Idle.add(() => {
                    set_label("Top Ten — Paperboy");
                    clear_items();
                    uint len = articles.get_length();
                    
                    // Track seen URLs to skip duplicates (backend sometimes sends duplicate articles)
                    var seen_urls = new Gee.HashSet<string>();
                    int added_count = 0;
                    
                    for (uint i = 0; i < len && added_count < 10; i++) {
                        var art = articles.get_element(i).get_object();
                        string title = json_get_string_safe(art, "title") != null ? json_get_string_safe(art, "title") : (json_get_string_safe(art, "headline") != null ? json_get_string_safe(art, "headline") : "No title");
                        string article_url = json_get_string_safe(art, "url") != null ? json_get_string_safe(art, "url") : (json_get_string_safe(art, "link") != null ? json_get_string_safe(art, "link") : "");
                        string? thumbnail = null;
                        if (json_get_string_safe(art, "thumbnail") != null) thumbnail = json_get_string_safe(art, "thumbnail");
                        else if (json_get_string_safe(art, "image") != null) thumbnail = json_get_string_safe(art, "image");
                        else if (json_get_string_safe(art, "image_url") != null) thumbnail = json_get_string_safe(art, "image_url");
                        
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

                        try {
                            if (provider_key.length > 0 && logo_url != null && logo_url.length > 0) {
                                SourceLogos.update_index_and_fetch(provider_key, source_name, logo_url, provider_url, session);
                            }
                        } catch (GLib.Error e) { }

                        string display_source = source_name;
                        if (logo_url != null && logo_url.length > 0) {
                            display_source = source_name + "||" + logo_url;
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

                        if (display_source == null) display_source = "";
                        display_source = display_source + "##category::" + category_id;

                        // Skip duplicates based on URL
                        if (seen_urls.contains(article_url)) {
                            continue;
                        }
                        seen_urls.add(article_url);
                        
                        add_item(title, article_url, thumbnail, "topten", display_source);
                        added_count++;
                    }
                    return false;
                });
            } catch (GLib.Error e) { warning("Paperboy Top Ten fetch error: %s", e.message); }
            return null;
        });
    }

    // Helpers
    // Utility to strip HTML tags from a string (moved here to live with other helpers)
    private static string strip_html(string input) {
        // Remove all tags
        var regex = new Regex("<[^>]+>", RegexCompileFlags.DEFAULT);
        return regex.replace(input, -1, 0, "");
    }

    // Safe JSON string accessor: returns null when the member is missing,
    // not a JSON value node, or when the node cannot be converted to a string.
    // Avoids using Json.Value/GLib.Value helpers which vary across vapi
    // versions; instead rely on Json.Node API and a guarded call to get_string().
    private static string? json_get_string_safe(Json.Object obj, string member) {
        try {
            if (!obj.has_member(member)) return null;
            var node = obj.get_member(member);
            if (node == null) return null;
            if (node.get_node_type() != Json.NodeType.VALUE) return null;
            // Json.Node.get_string() will throw if the value isn't a string,
            // so guard it with try/catch and return null on error.
            try {
                return node.get_string();
            } catch (GLib.Error e) {
                return null;
            }
        } catch (GLib.Error e) {
            return null;
        }
    }
    // Infer a friendly display name from an article URL when the backend
    // does not provide a meaningful provider name. This uses the host
    // portion of the URL (stripping www and ports) and turns label parts
    // into Title Case (e.g. "nytimes" -> "Nytimes", "the-guardian" -> "The Guardian").
    private static string infer_display_name_from_url(string? url) {
        if (url == null) return "Paperboy";
        string u = url.strip();
        if (u.length == 0) return "Paperboy";
        // Remove scheme if present
        int pos = u.index_of("://");
    if (pos >= 0) u = u.substring(pos + 3);
        // Remove path
    int slash = u.index_of("/");
    if (slash >= 0) u = u.substring(0, slash);
        // Remove port
    int colon = u.index_of(":");
    if (colon >= 0) u = u.substring(0, colon);
        // Strip common www prefix
    if (u.has_prefix("www.")) u = u.substring(4);
        if (u.length == 0) return "Paperboy";
    string[] parts = u.split(".");
        string label = parts.length > 0 ? parts[0] : u;
        label = label.replace("-", " ").replace("_", " ");
        string[] words = label.split(" ");
        string out = "";
        for (int i = 0; i < words.length; i++) {
            string w = words[i].strip();
            if (w.length == 0) continue;
            // Upper-case the first character (ASCII only) and keep the rest as-is
            string head = w.substring(0, 1);
            string tail = w.length > 1 ? w.substring(1) : "";
            if (out.length > 0) out += " ";
            out += head + tail;
        }
        if (out.length == 0) out = u;
        return out;
    }
    private static string category_display_name(string cat) {
        switch (cat) {
            case "frontpage": return "The Frontpage";
            case "myfeed": return "My Feed";
            case "general": return "World News";
            case "us": return "US News";
            case "technology": return "Technology";
            case "business": return "Business";
            case "markets": return "Markets";
            case "industries": return "Industries";
            case "economics": return "Economics";
            case "wealth": return "Wealth";
            case "green": return "Green";
            case "science": return "Science";
            case "sports": return "Sports";
            case "health": return "Health";
            case "entertainment": return "Entertainment";
            case "politics": return "Politics";
            case "lifestyle": return "Lifestyle";
        }
        return "News";
    }

    private static string get_source_name(NewsSource source) {
        switch (source) {
            case NewsSource.GUARDIAN:
                return "The Guardian";
            case NewsSource.WALL_STREET_JOURNAL:
                return "Wall Street Journal";
            case NewsSource.BBC:
                return "BBC News";
            case NewsSource.REDDIT:
                return "Reddit";
            case NewsSource.NEW_YORK_TIMES:
                return "New York Times";
            case NewsSource.BLOOMBERG:
                return "Bloomberg";
            case NewsSource.REUTERS:
                return "Reuters";
            case NewsSource.NPR:
                return "NPR";
            case NewsSource.FOX:
                return "Fox News";
            default:
                return "News";
        }
    }

    // Return whether a given NewsSource can provide articles for the
    // requested category. This is used by the UI when multiple sources are
    // selected: if a category (e.g. "markets") is chosen that some sources
    // don't support (Bloomberg-specific sections), we exclude those sources
    // from the multi-source fetch so only compatible sources are queried.
    public static bool supports_category(NewsSource source, string category) {
        // Only Bloomberg needs special handling: it exposes a narrower set
        // of dedicated sections. All other sources can be considered to
        // support the common categories (and many use site-search fallbacks).
        // BBC, Reddit, and Reuters do not provide dedicated "lifestyle" content;
        // hide that category for these sources so the UI won't show it.
        if (source == NewsSource.BBC || source == NewsSource.REDDIT || source == NewsSource.REUTERS) {
            if (category == "lifestyle") return false;
        }

        if (source == NewsSource.BLOOMBERG) {
            switch (category) {
                case "markets":
                case "industries":
                case "economics":
                case "wealth":
                case "green":
                case "politics":
                case "technology":
                    return true;
                default:
                    return false;
            }
        }
        return true;
    }


    private static void fetch_google_domain(
        string current_category,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item,
        string domain,
        string source_name
    ) {
        string base_url = "https://news.google.com/rss/search";
        string ceid = "hl=en-US&gl=US&ceid=US:en";
        string category_name = category_display_name(current_category);
        string query = @"site:$(domain)";
        if (current_search_query.length > 0) {
            query = query + " " + current_search_query;
        }
        string url = @"$(base_url)?q=$(Uri.escape_string(query))&$(ceid)";
        
        RssParser.fetch_rss_url(url, source_name, category_name, current_category, current_search_query, session, set_label, clear_items, add_item);
    }

    private static void fetch_nyt(
        string current_category,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        string base_url = "https://rss.nytimes.com/services/xml/rss/nyt/";
        string path = "World.xml";
        switch (current_category) {
            case "us":
                path = "US.xml";
                break;
            case "technology":
                path = "Technology.xml";
                break;
            case "business":
                path = "business.xml";
                break;
            case "science":
                path = "Science.xml";
                break;
            case "sports":
                path = "Sports.xml";
                break;
            case "health":
                path = "Health.xml";
                break;
            case "politics":
            case "entertainment":
            case "lifestyle":
                // Use Google site search for reliable category coverage
                fetch_google_domain(current_category, current_search_query, session, set_label, clear_items, add_item, "nytimes.com", "New York Times");
                return;
            default:
                path = "World.xml";
                break;
        }
        if (current_search_query.length > 0) {
            fetch_google_domain(current_category, current_search_query, session, set_label, clear_items, add_item, "nytimes.com", "New York Times");
            return;
        }
    RssParser.fetch_rss_url(@"$(base_url)$(path)", "New York Times", category_display_name(current_category), current_category, current_search_query, session, set_label, clear_items, add_item);
    }

    private static void fetch_bbc(
        string current_category,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        string url = "https://feeds.bbci.co.uk/news/world/rss.xml";
        switch (current_category) {
            case "technology":
                url = "https://feeds.bbci.co.uk/news/technology/rss.xml";
                break;
            case "business":
                url = "https://feeds.bbci.co.uk/news/business/rss.xml";
                break;
            case "science":
                url = "https://feeds.bbci.co.uk/news/science_and_environment/rss.xml";
                break;
            case "sports":
                url = "https://feeds.bbci.co.uk/sport/rss.xml";
                break;
            case "health":
                url = "https://feeds.bbci.co.uk/news/health/rss.xml";
                break;
            case "us":
                url = "https://feeds.bbci.co.uk/news/world/us_and_canada/rss.xml";
                break;
            case "politics":
                url = "https://feeds.bbci.co.uk/news/politics/rss.xml";
                break;
            case "entertainment":
                url = "https://feeds.bbci.co.uk/news/entertainment_and_arts/rss.xml";
                break;
            // Note: BBC does not have a dedicated "lifestyle" RSS feed. The
            // UI will not show "lifestyle" for BBC (see supports_category),
            // so we avoid attempting a site-search fallback here.
            default:
                url = "https://feeds.bbci.co.uk/news/world/rss.xml";
                break;
        }
    RssParser.fetch_rss_url(url, "BBC News", category_display_name(current_category), current_category, current_search_query, session, set_label, clear_items, add_item);
    }

    private static void fetch_guardian(
        string current_category,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        new Thread<void*>("fetch-news", () => {
            try {
                // No article cache: always fetch fresh Guardian API results
                string base_url = "https://content.guardianapis.com/search?show-fields=thumbnail&page-size=30&api-key=test";
                string url;
                switch (current_category) {
                    case "us":
                        url = base_url + "&section=us-news";
                        break;
                    case "technology":
                        url = base_url + "&section=technology";
                        break;
                    case "business":
                        url = base_url + "&section=business";
                        break;
                    case "science":
                        url = base_url + "&section=science";
                        break;
                    case "sports":
                        url = base_url + "&section=sport";
                        break;
                    case "health":
                        url = base_url + "&tag=society/health";
                        break;
                    case "politics":
                        url = base_url + "&section=politics";
                        break;
                    case "entertainment":
                        url = base_url + "&section=culture";
                        break;
                    case "lifestyle":
                        url = base_url + "&section=lifeandstyle";
                        break;
                    case "general":
                    default:
                        url = base_url + "&section=world";
                        break;
                }
                if (current_search_query.length > 0) {
                    url = url + "&q=" + Uri.escape_string(current_search_query);
                }
                var msg = new Soup.Message("GET", url);
                msg.request_headers.append("User-Agent", "paperboy/0.1");
                session.send_message(msg);
                if (msg.status_code != 200) {
                    warning("HTTP error: %u", msg.status_code);
                    return null;
                }
                string body = (string) msg.response_body.flatten().data;
                // No article cache in this build; just proceed with parsing and UI update

                var parser = new Json.Parser();
                parser.load_from_data(body);
                var root = parser.get_root();
                var data = root.get_object();
                if (!data.has_member("response")) {
                    return null;
                }
                var response = data.get_object_member("response");
                if (!response.has_member("results")) {
                    return null;
                }
                var results = response.get_array_member("results");

                string category_name = category_display_name(current_category);
                Idle.add(() => {
                    if (current_search_query.length > 0) {
                        set_label(@"Search Results: \"$(current_search_query)\" in $(category_name) — The Guardian");
                    } else {
                        set_label(@"$(category_name) — The Guardian");
                    }
                    uint len = results.get_length();
                    for (uint i = 0; i < len; i++) {
                        var article = results.get_element(i).get_object();
                        var title = article.has_member("webTitle") ? article.get_string_member("webTitle") : "No title";
                        var article_url = article.has_member("webUrl") ? article.get_string_member("webUrl") : "";
                        string? thumbnail = null;
                        if (article.has_member("fields")) {
                            var fields = article.get_object_member("fields");
                            if (fields.has_member("thumbnail")) {
                                thumbnail = fields.get_string_member("thumbnail");
                            }
                        }
                        add_item(title, article_url, thumbnail, current_category, "The Guardian");
                    }
                    // Attempt to fetch higher-quality images (OG images) for Guardian articles
                    fetch_guardian_article_images(results, session, add_item, current_category);
                    return false;
                });
            } catch (GLib.Error e) { warning("Fetch error: %s", e.message); }
            return null;
        });
    }

    private static void fetch_reddit(
        string current_category,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        new Thread<void*>("fetch-news", () => {
            try {
                string subreddit = "";
                string category_name = "";
                switch (current_category) {
                    case "general":
                        subreddit = "worldnews";
                        category_name = "World News";
                        break;
                    case "us":
                        subreddit = "news";
                        category_name = "US News";
                        break;
                    case "technology":
                        subreddit = "technology";
                        category_name = "Technology";
                        break;
                    case "business":
                        subreddit = "business";
                        category_name = "Business";
                        break;
                    case "science":
                        subreddit = "science";
                        category_name = "Science";
                        break;
                    case "sports":
                        subreddit = "sports";
                        category_name = "Sports";
                        break;
                    case "health":
                        subreddit = "health";
                        category_name = "Health";
                        break;
                    case "entertainment":
                        subreddit = "entertainment";
                        category_name = "Entertainment";
                        break;
                    case "politics":
                        subreddit = "politics";
                        category_name = "Politics";
                        break;
                    case "lifestyle":
                        subreddit = "lifestyle";
                        category_name = "Lifestyle";
                        break;
                    default:
                        subreddit = "worldnews";
                        category_name = "World News";
                        break;
                }
                string url = @"https://www.reddit.com/r/$(subreddit)/hot.json?limit=30";
                if (current_search_query.length > 0) {
                    url = @"https://www.reddit.com/r/$(subreddit)/search.json?q=$(Uri.escape_string(current_search_query))&restrict_sr=1&limit=30";
                }
                var msg = new Soup.Message("GET", url);
                msg.request_headers.append("User-Agent", "paperboy/0.1");
                session.send_message(msg);
                if (msg.status_code != 200) {
                    warning("HTTP error: %u", msg.status_code);
                    return null;
                }
                string body = (string) msg.response_body.flatten().data;

                var parser = new Json.Parser();
                parser.load_from_data(body);
                var root = parser.get_root();
                var data = root.get_object();
                if (!data.has_member("data")) {
                    return null;
                }
                var data_obj = data.get_object_member("data");
                if (!data_obj.has_member("children")) {
                    return null;
                }
                var children = data_obj.get_array_member("children");

                Idle.add(() => {
                    if (current_search_query.length > 0) {
                        set_label(@"Search Results: \"$(current_search_query)\" in $(category_name)");
                    } else {
                        set_label(category_name);
                    }
                    uint len = children.get_length();
                    for (uint i = 0; i < len; i++) {
                        var post = children.get_element(i).get_object();
                        var post_data = post.get_object_member("data");
                        var title = post_data.has_member("title") ? post_data.get_string_member("title") : "No title";
                        var post_url = post_data.has_member("url") ? post_data.get_string_member("url") : "";
                        string? thumbnail = null;
                        
                        // Try to get high-quality preview image first
                        if (post_data.has_member("preview")) {
                            var preview = post_data.get_object_member("preview");
                            if (preview.has_member("images")) {
                                var images = preview.get_array_member("images");
                                if (images.get_length() > 0) {
                                    var first_image = images.get_element(0).get_object();
                                    if (first_image.has_member("source")) {
                                        var source = first_image.get_object_member("source");
                                        if (source.has_member("url")) {
                                            string preview_url = source.get_string_member("url");
                                            // Decode HTML entities in URL
                                            thumbnail = preview_url.replace("&amp;", "&");
                                        }
                                    }
                                }
                            }
                        }
                        
                        // Fallback to thumbnail if no preview available
                        if (thumbnail == null && post_data.has_member("thumbnail")) {
                            string thumb = post_data.get_string_member("thumbnail");
                            if (thumb.has_prefix("http") && thumb != "default" && thumb != "self" && thumb != "nsfw") {
                                thumbnail = thumb;
                            }
                        }
                        
                        add_item(title, post_url, thumbnail, current_category, "Reddit");
                    }
                    return false;
                });
            } catch (GLib.Error e) {
                warning("Fetch error: %s", e.message);
            }
            return null;
        });
    }

    private static void fetch_reuters(
        string current_category,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        // Reuters RSS feeds require authentication, so use Google News site search
        // Reuters also doesn't provide images for its RSS feed.
        fetch_google_domain(current_category, current_search_query, session, set_label, clear_items, add_item, "reuters.com", "Reuters");
    }

    // Bloomberg doesn't present tradional news (i.e. doesn't have regular feeds). That's ok, let's just present the categories they do have.
    private static void fetch_bloomberg(
        string current_category,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        if (current_search_query.length > 0) {
            fetch_google_domain(current_category, current_search_query, session, set_label, clear_items, add_item, "bloomberg.com", "Bloomberg");
            return;
        }
        string url = "https://feeds.bloomberg.com/markets/news.rss";
        switch (current_category) {
            case "technology":
                url = "https://feeds.bloomberg.com/technology/news.rss";
                break;
            case "industries":
                url = "https://feeds.bloomberg.com/industries/news.rss";
                break;
            case "markets":
                url = "https://feeds.bloomberg.com/markets/news.rss";
                break;
            case "economics":
                url = "https://feeds.bloomberg.com/economics/news.rss";
                break;
            case "wealth":
                url = "https://feeds.bloomberg.com/wealth/news.rss";
                break;
            case "green":
                url = "https://feeds.bloomberg.com/green/news.rss";
                break;
            case "politics":
                url = "https://feeds.bloomberg.com/politics/news.rss";
                break;
            default:
                url = "https://feeds.bloomberg.com/markets/news.rss";
                break;
        }
        RssParser.fetch_rss_url(url, "Bloomberg", category_display_name(current_category), current_category, current_search_query, session, set_label, clear_items, add_item);
    }

    private static void fetch_npr(
        string current_category,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        if (current_search_query.length > 0) {
            fetch_google_domain(current_category, current_search_query, session, set_label, clear_items, add_item, "npr.org", "NPR");
            return;
        }
        string url = "https://feeds.npr.org/1001/rss.xml";
        switch (current_category) {
            case "technology":
                url = "https://feeds.npr.org/1019/rss.xml";
                break;
            case "science":
                url = "https://feeds.npr.org/1007/rss.xml";
                break;
            case "sports":
                url = "https://feeds.npr.org/1055/rss.xml";
                break;
            case "health":
                url = "https://feeds.npr.org/1128/rss.xml";
                break;
            case "us":
                url = "https://feeds.npr.org/1003/rss.xml";
                break;
            case "politics":
                url = "https://feeds.npr.org/1014/rss.xml";
                break;
            case "entertainment":
                url = "https://feeds.npr.org/1008/rss.xml";
                break;
            case "lifestyle":
                url = "https://feeds.npr.org/1053/rss.xml";
                break;
            default:
                url = "https://feeds.npr.org/1001/rss.xml";
                break;
        }
        RssParser.fetch_rss_url(url, "NPR", category_display_name(current_category), current_category, current_search_query, session, set_label, clear_items, add_item);
    }

    private static void fetch_fox(
        string current_category,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        // Use web scraping for Fox News to get better control over content and images
        // Keep the optimized version with reduced delays and limited concurrent requests
        fetch_fox_scrape(current_category, current_search_query, session, set_label, clear_items, add_item);
    }

    private static void fetch_fox_scrape(
        string current_category,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        new Thread<void*>("fetch-fox-scrape", () => {
            try {
                Gee.ArrayList<string> section_urls = new Gee.ArrayList<string>();
                switch (current_category) {
                    case "politics": section_urls.add("https://www.foxnews.com/politics"); break;
                    case "us": section_urls.add("https://www.foxnews.com/us"); break;
                    case "technology":
                        section_urls.add("https://www.foxnews.com/tech");
                        section_urls.add("https://www.foxnews.com/technology");
                        break;
                    case "business": section_urls.add("https://www.foxnews.com/business"); break;
                    case "science": section_urls.add("https://www.foxnews.com/science"); break;
                    case "sports": section_urls.add("https://www.foxnews.com/sports"); break;
                    case "health": section_urls.add("https://www.foxnews.com/health"); break;
                    case "entertainment": section_urls.add("https://www.foxnews.com/entertainment"); break;
                    case "lifestyle": section_urls.add("https://www.foxnews.com/lifestyle"); break;
                    case "general":
                        section_urls.add("https://www.foxnews.com/world");
                        section_urls.add("https://www.foxnews.com");
                        break;
                    default: section_urls.add("https://www.foxnews.com"); break;
                }

                if (current_search_query.length > 0) {
                    Idle.add(() => {
                        set_label(@"No Fox News results for search: \"$(current_search_query)\"");
                        return false;
                    });
                    return null;
                }

                Gee.ArrayList<Paperboy.NewsArticle> articles = ArticleScraper.scrape_section_urls(section_urls, "https://www.foxnews.com", current_search_query, session);
                // UI batching: add articles in small batches with short delays
                Idle.add(() => {
                    string category_name = category_display_name(current_category) + " — Fox News";
                    if (current_search_query.length > 0) {
                        set_label(@"Search Results: \"$(current_search_query)\" in $(category_name)");
                    } else {
                        set_label(category_name);
                    }
                    int ui_limit = 16;
                    int ui_count = 0;
                    int total = articles.size;
                    int count = 0;
                    foreach (var article in articles) {
                        if (count >= ui_limit) break;
                        Idle.add(() => {
                            add_item(article.title, article.url, article.image_url, current_category, "Fox News");
                            return false;
                        });
                        count++;
                    }
                    fetch_fox_article_images(articles, session, add_item, current_category);
                    return false;
                });
            } catch (GLib.Error e) {
                warning("Error parsing Fox News HTML: %s", e.message);
                    Idle.add(() => {
                        set_label("Fox News: Error loading articles");
                        return false;
                    });
            }
            return null;
        });
    }
    private static bool is_duplicate_url(Gee.ArrayList<Paperboy.NewsArticle> articles, string url) {
        foreach (var article in articles) {
            if (article.url == url) {
                return true;
            }
        }
        return false;
    }

    private static void fetch_fox_article_images(
    Gee.ArrayList<Paperboy.NewsArticle> articles,
        Soup.Session session,
        AddItemFunc add_item,
        string current_category
    ) {
        // Fetch OG images for articles that don't have them yet, limited to a few
        // to avoid long-running work. Delegate to Tools.ImageParser.fetch_open_graph_image
        // which spawns its own background thread and updates the UI via add_item.
        int count = 0;
        foreach (var article in articles) {
            if (article.image_url == null && count < 6 && article.url != null) {
                Tools.ImageParser.fetch_open_graph_image(article.url, session, add_item, current_category, "Fox News");
                count++;
            }
            if (count >= 6) break;
        }
    }

    private static void fetch_guardian_article_images(
        Json.Array results,
        Soup.Session session,
        AddItemFunc add_item,
        string current_category
    ) {
        // results is the Guardian API 'results' array; fetch OG images for first few
        // articles (lower concurrency to speed up perceived load). We spawn
        // fetch threads immediately; the fetch function itself runs in a
        // background thread so no additional scheduling is necessary.
        int count = 0;
        uint len = results.get_length();
        for (uint i = 0; i < len && count < 6; i++) {
            var article = results.get_element(i).get_object();
            if (article.has_member("webUrl")) {
                string url = article.get_string_member("webUrl");
                // Delegate OG image fetching to Tools.ImageParser
                Tools.ImageParser.fetch_open_graph_image(url, session, add_item, current_category, "The Guardian");
                count++;
            }
        }
    }


    private static void fetch_wsj(
        string current_category,
        string current_search_query,
        Soup.Session session,
        SetLabelFunc set_label,
        ClearItemsFunc clear_items,
        AddItemFunc add_item
    ) {
        if (current_search_query.length > 0) {
            fetch_google_domain(current_category, current_search_query, session, set_label, clear_items, add_item, "wsj.com", "WSJ");
            return;
        }
        string url = "https://feeds.content.dowjones.io/public/rss/RSSWorldNews.xml";
        switch (current_category) {
            case "technology":
                url = "https://feeds.content.dowjones.io/public/rss/RSSWSJD";
                break;
            case "business":
                url = "https://feeds.content.dowjones.io/public/rss/WSJcomUSBusiness";
                break;
            case "sports":
                url = "https://feeds.content.dowjones.io/public/rss/rsssportsfeed";
                break;
            case "health":
                url = "https://feeds.content.dowjones.io/public/rss/socialhealth";
                break;
            case "us":
                url = "https://feeds.content.dowjones.io/public/rss/RSSUSnews";
                break;
            case "politics":
                url = "https://feeds.content.dowjones.io/public/rss/socialpoliticsfeed";
                break;
            case "entertainment":
                url = "https://feeds.content.dowjones.io/public/rss/RSSArtsCulture";
                break;
            case "lifestyle":
                url = "https://feeds.content.dowjones.io/public/rss/RSSLifestyle";
                break;
            default:
                url = "https://feeds.content.dowjones.io/public/rss/RSSWorldNews";
                break;
        }
        RssParser.fetch_rss_url(url, "WSJ", category_display_name(current_category), current_category, current_search_query, session, set_label, clear_items, add_item);
    }
}
