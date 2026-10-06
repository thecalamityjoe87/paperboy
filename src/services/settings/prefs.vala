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
using Adw;

// A favorited team's identity - league key + ESPN team id. See
// NewsPreferences.favorite_teams()/add_favorite_team()/etc.
public class FavoriteTeamRef : GLib.Object {
    public string league_key;
    public string team_id;

    public FavoriteTeamRef(string league_key, string team_id) {
        this.league_key = league_key;
        this.team_id = team_id;
    }
}

public class NewsPreferences : GLib.Object {
    private static NewsPreferences? instance = null;
    private GLib.Settings settings;
    private GLib.KeyFile config;  // Used for preferred_sources (user-generated data)
    private string config_path;
    // True while we're loading/migrating the KeyFile to avoid triggering
    // saves from setters during initialization.
    private bool loading = false;
    // One-time migration guard: adding a custom RSS source never enabled it
    // in preferred_sources (a bug - it required manually flipping the
    // source's switch in Settings afterward), so existing installs can have
    // sources that look "disabled" despite having been added intentionally.
    // Runs once per install; see load_config()/save_config().
    private bool custom_sources_enable_migration_done = false;
    // One-time migration guard: an empty preferred_sources list used to mean
    // "every built-in source on". It's now seeded with those sources
    // explicitly, so afterwards an empty list really means none.
    private bool builtin_sources_seeded = false;

    // GSettings-backed properties (automatically persisted)
    public string category {
        owned get {
            string cat = settings.get_string("category");
            // Top Ten no longer exists as its own page - existing users
            // who had it selected land on the Front Page instead, where
            // its content now lives as the Trending section.
            return (cat == "topten") ? "frontpage" : cat;
        }
        set { settings.set_string("category", value); }
    }

    public bool personalized_feed_enabled {
        get { return settings.get_boolean("personalized-feed-enabled"); }
        set { settings.set_boolean("personalized-feed-enabled", value); }
    }

    // Whether the user has completed (or skipped) the first-run onboarding
    // dialog. Distinct from `first_run` (which tracks whether the config
    // file existed at startup and drives one-time migrations) so the
    // onboarding dialog can be re-opened from the menu without re-running
    // those migrations.
    public bool onboarding_completed {
        get { return settings.get_boolean("onboarding-completed"); }
        set { settings.set_boolean("onboarding-completed", value); }
    }

    // Google News edition id ("DE:de"), or "" to follow the system.
    // Setting it pushes the choice to GoogleNewsUtils.
    public string news_edition {
        owned get { return settings.get_string("news-edition"); }
        set {
            settings.set_string("news-edition", value);
            GoogleNewsUtils.set_chosen(value);
        }
    }

    // Preferred app color scheme: "system", "light", or "dark". Setting
    // this immediately applies it via Adw.StyleManager so callers don't
    // need to separately push the change to the UI.
    public string color_scheme {
        owned get { return settings.get_string("color-scheme"); }
        set {
            settings.set_string("color-scheme", value);
            apply_color_scheme();
        }
    }

    // Push the stored color-scheme preference to Adw.StyleManager. Called
    // once at startup (in case the app doesn't already default to "system"
    // the way libadwaita does) and again whenever `color_scheme` is set.
    public void apply_color_scheme() {
        var sm = Adw.StyleManager.get_default();
        if (sm == null) return;
        switch (color_scheme) {
            case "light": sm.set_color_scheme(Adw.ColorScheme.FORCE_LIGHT); break;
            case "dark": sm.set_color_scheme(Adw.ColorScheme.FORCE_DARK); break;
            default: sm.set_color_scheme(Adw.ColorScheme.DEFAULT); break;
        }
    }

    public bool myfeed_custom_only {
        get { return settings.get_boolean("myfeed-custom-only"); }
        set { settings.set_boolean("myfeed-custom-only", value); }
    }

    // Opt-in preview rows for other app features shown in My Feed - see
    // MyFeedExtrasController.
    public bool myfeed_show_sports {
        get { return settings.get_boolean("myfeed-show-sports"); }
        set { settings.set_boolean("myfeed-show-sports", value); }
    }

    public bool myfeed_show_market {
        get { return settings.get_boolean("myfeed-show-market"); }
        set { settings.set_boolean("myfeed-show-market", value); }
    }

    public bool myfeed_show_podcasts {
        get { return settings.get_boolean("myfeed-show-podcasts"); }
        set { settings.set_boolean("myfeed-show-podcasts", value); }
    }

    public bool myfeed_show_magazines {
        get { return settings.get_boolean("myfeed-show-magazines"); }
        set { settings.set_boolean("myfeed-show-magazines", value); }
    }

    public bool sidebar_followed_sources_expanded {
        get { return settings.get_boolean("sidebar-followed-sources-expanded"); }
        set { settings.set_boolean("sidebar-followed-sources-expanded", value); }
    }

    public bool sidebar_local_news_expanded {
        get { return settings.get_boolean("sidebar-local-news-expanded"); }
        set { settings.set_boolean("sidebar-local-news-expanded", value); }
    }

