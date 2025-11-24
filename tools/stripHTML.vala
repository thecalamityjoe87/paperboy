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


/*
* Utility for stripping HTML and decoding common entities.
* Extracted from articleWindow to be reusable across the project.
*/

public class HtmlUtils {
    
    public static string strip_html(string s) {
        // Decode entities first so encoded tags like &lt;strong&gt; become
        // literal '<' / '>' and can be stripped below.
        string out = s;

        // First decode named HTML entities. Doing this before numeric
        // replacements ensures sequences like "&amp;#039;" (double-escaped)
        // are converted to "&#039;" and then handled by numeric decoding.
        out = out.replace("&amp;", "&");
        out = out.replace("&lt;", "<");
        out = out.replace("&gt;", ">");
        out = out.replace("&quot;", "\"");
        out = out.replace("&#39;", "'");
        out = out.replace("&apos;", "'");
        out = out.replace("&nbsp;", " ");
        out = out.replace("&mdash;", "—");
        out = out.replace("&ndash;", "–");
        out = out.replace("&hellip;", "…");
        out = out.replace("&rsquo;", "'");
        out = out.replace("&lsquo;", "'");
        out = out.replace("&rdquo;", "\"");
        out = out.replace("&ldquo;", "\"");
        // Also collapse any common double-escaped numeric entity form like
        // "&amp;#039;" -> "&#039;" so numeric replacements below will match.
        while (out.index_of("&amp;#") >= 0) out = out.replace("&amp;#", "&#");
        while (out.index_of("&AMP;#") >= 0) out = out.replace("&AMP;#", "&#");
        // Now decode numeric HTML entities (both decimal and hexadecimal)
        out = out.replace("&#x27;", "'");
        out = out.replace("&#X27;", "'");
        out = out.replace("&#x22;", "\"");
        out = out.replace("&#X22;", "\"");
        out = out.replace("&#x26;", "&");
        out = out.replace("&#X26;", "&");
        out = out.replace("&#x3C;", "<");
        out = out.replace("&#X3C;", "<");
        out = out.replace("&#x3E;", ">");
        out = out.replace("&#X3E;", ">");
        out = out.replace("&#x20;", " ");
        out = out.replace("&#X20;", " ");
        out = out.replace("&#x2019;", "'");
        out = out.replace("&#X2019;", "'");
        out = out.replace("&#x2018;", "'");
        out = out.replace("&#X2018;", "'");
        out = out.replace("&#8216;", "'");
        out = out.replace("&#8217;", "'");
        out = out.replace("&#039;", "'");
        out = out.replace("&#x201C;", "\"");
        out = out.replace("&#X201C;", "\"");
        out = out.replace("&#x201D;", "\"");
        out = out.replace("&#X201D;", "\"");
        out = out.replace("&#8220;", "\"");
        out = out.replace("&#8221;", "\"");
        out = out.replace("&#x2013;", "–");
        out = out.replace("&#X2013;", "–");
        out = out.replace("&#x2014;", "—");
        out = out.replace("&#X2014;", "—");

        // Common invisible / zero-width characters
        out = out.replace("&#x200B;", "");
        out = out.replace("&#X200B;", "");
        out = out.replace("&#8203;", "");
        out = out.replace("\u200B", "");
        out = out.replace("\uFEFF", "");

        // Remove any HTML tags (now that encoded tags have been decoded).
        var sb = new StringBuilder();
        bool intag = false;
        for (int i = 0; i < out.length; i++) {
            char c = out[i];
            if (c == '<') { intag = true; continue; }
            if (c == '>') { intag = false; continue; }
            if (!intag) sb.append_c(c);
        }
        out = sb.str;

        // Clean whitespace
        out = out.replace("\n", " ").replace("\r", " ").replace("\t", " ");
        // collapse multiple spaces
        while (out.index_of("  ") >= 0) out = out.replace("  ", " ");
        return out.strip();
    }

    // Extract HTML attribute value from a tag (naive parser for simple attributes)
    public static string extract_attr(string tag, string attr) {
        // naive attribute extractor attr="..."
        int ai = tag.index_of(attr + "=");
        if (ai < 0) return "";
        ai += attr.length + 1;
        if (ai >= tag.length) return "";
        char quote = tag[ai];
        if (quote != '"' && quote != '\'') return "";
        int start = ai + 1;
        int end = tag.index_of_char(quote, start);
        if (end <= start) return "";
        return tag.substring(start, end - start);
    }

    // Extract a snippet from HTML by looking for meta tags or first paragraph
    public static string extract_snippet_from_html(string html) {
        string lower = html.down();
        // Try OpenGraph description
        int pos = 0;
        while ((pos = lower.index_of("<meta", pos)) >= 0) {
            int end = lower.index_of(">", pos);
            if (end < 0) break;
            string tag = html.substring(pos, end - pos + 1);
            string tl = lower.substring(pos, end - pos + 1);
            bool matches = tl.index_of("property=\"og:description\"") >= 0 ||
                           tl.index_of("name=\"description\"") >= 0 ||
                           tl.index_of("name=\"twitter:description\"") >= 0;
            if (matches) {
                string content = extract_attr(tag, "content");
                if (content != null && content.strip().length > 0) {
                    return truncate_snippet(strip_html(content), 280);
                }
            }
            pos = end + 1;
        }

        // Fallback: first paragraph
        int p1 = lower.index_of("<p");
        if (p1 >= 0) {
            int p1end = lower.index_of(">", p1);
            if (p1end > p1) {
                int p2 = lower.index_of("</p>", p1end);
                if (p2 > p1end) {
                    string inner = html.substring(p1end + 1, p2 - (p1end + 1));
                    return truncate_snippet(strip_html(inner), 280);
                }
            }
        }
        return "";
    }

    // Truncate a string to maxlen with ellipsis
    public static string truncate_snippet(string s, int maxlen) {
        if (s.length <= maxlen) return s;
        return s.substring(0, maxlen - 1) + "…";
    }
}
