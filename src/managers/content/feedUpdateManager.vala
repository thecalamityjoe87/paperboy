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
using Gee;

/**
 * FeedUpdateManager - background refresh scheduler for followed RSS feeds.
 *
 * Each feed has its own due time instead of everything refreshing in one burst:
 * last successful refresh + an interval that stretches for feeds that rarely change,
 * plus per-feed jitter and exponential backoff after failures. A tick every minute
 * dispatches a few due true feeds (cheap conditional GETs) and at most one generated
 * feed (a WebKit page load). Paused while the window is hidden, slowed down on
 * metered connections and in power-saver mode.
 */
public class FeedUpdateManager : GLib.Object {
    private weak NewsWindow window;
    private uint tick_id = 0;
    private bool generating = false;
    private string? generating_url = null;
    // Feeds open in the UI whose XML file is missing - the view is waiting on their generation.
    private Gee.HashSet<string> awaited_urls = new Gee.HashSet<string>();
    private bool tick_pending = false;
    private int64 last_tick_at = 0;
    // Feeds opened in the UI (or just imported) jump the generation queue.
    private Gee.ArrayList<string> priority_urls = new Gee.ArrayList<string>();
    private Gee.HashSet<string> outdated_urls = new Gee.HashSet<string>();
    // Dispatched true feeds whose fetch may still be in flight.
    private Gee.HashMap<string, int64?> dispatched_at = new Gee.HashMap<string, int64?>();
    // Background refreshes not yet counted toward the summary toast, by dispatch time.
    private Gee.HashMap<string, int64?> awaiting_result = new Gee.HashMap<string, int64?>();
    private int updated_since_toast = 0;
    private int64 last_toast_at = 0;

    private const uint TICK_SECONDS = 60;
    private const int TRUE_FEEDS_PER_TICK = 8;
    private const int64 REDISPATCH_GUARD_SECONDS = 5 * 60;
    private const int64 GENERATED_MIN_INTERVAL_SECONDS = 60 * 60;
    private const int64 MAX_INTERVAL_SECONDS = 24 * 60 * 60;
    private const int64 CONSTRAINED_SLOWDOWN = 4;
    private const int MAX_FEED_ITEMS = 100;

    // Only for feeds in awaited_urls; new_url differs from old_url if the file moved.
    public signal void request_show_toast(string message);

    public signal void awaited_feed_generated(string old_url, string new_url, bool success);

    public FeedUpdateManager(NewsWindow window) {
        this.window = window;
    }

    ~FeedUpdateManager() {
        stop();
    }

    // Seconds, or -1 for manual updates.
    private int64 get_update_interval_seconds() {
        switch (window.prefs.update_interval) {
            case "manual": return -1;
            case "15min": return 900;
            case "30min": return 1800;
            case "1hour": return 3600;
            case "2hours": return 7200;
            case "4hours": return 14400;
            default: return 3600;
        }
    }

    public void start() {
        if (tick_id != 0) return;
        foreach (var source in Paperboy.RssSourceStore.get_instance().get_sources_for_scheduling()) {
            if (is_outdated_generated_feed(source)) outdated_urls.add(source.url);
        }

        window.notify["suspended"].connect(on_window_state_changed);
        window.notify["visible"].connect(on_window_state_changed);
        window.notify["is-active"].connect(on_window_state_changed);

        tick();
        tick_id = GLib.Timeout.add_seconds(TICK_SECONDS, () => {
            tick();
            return GLib.Source.CONTINUE;
        });
    }

    public void stop() {
        if (tick_id != 0) {
            GLib.Source.remove(tick_id);
            tick_id = 0;
        }
    }

    // Coming back to the window catches up on anything that went due while it was away.
    private void on_window_state_changed() {
        if (tick_id != 0 && !is_paused()) tick();
    }

    private bool is_paused() {
        return !window.get_visible() || window.is_suspended();
    }

    private bool is_constrained() {
        return GLib.NetworkMonitor.get_default().get_network_metered()
            || GLib.PowerProfileMonitor.dup_default().get_power_saver_enabled();
    }

    public bool is_awaiting_generation(string url) {
        return awaited_urls.contains(url);
    }

    private static bool feed_file_missing(Paperboy.RssSource source) {
        return source.url.has_prefix("file://") && !GLib.FileUtils.test(source.url.substring(7), GLib.FileTest.EXISTS);
    }

    // Called when a feed is opened: a due generated feed moves to the front of the queue.
    // One whose file is missing always does, since the view has nothing to show until it's generated.
    public void request_refresh(Paperboy.RssSource source, bool viewing_this_feed = false) {
        if (!source.url.has_prefix("file://")) return;
        if (feed_file_missing(source)) {
            if (viewing_this_feed) awaited_urls.add(source.url);
            if (source.url != generating_url) prioritize(source.url);
            return;
        }
        int64 base_interval = get_update_interval_seconds();
        if (base_interval < 0) return;
        if (!is_due(source, GLib.get_real_time() / 1000000, base_interval)) return;
        prioritize(source.url);
    }