    public bool sidebar_popular_categories_expanded {
        get { return settings.get_boolean("sidebar-popular-categories-expanded"); }
        set { settings.set_boolean("sidebar-popular-categories-expanded", value); }
    }

    public bool sidebar_podcasts_expanded {
        get { return settings.get_boolean("sidebar-podcasts-expanded"); }
        set { settings.set_boolean("sidebar-podcasts-expanded", value); }
    }

    // Legacy single-location keys, only read to migrate into local-areas.
    public string user_location {
        owned get { return settings.get_string("user-location"); }
        set { settings.set_string("user-location", value); }
    }

    public string user_location_city {
        owned get { return settings.get_string("user-location-city"); }
        set { settings.set_string("user-location-city", value); }
    }

    public string user_location_news_query {
        owned get { return settings.get_string("user-location-news-query"); }
        set { settings.set_string("user-location-news-query", value); }
    }

    public const int MAX_LOCAL_AREAS = 5;

    public string active_local_area_key {
        owned get { return settings.get_string("active-local-area"); }
        set { settings.set_string("active-local-area", value); }
    }

    // Saved Local News locations, in sidebar order. Migrates the old
    // single-location keys into the list on first read.
    public Gee.ArrayList<LocalArea> get_local_areas() {
        var areas = new Gee.ArrayList<LocalArea>();
        var iter = settings.get_value("local-areas").iterator();
        string query, city;
        while (iter.next("(ss)", out query, out city)) {
            areas.add(new LocalArea(query, city));
        }

        if (areas.size == 0) {
            string legacy_city = user_location_city.length > 0 ? user_location_city : user_location;
            if (legacy_city.length > 0) {
                // The old single location searched both the town and its
                // nearest metro, so keep both as separate entries.
                var area = new LocalArea(user_location, legacy_city);
                areas.add(area);
                string metro = user_location_news_query;
                if (metro.length > 0 && LocalArea.short_name(metro).down() != LocalArea.short_name(legacy_city).down()) {
                    areas.add(new LocalArea(metro, metro));
                }
                set_local_areas(areas);
                active_local_area_key = area.key;
                user_location = "";
                user_location_city = "";
                user_location_news_query = "";
            }
        }
        return areas;
    }

    public void set_local_areas(Gee.ArrayList<LocalArea> areas) {
        var builder = new VariantBuilder(new VariantType("a(ss)"));
        foreach (var area in areas) {
            builder.add("(ss)", area.query, area.city);
        }
        settings.set_value("local-areas", builder.end());
    }

    // The area Local News is showing: the active one, else the first saved.
    public LocalArea? get_active_local_area() {
        var areas = get_local_areas();
        if (areas.size == 0) return null;
        string key = active_local_area_key;
        foreach (var area in areas) {
            if (area.key == key) return area;
        }
        return areas[0];
    }

    // Adds `area` and makes it active. An already-saved city is just made
    // active. Returns false when the list is full.
    public bool add_local_area(LocalArea area) {
        var areas = get_local_areas();
        foreach (var existing in areas) {
            if (existing.key == area.key) {
                active_local_area_key = area.key;
                return true;
            }
        }
        if (areas.size >= MAX_LOCAL_AREAS) return false;
        areas.add(area);
        set_local_areas(areas);
        active_local_area_key = area.key;
        return true;
    }

    public void remove_local_area(string key) {
        var areas = get_local_areas();
        for (int i = areas.size - 1; i >= 0; i--) {
            if (areas[i].key == key) areas.remove_at(i);
        }
        set_local_areas(areas);
    }

    // Moves the area saved under `key` to position `index`.
    public void move_local_area(string key, int index) {
        var areas = get_local_areas();
        for (int i = 0; i < areas.size; i++) {
            if (areas[i].key != key) continue;
            int target = index.clamp(0, areas.size - 1);
            if (target == i) return;
            var area = areas.remove_at(i);
            areas.insert(target, area);
            set_local_areas(areas);
            return;
        }
    }

    // Swaps the area saved under `old_key` for `area`, keeping its position.
    public void replace_local_area(string old_key, LocalArea area) {
        var areas = get_local_areas();
        int index = -1;
        for (int i = 0; i < areas.size; i++) {
            if (areas[i].key == old_key) index = i;
        }
        if (index < 0) {
            add_local_area(area);
            return;
        }
        // Drop any other entry that already holds the new city.
        for (int i = areas.size - 1; i >= 0; i--) {
            if (i != index && areas[i].key == area.key) {
                areas.remove_at(i);
                if (i < index) index--;
            }
        }
        areas[index] = area;
        set_local_areas(areas);
        active_local_area_key = area.key;
    }

    public bool reader_view_enabled {
        get { return settings.get_boolean("reader-view-enabled"); }
        set { settings.set_boolean("reader-view-enabled", value); }
    }

    public bool recommendations_enabled {
        get { return settings.get_boolean("recommendations-enabled"); }
        set { settings.set_boolean("recommendations-enabled", value); }
    }

    public bool comments_enabled {
        get { return settings.get_boolean("comments-enabled"); }
        set { settings.set_boolean("comments-enabled", value); }
    }

