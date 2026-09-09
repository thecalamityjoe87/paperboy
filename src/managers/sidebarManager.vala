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
using GLib;

// Data structures for sidebar representation
public enum SidebarItemType {
    CATEGORY,
    RSS_SOURCE,
    SPECIAL  // Front Page, My Feed, etc.
}

public struct SidebarItemData {
    public string id;              // category ID or "rssfeed:url"
    public string title;           // Display name
    public string? icon_key;       // For category icons (passed to CategoryIcons)
    public int unread_count;       // Badge count
    public bool is_selected;       // Currently active
    public SidebarItemType item_type;
}

public struct RssSourceItemData {
    public string name;
    public string url;
    public string? display_name;
    public string? icon_path;      // Path to saved icon file
    public string? icon_url;       // Fallback icon URL
    public int unread_count;
    public bool is_selected;
}

public struct SidebarSectionData {
    public string section_id;      // "special", "followed_sources", "popular_categories"
    public string title;
    public bool is_expandable;
    public bool is_expanded;
    public Gee.ArrayList<SidebarItemData?> items;
}

public delegate void SidebarActivateHandler(string cat, string title);
public delegate void RssFeedAddedCallback(bool success, string discovered_name);

/**
 * Logic-only sidebar manager - handles data and business logic without GTK widgets.
 * All UI building is delegated to SidebarView.
 */
public class SidebarManager : GLib.Object {
    private weak NewsWindow window;
    private SidebarActivateHandler? activate_cb;

    // Expandable sections state tracking (logic only)
    private bool followed_sources_expanded = true;
    private bool popular_categories_expanded = true;
    private bool podcasts_expanded = true;

    // Track currently selected item ID (data only)
    private string? currently_selected_id = null;

    // Track unread counts (data only - no widgets)
    private Gee.HashMap<string, int> category_unread_counts;
    private Gee.HashMap<string, int> source_unread_counts;
    // New (unplayed, published since the show was last opened) episode
    // counts per subscribed show, keyed by feed_id - filled in lazily by
    // refresh_podcast_new_count() below since it needs a network fetch,
    // unlike article unread counts which are already known locally.
    // Explicit hash/equal funcs: Gee.HashMap<int64?, V> without them
    // defaults to pointer identity on the boxed key, not value equality,
    // so has_key()/get() would never match a freshly-boxed int64 with the
    // same value as an existing key.
    private Gee.HashMap<int64?, int> podcast_new_counts =
        new Gee.HashMap<int64?, int>((v) => { return (uint) v; }, (a, b) => { return a == b; });
    
    // Track which categories have been visited by the user
    // Popular categories show "--" until visited, then show actual count
    private Gee.HashSet<string> visited_categories;
    // Track which sources have been visited by the user
    // Sources show "--" until visited, then show actual count
    private Gee.HashSet<string> visited_sources;

    // Signals to notify SidebarView of changes
    public signal void sidebar_rebuild_requested(Gee.ArrayList<SidebarSectionData?> sections);
    public signal void category_selected(string category_id, string title);
    public signal void rss_source_added(RssSourceItemData source);
    public signal void rss_source_removed(string url);
    public signal void rss_source_updated(RssSourceItemData source);
    // Targeted single-row add/remove for the Podcasts section - unlike RSS
    // sources (which still trigger a full rebuild_sidebar() on add/remove),
    // subscribing/unsubscribing shouldn't visibly rebuild the whole sidebar
    // for one row.
    public signal void podcast_subscription_added(SidebarItemData item);
    public signal void podcast_subscription_removed(string item_id);
    public signal void badge_updated(string item_id, int count, bool is_source);
    public signal void badge_updated_force(string item_id, int count, bool is_source);
    public signal void badge_placeholder_set(string item_id, bool is_source);
    public signal void all_badges_refresh_requested();
    public signal void expanded_state_changed(string section_name, bool expanded);
    public signal void selection_changed(string? item_id);

