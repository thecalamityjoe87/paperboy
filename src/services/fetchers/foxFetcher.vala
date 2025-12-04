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

public class FoxFetcher : BaseFetcher {
    public FoxFetcher(SetLabelFunc set_label_func, ClearItemsFunc clear_items_func, AddItemFunc add_item_func) {
        base(set_label_func, clear_items_func, add_item_func);
    }

    public override void fetch(string category, string search_query, Soup.Session session) {
        fetch_fox_scrape(category, search_query, session);
    }

    public override string get_source_name() {
        return "Fox News";
    }

    private void fetch_fox_scrape(
        string current_category,
        string current_search_query,
        Soup.Session session
    ) {
        new Thread<void*>("fetch-fox-scrape", () => {
            try {
                Gee.ArrayList<string> section_urls = new Gee.ArrayList<string>();
                switch (current_category) {
                    case "politics": section_urls.add("https://www.foxnews.com/politics"); break;
                    case "us": section_urls.add("https://www.foxnews.com/us"); break;
                    case "technology":
                        section_urls.add("https://www.foxnews.com/tech");
                        section_urls.add("https://www.foxnews.com/technology");
                        break;
                    case "business": section_urls.add("https://www.foxnews.com/business"); break;
                    case "science": section_urls.add("https://www.foxnews.com/science"); break;
                    case "sports": section_urls.add("https://www.foxnews.com/sports"); break;
                    case "health": section_urls.add("https://www.foxnews.com/health"); break;
                    case "entertainment": section_urls.add("https://www.foxnews.com/entertainment"); break;
                    case "lifestyle": section_urls.add("https://www.foxnews.com/lifestyle"); break;
                    case "general":
                        section_urls.add("https://www.foxnews.com/world");
                        section_urls.add("https://www.foxnews.com");
                        break;
                    default: section_urls.add("https://www.foxnews.com"); break;
                }

                if (current_search_query.length > 0) {
                    Idle.add(() => {
                        set_label(@"No Fox News results for search: \"$(current_search_query)\"");
                        return false;
                    });
                    return null;
                }

                Gee.ArrayList<Paperboy.NewsArticle> articles = ArticleScraper.scrape_section_urls(section_urls, "https://www.foxnews.com", current_search_query, session);
                Idle.add(() => {
                    string category_name = FetcherUtils.category_display_name(current_category) + " — Fox News";
                    if (current_search_query.length > 0) {
                        set_label(@"Search Results: \"$(current_search_query)\" in $(category_name)");
                    } else {
                        set_label(category_name);
                    }
                    int ui_limit = 16;
                    int count = 0;
                    foreach (var article in articles) {
                        if (count >= ui_limit) break;
                        Idle.add(() => {
                            add_item(article.title, article.url, article.image_url, current_category, "Fox News");
                            return false;
                        });
                        count++;
                    }
                    fetch_fox_article_images(articles, session, add_item, current_category);
                    return false;
                });
            } catch (GLib.Error e) {
                warning("Error parsing Fox News HTML: %s", e.message);
                Idle.add(() => {
                    set_label("Fox News: Error loading articles");
                    return false;
                });
            }
            return null;
        });
    }

    private void fetch_fox_article_images(
        Gee.ArrayList<Paperboy.NewsArticle> articles,
        Soup.Session session,
        AddItemFunc add_item,
        string current_category
    ) {
        int count = 0;
        foreach (var article in articles) {
            if (article.image_url == null && count < 6 && article.url != null) {
                Tools.ImageParser.fetch_open_graph_image(article.url, session, add_item, current_category, "Fox News");
                count++;
            }
            if (count >= 6) break;
        }
    }
}
