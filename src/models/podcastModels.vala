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

namespace Paperboy {

    // A podcast show/feed, as returned by PodcastIndexService (via
    // paperboyBackend). Kept separate from RssSource - a podcast feed isn't
    // browsed/read the way an RSS article feed is, it's subscribed to and
    // its episodes are played, so it doesn't share RssSource's invariants.
    public class PodcastShow : GLib.Object {
        public int64 feed_id;
        public string title;
        public string? author;
        public string? description;
        public string? image_url;
        public string feed_url;
        public string? category;
        public int episode_count;
        public string? language;
        // True for a show added directly by feed URL (see
        // PodcastFeedResolver) rather than discovered via PodcastIndex -
        // has no real PodcastIndex feed_id (feed_id is a synthetic,
        // negative, feed_url-derived id instead; see
        // PodcastFeedResolver.compute_synthetic_feed_id), and its episodes
        // must be resolved by re-parsing feed_url directly
        // (PodcastFeedResolver.fetch_episodes) rather than
        // PodcastIndexService.episodes_for_feed().
        public bool from_direct_feed;

        public PodcastShow() {
            feed_id = 0;
            title = "";
            author = null;
            description = null;
            image_url = null;
            feed_url = "";
            category = null;
            episode_count = 0;
            language = null;
            from_direct_feed = false;
        }
    }

    // A single episode of a PodcastShow.
    public class PodcastEpisode : GLib.Object {
        public int64 episode_id;
        public int64 feed_id;
        public string title;
        public string? description;
        public string audio_url;
        public int64 duration_seconds;
        // Unix timestamp string, matching DateUtils.time_ago's expected
        // input shape elsewhere in the app.
        public string? published;
        public string? image_url;
        // Denormalized so episode cards (e.g. "Your Shows" row) can render
        // the show's title without a separate lookup against PodcastShow.
        public string show_title;

        public PodcastEpisode() {
            episode_id = 0;
            feed_id = 0;
            title = "";
            description = null;
            audio_url = "";
            duration_seconds = 0;
            published = null;
            image_url = null;
            show_title = "";
        }
    }

    // Local bookkeeping for a show the user has subscribed to - not
    // returned by PodcastIndexService, persisted via PodcastSubscriptionStore.
    public class PodcastSubscription : GLib.Object {
        public int64 feed_id;
        public string title;
        public string? author;
        public string? image_url;
        public string feed_url;
        public int64 subscribed_at;

        public PodcastSubscription() {
            feed_id = 0;
            title = "";
            author = null;
            image_url = null;
            feed_url = "";
            subscribed_at = 0;
        }

        public PodcastSubscription.from_show(Paperboy.PodcastShow show) {
            feed_id = show.feed_id;
            title = show.title;
            author = show.author;
            image_url = show.image_url;
            feed_url = show.feed_url;
            subscribed_at = GLib.get_real_time() / 1000000;
        }

        // Reconstructs enough of a PodcastShow to open PodcastPane from a
        // stored subscription (e.g. clicking it in the sidebar) - no
        // description/category/episode_count since those aren't persisted
        // here. feed_id < 0 reliably means "added by direct feed URL" (see
        // PodcastShow.from_direct_feed): real PodcastIndex feed_ids are
        // always positive, synthetic ones are always negative.
        public Paperboy.PodcastShow to_show() {
            var show = new Paperboy.PodcastShow();
            show.feed_id = feed_id;
            show.title = title;
            show.author = author;
            show.image_url = image_url;
            show.feed_url = feed_url;
            show.from_direct_feed = feed_id < 0;
            return show;
        }
    }
}