    public SidebarManager(NewsWindow window, SidebarActivateHandler? activate_cb = null) {
        GLib.Object();
        this.window = window;
        this.activate_cb = activate_cb;
        this.category_unread_counts = new Gee.HashMap<string, int>();
        this.source_unread_counts = new Gee.HashMap<string, int>();
        this.visited_categories = new Gee.HashSet<string>();
        this.visited_sources = new Gee.HashSet<string>();

        // Load saved expanded states from preferences
        load_expanded_states();

        // Load visited categories and sources from ArticleStateStore cache
        // This allows popular category and source badges to show immediately on startup
        if (window.article_state_store != null) {
            var cached_visited_cats = window.article_state_store.get_visited_categories();
            visited_categories.add_all(cached_visited_cats);
            var cached_visited_srcs = window.article_state_store.get_visited_sources();
            visited_sources.add_all(cached_visited_srcs);
        }

        // Listen for changes to custom RSS sources
        var store = Paperboy.RssSourceStore.get_instance();
        store.source_added.connect((s) => {
            Idle.add(() => {
                handle_source_added(s);
                return false;
            });
        });
        store.source_removed.connect((s) => {
            Idle.add(() => {
                handle_source_removed(s);
                return false;
            });
        });
        store.source_updated.connect((s) => {
            Idle.add(() => {
                handle_source_updated(s);
                return false;
            });
        });

        // Listen for podcast subscription changes so the Podcasts section's
        // sub-item list stays in sync - no lighter-weight targeted-update
        // path exists yet for these rows (unlike RSS sources' icon-only
        // update), so mirror source_added/source_removed's own
        // full-rebuild behavior here too.
        var podcast_store = Paperboy.PodcastSubscriptionStore.get_instance();
        podcast_store.subscription_added.connect((sub) => {
            Idle.add(() => {
                podcast_subscription_added(create_podcast_subscription_item_data(sub));
                refresh_podcast_new_count(sub);
                return false;
            });
        });
        podcast_store.subscription_removed.connect((feed_id) => {
            Idle.add(() => {
                podcast_subscription_removed("podcastshow:" + feed_id.to_string());
                podcast_new_counts.unset(feed_id);
                return false;
            });
        });

        // Opening a show's episode list (PodcastPane/PodcastDetailDialog)
        // already accounts for whatever was new - clear its badge
        // immediately rather than waiting for the next periodic refetch.
        var playback_state_store = Paperboy.PodcastPlaybackStateStore.get_instance();
        playback_state_store.show_viewed.connect((feed_id) => {
            Idle.add(() => {
                podcast_new_counts.set(feed_id, 0);
                badge_updated("podcastshow:" + feed_id.to_string(), 0, false);
                return false;
            });
        });

        // Kick off an initial fetch for every subscribed show so badges
        // populate shortly after startup, same "fetch in the background,
        // update the badge when it lands" idea as ArticleStateStore's
        // initial metadata fetch.
        foreach (var sub in podcast_store.get_all_subscriptions()) {
            refresh_podcast_new_count(sub);
        }

        // Listen for article viewed/unviewed changes so badges update immediately
        if (window.article_state_store != null) {
            window.article_state_store.viewed_status_changed.connect((url, viewed) => {
                // Run in Idle to avoid contention with the emitter
                Idle.add(() => {
                        // Update categories containing this URL
                        var cats = window.article_state_store.get_categories_for_url(url);
                        foreach (var c in cats) {
                            update_badge_for_category(c);
                        }

                        // Update sources containing this URL
                        var srcs = window.article_state_store.get_sources_for_url(url);
                        foreach (var s in srcs) {
                            update_badge_for_source(s);
                        }

                        // If the article is saved, update the Saved badge as well
                            if (window.article_state_store.is_saved(url)) {
                                update_badge_for_category("saved");
                            }
                    return false;
                });
            });
        }
    }

    private void load_expanded_states() {
        var prefs = NewsPreferences.get_instance();
        followed_sources_expanded = prefs.sidebar_followed_sources_expanded;
        popular_categories_expanded = prefs.sidebar_popular_categories_expanded;
        podcasts_expanded = prefs.sidebar_podcasts_expanded;
    }

    private void save_followed_sources_state() {
        var prefs = NewsPreferences.get_instance();
        prefs.sidebar_followed_sources_expanded = followed_sources_expanded;
        prefs.save_config();
    }

    private void save_popular_categories_state() {
        var prefs = NewsPreferences.get_instance();
        prefs.sidebar_popular_categories_expanded = popular_categories_expanded;
        prefs.save_config();
    }

    private void save_podcasts_expanded_state() {
        var prefs = NewsPreferences.get_instance();
        prefs.sidebar_podcasts_expanded = podcasts_expanded;
        prefs.save_config();
    }

    /**
     * Toggle expanded state for a section
     */
    public void toggle_section_expanded(string section_id) {
        if (section_id == "followed_sources") {
            followed_sources_expanded = !followed_sources_expanded;
            save_followed_sources_state();
            expanded_state_changed(section_id, followed_sources_expanded);
        } else if (section_id == "popular_categories") {
            popular_categories_expanded = !popular_categories_expanded;
            save_popular_categories_state();
            expanded_state_changed(section_id, popular_categories_expanded);
        } else if (section_id == "podcasts_entry") {
            podcasts_expanded = !podcasts_expanded;
            save_podcasts_expanded_state();
            expanded_state_changed(section_id, podcasts_expanded);
        }
    }

