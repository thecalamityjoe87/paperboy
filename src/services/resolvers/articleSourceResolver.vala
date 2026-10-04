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

        NewsSource article_src = NewsSource.UNKNOWN;

        // Map source name if found in buffer
        if (found_article_item && article_source_name != null && article_source_name.length > 0) {
            article_src = BuiltinSources.from_name(article_source_name);
            source_mapped = article_src != NewsSource.UNKNOWN;
        }

        // If not found in buffer or mapping failed, infer from URL
        if (!found_article_item || !source_mapped) {
            article_src = BuiltinSources.from_url(url);
            // An unrecognized URL stays unmapped, which triggers the generic placeholder
            source_mapped = article_src != NewsSource.UNKNOWN;
        }

        resolved_source = article_src;
    }
}

