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

// Preferences "Sports Score Cards" group: master switch, favorite teams,
// live indicator, and the per-league list.
public class SportsPrefsGroup : Adw.PreferencesGroup {
    private PrefsContext ctx;

    // Focused when Preferences is opened from the Sports settings badge.
    public Adw.SwitchRow master_row { get; private set; }

    private delegate void SportsOrderPersistFunc();

    public SportsPrefsGroup(PrefsContext ctx) {
        this.ctx = ctx;
        var prefs = ctx.prefs;
        var win = ctx.win;
        set_title("Sports Score Cards");
        set_description("Choose which leagues show score cards, and drag a row (by its handle) to set the order their sections appear in the Sports category");

        var favorite_teams_row = new Adw.ActionRow();
        favorite_teams_row.set_title("Favorite Teams");
        favorite_teams_row.set_subtitle("Follow specific teams to show their own score cards");
        PrefsRows.make_nav_row(ctx.dialog, favorite_teams_row, () => build_favorite_teams_leagues_page());

        var sports_list_box = build_league_list_box(prefs, win);
        sports_list_box.set_margin_top(18);

        master_row = new Adw.SwitchRow();
        master_row.set_title("Show score cards");
        master_row.set_subtitle("Turn off to hide all live score cards from the Sports category");
        master_row.set_active(prefs.sports_scores_enabled);
        sports_list_box.set_sensitive(prefs.sports_scores_enabled);

        var live_indicator_row = new Adw.SwitchRow();
        live_indicator_row.set_title("Show live indicator");
        live_indicator_row.set_subtitle("Show a \"Live\" pill next to the Sports sidebar count while a game is in progress");
        live_indicator_row.set_active(prefs.sports_live_indicator_enabled);
        live_indicator_row.set_sensitive(prefs.sports_scores_enabled);

        // The live indicator runs only while both switches are on.
        void sync_live_indicator() {
            if (win == null || win.sports_live_indicator == null) return;
            if (prefs.sports_scores_enabled && prefs.sports_live_indicator_enabled) {
                win.sports_live_indicator.start();
            } else {
                win.sports_live_indicator.stop();
            }
        }

        master_row.notify["active"].connect(() => {
            bool enabled = master_row.get_active();
            prefs.sports_scores_enabled = enabled;
            sports_list_box.set_sensitive(enabled);
            // The live indicator can't be enabled while score cards themselves are off.
            live_indicator_row.set_sensitive(enabled);
            sync_live_indicator();
            if (win != null && win.prefs.category == "sports") {
                SportsScoresController.load(win);
            }
        });

        live_indicator_row.notify["active"].connect(() => {
            prefs.sports_live_indicator_enabled = live_indicator_row.get_active();
            sync_live_indicator();
        });

        add(master_row);
        add(favorite_teams_row);
        add(live_indicator_row);
        add(sports_list_box);
    }

    // Builds the drag-reorderable, per-league enable/disable list - shared
    // between Preferences and the onboarding flow so both stay in sync
    // automatically. `win` is null during onboarding (no NewsWindow yet to
    // refresh).
    public static Gtk.ListBox build_league_list_box(NewsPreferences prefs, NewsWindow? win) {
        var sports_list_box = new Gtk.ListBox();
        sports_list_box.set_selection_mode(Gtk.SelectionMode.NONE);
        sports_list_box.add_css_class("boxed-list");

        // Persists the listbox's current row order back to prefs, reading
        // each row's league key off the name we stashed on it below rather
        // than tracking a separate parallel list.
        SportsOrderPersistFunc persist_sports_order = () => {
            var new_order = new Gee.ArrayList<string>();
            var row = sports_list_box.get_row_at_index(0);
            int i = 0;
            while (row != null) {
                new_order.add(row.get_name());
                i++;
                row = sports_list_box.get_row_at_index(i);
            }
            prefs.sports_league_order = new_order;

            if (win != null && win.prefs.category == "sports") {
                SportsScoresController.load(win);
            }
        };

        foreach (var league_key in prefs.ordered_sports_league_keys()) {
            string display_name = SportsScoresService.display_name_for(league_key);
            var league_row = new Adw.SwitchRow();
            league_row.set_title(display_name);
            league_row.set_active(prefs.sports_league_enabled(league_key));
            league_row.set_name(league_key);

            // Circular logo baked into the image itself (PixbufUtils) - a
            // plain "circular-logo" CSS class only clips widgets already
            // scoped under an existing selector.
            league_row.add_prefix(league_logo(league_key));
            PrefsRows.add_drag_handle(league_row, display_name, () => {
                Value val = Value(typeof(Gtk.ListBoxRow));
                val.set_object(league_row);
                return new Gdk.ContentProvider.for_value(val);
            });

            string _league_key = league_key;
            league_row.notify["active"].connect(() => {
                prefs.set_sports_league_enabled(_league_key, league_row.get_active());

                // Reflect the change immediately rather than waiting on the
                // "Refresh Content?" dialog other Preferences changes use -
                // toggling a switch here has no other user-visible effect
                // otherwise, since Sports may already be the open category.
                if (win != null && win.prefs.category == "sports") {
                    SportsScoresController.load(win);
                }
            });

            var drop_target = new Gtk.DropTarget(typeof(Gtk.ListBoxRow), Gdk.DragAction.MOVE);
            drop_target.drop.connect((value, x, y) => {
                Gtk.ListBoxRow? src_row = (Gtk.ListBoxRow) value.get_object();
                if (src_row == null || src_row == league_row) return false;

                int target_index = league_row.get_index();
                sports_list_box.remove(src_row);
                sports_list_box.insert(src_row, target_index);
                persist_sports_order();
                return true;
            });
            league_row.add_controller(drop_target);

            sports_list_box.append(league_row);
        }

        return sports_list_box;
    }