    /**
     * Get all sidebar sections with their items as data structures
     */
    public Gee.ArrayList<SidebarSectionData?> get_sidebar_sections() {
        var sections = new Gee.ArrayList<SidebarSectionData?>();

        // Section 1: Special items (Top Ten, Front Page, My Feed, Local News, Saved)
        var special_section = SidebarSectionData();
        special_section.section_id = "special";
        special_section.title = "";
        special_section.is_expandable = false;
        special_section.is_expanded = true;
        special_section.items = new Gee.ArrayList<SidebarItemData?>();

        special_section.items.add(create_item_data("Top Ten", "topten", SidebarItemType.SPECIAL));
        special_section.items.add(create_item_data("Front Page", "frontpage", SidebarItemType.SPECIAL));
        special_section.items.add(create_item_data("My Feed", "myfeed", SidebarItemType.SPECIAL));
        special_section.items.add(create_item_data("Local News", "local_news", SidebarItemType.SPECIAL));
        special_section.items.add(create_item_data("Saved", "saved", SidebarItemType.SPECIAL));

        sections.add(special_section);

        // Section 2: Popular Categories
        var categories_section = SidebarSectionData();
        categories_section.section_id = "popular_categories";
        categories_section.title = "Popular Categories";
        categories_section.is_expandable = true;
        categories_section.is_expanded = popular_categories_expanded;
        categories_section.items = new Gee.ArrayList<SidebarItemData?>();

        // Add categories based on selected sources
        add_categories_for_sources(categories_section.items);

        sections.add(categories_section);

        // Section 3: Followed Sources (RSS feeds)
        var followed_section = SidebarSectionData();
        followed_section.section_id = "followed_sources";
        followed_section.title = "Feeds";
        followed_section.is_expandable = true;
        followed_section.is_expanded = followed_sources_expanded;
        followed_section.items = new Gee.ArrayList<SidebarItemData?>();

        var store = Paperboy.RssSourceStore.get_instance();
        var sources = store.get_all_sources();
        foreach (var source in sources) {
            if (!window.prefs.preferred_source_enabled("custom:" + source.url)) continue;
            followed_section.items.add(create_rss_item_data(source));
        }

        sections.add(followed_section);

        // Section 4: Podcasts - "Discover" (the main browse/hero page,
        // same destination the old flat "Podcasts" item pointed to) plus
        // one row per subscribed show. Expandable like Feeds, since it can
        // grow the same way as the user subscribes to more shows.
        var podcasts_section = SidebarSectionData();
        podcasts_section.section_id = "podcasts_entry";
        podcasts_section.title = "Podcasts";
        podcasts_section.is_expandable = true;
        podcasts_section.is_expanded = podcasts_expanded;
        podcasts_section.items = new Gee.ArrayList<SidebarItemData?>();
        // id stays "podcasts" (the routing key) - only title/icon change.
        var discover_item = create_item_data("Find Podcasts", "podcasts", SidebarItemType.SPECIAL);
        discover_item.icon_key = "podcasts_discover";
        podcasts_section.items.add(discover_item);

        var podcast_store = Paperboy.PodcastSubscriptionStore.get_instance();
        foreach (var sub in podcast_store.get_all_subscriptions()) {
            podcasts_section.items.add(create_podcast_subscription_item_data(sub));
        }

        sections.add(podcasts_section);

        return sections;
    }

    /**
     * Build the sidebar rows according to currently selected source
     */
    public void rebuild_sidebar() {
        // Update currently selected ID from preferences
        currently_selected_id = window.prefs.category;

        // Get all sections with data
        var sections = get_sidebar_sections();

        // Emit signal for SidebarView to rebuild UI
        sidebar_rebuild_requested(sections);

        // Refresh badge counts after rebuild
        refresh_all_badge_counts();
    }

