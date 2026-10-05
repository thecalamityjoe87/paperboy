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

public enum GameStatus {
    SCHEDULED,
    LIVE,
    FINAL
}

/**
 * One game/event from ESPN's scoreboard API, sibling to ArticleItem - not an
 * extension of it, since scores have no home in that flat title/url/thumbnail
 * shape.
 */
public class GameScore : GLib.Object {
    public string league;              // e.g. "nfl", "nba", "mlb", "nhl"
    public string league_display_name; // e.g. "NFL"
    public string game_id;
    public string home_team;
    public string away_team;
    public string home_team_abbr;
    public string away_team_abbr;
    public string home_score;
    public string away_score;
    public string? home_logo_url;
    public string? away_logo_url;
    // ESPN's numeric team id (null for MMA, which has athletes, not teams) -
    // lets a favorited-team row (see SportsScoresController) identify which
    // side is "my" team without string-matching on display name.
    public string? home_team_id;
    public string? away_team_id;
    public GameStatus status;
    public string status_detail; // e.g. "Q3 7:42", "FINAL", "7:00 PM"
    public GLib.DateTime? start_time;
    public bool time_valid;  // false when ESPN has a date but no kickoff time yet ("TBD")
    public bool no_result;   // finished without being played (postponed, canceled)
    public string espn_link;
    // Golf/racing: the leaders of a whole-field event, in place of the
    // home/away sides (left empty). null for head-to-head games.
    public Gee.ArrayList<FieldEntry>? field;
    public string event_name; // tournament or race name, e.g. "China Open"; "" for team sports
    public string round_name; // e.g. "Semifinal" (tennis), "Qual" (F1); "" when ESPN gives none

    public GameScore(string league, string league_display_name, string game_id) {
        this.league = league;
        this.league_display_name = league_display_name;
        this.game_id = game_id;
        this.home_team = "";
        this.away_team = "";
        this.home_team_abbr = "";
        this.away_team_abbr = "";
        this.home_score = "";
        this.away_score = "";
        this.status = GameStatus.SCHEDULED;
        this.status_detail = "";
        this.time_valid = true;
        this.no_result = false;
        this.espn_link = "";
        this.field = null;
        this.event_name = "";
        this.round_name = "";
    }
}

// One placed athlete in a field event (see GameScore.field).
public class FieldEntry : GLib.Object {
    public string name;
    public string short_name;
    public string position; // "1", "T4" when tied on score
    public string score;    // golf's to-par ("-12", "E"); "" for racing
    public string? flag_url;

    public FieldEntry(string name, string short_name, string position, string score, string? flag_url) {
        this.name = name;
        this.short_name = short_name;
        this.position = position;
        this.score = score;
        this.flag_url = flag_url;
    }
}
