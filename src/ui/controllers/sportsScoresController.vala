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
 * Drives the live-scores sections shown in the Sports category between the
 * hero and the article grid below it, entirely additive to whatever the
 * Sports category already renders (RSS hero + article grid, untouched) -
 * see NewsWindow.fetch_news(), the only call site that invokes this.
 * Populates ContentView.sports_scores_container directly rather than going
 * through LayoutManager's Front-Page-specific section machinery, since that
 * machinery is tightly coupled to ArticleItem/search/overflow-queue
 * concerns that don't apply to scores.
 */
public class SportsScoresController : GLib.Object {
    // Fast cadence while at least one fetched game is actually in progress.
    // Otherwise, scale the wait to how far off the *next* scheduled game
    // actually is - a game a month out doesn't need re-checking every few
    // minutes, but one kicking off in the next few minutes should still be
    // caught promptly so it flips over to live-cadence polling on time.
    private const int LIVE_POLL_SECONDS = 45;
    private const int SOON_THRESHOLD_SECONDS = 300;   // next game starts within 5 min
    private const int SOON_POLL_SECONDS = 45;
    private const int UPCOMING_THRESHOLD_SECONDS = 1800; // next game starts within 30 min
    private const int UPCOMING_POLL_SECONDS = 300;
    private const int FAR_OUT_POLL_SECONDS = 1800; // next game is >30 min out, or nothing scheduled

    private static uint timeout_id = 0;
    private static weak NewsWindow? active_window = null;
    // Captured in load(), which always runs right after the fetch_news()
    // call that mints it (see appWindow.vala) - reusing that same
    // FetchContext, rather than a separate ad hoc guard, means Sports
    // Scores is arbitrated by the exact same "who owns the shared
    // containers right now" mechanism as the news pipeline, Podcasts, and
    // search (see FetchContext.still_owns_view()).
    private static FetchContext? active_ctx = null;

    // Last successfully fetched games per league, served on a transient
    // per-poll failure so a section doesn't flicker away just because one
    // refresh tick had a bad request.
    //
    // Lazily constructed (rather than a field initializer) because this
    // class is only ever used as a static namespace - never instantiated -
    // so its class_init, which is where Vala would run a field initializer,
    // never fires; a field initializer here left this null at first use in
    // manual testing (mirrors the exact issue HttpClientUtils.ensure_initialized()
    // works around for its own singleton).
    private static Gee.HashMap<string, Gee.ArrayList<GameScore>>? _last_good = null;
    private static Gee.HashMap<string, Gee.ArrayList<GameScore>> last_good() {
        if (_last_good == null) _last_good = new Gee.HashMap<string, Gee.ArrayList<GameScore>>();
        return _last_good;
    }

    // The section/cards for each league are built once and reused across
    // polls (see render()'s comment for why) rather than rebuilt every
    // time. All lazily constructed for the same reason as last_good() above.
    private static Gee.HashMap<string, CategorySection>? _current_sections = null;
    private static Gee.HashMap<string, CategorySection> current_sections() {
        if (_current_sections == null) _current_sections = new Gee.HashMap<string, CategorySection>();
        return _current_sections;
    }
    private static Gee.HashMap<string, Gee.HashMap<string, ScoreCard>>? _current_cards = null;
    private static Gee.HashMap<string, Gee.HashMap<string, ScoreCard>> current_cards() {
        if (_current_cards == null) _current_cards = new Gee.HashMap<string, Gee.HashMap<string, ScoreCard>>();
        return _current_cards;
    }
    // Which leagues were actually shown (had >=1 game), in the order they
    // were rendered - used to detect a league appearing/disappearing/being
    // reordered, which still needs a full rebuild.
    private static Gee.ArrayList<string>? _last_rendered_order = null;
    private static Gee.ArrayList<string> last_rendered_order() {
        if (_last_rendered_order == null) _last_rendered_order = new Gee.ArrayList<string>();
        return _last_rendered_order;
    }

    // Which league's score-card row is currently shown; null until the
    // first render(), which picks a default (see render()'s doc comment).
    private static string? selected_league = null;
    // Guards against reconnecting to league_badge_carousel.badge_selected
    // on every rebuild() - see the connect() call site below.
    private static bool badge_carousel_connected = false;