    public double reader_font_scale {
        get { return settings.get_double("reader-font-scale"); }
        set { settings.set_double("reader-font-scale", value); }
    }

    public string reader_font_family {
        owned get { return settings.get_string("reader-font-family"); }
        set { settings.set_string("reader-font-family", value); }
    }

    public string reader_color_scheme {
        owned get { return settings.get_string("reader-color-scheme"); }
        set { settings.set_string("reader-color-scheme", value); }
    }

    public bool card_hover_actions_enabled {
        get { return settings.get_boolean("card-hover-actions-enabled"); }
        set { settings.set_boolean("card-hover-actions-enabled", value); }
    }

    public bool article_click_opens_reader {
        get { return settings.get_boolean("article-click-opens-reader"); }
        set { settings.set_boolean("article-click-opens-reader", value); }
    }

    public bool unread_badges_enabled {
        get { return settings.get_boolean("unread-badges-enabled"); }
        set { settings.set_boolean("unread-badges-enabled", value); }
    }

    public bool unread_badges_categories {
        get { return settings.get_boolean("unread-badges-categories"); }
        set { settings.set_boolean("unread-badges-categories", value); }
    }

    // Whether to show badges on special categories
    // (Front Page, Top Ten, My Feed, Local News, Saved)
    public bool unread_badges_special_categories {
        get { return settings.get_boolean("unread-badges-special-categories"); }
        set { settings.set_boolean("unread-badges-special-categories", value); }
    }

    public bool unread_badges_sources {
        get { return settings.get_boolean("unread-badges-sources"); }
        set { settings.set_boolean("unread-badges-sources", value); }
    }

    public string update_interval {
        owned get { return settings.get_string("update-interval"); }
        set { settings.set_string("update-interval", value); }
    }

    public double podcast_playback_speed {
        get { return settings.get_double("podcast-playback-speed"); }
        set { settings.set_double("podcast-playback-speed", value); }
    }

    public int podcast_skip_seconds {
        get { return settings.get_int("podcast-skip-seconds"); }
        set { settings.set_int("podcast-skip-seconds", value); }
    }

    // Every news category, in default order.
    public const string[] ALL_CATEGORIES = {
        "general", "us", "technology", "business", "sports",
        "science", "health", "entertainment", "politics", "lifestyle"
    };

    // The news categories the user follows, in their sidebar order. Drives
    // the sidebar's Categories list and what My Feed draws from.
    public Gee.ArrayList<string> categories {
        owned get {
            var list = new Gee.ArrayList<string>();
            // An installed schema older than this key (not yet reinstalled)
            // reads as every category chosen, rather than aborting.
            if (!settings.settings_schema.has_key("categories")) {
                foreach (var c in ALL_CATEGORIES) list.add(c);
                return list;
            }
            foreach (var c in settings.get_strv("categories")) {
                if (c in ALL_CATEGORIES && !list.contains(c)) list.add(c);
            }
            return list;
        }
        set {
            if (!settings.settings_schema.has_key("categories")) {
                warning("Can't save categories: the installed GSettings schema predates the \"categories\" key - reinstall Paperboy");
                return;
            }
            // A fresh Vala string[] is NULL-terminated, as set_strv() needs;
            // Gee's to_array() isn't guaranteed to be.
            string[] arr = new string[value.size];
            for (int i = 0; i < value.size; i++) arr[i] = value.get(i);
            settings.set_strv("categories", arr);
        }
    }

    // URLs of custom RSS feeds included in My Feed. Deliberately separate
    // from preferred_sources' "custom:<url>" entries: that flag controls
    // whether the feed exists/shows in the sidebar at all (see
    // SidebarManager.get_sidebar_sections()), independent of whether it's
    // merged into My Feed - this is that second, independent opt-in.
    public Gee.ArrayList<string> myfeed_included_feeds {
        owned get {
            var list = new Gee.ArrayList<string>();
            string[] arr = settings.get_strv("myfeed-included-feeds");
            foreach (var s in arr) list.add(s);
            return list;
        }
        set {
            if (value == null) {
                settings.set_strv("myfeed-included-feeds", new string[0]);
            } else {
                string[] arr = new string[value.size];
                for (int i = 0; i < value.size; i++) arr[i] = value.get(i);
                settings.set_strv("myfeed-included-feeds", arr);
            }
        }
    }

    public bool myfeed_feed_enabled(string url) {
        foreach (var u in myfeed_included_feeds) if (u == url) return true;
        return false;
    }

    public void set_myfeed_feed_enabled(string url, bool enabled) {
        var current_list = myfeed_included_feeds;
        var updated_list = new Gee.ArrayList<string>();
        foreach (var u in current_list) updated_list.add(u);

        if (enabled) {
            if (!updated_list.contains(url)) updated_list.add(url);
        } else {
            var to_remove = new Gee.ArrayList<string>();
            foreach (var u in updated_list) if (u == url) to_remove.add(u);
            foreach (var r in to_remove) updated_list.remove(r);
        }

        myfeed_included_feeds = updated_list;
    }