    private void add_categories_for_sources(Gee.ArrayList<SidebarItemData?> items) {
        // If multiple preferred sources are selected, build union of supported categories
        if (window.prefs.preferred_sources != null && window.prefs.preferred_sources.size > 1) {
            var allowed = new Gee.HashMap<string, bool>();
            string[] default_cats = { "general", "us", "technology", "business", "science", "sports", "health", "entertainment", "politics", "lifestyle" };
            foreach (var c in default_cats) {
                allowed.set(c, true);
            }

            // Check if at least one source supports lifestyle
            bool any_source_supports_lifestyle = false;
            foreach (var id in window.prefs.preferred_sources) {
                NewsSource src = parse_source_id(id);
                if (NewsService.supports_category(src, "lifestyle")) {
                    any_source_supports_lifestyle = true;
                }
            }

            // If no source supports lifestyle, remove it from allowed categories
            if (!any_source_supports_lifestyle) {
                allowed.unset("lifestyle");
            }

            foreach (var id in window.prefs.preferred_sources) {
                if (id == "bloomberg") {
                    allowed.set("markets", true);
                    allowed.set("industries", true);
                    allowed.set("economics", true);
                }
            }

            string[] priority = { "general", "us", "technology", "business", "markets", "industries", "economics", "sports", "science", "health", "entertainment", "politics", "lifestyle" };
            foreach (var cat in priority) {
                if (allowed.has_key(cat) && allowed.get(cat)) {
                    items.add(create_item_data(window.category_display_name_for(cat), cat, SidebarItemType.CATEGORY));
                }
            }
        } else {
            // Single-source path: show categories appropriate to the selected source
            NewsSource sidebar_eff = effective_news_source();
            if (sidebar_eff == NewsSource.BLOOMBERG) {
                items.add(create_item_data("Markets", "markets", SidebarItemType.CATEGORY));
                items.add(create_item_data("Industries", "industries", SidebarItemType.CATEGORY));
                items.add(create_item_data("Economics", "economics", SidebarItemType.CATEGORY));
                items.add(create_item_data("Technology", "technology", SidebarItemType.CATEGORY));
                items.add(create_item_data("Politics", "politics", SidebarItemType.CATEGORY));
            } else {
                items.add(create_item_data("World News", "general", SidebarItemType.CATEGORY));
                items.add(create_item_data("US News", "us", SidebarItemType.CATEGORY));
                items.add(create_item_data("Technology", "technology", SidebarItemType.CATEGORY));
                items.add(create_item_data("Business", "business", SidebarItemType.CATEGORY));
                items.add(create_item_data("Sports", "sports", SidebarItemType.CATEGORY));
                items.add(create_item_data("Science", "science", SidebarItemType.CATEGORY));
                items.add(create_item_data("Health", "health", SidebarItemType.CATEGORY));
                items.add(create_item_data("Entertainment", "entertainment", SidebarItemType.CATEGORY));
                items.add(create_item_data("Politics", "politics", SidebarItemType.CATEGORY));

                if (NewsService.supports_category(sidebar_eff, "lifestyle")) {
                    items.add(create_item_data("Lifestyle", "lifestyle", SidebarItemType.CATEGORY));
                }
            }
        }
    }

    private SidebarItemData create_item_data(string title, string id, SidebarItemType type) {
        var item = SidebarItemData();
        item.id = id;
        item.title = title;
        item.icon_key = id;  // Use ID as icon key for CategoryIcons
        item.item_type = type;
        item.is_selected = (currently_selected_id == id);
        item.unread_count = get_unread_count_for_item(id, type);
        return item;
    }

    private SidebarItemData create_rss_item_data(Paperboy.RssSource source) {
        var item = SidebarItemData();
        item.id = "rssfeed:" + source.url;
        item.title = source.name;
        item.icon_key = "rss:" + source.url;  // Special prefix for RSS sources
        item.item_type = SidebarItemType.RSS_SOURCE;
        item.is_selected = (currently_selected_id == item.id);
        item.unread_count = get_unread_count_for_source(source.name);
        return item;
    }

    // A subscribed show's sidebar row. icon_key is the fixed "podcasts"
    // glyph (not per-show artwork - keeps this simple/consistent with the
    // rest of the sidebar rather than replicating RSS rows' per-favicon
    // loading), item_type SPECIAL since it's not a real news category and
    // doesn't participate in category-badge logic (see get_unread_count_
    // for_item, which only handles CATEGORY/RSS_SOURCE).
    private SidebarItemData create_podcast_subscription_item_data(Paperboy.PodcastSubscription sub) {
        var item = SidebarItemData();
        // Keyed by feed_id, not feed_url: PodcastSubscriptionStore.
        // subscription_removed only hands back a feed_id, so this id
        // scheme lets that signal map straight to a sidebar item id with
        // no lookup needed (see the constructor's wiring above).
        item.id = "podcastshow:" + sub.feed_id.to_string();
        item.title = sub.title;
        item.icon_key = "podcasts";
        item.item_type = SidebarItemType.SPECIAL;
        item.is_selected = (currently_selected_id == item.id);
        item.unread_count = podcast_new_counts.has_key(sub.feed_id) ? podcast_new_counts.get(sub.feed_id) : 0;
        return item;
    }

    // Fetches this show's most recent episodes and counts how many are
    // both unplayed and published after the show was last opened, then
    // updates the sidebar badge once the count is known. A synthetic
    // (negative) feed_id means the show was added by direct feed URL
    // rather than discovered via PodcastIndex, so it has no real
    // PodcastIndex id to query episodes_for_feed() with - re-parse its own
    // feed directly instead (PodcastFeedResolver.fetch_episodes), same as
    // PodcastPane/PodcastDetailDialog already do for these shows. Needs a
    // Soup.Session, so this path is skipped (badge stays 0) if `window` or
    // its session isn't available yet.
    private void refresh_podcast_new_count(Paperboy.PodcastSubscription sub) {
        int64 feed_id = sub.feed_id;
        var playback_state_store = Paperboy.PodcastPlaybackStateStore.get_instance();
        int64 last_viewed = playback_state_store.get_last_viewed(feed_id);

        if (feed_id > 0) {
            var service = Paperboy.PodcastIndexService.get_instance();
            service.episodes_for_feed(feed_id, 10, (episodes) => {
                apply_new_count(feed_id, episodes, last_viewed, playback_state_store);
            });
        } else if (window != null && window.session != null) {
            var resolver = Paperboy.PodcastFeedResolver.get_instance();
            resolver.fetch_episodes(sub.feed_url, sub.title, sub.image_url, window.session, (episodes) => {
                apply_new_count(feed_id, episodes, last_viewed, playback_state_store);
            });
        }
    }

