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
 * Fetches and parses live scores from ESPN's free, unofficial, key-less
 * scoreboard API (site.api.espn.com). Undocumented and could change without
 * notice - acceptable for this project, but keep the URL-building and
 * parsing isolated here so a break is easy to track down and patch.
 */
public class SportsScoresService : GLib.Object {
    public delegate void LeagueResultCallback(string league_key, Gee.ArrayList<GameScore>? games);

    // (sport_path, league_path, display_name, key, extra_query) - add a row
    // here to support another league; nothing else needs to change.
    // extra_query is appended as-is (e.g. "groups=80") when non-null/empty.
    private struct League {
        public string sport_path;
        public string league_path;
        public string display_name;
        public string key;
        public string? extra_query;
    }

    private static League[] get_leagues() {
        return {
            { "football", "nfl", "NFL", "nfl", null },
            { "basketball", "nba", "NBA", "nba", null },
            { "baseball", "mlb", "MLB", "mlb", null },
            { "hockey", "nhl", "NHL", "nhl", null },
            // ESPN has no single catch-all league per sport for these four -
            // each picks one representative competition. Off-season for
            // that competition just means the section doesn't appear that
            // day, same as NHL/MLB already do outside their seasons.
            { "soccer", "eng.1", "Premier League", "epl", null },
            { "soccer", "usa.1", "MLS", "mls", null },
            { "soccer", "uefa.champions", "Champions League", "ucl", null },
            { "rugby", "270557", "Rugby (URC)", "rugby", null },
            { "cricket", "8048", "Cricket (IPL)", "cricket", null },
            { "mma", "ufc", "UFC", "mma", null },
            // groups=80 restricts college football to FBS; without it the
            // scoreboard is flooded with FCS/D2 games most weeks.
            { "football", "college-football", "College Football", "cfb", "groups=80" },
            { "basketball", "mens-college-basketball", "Men's College Basketball", "mbb", null },
            { "basketball", "womens-college-basketball", "Women's College Basketball", "wbb", null },
            { "baseball", "college-baseball", "College Baseball", "cbsb", null }
        };
    }

    public static Gee.ArrayList<string> league_keys() {
        var keys = new Gee.ArrayList<string>();
        foreach (var l in get_leagues()) keys.add(l.key);
        return keys;
    }

    public static string display_name_for(string league_key) {
        foreach (var l in get_leagues()) {
            if (l.key == league_key) return l.display_name;
        }
        return league_key.up();
    }

    // Fetches a single league's scoreboard. Callers wanting all leagues
    // should call this once per key from their own loop (see
    // SportsScoresController.fetch_and_populate) rather than have this
    // class fan out internally: each call's `callback` is `owned` because
    // it escapes into an async HTTP callback, and a single `owned` value
    // can only safely back one such escape - looping over multiple leagues
    // *inside* this method while forwarding the same borrowed callback into
    // each async call let the shared closure data get freed as soon as the
    // loop that launched the requests returned, before any response had
    // arrived (a real use-after-free hit during manual testing). Letting
    // the caller's own loop construct a fresh closure per league sidesteps
    // that entirely - each iteration's lambda is its own independently
    // ref-counted closure.
    public static void fetch_league(string league_key, owned LeagueResultCallback callback) {
        bool found = false;
        League l = {};
        foreach (var candidate in get_leagues()) {
            if (candidate.key == league_key) { l = candidate; found = true; break; }
        }
        if (!found) {
            callback(league_key, null);
            return;
        }

        string url = "https://site.api.espn.com/apis/site/v2/sports/%s/%s/scoreboard".printf(l.sport_path, l.league_path);
        if (l.extra_query != null && l.extra_query.length > 0) {
            url = "%s?%s".printf(url, l.extra_query);
        }

        // ESPN's unofficial API appears to block by User-Agent content
        // specifically, not by header shape or rate: confirmed by hand
        // (repeated, alternating curl calls against the live endpoint)
        // that both the app's default "paperboy/1.0" UA and a spoofed
        // Chrome UA get 403, while a plain "curl/x.y" - or literally any
        // -H/-A override carrying that exact string - gets 200 every time.
        // Match that shape rather than the app's normal browser-spoofing
        // User-Agent (used elsewhere for RSS/thumbnail fetches).
        var options = new Paperboy.HttpClientUtils.RequestOptions();
        options.user_agent = "curl/8.7.1";

        var client = Paperboy.HttpClientUtils.get_default();
        client.fetch_async(url, options, (response) => {
            if (!response.is_success()) {
                callback(l.key, null);
                return;
            }

            Json.Node? root = null;
            try {
                var parser = new Json.Parser();
                string? body = response.get_body_string();
                if (body == null) {
                    callback(l.key, null);
                    return;
                }
                parser.load_from_data(body);
                root = parser.get_root();
            } catch (GLib.Error e) {
                warning("SportsScoresService: JSON parse error for %s: %s", l.key, e.message);
                callback(l.key, null);
                return;
            }

            if (root == null) {
                callback(l.key, null);
                return;
            }

            try {
                var games = parse_events(root, l.key, l.display_name);
                callback(l.key, games);
            } catch (GLib.Error e) {
                warning("SportsScoresService: failed to parse %s scoreboard: %s", l.key, e.message);
                callback(l.key, null);
            }
        });
    }

