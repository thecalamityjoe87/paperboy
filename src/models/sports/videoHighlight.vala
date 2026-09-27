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

/**
 * One ESPN video clip from a league's news feed. `stream_url` is filled in
 * by SportsScoresService.resolve_highlight_stream(), since the feed itself
 * only links to a per-clip detail endpoint.
 */
public class VideoHighlight : GLib.Object {
    public string clip_id;
    public string league_key;
    public string headline;
    public string? description;
    public string? thumbnail_url;
    public string? web_url;
    public GLib.DateTime? published;
    public Gee.ArrayList<string> team_ids;

    public string? stream_url;
    public int duration_seconds;

    public VideoHighlight(string clip_id, string league_key, string headline) {
        this.clip_id = clip_id;
        this.league_key = league_key;
        this.headline = headline;
        this.team_ids = new Gee.ArrayList<string>();
    }
}
