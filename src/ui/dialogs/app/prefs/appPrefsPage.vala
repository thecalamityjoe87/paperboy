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

using Gtk;
using Adw;

// Preferences "App" tab: appearance, update interval, caches, backup &
// restore, factory reset and experimental features.
public class AppPrefsPage : Adw.PreferencesPage {
    private PrefsContext ctx;

    // Automatic update intervals in dropdown order, as the
    // prefs.update_interval values FeedUpdateManager understands.
    private const string[] UPDATE_INTERVAL_IDS = { "15min", "30min", "1hour", "2hours", "4hours" };
    private const uint DEFAULT_UPDATE_INTERVAL_INDEX = 1; // 30 minutes

    // Emitted after an OPML import adds feeds, so the Sources page can
    // show them without Preferences being reopened.
    public signal void feeds_imported();

    public AppPrefsPage(PrefsContext ctx) {
        this.ctx = ctx;
        set_title(_("App"));
        set_icon_name("preferences-system-symbolic");

        add(build_appearance_group());
        add(build_update_interval_group());
        add(build_data_group());
        add(build_backup_group());
        add(build_danger_group());
        add(build_experimental_group());
    }

    // ========== APPEARANCE ==========

    private Adw.PreferencesGroup build_appearance_group() {
        var prefs = ctx.prefs;
        var group = new Adw.PreferencesGroup();
        group.set_title(_("Appearance"));

        var theme_row = new Adw.ActionRow();
        theme_row.set_title(_("Theme"));
        theme_row.set_subtitle(_("Follow the system theme, or force light or dark mode"));

        var theme_dropdown = new Gtk.DropDown.from_strings(new string[] {
            _("Follow System"), _("Light"), _("Dark")
        });
        theme_dropdown.set_valign(Gtk.Align.CENTER);
        switch (prefs.color_scheme) {
            case "light": theme_dropdown.set_selected(1); break;
            case "dark": theme_dropdown.set_selected(2); break;
            default: theme_dropdown.set_selected(0); break;
        }
        theme_dropdown.notify["selected"].connect(() => {
            switch (theme_dropdown.get_selected()) {
                case 1: prefs.color_scheme = "light"; break;
                case 2: prefs.color_scheme = "dark"; break;
                default: prefs.color_scheme = "system"; break;
            }
            prefs.save_config();
        });
        theme_row.add_suffix(theme_dropdown);
        theme_row.set_activatable_widget(theme_dropdown);
        group.add(theme_row);
        return group;
    }

    // ========== UPDATE INTERVAL ==========

    private Adw.PreferencesGroup build_update_interval_group() {
        var prefs = ctx.prefs;
        var group = new Adw.PreferencesGroup();
        group.set_title(_("Update Interval"));
        group.set_description(_("Short update intervals can trigger rate limits or cause requests to be blocked."));
        group.set_tooltip_text(_("Updating feeds too often may look like automated traffic. Sites could temporarily block requests or refuse articles if too many are made in a short time. Choose a longer interval to avoid this."));

        // "Manual" and "Sync Every" are radio-style check buttons.
        var manual_row = new Adw.ActionRow();
        manual_row.set_title(_("Manual"));
        manual_row.set_subtitle(_("No automatic synchronization"));
        var manual_check = new Gtk.CheckButton();
        manual_check.set_valign(Gtk.Align.CENTER);
        manual_row.add_prefix(manual_check);
        manual_row.set_activatable_widget(manual_check);

        var sync_row = new Adw.ActionRow();
        sync_row.set_title(_("Sync Every"));
        var sync_check = new Gtk.CheckButton();
        sync_check.set_group(manual_check);
        sync_check.set_valign(Gtk.Align.CENTER);
        sync_row.add_prefix(sync_check);

        // from_strings() needs a NULL-terminated array: a fresh Vala string[]
        // is one, the const array isn't. Literal _() here so xgettext sees them.
        var interval_labels = new string[UPDATE_INTERVAL_IDS.length];
        interval_labels[0] = _("15 Minutes");
        interval_labels[1] = _("30 Minutes");
        interval_labels[2] = _("1 Hour");
        interval_labels[3] = _("2 Hours");
        interval_labels[4] = _("4 Hours");
        var interval_dropdown = new Gtk.DropDown.from_strings(interval_labels);
        interval_dropdown.set_valign(Gtk.Align.CENTER);

        // Set initial state based on prefs
        string current_interval = prefs.update_interval;
        if (current_interval == "manual") {
            manual_check.set_active(true);
            interval_dropdown.set_sensitive(false);
        } else {
            sync_check.set_active(true);
            uint selected_index = DEFAULT_UPDATE_INTERVAL_INDEX;
            for (uint i = 0; i < UPDATE_INTERVAL_IDS.length; i++) {
                if (UPDATE_INTERVAL_IDS[i] == current_interval) selected_index = i;
            }
            interval_dropdown.set_selected(selected_index);
        }

        void save_selected_interval() {
            uint selected = interval_dropdown.get_selected();
            if (selected >= UPDATE_INTERVAL_IDS.length) selected = DEFAULT_UPDATE_INTERVAL_INDEX;
            prefs.update_interval = UPDATE_INTERVAL_IDS[selected];
            prefs.save_config();
        }

        manual_check.toggled.connect(() => {
            if (manual_check.get_active()) {
                interval_dropdown.set_sensitive(false);
                prefs.update_interval = "manual";
                prefs.save_config();
            }
        });

        sync_check.toggled.connect(() => {
            if (sync_check.get_active()) {
                interval_dropdown.set_sensitive(true);
                save_selected_interval();
            }
        });

        interval_dropdown.notify["selected"].connect(() => {
            if (sync_check.get_active()) save_selected_interval();
        });

        sync_row.add_suffix(interval_dropdown);
        sync_row.set_activatable_widget(sync_check);

        group.add(manual_row);
        group.add(sync_row);
        return group;
    }

