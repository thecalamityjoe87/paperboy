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

// Folds a show's categories into one of Apple Podcasts' top-level groups,
// so My Library's category rows read "Society & Culture" rather than
// splitting a library across "Society", "Culture", "Documentary", etc.
// Two inputs: PodcastIndex's {"<id>": "<name>"} map (via paperboyBackend),
// whose ids are laid out parent-first (Arts=1, then its subcategories 2-8,
// Business=9, ...), and a feed's own <itunes:category text="...">, which is
// already an Apple top-level name.
public class PodcastCategoryUtils : GLib.Object {
    // First PodcastIndex id of each top-level group, ascending - an id
    // belongs to the last entry whose start is <= it.
    private const int[] GROUP_STARTS = { 1, 9, 16, 20, 26, 28, 29, 36, 42, 53, 55, 58, 60, 67, 77, 86, 102, 103, 104, 108, 110, 112 };

    private static string group_for_start(int start) {
        switch (start) {
            case 1: return _("Arts");
            case 9: return _("Business");
            case 16: return _("Comedy");
            case 20: return _("Education");
            case 26: return _("Fiction");
            case 28: return _("History");
            case 29: return _("Health & Fitness");
            case 36: return _("Kids & Family");
            case 42: return _("Leisure");
            case 53: return _("Music");
            case 55: return _("News");
            case 58: return _("Government");
            case 60: return _("Religion & Spirituality");
            case 67: return _("Science");
            case 77: return _("Society & Culture");
            case 86: return _("Sports");
            case 102: return _("Technology");
            case 103: return _("True Crime");
            case 104: return _("TV & Film");
            // Climate/Weather - PodcastIndex-only, closest Apple group.
            case 108: return _("Science");
            // Tabletop/Role-Playing.
            case 110: return _("Leisure");
            // Cryptocurrency.
            case 112: return _("Business");
            default: return "";
        }
    }

    // Politics (59) sits next to Government in PodcastIndex's numbering,
    // but Apple files it under News.
    private const int POLITICS_ID = 59;

    public static string? from_podcastindex_id(int id) {
        if (id <= 0) return null;
        if (id == POLITICS_ID) return _("News");
        int match = -1;
        foreach (int start in GROUP_STARTS) {
            if (start > id) break;
            match = start;
        }
        if (match < 0) return null;
        string name = group_for_start(match);
        return name.length > 0 ? name : null;
    }

    // `categories` is the backend's {"55": "News", "9": "Business"} object -
    // the first member is the feed's primary category, so it decides.
    public static string? from_podcastindex_json(Json.Object categories) {
        foreach (string key in categories.get_members()) {
            string? group = from_podcastindex_id(int.parse(key));
            if (group != null) return group;
        }
        return null;
    }

    // <itunes:category text="..."> is already Apple's top-level name; only
    // the pre-2019 names it may still carry need folding into today's set.
    public static string? from_itunes(string? text) {
        if (text == null) return null;
        string t = text.strip();
        if (t.length == 0) return null;
        switch (t) {
            case "Games & Hobbies": return _("Leisure");
            case "Science & Medicine": return _("Science");
            case "Society and Culture": return _("Society & Culture");
            case "TV and Film": return _("TV & Film");
            default: return t;
        }
    }

    // "42m", "1h 5m" - the same compact units (and translation strings) as
    // the episode lists' durations, short enough for the Up Next play pill.
    public static string format_time_estimate(int64 seconds) {
        if (seconds <= 0) return "";
        int64 total_mins = (seconds + 30) / 60;
        if (total_mins < 1) total_mins = 1;
        int64 hrs = total_mins / 60;
        int64 mins = total_mins % 60;
        if (hrs > 0 && mins > 0) return _("%lldh %lldm").printf(hrs, mins);
        if (hrs > 0) return _("%lldh").printf(hrs);
        return _("%lldm").printf(mins);
    }
}
