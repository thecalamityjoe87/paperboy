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

using Gtk;
using Adw;

// Preferences "Personalization" tab: My Feed, Front Page, reading
// behavior, and the market and sports cards.
public class PersonalizationPrefsPage : Adw.PreferencesPage {
    private PrefsContext ctx;

    public SportsPrefsGroup sports_group { get; private set; }


    public PersonalizationPrefsPage(PrefsContext ctx) {
        this.ctx = ctx;
        set_title(_("Personalization"));
        set_icon_name("preferences-desktop-symbolic");

        add(build_region_group());
        add(build_categories_group());
        add(build_my_feed_group());
        add(build_myfeed_extras_group());
        add(build_frontpage_group());
        add(build_reading_group());
        add(build_market_group());
        sports_group = new SportsPrefsGroup(ctx);
        add(sports_group);
    }

    // ========== REGION ==========

    // Which Google News edition local news and Google-backed results use.
    private Adw.PreferencesGroup build_region_group() {
        var prefs = ctx.prefs;
        var win = ctx.win;
        var group = new Adw.PreferencesGroup();
        group.set_title(_("Region"));
        group.set_description(_("Your national news and Front Page come from this country"));

        var row = PrefsRows.country_row(prefs, () => {
            if (win == null) return;
            // The "us" category's name follows the edition
            if (win.sidebar_manager != null) win.sidebar_manager.rebuild_sidebar();
            win.fetch_news();
        });
        group.add(row);
        return group;
    }

    // ========== CATEGORIES ==========

    private Adw.NavigationPage? categories_page = null;

    // Opens the category chooser subpage, e.g. from the sidebar's
    // "Manage Categories". Call after the dialog is presented.
    public void open_categories_page() {
        if (categories_page != null && categories_page.get_parent() == null) ctx.dialog.push_subpage(categories_page);
    }

    // A row summarizing the chosen categories that opens the chooser.
    private Adw.PreferencesGroup build_categories_group() {
        var group = new Adw.PreferencesGroup();
        group.set_title(_("Categories"));
        group.set_description(_("The categories shown in the sidebar and used for My Feed"));

        var nav_row = new Adw.ActionRow();
        nav_row.set_title(_("Shown categories"));
        categories_page = build_categories_page(nav_row);
        PrefsRows.make_nav_row(ctx.dialog, nav_row, () => categories_page);
        group.add(nav_row);
        return group;
    }

    private void update_categories_summary(Adw.ActionRow nav_row) {
        int n = ctx.prefs.categories.size;
        int total = NewsPreferences.ALL_CATEGORIES.length;
        // if/else, not a ternary: Vala frees the printf() temp in that form before it's used.
        if (n == total) nav_row.set_subtitle(ngettext("All %d category", "All %d categories", total).printf(total));
        else if (n == 0) nav_row.set_subtitle(_("None"));
        else nav_row.set_subtitle(ngettext("%d of %d category", "%d of %d categories", total).printf(n, total));
    }

    // The chooser: every category gets a row - its switch adds or removes
    // it, its handle drags it into place. Chosen categories come first.
    private Adw.NavigationPage build_categories_page(Adw.ActionRow nav_row) {
        var prefs = ctx.prefs;
        var win = ctx.win;
        var group = new Adw.PreferencesGroup();
        group.set_description(_("Choose the categories shown in the sidebar and used for My Feed. Drag a row by its handle to reorder."));

        var list_box = new Gtk.ListBox();
        list_box.set_selection_mode(Gtk.SelectionMode.NONE);
        list_box.add_css_class("boxed-list");

        var ordered = prefs.categories;
        foreach (var cat in NewsPreferences.ALL_CATEGORIES) {
            if (!ordered.contains(cat)) ordered.add(cat);
        }

        // Saves the switched-on rows, top to bottom, as the categories list
        void persist() {
            var chosen = new Gee.ArrayList<string>();
            for (int i = 0; ; i++) {
                var row = list_box.get_row_at_index(i) as Adw.SwitchRow;
                if (row == null) break;
                if (row.get_active()) chosen.add(row.get_name());
            }
            prefs.categories = chosen;
            update_categories_summary(nav_row);
            // Applied live - no "Refresh Content?" prompt on close. Only My
            // Feed shows these categories' articles, so it's the one view to reload.
            if (win != null) {
                if (win.sidebar_manager != null) win.sidebar_manager.rebuild_sidebar();
                UnreadFetchService.refresh_myfeed_metadata(win);
                if (win.prefs.category == "myfeed") win.fetch_news();
            }
        }

        foreach (var cat in ordered) {
            var row = new Adw.SwitchRow();
            string title = win != null ? win.category_display_name_for(cat) : cat;
            row.set_title(title);
            row.set_name(cat);
            row.set_active(prefs.category_enabled(cat));
            var icon = CategoryIconsUtils.create_category_icon(cat);
            if (icon != null) row.add_prefix(icon);
            PrefsRows.add_drag_handle(row, title, () => {
                Value val = Value(typeof(Gtk.ListBoxRow));
                val.set_object(row);
                return new Gdk.ContentProvider.for_value(val);
            });
            row.notify["active"].connect(() => persist());

            var drop_target = new Gtk.DropTarget(typeof(Gtk.ListBoxRow), Gdk.DragAction.MOVE);
            drop_target.drop.connect((value, x, y) => {
                Gtk.ListBoxRow? src_row = (Gtk.ListBoxRow) value.get_object();
                if (src_row == null || src_row == row) return false;
                int target_index = row.get_index();
                list_box.remove(src_row);
                list_box.insert(src_row, target_index);
                persist();
                return true;
            });
            row.add_controller(drop_target);

            list_box.append(row);
        }

        update_categories_summary(nav_row);
        group.add(list_box);
        var page = new Adw.PreferencesPage();
        page.add(group);
        return PrefsRows.build_subpage(page, "Categories");
    }