    private void apply_new_count(int64 feed_id, Gee.ArrayList<Paperboy.PodcastEpisode> episodes, int64 last_viewed,
            Paperboy.PodcastPlaybackStateStore playback_state_store) {
        int count = 0;
        foreach (var episode in episodes) {
            if (playback_state_store.is_episode_played(episode.episode_id)) continue;
            var dt = DateUtils.parse_published_datetime(episode.published);
            if (dt == null || dt.to_unix() <= last_viewed) continue;
            count++;
        }
        podcast_new_counts.set(feed_id, count);
        badge_updated("podcastshow:" + feed_id.to_string(), count, false);
    }

    private Paperboy.PodcastSubscription? find_subscription_by_feed_id(int64 feed_id) {
        var store = Paperboy.PodcastSubscriptionStore.get_instance();
        foreach (var sub in store.get_all_subscriptions()) {
            if (sub.feed_id == feed_id) return sub;
        }
        return null;
    }

    private int get_unread_count_for_item(string id, SidebarItemType type) {
        if (window.article_state_store == null) {
            return 0;
        }

        if (type == SidebarItemType.RSS_SOURCE) {
            // Extract name from "rssfeed:url" format
            if (id.has_prefix("rssfeed:")) {
                string url = id.substring(8);
                var store = Paperboy.RssSourceStore.get_instance();
                var source = store.get_source_by_url(url);
                if (source != null) {
                    return window.article_state_store.get_unread_count_for_source(source.name);
                }
            }
            return 0;
        }

        // Saved: badge shows total number of saved articles (bookmarks)
        // This is more useful than "unread saved" since saved articles are
        // meant to be a user's reading list, not an unread queue.
        if (id == "saved") {
            // Show number of unread saved items rather than total saved count
            // so the badge reflects items still to read.
            return window.article_state_store.get_unread_saved_count();
        }

        // Frontpage and Top Ten: populated by startup metadata fetch and
        // their own fetchers, so use category-based unread count
        if (id == "frontpage" || id == "topten") {
            return window.article_state_store.get_unread_count_for_category(id);
        }

        // My Feed: Articles fetched for My Feed are registered under the
        // "myfeed" category_id, so we can use category-based unread count.
        // This includes articles from personalized categories and custom
        // RSS sources that the user has configured for My Feed.
        // IMPORTANT: Only show badge if personalized_feed_enabled is true
        // Also filter by currently enabled sources only
        if (id == "myfeed") {
            if (!window.prefs.personalized_feed_enabled) {
                return 0;
            }
            var displayed = window.article_manager != null ? window.article_manager.get_myfeed_displayed_urls() : null;
            // Placeholder until My Feed has actually been built this
            // session (is_category_visited persists across app restarts,
            // but displayed_urls is reset fresh each launch - gating on the
            // persisted flag would skip the placeholder even when there's
            // no real data yet this session).
            if (displayed == null || displayed.size == 0) {
                return -1;
            }
            return window.article_state_store.get_unread_count_for_myfeed(displayed);
        }

        // Local News: use category-based unread count (articles registered
        // under "local_news" are local articles)
        if (id == "local_news") {
            return window.article_state_store.get_unread_count_for_category(id);
        }

        // Popular categories (CATEGORY type only): return -1 (placeholder) until user visits them
        if (type == SidebarItemType.CATEGORY) {
            if (is_popular_category(id) && !is_category_visited(id)) {
                return -1;
            }
        }

        // All other categories
        return window.article_state_store.get_unread_count_for_category(id);
    }

    private int get_unread_count_for_source(string source_name) {
            if (window.article_state_store == null) {
                return 0;
            }
            // Show placeholder "--" until user visits this source for the first time
            if (!is_source_visited(source_name)) {
                return -1;
            }
            return window.article_state_store.get_unread_count_for_source(source_name);
    }

    private NewsSource effective_news_source() {
        if (window.prefs.preferred_sources != null && window.prefs.preferred_sources.size == 1) {
            string id = window.prefs.preferred_sources.get(0);
            return parse_source_id(id);
        }
        return window.prefs.news_source;
    }