    // Used after OPML import adds a generated feed whose XML doesn't exist yet in this profile.
    public void regenerate_single_feed_async(Paperboy.RssSource source) {
        prioritize(source.url);
    }

    private void prioritize(string url) {
        if (!priority_urls.contains(url)) priority_urls.add(url);
        if (!tick_pending) {
            tick_pending = true;
            GLib.Idle.add(() => {
                tick_pending = false;
                maybe_start_generation();
                return false;
            });
        }
    }

    private int64 base_interval_for(Paperboy.RssSource source, int64 base_interval) {
        int64 interval = source.url.has_prefix("file://")
            ? int64.max(base_interval, GENERATED_MIN_INTERVAL_SECONDS)
            : base_interval;
        return is_constrained() ? interval * CONSTRAINED_SLOWDOWN : interval;
    }

    private int64 next_due_at(Paperboy.RssSource source, int64 now, int64 base_interval) {
        int64 base_for = base_interval_for(source, base_interval);

        if (source.failure_count > 0) {
            int64 backoff = int64.min(base_for << int.min(source.failure_count - 1, 10), MAX_INTERVAL_SECONDS);
            return source.last_failure_at + backoff;
        }
        if (outdated_urls.contains(source.url) || feed_file_missing(source)) return 0;

        // Feeds that haven't changed in a while get checked less often.
        int64 interval = base_for;
        if (source.last_changed_at > 0) {
            int64 max_interval = int64.max(base_for, int64.min(base_for * 8, MAX_INTERVAL_SECONDS));
            interval = (now - source.last_changed_at) / 4;
            interval = int64.max(base_for, int64.min(interval, max_interval));
        }
        int64 jitter = (int64) (source.url.hash() % (uint) int64.max(1, interval / 10));
        return source.last_fetched_at + interval + jitter;
    }

    private bool is_due(Paperboy.RssSource source, int64 now, int64 base_interval) {
        return now >= next_due_at(source, now, base_interval);
    }

    private bool can_refresh() {
        return get_update_interval_seconds() >= 0 && !is_paused()
            && GLib.NetworkMonitor.get_default().get_network_available();
    }

    // Window-state changes call this too, so it only runs once per TICK_SECONDS.
    private void tick() {
        int64 now = GLib.get_real_time() / 1000000;
        if (now - last_tick_at < TICK_SECONDS - 1 || !can_refresh()) return;
        last_tick_at = now;

        maybe_start_generation();

        int64 base_interval = get_update_interval_seconds();
        var sources = Paperboy.RssSourceStore.get_instance().get_sources_for_scheduling();
        int dispatched = 0;
        foreach (var source in sources) {
            if (dispatched >= TRUE_FEEDS_PER_TICK) break;
            if (source.url.has_prefix("file://")) continue;
            if (dispatched_at.has_key(source.url) && now - dispatched_at[source.url] < REDISPATCH_GUARD_SECONDS) continue;
            if (!is_due(source, now, base_interval)) continue;

            dispatched_at[source.url] = now;
            awaiting_result[source.url] = now;
            GLib.debug("Feed refresh: checking %s", source.name);
            maybe_check_for_podcast_feed(source);
            UnreadFetchService.refresh_rss_source(window, source);
            dispatched++;
        }

        collect_results(sources, now);
        if (dispatched == 0 && !generating && awaiting_result.size == 0) maybe_show_summary(now, base_interval);
    }

    // True feeds finish asynchronously, so their outcome is read back from the store's schedule fields.
    private void collect_results(Gee.ArrayList<Paperboy.RssSource> sources, int64 now) {
        foreach (var source in sources) {
            if (!awaiting_result.has_key(source.url)) continue;
            int64 sent = awaiting_result[source.url];
            if (source.last_fetched_at >= sent) {
                if (source.last_changed_at >= sent) updated_since_toast++;
            } else if (source.last_failure_at < sent && now - sent < REDISPATCH_GUARD_SECONDS) {
                continue;
            }
            awaiting_result.unset(source.url);
        }
        // Sources removed while their fetch was in flight.
        var gone = new Gee.ArrayList<string>();
        foreach (var url in awaiting_result.keys) {
            if (now - awaiting_result[url] >= REDISPATCH_GUARD_SECONDS) gone.add(url);
        }
        foreach (var url in gone) awaiting_result.unset(url);
    }

    // One summary per wave of background work, at most once per update interval.
    private void maybe_show_summary(int64 now, int64 base_interval) {
        if (updated_since_toast == 0) return;
        if (last_toast_at > 0 && now - last_toast_at < base_interval) return;
        string message = "RSS feeds: %d updated".printf(updated_since_toast);
        GLib.debug("Feed refresh: toast \"%s\"", message);
        request_show_toast(message);
        last_toast_at = now;
        updated_since_toast = 0;
    }

