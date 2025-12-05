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

public class NewsPreferences : GLib.Object {
    private static NewsPreferences? instance = null;
    private GLib.Settings settings;
    private GLib.KeyFile config;  // Used for preferred_sources (user-generated data)
    private string config_path;
    // True while we're loading/migrating the KeyFile to avoid triggering
    // saves from setters during initialization.
    private bool loading = false;

    // GSettings-backed properties (automatically persisted)
    public NewsSource news_source {
        get {
            string source_str = settings.get_string("news-source");
            switch (source_str) {
                case "guardian": return NewsSource.GUARDIAN;
                case "reddit": return NewsSource.REDDIT;
                case "bbc": return NewsSource.BBC;
                case "wsj": return NewsSource.WALL_STREET_JOURNAL;
                case "nytimes": return NewsSource.NEW_YORK_TIMES;
                case "bloomberg": return NewsSource.BLOOMBERG;
                case "reuters": return NewsSource.REUTERS;
                case "npr": return NewsSource.NPR;
                case "fox": return NewsSource.FOX;
                case "unknown": return NewsSource.UNKNOWN;
                default: return NewsSource.GUARDIAN;
            }
        }
        set {
            string source_str = "";
            switch (value) {
                case NewsSource.GUARDIAN: source_str = "guardian"; break;
                case NewsSource.REDDIT: source_str = "reddit"; break;
                case NewsSource.BBC: source_str = "bbc"; break;
                case NewsSource.WALL_STREET_JOURNAL: source_str = "wsj"; break;
                case NewsSource.NEW_YORK_TIMES: source_str = "nytimes"; break;
                case NewsSource.BLOOMBERG: source_str = "bloomberg"; break;
                case NewsSource.REUTERS: source_str = "reuters"; break;
                case NewsSource.NPR: source_str = "npr"; break;
                case NewsSource.FOX: source_str = "fox"; break;
                case NewsSource.UNKNOWN: source_str = "unknown"; break;
                default: source_str = "guardian"; break;
            }
            settings.set_string("news-source", source_str);
        }
    }

    public string category {
        owned get { return settings.get_string("category"); }
        set { settings.set_string("category", value); }
    }

    public bool personalized_feed_enabled {
        get { return settings.get_boolean("personalized-feed-enabled"); }
        set { settings.set_boolean("personalized-feed-enabled", value); }
    }

    public bool myfeed_custom_only {
        get { return settings.get_boolean("myfeed-custom-only"); }
        set { settings.set_boolean("myfeed-custom-only", value); }
    }

    public bool sidebar_followed_sources_expanded {
        get { return settings.get_boolean("sidebar-followed-sources-expanded"); }
        set { settings.set_boolean("sidebar-followed-sources-expanded", value); }
    }

    public bool sidebar_popular_categories_expanded {
        get { return settings.get_boolean("sidebar-popular-categories-expanded"); }
        set { settings.set_boolean("sidebar-popular-categories-expanded", value); }
    }

    public string user_location {
        owned get { return settings.get_string("user-location"); }
        set { settings.set_string("user-location", value); }
    }

    public string user_location_city {
        owned get { return settings.get_string("user-location-city"); }
        set { settings.set_string("user-location-city", value); }
    }

    public bool unread_badges_enabled {
        get { return settings.get_boolean("unread-badges-enabled"); }
        set { settings.set_boolean("unread-badges-enabled", value); }
    }

    public bool unread_badges_categories {
        get { return settings.get_boolean("unread-badges-categories"); }
        set { settings.set_boolean("unread-badges-categories", value); }
    }

    public bool unread_badges_sources {
        get { return settings.get_boolean("unread-badges-sources"); }
        set { settings.set_boolean("unread-badges-sources", value); }
    }

    public string update_interval {
        owned get { return settings.get_string("update-interval"); }
        set { settings.set_string("update-interval", value); }
    }

