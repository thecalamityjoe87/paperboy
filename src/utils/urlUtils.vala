using GLib;

public class UrlUtils {
    // Normalize article URLs for stable mapping (strip query params, trailing slash, lowercase host)
    public static string normalize_article_url(string url) {
        if (url == null) return "";
        string u = url.strip();
        // Remove query string entirely (utm and tracking params commonly appended)
        int qpos = u.index_of("?");
        if (qpos >= 0) {
            u = u.substring(0, qpos);
        }
        // Remove trailing slash
        while (u.length > 1 && u.has_suffix("/")) {
            u = u.substring(0, u.length - 1);
        }
        // Lowercase scheme and host portion
        int scheme_end = u.index_of("://");
        if (scheme_end >= 0) {
            int path_start = u.index_of("/", scheme_end + 3);
            string host_part = path_start >= 0 ? u.substring(0, path_start) : u;
            string rest = path_start >= 0 ? u.substring(path_start) : "";
            host_part = host_part.down();
            u = host_part + rest;
        } else {
            u = u.down();
        }
        return u;
    }
}