    // Queued feeds were asked for directly, so they run even in manual mode or while the window is away.
    private void maybe_start_generation() {
        if (generating) return;
        bool has_priority = priority_urls.size > 0 && GLib.NetworkMonitor.get_default().get_network_available();
        if (!has_priority && !can_refresh()) return;
        var sources = Paperboy.RssSourceStore.get_instance().get_sources_for_scheduling();
        var next = pick_generated_feed(sources, GLib.get_real_time() / 1000000, get_update_interval_seconds(), can_refresh());
        if (next != null) start_generation(next);
    }

    // Prioritized feeds first, then the most overdue one.
    private Paperboy.RssSource? pick_generated_feed(Gee.ArrayList<Paperboy.RssSource> sources, int64 now, int64 base_interval, bool include_scheduled) {
        while (priority_urls.size > 0) {
            string url = priority_urls.remove_at(0);
            foreach (var source in sources) {
                if (source.url == url) return source;
            }
        }

        if (!include_scheduled) return null;
        Paperboy.RssSource? best = null;
        int64 best_due = int64.MAX;
        foreach (var source in sources) {
            if (!source.url.has_prefix("file://")) continue;
            int64 due = next_due_at(source, now, base_interval);
            if (due <= now && due < best_due) {
                best = source;
                best_due = due;
            }
        }
        return best;
    }

    private void start_generation(Paperboy.RssSource source) {
        generating = true;
        generating_url = source.url;
        GLib.debug("Feed refresh: regenerating %s", source.name);
        maybe_check_for_podcast_feed(source);
        string old_url = source.url;
        new GLib.Thread<void*>("feed-regen", () => {
            bool changed;
            bool ok = regenerate_generated_feed(source, out changed);
            if (!ok) Paperboy.RssSourceStore.get_instance().record_fetch_failure(old_url);
            GLib.Idle.add(() => {
                generating = false;
                generating_url = null;
                if (ok && changed) updated_since_toast++;
                string new_url = old_url;
                if (ok) {
                    outdated_urls.remove(old_url);
                    var store = Paperboy.RssSourceStore.get_instance();
                    var updated = store.get_source_by_url(old_url);
                    if (updated == null && source.original_url != null) {
                        foreach (var s in store.get_sources_for_scheduling()) {
                            if (s.original_url == source.original_url) updated = s;
                        }
                    }
                    if (updated != null) {
                        new_url = updated.url;
                        if (window != null) UnreadFetchService.refresh_rss_source(window, updated);
                    }
                }
                if (awaited_urls.remove(old_url)) awaited_feed_generated(old_url, new_url, ok);
                // Queued feeds run back-to-back; background ones wait for the next tick.
                if (priority_urls.size > 0) maybe_start_generation();
                return false;
            });
            return null;
        });
    }

    private class GeneratedFeedResult : GLib.Object {
        public bool success = false;
        public string? rss_xml = null;
        public string? error_message = null;
    }

    // Called from the background "feed-updater" thread. GeneratedFeedService
    // needs a WebView, so the actual generation must run on the main thread -
    // dispatched here via Idle.add. Waiting for it with a nested MainLoop on
    // the default context would deadlock: that context is already owned by
    // the main thread's own GTK loop, which never releases it. A condition
    // variable lets this thread block without touching that context.
    private GeneratedFeedResult generate_feed_via_webkit_blocking(string url) {
        var result = new GeneratedFeedResult();
        var mutex = GLib.Mutex();
        var cond = GLib.Cond();
        bool done = false;

        GLib.Idle.add(() => {
            Paperboy.GeneratedFeedService.generate_async(url, (success, rss_xml, error_message) => {
                result.success = success;
                result.rss_xml = rss_xml;
                result.error_message = error_message;
                mutex.lock();
                done = true;
                cond.signal();
                mutex.unlock();
            });
            return false;
        });

        mutex.lock();
        while (!done) {
            cond.wait(mutex);
        }
        mutex.unlock();
        return result;
    }

