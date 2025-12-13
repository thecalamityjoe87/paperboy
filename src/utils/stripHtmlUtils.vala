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

public class stripHtmlUtils {

    public static string strip_html(string s) {
        string out_str = s;

        // Remove <script> and <style> blocks early.
        // This avoids their contents leaking into text.
        try {
            var ss_regex = new Regex("<(script|style)[^>]*>.*?</\\1>",
                                     RegexCompileFlags.DOTALL | RegexCompileFlags.CASELESS);
            out_str = ss_regex.replace(out_str, -1, 0, "");
        } catch (Error e) {
            // Ignore regex failures.
        }

        // Decode named HTML entities first
        out_str = out_str.replace("&amp;", "&");
        out_str = out_str.replace("&lt;", "<");
        out_str = out_str.replace("&gt;", ">");
        out_str = out_str.replace("&quot;", "\"");
        out_str = out_str.replace("&#39;", "'");
        out_str = out_str.replace("&apos;", "'");
        out_str = out_str.replace("&nbsp;", " ");
        out_str = out_str.replace("&mdash;", "—");
        out_str = out_str.replace("&ndash;", "–");
        out_str = out_str.replace("&hellip;", "…");
        out_str = out_str.replace("&rsquo;", "'");
        out_str = out_str.replace("&lsquo;", "'");
        out_str = out_str.replace("&rdquo;", "\"");
        out_str = out_str.replace("&ldquo;", "\"");

        // Second pass for double-encoded entities (e.g., &amp;mdash; → &mdash; → —)
        out_str = out_str.replace("&mdash;", "—");
        out_str = out_str.replace("&ndash;", "–");
        out_str = out_str.replace("&hellip;", "…");
        out_str = out_str.replace("&rsquo;", "'");
        out_str = out_str.replace("&lsquo;", "'");
        out_str = out_str.replace("&rdquo;", "\"");
        out_str = out_str.replace("&ldquo;", "\"");
        out_str = out_str.replace("&nbsp;", " ");

        // Convert &amp;#123; → &#123;
        while (out_str.index_of("&amp;#") >= 0)
            out_str = out_str.replace("&amp;#", "&#");
        while (out_str.index_of("&AMP;#") >= 0)
            out_str = out_str.replace("&AMP;#", "&#");

        // Decode numeric entities (hex + decimal)
        try {
            // Hex entities
            var hex_regex = new Regex("&#[xX]([0-9a-fA-F]+);");
            MatchInfo? m = null;
            hex_regex.match(out_str, 0, out m);

            while (m != null && m.matches()) {
                string entity = m.fetch(0);
                string hex_str = m.fetch(1);

                int64 code_point = 0;
                for (int i = 0; i < hex_str.length; i++) {
                    char c = hex_str[i];
                    code_point *= 16;
                    if (c >= '0' && c <= '9') code_point += (c - '0');
                    else if (c >= 'a' && c <= 'f') code_point += (c - 'a' + 10);
                    else if (c >= 'A' && c <= 'F') code_point += (c - 'A' + 10);
                }

                if (code_point > 0 && code_point <= 0x10FFFF) {
                    out_str = out_str.replace(entity, ((unichar)code_point).to_string());
                }

                hex_regex.match(out_str, 0, out m);
            }

            // Decimal entities
            var dec_regex = new Regex("&#([0-9]+);");
            MatchInfo? dm = null;
            dec_regex.match(out_str, 0, out dm);

            while (dm != null && dm.matches()) {
                string entity = dm.fetch(0);
                string dec_str = dm.fetch(1);

                int64 code_point;
                try {
                    code_point = int64.parse(dec_str);
                } catch (Error e) {
                    dec_regex.match(out_str, 0, out dm);
                    continue;
                }

                if (code_point > 0 && code_point <= 0x10FFFF) {
                    out_str = out_str.replace(entity, ((unichar)code_point).to_string());
                }

                dec_regex.match(out_str, 0, out dm);
            }

        } catch (RegexError e) {
            // Fallback manual replacements
            out_str = out_str.replace("&#x27;", "'");
            out_str = out_str.replace("&#X27;", "'");
            out_str = out_str.replace("&#x22;", "\"");
            out_str = out_str.replace("&#X22;", "\"");
            out_str = out_str.replace("&#x2d;", "-");
            out_str = out_str.replace("&#X2D;", "-");
            out_str = out_str.replace("&#45;", "-");
            out_str = out_str.replace("&#8216;", "'");
            out_str = out_str.replace("&#8217;", "'");
            out_str = out_str.replace("&#039;", "'");
            out_str = out_str.replace("&#8220;", "\"");
            out_str = out_str.replace("&#8221;", "\"");
            out_str = out_str.replace("&#8230;", "…");
        }

        // Remove zero-width characters
        out_str = out_str.replace("&#x200B;", "");
        out_str = out_str.replace("&#X200B;", "");
        out_str = out_str.replace("&#8203;", "");
        out_str = out_str.replace("\u200B", "");
        out_str = out_str.replace("\uFEFF", "");

        // Strip tags
        var sb = new StringBuilder();
        bool intag = false;
        for (int i = 0; i < out_str.length; i++) {
            char c = out_str[i];
            if (c == '<') { intag = true; continue; }
            if (c == '>') { intag = false; continue; }
            if (!intag) sb.append_c(c);
        }
        out_str = sb.str;

        // Normalize whitespace
        out_str = out_str.replace("\n", " ").replace("\r", " ").replace("\t", " ");

        // Normalize common smart quotes to ASCII equivalents so we don't
        // end up with control/encoding artifacts in plain text output.
        out_str = out_str.replace("\u2019", "'");
        out_str = out_str.replace("\u2018", "'");
        out_str = out_str.replace("\u201C", "\"");
        out_str = out_str.replace("\u201D", "\"");

        // Remove C0 control characters (0x00-0x1F) except common whitespace
        // characters (TAB, LF, CR). This filters out stray low-value bytes
        // that appear as weird symbols in the UI.
        var clean_sb = new StringBuilder();
        for (int i = 0; i < out_str.length; i++) {
            uint code = (uint) out_str[i];
            if (code == 9 || code == 10 || code == 13) {
                clean_sb.append_c((char) code);
            } else if (code >= 0x20) {
                clean_sb.append_c((char) code);
            } else {
                // skip the control character
            }
        }
        out_str = clean_sb.str;

        // Collapse multiple spaces
        while (out_str.index_of("  ") >= 0)
            out_str = out_str.replace("  ", " ");

        return out_str.strip();
    }