    // Below this many leagues chosen in Preferences, looping/scrolling the
    // carousel has nothing to scroll to - it switches to a static carousel
    // (see LeagueBadgeCarousel.rebuild()) with a trailing badge inviting the
    // user to enable more leagues, instead of the normal looping one.
    private const int MIN_LEAGUES_FOR_LOOPING_CAROUSEL = 4;
    // Tracks the last static/looping mode actually built, so a change in
    // how many leagues are *chosen* (not just which are active today)
    // still forces a rebuild even if the active league set didn't change.
    private static bool last_static_mode = false;
    private static bool settings_badge_connected = false;

    // "My Teams" (favorited individual teams, see fetch_and_populate_favorite_teams())
    // polls independently of the league sections above - own timer, own
    // last-good cache, own built-once/updated-in-place sections, keyed by
    // "league_key|team_id" rather than a bare league key. Kept decoupled
    // from the league polling/rebuild logic above rather than merged into
    // it, to avoid risking regressions in that already-tuned cadence.
    private static uint favorite_teams_timeout_id = 0;
    private static Gee.HashMap<string, Gee.ArrayList<GameScore>>? _favorite_teams_last_good = null;
    private static Gee.HashMap<string, Gee.ArrayList<GameScore>> favorite_teams_last_good() {
        if (_favorite_teams_last_good == null) _favorite_teams_last_good = new Gee.HashMap<string, Gee.ArrayList<GameScore>>();
        return _favorite_teams_last_good;
    }
    private static Gee.HashMap<string, CategorySection>? _favorite_team_sections = null;
    private static Gee.HashMap<string, CategorySection> favorite_team_sections() {
        if (_favorite_team_sections == null) _favorite_team_sections = new Gee.HashMap<string, CategorySection>();
        return _favorite_team_sections;
    }
    private static Gee.HashMap<string, Gee.HashMap<string, ScoreCard>>? _favorite_team_cards = null;
    private static Gee.HashMap<string, Gee.HashMap<string, ScoreCard>> favorite_team_cards() {
        if (_favorite_team_cards == null) _favorite_team_cards = new Gee.HashMap<string, Gee.HashMap<string, ScoreCard>>();
        return _favorite_team_cards;
    }
    private static Gee.ArrayList<string>? _last_rendered_favorite_teams = null;
    private static Gee.ArrayList<string> last_rendered_favorite_teams() {
        if (_last_rendered_favorite_teams == null) _last_rendered_favorite_teams = new Gee.ArrayList<string>();
        return _last_rendered_favorite_teams;
    }

    public static void load(NewsWindow win) {
        if (!win.prefs.sports_scores_enabled) {
            stop_polling();
            hide(win);
            return;
        }

        active_window = win;
        active_ctx = FetchContext.current_context();
        fetch_and_populate(win);
        fetch_and_populate_favorite_teams(win);
    }

    public static void stop_polling() {
        ViewSession.remove_source(ref timeout_id);
        ViewSession.remove_source(ref favorite_teams_timeout_id);
    }

    // Drop the reused sections/cards - called on window close so this
    // static state doesn't hold a stray reference to a torn-down window's
    // widgets. Navigating away from Sports (hide()) deliberately does NOT
    // call this: keeping the built sections around is exactly the point
    // (see render()'s comment), so coming back to Sports shows the
    // last-known scores immediately instead of an empty container until
    // the next poll.
    public static void reset() {
        current_sections().clear();
        current_cards().clear();
        last_rendered_order().clear();
        selected_league = null;

        favorite_team_sections().clear();
        favorite_team_cards().clear();
        last_rendered_favorite_teams().clear();
    }

    // Called when navigating away from Sports: render() only ever runs
    // while still on the Sports category, so without this the container
    // stays visible with its last-rendered score sections showing
    // underneath every other category's content.
    public static void hide(NewsWindow win) {
        if (win.content_view == null || win.content_view.sports_scores_container == null) return;
        win.content_view.sports_scores_container.set_visible(false);
        if (win.content_view.favorite_teams_container != null) win.content_view.favorite_teams_container.set_visible(false);
        if (win.content_view.favorite_teams_label != null) win.content_view.favorite_teams_label.set_visible(false);
        if (win.content_view.favorite_teams_separator != null) win.content_view.favorite_teams_separator.set_visible(false);
        if (win.content_view.league_badge_carousel != null) win.content_view.league_badge_carousel.root.set_visible(false);
        if (win.content_view.hero_scores_separator != null) win.content_view.hero_scores_separator.set_visible(false);
        if (win.content_view.scores_articles_separator != null) win.content_view.scores_articles_separator.set_visible(false);
    }