    // Runs on the "feed-regen" thread. Records its own success (the file URL can change);
    // the caller records failures.
    private bool regenerate_generated_feed(Paperboy.RssSource source, out bool changed) {
        changed = false;
        // Check if we have the original_url to regenerate from
        if (source.original_url == null || source.original_url.length == 0) {
            GLib.warning("  ✗ Cannot regenerate %s: no original_url stored", source.name);
            return false;
        }

        GLib.print("  ⟳ Regenerating feed for %s from %s\n", source.name, source.original_url);

        // Extract host from original_url
        string? host = UrlUtils.extract_host_from_url(source.original_url);
        if (host == null || host.length == 0) {
            GLib.warning("  ✗ Cannot extract host from original_url: %s", source.original_url);
            return false;
        }

        var gen_result = generate_feed_via_webkit_blocking(source.original_url);
        if ((!gen_result.success || gen_result.rss_xml == null)
            && Paperboy.GeneratedFeedService.is_retryable_error(gen_result.error_message)) {
            GLib.print("  ⟳ Retrying generation for %s (%s)\n", source.name, gen_result.error_message ?? "unknown error");
            gen_result = generate_feed_via_webkit_blocking(source.original_url);
        }
        if (!gen_result.success || gen_result.rss_xml == null) {
            GLib.warning("  ✗ Feed generation failed for %s: %s", source.name, gen_result.error_message ?? "unknown error");
            return false;
        }

        try {
            string gen_feed = gen_result.rss_xml;

            // Validate the generated feed
            string? error = null;
            if (RssValidatorUtils.is_valid_rss(gen_feed, out error)) {
                int item_count = RssValidatorUtils.get_item_count(gen_feed);

                // Check if content actually changed by comparing with old feed
                bool content_changed = true;
                string old_file_path = "";
                if (source.url.length > 7) {
                    old_file_path = source.url.substring(7); // Remove "file://" prefix
                }

                if (old_file_path.length > 0) {
                    try {
                        var old_file = GLib.File.new_for_path(old_file_path);
                        if (old_file.query_exists()) {
                            // Read old feed content
                            uint8[] old_contents;
                            old_file.load_contents(null, out old_contents, null);
                            string old_feed = (string) old_contents;

                            // Compare feeds by checking if they have the same items
                            // We'll use a simple heuristic: compare item count and a hash of GUIDs/links
                            if (RssValidatorUtils.is_valid_rss(old_feed, out error)) {
                                int old_item_count = RssValidatorUtils.get_item_count(old_feed);

                                if (old_item_count == item_count) {
                                    // Same number of items - do a deeper comparison
                                    // Extract GUIDs/links from both feeds and compare
                                    string old_signature = extract_feed_signature(old_feed);
                                    string new_signature = extract_feed_signature(gen_feed);

                                    if (old_signature == new_signature && !generator_outdated(old_feed)) {
                                        content_changed = false;
                                        GLib.print("  ⏭  Skipping %s - content unchanged (%d items)\n", source.name, item_count);
                                    }
                                }
                            }
                        }
                    } catch (Error e) {
                        // If we can't read old file, assume content changed
                        GLib.warning("  ⚠ Could not read old feed for comparison: %s", e.message);
                    }
                }

                // Only update if content actually changed
                if (content_changed) {
                    // Merge old articles into new feed before saving
                    if (old_file_path.length > 0) {
                        try {
                            var old_file = GLib.File.new_for_path(old_file_path);
                            if (old_file.query_exists()) {
                                // Read old feed content
                                uint8[] old_contents;
                                old_file.load_contents(null, out old_contents, null);
                                string old_feed = (string) old_contents;

                                if (RssValidatorUtils.is_valid_rss(old_feed, out error)) {
                                    // Merge old articles into new feed
                                    gen_feed = merge_rss_feeds(old_feed, gen_feed);
                                    item_count = RssValidatorUtils.get_item_count(gen_feed);
                                    GLib.print("  ↻ Merged with old feed (now %d total items)\n", item_count);
                                }
                            }
                        } catch (Error e) {
                            GLib.warning("  ⚠ Failed to merge old feed: %s", e.message);
                        }
                    }

                    // Save new XML file (now contains merged articles)
                    // Use same filename (without timestamp) so we replace the old file
                    string data_dir = GLib.Environment.get_user_data_dir();
                    string paperboy_dir = GLib.Path.build_filename(data_dir, "paperboy");
                    string gen_dir = GLib.Path.build_filename(paperboy_dir, "generated_feeds");
                    GLib.DirUtils.create_with_parents(gen_dir, 0755);

                    string safe_host = host.replace("/", "_").replace(":", "_");
                    string filename = safe_host + ".xml";
                    string new_file_path = GLib.Path.build_filename(gen_dir, filename);

                    var f = GLib.File.new_for_path(new_file_path);
                    var out_stream = f.replace(null, false, GLib.FileCreateFlags.NONE, null);
                    var writer = new DataOutputStream(out_stream);
                    string safe_feed = RssValidatorUtils.sanitize_for_xml(gen_feed);
                    writer.put_string(safe_feed);
                    writer.close(null);

                    // Only remove the old file once the new one is safely written (replace() is atomic),
                    // and never outside our own generated_feeds folder.
                    if (old_file_path.length > 0 && old_file_path != new_file_path
                        && GLib.Path.get_dirname(old_file_path) == gen_dir) {
                        try {
                            var old_file = GLib.File.new_for_path(old_file_path);
                            if (old_file.query_exists()) {
                                old_file.delete();
                                GLib.print("  ✓ Deleted old feed file: %s\n", GLib.Path.get_basename(old_file_path));
                            }
                        } catch (Error e) {
                            GLib.warning("  ⚠ Failed to delete old feed file: %s", e.message);
                        }
                    }

                    // Update database with new file path
                    var store = Paperboy.RssSourceStore.get_instance();
                    string new_url = "file://" + new_file_path;
                    store.update_source_url(source.url, new_url);
                    store.record_fetch_success(new_url, true);

                    GLib.print("  ✓ Regenerated: %s (%d items)\n", source.name, item_count);
                } else {
                    var store = Paperboy.RssSourceStore.get_instance();
                    store.record_fetch_success(source.url, false);
                }

                changed = content_changed;
                malloc_trim(0);
                return true;
            } else {
                GLib.warning("  ✗ Generated invalid RSS for %s: %s", source.name, error);
                malloc_trim(0);
                return false;
            }
        } catch (Error e) {
            GLib.warning("  ✗ Error regenerating feed for %s: %s", source.name, e.message);
            malloc_trim(0);
            return false;
        }
    }