    private NewsSource parse_source_id(string id) {
        switch (id) {
            case "guardian": return NewsSource.GUARDIAN;
            case "reddit": return NewsSource.REDDIT;
            case "bbc": return NewsSource.BBC;
            case "nytimes": return NewsSource.NEW_YORK_TIMES;
            case "wsj": return NewsSource.WALL_STREET_JOURNAL;
            case "bloomberg": return NewsSource.BLOOMBERG;
            case "abc": return NewsSource.ABC_NEWS;
            case "npr": return NewsSource.NPR;
            case "fox": return NewsSource.FOX;
            default: return window.prefs.news_source;
        }
    }

    /**
     * Handle category/item activation
     */
    public void handle_item_activation(string id, string title) {
        // A subscribed show's row just opens its detail pane - PodcastPane
        // is a floating overlay (Gtk.Revealer on root_overlay, independent
        // of whichever page is showing underneath), not something tied to
        // being on the Podcasts page. So this deliberately does NOT
        // navigate there or touch prefs.category/selection state - if
        // you're reading a news article and click a subscription, you stay
        // exactly where you are and the pane just slides up over it.
        if (id.has_prefix("podcastshow:")) {
            int64 feed_id = int64.parse(id.substring("podcastshow:".length));
            var subscription = find_subscription_by_feed_id(feed_id);
            if (subscription != null && window.podcast_pane != null) {
                window.podcast_pane.open_for_show(subscription.to_show());
            }
            return;
        }

        string validated = validate_category_for_sources(id);

        window.prefs.category = validated;
        window.update_category_icon();
        window.update_local_news_ui();
        window.prefs.save_config();

        // Mark category as visited so badge can update from placeholder
        mark_category_visited(validated);

        // If this is an RSS source, also mark the source as visited
        if (validated.has_prefix("rssfeed:")) {
            string url = validated.substring(8);
            var store = Paperboy.RssSourceStore.get_instance();
            var source = store.get_source_by_url(url);
            if (source != null) {
                mark_source_visited(source.name);
            }
        }

        // Update selection state
        currently_selected_id = validated;
        selection_changed(validated);

        // Notify listeners
        category_selected(validated, title);
        if (activate_cb != null) {
            activate_cb(validated, title);
        }
    }

    private string validate_category_for_sources(string requested_cat) {
        // App-level categories that don't depend on news sources
        if (requested_cat == "saved" || requested_cat == "topten" ||
            requested_cat == "myfeed" || requested_cat == "local_news" ||
            requested_cat == "podcasts" ||
            requested_cat.has_prefix("rssfeed:")) {
            return requested_cat;
        }

        bool category_supported = false;
        if (window.prefs.preferred_sources != null && window.prefs.preferred_sources.size > 1) {
            foreach (var id in window.prefs.preferred_sources) {
                NewsSource src = parse_source_id(id);
                if (NewsService.supports_category(src, requested_cat)) {
                    category_supported = true;
                    break;
                }
            }
        } else {
            NewsSource current_source = effective_news_source();
            category_supported = NewsService.supports_category(current_source, requested_cat);
        }

        if (!category_supported) {
            return "frontpage";
        }
        return requested_cat;
    }

    /**
     * Handle RSS source added
     */
    private void handle_source_added(Paperboy.RssSource source) {
        var item_data = create_rss_source_item_data(source);
        rss_source_added(item_data);
    }

    /**
     * Handle RSS source removed
     */
    private void handle_source_removed(Paperboy.RssSource source) {
        rss_source_removed(source.url);

        // If this removed source was selected, fall back to Front Page
        if (currently_selected_id == "rssfeed:" + source.url) {
            handle_item_activation("frontpage", "Front Page");
        }
    }

    /**
     * Handle RSS source updated
     */
    private void handle_source_updated(Paperboy.RssSource source) {
        var item_data = create_rss_source_item_data(source);
        rss_source_updated(item_data);
    }

    private RssSourceItemData create_rss_source_item_data(Paperboy.RssSource source) {
        var item = RssSourceItemData();
        item.name = source.name;
        item.url = source.url;
        item.display_name = SourceMetadata.get_display_name_for_source(source.name);
        item.icon_path = get_icon_path_for_source(source);
        item.icon_url = get_icon_url_for_source(source);
        item.unread_count = get_unread_count_for_source(source.name);
        item.is_selected = (currently_selected_id == "rssfeed:" + source.url);
        return item;
    }

    private string? get_icon_path_for_source(Paperboy.RssSource source) {
        // Use SourceMetadata.get_valid_saved_filename_for_source (validates file exists)
        string? icon_filename = SourceMetadata.get_valid_saved_filename_for_source(source.name, CategoryIconsUtils.SIDEBAR_SOURCE_ICON_SIZE, CategoryIconsUtils.SIDEBAR_SOURCE_ICON_SIZE);
        if (icon_filename != null && icon_filename.length > 0) {
            var data_dir = GLib.Environment.get_user_data_dir();
            var icon_path = GLib.Path.build_filename(data_dir, "paperboy", "source_logos", icon_filename);
            if (GLib.FileUtils.test(icon_path, GLib.FileTest.EXISTS)) {
                return icon_path;
            }
        }
        return null;
    }