    // ========== MY FEED ==========

    private Adw.PreferencesGroup build_my_feed_group() {
        var prefs = ctx.prefs;
        var win = ctx.win;
        var group = new Adw.PreferencesGroup();
        group.set_title(_("Personalization"));

        var personalized_row = new Adw.ActionRow();
        personalized_row.set_title(_("Enable personalized feed"));
        personalized_row.set_subtitle(_("Enable a personalized feed based on your reading habits"));

        var personalized_switch = PrefsRows.add_switch_suffix(personalized_row, prefs.personalized_feed_enabled);
        personalized_switch.notify["active"].connect(() => {
            prefs.personalized_feed_enabled = personalized_switch.get_active();
            prefs.save_config();
            // Drop the stale count so re-enabling starts from a fresh build
            if (!prefs.personalized_feed_enabled && win != null && win.article_state_store != null) {
                win.article_state_store.reset_myfeed_displayed_urls();
                win.article_state_store.save_article_tracking_to_disk();
            }
            if (win != null && win.sidebar_manager != null) {
                win.sidebar_manager.update_badge_for_category("myfeed");
            }
            // If user is currently viewing My Feed when they disable it, refresh the view
            // to show the "disabled" message
            if (win != null && win.prefs.category == "myfeed") {
                win.fetch_news();
            }
        });
        group.add(personalized_row);

        // Choosing which followed feeds show up in My Feed gets its own
        // slide-in subpage. Rebuilt on each open so it reflects feeds
        // followed since.
        var myfeed_feeds_row = new Adw.ActionRow();
        myfeed_feeds_row.set_title(_("Custom feeds in My Feed"));
        myfeed_feeds_row.set_subtitle(_("Choose which followed RSS feeds appear in My Feed"));
        PrefsRows.make_nav_row(ctx.dialog, myfeed_feeds_row, () => build_myfeed_feeds_page());
        group.add(myfeed_feeds_row);

        var custom_only_row = new Adw.SwitchRow();
        custom_only_row.set_title(_("Custom feeds only in My Feed"));
        custom_only_row.set_subtitle(_("Only show followed RSS feeds in My Feed, hide built-in sources"));
        custom_only_row.set_active(prefs.myfeed_custom_only);
        custom_only_row.notify["active"].connect(() => {
            prefs.myfeed_custom_only = custom_only_row.get_active();
            prefs.save_config();
        });
        group.add(custom_only_row);

        group.add(build_unread_badges_row());
        return group;
    }

