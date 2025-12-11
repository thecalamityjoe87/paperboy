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

public class SourceUtils {
    // Get display name for a NewsSource
    public static string get_source_name(NewsSource source) {
        switch (source) {
            case NewsSource.GUARDIAN:
                return "The Guardian";
            case NewsSource.WALL_STREET_JOURNAL:
                return "Wall Street Journal";
            case NewsSource.BBC:
                return "BBC News";
            case NewsSource.REDDIT:
                return "Reddit";
            case NewsSource.NEW_YORK_TIMES:
                return "NY Times";
            case NewsSource.BLOOMBERG:
                return "Bloomberg";
            case NewsSource.REUTERS:
                return "Reuters";
            case NewsSource.NPR:
                return "NPR";
            case NewsSource.FOX:
                return "Fox News";
            case NewsSource.UNKNOWN:
                return "News";
            default:
                return "News";
        }
    }

    // Get icon file path for a NewsSource
    public static string? get_source_icon_path(NewsSource source) {
        string icon_filename;
        switch (source) {
            case NewsSource.GUARDIAN:
                icon_filename = "guardian-logo.png";
                break;
            case NewsSource.BBC:
                icon_filename = "bbc-logo.png";
                break;
            case NewsSource.REDDIT:
                icon_filename = "reddit-logo.png";
                break;
            case NewsSource.NEW_YORK_TIMES:
                icon_filename = "nytimes-logo.png";
                break;
            case NewsSource.BLOOMBERG:
                icon_filename = "bloomberg-logo.png";
                break;
            case NewsSource.REUTERS:
                icon_filename = "reuters-logo.png";
                break;
            case NewsSource.NPR:
                icon_filename = "npr-logo.png";
                break;
            case NewsSource.FOX:
                icon_filename = "foxnews-logo.png";
                break;
            case NewsSource.WALL_STREET_JOURNAL:
                icon_filename = "wsj-logo.png";
                break;
            case NewsSource.UNKNOWN:
                return null;
            default:
                return null;
        }

        // Try to find icon in data directory
        string icon_path = DataPathsUtils.find_data_file("icons/" + icon_filename);
        return icon_path;
    }

    // Infer source from a URL by checking known domain substrings
    public static NewsSource infer_source_from_url(string? url) {
        if (url == null || url.length == 0) return NewsSource.UNKNOWN;
        string low = url.down();
        if (low.index_of("guardian") >= 0 || low.index_of("theguardian") >= 0) return NewsSource.GUARDIAN;
        if (low.index_of("bbc.co") >= 0 || low.index_of("bbc.") >= 0) return NewsSource.BBC;
        if (low.index_of("reddit.com") >= 0 || low.index_of("redd.it") >= 0) return NewsSource.REDDIT;
        if (low.index_of("nytimes") >= 0 || low.index_of("nyti.ms") >= 0) return NewsSource.NEW_YORK_TIMES;
        if (low.index_of("wsj.com") >= 0 || low.index_of("dowjones") >= 0) return NewsSource.WALL_STREET_JOURNAL;
        if (low.index_of("bloomberg") >= 0) return NewsSource.BLOOMBERG;
        if (low.index_of("reuters") >= 0) return NewsSource.REUTERS;
        if (low.index_of("npr.org") >= 0) return NewsSource.NPR;
        if (low.index_of("foxnews") >= 0 || low.index_of("fox.com") >= 0) return NewsSource.FOX;
        // Unknown source - don't default to user preference to avoid incorrect branding
        return NewsSource.UNKNOWN;
    }
}
