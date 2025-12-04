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
using Soup;

public class RedditFetcher : BaseFetcher {
    public RedditFetcher(SetLabelFunc set_label_func, ClearItemsFunc clear_items_func, AddItemFunc add_item_func) {
        base(set_label_func, clear_items_func, add_item_func);
    }

    public override void fetch(string category, string search_query, Soup.Session session) {
        var client = Paperboy.HttpClient.get_default();
        string subreddit = "";
        string category_name = "";
        switch (category) {
            case "general":
                subreddit = "worldnews";
                category_name = "World News";
                break;
            case "us":
                subreddit = "news";
                category_name = "US News";
                break;
            case "technology":
                subreddit = "technology";
                category_name = "Technology";
                break;
            case "business":
                subreddit = "business";
                category_name = "Business";
                break;
            case "science":
                subreddit = "science";
                category_name = "Science";
                break;
            case "sports":
                subreddit = "sports";
                category_name = "Sports";
                break;
            case "health":
                subreddit = "health";
                category_name = "Health";
                break;
            case "entertainment":
                subreddit = "entertainment";
                category_name = "Entertainment";
                break;
            case "politics":
                subreddit = "politics";
                category_name = "Politics";
                break;
            case "lifestyle":
                subreddit = "lifestyle";
                category_name = "Lifestyle";
                break;
            default:
                subreddit = "worldnews";
                category_name = "World News";
                break;
        }
        string url = @"https://www.reddit.com/r/$(subreddit)/hot.json?limit=30";
        if (search_query.length > 0) {
            url = @"https://www.reddit.com/r/$(subreddit)/search.json?q=$(Uri.escape_string(search_query))&restrict_sr=1&limit=30";
        }

        client.fetch_json(url, (response, parser, root) => {
            if (!response.is_success() || root == null) {
                warning("Reddit API HTTP error: %u", response.status_code);
                return;
            }

            try {
                var data = root.get_object();
                if (!data.has_member("data")) {
                    return;
                }
                var data_obj = data.get_object_member("data");
                if (!data_obj.has_member("children")) {
                    return;
                }
                var children = data_obj.get_array_member("children");

                Idle.add(() => {
                    if (search_query.length > 0) {
                        set_label(@"Search Results: \"$(search_query)\" in $(category_name)");
                    } else {
                        set_label(category_name);
                    }
                    uint len = children.get_length();
                    for (uint i = 0; i < len; i++) {
                        var post = children.get_element(i).get_object();
                        var post_data = post.get_object_member("data");
                        var title = post_data.has_member("title") ? post_data.get_string_member("title") : "No title";
                        var post_url = post_data.has_member("url") ? post_data.get_string_member("url") : "";
                        string? thumbnail = null;

                        // Try to get high-quality preview image first
                        if (post_data.has_member("preview")) {
                            var preview = post_data.get_object_member("preview");
                            if (preview.has_member("images")) {
                                var images = preview.get_array_member("images");
                                if (images.get_length() > 0) {
                                    var first_image = images.get_element(0).get_object();
                                    if (first_image.has_member("source")) {
                                        var source = first_image.get_object_member("source");
                                        if (source.has_member("url")) {
                                            string preview_url = source.get_string_member("url");
                                            // Decode HTML entities in URL
                                            thumbnail = preview_url.replace("&amp;", "&");
                                        }
                                    }
                                }
                            }
                        }

                        // Fallback to thumbnail if no preview available
                        if (thumbnail == null && post_data.has_member("thumbnail")) {
                            string thumb = post_data.get_string_member("thumbnail");
                            if (thumb.has_prefix("http") && thumb != "default" && thumb != "self" && thumb != "nsfw") {
                                thumbnail = thumb;
                            }
                        }

                        add_item(title, post_url, thumbnail, category, "Reddit");
                    }
                    return false;
                });
            } catch (GLib.Error e) {
                warning("Reddit fetch error: %s", e.message);
            }
        });
    }

    public override string get_source_name() {
        return "Reddit";
    }
}
