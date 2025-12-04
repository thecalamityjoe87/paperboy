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
using Tools;

public class GuardianFetcher : BaseFetcher {
    public GuardianFetcher(SetLabelFunc set_label_func, ClearItemsFunc clear_items_func, AddItemFunc add_item_func) {
        base(set_label_func, clear_items_func, add_item_func);
    }

    public override void fetch(string category, string search_query, Soup.Session session) {
        var client = Paperboy.HttpClient.get_default();
        string base_url = "https://content.guardianapis.com/search?show-fields=thumbnail&page-size=30&api-key=test";
        string url;
        switch (category) {
            case "us":
                url = base_url + "&section=us-news";
                break;
            case "technology":
                url = base_url + "&section=technology";
                break;
            case "business":
                url = base_url + "&section=business";
                break;
            case "science":
                url = base_url + "&section=science";
                break;
            case "sports":
                url = base_url + "&section=sport";
                break;
            case "health":
                url = base_url + "&tag=society/health";
                break;
            case "politics":
                url = base_url + "&section=politics";
                break;
            case "entertainment":
                url = base_url + "&section=culture";
                break;
            case "lifestyle":
                url = base_url + "&section=lifeandstyle";
                break;
            case "general":
            default:
                url = base_url + "&section=world";
                break;
        }
        if (search_query.length > 0) {
            url = url + "&q=" + Uri.escape_string(search_query);
        }

        client.fetch_json(url, (response, parser, root) => {
            if (!response.is_success() || root == null) {
                warning("Guardian API HTTP error: %u", response.status_code);
                return;
            }

            try {
                var data = root.get_object();
                if (!data.has_member("response")) {
                    return;
                }
                var response_obj = data.get_object_member("response");
                if (!response_obj.has_member("results")) {
                    return;
                }
                var results = response_obj.get_array_member("results");

                string category_name = FetcherUtils.category_display_name(category);
                Idle.add(() => {
                    if (search_query.length > 0) {
                        set_label(@"Search Results: \"$(search_query)\" in $(category_name) — The Guardian");
                    } else {
                        set_label(@"$(category_name) — The Guardian");
                    }
                    uint len = results.get_length();
                    for (uint i = 0; i < len; i++) {
                        var article = results.get_element(i).get_object();
                        var title = article.has_member("webTitle") ? article.get_string_member("webTitle") : "No title";
                        var article_url = article.has_member("webUrl") ? article.get_string_member("webUrl") : "";
                        string? thumbnail = null;
                        if (article.has_member("fields")) {
                            var fields = article.get_object_member("fields");
                            if (fields.has_member("thumbnail")) {
                                thumbnail = fields.get_string_member("thumbnail");
                            }
                        }
                        add_item(title, article_url, thumbnail, category, "The Guardian");
                    }
                    fetch_guardian_article_images(results, session, add_item, category);
                    return false;
                });
            } catch (GLib.Error e) {
                warning("Guardian fetch error: %s", e.message);
            }
        });
    }

    public override string get_source_name() {
        return "The Guardian";
    }

    private void fetch_guardian_article_images(
        Json.Array results,
        Soup.Session session,
        AddItemFunc add_item,
        string current_category
    ) {
        int count = 0;
        uint len = results.get_length();
        for (uint i = 0; i < len && count < 6; i++) {
            var article = results.get_element(i).get_object();
            if (article.has_member("webUrl")) {
                string url = article.get_string_member("webUrl");
                Tools.ImageParser.fetch_open_graph_image(url, session, add_item, current_category, "The Guardian");
                count++;
            }
        }
    }
}
