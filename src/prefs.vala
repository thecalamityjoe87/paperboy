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

    // Return true if the provided category is valid for the given source
    private bool category_valid_for_source(NewsSource source, string cat) {
        if (cat == "all") return true; // "All News" is supported by every source
        switch (source) {
            case NewsSource.BLOOMBERG:
                string[] bb = { "markets", "industries", "economics", "wealth", "green", "politics", "technology" };
                foreach (var b in bb) if (b == cat) return true;
                return false;
            default:
                string[] def = { "general", "us", "technology", "science", "sports", "health", "entertainment", "politics", "lifestyle" };
                foreach (var d in def) if (d == cat) return true;
                return false;
        }
    }

    private NewsPreferences() {
        config = new GLib.KeyFile();
        config_path = get_config_file_path();
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
            // selected news source (e.g., a Bloomberg-only category for other
            // sources). Normalize to a sensible default if necessary.
            if (!category_valid_for_source(news_source, category)) {
                // Use the neutral "all" view as a safe persisted default
                category = "all";
            }
            config.set_string("preferences", "category", category);
            
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
            
            // Load category and normalize it against the loaded news source.
            if (config.has_key("preferences", "category")) {
                category = config.get_string("preferences", "category");
                if (!category_valid_for_source(news_source, category)) {
                    // Don't try to force a Bloomberg-only category for other sources.
                    // Use neutral "all" view so UI shows something valid.
                    category = "all";
                }
            }
        } catch (GLib.Error e) {
            warning("Failed to load config: %s", e.message);
        }
    }
}