    private string? get_icon_url_for_source(Paperboy.RssSource source) {
        // Priority 1: API logo URL from SourceMetadata
        string? meta_logo_url = SourceMetadata.get_logo_url_for_source(source.name);
        if (meta_logo_url != null && meta_logo_url.length > 0 &&
            (meta_logo_url.has_prefix("http://") || meta_logo_url.has_prefix("https://"))) {
            return meta_logo_url;
        }

        // Priority 2: Google favicon service
        string? host = UrlUtils.extract_host_from_url(source.url);
        if (host != null && host.length > 0) {
            return "https://www.google.com/s2/favicons?domain=" + host + "&sz=128";
        }

        return null;
    }

    /**
     * Update for source change (rebuilds sidebar)
     */
    public void update_for_source_change() {
        rebuild_sidebar();
    }

    /**
     * Check if a category is a "popular category" (not special)
     * Popular categories show "--" until visited by the user
     */
    private bool is_popular_category(string category_id) {
        // Special categories always show their count
        if (category_id == "frontpage" || category_id == "topten" ||
            category_id == "myfeed" || category_id == "local_news" ||
            category_id == "saved" || category_id == "podcasts") {
            return false;
        }
        // RSS feeds are not popular categories
        if (category_id.has_prefix("rssfeed:")) {
            return false;
        }
        // Everything else is a popular category
        return true;
    }

    /**
     * Mark a category as visited by the user
     * This enables badge updates for popular categories
     */
    public void mark_category_visited(string category_id) {
        visited_categories.add(category_id);
        // Persist to ArticleStateStore so it's cached and available on next startup
        if (window != null && window.article_state_store != null) {
            window.article_state_store.mark_category_visited(category_id);
        }
    }

    /**
     * Check if a category has been visited
     */
    public bool is_category_visited(string category_id) {
        return visited_categories.contains(category_id);
    }

    /**
     * Mark a source as visited by the user
     * This enables badge updates for sources
     */
    public void mark_source_visited(string source_name) {
        visited_sources.add(source_name);
        // Persist to ArticleStateStore so it's cached and available on next startup
        if (window != null && window.article_state_store != null) {
            window.article_state_store.mark_source_visited(source_name);
        }
    }

    /**
     * Check if a source has been visited
     */
    public bool is_source_visited(string source_name) {
        return visited_sources.contains(source_name);
    }

    /**
     * Update unread count badge for a specific category
     */
    public void update_badge_for_category(string category_id) {
        int unread_count = 0;
        // My Feed has no real count until it's actually been built this
        // session (displayed_urls is reset fresh each launch, unlike the
        // persisted is_category_visited flag popular categories use) -
        // keep showing "--" until then.
        bool myfeed_has_data = false;
        if (window.article_state_store != null) {
            if (category_id == "myfeed") {
                var displayed = window.article_manager != null ? window.article_manager.get_myfeed_displayed_urls() : null;
                myfeed_has_data = displayed != null && displayed.size > 0;
                unread_count = window.article_state_store.get_unread_count_for_myfeed(displayed);
            } else {
                unread_count = window.article_state_store.get_unread_count_for_category(category_id);
            }
        }
        category_unread_counts.set(category_id, unread_count);

        if (category_id == "myfeed") {
            if (!myfeed_has_data) return;
        } else if (is_popular_category(category_id) && !is_category_visited(category_id)) {
            // Don't update - keep placeholder
            return;
        }

        badge_updated_force(category_id, unread_count, false);
    }

    /**
     * Schedule a badge refresh for a category after a delay.
     * Uses fetch_sequence to ignore stale updates from cancelled fetches.
     *
     * @param category_id The category to refresh badge for
     * @param fetch_seq The fetch sequence number to check against
     * @param delay_ms Delay in milliseconds before refresh (default 1500)
     */
    public void schedule_badge_refresh(string category_id, uint fetch_seq, uint delay_ms = 1500) {
        Timeout.add(delay_ms, () => {
            if (fetch_seq != FetchContext.current) return false;
                update_badge_for_category(category_id);
            return false;
        });
    }

    /**
     * Schedule a badge refresh for an RSS source after a delay.
     * Uses fetch_sequence to ignore stale updates from cancelled fetches.
     *
     * @param source_name The source name to refresh badge for
     * @param fetch_seq The fetch sequence number to check against
     * @param delay_ms Delay in milliseconds before refresh (default 1500)
     */
    public void schedule_source_badge_refresh(string source_name, uint fetch_seq, uint delay_ms = 1500) {
        Timeout.add(delay_ms, () => {
            if (fetch_seq != FetchContext.current) return false;
                update_badge_for_source(source_name);
            return false;
        });
    }