    // Safer attribute extractor (handles whitespace)
    public static string extract_attr(string tag, string attr) {
        int ai = tag.index_of(attr + "=");
        if (ai < 0) return "";

        ai += attr.length + 1;
        if (ai >= tag.length) return "";

        // Skip whitespace before the quote
        int q = ai;
        while (q < tag.length && (tag[q] == ' ' || tag[q] == '\t'))
            q++;

        if (q >= tag.length) return "";

        char quote = tag[q];
        if (quote != '"' && quote != '\'') return "";

        int start = q + 1;
        int end = tag.index_of_char(quote, start);
        if (end <= start) return "";

        return tag.substring(start, end - start);
    }

    public static string extract_snippet_from_html(string html) {
        string lower = html.down();
        int pos = 0;

        // Try <meta> descriptions
        while ((pos = lower.index_of("<meta", pos)) >= 0) {
            int end = lower.index_of(">", pos);
            if (end < 0) break;

            string tag = html.substring(pos, end - pos + 1);
            string tl  = lower.substring(pos, end - pos + 1);

            bool matches =
                tl.index_of("property=\"og:description\"") >= 0 ||
                tl.index_of("name=\"description\"") >= 0 ||
                tl.index_of("name=\"twitter:description\"") >= 0;

            if (matches) {
                string content = extract_attr(tag, "content");
                if (content != null && content.strip().length > 0)
                    return truncate_snippet(strip_html(content), 280);
            }

            pos = end + 1;
        }

        // Fallback: first <p>...</p>
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

    public static string truncate_snippet(string s, int maxlen) {
        if (s.length <= maxlen) return s;
        return s.substring(0, maxlen - 1) + "…";
    }
}
