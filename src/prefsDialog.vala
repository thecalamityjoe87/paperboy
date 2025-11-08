/*
 * Copyright (C) 2025  Isaac Joseph <calamityjoe87@gmail.com>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

using Gtk;
using Adw;
using Soup;
using Gdk;

public class PrefsDialog : GLib.Object {
    
    public static void show_source_dialog(Gtk.Window parent) {
        // If an article preview is currently open in the main window, close it
        var maybe_win = parent as NewsWindow;
        if (maybe_win != null) maybe_win.close_article_preview();

        var prefs = NewsPreferences.get_instance();
        string current_source_name = "";
        switch (prefs.news_source) {
            case NewsSource.GUARDIAN:
                current_source_name = "The Guardian";
                break;
            case NewsSource.REDDIT:
                current_source_name = "Reddit";
                break;
            case NewsSource.BBC:
                current_source_name = "BBC News";
                break;
            case NewsSource.NEW_YORK_TIMES:
                current_source_name = "New York Times";
                break;
            case NewsSource.BLOOMBERG:
                current_source_name = "Bloomberg";
                break;
            case NewsSource.REUTERS:
                current_source_name = "Reuters";
                break;
            case NewsSource.NPR:
                current_source_name = "NPR";
                break;
            case NewsSource.FOX:
                current_source_name = "Fox News";
                break;
            case NewsSource.WALL_STREET_JOURNAL:
                current_source_name = "Wall Street Journal";
                break;
        }
        
        var dialog = new Adw.AlertDialog(
            "News Source",
            @"Currently using <b>$(current_source_name)</b> as the news source."
        );
        dialog.set_body_use_markup(true);
        dialog.add_response("browse", "Switch Source");
        dialog.add_response("ok", "OK");
        dialog.set_default_response("ok");
        dialog.set_close_response("ok");
        dialog.set_response_appearance("browse", Adw.ResponseAppearance.SUGGESTED);
        
        dialog.choose.begin(parent, null, (obj, res) => {
            string response = dialog.choose.end(res);
            if (response == "browse") {
                show_sources_list_dialog(parent);
            }
        });
    }
    
    public static void show_sources_list_dialog(Gtk.Window parent) {
        var win = (NewsWindow) parent;
        var prefs = NewsPreferences.get_instance();
        var sources_dialog = new Adw.AlertDialog(
            "Select News Source",
            "Choose a news source to fetch articles from:"
        );
        
        // Create a ListBox for interactive source selection
        var list_box = new Gtk.ListBox();
        list_box.set_selection_mode(Gtk.SelectionMode.NONE);
        list_box.add_css_class("boxed-list");

        // Helper: async load favicon into provided Gtk.Image
        void load_favicon(Gtk.Image image, string url) {
            new Thread<void*>("load-favicon", () => {
                try {
                    var session = new Soup.Session();
                    var msg = new Soup.Message("GET", url);
                    msg.request_headers.append("User-Agent", "news-vala-gnome/0.1");
                    // Request higher quality favicon formats when possible
                    msg.request_headers.append("Accept", "image/png,image/x-icon,image/svg+xml,image/*;q=0.8");
                    session.send_message(msg);
                    if (msg.status_code == 200 && msg.response_body.length > 0) {
                        Idle.add(() => {
                            try {
                                var loader = new Gdk.PixbufLoader();
                                uint8[] data = new uint8[msg.response_body.length];
                                Memory.copy(data, msg.response_body.data, (size_t) msg.response_body.length);
                                loader.write(data);
                                loader.close();
                                var pixbuf = loader.get_pixbuf();
                                if (pixbuf != null) {
                                    // Scale to 24x24 with high quality interpolation
                                    var scaled = pixbuf.scale_simple(24, 24, Gdk.InterpType.HYPER);
                                    if (scaled != null) {
                                        var texture = Gdk.Texture.for_pixbuf(scaled);
                                        image.set_from_paintable(texture);
                                    }
                                }
                            } catch (GLib.Error e) {
                                // keep placeholder
                            }
                            return false;
                        });
                    }
                } catch (GLib.Error e) { }
                return null;
            });
        }
        
        // Add The Guardian
        var guardian_row = new Adw.ActionRow();
        guardian_row.set_title("The Guardian");
        guardian_row.set_subtitle("World news with multiple categories");
        var guardian_icon = new Gtk.Image.from_icon_name("globe-symbolic");
        guardian_row.add_prefix(guardian_icon);
        load_favicon(guardian_icon, "https://www.theguardian.com/favicon.ico");
        if (prefs.news_source == NewsSource.GUARDIAN) {
            var check = new Gtk.Image.from_icon_name("emblem-ok-symbolic");
            guardian_row.add_suffix(check);
        }
        guardian_row.activatable = true;
        guardian_row.activated.connect(() => {
            prefs.news_source = NewsSource.GUARDIAN;
            prefs.save_config();
            sources_dialog.close();
            win.fetch_news();
        });
        list_box.append(guardian_row);
        
        // Add Reddit
        var reddit_row = new Adw.ActionRow();
        reddit_row.set_title("Reddit");
        reddit_row.set_subtitle("Popular posts from subreddits");
        var reddit_icon = new Gtk.Image.from_icon_name("internet-chat-symbolic");
        reddit_row.add_prefix(reddit_icon);
        load_favicon(reddit_icon, "https://www.reddit.com/favicon.ico");
        if (prefs.news_source == NewsSource.REDDIT) {
            var check = new Gtk.Image.from_icon_name("emblem-ok-symbolic");
            reddit_row.add_suffix(check);
        }
        reddit_row.activatable = true;
        reddit_row.activated.connect(() => {
            prefs.news_source = NewsSource.REDDIT;
            prefs.save_config();
            sources_dialog.close();
            win.fetch_news();
        });
        list_box.append(reddit_row);
        
        // Add BBC
        var bbc_row = new Adw.ActionRow();
        bbc_row.set_title("BBC News");
        bbc_row.set_subtitle("Global news and categories");
        var bbc_icon = new Gtk.Image.from_icon_name("globe-symbolic");
        bbc_row.add_prefix(bbc_icon);
        load_favicon(bbc_icon, "https://www.bbc.co.uk/favicon.ico");
        if (prefs.news_source == NewsSource.BBC) {
            var check = new Gtk.Image.from_icon_name("emblem-ok-symbolic");
            bbc_row.add_suffix(check);
        }
        bbc_row.activatable = true;
        bbc_row.activated.connect(() => {
            prefs.news_source = NewsSource.BBC;
            prefs.save_config();
            sources_dialog.close();
            win.fetch_news();
        });
        list_box.append(bbc_row);

        // Add New York Times
        var nyt_row = new Adw.ActionRow();
        nyt_row.set_title("New York Times");
        nyt_row.set_subtitle("NYT RSS feeds by section");
        var nyt_icon = new Gtk.Image.from_icon_name("emblem-documents-symbolic");
        nyt_row.add_prefix(nyt_icon);
        load_favicon(nyt_icon, "https://www.nytimes.com/favicon.ico");
        if (prefs.news_source == NewsSource.NEW_YORK_TIMES) {
            var check = new Gtk.Image.from_icon_name("emblem-ok-symbolic");
            nyt_row.add_suffix(check);
        }
        nyt_row.activatable = true;
        nyt_row.activated.connect(() => {
            prefs.news_source = NewsSource.NEW_YORK_TIMES;
            prefs.save_config();
            sources_dialog.close();
            win.fetch_news();
        });
        list_box.append(nyt_row);

        // Add Bloomberg
        var bb_row = new Adw.ActionRow();
        bb_row.set_title("Bloomberg");
        bb_row.set_subtitle("Financial and business news");
        var bb_icon = new Gtk.Image.from_icon_name("emblem-money-symbolic");
        bb_row.add_prefix(bb_icon);
        load_favicon(bb_icon, "https://www.bloomberg.com/favicon.ico");
        if (prefs.news_source == NewsSource.BLOOMBERG) {
            var check = new Gtk.Image.from_icon_name("emblem-ok-symbolic");
            bb_row.add_suffix(check);
        }
        bb_row.activatable = true;
        bb_row.activated.connect(() => {
            // Persist the news source change, but avoid writing a
            // temporary category to config.ini. We want the category
            // reset to be session-only so we don't overwrite the user's
            // previously saved category.
            prefs.news_source = NewsSource.BLOOMBERG;
            prefs.save_config();
            // In-memory reset so the UI/fetch logic shows Bloomberg-compatible content
            // immediately, but the change is not persisted to config.ini.
            prefs.category = "markets";
            sources_dialog.close();
            win.fetch_news();
        });
        list_box.append(bb_row);

        // Add Wall Street Journal
        var wsj_row = new Adw.ActionRow();
        wsj_row.set_title("Wall Street Journal");
        wsj_row.set_subtitle("Business and financial news (site search)");
        var wsj_icon = new Gtk.Image.from_icon_name("emblem-documents-symbolic");
        wsj_row.add_prefix(wsj_icon);
        load_favicon(wsj_icon, "https://www.wsj.com/favicon.ico");
        if (prefs.news_source == NewsSource.WALL_STREET_JOURNAL) {
            var check = new Gtk.Image.from_icon_name("emblem-ok-symbolic");
            wsj_row.add_suffix(check);
        }
        wsj_row.activatable = true;
        wsj_row.activated.connect(() => {
            prefs.news_source = NewsSource.WALL_STREET_JOURNAL;
            prefs.save_config();
            sources_dialog.close();
            win.fetch_news();
        });
        list_box.append(wsj_row);

        // Add Reuters
        var reuters_row = new Adw.ActionRow();
        reuters_row.set_title("Reuters");
        reuters_row.set_subtitle("International news wire service");
        var reuters_icon = new Gtk.Image.from_icon_name("globe-symbolic");
        reuters_row.add_prefix(reuters_icon);
        load_favicon(reuters_icon, "https://www.reuters.com/favicon.ico");
        if (prefs.news_source == NewsSource.REUTERS) {
            var check = new Gtk.Image.from_icon_name("emblem-ok-symbolic");
            reuters_row.add_suffix(check);
        }
        reuters_row.activatable = true;
        reuters_row.activated.connect(() => {
            prefs.news_source = NewsSource.REUTERS;
            prefs.save_config();
            sources_dialog.close();
            win.fetch_news();
        });
        list_box.append(reuters_row);

        // Add NPR
        var npr_row = new Adw.ActionRow();
        npr_row.set_title("NPR");
        npr_row.set_subtitle("National Public Radio news");
        var npr_icon = new Gtk.Image.from_icon_name("audio-card-symbolic");
        npr_row.add_prefix(npr_icon);
        load_favicon(npr_icon, "https://www.npr.org/favicon.ico");
        if (prefs.news_source == NewsSource.NPR) {
            var check = new Gtk.Image.from_icon_name("emblem-ok-symbolic");
            npr_row.add_suffix(check);
        }
        npr_row.activatable = true;
        npr_row.activated.connect(() => {
            prefs.news_source = NewsSource.NPR;
            prefs.save_config();
            sources_dialog.close();
            win.fetch_news();
        });
        list_box.append(npr_row);

        // Add Fox News
        var fox_row = new Adw.ActionRow();
        fox_row.set_title("Fox News");
        fox_row.set_subtitle("Conservative news and commentary");
        var fox_icon = new Gtk.Image.from_icon_name("emblem-documents-symbolic");
        fox_row.add_prefix(fox_icon);
        load_favicon(fox_icon, "https://www.foxnews.com/favicon.ico");
        if (prefs.news_source == NewsSource.FOX) {
            var check = new Gtk.Image.from_icon_name("emblem-ok-symbolic");
            fox_row.add_suffix(check);
        }
        fox_row.activatable = true;
        fox_row.activated.connect(() => {
            prefs.news_source = NewsSource.FOX;
            prefs.save_config();
            sources_dialog.close();
            win.fetch_news();
        });
        list_box.append(fox_row);

        sources_dialog.set_extra_child(list_box);
        sources_dialog.add_response("close", "Close");
        sources_dialog.set_default_response("close");
        sources_dialog.set_close_response("close");
        sources_dialog.present(parent);
    }
    
    public static void show_about_dialog(Gtk.Window parent) {
    var about = new Adw.AboutDialog();
    about.set_application_name("Paperboy");
    about.set_application_icon("paperboy"); // Use the correct icon name
    about.set_version("0.1");
    about.set_developer_name("thecalamityjoe87 (Isaac Joseph)");
    about.set_comments("A beautiful news viewer for GNOME");
    about.set_website("https://github.com/thecalamityjoe87/paperboy");
    about.set_license_type(Gtk.License.GPL_3_0);
    about.set_copyright("© 2025 thecalamityjoe87");
    about.present(parent);
    }
}