    // ========== DATA ==========

    private Adw.PreferencesGroup build_data_group() {
        var win = ctx.win;
        var group = new Adw.PreferencesGroup();
        group.set_title(_("Data"));

        // Article content cache (MetaCache)
        var cache_row = new Adw.ActionRow();
        cache_row.set_title(_("Article content cache"));
        cache_row.set_subtitle(MetaCache.get_instance().get_metacache_info());

        var clear_cache_btn = new Gtk.Button.with_label(_("Clear"));
        clear_cache_btn.set_valign(Gtk.Align.CENTER);
        clear_cache_btn.add_css_class("destructive-action");
        clear_cache_btn.clicked.connect(() => {
            DialogUtils.confirm_destructive(ctx.dialog, _("Clear article content cache?"),
                _("This will delete cached article content and images. Previously read articles will need to be re-downloaded."),
                _("Clear Cache"), () => {
                if (win != null && win.meta_cache != null) {
                    win.meta_cache.clear();
                    cache_row.set_subtitle(_("0 bytes"));
                    if (win.toast_manager != null) win.toast_manager.show_toast(_("Cache cleared successfully"));
                }
            });
        });
        cache_row.add_suffix(clear_cache_btn);
        group.add(cache_row);

        // RSS feed cache
        var rss_cache = Paperboy.RssArticleCache.get_instance();
        var rss_cache_row = new Adw.ActionRow();
        rss_cache_row.set_title(_("RSS feed cache"));
        rss_cache_row.set_subtitle(rss_cache.get_cache_info_formatted());

        // Keep the size current as sources are removed, until the dialog closes
        var rss_source_store = Paperboy.RssSourceStore.get_instance();
        ulong source_removed_handler = rss_source_store.source_removed.connect((source) => {
            rss_cache_row.set_subtitle(rss_cache.get_cache_info_formatted());
        });
        ctx.dialog.closed.connect(() => {
            rss_source_store.disconnect(source_removed_handler);
        });

        var clear_rss_cache_btn = new Gtk.Button.with_label(_("Clear"));
        clear_rss_cache_btn.set_valign(Gtk.Align.CENTER);
        clear_rss_cache_btn.add_css_class("destructive-action");
        clear_rss_cache_btn.clicked.connect(() => {
            DialogUtils.confirm_destructive(ctx.dialog, _("Clear RSS Feed Cache?"),
                _("This will delete all cached RSS feed listings. Feeds will load from the network next time."),
                _("Clear Cache"), () => {
                rss_cache.clear_all();
                rss_cache_row.set_subtitle(_("0 bytes (0 articles)"));
                if (win != null && win.toast_manager != null) win.toast_manager.show_toast(_("RSS feed cache cleared"));
            });
        });
        rss_cache_row.add_suffix(clear_rss_cache_btn);
        group.add(rss_cache_row);
        return group;
    }

    // ========== BACKUP & RESTORE ==========

