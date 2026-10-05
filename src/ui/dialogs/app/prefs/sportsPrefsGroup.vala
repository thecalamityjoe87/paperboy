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

// Preferences "Sports Score Cards" group: master switch, the Leagues and
// Section Order pages, favorite teams, and the live indicator.
public class SportsPrefsGroup : Adw.PreferencesGroup {
    private PrefsContext ctx;

    // Focused when Preferences is opened from the Sports settings badge.
    public Adw.SwitchRow master_row { get; private set; }

    private delegate void SportsOrderPersistFunc();
    public delegate void LeagueToggledFunc();

    public SportsPrefsGroup(PrefsContext ctx) {
        this.ctx = ctx;
        var prefs = ctx.prefs;
        var win = ctx.win;
        set_title(_("Sports Score Cards"));
        set_description(_("Choose which leagues show score cards in the Sports category, and the order their sections appear in"));

        var favorite_teams_row = new Adw.ActionRow();
        favorite_teams_row.set_title(_("Favorite Teams"));
        favorite_teams_row.set_subtitle(_("Follow specific teams to show their own score cards"));
        PrefsRows.make_nav_row(ctx.dialog, favorite_teams_row, () => build_favorite_teams_leagues_page());

        var leagues_row = new Adw.ActionRow();
        leagues_row.set_title(_("Leagues"));
        update_leagues_summary(leagues_row);
        PrefsRows.make_nav_row(ctx.dialog, leagues_row, () => build_leagues_page(leagues_row));

        // Rebuilt each time it opens, so it lists the leagues that are on now.
        var order_row = new Adw.ActionRow();
        order_row.set_title(_("Section Order"));
        order_row.set_subtitle(_("Drag leagues into the order their sections appear in"));
        PrefsRows.make_nav_row(ctx.dialog, order_row, () => build_order_page());

        master_row = new Adw.SwitchRow();
        master_row.set_title(_("Show score cards"));
        master_row.set_subtitle(_("Turn off to hide all live score cards from the Sports category"));
        master_row.set_active(prefs.sports_scores_enabled);
        leagues_row.set_sensitive(prefs.sports_scores_enabled);
        order_row.set_sensitive(prefs.sports_scores_enabled);

        var live_indicator_row = new Adw.SwitchRow();
        live_indicator_row.set_title(_("Show live indicator"));
        live_indicator_row.set_subtitle(_("Show a \"Live\" pill next to the Sports sidebar count while a game is in progress"));
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
            leagues_row.set_sensitive(enabled);
            order_row.set_sensitive(enabled);
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
        add(leagues_row);
        add(order_row);
        add(favorite_teams_row);
        add(live_indicator_row);
    }

    // Preferences headings for SportsScoresService's region codes, in display order.
    private const string[] REGIONS = { "intl", "europe", "us", "latam", "asia" };

    private static string region_title(string region) {
        switch (region) {
            case "europe": return _("Europe");
            case "us": return _("United States and Canada");
            case "latam": return _("Latin America");
            case "asia": return _("Asia and Oceania");
            default: return _("International");
        }
    }

    // League subtitle: its sport, from ESPN's sport path.
    private static string sport_label(string sport_path) {
        switch (sport_path) {
            case "soccer": return _("Soccer");
            case "football": return _("American football");
            case "basketball": return _("Basketball");
            case "baseball": return _("Baseball");
            case "hockey": return _("Hockey");
            case "rugby": return _("Rugby");
            case "cricket": return _("Cricket");
            case "mma": return _("Mixed martial arts");
            case "tennis": return _("Tennis");
            case "golf": return _("Golf");
            case "racing": return _("Motor racing");
            default: return "";
        }
    }

    private void update_leagues_summary(Adw.ActionRow row) {
        var keys = SportsScoresService.league_keys();
        int n = 0;
        foreach (var key in keys) if (ctx.prefs.sports_league_enabled(key)) n++;
        // if/else, not a ternary: Vala frees the printf() temp in that form before it's used.
        if (n == 0) row.set_subtitle(_("None"));
        else row.set_subtitle(ngettext("%d of %d league on", "%d of %d leagues on", keys.size).printf(n, keys.size));
    }

    private Adw.NavigationPage build_leagues_page(Adw.ActionRow summary_row) {
        var page = new Adw.PreferencesPage();
        foreach (var group in build_league_groups(ctx.prefs, ctx.win, () => update_leagues_summary(summary_row))) {
            page.add(group);
        }
        return PrefsRows.build_subpage(page, _("Leagues"));
    }

    // One group per region, each league a switch with its sport underneath -
    // shared by the Leagues page and onboarding's sports page. `win` is null
    // during onboarding (no NewsWindow yet to refresh); on_toggled runs after
    // each switch is saved.
    public static Gee.ArrayList<Adw.PreferencesGroup> build_league_groups(NewsPreferences prefs, NewsWindow? win, owned LeagueToggledFunc? on_toggled = null) {
        var groups = new Gee.ArrayList<Adw.PreferencesGroup>();
        foreach (string region in REGIONS) {
            var group = new Adw.PreferencesGroup();
            group.set_title(region_title(region));
            foreach (var league_key in SportsScoresService.league_keys()) {
                if (SportsScoresService.region_for(league_key) != region) continue;
                var row = new Adw.SwitchRow();
                row.set_title(SportsScoresService.display_name_for(league_key));
                row.set_subtitle(sport_label(SportsScoresService.sport_for(league_key)));
                row.add_prefix(league_logo(league_key));
                row.set_active(prefs.sports_league_enabled(league_key));

                string _league_key = league_key;
                row.notify["active"].connect(() => {
                    prefs.set_sports_league_enabled(_league_key, row.get_active());
                    if (on_toggled != null) on_toggled();
                    // Reflect the change immediately rather than waiting on the
                    // "Refresh Content?" dialog other Preferences changes use,
                    // since Sports may already be the open category.
                    if (win != null && win.prefs.category == "sports") {
                        SportsScoresController.load(win);
                    }
                });
                group.add(row);
            }
            groups.add(group);
        }
        return groups;
    }