    // Master on/off switch for the Sports category's score-card sections,
    // independent of which individual leagues are enabled below.
    public bool sports_scores_enabled {
        get { return settings.get_boolean("sports-scores-enabled"); }
        set { settings.set_boolean("sports-scores-enabled", value); }
    }

    // Whether the sidebar shows a "Live" pill next to the Sports badge while
    // a game is in progress. Independent of sports_scores_enabled so it can
    // be turned off without hiding score cards themselves; SportsLiveIndicatorManager
    // still treats sports_scores_enabled == false as "don't poll" too.
    public bool sports_live_indicator_enabled {
        get { return settings.get_boolean("sports-live-indicator-enabled"); }
        set { settings.set_boolean("sports-live-indicator-enabled", value); }
    }

    // Master on/off switch for the Business category's market index cards.
    public bool market_cards_enabled {
        get { return settings.get_boolean("market-cards-enabled"); }
        set { settings.set_boolean("market-cards-enabled", value); }
    }

    // Whether the sidebar shows an "Open" pill next to the Business badge
    // while the market is open. Independent of market_cards_enabled.
    public bool market_pill_enabled {
        get { return settings.get_boolean("market-pill-enabled"); }
        set { settings.set_boolean("market-pill-enabled", value); }
    }

    // Whether uncategorized magazines render as their own flat grid
    // (true, the default) or as an "Uncategorized" row alongside other
    // category rows (false). See MagazineLibraryManager.render_library().
    public bool magazine_uncategorized_as_grid {
        get { return settings.get_boolean("magazine-uncategorized-as-grid"); }
        set { settings.set_boolean("magazine-uncategorized-as-grid", value); }
    }

    // User-chosen top-to-bottom order for magazine category rows, set by
    // dragging rows in the Organize Magazines dialog. Only stores
    // categories the user has actually dragged into place.
    public Gee.ArrayList<string> magazine_category_order {
        owned get {
            var list = new Gee.ArrayList<string>();
            string[] arr = settings.get_strv("magazine-category-order");
            foreach (var s in arr) list.add(s);
            return list;
        }
        set {
            if (value == null) {
                settings.set_strv("magazine-category-order", new string[0]);
            } else {
                string[] arr = new string[value.size];
                for (int i = 0; i < value.size; i++) arr[i] = value.get(i);
                settings.set_strv("magazine-category-order", arr);
            }
        }
    }

    // available_categories in the user's preferred order: the stored order
    // first (dropping any names no longer present), then any remaining
    // categories appended alphabetically so a newly-created one still shows
    // up without needing to be dragged first.
    public Gee.ArrayList<string> ordered_magazine_categories(Gee.ArrayList<string> available_categories) {
        var ordered = new Gee.ArrayList<string>();
        foreach (var name in magazine_category_order) {
            if (available_categories.contains(name) && !ordered.contains(name)) ordered.add(name);
        }

        var remaining = new Gee.ArrayList<string>();
        foreach (var name in available_categories) {
            if (!ordered.contains(name)) remaining.add(name);
        }
        remaining.sort((a, b) => { return SortUtils.compare_titles(a, b); });
        ordered.add_all(remaining);

        return ordered;
    }

    public Gee.ArrayList<string> disabled_sports_leagues {
        owned get {
            var list = new Gee.ArrayList<string>();
            string[] arr = settings.get_strv("disabled-sports-leagues");
            foreach (var s in arr) list.add(s);
            return list;
        }
        set {
            if (value == null) {
                settings.set_strv("disabled-sports-leagues", new string[0]);
            } else {
                string[] arr = new string[value.size];
                for (int i = 0; i < value.size; i++) arr[i] = value.get(i);
                settings.set_strv("disabled-sports-leagues", arr);
            }
        }
    }

    // User-generated data: preferred sources (includes custom RSS feeds) - stored in KeyFile
    private Gee.ArrayList<string>? _preferred_sources = null;
    public Gee.ArrayList<string> preferred_sources {
        get {
            if (_preferred_sources == null) {
                _preferred_sources = new Gee.ArrayList<string>();
            }
            return _preferred_sources;
        }
        set {
            _preferred_sources = value;
            save_config();
        }
    }

    // Current RSS source filter (URL) when viewing a specific custom source (runtime-only, not persisted)
    public string? current_rss_source_filter { get; set; default = null; }

    // True when the config did not exist at startup (first run)
    public bool first_run { get; private set; }

    // Convenience helpers for managing preferred sources
    public bool preferred_source_enabled(string id) {
        if (preferred_sources == null) return false;
        foreach (var s in preferred_sources) if (s == id) return true;
        return false;
    }

    public void set_preferred_source_enabled(string id, bool enabled) {
        if (preferred_sources == null) preferred_sources = new Gee.ArrayList<string>();
        if (enabled) {
            if (!preferred_source_enabled(id)) preferred_sources.add(id);
        } else {
            if (preferred_source_enabled(id)) {
                var to_remove = new Gee.ArrayList<string>();
                foreach (var s in preferred_sources) if (s == id) to_remove.add(s);
                foreach (var r in to_remove) preferred_sources.remove(r);
            }
        }
        // Persist changes to KeyFile
        if (!loading) save_config();
    }