    // Re-schedules itself (rather than a single recurring GLib.Timeout) so
    // the cadence can change poll-to-poll based on whether any game is
    // currently live. Always cancels any outstanding poll first, so calling
    // this repeatedly (e.g. load() firing again before the previous fetch's
    // callback lands) collapses down to one live timer instead of leaking.
    private static void schedule_next_poll(int seconds) {
        ViewSession.remove_source(ref timeout_id);
        if (active_ctx == null) return;
        timeout_id = active_ctx.session.timeout_seconds(seconds, () => {
            timeout_id = 0;
            if (active_window == null || active_ctx == null || !active_ctx.still_owns_view()) {
                return false;
            }
            fetch_and_populate(active_window);
            return false; // one-shot; fetch_and_populate reschedules once results are in
        });
    }

    // Any game live -> poll fast. Otherwise, look at the soonest scheduled
    // (not yet started) game across every league and scale the wait so we
    // re-check well before it's due to start, without polling constantly
    // for games that are still hours or weeks away.
    private static int next_poll_seconds(Gee.HashMap<string, Gee.ArrayList<GameScore>> results) {
        GLib.DateTime? soonest_start = null;
        foreach (var games_list in results.values) {
            foreach (var game in games_list) {
                if (game.status == GameStatus.LIVE) return LIVE_POLL_SECONDS;
                if (game.status == GameStatus.SCHEDULED && game.start_time != null) {
                    if (soonest_start == null || game.start_time.compare(soonest_start) < 0) {
                        soonest_start = game.start_time;
                    }
                }
            }
        }

        if (soonest_start == null) return FAR_OUT_POLL_SECONDS;

        int64 seconds_until = soonest_start.difference(new GLib.DateTime.now_utc()) / GLib.TimeSpan.SECOND;
        if (seconds_until <= SOON_THRESHOLD_SECONDS) return SOON_POLL_SECONDS;
        if (seconds_until <= UPCOMING_THRESHOLD_SECONDS) return UPCOMING_POLL_SECONDS;
        return FAR_OUT_POLL_SECONDS;
    }

    private static void fetch_and_populate(NewsWindow win) {
        var all_league_keys = win.prefs.ordered_sports_league_keys();
        var league_keys = new Gee.ArrayList<string>();
        foreach (var key in all_league_keys) {
            if (win.prefs.sports_league_enabled(key)) league_keys.add(key);
        }
        var results = new Gee.HashMap<string, Gee.ArrayList<GameScore>>();
        int pending = league_keys.size;

        if (pending == 0) {
            render(win, league_keys, results);
            schedule_next_poll(FAR_OUT_POLL_SECONDS);
            return;
        }

        // One fetch_league call per league, each constructing its own
        // closure right here rather than going through a helper that fans
        // out internally - see the comment on SportsScoresService.fetch_league
        // for why (a use-after-free hit during manual testing otherwise).
        var ctx = active_ctx;
        foreach (var league_key in league_keys) {
            SportsScoresService.fetch_league(league_key, (returned_key, games) => {
                // The user may have navigated away (or started a search)
                // while this request was in flight; drop the result rather
                // than populate a hidden/stale/search-owned view.
                if (ctx == null || !ctx.still_owns_view()) return;

                if (games != null) {
                    last_good().set(returned_key, games);
                    results.set(returned_key, games);
                } else if (last_good().has_key(returned_key)) {
                    results.set(returned_key, last_good().get(returned_key));
                } else {
                    results.set(returned_key, new Gee.ArrayList<GameScore>());
                }

                pending--;
                if (pending <= 0) {
                    render(win, league_keys, results);
                    schedule_next_poll(next_poll_seconds(results));
                }
            });
        }
    }

    private static bool league_has_live_game(Gee.ArrayList<GameScore> games) {
        foreach (var game in games) {
            if (game.status == GameStatus.LIVE) return true;
        }
        return false;
    }

    private static bool string_lists_equal(Gee.ArrayList<string> a, Gee.ArrayList<string> b) {
        if (a.size != b.size) return false;
        for (int i = 0; i < a.size; i++) {
            if (a.get(i) != b.get(i)) return false;
        }
        return true;
    }

