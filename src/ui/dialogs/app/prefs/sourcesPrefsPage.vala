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

// Preferences "Sources" tab: built-in outlets, followed feeds, podcasts,
// magazine sources and Local News locations. The long lists each live on
// their own subpage.
public class SourcesPrefsPage : Adw.PreferencesPage {
    private PrefsContext ctx;
    private Paperboy.RssSourceStore rss_store;

    private Adw.PreferencesGroup rss_sources_group;
    private Adw.ActionRow feeds_nav_row;
    private int feed_row_count = 0;
    private Gee.HashSet<string> rendered_source_urls = new Gee.HashSet<string>();

    private Adw.PreferencesGroup local_group;
    private Gee.ArrayList<Gtk.Widget> local_rows = new Gee.ArrayList<Gtk.Widget>();

    // Focused when Preferences is opened straight to Local News.
    public Adw.ButtonRow add_location_row { get; private set; }

    public SourcesPrefsPage(PrefsContext ctx) {
        this.ctx = ctx;
        rss_store = Paperboy.RssSourceStore.get_instance();
        set_title(_("Sources"));
        set_icon_name("application-rss+xml-symbolic");

        add(build_builtin_group());
        add(build_feeds_group());
        add(build_podcasts_group());
        add(build_magazines_group());
        add(build_local_group());
    }

    // Adds rows for followed feeds not shown yet - e.g. after an OPML
    // import - so they appear without reopening Preferences.
    public void add_new_feed_rows() {
        foreach (var rss_source in rss_store.get_all_sources()) {
            if (rendered_source_urls.contains(rss_source.url)) continue;
            add_rss_source_row(rss_source);
        }
    }

    // ========== BUILT-IN SOURCES ==========

    private Adw.PreferencesGroup build_builtin_group() {
        var builtin_sources_group = new Adw.PreferencesGroup();
        foreach (unowned BuiltinSource s in BuiltinSources.ALL) {
            builtin_sources_group.add(create_builtin_source_row(s.name, _(s.description), s.id, s.favicon_url));
        }

        var builtin_page = new Adw.PreferencesPage();
        builtin_page.add(builtin_sources_group);
        var builtin_nav_page = PrefsRows.build_subpage(builtin_page, _("Built-in sources"));

        var builtin_group = new Adw.PreferencesGroup();
        builtin_group.set_title(_("Built-in sources"));
        builtin_group.set_description(_("News outlets that come with Paperboy"));
        var builtin_nav_row = new Adw.ActionRow();
        builtin_nav_row.set_title(_("News outlets"));
        builtin_nav_row.set_subtitle(_("Choose which outlets to follow"));
        PrefsRows.make_nav_row(ctx.dialog, builtin_nav_row, () => builtin_nav_page);
        builtin_group.add(builtin_nav_row);
        return builtin_group;
    }

    private Adw.ActionRow create_builtin_source_row(string title, string subtitle, string source_id, string? favicon_url) {
        var row = new Adw.ActionRow();
        row.set_title(title);
        row.set_subtitle(PrefsRows.elide(subtitle, 36));
        row.set_tooltip_text(subtitle);
        row.add_prefix(PrefsRows.favicon_image(favicon_url));

        var sw = PrefsRows.add_switch_suffix(row, ctx.prefs.preferred_source_enabled(source_id));
        sw.notify["active"].connect(() => {
            ctx.prefs.set_preferred_source_enabled(source_id, sw.get_active());
            ctx.prefs.save_config();
            ctx.sources_changed = true;

            // Update My Feed unread badge immediately when source is toggled
            if (ctx.win != null && ctx.win.sidebar_manager != null) {
                ctx.win.sidebar_manager.update_badge_for_category("myfeed");
            }
        });
        return row;
    }

    // ========== FOLLOWED FEEDS ==========