    private Adw.NavigationPage build_order_page() {
        var page = new Adw.PreferencesPage();
        var group = new Adw.PreferencesGroup();
        group.set_description(_("Drag a league by its handle to set where its section appears in the Sports category. Only leagues that are on are listed."));
        group.add(build_league_list_box(ctx.prefs, ctx.win));
        page.add(group);
        return PrefsRows.build_subpage(page, _("Section Order"));
    }

    // Builds the Section Order page's drag-reorderable list of the leagues that are on.
    private static Gtk.ListBox build_league_list_box(NewsPreferences prefs, NewsWindow? win) {
        var sports_list_box = new Gtk.ListBox();
        sports_list_box.set_selection_mode(Gtk.SelectionMode.NONE);
        sports_list_box.add_css_class("boxed-list");

        // Persists the listbox's current row order back to prefs, reading
        // each row's league key off the name we stashed on it below rather
        // than tracking a separate parallel list.
        SportsOrderPersistFunc persist_sports_order = () => {
            var league_keys = SportsScoresService.league_keys();
            var new_order = new Gee.ArrayList<string>();
            var row = sports_list_box.get_row_at_index(0);
            int i = 0;
            while (row != null) {
                if (league_keys.contains(row.get_name())) new_order.add(row.get_name());
                i++;
                row = sports_list_box.get_row_at_index(i);
            }
            // Keep the saved places of leagues this list doesn't show (those that are off)
            foreach (var key in prefs.sports_league_order) {
                if (!new_order.contains(key)) new_order.add(key);
            }
            prefs.sports_league_order = new_order;

            if (win != null && win.prefs.category == "sports") {
                SportsScoresController.load(win);
            }
        };

        foreach (var league_key in prefs.ordered_sports_league_keys()) {
            if (!prefs.sports_league_enabled(league_key)) continue;
            string display_name = SportsScoresService.display_name_for(league_key);
            var league_row = new Adw.ActionRow();
            league_row.set_subtitle(sport_label(SportsScoresService.sport_for(league_key)));
            league_row.set_title(display_name);
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

        if (sports_list_box.get_row_at_index(0) == null) {
            var empty_row = new Adw.ActionRow();
            empty_row.set_title(_("No leagues are on"));
            empty_row.set_subtitle(_("Turn some on in Leagues"));
            sports_list_box.append(empty_row);
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

    // First level of the Favorite Teams drill-down. Individual sports (MMA,
    // tennis, golf, racing) have no teams, so they're left out.
    private Adw.NavigationPage build_favorite_teams_leagues_page() {
        var page = new Adw.PreferencesPage();
        bool first = true;
        foreach (string region in REGIONS) {
            var group = new Adw.PreferencesGroup();
            group.set_title(region_title(region));
            if (first) group.set_description(_("Pick a league, then choose teams to follow - each followed team gets its own score-card row in \"My Teams\""));
            bool any = false;
            foreach (var league_key in SportsScoresService.league_keys()) {
                if (!SportsScoresService.has_teams(league_key)) continue; // individual athletes, not teams
                if (SportsScoresService.region_for(league_key) != region) continue;

                var league_row = new Adw.ActionRow();
                league_row.set_title(SportsScoresService.display_name_for(league_key));
                league_row.set_subtitle(sport_label(SportsScoresService.sport_for(league_key)));
                league_row.add_prefix(league_logo(league_key));

                string _league_key = league_key;
                PrefsRows.make_nav_row(ctx.dialog, league_row, () => build_favorite_team_picker_page(_league_key));
                group.add(league_row);
                any = true;
            }
            if (!any) continue; // International holds only individual sports, which have no teams
            page.add(group);
            first = false;
        }
        return PrefsRows.build_subpage(page, _("Favorite Teams"));
    }

    // Second level: one switch per team in `league_key`, loaded on open.
    private Adw.NavigationPage build_favorite_team_picker_page(string league_key) {
        var prefs = ctx.prefs;
        var win = ctx.win;
        var page = new Adw.PreferencesPage();
        var group = new Adw.PreferencesGroup();
        group.set_title(SportsScoresService.display_name_for(league_key));

        var loading_row = new Adw.ActionRow();
        loading_row.set_title(_("Loading teams…"));
        group.add(loading_row);

        page.add(group);
        var nav_page = PrefsRows.build_subpage(page, SportsScoresService.display_name_for(league_key));

        SportsScoresService.fetch_teams(league_key, (returned_key, teams) => {
            group.remove(loading_row);

            if (teams == null || teams.size == 0) {
                var empty_row = new Adw.ActionRow();
                empty_row.set_title(_("Couldn't load teams"));
                empty_row.set_subtitle(_("Check your connection and try again later."));
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