    /**
     * Update unread count badge for a specific source
     */
    public void update_badge_for_source(string source_name) {
        int unread_count = 0;
        if (window.article_state_store != null) {
            unread_count = window.article_state_store.get_unread_count_for_source(source_name);
        }
        source_unread_counts.set(source_name, unread_count);
        
        // Convert source name to item ID format ("rssfeed:" + url)
        var store = Paperboy.RssSourceStore.get_instance();
        var sources = store.get_all_sources();
        foreach (var source in sources) {
            if (source.name == source_name) {
                string item_id = "rssfeed:" + source.url;
                badge_updated_force(item_id, unread_count, true);
                return;
            }
        }
    }

    /**
     * Refresh all unread count badges
     * Runs asynchronously to avoid blocking main thread with expensive count calculations
     */
    public void refresh_all_badge_counts() {
        // CRITICAL: Do NOT refresh badges during initial_phase
        // Modifying the sidebar widget tree (via badge.set_visible()) while images
        // are being loaded can cause GTK to invalidate or lose paintable references
        // on Picture widgets in the main content area
        if (window.loading_state != null && window.loading_state.initial_phase) {
            return;
        }

        // Run badge refresh in Idle to avoid blocking if called during startup
        // This prevents hanging when multiple RSS sources need unread counts calculated
        Idle.add(() => {
            all_badges_refresh_requested();
            return false;
        });
    }

    /**
     * Set badge to show loading placeholder for source
     */
    public void set_badge_placeholder_for_source(string source_name) {
        // Convert source name to item ID format ("rssfeed:" + url)
        var store = Paperboy.RssSourceStore.get_instance();
        var sources = store.get_all_sources();
        foreach (var source in sources) {
            if (source.name == source_name) {
                string item_id = "rssfeed:" + source.url;
                badge_placeholder_set(item_id, true);
                return;
            }
        }
    }

    /**
     * Mark all articles from a source as read
     */
    public void mark_all_read_for_source(string source_name) {
        if (window.article_state_store == null) {
            return;
        }
        
        var articles = window.article_state_store.get_articles_for_source(source_name);
        if (articles != null) {
            foreach (string url in articles) {
                window.article_state_store.mark_viewed(url);
            }
        }
        
        update_badge_for_source(source_name);
        
        // Refresh the view to update viewed badges on cards
        if (window.view_state != null) {
            window.view_state.refresh_viewed_badges_for_source(source_name);
        }
    }

    /**
     * Mark all articles from a source as unread
     */
    public void mark_all_unread_for_source(string source_name) {
        if (window.article_state_store == null) {
            return;
        }
        
        var articles = window.article_state_store.get_articles_for_source(source_name);
        if (articles != null) {
            foreach (string url in articles) {
                window.article_state_store.mark_unviewed(url);
            }
        }
        
        update_badge_for_source(source_name);
        
        // Refresh the view to update viewed badges on cards
        if (window.view_state != null) {
            window.view_state.refresh_viewed_badges_for_source(source_name);
        }
    }

    /**
     * Remove an RSS source
     */
    public void remove_rss_source(string source_url) {
        var rss_store = Paperboy.RssSourceStore.get_instance();
        
        // Check if we're currently viewing this RSS source
        bool is_currently_viewing = false;
        if (window.prefs.category != null && window.prefs.category.has_prefix("rssfeed:")) {
            if (window.prefs.category.length > 8) {
                string current_url = window.prefs.category.substring(8);
                if (current_url == source_url) {
                    is_currently_viewing = true;
                }
            }
        }
        
        // Remove from database
        rss_store.remove_source(source_url);
        
        // Remove from preferences if enabled
        if (window.prefs.preferred_source_enabled("custom:" + source_url)) {
            window.prefs.set_preferred_source_enabled("custom:" + source_url, false);
            window.prefs.save_config();
        }
        
        // If we were viewing this source, navigate to Front Page
        if (is_currently_viewing) {
            GLib.Idle.add(() => {
                window.prefs.category = "frontpage";
                window.prefs.save_config();
                window.fetch_news();
                return false;
            });
        }
    }

    /**
     * Set badge to show loading placeholder for category
     */
    public void set_badge_placeholder_for_category(string category_id) {
        badge_placeholder_set(category_id, false);
    }

    /**
     * Add a new RSS feed with robust metadata discovery
     */
    public void add_rss_feed(string name, string url, owned RssFeedAddedCallback callback) {
        window.source_manager.add_rss_feed_with_discovery(url, name, (success, discovered_name) => {
            callback(success, discovered_name);
        });
    }

    /**
     * Get current selected item ID
     */
    public string? get_selected_item_id() {
        return currently_selected_id;
    }

    /**
     * Get RSS source icon data for a given source
     */
    public RssSourceItemData? get_rss_source_data(string url) {
        var store = Paperboy.RssSourceStore.get_instance();
        var source = store.get_source_by_url(url);
        if (source != null) {
            return create_rss_source_item_data(source);
        }
        return null;
    }
}
