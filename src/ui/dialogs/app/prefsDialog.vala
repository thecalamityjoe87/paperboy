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

// The Preferences dialog: assembles the tabs from ui/dialogs/app/prefs/
// and, on close, offers to refresh if sources or categories changed.
public class PrefsDialog : GLib.Object {

    public static void show_source_dialog(Gtk.Window parent) {
        // If an article preview is currently open in the main window, close it
        var maybe_win = parent as NewsWindow;
        if (maybe_win != null) maybe_win.close_article_preview();

        // Go directly to preferences dialog
        show_preferences_dialog(parent);
    }

    public static void show_preferences_dialog(Gtk.Window parent, bool open_personalization = false, bool open_sports_settings = false, bool open_local_news = false, bool open_categories = false) {
        var win = (NewsWindow) parent;

        var dialog = new Adw.PreferencesDialog();
        dialog.set_title(_("Preferences"));

        // Wide enough to keep the top view-switcher showing all three tabs
        // as pills - narrower than this and Adw.PreferencesDialog collapses
        // them into a dropdown menu instead.
        dialog.set_content_width(600);
        dialog.set_content_height(680);

        var ctx = new PrefsContext(dialog, win);
        var sources_page = new SourcesPrefsPage(ctx);
        var personalization_page = new PersonalizationPrefsPage(ctx);
        var app_page = new AppPrefsPage(ctx);
        app_page.feeds_imported.connect(() => sources_page.add_new_feed_rows());

        dialog.add(sources_page);
        dialog.add(personalization_page);
        dialog.add(app_page);

        dialog.closed.connect(() => {
            if (win != null && ctx.sources_changed) offer_refresh(win);
        });

        if (open_personalization || open_sports_settings || open_categories) {
            dialog.set_visible_page(personalization_page);
        }

        dialog.present(parent);

        if (open_local_news) focus_when_mapped(sources_page.add_location_row);
        if (open_categories) personalization_page.open_categories_page();

        // Land on the sports score cards settings after clicking the
        // Sports settings badge
        if (open_sports_settings) focus_when_mapped(personalization_page.sports_group.master_row);
    }

    // Sources changed: ask whether to refresh now.
    private static void offer_refresh(NewsWindow win) {
        var confirm_dialog = new Adw.AlertDialog(
            _("Refresh Content?"),
            _("Changes have been made to your news sources. Would you like to refresh the content now?")
        );
        confirm_dialog.add_response("cancel", _("Not Now"));
        confirm_dialog.add_response("refresh", _("Refresh"));
        confirm_dialog.set_default_response("refresh");
        confirm_dialog.set_close_response("cancel");
        confirm_dialog.set_response_appearance("refresh", Adw.ResponseAppearance.SUGGESTED);

        confirm_dialog.choose.begin(win, null, (obj, res) => {
            string response = confirm_dialog.choose.end(res);
            // Always rebuild sidebar when sources change, regardless of refresh choice
            if (win.sidebar_manager != null) {
                win.sidebar_manager.rebuild_sidebar();
            }
            if (response == "refresh") {
                win.fetch_news();
            }
        });
    }

    private static void focus_when_mapped(Gtk.Widget widget) {
        ulong handler_id = 0;
        handler_id = widget.map.connect(() => {
            widget.grab_focus();
            widget.disconnect(handler_id);
        });
    }
}