    // Checked far less often than the article feed itself (see
    // PODCAST_CHECK_INTERVAL_SECONDS) - crawls the site's homepage for a
    // separate podcast feed it advertises via a standard
    // <link rel="alternate" type="application/rss+xml"/atom+xml"> tag, since
    // most sites publish their podcast under a different URL than their
    // article feed (e.g. 9to5Google's article feed vs. its podcast feed).
    private const int64 PODCAST_CHECK_INTERVAL_SECONDS = 7 * 24 * 60 * 60; // once a week per source

    // Public so opening a feed can also trigger it (rate-limited separately, see above).
    public void maybe_check_for_podcast_feed(Paperboy.RssSource source) {
        int64 now = GLib.get_real_time() / 1000000;
        if (now - source.podcast_checked_at < PODCAST_CHECK_INTERVAL_SECONDS) {
            GLib.print("  [podcast-check] %s: skipped, checked recently\n", source.name);
            return;
        }

        string? root_url = UrlUtils.extract_root_url(source.url);
        if (root_url == null) {
            // source.url is a local file:// path for generated
            // feeds, so there's no homepage to scan - but original_url
            // (the real site this feed was scraped from, e.g.
            // "https://cnn.com") is exactly what try_podcastindex_name_search
            // needs, and it doesn't require fetching anything from the site
            // at all. Skip straight to it.
            if (UrlUtils.extract_root_url(source.original_url) != null) {
                GLib.print("  [podcast-check] %s: no homepage to scan (generated feed) - trying PodcastIndex name search\n", source.name);
                try_podcastindex_name_search(source, null);
            } else {
                GLib.print("  [podcast-check] %s: no root url and no usable original_url, giving up\n", source.name);
            }
            return;
        }

        GLib.print("  [podcast-check] %s: fetching homepage %s\n", source.name, root_url);
        var options = new Paperboy.HttpClientUtils.RequestOptions().with_browser_headers();
        Paperboy.HttpClientUtils.get_default().fetch_async(root_url, options, (response) => {
            if (!response.is_success()) {
                GLib.print("  [podcast-check] %s: homepage fetch failed, status=%u error=%s - trying PodcastIndex name search instead\n",
                    source.name, response.status_code, response.error_message ?? "none");
                try_podcastindex_name_search(source, null);
                return;
            }
            string? html = response.get_body_string();
            if (html == null) {
                GLib.print("  [podcast-check] %s: homepage fetch succeeded but empty body - trying PodcastIndex name search instead\n", source.name);
                try_podcastindex_name_search(source, null);
                return;
            }

            var candidates = extract_alternate_feed_links(html, root_url);
            // The followed feed itself is never the "discovery" - only a
            // genuinely separate feed counts.
            candidates.remove(source.url);
            int64 apple_podcast_id = extract_apple_podcast_id(html);
            GLib.print("  [podcast-check] %s: html=%d bytes, %d <link> candidates, apple_id=%lld\n",
                source.name, html.length, candidates.size, apple_podcast_id);
            check_candidates_for_podcast(source, candidates, 0, apple_podcast_id);
        });
    }

