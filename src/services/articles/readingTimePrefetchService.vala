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

// Fetches reading times in the background for cards whose feed only had an
// excerpt. Plain fetch only (no WebKit fallback), in card order, a few at a time.
public class ReadingTimePrefetchService : GLib.Object {
    private const int MAX_CONCURRENT = 3;

    private static Gee.ArrayList<string>? _queue = null;
    private static Gee.ArrayList<string> queue() {
        if (_queue == null) _queue = new Gee.ArrayList<string>();
        return _queue;
    }
    // Normalized URLs already queued or tried, so failed fetches aren't
    // retried. Values are unused. Bounded: an unbounded set grew by one URL
    // per excerpt-only article for the life of the app; past the cap only
    // the oldest URLs become eligible again.
    private const int SEEN_CAPACITY = 2000;
    private static LruCache<string, string>? _seen = null;
    private static LruCache<string, string> seen() {
        if (_seen == null) _seen = new LruCache<string, string>(SEEN_CAPACITY);
        return _seen;
    }
    private static int in_flight = 0;
    private static uint start_idle_id = 0;

    // Main thread only.
    public static void enqueue(string url) {
        if (!url.has_prefix("http://") && !url.has_prefix("https://")) return;
        string normalized = UrlUtils.normalize_article_url(url);
        if (seen().get(normalized) != null) return;
        if (ArticleReadingTimeCache.get_instance().get_minutes(normalized) != 0) return;
        seen().set(normalized, "");
        queue().add(url);

        // Deferred so thumbnail backfill for the same card is queued first.
        if (start_idle_id == 0) {
            start_idle_id = GLib.Idle.add(() => {
                start_idle_id = 0;
                maybe_start_next();
                return false;
            });
        }
    }

    // Drops pending fetches when the view changes; running ones still finish and cache.
    public static void clear_queue() {
        foreach (var url in queue()) seen().remove(UrlUtils.normalize_article_url(url));
        queue().clear();
    }

    private static void maybe_start_next() {
        while (in_flight < MAX_CONCURRENT && queue().size > 0) {
            string url = queue().remove_at(0);
            string normalized = UrlUtils.normalize_article_url(url);
            if (ArticleReadingTimeCache.get_instance().get_minutes(normalized) != 0) continue;
            // Its extraction records a reading time too.
            if (ThumbnailBackfillService.is_pending(normalized)) continue;

            in_flight++;
            ArticleExtractorService.extract_async(url, false, (extracted) => {
                in_flight--;
                maybe_start_next();
            });
        }
    }
}