    private static Gtk.Image league_logo(string league_key) {
        var logo = PixbufUtils.make_circular_logo_placeholder(PrefsRows.ROW_ICON_SIZE);
        string? logo_url = SportsScoresService.logo_url_for(league_key);
        if (logo_url != null && logo_url.length > 0) {
            PixbufUtils.load_circular_logo_async(logo, logo_url, PrefsRows.ROW_ICON_SIZE);
        }
        return logo;
    }

    // First level of the Favorite Teams drill-down. MMA has no teams
    // (individual fighters), so it's the only league left out.
    private Adw.NavigationPage build_favorite_teams_leagues_page() {
        var page = new Adw.PreferencesPage();
        var group = new Adw.PreferencesGroup();
        group.set_description("Pick a league, then choose teams to follow - each followed team gets its own score-card row in \"My Teams\"");

        foreach (var league_key in SportsScoresService.league_keys()) {
            if (league_key == "mma") continue; // individual fighters, not teams

            var league_row = new Adw.ActionRow();
            league_row.set_title(SportsScoresService.display_name_for(league_key));
            league_row.add_prefix(league_logo(league_key));

            string _league_key = league_key;
            PrefsRows.make_nav_row(ctx.dialog, league_row, () => build_favorite_team_picker_page(_league_key));
            group.add(league_row);
        }

        page.add(group);
        return PrefsRows.build_subpage(page, "Favorite Teams");
    }

    // Second level: one switch per team in `league_key`, loaded on open.
    private Adw.NavigationPage build_favorite_team_picker_page(string league_key) {
        var prefs = ctx.prefs;
        var win = ctx.win;
        var page = new Adw.PreferencesPage();
        var group = new Adw.PreferencesGroup();
        group.set_title(SportsScoresService.display_name_for(league_key));

        var loading_row = new Adw.ActionRow();
        loading_row.set_title("Loading teams…");
        group.add(loading_row);

        page.add(group);
        var nav_page = PrefsRows.build_subpage(page, SportsScoresService.display_name_for(league_key));

        SportsScoresService.fetch_teams(league_key, (returned_key, teams) => {
            group.remove(loading_row);

            if (teams == null || teams.size == 0) {
                var empty_row = new Adw.ActionRow();
                empty_row.set_title("Couldn't load teams");
                empty_row.set_subtitle("Check your connection and try again later.");
                group.add(empty_row);
                return;
            }

            foreach (var team in teams) {
                var team_row = new Adw.SwitchRow();
                team_row.set_title(GLib.Markup.escape_text(team.display_name));
                team_row.set_active(prefs.is_team_favorited(league_key, team.id));
                team_row.add_prefix(PrefsRows.favicon_image(team.logo_url));

                string _team_id = team.id;
                team_row.notify["active"].connect(() => {
                    if (team_row.get_active()) {
                        prefs.add_favorite_team(league_key, _team_id);
                    } else {
                        prefs.remove_favorite_team(league_key, _team_id);
                    }
                    if (win != null && win.prefs.category == "sports") {
                        SportsScoresController.load(win);
                    }
                });

                group.add(team_row);
            }
        });

        return nav_page;
    }
}