    // Many sites (e.g. 9to5Google) don't advertise their podcast via a
    // plain <link rel="alternate"> tag at all - the podcast is hosted
    // externally and only linked to from the page as a "Subscribe on Apple
    // Podcasts" button. Extracts the numeric id from the first such link
    // found, e.g. https://podcasts.apple.com/us/podcast/name/id1359922601
    // or the older itunes.apple.com form - both use the same "id<digits>"
    // path segment. Returns 0 if none found.
    //
    // Requires a literal "podcast" path segment: itunes.apple.com is a
    // legacy domain Apple also used for iOS *app* links (e.g.
    // itunes.apple.com/app/apple-store/id299948601 - TMZ's own iOS app,
    // observed on tmz.com's homepage), which would otherwise false-positive
    // as a podcast id and send an unrelated app id to PodcastIndex.
    private int64 extract_apple_podcast_id(string html) {
        try {
            var regex = new GLib.Regex(
                "(?:itunes|podcasts)\\.apple\\.com/(?:[a-z]{2}/)?podcast/[^\"'\\s]*?id(\\d+)",
                GLib.RegexCompileFlags.CASELESS);
            GLib.MatchInfo match_info;
            if (regex.match(html, 0, out match_info)) {
                string id_str = match_info.fetch(1);
                int64 id = int64.parse(id_str);
                if (id > 0) return id;
            }
        } catch (GLib.RegexError e) {
            GLib.warning("  ✗ Failed to scan for an Apple Podcasts link: %s", e.message);
        }
        return 0;
    }

    // Scans <head> for <link rel="alternate" type="application/rss+xml"|
    // "application/atom+xml" href="..."> tags - the standard way sites
    // advertise their feeds (including, sometimes, a separate podcast feed)
    // to feed readers. Resolves relative hrefs against base_url. Capped by
    // the caller (check_candidates_for_podcast) to a handful of attempts.
    private Gee.ArrayList<string> extract_alternate_feed_links(string html, string base_url) {
        var results = new Gee.ArrayList<string>();
        try {
            var regex = new GLib.Regex("<link\\s+[^>]*rel=[\"']alternate[\"'][^>]*>", GLib.RegexCompileFlags.CASELESS);
            GLib.MatchInfo match_info;
            regex.match(html, 0, out match_info);
            while (match_info.matches()) {
                string tag = match_info.fetch(0);
                if (tag.down().contains("application/rss+xml") || tag.down().contains("application/atom+xml")) {
                    var href_regex = new GLib.Regex("href=[\"']([^\"']+)[\"']", GLib.RegexCompileFlags.CASELESS);
                    GLib.MatchInfo href_match;
                    if (href_regex.match(tag, 0, out href_match)) {
                        string href = href_match.fetch(1);
                        string resolved = resolve_relative_url(href, base_url);
                        if (resolved.length > 0 && !results.contains(resolved)) results.add(resolved);
                    }
                }
                match_info.next();
            }
        } catch (GLib.RegexError e) {
            GLib.warning("  ✗ Failed to scan for alternate feed links: %s", e.message);
        }
        return results;
    }

    private string resolve_relative_url(string href, string base_url) {
        if (href.has_prefix("http://") || href.has_prefix("https://")) return href;
        if (href.has_prefix("//")) return "https:" + href;
        if (href.has_prefix("/")) {
            // base_url is always "scheme://host/" (see UrlUtils.extract_root_url) -
            // strip its trailing slash before appending the absolute path.
            return base_url.substring(0, base_url.length - 1) + href;
        }
        return base_url + href;
    }

    // Walks discovered <link>-tag candidate feed URLs one at a time (not in
    // parallel - this only runs once a week per source, so there's no rush,
    // and it keeps concurrent request pressure low), stopping at the first
    // one RssValidatorUtils.looks_like_podcast_feed() confirms is actually a
    // podcast. Falls back to the Apple Podcasts id (if one was found on the
    // page) once link-tag candidates are exhausted - see
    // try_apple_podcast_fallback().
    private void check_candidates_for_podcast(Paperboy.RssSource source, Gee.ArrayList<string> candidates, int index, int64 apple_podcast_id) {
        if (index >= candidates.size || index >= 5) {
            try_apple_podcast_fallback(source, apple_podcast_id);
            return;
        }

        string candidate_url = candidates[index];
        var options = new Paperboy.HttpClientUtils.RequestOptions();
        Paperboy.HttpClientUtils.get_default().fetch_async(candidate_url, options, (response) => {
            if (response.is_success()) {
                string? body = response.get_body_string();
                if (body != null && RssValidatorUtils.looks_like_podcast_feed(body)) {
                    GLib.print("  [podcast-check] %s: <link> candidate %s looks like a podcast\n", source.name, candidate_url);
                    finalize_with_confirmed_candidate(source, candidate_url);
                    return;
                }
            }
            GLib.print("  [podcast-check] %s: <link> candidate %s is not a podcast\n", source.name, candidate_url);
            check_candidates_for_podcast(source, candidates, index + 1, apple_podcast_id);
        });
    }

