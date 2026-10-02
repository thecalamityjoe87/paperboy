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

using Gee;

/*
 * Client-side interest model for the Front Page "Recommended for you" section, built
 * from reading history and thumbs up/down votes (so it decays and clears along with
 * them). Scores an article by how much the user reads its category, its site, and
 * the recurring topics in its title.
 */
public class InterestProfile : GLib.Object {
    // Reads needed before the profile is trusted enough to show anything.
    public const int MIN_READS = 10;
    public const double MATCH_THRESHOLD = 0.4;

    private const double HALF_LIFE_DAYS = 10.0;
    // Older articles lose up to half their score, so newer ones win close matches.
    private const double FRESHNESS_HALF_LIFE_HOURS = 12.0;
    // Each showing that wasn't opened costs this much, so ignored picks rotate out.
    private const double IMPRESSION_PENALTY = 0.75;
    // A title word only counts as a history topic once it shows up in this many reads.
    private const int MIN_TOPIC_READS = 2;

    private const double CATEGORY_WEIGHT = 0.25;
    private const double SOURCE_WEIGHT = 0.35;
    private const double TOPIC_WEIGHT = 0.4;

    // Votes are scored against their own signals, so a few count even against a long history.
    private const double LIKE_WEIGHT = 0.6;
    private const double DISLIKE_WEIGHT = 0.8;

    // Decayed category/site/topic weights for one kind of signal (reads, likes or dislikes).
    private class Signals {
        public HashMap<string, double?> categories = new HashMap<string, double?>();
        public HashMap<string, double?> sources = new HashMap<string, double?>();
        public HashMap<string, double?> topics = new HashMap<string, double?>();
        private HashMap<string, int> topic_counts = new HashMap<string, int>();
        private double max_category = 0;
        private double max_source = 0;
        private double max_topic = 0;

        public void add(string url, string? title, string? source, string? category_id, double w) {
            string? cat = resolve_category(category_id, source);
            if (cat != null) bump(categories, cat, w);

            string? host = host_for(url);
            if (host != null) bump(sources, host, w);

            if (title != null) {
                foreach (string topic in topics_for(title)) {
                    bump(topics, topic, w);
                    topic_counts.set(topic, topic_counts.get(topic) + 1);
                }
            }
        }

        public void finish(int min_topic_count) {
            var one_offs = new ArrayList<string>();
            foreach (var e in topic_counts.entries) {
                if (e.value < min_topic_count) one_offs.add(e.key);
            }
            foreach (string t in one_offs) topics.unset(t);
            topic_counts.clear();

            max_category = max_of(categories);
            max_source = max_of(sources);
            max_topic = max_of(topics);
        }

        // 0..1
        public double score(string title, string url, string? category_id, string? source) {
            double cat_score = 0;
            string? cat = resolve_category(category_id, source);
            if (cat != null && max_category > 0 && categories.has_key(cat)) {
                cat_score = categories.get(cat) / max_category;
            }

            double src_score = 0;
            string? host = host_for(url);
            if (host != null && max_source > 0 && sources.has_key(host)) {
                src_score = sources.get(host) / max_source;
            }

            double topic_sum = 0;
            if (max_topic > 0) {
                foreach (string topic in topics_for(title)) {
                    if (topics.has_key(topic)) topic_sum += topics.get(topic);
                }
            }
            double topic_score = max_topic > 0 ? double.min(1.0, topic_sum / max_topic) : 0;

            return CATEGORY_WEIGHT * cat_score + SOURCE_WEIGHT * src_score + TOPIC_WEIGHT * topic_score;
        }
    }

    private Signals history = new Signals();
    private Signals likes = new Signals();
    private Signals dislikes = new Signals();
    private int reads = 0;
    private int64 now = GLib.get_real_time() / 1000000;

    private static HashSet<string>? _stopwords = null;
    private static HashSet<string> stopwords {
        get {
            if (_stopwords == null) {
                _stopwords = new HashSet<string>();
                string[] words = {
                    "about", "after", "again", "against", "also", "amid", "among", "another", "around",
                    "back", "be", "because", "been", "before", "being", "best", "between", "big", "both",
                    "could", "does", "doing", "down", "during", "each", "even", "every", "first", "from",
                    "gets", "give", "gives", "going", "good", "have", "having", "here", "heres", "into",
                    "just", "know", "last", "latest", "like", "live", "look", "made", "make", "makes",
                    "many", "more", "most", "much", "must", "near", "need", "never", "news", "next",
                    "only", "other", "over", "people", "really", "report", "reports", "right", "said",
                    "says", "should", "since", "some", "still", "such", "take", "takes", "than", "that",
                    "thats", "their", "them", "then", "there", "these", "they", "thing", "things", "this",
                    "those", "three", "through", "time", "today", "under", "until", "update", "updates",
                    "very", "want", "wants", "watch", "were", "what", "whats", "when", "where", "which",
                    "while", "who", "whos", "will", "with", "without", "would", "year", "years", "your",
                    "youre", "week", "weeks", "days", "new", "now", "how", "why", "you", "the", "and",
                    "for", "are", "was", "has", "had", "its", "not", "but", "can", "out", "our", "all",
                    "one", "two", "may", "way", "day", "get", "got", "see", "say", "set", "use", "off"
                };
                foreach (string w in words) _stopwords.add(w);
            }
            return _stopwords;
        }
    }

