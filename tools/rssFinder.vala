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


 // Tool to help find RSS feed links

using GLib;

public class RSSFinder : Object {
    public static void main(string[] args) {
        // Accept a search string passed on the command line, e.g.:
        // rssFinder "New York" or rssFinder --query "New York"
        if (args.length == 0) {
            stderr.printf("Usage: rssFinder \"search terms\"\n");
            stderr.printf("Or: rssFinder --query \"search terms\"\n");
            return;
        }

        string keyword = "";
        // Some runtimes include the program path as argv[0] (e.g. "./rssFinder").
        // If the first arg contains a '/', treat it as the program path and skip it.
        string[] effective_args;
        if (args.length > 0 && args[0].contains("/")) {
            effective_args = new string[args.length - 1];
            for (int k = 1; k < args.length; k++)
                effective_args[k - 1] = args[k];
        } else {
            effective_args = args;
        }

        // If user provided --query or -q, use the next value. Otherwise join all args.
        for (int i = 0; i < effective_args.length; i++) {
            if (effective_args[i] == "--query" || effective_args[i] == "-q") {
                if (i + 1 < effective_args.length) {
                    keyword = effective_args[i + 1];
                    break;
                }
            }
        }
        if (keyword == "") {
            // join positional args into a single search string
            StringBuilder sb = new StringBuilder();
            for (int j = 0; j < effective_args.length; j++) {
                if (j > 0) sb.append(" ");
                sb.append(effective_args[j]);
            }
            keyword = sb.str;
        }
        keyword = keyword.strip();
        string formatted = keyword.strip().down().replace(" ", "_");
        string url = "https://rss.feedspot.com/" + formatted + "_news_rss_feeds/?_src=search";
        stdout.printf("Fetching with curl: %s\n", url);
        try {
            string[] argv = {"curl", "-sL", url};
            string html;
            string err;
            int status = 0;
            Process.spawn_sync(null, argv, null, SpawnFlags.SEARCH_PATH, null, out html, out err, out status);
            if (status != 0) {
                stderr.printf("curl failed with status %d. Error: %s\n", status, err);
                return;
            }
            if (html == null || html.strip() == "") {
                stderr.printf("curl did not return any data.\n");
                return;
            }
            // Look for RSS/Atom links in the HTML (href containing 'rss' or 'feed')
            Regex regex = new Regex("href=\\\"(https?://[^\\\"]*(rss|feed)[^\\\"]*)\\\"");
            MatchInfo match;
            bool found = false;
            if (regex.match(html, 0, out match)) {
                do {
                    string rss_url = match.fetch(1);
                    if (!rss_url.contains("feedspot.com") &&
                        !rss_url.contains("twitter.com") &&
                        !rss_url.contains("instagram.com") &&
                        !rss_url.contains("pinterest.com") &&
                        !rss_url.contains("tumblr.com") &&
                        !rss_url.contains("linkedin.com")) {
                        stdout.printf("Found feed: %s\n", rss_url);
                        found = true;

                        // Ensure config directory exists and append this feed to local_feeds
                        try {
                            string config_dir = GLib.Environment.get_user_config_dir() + "/paperboy";
                            string file_path = config_dir + "/local_feeds";

                            // mkdir -p <config_dir>
                            string[] mkdir_argv = { "mkdir", "-p", config_dir };
                            string mk_out;
                            string mk_err;
                            int mk_status = 0;
                            Process.spawn_sync (null, mkdir_argv, null, SpawnFlags.SEARCH_PATH, null, out mk_out, out mk_err, out mk_status);

                            // Append the feed URL to the file
                            string[] write_argv = { "sh", "-c", "printf '%s\\n' \"$1\" >> '" + file_path + "'", "--", rss_url };
                            string write_out;
                            string write_err;
                            int write_status = 0;
                            Process.spawn_sync (null, write_argv, null, SpawnFlags.SEARCH_PATH, null, out write_out, out write_err, out write_status);
                            if (write_status != 0) {
                                stderr.printf("Warning: failed to write feed to %s: %s\n", file_path, write_err ?? "");
                            }
                        } catch (Error e) {
                            stderr.printf("Error saving feed: %s\n", e.message);
                        }

                        // Fetch the feed XML and look for image metadata
                        string[] feed_argv = {"curl", "-sL", rss_url};
                        string feed_xml;
                        string feed_err;
                        int feed_status = 0;
                        Process.spawn_sync(null, feed_argv, null, SpawnFlags.SEARCH_PATH, null, out feed_xml, out feed_err, out feed_status);
                        if (feed_status == 0 && feed_xml != null && feed_xml.strip() != "") {
                            // Look for <image> (RSS 2.0)
                            Regex img_regex = new Regex("<image>.*?<url>([^<]+)</url>.*?</image>", RegexCompileFlags.DOTALL);
                            MatchInfo img_match;
                            if (img_regex.match(feed_xml, 0, out img_match)) {
                                string img_url = img_match.fetch(1);
                                stdout.printf("  Image: %s\n", img_url);
                                continue;
                            }
                            // Look for <itunes:image href=\\\"...\\\"/>
                            img_regex = new Regex("<itunes:image[^>]*href=\\\"([^\\\"]+)\\\"", RegexCompileFlags.DOTALL);
                            if (img_regex.match(feed_xml, 0, out img_match)) {
                                string img_url = img_match.fetch(1);
                                stdout.printf("  iTunes Image: %s\n", img_url);
                                continue;
                            }
                            // Look for <media:thumbnail url=\\\"...\\\"/>
                            img_regex = new Regex("<media:thumbnail[^>]*url=\\\"([^\\\"]+)\\\"", RegexCompileFlags.DOTALL);
                            if (img_regex.match(feed_xml, 0, out img_match)) {
                                string img_url = img_match.fetch(1);
                                stdout.printf("  Media Thumbnail: %s\n", img_url);
                                continue;
                            }
                            // Look for <media:content url=\\\"...\\\"/>
                            img_regex = new Regex("<media:content[^>]*url=\\\"([^\\\"]+)\\\"", RegexCompileFlags.DOTALL);
                            if (img_regex.match(feed_xml, 0, out img_match)) {
                                string img_url = img_match.fetch(1);
                                stdout.printf("  Media Content: %s\n", img_url);
                                continue;
                            }
                            // Look for <logo> (Atom)
                            img_regex = new Regex("<logo>([^<]+)</logo>", RegexCompileFlags.DOTALL);
                            if (img_regex.match(feed_xml, 0, out img_match)) {
                                string img_url = img_match.fetch(1);
                                stdout.printf("  Atom Logo: %s\n", img_url);
                                continue;
                            }
                        }
                    }
                } while (match.next());
            }
            if (!found) {
                stdout.printf("No RSS/Atom feeds found for '%s'.\n", keyword);
            }
        } catch (Error e) {
            stderr.printf("Error running curl: %s\n", e.message);
        }
    }
}