    // Once no <link>-advertised feed panned out: resolve a "Subscribe on
    // Apple Podcasts" link scraped off the page (see
    // extract_apple_podcast_id()) to its real feed url via PodcastIndex's
    // own database (PodcastIndexService.podcast_by_itunes_id() - never
    // calls Apple's API directly). Trusts the resolved url without
    // re-validating via looks_like_podcast_feed(): PodcastIndex's database
    // is podcasts by definition, unlike an arbitrary homepage-discovered
    // <link> candidate which could be any kind of feed. Falls through to
    // try_podcastindex_name_search() as the final resort.
    private void try_apple_podcast_fallback(Paperboy.RssSource source, int64 apple_podcast_id) {
        if (apple_podcast_id <= 0) {
            GLib.print("  [podcast-check] %s: no apple podcast id found\n", source.name);
            try_podcastindex_name_search(source, null);
            return;
        }

        GLib.print("  [podcast-check] %s: resolving apple id %lld via PodcastIndex\n", source.name, apple_podcast_id);
        Paperboy.PodcastIndexService.get_instance().podcast_by_itunes_id(apple_podcast_id, (show) => {
            if (show != null && show.feed_url.length > 0) {
                GLib.print("  [podcast-check] %s: resolved to %s\n", source.name, show.feed_url);
                finalize_with_confirmed_candidate(source, show.feed_url);
            } else {
                GLib.print("  [podcast-check] %s: PodcastIndex had no match for apple id %lld\n", source.name, apple_podcast_id);
                try_podcastindex_name_search(source, null);
            }
        });
    }

    // Searches PodcastIndex by site name for an accurate candidate count -
    // always run, even after a <link> tag or Apple id already confirmed one
    // candidate, since it's the only strategy that finds multiple.
    // already_confirmed_url (if any) survives a zero-result search.
    private void try_podcastindex_name_search(Paperboy.RssSource source, string? already_confirmed_url) {
        var store = Paperboy.RssSourceStore.get_instance();
        // source.url is a local file:// path for generated feeds -
        // original_url (the real site, e.g. "https://cnn.com") is the one
        // that actually has a meaningful domain to match against.
        string domain_source = UrlUtils.extract_root_url(source.original_url) != null ? source.original_url : source.url;
        string site_domain = UrlUtils.extract_host_from_url(domain_source);
        GLib.print("  [podcast-check] %s: searching PodcastIndex by name for site %s\n", source.name, site_domain);
        Paperboy.PodcastIndexService.get_instance().find_podcasts_by_site(source.name, site_domain, source.url, (shows) => {
            if (shows.size > 0) {
                GLib.print("  [podcast-check] %s: name search found %d candidate(s), first is %s\n", source.name, shows.size, shows[0].feed_url);
                store.set_podcast_feed_url(source.url, shows[0].feed_url, shows.size);
            } else if (already_confirmed_url != null) {
                GLib.print("  [podcast-check] %s: name search found nothing, keeping already-confirmed %s\n", source.name, already_confirmed_url);
                store.set_podcast_feed_url(source.url, already_confirmed_url, 1);
            } else {
                GLib.print("  [podcast-check] %s: no podcast found via name search either, giving up\n", source.name);
                store.set_podcast_feed_url(source.url, null, 1);
            }
        });
    }

    // Still runs the name search for an accurate count, without losing the
    // already-confirmed candidate if that search comes up empty.
    private void finalize_with_confirmed_candidate(Paperboy.RssSource source, string confirmed_url) {
        try_podcastindex_name_search(source, confirmed_url);
    }

    /**
     * Extract a signature from an RSS feed based on item GUIDs/links
     * This is used to determine if feed content has changed
     * @param feed_xml The RSS feed XML content
     * @return A signature string representing the feed's items
     */
    private string extract_feed_signature(string feed_xml) {
        var signature = new StringBuilder();
        
        Xml.Doc* doc = RssValidatorUtils.parse_feed_xml(feed_xml);
        if (doc == null) {
            return "";
        }

        Xml.Node* root = doc->get_root_element();
        if (root == null) {
            delete doc;
            return "";
        }

        // Find all <item> or <entry> elements
        for (Xml.Node* node = root->children; node != null; node = node->next) {
            if (node->type != Xml.ElementType.ELEMENT_NODE) continue;

            // Handle RSS <channel> wrapper
            if (node->name == "channel") {
                for (Xml.Node* item = node->children; item != null; item = item->next) {
                    if (item->type != Xml.ElementType.ELEMENT_NODE) continue;
                    if (item->name == "item") {
                        extract_item_signature(item, signature);
                    }
                }
            }
            // Handle Atom <entry> elements directly under root
            else if (node->name == "entry") {
                extract_item_signature(node, signature);
            }
        }

        delete doc;
        
        return signature.str;
    }
    
    /**
     * Extract signature from a single RSS item or Atom entry
     */
    // Generated feed file written by an older version of the generator.
    private bool is_outdated_generated_feed(Paperboy.RssSource source) {
        if (!source.url.has_prefix("file://")) return false;
        try {
            uint8[] contents;
            GLib.File.new_for_uri(source.url).load_contents(null, out contents, null);
            return generator_outdated((string) contents);
        } catch (Error e) {
            return false;
        }
    }

