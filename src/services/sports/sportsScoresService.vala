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
    public delegate void TeamsResultCallback(string league_key, Gee.ArrayList<TeamInfo>? teams);
    public delegate void TeamScheduleCallback(string league_key, string team_id, Gee.ArrayList<GameScore>? games);
    public delegate void HighlightsResultCallback(string league_key, Gee.ArrayList<VideoHighlight>? highlights);
    public delegate void HighlightStreamCallback(VideoHighlight highlight, bool ok);

    // One entry from a league's /teams listing - used only by the
    // Preferences "Favorite Teams" picker, not the score cards themselves.
    public class TeamInfo : GLib.Object {
        public string id;
        public string display_name;
        public string abbreviation;
        public string? logo_url;

        public TeamInfo(string id, string display_name, string abbreviation, string? logo_url) {
            this.id = id;
            this.display_name = display_name;
            this.abbreviation = abbreviation;
            this.logo_url = logo_url;
        }
    }

    // (sport_path, league_path, display_name, key, extra_query, logo_url) -
    // add a row here to support another league; nothing else needs to
    // change. extra_query is appended as-is (e.g. "groups=80") when
    // non-null/empty. logo_url is the "full"/"default" logo href each
    // league's own /scoreboard response reports under its top-level
    // "leagues" entry - hardcoded here (rather than read from that response)
    // so preference/onboarding UI can show a league's logo without having
    // to fetch its scoreboard first; verified against the live endpoint
    // when added, but ESPN's API is undocumented and could change the path.
    private struct League {
        public string sport_path;
        public string league_path;
        public string display_name;
        public string key;
        public string? extra_query;
        public string logo_url;
        // Solid background color for this league's badge in the Sports
        // carousel (see LeagueBadge) - no official-brand-accurate palette,
        // just a distinct, readable color per league.
        public string badge_color;
        // Where the league is on by default: comma-separated country codes
        // ("DE,AT,CH") or edition prefixes ("US:es" for US Spanish), matched
        // against the news edition (GoogleNewsUtils). null means on
        // everywhere, "" off everywhere. Users can switch any league on or
        // off regardless.
        public string? home_editions;
        // Preferences heading the league is listed under: "intl", "europe",
        // "us", "latam" or "asia" (see SportsPrefsGroup).
        public string region;
    }

    private static League[] get_leagues() {
        return {
            { "football", "nfl", "NFL", "nfl", null, "https://a.espncdn.com/i/teamlogos/leagues/500/nfl.png", "#6b4e3e", null, "us" },
            { "basketball", "nba", "NBA", "nba", null, "https://a.espncdn.com/i/teamlogos/leagues/500/nba.png", "#894eef", null, "us" },
            { "baseball", "mlb", "MLB", "mlb", null, "https://a.espncdn.com/i/teamlogos/leagues/500/mlb.png", "#3460dc", null, "us" },
            { "hockey", "nhl", "NHL", "nhl", null, "https://a.espncdn.com/i/teamlogos/leagues/500/nhl.png", "#353e4b", null, "us" },
            // ESPN has no single catch-all league per sport for these four -
            // each picks one representative competition. Off-season for
            // that competition just means the section doesn't appear that
            // day, same as NHL/MLB already do outside their seasons.
            { "soccer", "eng.1", "Premier League", "epl", null, "https://a.espncdn.com/i/leaguelogos/soccer/500/23.png", "#7f50b1", null, "europe" },
            { "soccer", "usa.1", "MLS", "mls", null, "https://a.espncdn.com/i/leaguelogos/soccer/500/19.png", "#1d8668", null, "us" },
            { "soccer", "uefa.champions", "Champions League", "ucl", null, "https://a.espncdn.com/i/leaguelogos/soccer/500/2.png", "#263f73", null, "europe" },
            { "rugby", "270557", "Rugby (URC)", "rugby", null, "https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/ESPN-icon-rugby.png", "#2d7448", null, "europe" },
            { "cricket", "8048", "Cricket (IPL)", "cricket", null, "https://a.espncdn.com/i/leaguelogos/cricket/500/8048.png", "#bc6422", null, "asia" },
            { "mma", "ufc", "UFC", "mma", null, "https://a.espncdn.com/i/teamlogos/leagues/500/ufc.png", "#6b0e0e", null, "intl" },
            // groups=80 restricts college football to FBS; without it the
            // scoreboard is flooded with FCS/D2 games most weeks.
            { "football", "college-football", "College Football", "cfb", "groups=80", "https://a.espncdn.com/redesign/assets/img/icons/ESPN-icon-football-college.png", "#962c4c", null, "us" },
            { "basketball", "mens-college-basketball", "Men's College Basketball", "mbb", null, "https://a.espncdn.com/redesign/assets/img/icons/ESPN-icon-basketball.png", "#a4482a", null, "us" },
            { "basketball", "womens-college-basketball", "Women's College Basketball", "wbb", null, "https://a.espncdn.com/redesign/assets/img/icons/ESPN-icon-basketball.png", "#ab33b7", null, "us" },
            { "baseball", "college-baseball", "College Baseball", "cbsb", null, "https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/ESPN-icon-baseball.png", "#1c78aa", null, "us" },
            // Regional leagues, on by default only where they're followed
            // (see home_editions) so other users don't get extra sections.
            { "soccer", "esp.1", "La Liga", "laliga", null, "https://a.espncdn.com/i/leaguelogos/soccer/500/15.png", "#c8102e", "ES", "europe" },
            { "soccer", "ger.1", "Bundesliga", "bundesliga", null, "https://a.espncdn.com/i/leaguelogos/soccer/500/10.png", "#b8141e", "DE,AT,CH", "europe" },
            { "soccer", "ita.1", "Serie A", "seriea", null, "https://a.espncdn.com/i/leaguelogos/soccer/500/12.png", "#1a4f9c", "IT,CH", "europe" },
            { "soccer", "fra.1", "Ligue 1", "ligue1", null, "https://a.espncdn.com/i/leaguelogos/soccer/500/9.png", "#16325c", "FR,BE,CH,MA,SN", "europe" },
            { "soccer", "ned.1", "Eredivisie", "eredivisie", null, "https://a.espncdn.com/i/leaguelogos/soccer/500/11.png", "#d4561a", "NL,BE", "europe" },
            { "soccer", "por.1", "Primeira Liga", "primeiraliga", null, "https://a.espncdn.com/i/leaguelogos/soccer/500/14.png", "#0b6e4f", "PT", "europe" },
            { "soccer", "tur.1", "Süper Lig", "superlig", null, "https://a.espncdn.com/i/leaguelogos/soccer/500/18.png", "#a3122a", "TR", "europe" },
            { "soccer", "uefa.europa", "Europa League", "uel", null, "https://a.espncdn.com/i/leaguelogos/soccer/500/2310.png", "#d15b00",
              "GB,IE,ES,FR,IT,DE,AT,CH,NL,BE,PT,SE,NO,FI,PL,CZ,SK,HU,RO,BG,GR,SI,RS,LT,LV,EE,UA,TR", "europe" },
            { "soccer", "mex.1", "Liga MX", "ligamx", null, "https://a.espncdn.com/i/leaguelogos/soccer/500/22.png", "#2c5f2d", "MX,US:es", "latam" },
            { "soccer", "bra.1", "Brasileirão", "brasileirao", null, "https://a.espncdn.com/i/leaguelogos/soccer/500/85.png", "#1f8a3c", "BR", "latam" },
            { "soccer", "arg.1", "Liga Profesional", "ligaprofesional", null, "https://a.espncdn.com/i/leaguelogos/soccer/500/1.png", "#3b7fc4", "AR", "latam" },
            { "soccer", "conmebol.libertadores", "Copa Libertadores", "libertadores", null, "https://a.espncdn.com/i/leaguelogos/soccer/500/58.png", "#8a6d1d", "BR,AR,CL,CO,PE,VE", "latam" },
            { "soccer", "jpn.1", "J.League", "jleague", null, "https://a.espncdn.com/i/leaguelogos/soccer/500/2199.png", "#d0021b", "JP", "asia" },
            { "soccer", "ksa.1", "Saudi Pro League", "saudipro", null, "https://a.espncdn.com/i/leaguelogos/soccer/500/2488.png", "#00704a", "SA,AE", "asia" },
            { "soccer", "aus.1", "A-League", "aleague", null, "https://a.espncdn.com/i/leaguelogos/soccer/500/1308.png", "#e35205", "AU,NZ", "asia" },
            { "rugby", "180659", "Six Nations", "sixnations", null, "https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/ESPN-icon-rugby.png", "#1b365d", "GB,IE,FR,IT", "europe" },
            // Individual sports, off by default everywhere. Golf and racing
            // are field events (a leaderboard, see GameScore.field); tennis
            // and PFL are head-to-head between athletes, like UFC.
            { "mma", "pfl", "PFL", "pfl", null, "https://a.espncdn.com/i/teamlogos/leagues/500/pfl.png", "#3d3d3d", "", "intl" },
            { "tennis", "atp", "ATP", "atp", null, "https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/ESPN-icon-tennis.png", "#2b5f8a", "", "intl" },
            { "tennis", "wta", "WTA", "wta", null, "https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/ESPN-icon-tennis.png", "#7a2e8c", "", "intl" },
            { "racing", "f1", "Formula 1", "f1", null, "https://a.espncdn.com/combiner/i?img=/i/teamlogos/leagues/500/f1.png", "#b3121d", "", "intl" },
            { "golf", "pga", "PGA Tour", "pga", null, "https://a.espncdn.com/combiner/i?img=/i/teamlogos/leagues/500/pgatour.png", "#16365c", "", "us" },
            { "golf", "lpga", "LPGA Tour", "lpga", null, "https://a.espncdn.com/combiner/i?img=/i/teamlogos/leagues/500/lpga.png", "#0e7c86", "", "us" },
            { "racing", "nascar-premier", "NASCAR Cup Series", "nascar", null, "https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/ESPN-icon-NASCAR.png", "#9a6b00", "", "us" },
            { "racing", "irl", "IndyCar", "indycar", null, "https://a.espncdn.com/combiner/i?img=/i/espn/teamlogos/500/indycar_series.png", "#24292f", "", "us" },
            { "golf", "eur", "DP World Tour", "dpworld", null, "https://a.espncdn.com/combiner/i?img=/i/espn/teamlogos/500/european_tour.png", "#3a2a6b", "", "europe" }
        };
    }

    public static Gee.ArrayList<string> league_keys() {
        var keys = new Gee.ArrayList<string>();
        foreach (var l in get_leagues()) keys.add(l.key);
        return keys;
    }

    // Whether the league is on when the user hasn't switched it on or off:
    // everywhere for leagues without home_editions, else only in those editions.
    public static bool enabled_by_default(string league_key) {
        foreach (var l in get_leagues()) {
            if (l.key == league_key) return l.home_editions == null || matches_edition(l.home_editions);
        }
        return false;
    }

    // A regional league followed in the user's news edition, e.g. La Liga in Spain.
    public static bool is_home_league(string league_key) {
        foreach (var l in get_leagues()) {
            if (l.key == league_key) return l.home_editions != null && matches_edition(l.home_editions);
        }
        return false;
    }

    private static bool matches_edition(string home_editions) {
        string country = GoogleNewsUtils.country();
        string ceid = GoogleNewsUtils.ceid();
        foreach (string token in home_editions.split(",")) {
            string t = token.strip();
            if (t.contains(":") ? ceid.has_prefix(t) : t == country) return true;
        }
        return false;
    }

    // Preferences heading code for the league, e.g. "europe".
    public static string region_for(string league_key) {
        foreach (var l in get_leagues()) {
            if (l.key == league_key) return l.region;
        }
        return "intl";
    }

    // ESPN's sport path for the league, e.g. "soccer" or "football".
    public static string sport_for(string league_key) {
        foreach (var l in get_leagues()) {
            if (l.key == league_key) return l.sport_path;
        }
        return "";
    }

    // Leagues of individual athletes (MMA, tennis, golf, racing) - no teams to follow.
    public static bool has_teams(string league_key) {
        string sport = sport_for(league_key);
        return sport != "mma" && sport != "tennis" && sport != "golf" && sport != "racing";
    }

    public static string display_name_for(string league_key) {
        foreach (var l in get_leagues()) {
            if (l.key == league_key) return l.display_name;
        }
        return league_key.up();
    }

    public static string? logo_url_for(string league_key) {
        foreach (var l in get_leagues()) {
            if (l.key == league_key) return l.logo_url;
        }
        return null;
    }

    public static string badge_color_for(string league_key) {
        foreach (var l in get_leagues()) {
            if (l.key == league_key) return l.badge_color;
        }
        return "#4b5563";
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

        string base_url = "https://site.api.espn.com/apis/site/v2/sports/%s/%s/scoreboard".printf(l.sport_path, l.league_path);
        string extra = (l.extra_query != null && l.extra_query.length > 0) ? l.extra_query : "";
        string url = extra.length > 0 ? "%s?%s".printf(base_url, extra) : base_url;

        fetch_json(url, l, (root) => {
            Gee.ArrayList<GameScore>? games = root != null ? parse_events(root, l.key, l.display_name) : null;
            // Tennis scoreboards list the whole tournament whatever the date, so the next day adds nothing.
            string? next_day = (games != null && l.sport_path != "tennis") ? next_scoreboard_day(root) : null;
            if (next_day == null) {
                callback(l.key, games);
                return;
            }

            // Daily scoreboards (everything but the weekly football ones) only cover one day; add the next.
            string next_url = "%s?dates=%s%s".printf(base_url, next_day, extra.length > 0 ? "&" + extra : "");
            fetch_json(next_url, l, (next_root) => {
                if (next_root != null) merge_games(games, parse_events(next_root, l.key, l.display_name));
                callback(l.key, games);
            });
        });
    }

    // "YYYYMMDD" for the day after a daily scoreboard's own "day", or null for weekly ones.
    private static string? next_scoreboard_day(Json.Node root) {
        if (root.get_node_type() != Json.NodeType.OBJECT) return null;
        var obj = root.get_object();
        if (!obj.has_member("day")) return null;
        var day_node = obj.get_member("day");
        if (day_node == null || day_node.get_node_type() != Json.NodeType.OBJECT) return null;
        string? date = json_get_string_safe(day_node.get_object(), "date");
        if (date == null) return null;
        var day = new GLib.DateTime.from_iso8601(date + "T00:00:00Z", null);
        if (day == null) return null;
        return day.add_days(1).format("%Y%m%d");
    }

    // Appends games not already present, then re-sorts.
    private static void merge_games(Gee.ArrayList<GameScore> games, Gee.ArrayList<GameScore> extra) {
        var seen = new Gee.HashSet<string>();
        foreach (var g in games) seen.add(g.game_id);
        foreach (var g in extra) {
            if (!seen.contains(g.game_id)) games.add(g);
        }
        sort_by_start_time(games);
    }

    private delegate void JsonCallback(Json.Node? root);

    private static void fetch_json(string url, League l, owned JsonCallback callback) {
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
            string? body = response.is_success() ? response.get_body_string() : null;
            if (body == null) {
                callback(null);
                return;
            }
            try {
                var parser = new Json.Parser();
                parser.load_from_data(body);
                callback(parser.get_root());
            } catch (GLib.Error e) {
                warning("SportsScoresService: JSON parse error for %s (%s): %s", l.key, url, e.message);
                callback(null);
            }
        });
    }

    private static bool find_league(string league_key, out League found_league) {
        found_league = {};
        foreach (var candidate in get_leagues()) {
            if (candidate.key == league_key) { found_league = candidate; return true; }
        }
        return false;
    }

    // Same curl-UA-spoofing/error-handling shape as fetch_league() above -
    // used only by the Preferences "Favorite Teams" picker (see
    // PrefsDialog), not by the score-card render path.
    public static void fetch_teams(string league_key, owned TeamsResultCallback callback) {
        League l;
        if (!find_league(league_key, out l)) {
            callback(league_key, null);
            return;
        }

        string url = "https://site.api.espn.com/apis/site/v2/sports/%s/%s/teams?limit=200".printf(l.sport_path, l.league_path);

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
                warning("SportsScoresService: JSON parse error fetching %s teams: %s", l.key, e.message);
                callback(l.key, null);
                return;
            }

            if (root == null) {
                callback(l.key, null);
                return;
            }

            callback(l.key, parse_teams(root));
        });
    }

    private static Gee.ArrayList<TeamInfo> parse_teams(Json.Node root) {
        var teams = new Gee.ArrayList<TeamInfo>();
        if (root.get_node_type() != Json.NodeType.OBJECT) return teams;
        var obj = root.get_object();
        if (!obj.has_member("sports")) return teams;

        var sports_node = obj.get_member("sports");
        if (sports_node == null || sports_node.get_node_type() != Json.NodeType.ARRAY) return teams;
        var sports = sports_node.get_array();
        if (sports.get_length() == 0) return teams;
        var sport_obj = sports.get_element(0);
        if (sport_obj.get_node_type() != Json.NodeType.OBJECT) return teams;
        if (!sport_obj.get_object().has_member("leagues")) return teams;

        var leagues_node = sport_obj.get_object().get_member("leagues");
        if (leagues_node == null || leagues_node.get_node_type() != Json.NodeType.ARRAY) return teams;
        var leagues = leagues_node.get_array();
        if (leagues.get_length() == 0) return teams;
        var league_obj = leagues.get_element(0);
        if (league_obj.get_node_type() != Json.NodeType.OBJECT) return teams;
        if (!league_obj.get_object().has_member("teams")) return teams;

        var team_entries_node = league_obj.get_object().get_member("teams");
        if (team_entries_node == null || team_entries_node.get_node_type() != Json.NodeType.ARRAY) return teams;
        var team_entries = team_entries_node.get_array();

        uint len = team_entries.get_length();
        for (uint i = 0; i < len; i++) {
            var entry = team_entries.get_element(i);
            if (entry.get_node_type() != Json.NodeType.OBJECT) continue;
            if (!entry.get_object().has_member("team")) continue;
            var team_node = entry.get_object().get_member("team");
            if (team_node == null || team_node.get_node_type() != Json.NodeType.OBJECT) continue;
            var team_obj = team_node.get_object();

            string? id = json_get_string_safe(team_obj, "id");
            if (id == null) continue;
            string? dn = json_get_string_safe(team_obj, "displayName");
            if (dn == null) dn = json_get_string_safe(team_obj, "name");
            string? abbr = json_get_string_safe(team_obj, "abbreviation");
            string? logo = null;

            if (team_obj.has_member("logos")) {
                var logos_node = team_obj.get_member("logos");
                if (logos_node != null && logos_node.get_node_type() == Json.NodeType.ARRAY) {
                    var logos = logos_node.get_array();
                    if (logos.get_length() > 0) {
                        var first_logo = logos.get_element(0);
                        if (first_logo.get_node_type() == Json.NodeType.OBJECT) {
                            logo = json_get_string_safe(first_logo.get_object(), "href");
                        }
                    }
                }
            }

            teams.add(new TeamInfo(id, dn ?? (abbr ?? id), abbr ?? "", logo));
        }
        return teams;
    }

    // A favorited team's own schedule (past + upcoming games), sorted oldest
    // first - ESPN returns soccer newest-first and everything else oldest-first.
    public static void fetch_team_schedule(string league_key, string team_id, owned TeamScheduleCallback callback) {
        League l;
        if (!find_league(league_key, out l)) {
            callback(league_key, team_id, null);
            return;
        }

        string url = "https://site.api.espn.com/apis/site/v2/sports/%s/%s/teams/%s/schedule".printf(l.sport_path, l.league_path, team_id);

        fetch_json(url, l, (root) => {
            Gee.ArrayList<GameScore>? games = root != null ? parse_events(root, l.key, l.display_name) : null;
            if (games == null || l.sport_path != "soccer") {
                callback(l.key, team_id, games);
                return;
            }

            // Soccer schedules only list played games; upcoming ones need fixture=true.
            fetch_json(url + "?fixture=true", l, (fixture_root) => {
                if (fixture_root != null) merge_games(games, parse_events(fixture_root, l.key, l.display_name));
                callback(l.key, team_id, games);
            });
        });
    }

    // Video clips from a league's news feed, newest first. Premium clips are skipped.
    public static void fetch_highlights(string league_key, owned HighlightsResultCallback callback) {
        League l;
        if (!find_league(league_key, out l)) {
            callback(league_key, null);
            return;
        }

        string url = "https://site.api.espn.com/apis/site/v2/sports/%s/%s/news?limit=50".printf(l.sport_path, l.league_path);
        fetch_json(url, l, (root) => {
            callback(l.key, root != null ? parse_highlights(root, l.key) : null);
        });
    }

    // Fills in stream_url (MP4, falling back to HLS) and duration from the clip's detail endpoint.
    public static void resolve_highlight_stream(VideoHighlight highlight, owned HighlightStreamCallback callback) {
        League l;
        if (!find_league(highlight.league_key, out l)) {
            callback(highlight, false);
            return;
        }

        string url = "https://content.core.api.espn.com/v1/video/clips/%s".printf(highlight.clip_id);
        fetch_json(url, l, (root) => {
            callback(highlight, root != null && apply_clip_detail(root, highlight));
        });
    }

    private static Gee.ArrayList<VideoHighlight> parse_highlights(Json.Node root, string league_key) {
        var highlights = new Gee.ArrayList<VideoHighlight>();
        if (root.get_node_type() != Json.NodeType.OBJECT) return highlights;
        var articles_node = root.get_object().get_member("articles");
        if (articles_node == null || articles_node.get_node_type() != Json.NodeType.ARRAY) return highlights;

        foreach (var node in articles_node.get_array().get_elements()) {
            if (node.get_node_type() != Json.NodeType.OBJECT) continue;
            var obj = node.get_object();
            if (json_get_string_safe(obj, "type") != "Media" || json_get_bool_safe(obj, "premium")) continue;

            string? id = json_get_id_safe(obj, "id");
            string? headline = json_get_string_safe(obj, "headline");
            if (id == null || headline == null) continue;

            var h = new VideoHighlight(id, league_key, headline);
            h.description = json_get_string_safe(obj, "description");
            string? published = json_get_string_safe(obj, "published");
            if (published != null) h.published = parse_espn_date(published);

            var images = obj.get_member("images");
            if (images != null && images.get_node_type() == Json.NodeType.ARRAY && images.get_array().get_length() > 0) {
                var first = images.get_array().get_element(0);
                if (first.get_node_type() == Json.NodeType.OBJECT) h.thumbnail_url = json_get_string_safe(first.get_object(), "url");
            }

            var links = obj.get_member("links");
            if (links != null && links.get_node_type() == Json.NodeType.OBJECT) {
                var web = links.get_object().get_member("web");
                if (web != null && web.get_node_type() == Json.NodeType.OBJECT) h.web_url = json_get_string_safe(web.get_object(), "href");
            }

            var categories = obj.get_member("categories");
            if (categories != null && categories.get_node_type() == Json.NodeType.ARRAY) {
                foreach (var cat in categories.get_array().get_elements()) {
                    if (cat.get_node_type() != Json.NodeType.OBJECT) continue;
                    if (json_get_string_safe(cat.get_object(), "type") != "team") continue;
                    string? team_id = json_get_id_safe(cat.get_object(), "teamId");
                    if (team_id != null) h.team_ids.add(team_id);
                }
            }

            highlights.add(h);
        }

        highlights.sort((a, b) => {
            if (a.published == null || b.published == null) {
                return (a.published == null ? 1 : 0) - (b.published == null ? 1 : 0);
            }
            return b.published.compare(a.published);
        });
        return highlights;
    }

    private static bool apply_clip_detail(Json.Node root, VideoHighlight highlight) {
        if (root.get_node_type() != Json.NodeType.OBJECT) return false;
        var videos = root.get_object().get_member("videos");
        if (videos == null || videos.get_node_type() != Json.NodeType.ARRAY || videos.get_array().get_length() == 0) return false;
        var video_node = videos.get_array().get_element(0);
        if (video_node.get_node_type() != Json.NodeType.OBJECT) return false;
        var video = video_node.get_object();

        var duration = video.get_member("duration");
        if (duration != null && duration.get_node_type() == Json.NodeType.VALUE && duration.get_value_type() == typeof(int64)) {
            highlight.duration_seconds = (int) duration.get_int();
        }

        var links = video.get_member("links");
        if (links == null || links.get_node_type() != Json.NodeType.OBJECT) return false;
        var source = links.get_object().get_member("source");
        if (source == null || source.get_node_type() != Json.NodeType.OBJECT) return false;
        var source_obj = source.get_object();

        // MP4 first: neither Gtk.Video nor WebKit plays ESPN's HLS playlists here.
        highlight.stream_url = json_get_string_safe(source_obj, "href");
        if (highlight.stream_url == null) {
            var hls = source_obj.get_member("HLS");
            if (hls != null && hls.get_node_type() == Json.NodeType.OBJECT) highlight.stream_url = json_get_string_safe(hls.get_object(), "href");
        }
        return highlight.stream_url != null;
    }

    private static void sort_by_start_time(Gee.ArrayList<GameScore> games) {
        games.sort((a, b) => {
            if (a.start_time == null || b.start_time == null) {
                return (a.start_time == null ? 1 : 0) - (b.start_time == null ? 1 : 0);
            }
            return a.start_time.compare(b.start_time);
        });
    }

    // Returns games sorted oldest first - ESPN's own order varies by league and endpoint.
    private static Gee.ArrayList<GameScore> parse_events(Json.Node root, string league_key, string league_display_name) {
        var games = new Gee.ArrayList<GameScore>();
        if (root.get_node_type() != Json.NodeType.OBJECT) return games;

        var obj = root.get_object();
        if (!obj.has_member("events")) return games;

        var events_node = obj.get_member("events");
        if (events_node == null || events_node.get_node_type() != Json.NodeType.ARRAY) return games;
        Json.Array events = events_node.get_array();
        uint len = events.get_length();
        for (uint i = 0; i < len; i++) {
            var ev = events.get_element(i);
            if (ev.get_node_type() != Json.NodeType.OBJECT) continue;
            parse_event(ev.get_object(), league_key, league_display_name, games);
        }
        sort_by_start_time(games);
        return games;
    }

    // ESPN lists every round of a tennis tournament, a few hundred matches,
    // whatever date is asked for - keep the main-draw singles from about the
    // last day to the next day and a half.
    private const int TENNIS_PAST_HOURS = 24;
    private const int TENNIS_FUTURE_HOURS = 36;
    // Athletes kept per golf/racing leaderboard (see GameScore.field).
    private const int FIELD_LEADERS = 3;

    // Most sports have exactly one competition per event (the game itself).
    // MMA is the exception - one "event" is a whole fight card, with each
    // individual bout as its own entry in "competitions", each carrying its
    // own status/date (bouts on a card start at different times) rather
    // than sharing the event-level ones. Looping every competition here and
    // falling back to the event-level date/status when a competition omits
    // them keeps the single-competition sports working unchanged. F1 is
    // similar (one competition per session), and tennis nests its matches
    // under "groupings", one per draw ("mens-singles", "womens-doubles"...).
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

        string sport = sport_for(league_key);
        bool field_event = sport == "golf" || sport == "racing";
        string event_name = json_get_string_safe(ev, "shortName") ?? (json_get_string_safe(ev, "name") ?? "");

        var comps = new Gee.ArrayList<Json.Object>();
        if (sport == "tennis") {
            // Singles only (doubles pairs come as a "roster", not an athlete),
            // and only this tour's draw - ATP and WTA both list joint events in full.
            string draw = league_key == "wta" ? "womens-singles" : "mens-singles";
            var groupings = json_get_array_safe(ev, "groupings");
            if (groupings == null) return;
            foreach (var g in groupings.get_elements()) {
                if (g.get_node_type() != Json.NodeType.OBJECT) continue;
                if (json_get_nested_string_safe(g.get_object(), "grouping", "slug") != draw) continue;
                add_objects(json_get_array_safe(g.get_object(), "competitions"), comps);
            }
        } else {
            add_objects(json_get_array_safe(ev, "competitions"), comps);
        }

        foreach (var comp_obj in comps) {
            string comp_id = json_get_string_safe(comp_obj, "id") ?? event_id;
            var game = new GameScore(league_key, league_display_name, comp_id);
            game.espn_link = event_link;

            string? date_str = json_get_string_safe(comp_obj, "date") ?? event_date_str;
            if (date_str != null) {
                game.start_time = parse_espn_date(date_str);
            }
            if (comp_obj.has_member("timeValid")) game.time_valid = json_get_bool_safe(comp_obj, "timeValid");

            var status_obj = comp_obj.has_member("status") ? comp_obj : ev;
            apply_status(status_obj, game);

            if (field_event || sport == "tennis") game.event_name = event_name;
            if (sport == "tennis") {
                game.round_name = json_get_nested_string_safe(comp_obj, "round", "displayName") ?? "";
                if (game.round_name.has_prefix("Qualifying") || !in_tennis_window(game)) continue;
            } else if (sport == "racing") {
                game.round_name = json_get_nested_string_safe(comp_obj, "type", "abbreviation") ?? "";
                if (game.round_name.has_prefix("FP")) continue; // F1 practice sessions
            }

            var competitors = json_get_array_safe(comp_obj, "competitors");
            if (field_event) {
                game.field = parse_field(competitors);
                // An upcoming event may not have its field posted yet; a finished one without a field wasn't held.
                if (game.field.size == 0 && game.status != GameStatus.SCHEDULED) continue;
                games.add(game);
                continue;
            }
            if (competitors == null) continue;

            uint clen = competitors.get_length();
            for (uint j = 0; j < clen; j++) {
                var c = competitors.get_element(j);
                if (c.get_node_type() != Json.NodeType.OBJECT) continue;
                apply_competitor(c.get_object(), game, (int) j, sport == "tennis");
            }

            if (game.home_team.length == 0 && game.away_team.length == 0) continue;
            games.add(game);
        }
    }

    private static void add_objects(Json.Array? array, Gee.ArrayList<Json.Object> objects) {
        if (array == null) return;
        foreach (var node in array.get_elements()) {
            if (node.get_node_type() == Json.NodeType.OBJECT) objects.add(node.get_object());
        }
    }

    private static bool in_tennis_window(GameScore game) {
        if (game.status == GameStatus.LIVE) return true;
        if (game.start_time == null) return false;
        int64 hours_from_now = game.start_time.difference(new GLib.DateTime.now_utc()) / GLib.TimeSpan.HOUR;
        return hours_from_now >= -TENNIS_PAST_HOURS && hours_from_now <= TENNIS_FUTURE_HOURS;
    }

    // The top FIELD_LEADERS of a golf/racing field. ESPN's "order" is the
    // current (or finishing) place; golfers level on score share it ("T4").
    private static Gee.ArrayList<FieldEntry> parse_field(Json.Array? competitors) {
        var leaders = new Gee.ArrayList<FieldEntry>();
        var ranked = new Gee.ArrayList<Json.Object>();
        add_objects(competitors, ranked);
        ranked.sort((a, b) => json_get_int_safe(a, "order", int.MAX) - json_get_int_safe(b, "order", int.MAX));

        var first_place_for = new Gee.HashMap<string, int>();
        var tied = new Gee.HashSet<string>();
        for (int i = 0; i < ranked.size; i++) {
            string? score = json_get_string_safe(ranked.get(i), "score");
            if (score == null || score.length == 0) continue;
            if (first_place_for.has_key(score)) tied.add(score);
            else first_place_for.set(score, i + 1);
        }

        foreach (var c_obj in ranked) {
            if (leaders.size >= FIELD_LEADERS) break;
            string name, short_name;
            string? flag;
            if (!read_athlete(c_obj, out name, out short_name, out flag)) continue;
            string score = json_get_string_safe(c_obj, "score") ?? "";
            string position = (leaders.size + 1).to_string();
            if (first_place_for.has_key(score)) {
                position = first_place_for.get(score).to_string();
                if (tied.contains(score)) position = "T" + position;
            }
            leaders.add(new FieldEntry(name, short_name, position, score, flag));
        }
        return leaders;
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
        game.no_result = state == "post" && type_obj.has_member("completed") && !json_get_bool_safe(type_obj, "completed");
        string? detail = json_get_string_safe(type_obj, "shortDetail");
        if (detail == null) detail = json_get_string_safe(type_obj, "detail");
        game.status_detail = detail ?? "";
    }

    // Team-based sports key competitors by "homeAway"/"team". MMA instead
    // gives each competitor "type":"athlete" and an "athlete" object with no
    // home/away concept - fall back to competitor order (first listed slots
    // into "away", second into "home", matching how ESPN lists them) and use
    // the fight result ("winner") in place of a numeric score. Tennis
    // athletes do have "homeAway", and set_scores gives their games per set.
    private static void apply_competitor(Json.Object c_obj, GameScore game, int index, bool set_scores = false) {
        string? home_away = json_get_string_safe(c_obj, "homeAway");
        string? competitor_type = json_get_string_safe(c_obj, "type");

        string name = "";
        string abbr = "";
        string? logo = null;
        string score = "";
        string? team_id = null;

        if (competitor_type == "athlete" && c_obj.has_member("athlete")) {
            read_athlete(c_obj, out name, out abbr, out logo);

            bool has_winner = c_obj.has_member("winner");
            bool winner = has_winner && json_get_bool_safe(c_obj, "winner");
            if (set_scores) {
                score = games_per_set(c_obj);
            } else if (game.status == GameStatus.FINAL && has_winner) {
                score = winner ? "W" : "L";
            }

            if (home_away == null) home_away = (index == 0) ? "away" : "home";
        } else {
            // Scoreboard gives "score" as a string; team schedules give an object with "displayValue".
            string? s = json_get_string_safe(c_obj, "score");
            if (s == null && c_obj.has_member("score")) {
                var score_node = c_obj.get_member("score");
                if (score_node != null && score_node.get_node_type() == Json.NodeType.OBJECT) {
                    s = json_get_string_safe(score_node.get_object(), "displayValue");
                }
            }
            score = s ?? "";
            if (c_obj.has_member("team")) {
                var team_node = c_obj.get_member("team");
                if (team_node != null && team_node.get_node_type() == Json.NodeType.OBJECT) {
                    var team_obj = team_node.get_object();
                    string? dn = json_get_string_safe(team_obj, "displayName");
                    if (dn == null) dn = json_get_string_safe(team_obj, "name");
                    name = dn ?? "";
                    abbr = json_get_string_safe(team_obj, "abbreviation") ?? "";
                    team_id = json_get_string_safe(team_obj, "id");

                    // The scoreboard endpoint gives a flat "logo" string;
                    // the teams/schedule endpoints instead give a "logos"
                    // array of variants (different sizes/backgrounds) with
                    // no flat field - fall back to its first entry so team
                    // logos still resolve regardless of which endpoint this
                    // competitor came from.
                    logo = json_get_string_safe(team_obj, "logo");
                    if (logo == null && team_obj.has_member("logos")) {
                        var logos_node = team_obj.get_member("logos");
                        if (logos_node != null && logos_node.get_node_type() == Json.NodeType.ARRAY) {
                            var logos = logos_node.get_array();
                            if (logos.get_length() > 0) {
                                var first_logo = logos.get_element(0);
                                if (first_logo.get_node_type() == Json.NodeType.OBJECT) {
                                    logo = json_get_string_safe(first_logo.get_object(), "href");
                                }
                            }
                        }
                    }
                }
            }
        }

        if (home_away == "home") {
            game.home_team = name;
            game.home_team_abbr = abbr;
            game.home_score = score;
            game.home_logo_url = logo;
            game.home_team_id = team_id;
        } else if (home_away == "away") {
            game.away_team = name;
            game.away_team_abbr = abbr;
            game.away_score = score;
            game.away_logo_url = logo;
            game.away_team_id = team_id;
        }
    }

    // A "type":"athlete" competitor's name, short name ("N. Djokovic") and country flag.
    private static bool read_athlete(Json.Object c_obj, out string name, out string short_name, out string? flag) {
        name = "";
        short_name = "";
        flag = null;
        if (!c_obj.has_member("athlete")) return false;
        var athlete_node = c_obj.get_member("athlete");
        if (athlete_node == null || athlete_node.get_node_type() != Json.NodeType.OBJECT) return false;
        var athlete_obj = athlete_node.get_object();
        name = json_get_string_safe(athlete_obj, "fullName") ?? "";
        short_name = json_get_string_safe(athlete_obj, "shortName") ?? name;
        flag = json_get_nested_string_safe(athlete_obj, "flag", "href");
        return name.length > 0;
    }

    // Tennis score as games won per set, e.g. "6 3 7".
    private static string games_per_set(Json.Object c_obj) {
        var sets = json_get_array_safe(c_obj, "linescores");
        if (sets == null) return "";
        string[] parts = {};
        foreach (var node in sets.get_elements()) {
            if (node.get_node_type() != Json.NodeType.OBJECT) continue;
            var value = node.get_object().get_member("value");
            if (value == null || value.get_node_type() != Json.NodeType.VALUE) continue;
            parts += ((int) value.get_double()).to_string();
        }
        return string.joinv(" ", parts);
    }

    // ESPN omits seconds ("2026-09-27T00:30Z"), which GLib's ISO 8601 parser rejects.
    private static GLib.DateTime? parse_espn_date(string date_str) {
        var dt = new GLib.DateTime.from_iso8601(date_str, null);
        if (dt != null) return dt;
        try {
            var no_seconds = new GLib.Regex("T(\\d{2}:\\d{2})(Z|[+-])");
            return new GLib.DateTime.from_iso8601(no_seconds.replace(date_str, -1, 0, "T\\1:00\\2"), null);
        } catch (GLib.RegexError e) {
            return null;
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

    private static int json_get_int_safe(Json.Object obj, string member, int fallback) {
        var node = obj.get_member(member);
        if (node == null || node.get_node_type() != Json.NodeType.VALUE || node.get_value_type() != typeof(int64)) return fallback;
        return (int) node.get_int();
    }

    private static Json.Array? json_get_array_safe(Json.Object obj, string member) {
        var node = obj.get_member(member);
        if (node == null || node.get_node_type() != Json.NodeType.ARRAY) return null;
        return node.get_array();
    }

    // obj[member][child] as a string, e.g. a competition's round name ("round", "displayName").
    private static string? json_get_nested_string_safe(Json.Object obj, string member, string child) {
        var node = obj.get_member(member);
        if (node == null || node.get_node_type() != Json.NodeType.OBJECT) return null;
        return json_get_string_safe(node.get_object(), child);
    }

    // ESPN ids come back as either JSON numbers or strings depending on the endpoint.
    private static string? json_get_id_safe(Json.Object obj, string member) {
        if (!obj.has_member(member)) return null;
        var node = obj.get_member(member);
        if (node == null || node.get_node_type() != Json.NodeType.VALUE) return null;
        if (node.get_value_type() == typeof(int64)) return node.get_int().to_string();
        if (node.get_value_type() == typeof(string)) return node.get_string();
        return null;
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
