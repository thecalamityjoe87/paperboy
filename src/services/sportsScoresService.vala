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

    // (sport_path, league_path, display_name, key) - add a row here to
    // support another league; nothing else needs to change.
    private struct League {
        public string sport_path;
        public string league_path;
        public string display_name;
        public string key;
    }

    private static League[] get_leagues() {
        return {
            { "football", "nfl", "NFL", "nfl" },
            { "basketball", "nba", "NBA", "nba" },
            { "baseball", "mlb", "MLB", "mlb" },
            { "hockey", "nhl", "NHL", "nhl" },
            // ESPN has no single catch-all league per sport for these four -
            // each picks one representative competition. Off-season for
            // that competition just means the section doesn't appear that
            // day, same as NHL/MLB already do outside their seasons.
            { "soccer", "eng.1", "Premier League", "epl" },
            { "rugby", "270557", "Rugby (URC)", "rugby" },
            { "cricket", "8048", "Cricket (IPL)", "cricket" },
            { "mma", "ufc", "UFC", "mma" }
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
            var game = parse_event(ev.get_object(), league_key, league_display_name);
            if (game != null) games.add(game);
        }
        return games;
    }

    private static GameScore? parse_event(Json.Object ev, string league_key, string league_display_name) {
        string game_id = json_get_string_safe(ev, "id") ?? "";
        var game = new GameScore(league_key, league_display_name, game_id);

        string? date_str = json_get_string_safe(ev, "date");
        if (date_str != null) {
            game.start_time = new GLib.DateTime.from_iso8601(date_str, null);
        }

        // Status
        if (ev.has_member("status")) {
            var status_node = ev.get_member("status");
            if (status_node != null && status_node.get_node_type() == Json.NodeType.OBJECT) {
                var status_obj = status_node.get_object();
                if (status_obj.has_member("type")) {
                    var type_node = status_obj.get_member("type");
                    if (type_node != null && type_node.get_node_type() == Json.NodeType.OBJECT) {
                        var type_obj = type_node.get_object();
                        string? state = json_get_string_safe(type_obj, "state");
                        game.status = state == "in" ? GameStatus.LIVE : (state == "post" ? GameStatus.FINAL : GameStatus.SCHEDULED);
                        string? detail = json_get_string_safe(type_obj, "shortDetail");
                        if (detail == null) detail = json_get_string_safe(type_obj, "detail");
                        game.status_detail = detail ?? "";
                    }
                }
            }
        }

        // ESPN game link
        if (ev.has_member("links")) {
            var links_node = ev.get_member("links");
            if (links_node != null && links_node.get_node_type() == Json.NodeType.ARRAY) {
                var links = links_node.get_array();
                if (links.get_length() > 0) {
                    var first = links.get_element(0);
                    if (first.get_node_type() == Json.NodeType.OBJECT) {
                        string? href = json_get_string_safe(first.get_object(), "href");
                        if (href != null) game.espn_link = href;
                    }
                }
            }
        }
        if (game.espn_link.length == 0) {
            game.espn_link = "https://www.espn.com/%s/game/_/gameId/%s".printf(league_key, game_id);
        }

        // Competitors (home/away teams + scores)
        if (!ev.has_member("competitions")) return null;
        var comps_node = ev.get_member("competitions");
        if (comps_node == null || comps_node.get_node_type() != Json.NodeType.ARRAY) return null;
        var comps = comps_node.get_array();
        if (comps.get_length() == 0) return null;

        var comp = comps.get_element(0);
        if (comp.get_node_type() != Json.NodeType.OBJECT) return null;
        var comp_obj = comp.get_object();
        if (!comp_obj.has_member("competitors")) return null;

        var competitors_node = comp_obj.get_member("competitors");
        if (competitors_node == null || competitors_node.get_node_type() != Json.NodeType.ARRAY) return null;
        var competitors = competitors_node.get_array();

        uint clen = competitors.get_length();
        for (uint i = 0; i < clen; i++) {
            var c = competitors.get_element(i);
            if (c.get_node_type() != Json.NodeType.OBJECT) continue;
            var c_obj = c.get_object();

            string? home_away = json_get_string_safe(c_obj, "homeAway");
            string? score = json_get_string_safe(c_obj, "score");
            string name = "";
            string abbr = "";
            string? logo = null;

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

            if (home_away == "home") {
                game.home_team = name;
                game.home_team_abbr = abbr;
                game.home_score = score ?? "";
                game.home_logo_url = logo;
            } else if (home_away == "away") {
                game.away_team = name;
                game.away_team_abbr = abbr;
                game.away_score = score ?? "";
                game.away_logo_url = logo;
            }
        }

        if (game.home_team.length == 0 && game.away_team.length == 0) return null;
        return game;
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
