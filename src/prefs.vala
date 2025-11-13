/*
 * Copyright (C) 2025  Isaac Joseph <calamityjoe87@gmail.com>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

using GLib;

public class NewsPreferences : GLib.Object {
    private static NewsPreferences? instance = null;
    private GLib.KeyFile config;
    private string config_path;

    public NewsSource news_source { get; set; default = NewsSource.GUARDIAN; }
    public string category { get; set; default = "all"; }
    public bool personalized_feed_enabled { get; set; default = false; }
    // Optional user-provided location (e.g., city or coordinates)
    public string user_location { get; set; default = ""; }
    // Resolved canonical city name for a provided ZIP (e.g. "San Francisco, California")
    public string user_location_city { get; set; default = ""; }
    // Categories included in the personalized feed (by id)
    public Gee.ArrayList<string> personalized_categories { get; set; }
    // Preferred news sources (string ids such as "guardian", "reddit")
    public Gee.ArrayList<string> preferred_sources { get; set; }
    // Track which normalized article URLs were viewed in previous sessions
    public Gee.ArrayList<string> viewed_articles { get; set; }
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
    }

    // Convenience helpers for managing personalized categories
    public bool personalized_category_enabled(string cat) {
        if (personalized_categories == null) return false;
        foreach (var c in personalized_categories) if (c == cat) return true;
        return false;
    }

    public void set_personalized_category_enabled(string cat, bool enabled) {
        if (personalized_categories == null) personalized_categories = new Gee.ArrayList<string>();
        if (enabled) {
            if (!personalized_category_enabled(cat)) personalized_categories.add(cat);
        } else {
            if (personalized_category_enabled(cat)) {
                // remove all occurrences
                var to_remove = new Gee.ArrayList<string>();
                foreach (var c in personalized_categories) if (c == cat) to_remove.add(c);
                foreach (var r in to_remove) personalized_categories.remove(r);
            }
        }
    }

    // Return true if the provided category is valid for the given source
    private bool category_valid_for_source(NewsSource source, string cat) {
        if (cat == "all") return true; // "All Categories" is supported by every source
        switch (source) {
            case NewsSource.BLOOMBERG:
                string[] bb = { "markets", "industries", "economics", "wealth", "green", "politics", "technology" };
                foreach (var b in bb) if (b == cat) return true;
                return false;
            default:
                // Include "local_news" as a top-level, non-category view so
                // users can select it even when operating in single-source
                // mode. Treat it similarly to "myfeed" for persistence checks.
                string[] def = { "general", "us", "technology", "science", "sports", "health", "entertainment", "politics", "lifestyle", "myfeed", "local_news" };
                foreach (var d in def) if (d == cat) return true;
                return false;
        }
    }

    private NewsPreferences() {
        config = new GLib.KeyFile();
        config_path = get_config_file_path();
        // Detect whether a configuration already exists so callers can
        // present first-run flows (dialogs, onboarding) when appropriate.
        try {
            bool exists = GLib.FileUtils.test(config_path, GLib.FileTest.EXISTS);
            first_run = !exists;
        } catch (GLib.Error e) { first_run = false; }
        // Ensure in-memory defaults are initialized so the UI reflects
        // the intended defaults on first run (before a config file
        // is created by save_config()).
        personalized_categories = new Gee.ArrayList<string>();
        preferred_sources = new Gee.ArrayList<string>();
        // First-run convenience: if no config exists yet, seed the
        // preferred_sources with a sane default set. Historically we
        // enabled Guardian only; prefer enabling all sources by default
        // so users can unchoose what they don't want.
        if (first_run) {
            string[] all = { "guardian", "reddit", "bbc", "nytimes", "wsj", "bloomberg", "reuters", "npr", "fox" };
            foreach (var s in all) preferred_sources.add(s);
        }
        // Preferred sources and other defaults will be seeded by load_config()/save_config().
        // Don't seed preferred_sources here. Load configuration first so
        // pre-existing user choices are respected. If no config exists,
        // load_config() will create one and seed defaults appropriately.
    viewed_articles = new Gee.ArrayList<string>();
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
        try {
            // Convert NewsSource enum to string
            string source_name = "";
            switch (news_source) {
                case NewsSource.GUARDIAN: source_name = "guardian"; break;
                case NewsSource.REDDIT: source_name = "reddit"; break;
                case NewsSource.BBC: source_name = "bbc"; break;
                case NewsSource.WALL_STREET_JOURNAL: source_name = "wsj"; break;
                case NewsSource.NEW_YORK_TIMES: source_name = "nytimes"; break;
                case NewsSource.BLOOMBERG: source_name = "bloomberg"; break;
                default: source_name = "guardian"; break;
            }
            
            config.set_string("preferences", "news_source", source_name);
            // Ensure we don't persist a category incompatible with the
            // selected news source. When the user has enabled multiple
            // `preferred_sources` we treat the multi-select as authoritative
            // and avoid coercing `category` here (the UI and fetch code will
            // handle combining categories). Only enforce compatibility when
            // operating in legacy/single-source mode.
            if (preferred_sources == null || preferred_sources.size <= 1) {
                // Allow the special "myfeed" and "frontpage" categories to
                // persist when selected even in single-source mode. These
                // are UI-level aggregated views (not tied to a specific
                // provider) and should not be coerced to "all".
                if (!(category == "myfeed" && personalized_feed_enabled) && category != "frontpage") {
                    if (!category_valid_for_source(news_source, category)) {
                        // Use the neutral "all" view as a safe persisted default
                        category = "all";
                    }
                }
            }
            config.set_string("preferences", "category", category);
            // Persist user location if provided
            config.set_string("preferences", "user_location", user_location);
            // Persist resolved city name if present
            config.set_string("preferences", "user_location_city", user_location_city);
            // Persist the personalized feed toggle
            config.set_boolean("preferences", "personalized_feed_enabled", personalized_feed_enabled);
            // Persist personalized categories list
            // If Bloomberg is not enabled in preferred_sources, strip any
            // Bloomberg-only categories so the saved personalized feed will
            // not attempt to show Bloomberg categories when the source is
            // disabled.
            if (!preferred_source_enabled("bloomberg") && personalized_categories != null) {
                string[] bb = { "markets", "industries", "economics", "wealth", "green", "politics", "technology" };
                var to_remove = new Gee.ArrayList<string>();
                foreach (var c in personalized_categories) {
                    foreach (var b in bb) if (c == b) to_remove.add(c);
                }
                foreach (var r in to_remove) personalized_categories.remove(r);
            }

            if (personalized_categories != null) {
                // Convert Gee.ArrayList to string[]
                string[] arr = new string[personalized_categories.size];
                for (int i = 0; i < personalized_categories.size; i++) arr[i] = personalized_categories.get(i);
                config.set_string_list("preferences", "personalized_categories", arr);
            } else {
                config.set_string_list("preferences", "personalized_categories", new string[0]);
            }
            // Persist preferred sources (if present)
            if (preferred_sources != null) {
                string[] parr = new string[preferred_sources.size];
                for (int i = 0; i < preferred_sources.size; i++) parr[i] = preferred_sources.get(i);
                config.set_string_list("preferences", "preferred_sources", parr);
            } else {
                // Fall back to single news_source if preferred_sources not yet set
                string[] fallback = { source_name };
                config.set_string_list("preferences", "preferred_sources", fallback);
            }
            // Persist viewed articles (normalized URLs) so viewed state survives restarts
            if (viewed_articles != null) {
                string[] varr = new string[viewed_articles.size];
                for (int i = 0; i < viewed_articles.size; i++) varr[i] = viewed_articles.get(i);
                config.set_string_list("preferences", "viewed_articles", varr);
            } else {
                config.set_string_list("preferences", "viewed_articles", new string[0]);
            }
            
            string config_data = config.to_data();
            GLib.FileUtils.set_contents(config_path, config_data);
        } catch (GLib.Error e) {
            warning("Failed to save config: %s", e.message);
        }
    }

    private void load_config() {
        try {
            if (!GLib.FileUtils.test(config_path, GLib.FileTest.EXISTS)) {
                // No config file yet, save current defaults to create it
                save_config();
                return;
            }
            
            config.load_from_file(config_path, GLib.KeyFileFlags.NONE);
            
            // Load news source
            if (config.has_key("preferences", "news_source")) {
                string source_name = config.get_string("preferences", "news_source");
                switch (source_name) {
                    case "guardian": news_source = NewsSource.GUARDIAN; break;
                    case "reddit": news_source = NewsSource.REDDIT; break;
                    case "bbc": news_source = NewsSource.BBC; break;
                    case "wsj": news_source = NewsSource.WALL_STREET_JOURNAL; break;
                    case "nytimes": news_source = NewsSource.NEW_YORK_TIMES; break;
                    case "google": news_source = NewsSource.GUARDIAN; break; // Migrate from removed Google News
                    case "bloomberg": news_source = NewsSource.BLOOMBERG; break;
                    default: news_source = NewsSource.GUARDIAN; break;
                }
            }

            // Load preferred sources list if present; otherwise seed from news_source
            if (config.has_key("preferences", "preferred_sources")) {
                try {
                    string[] parr = config.get_string_list("preferences", "preferred_sources");
                    preferred_sources = new Gee.ArrayList<string>();
                    foreach (var s in parr) preferred_sources.add(s);
                } catch (GLib.Error e) { preferred_sources = new Gee.ArrayList<string>(); }
            } else {
                preferred_sources = new Gee.ArrayList<string>();
                // Seed with the single news_source value for backward compatibility
                switch (news_source) {
                    case NewsSource.GUARDIAN: preferred_sources.add("guardian"); break;
                    case NewsSource.REDDIT: preferred_sources.add("reddit"); break;
                    case NewsSource.BBC: preferred_sources.add("bbc"); break;
                    case NewsSource.WALL_STREET_JOURNAL: preferred_sources.add("wsj"); break;
                    case NewsSource.NEW_YORK_TIMES: preferred_sources.add("nytimes"); break;
                    case NewsSource.BLOOMBERG: preferred_sources.add("bloomberg"); break;
                    case NewsSource.REUTERS: preferred_sources.add("reuters"); break;
                    case NewsSource.NPR: preferred_sources.add("npr"); break;
                    case NewsSource.FOX: preferred_sources.add("fox"); break;
                    default: preferred_sources.add("guardian"); break;
                }
            }
            
            // Load category (normalization is applied after reading the
            // personalized_feed flag so we can preserve "myfeed" when the
            // user has enabled personalization).
            if (config.has_key("preferences", "category")) {
                category = config.get_string("preferences", "category");
            }
            // Load personalized feed flag if present
            if (config.has_key("preferences", "personalized_feed_enabled")) {
                try {
                    personalized_feed_enabled = config.get_boolean("preferences", "personalized_feed_enabled");
                } catch (GLib.Error e) { /* ignore and keep default */ }
            }
            // Load user-provided location if present
            if (config.has_key("preferences", "user_location")) {
                try {
                    user_location = config.get_string("preferences", "user_location");
                } catch (GLib.Error e) { user_location = ""; }
            }
            // Load resolved city name if present
            if (config.has_key("preferences", "user_location_city")) {
                try {
                    user_location_city = config.get_string("preferences", "user_location_city");
                } catch (GLib.Error e) { user_location_city = ""; }
            }
            // After knowing whether personalization is enabled, normalize
            // the category. Allow "myfeed" to survive normalization when
            // personalization is enabled so users can select a personalized
            // feed even when the effective single source is Bloomberg.
            if (!category_valid_for_source(news_source, category)) {
                if (!(category == "myfeed" && personalized_feed_enabled)) {
                    category = "all";
                }
            }
            // Load personalized categories list if present
            if (config.has_key("preferences", "personalized_categories")) {
                try {
                    string[] arr = config.get_string_list("preferences", "personalized_categories");
                    personalized_categories = new Gee.ArrayList<string>();
                    foreach (var s in arr) personalized_categories.add(s);
                } catch (GLib.Error e) { personalized_categories = new Gee.ArrayList<string>(); }
            } else {
                personalized_categories = new Gee.ArrayList<string>();
            }
            // Load viewed articles list if present
            if (config.has_key("preferences", "viewed_articles")) {
                try {
                    string[] varr = config.get_string_list("preferences", "viewed_articles");
                    viewed_articles = new Gee.ArrayList<string>();
                    foreach (var s in varr) viewed_articles.add(s);
                } catch (GLib.Error e) { viewed_articles = new Gee.ArrayList<string>(); }
            } else {
                viewed_articles = new Gee.ArrayList<string>();
            }
        } catch (GLib.Error e) {
            warning("Failed to load config: %s", e.message);
        }
    }
}