    public bool category_enabled(string cat) {
        return categories.contains(cat);
    }

    // User-chosen top-to-bottom order for sports league sections. Only
    // stores keys the user has actually dragged into place; leagues absent
    // from this list (including ones added to SportsScoresService after the
    // user last reordered) fall back to their built-in position.
    public Gee.ArrayList<string> sports_league_order {
        owned get {
            var list = new Gee.ArrayList<string>();
            string[] arr = settings.get_strv("sports-league-order");
            foreach (var s in arr) list.add(s);
            return list;
        }
        set {
            if (value == null) {
                settings.set_strv("sports-league-order", new string[0]);
            } else {
                string[] arr = new string[value.size];
                for (int i = 0; i < value.size; i++) arr[i] = value.get(i);
                settings.set_strv("sports-league-order", arr);
            }
        }
    }

    // Regional leagues the user switched on outside their home editions
    // (see SportsScoresService.enabled_by_default). Same convention as
    // disabled_sports_leagues.
    public Gee.ArrayList<string> enabled_sports_leagues {
        owned get {
            var list = new Gee.ArrayList<string>();
            foreach (var s in settings.get_strv("enabled-sports-leagues")) list.add(s);
            return list;
        }
        set {
            string[] arr = new string[value != null ? value.size : 0];
            for (int i = 0; i < arr.length; i++) arr[i] = value.get(i);
            settings.set_strv("enabled-sports-leagues", arr);
        }
    }

    // Convenience helpers for managing which sports leagues show score cards.
    // An explicit choice wins; otherwise the league's default for the user's
    // news edition applies.
    public bool sports_league_enabled(string league_key) {
        if (disabled_sports_leagues.contains(league_key)) return false;
        if (enabled_sports_leagues.contains(league_key)) return true;
        return SportsScoresService.enabled_by_default(league_key);
    }

    // All league keys (enabled or not) in the user's preferred display
    // order: the stored order first (dropping any keys that no longer
    // exist), then any remaining league keys appended in their built-in
    // order so newly added leagues still show up without a re-sort.
    public Gee.ArrayList<string> ordered_sports_league_keys() {
        var all_keys = SportsScoresService.league_keys();
        var ordered = new Gee.ArrayList<string>();

        foreach (var key in sports_league_order) {
            if (all_keys.contains(key) && !ordered.contains(key)) ordered.add(key);
        }
        // Unplaced leagues: the user's regional ones (La Liga in Spain) first
        foreach (var key in all_keys) {
            if (!ordered.contains(key) && SportsScoresService.is_home_league(key)) ordered.add(key);
        }
        foreach (var key in all_keys) {
            if (!ordered.contains(key)) ordered.add(key);
        }

        return ordered;
    }

    public void set_sports_league_enabled(string league_key, bool enabled) {
        var current_list = disabled_sports_leagues;
        var updated_list = new Gee.ArrayList<string>();
        foreach (var k in current_list) updated_list.add(k);

        if (enabled) {
            var to_remove = new Gee.ArrayList<string>();
            foreach (var k in updated_list) if (k == league_key) to_remove.add(k);
            foreach (var r in to_remove) updated_list.remove(r);
        } else {
            bool already_present = false;
            foreach (var k in updated_list) if (k == league_key) { already_present = true; break; }
            if (!already_present) updated_list.add(league_key);
        }

        disabled_sports_leagues = updated_list;

        // Record an explicit "on" too, so a regional league stays on after
        // the user changes country
        var opted_in = enabled_sports_leagues;
        if (enabled && !opted_in.contains(league_key)) opted_in.add(league_key);
        if (!enabled) opted_in.remove(league_key);
        enabled_sports_leagues = opted_in;
    }

    // Favorite sports teams, stored as "league_key|team_id" strings - same
    // plain-string-array convention as disabled_sports_leagues/
    // sports_league_order above. Used by the "My Teams" section (see
    // SportsScoresController) to show each favorited team's own score row.
    public Gee.ArrayList<string> favorite_sports_teams {
        owned get {
            var list = new Gee.ArrayList<string>();
            string[] arr = settings.get_strv("favorite-sports-teams");
            foreach (var s in arr) list.add(s);
            return list;
        }
        set {
            if (value == null) {
                settings.set_strv("favorite-sports-teams", new string[0]);
            } else {
                string[] arr = new string[value.size];
                for (int i = 0; i < value.size; i++) arr[i] = value.get(i);
                settings.set_strv("favorite-sports-teams", arr);
            }
        }
    }

    private static string favorite_team_key(string league_key, string team_id) {
        return "%s|%s".printf(league_key, team_id);
    }

    public bool is_team_favorited(string league_key, string team_id) {
        string needle = favorite_team_key(league_key, team_id);
        foreach (var s in favorite_sports_teams) if (s == needle) return true;
        return false;
    }

