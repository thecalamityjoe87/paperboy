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
 * RssValidator - Utility class for validating RSS/Atom feeds
 * 
 * Validates XML structure, checks for required elements, and counts items
 */
public class RssValidatorUtils : GLib.Object {
    
    /**
     * Validate RSS/Atom XML structure
     * 
     * @param xml_content The XML content to validate
     * @param error_message Output parameter for error details
     * @return true if valid, false otherwise
     */
    public static bool is_valid_rss(string xml_content, out string? error_message) {
        error_message = null;
        
        if (xml_content == null || xml_content.length == 0) {
            error_message = "Empty content";
            return false;
        }
        
        // Check 1: Basic XML structure - must be RSS or Atom
        string lower_content = xml_content.down();
        if (!lower_content.contains("<rss") && !lower_content.contains("<feed")) {
            error_message = "Not valid RSS/Atom XML (missing <rss> or <feed> tag)";
            return false;
        }
        
        // Check 2: Has channel element (RSS) or is Atom feed
        if (!lower_content.contains("<channel") && !lower_content.contains("<feed")) {
            error_message = "Missing <channel> or <feed> element";
            return false;
        }
        
        // Check 3: Has at least one item/entry
        if (!lower_content.contains("<item") && !lower_content.contains("<entry")) {
            error_message = "No <item> or <entry> elements found";
            return false;
        }
        
        // Check 4: Has title element (required for valid feeds)
        if (!lower_content.contains("<title")) {
            error_message = "Missing <title> element";
            return false;
        }
        
        // Check 5: Basic XML well-formedness - count opening/closing tags
        // Use regex-based tag detection to avoid false positives (handles
        // attributes, namespaces, and whitespace after the tag name).
        int rss_open = count_tag_openings(lower_content, "rss");
        int rss_close = count_tag_closings(lower_content, "rss");
        int feed_open = count_tag_openings(lower_content, "feed");
        int feed_close = count_tag_closings(lower_content, "feed");

        if (rss_open > 0 && rss_open != rss_close) {
            error_message = "Malformed XML: <rss> tags don't match";
            return false;
        }

        if (feed_open > 0 && feed_open != feed_close) {
            error_message = "Malformed XML: <feed> tags don't match";
            return false;
        }
        
        return true;
    }
    
    /**
     * Extract item count from RSS/Atom feed
     * 
     * @param xml_content The XML content to analyze
     * @return Number of items/entries found
     */
    public static int get_item_count(string xml_content) {
        if (xml_content == null || xml_content.length == 0) {
            return 0;
        }
        
        string lower_content = xml_content.down();
        
        // Count <item> tags (RSS) or <entry> tags (Atom) using robust tag matching
        int count = count_tag_openings(lower_content, "item");

        // If no items, count <entry> tags (Atom)
        if (count == 0) {
            count = count_tag_openings(lower_content, "entry");
        }

        // If we still have zero, attempt an XML-parse fallback which will
        // correctly handle namespaces and unusual formatting.
        if (count == 0) {
            try {
                Xml.Doc* doc = Xml.Parser.parse_doc(xml_content);
                if (doc != null) {
                    Xml.Node* root = doc->get_root_element();
                    if (root != null) {
                        int xml_items = count_xml_elements(root, "item");
                        int xml_entries = count_xml_elements(root, "entry");
                        int xml_count = xml_items + xml_entries;
                        delete doc;
                        if (xml_count > 0) return xml_count;
                    } else {
                        delete doc;
                    }
                }
            } catch (Error e) {
                // best-effort fallback; ignore parse errors
            }
        }

        return count;
    }
    
    /**
     * Check if feed has minimum number of items
     * 
     * @param xml_content The XML content to check
     * @param min_items Minimum number of items required (default: 1)
     * @return true if feed has at least min_items
     */
    public static bool has_minimum_items(string xml_content, int min_items = 1) {
        return get_item_count(xml_content) >= min_items;
    }
    
    /**
     * Count occurrences of a substring in a string
     * 
     * @param haystack The string to search in
     * @param needle The substring to count
     * @return Number of occurrences
     */
    private static int count_occurrences(string haystack, string needle) {
        if (haystack == null || needle == null || needle.length == 0) {
            return 0;
        }
        
        int count = 0;
        int pos = 0;
        
        while ((pos = haystack.index_of(needle, pos)) >= 0) {
            count++;
            pos += needle.length;
        }
        
        return count;
    }