    private Adw.ActionRow build_unread_badges_row() {
        var prefs = ctx.prefs;
        var win = ctx.win;

        void refresh_badges() {
            if (win != null && win.sidebar_manager != null) {
                win.sidebar_manager.refresh_all_badge_counts();
            }
        }

        // ActionRow rather than SwitchRow, to fit a settings button
        var unread_badges_row = new Adw.ActionRow();
        unread_badges_row.set_title(_("Show unread count badges"));
        unread_badges_row.set_subtitle(_("Display unread article counts in the sidebar"));

        // Popover with per-area badge visibility options
        var badge_settings_btn = PrefsRows.flat_icon_button("settings-symbolic", _("Badge visibility settings"));
        badge_settings_btn.clicked.connect(() => {
            var popover = new Gtk.Popover();
            popover.set_parent(badge_settings_btn);

            var popover_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
            popover_box.set_margin_start(12);
            popover_box.set_margin_end(12);
            popover_box.set_margin_top(12);
            popover_box.set_margin_bottom(12);

            var special_check = new Gtk.CheckButton.with_label(_("Show on special categories"));
            special_check.set_active(prefs.unread_badges_special_categories);
            special_check.toggled.connect(() => {
                prefs.unread_badges_special_categories = special_check.get_active();
                prefs.save_config();
                refresh_badges();
            });

            var sources_check = new Gtk.CheckButton.with_label(_("Show on Feeds"));
            sources_check.set_active(prefs.unread_badges_sources);
            sources_check.toggled.connect(() => {
                prefs.unread_badges_sources = sources_check.get_active();
                prefs.save_config();
                refresh_badges();
            });

            var categories_check = new Gtk.CheckButton.with_label(_("Show on categories"));
            categories_check.set_active(prefs.unread_badges_categories);
            categories_check.toggled.connect(() => {
                prefs.unread_badges_categories = categories_check.get_active();
                prefs.save_config();
                refresh_badges();
            });

            popover_box.append(special_check);
            popover_box.append(sources_check);
            popover_box.append(categories_check);
            popover.set_child(popover_box);
            popover.popup();
        });
        unread_badges_row.add_suffix(badge_settings_btn);

        var unread_badges_switch = PrefsRows.add_switch_suffix(unread_badges_row, prefs.unread_badges_enabled);
        unread_badges_switch.notify["active"].connect(() => {
            prefs.unread_badges_enabled = unread_badges_switch.get_active();
            prefs.save_config();
            refresh_badges();
        });
        return unread_badges_row;
    }

    private Adw.NavigationPage build_myfeed_feeds_page() {
        var prefs = ctx.prefs;
        var page = new Adw.PreferencesPage();
        var group = new Adw.PreferencesGroup();
        group.set_description(_("Choose which of your followed RSS feeds appear in My Feed"));

        var enabled_feeds = new Gee.ArrayList<Paperboy.RssSource>();
        foreach (var src in Paperboy.RssSourceStore.get_instance().get_all_sources()) {
            if (prefs.preferred_source_enabled("custom:" + src.url)) enabled_feeds.add(src);
        }

        if (enabled_feeds.size == 0) {
            var empty_row = new Adw.ActionRow();
            empty_row.set_title(_("No feeds followed yet"));
            empty_row.set_subtitle(_("Follow a custom RSS feed in Preferences -> Feeds first, then come back here to include it in My Feed."));
            group.add(empty_row);
        } else {
            foreach (var src in enabled_feeds) {
                string feed_url = src.url;
                var frow = new Adw.ActionRow();
                // Escape before set_title(): ActionRow parses this as
                // Pango markup, so an unescaped "&" (e.g. "Food & Wine")
                // breaks the parser and the title renders blank instead
                // of erroring.
                frow.set_title(GLib.Markup.escape_text(src.get_display_name()));
                frow.add_prefix(PrefsRows.rss_source_icon(src));

                var fswitch = PrefsRows.add_switch_suffix(frow, prefs.myfeed_feed_enabled(feed_url));
                fswitch.notify["active"].connect(() => {
                    prefs.set_myfeed_feed_enabled(feed_url, fswitch.get_active());
                    prefs.save_config();
                    // Applied live, like the categories: only My Feed shows these
                    if (ctx.win != null) {
                        UnreadFetchService.refresh_myfeed_metadata(ctx.win);
                        if (ctx.win.prefs.category == "myfeed") ctx.win.fetch_news();
                    }
                });
                group.add(frow);
            }
        }

        page.add(group);
        return PrefsRows.build_subpage(page, _("Custom feeds in My Feed"));
    }

    // ========== MY FEED EXTRAS ==========

    private Adw.PreferencesGroup build_myfeed_extras_group() {
        var group = new Adw.PreferencesGroup();
        group.set_title(_("My Feed Extras"));
        group.set_description(_("Show a preview row for other features at the top of My Feed, with a button to jump to the full page"));
        group.add(myfeed_extra_row(_("Sports scores"), "myfeed-show-sports"));
        group.add(myfeed_extra_row(_("Markets"), "myfeed-show-market"));
        group.add(myfeed_extra_row(_("Podcasts"), "myfeed-show-podcasts"));
        group.add(myfeed_extra_row(_("Magazine Rack"), "myfeed-show-magazines"));
        return group;
    }