    private Adw.PreferencesGroup build_feeds_group() {
        rss_sources_group = new Adw.PreferencesGroup();
        feeds_nav_row = new Adw.ActionRow();
        feeds_nav_row.set_title(_("Followed feeds"));

        foreach (var rss_source in rss_store.get_all_sources()) {
            add_rss_source_row(rss_source);
        }
        update_feeds_summary();

        var feeds_page = new Adw.PreferencesPage();
        feeds_page.add(rss_sources_group);
        var feeds_nav_page = PrefsRows.build_subpage(feeds_page, _("Custom feeds"));

        var custom_group = new Adw.PreferencesGroup();
        custom_group.set_title(_("Custom feeds"));
        custom_group.set_description(_("RSS feeds you've followed"));
        PrefsRows.make_nav_row(ctx.dialog, feeds_nav_row, () => feeds_nav_page);
        custom_group.add(feeds_nav_row);
        return custom_group;
    }

    private void update_feeds_summary() {
        if (feed_row_count == 0) {
            feeds_nav_row.set_subtitle(_("No feeds followed yet"));
            rss_sources_group.set_description(_("No feeds followed yet. Add one from the sidebar's Feeds section."));
        } else {
            feeds_nav_row.set_subtitle(ngettext("%d followed feed", "%d followed feeds", feed_row_count).printf(feed_row_count));
            rss_sources_group.set_description(null);
        }
    }

    private void add_rss_source_row(Paperboy.RssSource rss_source) {
        var win = ctx.win;
        var prefs = ctx.prefs;
        var rss_row = new Adw.ActionRow();

        // Escape any user-controlled text before assigning to ActionRow
        // Some underlying label implementations parse Pango/markup, so
        // ensure ampersands and other entities are escaped to avoid
        // runtime markup parse errors (e.g. "Food & Wine").
        rss_row.set_title(GLib.Markup.escape_text(rss_source.get_display_name() ?? ""));
        rss_row.set_subtitle(GLib.Markup.escape_text(PrefsRows.elide(rss_source.url ?? "", 28)));
        rss_row.set_tooltip_text(rss_source.url);
        rss_row.add_prefix(PrefsRows.rss_source_icon(rss_source));

        var edit_btn = PrefsRows.flat_icon_button("document-edit-symbolic", _("Rename this source"));
        edit_btn.clicked.connect(() => {
            FeedRenameDialog.present(ctx.dialog, win, rss_source.url, (updated) => {
                rss_row.set_title(GLib.Markup.escape_text(updated.get_display_name()));
            });
        });

        var delete_btn = PrefsRows.flat_icon_button("user-trash-symbolic", _("Remove this source"), true);
        delete_btn.clicked.connect(() => {
            DialogUtils.confirm_destructive(ctx.dialog, _("Remove this source?"),
                _("Are you sure you want to remove \"%s\" and all of its articles?").printf(rss_source.get_display_name()),
                _("Remove"), () => {
                bool is_currently_viewing = win != null && win.prefs.category == "rssfeed:" + rss_source.url;

                rss_store.remove_source(rss_source.url);

                // Remove from preferences if enabled
                if (prefs.preferred_source_enabled("custom:" + rss_source.url)) {
                    prefs.set_preferred_source_enabled("custom:" + rss_source.url, false);
                    prefs.save_config();
                }

                rss_sources_group.remove(rss_row);
                rendered_source_urls.remove(rss_source.url);
                feed_row_count--;
                update_feeds_summary();
                ctx.sources_changed = true;

                // If we were viewing this source, navigate to Front Page
                if (is_currently_viewing) {
                    GLib.Idle.add(() => {
                        win.prefs.category = "frontpage";
                        win.prefs.save_config();
                        win.fetch_news();
                        return false;
                    });
                }
            });
        });

        rss_row.add_suffix(edit_btn);
        rss_row.add_suffix(delete_btn);

        var custom_switch = PrefsRows.add_switch_suffix(rss_row, prefs.preferred_source_enabled("custom:" + rss_source.url));
        custom_switch.notify["active"].connect(() => {
            bool now_enabled = custom_switch.get_active();
            prefs.set_preferred_source_enabled("custom:" + rss_source.url, now_enabled);
            prefs.save_config();
            ctx.sources_changed = true;

            // Reflect the enable/disable immediately in the sidebar
            // rather than waiting on the "Refresh Content?" dialog
            // that only appears once Preferences is closed.
            if (win != null && win.sidebar_manager != null) {
                win.sidebar_manager.rebuild_sidebar();
                win.sidebar_manager.update_badge_for_category("myfeed");
            }

            // If the user just disabled the feed they're currently
            // viewing, its sidebar row is now gone - leaving its
            // content on screen would be stale and unreachable, so
            // redirect to Front Page like the "no sources support
            // this category" fallback does on dialog close.
            if (!now_enabled && win != null && win.prefs.category == "rssfeed:" + rss_source.url) {
                win.prefs.category = "frontpage";
                win.prefs.save_config();
                win.update_content_header();
                win.fetch_news();
            }
        });

        rss_sources_group.add(rss_row);
        rendered_source_urls.add(rss_source.url);
        feed_row_count++;
        update_feeds_summary();
    }