    private Adw.PreferencesGroup build_backup_group() {
        var win = ctx.win;
        var group = new Adw.PreferencesGroup();
        group.set_title(_("Backup &amp; Restore"));

        group.add(PrefsRows.backup_row(_("Feeds"),
            _("Export or import your custom RSS feeds and podcast subscriptions as an OPML file."),
            () => {
                PrefsRows.choose_save_path(win, _("Export Feeds & Podcasts"), "paperboy-feeds.opml",
                    PrefsRows.file_filter(_("OPML files"), "opml"), "export OPML", (path) => {
                    Paperboy.OpmlService.export_to_file(path);
                    if (win.toast_manager != null) win.toast_manager.show_toast(_("Exported feeds and podcasts"));
                });
            },
            () => {
                PrefsRows.choose_open_path(win, _("Import Feeds & Podcasts"),
                    PrefsRows.file_filter(_("OPML files"), "opml", "*.xml"), "import OPML", (path) => {
                    if (win.toast_manager != null) win.toast_manager.show_toast(_("Importing feeds and podcasts…"));
                    Paperboy.OpmlService.import_from_file(path, win.source_manager, win.session, win.feed_updater, (import_result) => {
                        ctx.sources_changed = true;
                        if (import_result.feeds_added > 0) feeds_imported();
                        if (win.sidebar_manager != null) win.sidebar_manager.rebuild_sidebar();
                        if (win.toast_manager != null) {
                            win.toast_manager.show_toast(_("Imported %d feed(s) and %d podcast(s)").printf(import_result.feeds_added, import_result.podcasts_added));
                        }
                    });
                });
            }));

        group.add(PrefsRows.backup_row(_("Notes"),
            _("Export or import your article notes as a JSON file."),
            () => {
                PrefsRows.choose_save_path(win, _("Export Notes"), "paperboy-notes.json",
                    PrefsRows.file_filter(_("JSON files"), "json"), "export notes", (path) => {
                    Paperboy.NotesExportService.export_to_file(path);
                    if (win.toast_manager != null) win.toast_manager.show_toast(_("Exported notes"));
                });
            },
            () => {
                PrefsRows.choose_open_path(win, _("Import Notes"),
                    PrefsRows.file_filter(_("JSON files"), "json"), "import notes", (path) => {
                    int imported = Paperboy.NotesExportService.import_from_file(path);
                    if (win.toast_manager != null) win.toast_manager.show_toast(_("Imported %d note(s)").printf(imported));
                });
            }));
        return group;
    }

    // ========== DANGER ZONE ==========

    private Adw.PreferencesGroup build_danger_group() {
        var group = new Adw.PreferencesGroup();
        group.set_title(_("Danger Zone"));

        var reset_row = new Adw.ActionRow();
        reset_row.set_title(_("Reset app to factory settings"));
        reset_row.set_subtitle(_("Erases all sources, saved articles, notes, settings, and cached data, then restarts Paperboy as if freshly installed."));

        var reset_btn = new Gtk.Button.with_label(_("Reset"));
        reset_btn.set_valign(Gtk.Align.CENTER);
        reset_btn.add_css_class("destructive-action");
        reset_btn.clicked.connect(() => {
            DialogUtils.confirm_destructive(ctx.dialog, _("Reset to factory settings?"),
                _("This permanently deletes all sources, saved articles, notes, and settings, and cannot be undone. Paperboy will restart as if freshly installed."),
                _("Reset App"), () => {
                ctx.prefs.factory_reset();
                ((PaperboyApp) ctx.win.application).restart();
            });
        });

        reset_row.add_suffix(reset_btn);
        group.add(reset_row);
        return group;
    }

    // ========== EXPERIMENTAL ==========

    private Adw.PreferencesGroup build_experimental_group() {
        var prefs = ctx.prefs;
        var group = new Adw.PreferencesGroup();
        group.set_title(_("Experimental"));

        var comments_row = new Adw.SwitchRow();
        comments_row.set_title(_("Show article comments"));
        comments_row.set_subtitle(_("Show a comments button on the reader page for articles with a discoverable comment source (native feed, Disqus, or Hacker News discussion). Coverage is limited - many sites don't expose comments through any of these."));
        comments_row.set_active(prefs.comments_enabled);
        comments_row.notify["active"].connect(() => {
            prefs.comments_enabled = comments_row.get_active();
        });
        group.add(comments_row);
        return group;
    }
}