    public void add_favorite_team(string league_key, string team_id) {
        if (is_team_favorited(league_key, team_id)) return;
        var updated = favorite_sports_teams;
        updated.add(favorite_team_key(league_key, team_id));
        favorite_sports_teams = updated;
    }

    public void remove_favorite_team(string league_key, string team_id) {
        string needle = favorite_team_key(league_key, team_id);
        var current = favorite_sports_teams;
        var updated = new Gee.ArrayList<string>();
        foreach (var s in current) if (s != needle) updated.add(s);
        favorite_sports_teams = updated;
    }

    // (league_key, team_id) pairs for every favorited team, parsed from the
    // raw "league_key|team_id" strings - malformed entries are skipped.
    public Gee.ArrayList<FavoriteTeamRef> favorite_teams() {
        var result = new Gee.ArrayList<FavoriteTeamRef>();
        foreach (var s in favorite_sports_teams) {
            string[] parts = s.split("|", 2);
            if (parts.length == 2 && parts[0].length > 0 && parts[1].length > 0) {
                result.add(new FavoriteTeamRef(parts[0], parts[1]));
            }
        }
        return result;
    }

    private NewsPreferences() {
        // Initialize GSettings for UI preferences
        settings = new GLib.Settings("io.github.thecalamityjoe87.Paperboy");
        GoogleNewsUtils.set_chosen(news_edition);
        
        // Initialize KeyFile for user-generated data (preferred_sources)
        config = new GLib.KeyFile();
        config_path = get_config_file_path();
        
        // Detect whether a configuration already exists so callers can
        // present first-run flows (dialogs, onboarding) when appropriate.
        bool exists = GLib.FileUtils.test(config_path, GLib.FileTest.EXISTS);
        first_run = !exists;
        // Last-viewed category lives in dconf, which outlives a wiped config dir.
        if (first_run) settings.set_string("category", "frontpage");
        
        // Load user-generated data from KeyFile
        load_config();
    }

    public static NewsPreferences get_instance() {
        if (instance == null) {
            instance = new NewsPreferences();
        }
        return instance;
    }

    private string get_config_file_path() {
        var config_dir = GLib.Environment.get_user_config_dir();
        GLib.DirUtils.create_with_parents(GLib.Path.build_filename(config_dir, "paperboy"), 0755);
        return GLib.Path.build_filename(config_dir, "paperboy", "config.ini");
    }

    // Wipes all persisted state back to a fresh install: every GSettings key
    // (including onboarding-completed, so the welcome tour reappears),
    // config.ini, and the entire cache/data directories (sources, notes,
    // podcasts, article cache, etc). Best-effort; the app is expected to
    // restart immediately after so no live store keeps writing to the
    // now-deleted files.
    public void factory_reset() {
        foreach (string key in settings.list_keys()) {
            settings.reset(key);
        }
        // Flush before the restart quits the app, or dconf can drop the resets.
        GLib.Settings.sync();

        try { GLib.FileUtils.remove(config_path); } catch (GLib.Error e) { }

        delete_directory_recursive(GLib.Path.build_filename(GLib.Environment.get_user_cache_dir(), "paperboy"));
        delete_directory_recursive(GLib.Path.build_filename(GLib.Environment.get_user_data_dir(), "paperboy"));
    }