    // ========== PODCASTS ==========

    private Adw.PreferencesGroup build_podcasts_group() {
        var podcast_store = Paperboy.PodcastSubscriptionStore.get_instance();
        var podcasts_list_group = new Adw.PreferencesGroup();
        var podcast_rows = new Gee.ArrayList<Gtk.Widget>();
        var podcasts_nav_row = new Adw.ActionRow();
        podcasts_nav_row.set_title(_("Subscribed podcasts"));

        var remove_all_podcasts_row = new Adw.ButtonRow();
        remove_all_podcasts_row.set_title(_("Remove all podcasts"));
        remove_all_podcasts_row.set_start_icon_name("user-trash-symbolic");
        remove_all_podcasts_row.add_css_class("destructive-action");
        var remove_all_podcasts_group = new Adw.PreferencesGroup();
        remove_all_podcasts_group.add(remove_all_podcasts_row);

        void update_podcasts_summary() {
            int n = podcast_rows.size;
            // if/else, not a nested ternary: Vala frees the printf() temp in that form before it's used.
            if (n == 0) podcasts_nav_row.set_subtitle(_("No podcasts yet"));
            else podcasts_nav_row.set_subtitle(ngettext("%d podcast", "%d podcasts", n).printf(n));
            podcasts_list_group.set_description(n == 0 ? _("No podcasts yet. Find some from the sidebar's Podcasts section.") : null);
            remove_all_podcasts_group.set_visible(n > 0);
        }

        void populate_podcast_rows() {
            foreach (var old_row in podcast_rows) podcasts_list_group.remove(old_row);
            podcast_rows.clear();
            foreach (var sub in podcast_store.get_all_subscriptions()) {
                int64 feed_id = sub.feed_id;
                string show_title = sub.title;
                var row = new Adw.ActionRow();
                row.set_title(GLib.Markup.escape_text(show_title));
                if (sub.author != null && sub.author.length > 0) row.set_subtitle(GLib.Markup.escape_text(sub.author));
                row.add_prefix(PrefsRows.favicon_image(sub.image_url));

                var delete_btn = PrefsRows.flat_icon_button("user-trash-symbolic", _("Remove podcast"), true);
                delete_btn.clicked.connect(() => {
                    DialogUtils.confirm_destructive(ctx.dialog, _("Remove podcast?"),
                        _("\"%s\" will be removed from your podcasts.").printf(show_title), _("Remove"), () => {
                        podcast_store.unsubscribe(feed_id);
                        podcasts_list_group.remove(row);
                        podcast_rows.remove(row);
                        update_podcasts_summary();
                    });
                });
                row.add_suffix(delete_btn);

                podcasts_list_group.add(row);
                podcast_rows.add(row);
            }
            update_podcasts_summary();
        }

        remove_all_podcasts_row.activated.connect(() => {
            int n = podcast_rows.size;
            string body = n == 1 ? _("Your 1 podcast will be removed.") : ngettext("All %d of your podcasts will be removed.", "All %d of your podcasts will be removed.", n).printf(n);
            DialogUtils.confirm_destructive(ctx.dialog, _("Remove all podcasts?"), body, _("Remove all"), () => {
                foreach (var sub in podcast_store.get_all_subscriptions()) podcast_store.unsubscribe(sub.feed_id);
                populate_podcast_rows();
            });
        });

        populate_podcast_rows();
        var podcasts_page = new Adw.PreferencesPage();
        podcasts_page.add(podcasts_list_group);
        podcasts_page.add(remove_all_podcasts_group);
        var podcasts_nav_page = PrefsRows.build_subpage(podcasts_page, _("Podcasts"));

        var podcasts_group = new Adw.PreferencesGroup();
        podcasts_group.set_title(_("Podcasts"));
        podcasts_group.set_description(_("Shows you've subscribed to"));
        PrefsRows.make_nav_row(ctx.dialog, podcasts_nav_row, () => podcasts_nav_page);
        podcasts_group.add(podcasts_nav_row);
        return podcasts_group;
    }