    private bool generator_outdated(string feed_xml) {
        return !feed_xml.contains("<generator>" + Paperboy.GeneratedFeedService.GENERATOR_VERSION + "</generator>");
    }

    private void extract_item_signature(Xml.Node* item, StringBuilder signature) {
        for (Xml.Node* child = item->children; child != null; child = child->next) {
            if (child->type != Xml.ElementType.ELEMENT_NODE) continue;
            
            // Look for GUID, link, or id elements
            // Dates included so a regeneration that newly finds them isn't treated as unchanged.
            if (child->name == "guid" || child->name == "link" || child->name == "id" ||
                child->name == "pubDate" || child->name == "published" || child->name == "updated") {
                string? content = child->get_content();
                if (content != null && content.length > 0) {
                    signature.append(content);
                    signature.append("|");
                }
            }
        }
    }
    
    /**
     * Merge two RSS feeds, combining items from both while avoiding duplicates
     * @param old_feed The old RSS feed XML
     * @param new_feed The new RSS feed XML
     * @return Merged RSS feed XML with items from both feeds
     */
    private string merge_rss_feeds(string old_feed, string new_feed) {
        try {
            // Parse both feeds
            Xml.Doc* old_doc = RssValidatorUtils.parse_feed_xml(old_feed);
            Xml.Doc* new_doc = RssValidatorUtils.parse_feed_xml(new_feed);

            if (old_doc == null || new_doc == null) {
                GLib.warning("Failed to parse feeds for merging");
                if (old_doc != null) delete old_doc;
                if (new_doc != null) delete new_doc;
                return new_feed; // Return new feed as fallback
            }

            Xml.Node* old_root = old_doc->get_root_element();
            Xml.Node* new_root = new_doc->get_root_element();

            if (old_root == null || new_root == null) {
                delete old_doc;
                delete new_doc;
                return new_feed;
            }

            // Find the channel node in new feed (RSS) or use root for Atom
            Xml.Node* new_channel = null;
            for (Xml.Node* node = new_root->children; node != null; node = node->next) {
                if (node->type == Xml.ElementType.ELEMENT_NODE && node->name == "channel") {
                    new_channel = node;
                    break;
                }
            }

            // If no channel found, assume Atom feed or malformed RSS
            if (new_channel == null) {
                new_channel = new_root;
            }

            // Collect new item GUIDs/links to avoid duplicates
            var new_item_ids = new Gee.HashSet<string>();
            for (Xml.Node* item = new_channel->children; item != null; item = item->next) {
                if (item->type == Xml.ElementType.ELEMENT_NODE && item->name == "item") {
                    string? id = extract_item_id(item);
                    if (id != null) {
                        new_item_ids.add(id);
                    }
                }
            }

            // Find old channel
            Xml.Node* old_channel = null;
            for (Xml.Node* node = old_root->children; node != null; node = node->next) {
                if (node->type == Xml.ElementType.ELEMENT_NODE && node->name == "channel") {
                    old_channel = node;
                    break;
                }
            }

            if (old_channel == null) {
                old_channel = old_root;
            }

            // Copy old items that aren't in new feed, up to MAX_FEED_ITEMS total
            int merged_count = 0;
            int total = new_item_ids.size;
            for (Xml.Node* item = old_channel->children; item != null && total < MAX_FEED_ITEMS; item = item->next) {
                if (item->type == Xml.ElementType.ELEMENT_NODE && item->name == "item") {
                    string? id = extract_item_id(item);
                    if (id != null && !new_item_ids.contains(id)) {
                        // Copy this item to new feed
                        Xml.Node* copied_item = item->copy(1); // Deep copy
                        new_channel->add_child(copied_item);
                        merged_count++;
                        total++;
                    }
                }
            }

            // Convert back to string
            string result = "";
            new_doc->dump_memory_enc(out result);

            delete old_doc;
            delete new_doc;

            GLib.print("  ✓ Merged %d unique old articles into new feed\n", merged_count);
            return result;

        } catch (Error e) {
            GLib.warning("Error merging feeds: %s", e.message);
            return new_feed; // Return new feed as fallback
        }
    }

    /**
     * Extract a unique identifier from an RSS item (GUID or link)
     * @param item The RSS item node
     * @return The item's unique identifier or null
     */
    private string? extract_item_id(Xml.Node* item) {
        for (Xml.Node* child = item->children; child != null; child = child->next) {
            if (child->type != Xml.ElementType.ELEMENT_NODE) continue;

            if (child->name == "guid" || child->name == "link") {
                string? content = child->get_content();
                if (content != null && content.length > 0) {
                    return content.strip();
                }
            }
        }
        return null;
    }
}