    private void delete_directory_recursive(string path) {
        var dir = GLib.File.new_for_path(path);
        if (!dir.query_exists()) return;

        try {
            var enumerator = dir.enumerate_children("standard::name,standard::type", GLib.FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
            GLib.FileInfo? info;
            while ((info = enumerator.next_file(null)) != null) {
                string child_path = GLib.Path.build_filename(path, info.get_name());
                if (info.get_file_type() == GLib.FileType.DIRECTORY) {
                    delete_directory_recursive(child_path);
                } else {
                    try { GLib.FileUtils.remove(child_path); } catch (GLib.Error e) { }
                }
            }
        } catch (GLib.Error e) { }

        try { GLib.DirUtils.remove(path); } catch (GLib.Error e) { }
    }

    public void save_config() {
        // GSettings automatically persists UI preferences, so we only need to
        // save user-generated data (preferred_sources) to KeyFile
        try {
            // Create a clean KeyFile with ONLY the keys that belong in config.ini
            var clean_config = new GLib.KeyFile();

            // Persist preferred sources (user-followed sources including custom RSS feeds)
            if (custom_sources_enable_migration_done) {
                clean_config.set_boolean("preferences", "custom_sources_enable_migration_v1", true);
            }

            if (builtin_sources_seeded) {
                clean_config.set_boolean("preferences", "builtin_sources_seeded_v1", true);
            }

            if (_preferred_sources != null) {
                // Written even when empty: an empty list means every source is off
                string[] parr = new string[_preferred_sources.size];
                for (int i = 0; i < _preferred_sources.size; i++) parr[i] = _preferred_sources.get(i);
                clean_config.set_string_list("preferences", "preferred_sources", parr);
            } else if (GLib.FileUtils.test(config_path, GLib.FileTest.EXISTS)) {
                // Not loaded yet - keep whatever is on disk rather than wiping it
                try {
                    var temp_config = new GLib.KeyFile();
                    temp_config.load_from_file(config_path, GLib.KeyFileFlags.NONE);
                    if (temp_config.has_key("preferences", "preferred_sources")) {
                        string[] parr = temp_config.get_string_list("preferences", "preferred_sources");
                        clean_config.set_string_list("preferences", "preferred_sources", parr);
                    }
                } catch (GLib.Error e) {
                    warning("Failed to load existing preferred_sources: %s", e.message);
                }
            }

            string config_data = clean_config.to_data();
            GLib.FileUtils.set_contents(config_path, config_data);
        } catch (GLib.Error e) {
            warning("Failed to save config: %s", e.message);
        }
    }

   private void load_config() {
        // GSettings automatically loads UI preferences, so we only need to
        // load user-generated data (viewed_articles) from KeyFile
        try {
            // Mark that we're loading so setters don't trigger saves
            loading = true;

            bool exists = false;
            try { exists = GLib.FileUtils.test(config_path, GLib.FileTest.EXISTS); } catch (GLib.Error e) { exists = false; }
            //warning("NewsPreferences.load_config: config_path=%s exists=%s", config_path, exists ? "true" : "false");
            
            // Validate config file before loading to prevent crashes from corrupted files
            if (exists) {
                try {
                    var config_file = File.new_for_path(config_path);
                    var info = config_file.query_info("standard::size", FileQueryInfoFlags.NONE, null);
                    int64 size = info.get_size();
                    
                    // If config file is unreasonably large (>10MB), treat as corrupted
                    const int64 MAX_CONFIG_SIZE = 10 * 1024 * 1024;
                    if (size > MAX_CONFIG_SIZE) {
                        warning("NewsPreferences.load_config: config file too large (%lld bytes), treating as corrupted", size);
                        exists = false;
                        // Backup corrupted file and start fresh
                        try {
                            string backup_path = config_path + ".corrupted";
                            FileUtils.rename(config_path, backup_path);
                            warning("NewsPreferences.load_config: backed up corrupted config to %s", backup_path);
                        } catch (GLib.Error e) {
                            warning("Failed to backup corrupted config: %s", e.message);
                        }
                    }
                } catch (GLib.Error e) {
                    warning("NewsPreferences.load_config: failed to validate config file: %s", e.message);
                }
            }
            
            if (exists) {
                try {
                    config.load_from_file(config_path, GLib.KeyFileFlags.NONE);
                } catch (GLib.Error e) {
                    warning("NewsPreferences.load_config: failed to parse config file: %s - starting with defaults", e.message);
                    // Backup corrupted file
                    try {
                        string backup_path = config_path + ".parse-error";
                        FileUtils.rename(config_path, backup_path);
                        warning("NewsPreferences.load_config: backed up unparseable config to %s", backup_path);
                    } catch (GLib.Error e2) { }
                    // Continue with empty config
                    config = new GLib.KeyFile();
                }
            }
            
            // MIGRATION: If old preferences exist in KeyFile, migrate them to GSettings.
            // An old-format config is recognized by its news_source key (whose
            // single-default-source setting no longer exists, so it isn't migrated).
            // has_key() throws when the group is missing, as on a fresh install
            bool needs_migration = config.has_group("preferences") && config.has_key("preferences", "news_source");
            if (needs_migration) {
                // Migrate category
                if (config.has_key("preferences", "category")) {
                    string cat = config.get_string("preferences", "category");
                    // Migration: "all categories" has been removed, default to "frontpage" instead
                    if (cat == "all") cat = "frontpage";
                    // Top Ten no longer exists as its own page - its content
                    // moved onto the Front Page's Trending section.
                    if (cat == "topten") cat = "frontpage";
                    settings.set_string("category", cat);
                }
                
                // Migrate personalized_feed_enabled
                if (config.has_key("preferences", "personalized_feed_enabled")) {
                    try {
                        bool enabled = config.get_boolean("preferences", "personalized_feed_enabled");
                        settings.set_boolean("personalized-feed-enabled", enabled);
                    } catch (GLib.Error e) { }
                }
                
                // Migrate myfeed_custom_only
                if (config.has_key("preferences", "myfeed_custom_only")) {
                    try {
                        bool custom_only = config.get_boolean("preferences", "myfeed_custom_only");
                        settings.set_boolean("myfeed-custom-only", custom_only);
                    } catch (GLib.Error e) { }
                }
                
                // Migrate sidebar_followed_sources_expanded
                if (config.has_key("preferences", "sidebar_followed_sources_expanded")) {
                    try {
                        bool expanded = config.get_boolean("preferences", "sidebar_followed_sources_expanded");
                        settings.set_boolean("sidebar-followed-sources-expanded", expanded);
                    } catch (GLib.Error e) { }
                }
                
                // Migrate sidebar_popular_categories_expanded
                if (config.has_key("preferences", "sidebar_popular_categories_expanded")) {
                    try {
                        bool expanded = config.get_boolean("preferences", "sidebar_popular_categories_expanded");
                        settings.set_boolean("sidebar-popular-categories-expanded", expanded);
                    } catch (GLib.Error e) { }
                }
                
                // Migrate user_location
                if (config.has_key("preferences", "user_location")) {
                    try {
                        string location = config.get_string("preferences", "user_location");
                        settings.set_string("user-location", location);
                    } catch (GLib.Error e) { }
                }
                
                // Migrate user_location_city
                if (config.has_key("preferences", "user_location_city")) {
                    try {
                        string city = config.get_string("preferences", "user_location_city");
                        settings.set_string("user-location-city", city);
                    } catch (GLib.Error e) { }
                }
                
                // After migration, remove the old preferences section from config file
                // We'll do this by creating a new config with only user_data
                var new_config = new GLib.KeyFile();
                
                // Copy preferred_sources to new config. Prefer the newer
                // `user_data` value when present so we don't downgrade a richer
                // list, but store the final value in the single on-disk
                // `preferences` group (we only want one section written).
                if (config.has_key("user_data", "preferred_sources")) {
                    try {
                        string[] parr = config.get_string_list("user_data", "preferred_sources");
                        new_config.set_string_list("preferences", "preferred_sources", parr);
                    } catch (GLib.Error e) { }
                } else if (config.has_key("preferences", "preferred_sources")) {
                    try {
                        string[] parr = config.get_string_list("preferences", "preferred_sources");
                        new_config.set_string_list("preferences", "preferred_sources", parr);
                    } catch (GLib.Error e) { }
                }
                
                // Save the cleaned config
                config = new_config;
                string config_data = config.to_data();
                GLib.FileUtils.set_contents(config_path, config_data);
            }
            // Populate in-memory preferred_sources from KeyFile. Prefer
            // `user_data` when present (richer), otherwise fall back to
            // `preferences` so we're compatible with the single-group layout
            // we write to disk.
            _preferred_sources = new Gee.ArrayList<string>();

            // Try user_data group first
            try {
                if (config.has_group("user_data") && config.has_key("user_data", "preferred_sources")) {
                    string[] parr = config.get_string_list("user_data", "preferred_sources");
                    foreach (var s in parr) _preferred_sources.add(s);
                    warning("NewsPreferences.load_config: loaded %d preferred_sources from user_data", _preferred_sources.size);
                }
            } catch (GLib.Error e) {
                warning("NewsPreferences.load_config: could not read from user_data: %s", e.message);
            }

            // If nothing loaded yet, try preferences group
            if (_preferred_sources.size == 0) {
                try {
                    if (config.has_group("preferences") && config.has_key("preferences", "preferred_sources")) {
                        string[] parr = config.get_string_list("preferences", "preferred_sources");
                        foreach (var s in parr) _preferred_sources.add(s);
                        //warning("NewsPreferences.load_config: loaded %d preferred_sources from preferences", _preferred_sources.size);
                    }
                } catch (GLib.Error e) {
                    warning("NewsPreferences.load_config: could not read from preferences: %s", e.message);
                }
            }

            // Reddit was removed as a built-in source.
            while (_preferred_sources.remove("reddit")) {}

            if (_preferred_sources.size == 0) {
                warning("NewsPreferences.load_config: no preferred_sources found in config, initialized empty list");
            }

            try {
                custom_sources_enable_migration_done = config.has_key("preferences", "custom_sources_enable_migration_v1")
                    && config.get_boolean("preferences", "custom_sources_enable_migration_v1");
            } catch (GLib.Error e) { custom_sources_enable_migration_done = false; }
            try {
                builtin_sources_seeded = config.has_key("preferences", "builtin_sources_seeded_v1")
                    && config.get_boolean("preferences", "builtin_sources_seeded_v1");
            } catch (GLib.Error e) { builtin_sources_seeded = false; }

            // Unset loading marker so setters/save operations can run normally
            loading = false;

            // One-time migration (see the field comment above). Only a
            // completely empty list - a fresh install, or one that never
            // chose - was treated as "all on"; a list holding just custom
            // feeds already meant every built-in source was off. Runs before
            // the custom-sources migration below, which can add to the list.
            if (!builtin_sources_seeded) {
                if (_preferred_sources.size == 0) {
                    foreach (unowned BuiltinSource src in BuiltinSources.ALL) _preferred_sources.add(src.id);
                }
                builtin_sources_seeded = true;
                save_config();
            }

            // One-time migration: enable every existing custom RSS source
            // that isn't already tracked (see the field comment above).
            if (!custom_sources_enable_migration_done) {
                try {
                    var store = Paperboy.RssSourceStore.get_instance();
                    foreach (var src in store.get_all_sources()) {
                        string id = "custom:" + src.url;
                        if (!preferred_source_enabled(id)) {
                            _preferred_sources.add(id);
                        }
                    }
                } catch (GLib.Error e) {
                    warning("NewsPreferences.load_config: custom sources migration failed: %s", e.message);
                }
                custom_sources_enable_migration_done = true;
                save_config();
            }

        } catch (GLib.Error e) {
            // Ensure loading flag is cleared on error
            loading = false;
            warning("Failed to load config: %s", e.message);
        }
    }
}