    // ========== MAGAZINE SOURCES ==========

    // Websites scanned for magazine PDFs.
    private Adw.PreferencesGroup build_magazines_group() {
        var magazine_store = Paperboy.MagazineLibraryStore.get_instance();
        var magazine_sources_list_group = new Adw.PreferencesGroup();
        int magazine_source_count = 0;
        var magazine_sources_nav_row = new Adw.ActionRow();
        magazine_sources_nav_row.set_title(_("Magazine sources"));

        void update_magazine_sources_summary() {
            int n = magazine_source_count;
            if (n == 0) magazine_sources_nav_row.set_subtitle(_("No sources yet"));
            else magazine_sources_nav_row.set_subtitle(ngettext("%d source", "%d sources", n).printf(n));
            magazine_sources_list_group.set_description(n == 0 ? _("No sources yet. Websites you add from the Magazines page show up here.") : null);
        }

        foreach (var source in magazine_store.get_all_sources()) {
            int64 source_id = source.id;
            string source_name = (source.name != null && source.name.length > 0) ? source.name : source.website_url;
            var row = new Adw.ActionRow();
            row.set_title(GLib.Markup.escape_text(source_name));
            row.set_subtitle(GLib.Markup.escape_text(PrefsRows.elide(source.website_url, 28)));
            row.set_tooltip_text(source.website_url);
            string host = UrlUtils.extract_host_from_url(source.website_url);
            row.add_prefix(PrefsRows.favicon_image(host.length > 0 ? SourceMetadata.google_favicon_url(host) : null));

            var delete_btn = PrefsRows.flat_icon_button("user-trash-symbolic", _("Remove source"), true);
            delete_btn.clicked.connect(() => {
                int n_entries = magazine_store.get_entries_for_source(source_id).size;
                string body;
                if (n_entries == 0) {
                    body = _("\"%s\" will be removed.").printf(source_name);
                } else if (n_entries == 1) {
                    body = "\"%s\" and the 1 magazine added from it will be removed, including its downloaded file.".printf(source_name);
                } else {
                    body = "\"%s\" and the %d magazines added from it will be removed, including their downloaded files.".printf(source_name, n_entries);
                }
                DialogUtils.confirm_destructive(ctx.dialog, _("Remove source?"), body, _("Remove"), () => {
                    magazine_store.remove_source(source_id);
                    magazine_sources_list_group.remove(row);
                    magazine_source_count--;
                    update_magazine_sources_summary();
                });
            });
            row.add_suffix(delete_btn);

            magazine_sources_list_group.add(row);
            magazine_source_count++;
        }
        update_magazine_sources_summary();

        var magazine_sources_page = new Adw.PreferencesPage();
        magazine_sources_page.add(magazine_sources_list_group);
        var magazine_sources_nav_page = PrefsRows.build_subpage(magazine_sources_page, _("Magazine sources"));

        var magazines_group = new Adw.PreferencesGroup();
        magazines_group.set_title(_("Magazines"));
        magazines_group.set_description(_("Websites scanned for magazine PDFs"));
        PrefsRows.make_nav_row(ctx.dialog, magazine_sources_nav_row, () => magazine_sources_nav_page);
        magazines_group.add(magazine_sources_nav_row);
        return magazines_group;
    }