    // Count opening tag occurrences like <tag ...> or <tag>
    // This handles optional namespace prefixes (e.g. <atom:entry>)
    private static int count_tag_openings(string haystack, string tag) {
        if (haystack == null || tag == null || tag.length == 0) return 0;
        try {
            string pattern = "<(?:\\w+:)?" + tag + "(\\s|>|$)";
            var regex = new GLib.Regex(pattern, GLib.RegexCompileFlags.CASELESS);
            GLib.MatchInfo match_info;
            int count = 0;
            if (regex.match(haystack, 0, out match_info)) {
                do {
                    count++;
                } while (match_info.next());
            }
            return count;
        } catch (GLib.Error e) {
            return 0;
        }
    }

    // Count closing tag occurrences like </tag>
    // Handles optional namespace prefixes (e.g. </atom:feed>)
    private static int count_tag_closings(string haystack, string tag) {
        if (haystack == null || tag == null || tag.length == 0) return 0;
        try {
            string pattern = "</(?:\\w+:)?" + tag + "\\s*>";
            var regex = new GLib.Regex(pattern, GLib.RegexCompileFlags.CASELESS);
            GLib.MatchInfo match_info;
            int count = 0;
            if (regex.match(haystack, 0, out match_info)) {
                do {
                    count++;
                } while (match_info.next());
            }
            return count;
        } catch (GLib.Error e) {
            return 0;
        }
    }
    
    /**
     * Extract feed title from RSS/Atom XML
     * 
     * @param xml_content The XML content
     * @return Feed title or null if not found
     */
    public static string? extract_feed_title(string xml_content) {
        if (xml_content == null || xml_content.length == 0) {
            return null;
        }
        
        // Simple regex-based extraction
        // Look for first <title> tag (should be feed title, not item title)
        try {
            var title_regex = new GLib.Regex("<title>([^<]+)</title>", GLib.RegexCompileFlags.CASELESS);
            GLib.MatchInfo match_info;
            
            if (title_regex.match(xml_content, 0, out match_info)) {
                string? title = match_info.fetch(1);
                if (title != null && title.length > 0) {
                    // Decode HTML entities
                    title = title.strip();
                    title = title.replace("&amp;", "&");
                    title = title.replace("&lt;", "<");
                    title = title.replace("&gt;", ">");
                    title = title.replace("&quot;", "\"");
                    title = title.replace("&#39;", "'");
                    title = title.replace("&apos;", "'");
                    
                    // Don't use if too long (likely description)
                    if (title.length <= 100) {
                        return title;
                    }
                }
            }
        } catch (GLib.Error e) {
            GLib.warning("Failed to extract feed title: %s", e.message);
        }
        
        return null;
    }

    /**
     * Clean RSS content by removing trailing garbage (e.g. HTML appended by generators)
     * 
     * @param content The raw content to clean
     * @return Cleaned content or original if no cleaning needed
     */
    public static string clean_rss_content(string content) {
        if (content == null || content.length == 0) return "";
        
        string lower = content.down();
        
        // Check for RSS closing tag
        int rss_end = lower.last_index_of("</rss>");
        if (rss_end >= 0) {
            // Keep the closing tag (length is 6)
            if (rss_end + 6 <= content.length)
                return content.substring(0, rss_end + 6).strip();
        }
        
        // Check for Atom closing tag
        int feed_end = lower.last_index_of("</feed>");
        if (feed_end >= 0) {
            // Keep the closing tag (length is 7)
            if (feed_end + 7 <= content.length)
                return content.substring(0, feed_end + 7).strip();
        }
        
        return content;
    }

    /**
     * Sanitize content for XML storage by removing illegal XML control characters
     * Keeps tab (0x09), LF (0x0A) and CR (0x0D) and all characters >= 0x20.
     */
    public static string sanitize_for_xml(string content) {
        if (content == null || content.length == 0) return "";

        var sb = new StringBuilder();
        for (int i = 0; i < content.length; i++) {
            char ch = content[i];
            int code = (int) ch;
            if (code == 9 || code == 10 || code == 13 || code >= 32) {
                sb.append_c(ch);
            }
        }
        return sb.str;
    }

    // Recursively count element nodes with the given local name. This
    // correctly handles namespaced elements because Xml.Node->name gives
    // the local name independent of namespace prefix.
    private static int count_xml_elements(Xml.Node* node, string tag) {
        if (node == null) return 0;
        int c = 0;
        for (Xml.Node* child = node->children; child != null; child = child->next) {
            if (child->type == Xml.ElementType.ELEMENT_NODE) {
                if (child->name != null && child->name == tag) c++;
                c += count_xml_elements(child, tag);
            }
        }
        return c;
    }
}
