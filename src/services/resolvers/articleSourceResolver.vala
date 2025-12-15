using GLib;

public class ArticleSourceResolver : GLib.Object {

    // Returns resolved source, whether it was mapped, and optionally the published date
    public static void resolve(
        string? source_name,
        string url,
        Gee.ArrayList<ArticleItem> article_buffer,
        out NewsSource resolved_source,
        out bool source_mapped,
        out string? published
    ) {
        string? article_source_name = source_name;
        bool found_article_item = false;
        source_mapped = false;
        published = null;

        // Only look in buffer if source_name is missing
        if (article_source_name == null || article_source_name.length == 0) {
            foreach (var item in article_buffer) {
                if (item.url == url && item is ArticleItem) {
                    var ai = (ArticleItem) item;
                    article_source_name = ai.source_name;
                    published = ai.published;
                    found_article_item = true;
                    break;
                }
            }
        }

        NewsSource article_src = NewsSource.REDDIT;

        // Map source name if found in buffer
        if (found_article_item && article_source_name != null && article_source_name.length > 0) {
            string lower = article_source_name.down();
            if (lower.contains("reuters")) { article_src = NewsSource.REUTERS; source_mapped = true; }
            else if (lower.contains("guardian")) { article_src = NewsSource.GUARDIAN; source_mapped = true; }
            else if (lower.contains("bbc")) { article_src = NewsSource.BBC; source_mapped = true; }
            else if (lower.contains("nytimes")) { article_src = NewsSource.NEW_YORK_TIMES; source_mapped = true; }
            else if (lower.contains("wsj") || lower.contains("wall street journal")) { article_src = NewsSource.WALL_STREET_JOURNAL; source_mapped = true; }
            else if (lower.contains("bloomberg")) { article_src = NewsSource.BLOOMBERG; source_mapped = true; }
            else if (lower.contains("npr")) { article_src = NewsSource.NPR; source_mapped = true; }
            else if (lower.contains("fox")) { article_src = NewsSource.FOX; source_mapped = true; }
            else if (lower.contains("reddit")) { article_src = NewsSource.REDDIT; source_mapped = true; }
        }

        // If not found in buffer or mapping failed, infer from URL
        if (!found_article_item || !source_mapped) {
            article_src = SourceUtils.infer_source_from_url(url);

            // Check actual match
            bool is_actual_match = false;
            string url_lower = url.down();
            switch (article_src) {
                case NewsSource.GUARDIAN: is_actual_match = url_lower.contains("guardian") || url_lower.contains("theguardian"); break;
                case NewsSource.BBC: is_actual_match = url_lower.contains("bbc."); break;
                case NewsSource.REDDIT: is_actual_match = url_lower.contains("reddit") || url_lower.contains("redd.it"); break;
                case NewsSource.NEW_YORK_TIMES: is_actual_match = url_lower.contains("nytimes") || url_lower.contains("nyti.ms"); break;
                case NewsSource.WALL_STREET_JOURNAL: is_actual_match = url_lower.contains("wsj.com") || url_lower.contains("dowjones"); break;
                case NewsSource.BLOOMBERG: is_actual_match = url_lower.contains("bloomberg"); break;
                case NewsSource.REUTERS: is_actual_match = url_lower.contains("reuters"); break;
                case NewsSource.NPR: is_actual_match = url_lower.contains("npr.org"); break;
                case NewsSource.FOX: is_actual_match = url_lower.contains("foxnews") || url_lower.contains("fox.com"); break;
                default: is_actual_match = false; break;
            }

            if (is_actual_match) source_mapped = true; // treat inferred match as mapped
            else source_mapped = false; // fallback, will trigger generic placeholder
        }

        resolved_source = article_src;
    }
}