    public bool is_ready() {
        return reads >= MIN_READS;
    }

    public void add_read(string url, string? title, string? source, string? category_id, int64 viewed_timestamp) {
        reads++;
        history.add(url, title, source, category_id, decay(viewed_timestamp));
    }

    // vote is +1 (thumbs up) or -1 (thumbs down).
    public void add_feedback(string url, string? title, string? source, string? category_id, int vote, int64 timestamp) {
        if (vote > 0) {
            reads++;
            likes.add(url, title, source, category_id, decay(timestamp));
        } else {
            dislikes.add(url, title, source, category_id, decay(timestamp));
        }
    }

    private double decay(int64 timestamp) {
        double age_days = double.max(0, (now - timestamp) / 86400.0);
        return Math.pow(0.5, age_days / HALF_LIFE_DAYS);
    }

    // Call once after the last add_read()/add_feedback().
    public void finish() {
        history.finish(MIN_TOPIC_READS);
        // A single vote is deliberate, so its title words count straight away.
        likes.finish(1);
        dislikes.finish(1);
    }

    // MATCH_THRESHOLD and above counts as a "Recommended for you" pick.
    public double score(string title, string url, string? category_id, string? source) {
        return history.score(title, url, category_id, source)
            + LIKE_WEIGHT * likes.score(title, url, category_id, source)
            - DISLIKE_WEIGHT * dislikes.score(title, url, category_id, source);
    }

    // Ranking score: freshness and the shown-but-ignored penalty applied to a score().
    public double adjust(double score, string? published, int impressions) {
        double factor = Math.pow(IMPRESSION_PENALTY, impressions);
        var when = DateUtils.parse_published_datetime(published);
        if (when != null) {
            double age_hours = double.max(0, (now - when.to_unix()) / 3600.0);
            factor *= 0.5 + 0.5 * Math.pow(0.5, age_hours / FRESHNESS_HALF_LIFE_HOURS);
        }
        return score * factor;
    }

    // Topic category for an article; views like Front Page carry the real one in a "##category::" source suffix.
    public static string? resolve_category(string? category_id, string? source) {
        string? cat = category_id;
        if (source != null) {
            int idx = source.index_of("##category::");
            if (idx >= 0) cat = source.substring(idx + 12).strip();
        }
        if (cat == null || cat.length == 0) return null;
        switch (cat) {
            case "frontpage": case "topten": case "saved": case "history":
            case "myfeed": case "local_news":
                return null;
            // Front Page API ids vs. sidebar ids for the same topic
            case "world": return "general";
            case "nation": return "us";
            default:
                return cat.has_prefix("rssfeed:") ? null : cat;
        }
    }

    private static string? host_for(string url) {
        int scheme = url.index_of("://");
        if (scheme < 0 || !url.has_prefix("http")) return null;
        string rest = url.substring(scheme + 3);
        int end = rest.index_of_char('/');
        string host = (end >= 0 ? rest.substring(0, end) : rest).down();
        int port = host.index_of_char(':');
        if (port >= 0) host = host.substring(0, port);
        if (host.has_prefix("www.")) host = host.substring(4);
        return host.length > 0 ? host : null;
    }

    private static HashSet<string> topics_for(string title) {
        var topics = new HashSet<string>();
        var word = new StringBuilder();
        // Apostrophes split words too, so "Trump's" yields "trump".
        string lower = title.down() + " ";
        unichar c;
        int i = 0;
        while (lower.get_next_char(ref i, out c)) {
            if (c.isalnum()) {
                word.append_unichar(c);
                continue;
            }
            string w = word.str;
            if (w.length >= 4 && !stopwords.contains(w) && !w.get_char(0).isdigit()) topics.add(w);
            word.truncate(0);
        }
        return topics;
    }

    private static void bump(HashMap<string, double?> map, string key, double w) {
        double cur = map.has_key(key) ? map.get(key) : 0;
        map.set(key, cur + w);
    }

    private static double max_of(HashMap<string, double?> map) {
        double m = 0;
        foreach (var v in map.values) if (v > m) m = v;
        return m;
    }
}