    // The update-in-place path assumes the sections it built last time are
    // still in `container` - if anything else has emptied it since, fall
    // back to a full rebuild rather than updating cards no longer on screen.
    private static bool sections_attached(Gee.HashMap<string, CategorySection> sections, Gtk.Widget container) {
        foreach (var section in sections.values) {
            if (section.wrapper.get_parent() != container) return false;
        }
        return true;
    }

    private static void render(NewsWindow win, Gee.ArrayList<string> league_keys, Gee.HashMap<string, Gee.ArrayList<GameScore>> results) {
        if (win.content_view == null || win.content_view.sports_scores_container == null) return;
        if (active_ctx == null || !active_ctx.still_owns_view()) return;

        var container = win.content_view.sports_scores_container;
        bool static_mode = league_keys.size < MIN_LEAGUES_FOR_LOOPING_CAROUSEL;

        var active_leagues = new Gee.ArrayList<string>();
        foreach (var league_key in league_keys) {
            var games = results.get(league_key);
            if (games != null && games.size > 0) active_leagues.add(league_key);
        }

        // A full rebuild is only actually needed when the set/order of
        // leagues shown, or a league's set of games, has changed (a game
        // started or finished, or the user reordered/toggled leagues) -
        // the common case (same games, just scores/status ticking) takes
        // the fast in-place update path below instead. Repeatedly
        // destroying/recreating a league's CategorySection (Overlay +
        // ScrolledWindow + EventControllerMotion, see ScrollNavButtons)
        // every poll was found to leak memory, a GTK4 quirk confirmed via
        // an isolated repro and unrelated to anything ScoreCard itself
        // draws or holds onto.
        bool needs_rebuild = !string_lists_equal(active_leagues, last_rendered_order()) || static_mode != last_static_mode
            || !sections_attached(current_sections(), container);
        if (!needs_rebuild) {
            foreach (var league_key in active_leagues) {
                var games = results.get(league_key);
                var cards_for_league = current_cards().get(league_key);
                if (cards_for_league == null || cards_for_league.size != games.size) {
                    needs_rebuild = true;
                    break;
                }
                foreach (var game in games) {
                    if (!cards_for_league.has_key(game.game_id)) {
                        needs_rebuild = true;
                        break;
                    }
                }
                if (needs_rebuild) break;
            }
        }

        if (needs_rebuild) {
            Gtk.Widget? child = container.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                container.remove(child);
                child = next;
            }
            current_sections().clear();
            current_cards().clear();

            foreach (var league_key in active_leagues) {
                var games = results.get(league_key);

                // Every league's own score-card row is still built and kept
                // updated (see the in-place branch below) even while hidden
                // - the badge carousel only toggles which one is visible
                // (see apply_selected_league()), so switching leagues is
                // instant with no re-render.
                var section = new CategorySection(win, SportsScoresService.display_name_for(league_key), "sports:" + league_key, true, true, SportsScoresService.logo_url_for(league_key), league_has_live_game(games));
                var cards_for_league = new Gee.HashMap<string, ScoreCard>();
                foreach (var game in games) {
                    var card = new ScoreCard(game);
                    section.add_card(card.root);
                    cards_for_league.set(game.game_id, card);
                }
                container.append(section.wrapper);
                current_sections().set(league_key, section);
                current_cards().set(league_key, cards_for_league);
            }

            win.content_view.league_badge_carousel.rebuild(active_leagues, static_mode);
            // The carousel itself is a permanent widget (never rebuilt) -
            // only connect its selection/settings signals once, not on
            // every rebuild(), or repeated league changes would stack up
            // duplicate handlers and fire selection multiple times.
            if (!badge_carousel_connected) {
                badge_carousel_connected = true;
                win.content_view.league_badge_carousel.badge_selected.connect((league_key) => {
                    selected_league = league_key;
                    apply_selected_league();
                });
            }
            if (!settings_badge_connected) {
                settings_badge_connected = true;
                GLib.debug("LeagueBadgeCarousel: connecting settings_requested handler");
                win.content_view.league_badge_carousel.settings_requested.connect(() => {
                    GLib.debug("SportsScoresController: settings_requested received, active_window=%p", active_window);
                    if (active_window != null) PrefsDialog.show_preferences_dialog(active_window, false, true);
                });
            }
            foreach (var league_key in active_leagues) {
                var games = results.get(league_key);
                win.content_view.league_badge_carousel.set_live(league_key, league_has_live_game(games));
            }

            last_rendered_order().clear();
            last_rendered_order().add_all(active_leagues);
            last_static_mode = static_mode;
        } else {
            foreach (var league_key in active_leagues) {
                var games = results.get(league_key);
                var cards_for_league = current_cards().get(league_key);
                foreach (var game in games) {
                    cards_for_league.get(game.game_id).update(game);
                }

                bool has_live = league_has_live_game(games);
                var section = current_sections().get(league_key);
                if (section != null && section.live_pill_widget != null) {
                    section.live_pill_widget.set_visible(has_live);
                }
                win.content_view.league_badge_carousel.set_live(league_key, has_live);
            }
        }

