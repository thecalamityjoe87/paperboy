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

/**
 * Lets the user choose which of several podcasts discovered for a followed
 * RSS site to subscribe to - see HeaderManager's "Add podcast" button. A
 * site can genuinely run more than one podcast (e.g. USA Today has ~7 in
 * PodcastIndex), so silently subscribing to just the first match found
 * isn't good enough. Only shown when PodcastIndexService.
 * find_podcasts_by_site() returns 2+ matches; a single match still
 * subscribes directly with no dialog, same as before this existed.
 */
public class PodcastPickerDialog : GLib.Object {
    public static void show(NewsWindow? window, Gee.ArrayList<Paperboy.PodcastShow> shows, string? preselect_feed_url, Gtk.Window parent_window) {
        var dialog = new Adw.AlertDialog(
            "Choose Podcasts",
            "This site publishes more than one podcast - select which ones to add."
        );

        var scroller = new Gtk.ScrolledWindow();
        scroller.set_vexpand(true);
        scroller.set_min_content_height(240);
        scroller.set_max_content_height(420);
        scroller.set_hexpand(true);
        scroller.set_min_content_width(340);

        var list = new Gtk.ListBox();
        list.set_selection_mode(Gtk.SelectionMode.NONE);
        list.add_css_class("boxed-list");

        var sub_store = Paperboy.PodcastSubscriptionStore.get_instance();
        var checkboxes = new Gee.ArrayList<Gtk.CheckButton>();
        // Only unsubscribed rows count toward whether "Add Selected" has
        // anything to actually do - an already-subscribed row's checkbox is
        // always active but disabled, so it shouldn't count on its own.
        var selectable_checkboxes = new Gee.ArrayList<Gtk.CheckButton>();

        foreach (var show_item in shows) {
            bool already_subscribed = sub_store.is_subscribed(show_item.feed_id);

            string subtitle = show_item.author ?? "";
            if (show_item.episode_count > 0) {
                string ep_text = "%d episode%s".printf(show_item.episode_count, show_item.episode_count == 1 ? "" : "s");
                subtitle = subtitle.length > 0 ? "%s · %s".printf(subtitle, ep_text) : ep_text;
            }
            if (already_subscribed) {
                subtitle = subtitle.length > 0 ? "%s · Already subscribed".printf(subtitle) : "Already subscribed";
            }

            var row = new Adw.ActionRow();
            row.set_title(show_item.title);
            if (subtitle.length > 0) row.set_subtitle(subtitle);

            var cover = new Gtk.Picture();
            cover.set_size_request(40, 40);
            cover.set_content_fit(Gtk.ContentFit.COVER);
            cover.set_keep_aspect_ratio(false);
            cover.add_css_class("podcast-pane-cover");
            row.add_prefix(cover);
            if (window != null && show_item.image_url != null && show_item.image_url.length > 0) {
                window.image_manager.load_image_async(cover, show_item.image_url, 40, 40);
            }

            var check = new Gtk.CheckButton();
            check.set_valign(Gtk.Align.CENTER);
            check.set_active(already_subscribed || show_item.feed_url == preselect_feed_url);
            check.set_sensitive(!already_subscribed);
            row.add_suffix(check);

            if (!already_subscribed) {
                row.set_activatable(true);
                row.activated.connect(() => { check.set_active(!check.get_active()); });
                selectable_checkboxes.add(check);
            }

            checkboxes.add(check);
            list.append(row);
        }

        scroller.set_child(list);
        dialog.set_extra_child(scroller);

        dialog.add_response("cancel", "Cancel");
        dialog.add_response("subscribe", "Add Selected");
        dialog.set_response_appearance("subscribe", Adw.ResponseAppearance.SUGGESTED);
        dialog.set_default_response("subscribe");
        dialog.set_close_response("cancel");

        // Disabled until at least one not-already-subscribed row is
        // checked - nothing for "Add Selected" to actually do otherwise.
        void update_subscribe_enabled() {
            bool any_selected = false;
            foreach (var cb in selectable_checkboxes) {
                if (cb.get_active()) { any_selected = true; break; }
            }
            dialog.set_response_enabled("subscribe", any_selected);
        }
        foreach (var cb in selectable_checkboxes) {
            cb.notify["active"].connect(() => { update_subscribe_enabled(); });
        }
        update_subscribe_enabled();

        dialog.response.connect((response) => {
            if (response != "subscribe") return;

            int added = 0;
            for (int i = 0; i < shows.size; i++) {
                if (checkboxes[i].get_active() && !sub_store.is_subscribed(shows[i].feed_id)) {
                    sub_store.subscribe(shows[i]);
                    added++;
                }
            }
            if (window != null && window.toast_manager != null && added > 0) {
                window.toast_manager.show_toast(added == 1 ? "Podcast added" : "%d podcasts added".printf(added));
            }
        });

        dialog.present(parent_window);
    }
}