    // Switch for one My Feed preview row; `property` names the
    // NewsPreferences bool it controls. Reloads My Feed if it's open.
    private Adw.SwitchRow myfeed_extra_row(string title, string property) {
        var prefs = ctx.prefs;
        var win = ctx.win;
        bool active;
        prefs.get(property, out active);

        var row = new Adw.SwitchRow();
        row.set_title(title);
        row.set_active(active);
        row.notify["active"].connect(() => {
            prefs.set(property, row.get_active());
            prefs.save_config();
            if (win != null && win.prefs.category == "myfeed") win.fetch_news();
        });
        return row;
    }

    // ========== FRONT PAGE ==========

    private Adw.PreferencesGroup build_frontpage_group() {
        var prefs = ctx.prefs;
        var win = ctx.win;
        var group = new Adw.PreferencesGroup();
        group.set_title(_("Front Page"));

        var recommendations_row = new Adw.SwitchRow();
        recommendations_row.set_title(_("Show recommendations"));
        recommendations_row.set_subtitle(_("Suggest articles based on your reading history. This stays on your device."));
        recommendations_row.set_active(prefs.recommendations_enabled);
        recommendations_row.notify["active"].connect(() => {
            prefs.recommendations_enabled = recommendations_row.get_active();
            if (win != null && win.prefs.category == "frontpage") win.fetch_news();
        });
        group.add(recommendations_row);
        return group;
    }

    // ========== READING ==========

    private Adw.PreferencesGroup build_reading_group() {
        var prefs = ctx.prefs;
        var win = ctx.win;
        var group = new Adw.PreferencesGroup();
        group.set_title(_("Reading"));

        var reader_view_row = new Adw.SwitchRow();
        reader_view_row.set_title(_("Open articles in reader view"));
        reader_view_row.set_subtitle(_("Show an extracted, distraction-free view of the article text instead of the full webpage by default. You can still switch views per article."));
        reader_view_row.set_active(prefs.reader_view_enabled);
        reader_view_row.notify["active"].connect(() => {
            prefs.reader_view_enabled = reader_view_row.get_active();
        });
        group.add(reader_view_row);

        var article_click_row = new Adw.SwitchRow();
        article_click_row.set_title(_("Clicking an article opens reader view directly"));
        article_click_row.set_subtitle(_("Skip the preview pane and jump straight into reader view when you click an article card"));
        article_click_row.set_active(prefs.article_click_opens_reader);
        article_click_row.notify["active"].connect(() => {
            prefs.article_click_opens_reader = article_click_row.get_active();
        });
        group.add(article_click_row);

        var hover_actions_row = new Adw.SwitchRow();
        hover_actions_row.set_title(_("Show quick-open buttons on hover"));
        hover_actions_row.set_subtitle(_("Show reader view / preview buttons over an article card's image when you hover it"));
        hover_actions_row.set_active(prefs.card_hover_actions_enabled);
        hover_actions_row.notify["active"].connect(() => {
            bool enabled = hover_actions_row.get_active();
            prefs.card_hover_actions_enabled = enabled;
            if (win != null) ArticleCard.set_hover_actions_visible_for_all(win, enabled);
        });
        group.add(hover_actions_row);
        return group;
    }

    // ========== MARKET CARDS ==========

    private Adw.PreferencesGroup build_market_group() {
        var prefs = ctx.prefs;
        var win = ctx.win;
        var group = new Adw.PreferencesGroup();
        group.set_title(_("Market Cards"));
        group.set_description(_("Choose whether the Business category shows live market index cards"));

        var market_master_row = new Adw.SwitchRow();
        market_master_row.set_title(_("Show market cards"));
        market_master_row.set_subtitle(_("Turn off to hide the live market index cards from the Business category"));
        market_master_row.set_active(prefs.market_cards_enabled);
        market_master_row.notify["active"].connect(() => {
            bool enabled = market_master_row.get_active();
            prefs.market_cards_enabled = enabled;
            if (win != null && win.prefs.category == "business" && enabled) {
                StocksTickerController.load(win);
            } else if (win != null) {
                StocksTickerController.stop_polling();
                StocksTickerController.hide(win);
            }
        });

        var market_pill_row = new Adw.SwitchRow();
        market_pill_row.set_title(_("Show market status pill"));
        market_pill_row.set_subtitle(_("Show an \"Open\" pill next to the Business sidebar count while the market is open"));
        market_pill_row.set_active(prefs.market_pill_enabled);
        market_pill_row.notify["active"].connect(() => {
            prefs.market_pill_enabled = market_pill_row.get_active();
            if (win != null && win.sidebar_manager != null) {
                win.sidebar_manager.rebuild_sidebar();
            }
        });

        group.add(market_master_row);
        group.add(market_pill_row);
        return group;
    }
}