    private static Gee.ArrayList<GameScore> parse_events(Json.Node root, string league_key, string league_display_name) throws GLib.Error {
        var games = new Gee.ArrayList<GameScore>();
        if (root.get_node_type() != Json.NodeType.OBJECT) return games;

        var obj = root.get_object();
        if (!obj.has_member("events")) return games;

        Json.Array events = obj.get_array_member("events");
        uint len = events.get_length();
        for (uint i = 0; i < len; i++) {
            var ev = events.get_element(i);
            if (ev.get_node_type() != Json.NodeType.OBJECT) continue;
            parse_event(ev.get_object(), league_key, league_display_name, games);
        }
        return games;
    }

    // Most sports have exactly one competition per event (the game itself).
    // MMA is the exception - one "event" is a whole fight card, with each
    // individual bout as its own entry in "competitions", each carrying its
    // own status/date (bouts on a card start at different times) rather
    // than sharing the event-level ones. Looping every competition here and
    // falling back to the event-level date/status when a competition omits
    // them keeps the single-competition sports working unchanged.
    private static void parse_event(Json.Object ev, string league_key, string league_display_name, Gee.ArrayList<GameScore> games) {
        string event_id = json_get_string_safe(ev, "id") ?? "";
        string? event_date_str = json_get_string_safe(ev, "date");
        string event_link = "";

        if (ev.has_member("links")) {
            var links_node = ev.get_member("links");
            if (links_node != null && links_node.get_node_type() == Json.NodeType.ARRAY) {
                var links = links_node.get_array();
                if (links.get_length() > 0) {
                    var first = links.get_element(0);
                    if (first.get_node_type() == Json.NodeType.OBJECT) {
                        string? href = json_get_string_safe(first.get_object(), "href");
                        if (href != null) event_link = href;
                    }
                }
            }
        }
        if (event_link.length == 0) {
            event_link = "https://www.espn.com/%s/game/_/gameId/%s".printf(league_key, event_id);
        }

        if (!ev.has_member("competitions")) return;
        var comps_node = ev.get_member("competitions");
        if (comps_node == null || comps_node.get_node_type() != Json.NodeType.ARRAY) return;
        var comps = comps_node.get_array();

        uint comp_count = comps.get_length();
        for (uint i = 0; i < comp_count; i++) {
            var comp = comps.get_element(i);
            if (comp.get_node_type() != Json.NodeType.OBJECT) continue;
            var comp_obj = comp.get_object();

            string comp_id = json_get_string_safe(comp_obj, "id") ?? event_id;
            var game = new GameScore(league_key, league_display_name, comp_id);
            game.espn_link = event_link;

            string? date_str = json_get_string_safe(comp_obj, "date") ?? event_date_str;
            if (date_str != null) {
                game.start_time = new GLib.DateTime.from_iso8601(date_str, null);
            }

            var status_obj = comp_obj.has_member("status") ? comp_obj : ev;
            apply_status(status_obj, game);

            if (!comp_obj.has_member("competitors")) continue;
            var competitors_node = comp_obj.get_member("competitors");
            if (competitors_node == null || competitors_node.get_node_type() != Json.NodeType.ARRAY) continue;
            var competitors = competitors_node.get_array();

            uint clen = competitors.get_length();
            for (uint j = 0; j < clen; j++) {
                var c = competitors.get_element(j);
                if (c.get_node_type() != Json.NodeType.OBJECT) continue;
                apply_competitor(c.get_object(), game, (int) j);
            }

            if (game.home_team.length == 0 && game.away_team.length == 0) continue;
            games.add(game);
        }
    }