    // ========== LOCAL NEWS ==========

    private Adw.PreferencesGroup build_local_group() {
        local_group = new Adw.PreferencesGroup();
        local_group.set_title(_("Local News"));
        add_location_row = new Adw.ButtonRow();
        add_location_row.set_title(_("Add a location"));
        add_location_row.set_start_icon_name("list-add-symbolic");

        add_location_row.activated.connect(() => {
            LocationDialog.choose(ctx.dialog, null, (chosen) => {
                LocationDialog.save_areas(ctx.win, chosen);
                populate_local_group();
            });
        });

        populate_local_group();
        return local_group;
    }

    // Fills the Local News group: one row per saved location, then the add row.
    private void populate_local_group() {
        var prefs = ctx.prefs;
        var win = ctx.win;
        foreach (var old_row in local_rows) local_group.remove(old_row);
        local_rows.clear();
        if (add_location_row.get_parent() != null) local_group.remove(add_location_row);

        var areas = prefs.get_local_areas();
        int max = NewsPreferences.MAX_LOCAL_AREAS;
        if (areas.size >= max) {
            local_group.set_description(ngettext("%d of %d location added. Remove one to add another.", "%d of %d locations added. Remove one to add another.", max).printf(areas.size, max));
        } else {
            local_group.set_description(ngettext("Up to %d location · %d added", "Up to %d locations · %d added", max).printf(max, areas.size));
        }

        for (int i = 0; i < areas.size; i++) {
            var area = areas[i];
            var row = new Adw.ActionRow();
            row.set_title(GLib.Markup.escape_text(area.name));
            row.set_subtitle(GLib.Markup.escape_text(area.city));
            var icon = CategoryIconsUtils.create_category_icon("local_news");
            if (icon != null) row.add_prefix(icon);
            PrefsRows.add_drag_handle(row, area.name, () => new Gdk.ContentProvider.for_value(area.key));

            var edit_btn = PrefsRows.flat_icon_button("document-edit-symbolic", _("Change location"));
            var delete_btn = PrefsRows.flat_icon_button("user-trash-symbolic", _("Remove location"), true);
            row.add_suffix(edit_btn);
            row.add_suffix(delete_btn);

            int target_index = i;
            var drop_target = new Gtk.DropTarget(typeof(string), Gdk.DragAction.MOVE);
            drop_target.drop.connect((value, x, y) => {
                string src_key = value.get_string();
                if (src_key == area.key) return false;
                prefs.move_local_area(src_key, target_index);
                // Rebuild after the drop finishes, not while its row is mid-drag.
                Idle.add(() => {
                    populate_local_group();
                    if (win.sidebar_manager != null) win.sidebar_manager.rebuild_sidebar();
                    return false;
                });
                return true;
            });
            row.add_controller(drop_target);
            edit_btn.clicked.connect(() => {
                LocationDialog.choose(ctx.dialog, area, (chosen) => {
                    LocationDialog.save_areas(win, chosen, area.key);
                    populate_local_group();
                });
            });
            delete_btn.clicked.connect(() => {
                prefs.remove_local_area(area.key);
                prefs.save_config();
                populate_local_group();
                LocationDialog.refresh_local_news(win);
            });

            local_group.add(row);
            local_rows.add(row);
        }

        add_location_row.set_sensitive(areas.size < max);
        local_group.add(add_location_row);
    }
}
