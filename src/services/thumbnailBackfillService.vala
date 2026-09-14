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

// Tracks backfill requests belonging to one batch of cards (e.g. one "Load
// More" click) so the caller can hold that batch's entrance animation until
// every request in it has resolved, or a bounded grace period passes -
// whichever comes first. Mirrors LoadingStateManager's pending_backfills
// gate for the initial category load, but scoped to an arbitrary batch
// instead of "the current view."
public class BackfillBatchGate : GLib.Object {
    private const int GRACE_MS = 1500;
    private int pending = 0;
    private bool began = false;
    private bool settled = false;
    private uint grace_timeout_id = 0;

    // Fired once, when the batch is ready to reveal (all requests resolved,
    // or the grace period expired).
    public signal void ready();

    public void started() {
        pending++;
    }

    public void finished() {
        if (pending > 0) pending--;
        if (began && pending == 0) settle();
    }

    // Call once all started()/finished() calls for this batch have been
    // issued synchronously (i.e. right after the batch's cards are placed).
    public void begin() {
        began = true;
        if (pending == 0) {
            settle();
            return;
        }
        grace_timeout_id = GLib.Timeout.add(GRACE_MS, () => {
            grace_timeout_id = 0;
            settle();
            return false;
        });
    }

    private void settle() {
        if (settled) return;
        settled = true;
        if (grace_timeout_id > 0) {
            Source.remove(grace_timeout_id);
            grace_timeout_id = 0;
        }
        ready();
    }
}

// Background thumbnail backfill: when a card is placed with no real API
// thumbnail, quietly extract its article looking for a hero image, so the
// placeholder can be replaced without the user having to open reader view
// first. Kept cheap and bounded on purpose - skips the WebKit rendering
// fallback (reader view itself still uses that when the user opens it) and
// caps how many extractions run at once so a category full of image-less
// articles doesn't flood the network.
//
// Discovered images are persisted in DiscoveredThumbnailCache, keyed by
// normalized URL, so revisiting the same feed later reuses the stored image
// instead of re-extracting the article every time.
public class ThumbnailBackfillService : GLib.Object {
    // Lower than it would need to be for plain HTTP fetches alone - a
    // request that falls through to the WebKit fallback (see run() below)
    // is a real hidden browser view alive for up to ~15s, not a cheap
    // socket, so keep few of those alive at once.
    private const int MAX_CONCURRENT = 2;

    private class Request : GLib.Object {
        public NewsWindow window;
        public string url;
        public string normalized_url;
        public Gtk.Picture pic;
        public BackfillBatchGate? batch;
        public int fallback_w;
        public int fallback_h;
        public Request(NewsWindow window, string url, string normalized_url, Gtk.Picture pic, BackfillBatchGate? batch, int fallback_w, int fallback_h) {
            this.window = window;
            this.url = url;
            this.normalized_url = normalized_url;
            this.pic = pic;
            this.batch = batch;
            this.fallback_w = fallback_w;
            this.fallback_h = fallback_h;
        }
    }

    // Static Gee collection fields with inline initializers never actually
    // run in Vala - must lazy-init on first access instead.
    private static Gee.ArrayList<Request>? _queue = null;
    private static Gee.ArrayList<Request> queue() {
        if (_queue == null) _queue = new Gee.ArrayList<Request>();
        return _queue;
    }
    private static int in_flight = 0;

    // Set by a caller (e.g. "Load More") right before placing a batch of
    // cards, so every enqueue() call made while placing them is attributed
    // to that batch - see BackfillBatchGate. Left null for the initial
    // category load, which uses LoadingStateManager's own gate instead.
    public static BackfillBatchGate? current_batch = null;

    // fallback_w/fallback_h are used if the picture hasn't been allocated a
    // size yet by the time the image is ready (see apply_thumbnail) - pass
    // the size the caller requested for it, since get_size_request() isn't
    // reliable (e.g. a picture sized with set_size_request(-1, h) reports
    // width -1, not its actual intended width).
    public static void enqueue(NewsWindow window, string url, Gtk.Picture pic, int fallback_w = 0, int fallback_h = 0) {
        if (pic.get_data<bool>("thumbnail-backfill-queued")) return;
        pic.set_data<bool>("thumbnail-backfill-queued", true);

        string normalized = window.normalize_article_url(url);
        string? cached = DiscoveredThumbnailCache.get_instance().get(normalized);
        if (cached != null && cached.length > 0) {
            apply_thumbnail(window, pic, cached, fallback_w, fallback_h);
            return;
        }

        // Lets LoadingStateManager hold the initial reveal briefly for this
        // request - see its BACKFILL_GRACE_MS - so the card doesn't pop
        // from placeholder to image right after the view appears.
        if (window.loading_state != null) window.loading_state.on_backfill_started();
        if (current_batch != null) current_batch.started();

        queue().add(new Request(window, url, normalized, pic, current_batch, fallback_w, fallback_h));
        maybe_start_next();
    }

    private static void maybe_start_next() {
        while (in_flight < MAX_CONCURRENT && queue().size > 0) {
            var req = queue().remove_at(0);
            in_flight++;
            run(req);
        }
    }

    private static void run(Request req) {
        // Allow the WebKit/Readability fallback here too - some built-in
        // sources (e.g. Bloomberg) never put a thumbnail in their RSS feed
        // at all and bot-block the plain fetch outright (HTTP 403), so
        // without this fallback background backfill silently fails for
        // every one of their articles and only succeeds once the user
        // opens the article themselves (reader view's own extraction
        // already uses this same fallback). The cost is bounded by
        // MAX_CONCURRENT above, same as the plain-fetch case.
        ArticleExtractorService.extract_async(req.url, true, (extracted) => {
            in_flight--;

            // Don't require extracted.success - that reflects whether the
            // article body itself was extracted, not whether a hero image
            // was found. Plenty of pages have a clean og:image/JSON-LD image
            // even when the body-density heuristic fails to find the article.
            if (extracted.hero_image_url != null && extracted.hero_image_url.length > 0) {
                DiscoveredThumbnailCache.get_instance().set(req.normalized_url, extracted.hero_image_url);
                if (!req.pic.get_data<bool>("has-real-thumbnail")) {
                    apply_thumbnail(req.window, req.pic, extracted.hero_image_url, req.fallback_w, req.fallback_h);
                }
            }

            if (req.window.loading_state != null) req.window.loading_state.on_backfill_finished();
            if (req.batch != null) req.batch.finished();
            maybe_start_next();
        });
    }

    private static void apply_thumbnail(NewsWindow window, Gtk.Picture pic, string thumbnail_url, int fallback_w = 0, int fallback_h = 0) {
        // Widget may not have been allocated a size yet if this runs very
        // quickly (e.g. a cache hit) - fall back to its requested size,
        // then to the caller-supplied fallback (get_size_request() isn't
        // reliable - e.g. a picture sized (-1, h) reports width -1).
        int w = pic.get_width();
        int h = pic.get_height();
        if (w <= 0 || h <= 0) pic.get_size_request(out w, out h);
        if (w <= 0) w = fallback_w;
        if (h <= 0) h = fallback_h;
        if (w <= 0 || h <= 0 || window.image_manager == null) return;

        window.image_manager.load_image_async(pic, thumbnail_url, w * 3, h * 3, true);
        pic.set_data<bool>("has-real-thumbnail", true);
    }
}