    private static void apply_status(Json.Object obj, GameScore game) {
        if (!obj.has_member("status")) return;
        var status_node = obj.get_member("status");
        if (status_node == null || status_node.get_node_type() != Json.NodeType.OBJECT) return;
        var status_obj = status_node.get_object();
        if (!status_obj.has_member("type")) return;
        var type_node = status_obj.get_member("type");
        if (type_node == null || type_node.get_node_type() != Json.NodeType.OBJECT) return;
        var type_obj = type_node.get_object();
        string? state = json_get_string_safe(type_obj, "state");
        game.status = state == "in" ? GameStatus.LIVE : (state == "post" ? GameStatus.FINAL : GameStatus.SCHEDULED);
        string? detail = json_get_string_safe(type_obj, "shortDetail");
        if (detail == null) detail = json_get_string_safe(type_obj, "detail");
        game.status_detail = detail ?? "";
    }

    // Team-based sports key competitors by "homeAway"/"team". MMA instead
    // gives each competitor "type":"athlete" and an "athlete" object with no
    // home/away concept - fall back to competitor order (first listed slots
    // into "away", second into "home", matching how ESPN lists them) and use
    // the fight result ("winner") in place of a numeric score.
    private static void apply_competitor(Json.Object c_obj, GameScore game, int index) {
        string? home_away = json_get_string_safe(c_obj, "homeAway");
        string? competitor_type = json_get_string_safe(c_obj, "type");

        string name = "";
        string abbr = "";
        string? logo = null;
        string score = "";

        if (competitor_type == "athlete" && c_obj.has_member("athlete")) {
            var athlete_node = c_obj.get_member("athlete");
            if (athlete_node != null && athlete_node.get_node_type() == Json.NodeType.OBJECT) {
                var athlete_obj = athlete_node.get_object();
                name = json_get_string_safe(athlete_obj, "fullName") ?? "";
                abbr = json_get_string_safe(athlete_obj, "shortName") ?? name;
                if (athlete_obj.has_member("flag")) {
                    var flag_node = athlete_obj.get_member("flag");
                    if (flag_node != null && flag_node.get_node_type() == Json.NodeType.OBJECT) {
                        logo = json_get_string_safe(flag_node.get_object(), "href");
                    }
                }
            }

            bool has_winner = c_obj.has_member("winner");
            bool winner = has_winner && json_get_bool_safe(c_obj, "winner");
            if (game.status == GameStatus.FINAL && has_winner) {
                score = winner ? "W" : "L";
            }

            home_away = (index == 0) ? "away" : "home";
        } else {
            string? s = json_get_string_safe(c_obj, "score");
            score = s ?? "";
            if (c_obj.has_member("team")) {
                var team_node = c_obj.get_member("team");
                if (team_node != null && team_node.get_node_type() == Json.NodeType.OBJECT) {
                    var team_obj = team_node.get_object();
                    string? dn = json_get_string_safe(team_obj, "displayName");
                    if (dn == null) dn = json_get_string_safe(team_obj, "name");
                    name = dn ?? "";
                    abbr = json_get_string_safe(team_obj, "abbreviation") ?? "";
                    logo = json_get_string_safe(team_obj, "logo");
                }
            }
        }

        if (home_away == "home") {
            game.home_team = name;
            game.home_team_abbr = abbr;
            game.home_score = score;
            game.home_logo_url = logo;
        } else if (home_away == "away") {
            game.away_team = name;
            game.away_team_abbr = abbr;
            game.away_score = score;
            game.away_logo_url = logo;
        }
    }

    private static bool json_get_bool_safe(Json.Object obj, string member) {
        try {
            if (!obj.has_member(member)) return false;
            var node = obj.get_member(member);
            if (node == null || node.get_node_type() != Json.NodeType.VALUE) return false;
            return node.get_boolean();
        } catch (GLib.Error e) {
            return false;
        }
    }

    private static string? json_get_string_safe(Json.Object obj, string member) {
        try {
            if (!obj.has_member(member)) return null;
            var node = obj.get_member(member);
            if (node == null) return null;
            if (node.get_node_type() != Json.NodeType.VALUE) return null;
            try {
                return node.get_string();
            } catch (GLib.Error e) {
                return null;
            }
        } catch (GLib.Error e) {
            return null;
        }
    }
}
