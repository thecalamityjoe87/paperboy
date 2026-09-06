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
    public GameStatus status;
    public string status_detail; // e.g. "Q3 7:42", "FINAL", "7:00 PM"
    public GLib.DateTime? start_time;
    public string espn_link;

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
        this.espn_link = "";
    }
}