    public Gee.ArrayList<string> personalized_categories {
        owned get {
            var list = new Gee.ArrayList<string>();
            string[] arr = settings.get_strv("personalized-categories");
            foreach (var s in arr) list.add(s);
            warning("personalized_categories getter: loaded %d categories from GSettings", list.size);
            return list;
        }
        set {
            warning("personalized_categories setter: writing %d categories to GSettings", value != null ? value.size : 0);
            if (value == null) {
                settings.set_strv("personalized-categories", new string[0]);
            } else {
                string[] arr = new string[value.size];
                for (int i = 0; i < value.size; i++) {
                    arr[i] = value.get(i);
                    warning("  - writing category: %s", arr[i]);
                }
                settings.set_strv("personalized-categories", arr);
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
        // If the user has enabled exactly one preferred source, keep the
        // single-source `news_source` value in sync so code that still
        // reads `prefs.news_source` will reflect the user's intent.
        if (preferred_sources != null && preferred_sources.size == 1) {
            string only = preferred_sources.get(0);
            switch (only) {
                case "guardian": news_source = NewsSource.GUARDIAN; break;
                case "reddit": news_source = NewsSource.REDDIT; break;
                case "bbc": news_source = NewsSource.BBC; break;
                case "nytimes": news_source = NewsSource.NEW_YORK_TIMES; break;
                case "wsj": news_source = NewsSource.WALL_STREET_JOURNAL; break;
                case "bloomberg": news_source = NewsSource.BLOOMBERG; break;
                case "reuters": news_source = NewsSource.REUTERS; break;
                case "npr": news_source = NewsSource.NPR; break;
                case "fox": news_source = NewsSource.FOX; break;
                default: /* leave news_source unchanged for unknown ids */ break;
            }
        }
        // Persist changes to KeyFile
        if (!loading) save_config();
    }

    // Convenience helpers for managing personalized categories
    public bool personalized_category_enabled(string cat) {
        if (personalized_categories == null) return false;
        foreach (var c in personalized_categories) if (c == cat) return true;
        return false;
    }

    public void set_personalized_category_enabled(string cat, bool enabled) {
        // Get current list from GSettings
        var current_list = personalized_categories;
        if (current_list == null) current_list = new Gee.ArrayList<string>();

        // Create a new list for modification
        var updated_list = new Gee.ArrayList<string>();
        foreach (var c in current_list) updated_list.add(c);

        if (enabled) {
            // Add category if not already present
            bool already_present = false;
            foreach (var c in updated_list) {
                if (c == cat) {
                    already_present = true;
                    break;
                }
            }
            if (!already_present) {
                updated_list.add(cat);
                warning("set_personalized_category_enabled: adding category '%s'", cat);
            }
        } else {
            // Remove all occurrences of category
            var to_remove = new Gee.ArrayList<string>();
            foreach (var c in updated_list) {
                if (c == cat) to_remove.add(c);
            }
            foreach (var r in to_remove) {
                updated_list.remove(r);
                warning("set_personalized_category_enabled: removing category '%s'", r);
            }
        }

        // Write back to GSettings by triggering the property setter
        personalized_categories = updated_list;

        // Debug: verify what was written
        var verify_list = personalized_categories;
        warning("set_personalized_category_enabled: after save, GSettings contains %d categories", verify_list.size);
        foreach (var c in verify_list) {
            warning("  - category: %s", c);
        }
    }

    // Return true if the provided category is valid for the given source
    private bool category_valid_for_source(NewsSource source, string cat) {
        switch (source) {
            case NewsSource.BLOOMBERG:
                string[] bb = { "markets", "industries", "economics", "wealth", "green", "politics", "technology" };
                foreach (var b in bb) if (b == cat) return true;
                return false;
            default:
                // Include "local_news" as a top-level, non-category view so
                // users can select it even when operating in single-source
                // mode. Treat it similarly to "myfeed" for persistence checks.
                // Include common cross-source categories here so they are
                // preserved when the app is operating in single-source mode.
                // 'business' is supported by many sources (Guardian, NYTimes,
                // Bloomberg, etc.) and must be allowed or we'll coerce the
                // user back to 'topten' when saving preferences.
                string[] def = { "general", "us", "technology", "business", "science", "sports", "health", "entertainment", "politics", "lifestyle", "myfeed", "local_news" };
                foreach (var d in def) if (d == cat) return true;
                return false;
        }
    }

    private NewsPreferences() {
        // Initialize GSettings for UI preferences
        settings = new GLib.Settings("io.github.thecalamityjoe87.Paperboy");
        
        // Initialize KeyFile for user-generated data (preferred_sources)
        config = new GLib.KeyFile();
        config_path = get_config_file_path();
        
        // Detect whether a configuration already exists so callers can
        // present first-run flows (dialogs, onboarding) when appropriate.
        try {
            bool exists = GLib.FileUtils.test(config_path, GLib.FileTest.EXISTS);
            first_run = !exists;
        } catch (GLib.Error e) { first_run = false; }
        
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

    public void save_config() {
        // GSettings automatically persists UI preferences, so we only need to
        // save user-generated data (preferred_sources) to KeyFile
        try {
            warning("NewsPreferences.save_config: writing config_path=%s", config_path);

            // Create a clean KeyFile with ONLY the keys that belong in config.ini
            var clean_config = new GLib.KeyFile();

            // Persist preferred sources (user-followed sources including custom RSS feeds)
            if (_preferred_sources != null && _preferred_sources.size > 0) {
                warning("NewsPreferences.save_config: saving %d preferred_sources to config", _preferred_sources.size);
                string[] parr = new string[_preferred_sources.size];
                for (int i = 0; i < _preferred_sources.size; i++) parr[i] = _preferred_sources.get(i);
                clean_config.set_string_list("preferences", "preferred_sources", parr);
            } else {
                warning("NewsPreferences.save_config: _preferred_sources is null or empty (size=%d), will try to preserve from disk", _preferred_sources != null ? _preferred_sources.size : -1);
                // If the running instance has no in-memory preferred list, try to preserve
                // the existing value from disk rather than overwriting with an empty config.
                if (GLib.FileUtils.test(config_path, GLib.FileTest.EXISTS)) {
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
                // Only seed the default list on a true first-run (config file did
                // not exist at startup). If the config file exists but lacks the
                // key, leave it empty rather than seeding defaults.
                if (first_run && !clean_config.has_key("preferences", "preferred_sources")) {
                    string[] default_sources = {"guardian", "reddit", "bbc", "nytimes", "wsj", "bloomberg", "reuters", "npr", "fox"};
                    clean_config.set_string_list("preferences", "preferred_sources", default_sources);
                }
            }

            string config_data = clean_config.to_data();
            // Write file and confirm
            GLib.FileUtils.set_contents(config_path, config_data);
            warning("NewsPreferences.save_config: wrote %d bytes to %s", config_data.length, config_path);
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
            
            // MIGRATION: If old preferences exist in KeyFile, migrate them to GSettings
            bool needs_migration = config.has_key("preferences", "news_source");
            if (needs_migration) {
                // Migrate news_source
                if (config.has_key("preferences", "news_source")) {
                    string source_name = config.get_string("preferences", "news_source");
                    settings.set_string("news-source", source_name);
                }
                
                // Migrate category
                if (config.has_key("preferences", "category")) {
                    string cat = config.get_string("preferences", "category");
                    // Migration: "all categories" has been removed, default to "topten" instead
                    if (cat == "all") cat = "topten";
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
                
                // Migrate personalized_categories
                if (config.has_key("preferences", "personalized_categories")) {
                    try {
                        string[] arr = config.get_string_list("preferences", "personalized_categories");
                        settings.set_strv("personalized-categories", arr);
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

            if (_preferred_sources.size == 0) {
                warning("NewsPreferences.load_config: no preferred_sources found in config, initialized empty list");
            }

            // Unset loading marker so setters/save operations can run normally
            loading = false;

        } catch (GLib.Error e) {
            // Ensure loading flag is cleared on error
            loading = false;
            warning("Failed to load config: %s", e.message);
        }
    }
}