        // Default selection: first active league with a live game, else
        // the first in configured order - re-picked whenever the currently
        // selected league is gone (e.g. its games all ended and it dropped
        // out of active_leagues).
        if (selected_league == null || !active_leagues.contains(selected_league)) {
            string? default_league = null;
            foreach (var league_key in active_leagues) {
                var games = results.get(league_key);
                if (games != null && league_has_live_game(games)) {
                    default_league = league_key;
                    break;
                }
            }
            if (default_league == null && active_leagues.size > 0) default_league = active_leagues.get(0);
            selected_league = default_league;
        }
        apply_selected_league();

        bool any_section = active_leagues.size > 0;
        container.set_visible(any_section);
        if (win.content_view.league_badge_carousel != null) win.content_view.league_badge_carousel.root.set_visible(any_section);
        if (win.content_view.hero_scores_separator != null) win.content_view.hero_scores_separator.set_visible(any_section);
        if (win.content_view.scores_articles_separator != null) win.content_view.scores_articles_separator.set_visible(any_section);
    }

    // Shows only the selected league's score-card row/badge, hiding every
    // other already-built one - a pure visibility/state toggle over
    // existing widgets, safe to call from a badge click as well as render().
    // Uses active_window rather than a parameter since the badge click
    // closure (connected once, outside any single render() call) has no
    // NewsWindow of its own to pass in.
    private static void apply_selected_league() {
        foreach (var entry in current_sections().entries) {
            entry.value.wrapper.set_visible(entry.key == selected_league);
        }
        if (active_window != null && active_window.content_view != null && active_window.content_view.league_badge_carousel != null) {
            var carousel = active_window.content_view.league_badge_carousel;
            foreach (var league_key in current_sections().keys) {
                carousel.set_selected(league_key, league_key == selected_league);
            }
        }
    }

    private static string favorite_team_key(string league_key, string team_id) {
        return "%s|%s".printf(league_key, team_id);
    }

    private static void schedule_next_favorite_teams_poll(int seconds) {
        ViewSession.remove_source(ref favorite_teams_timeout_id);
        if (active_ctx == null) return;
        favorite_teams_timeout_id = active_ctx.session.timeout_seconds(seconds, () => {
            favorite_teams_timeout_id = 0;
            if (active_window == null || active_ctx == null || !active_ctx.still_owns_view()) {
                return false;
            }
            fetch_and_populate_favorite_teams(active_window);
            return false;
        });
    }

    // "My Teams" - independent of the league badge/selection above, always
    // shown when there's at least one favorited team (see NewsPreferences.
    // favorite_teams()). Same fetch/aggregate/render-once shape as
    // fetch_and_populate(), just keyed by "league_key|team_id" instead of a
    // bare league key.
    private static void fetch_and_populate_favorite_teams(NewsWindow win) {
        var favorites = win.prefs.favorite_teams();
        var results = new Gee.HashMap<string, Gee.ArrayList<GameScore>>();
        int pending = favorites.size;

        if (pending == 0) {
            render_favorite_teams(win, favorites, results);
            schedule_next_favorite_teams_poll(FAR_OUT_POLL_SECONDS);
            return;
        }

        var ctx = active_ctx;
        foreach (var fav in favorites) {
            string key = favorite_team_key(fav.league_key, fav.team_id);
            SportsScoresService.fetch_team_schedule(fav.league_key, fav.team_id, (league_key, team_id, games) => {
                if (ctx == null || !ctx.still_owns_view()) return;

                if (games != null) {
                    favorite_teams_last_good().set(key, games);
                    results.set(key, games);
                } else if (favorite_teams_last_good().has_key(key)) {
                    results.set(key, favorite_teams_last_good().get(key));
                } else {
                    results.set(key, new Gee.ArrayList<GameScore>());
                }

                pending--;
                if (pending <= 0) {
                    render_favorite_teams(win, favorites, results);
                    schedule_next_favorite_teams_poll(next_poll_seconds(results));
                }
            });
        }
    }

    // Picks out the favorited team's own display name/logo from whichever
    // side of a game matches its team_id - a team's schedule response has
    // no separate "this is you" field, but every game in it has the
    // favorited team on one side or the other.
    private static void apply_favorite_team_identity(GameScore game, string team_id, ref string? display_name, ref string? logo_url) {
        if (display_name != null) return;
        if (game.home_team_id == team_id) {
            display_name = game.home_team;
            logo_url = game.home_logo_url;
        } else if (game.away_team_id == team_id) {
            display_name = game.away_team;
            logo_url = game.away_logo_url;
        }
    }

    private static void render_favorite_teams(NewsWindow win, Gee.ArrayList<FavoriteTeamRef> favorites, Gee.HashMap<string, Gee.ArrayList<GameScore>> results) {
        if (win.content_view == null || win.content_view.favorite_teams_container == null) return;
        if (active_ctx == null || !active_ctx.still_owns_view()) return;

        var container = win.content_view.favorite_teams_container;

        // A team with no games at all (rare in-season, but possible) has no
        // way to resolve its own display name/logo from the schedule
        // response - skip it, same as a league with zero games not
        // rendering a section.
        var active_keys = new Gee.ArrayList<string>();
        foreach (var fav in favorites) {
            string key = favorite_team_key(fav.league_key, fav.team_id);
            var games = results.get(key);
            if (games != null && games.size > 0) active_keys.add(key);
        }

        bool needs_rebuild = !string_lists_equal(active_keys, last_rendered_favorite_teams())
            || !sections_attached(favorite_team_sections(), container);
        if (!needs_rebuild) {
            foreach (var key in active_keys) {
                var games = results.get(key);
                var cards_for_team = favorite_team_cards().get(key);
                if (cards_for_team == null || cards_for_team.size != games.size) {
                    needs_rebuild = true;
                    break;
                }
                foreach (var game in games) {
                    if (!cards_for_team.has_key(game.game_id)) {
                        needs_rebuild = true;
                        break;
                    }
                }
                if (needs_rebuild) break;
            }
        }

        if (needs_rebuild) {
            Gtk.Widget? child = container.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                container.remove(child);
                child = next;
            }
            favorite_team_sections().clear();
            favorite_team_cards().clear();

            foreach (var fav in favorites) {
                string key = favorite_team_key(fav.league_key, fav.team_id);
                if (!active_keys.contains(key)) continue;
                var games = results.get(key);

                string? display_name = null;
                string? logo_url = null;
                foreach (var game in games) {
                    apply_favorite_team_identity(game, fav.team_id, ref display_name, ref logo_url);
                    if (display_name != null) break;
                }
                if (display_name == null) continue;

                var section = new CategorySection(win, display_name, "sports-team:" + key, true, true, logo_url, league_has_live_game(games));
                var cards_for_team = new Gee.HashMap<string, ScoreCard>();
                foreach (var game in games) {
                    var card = new ScoreCard(game);
                    section.add_card(card.root);
                    cards_for_team.set(game.game_id, card);
                }
                container.append(section.wrapper);
                favorite_team_sections().set(key, section);
                favorite_team_cards().set(key, cards_for_team);
            }

            last_rendered_favorite_teams().clear();
            last_rendered_favorite_teams().add_all(active_keys);
        } else {
            foreach (var key in active_keys) {
                var games = results.get(key);
                var cards_for_team = favorite_team_cards().get(key);
                foreach (var game in games) {
                    cards_for_team.get(game.game_id).update(game);
                }

                var section = favorite_team_sections().get(key);
                if (section != null && section.live_pill_widget != null) {
                    section.live_pill_widget.set_visible(league_has_live_game(games));
                }
            }
        }

        bool any_section = active_keys.size > 0;
        container.set_visible(any_section);
        if (win.content_view.favorite_teams_label != null) win.content_view.favorite_teams_label.set_visible(any_section);
        if (win.content_view.favorite_teams_separator != null) win.content_view.favorite_teams_separator.set_visible(any_section);
    }
}
