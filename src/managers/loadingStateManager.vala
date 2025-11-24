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
using GLib;

namespace Managers {

public class LoadingStateManager : GLib.Object {
    private NewsWindow window;

    // UI widgets (public so NewsWindow can set them during construction)
    public Gtk.Widget? loading_container;
    public Gtk.Spinner? loading_spinner;
    public Gtk.Label? loading_label;
    public Gtk.Box? personalized_message_box;
    public Gtk.Label? personalized_message_label;
    public Gtk.Label? personalized_message_sub_label;
    public Gtk.Button? personalized_message_action;
    public Gtk.Box? local_news_message_box;
    public Gtk.Label? local_news_title;
    public Gtk.Label? local_news_hint;
    public Gtk.Button? local_news_button;
    public Gtk.Box? error_message_box;
    public Gtk.Image? error_icon;
    public Gtk.Label? error_message_label;
    public Gtk.Button? error_retry_button;

    // State flags (managed internally)
    public bool initial_phase = false;
    public bool hero_image_loaded = false;
    public int pending_images = 0;
    public bool initial_items_populated = false;
    public uint initial_reveal_timeout_id = 0;
    public bool network_failure_detected = false;

    public LoadingStateManager(NewsWindow w) {
        window = w;
    }

    public void show_loading_spinner() {
        if (loading_container != null && loading_spinner != null && loading_label != null) {
            // Remove "No more articles" message when starting a new load
            try {
                var children = window.content_box.observe_children();
                for (uint i = 0; i < children.get_n_items(); i++) {
                    var child = children.get_item(i) as Gtk.Widget;
                    if (child is Gtk.Label) {
                        var label = child as Gtk.Label;
                        var txt = label.get_label();
                        if (txt == "<b>No more articles</b>" || txt == "No more articles") {
                            window.content_box.remove(label);
                            break;
                        }
                    }
                }
            } catch (GLib.Error e) { }

            // Hide My Feed instructions if switching away from My Feed
            try { update_personalization_ui(); } catch (GLib.Error e) { }

            // If we're fetching Local News, show a more specific message
            try {
                var prefs_local = NewsPreferences.get_instance();
                if (prefs_local != null && prefs_local.category == "local_news") {
                    loading_label.set_text("Loading local news...");
                } else {
                    loading_label.set_text("Loading news...");
                }
            } catch (GLib.Error e) { }

            loading_container.set_visible(true);
            loading_spinner.start();
            try { if (window.main_content_container != null) window.main_content_container.set_visible(false); } catch (GLib.Error e) { }
        }
    }

    public void hide_loading_spinner() {
        if (loading_container != null && loading_spinner != null && loading_label != null) {
            try { loading_label.set_text("Loading news..."); } catch (GLib.Error e) { }
            loading_container.set_visible(false);
            loading_spinner.stop();
            try { update_personalization_ui(); } catch (GLib.Error e) { }
            try { update_local_news_ui(); } catch (GLib.Error e) { }

            if (window.article_manager.remaining_articles != null && window.article_manager.remaining_articles.length > 0 && window.article_manager.articles_shown >= Managers.ArticleManager.INITIAL_ARTICLE_LIMIT) {
                try { window.article_manager.show_load_more_button(); } catch (GLib.Error e) { }
            } else if (window.article_manager.remaining_articles == null || window.article_manager.remaining_articles.length == 0) {
                Timeout.add(800, () => {
                    if (loading_container == null || !loading_container.get_visible()) {
                        show_end_of_feed_message();
                    }
                    return false;
                });
            }
        }
    }

    public void show_error_message(string? msg = null) {
        if (error_message_box != null) {
            try { hide_loading_spinner(); } catch (GLib.Error e) { }
            try { if (personalized_message_box != null) personalized_message_box.set_visible(false); } catch (GLib.Error e) { }
            try { if (local_news_message_box != null) local_news_message_box.set_visible(false); } catch (GLib.Error e) { }
            try { if (window.main_content_container != null) window.main_content_container.set_visible(false); } catch (GLib.Error e) { }

            if (msg == null) msg = "No articles could be loaded. Try refreshing or check your source settings.";
            try { if (error_message_label != null && msg != null) error_message_label.set_text(msg); } catch (GLib.Error e) { }
            error_message_box.set_visible(true);
        }
    }

    public void hide_error_message() {
        if (error_message_box != null) {
            error_message_box.set_visible(false);
        }
    }

    public void update_personalization_ui() {
        if (personalized_message_box == null) return;
        var prefs = NewsPreferences.get_instance();
        bool enabled = prefs.personalized_feed_enabled;
        bool is_myfeed = prefs.category == "myfeed";
        bool has_personalized = prefs.personalized_categories != null && prefs.personalized_categories.size > 0;

        bool show_message = false;
        try {
            if (is_myfeed) {
                if (!enabled) {
                    if (personalized_message_label != null) personalized_message_label.set_text("Enable this option in settings to get a personalized feed.");
                    if (personalized_message_sub_label != null) {
                        personalized_message_sub_label.set_text("Open the main menu (☰) and choose 'Preferences' → 'Set Source Options' and toggle 'Enable Personalized Feed'");
                        personalized_message_sub_label.set_visible(true);
                    }
                    if (personalized_message_action != null) personalized_message_action.set_visible(true);
                    show_message = true;
                } else if (enabled && !has_personalized) {
                    if (personalized_message_label != null) personalized_message_label.set_text("Personalized Feed is enabled but no categories are selected.");
                    if (personalized_message_sub_label != null) {
                        personalized_message_sub_label.set_text("Open Preferences → Personalized Feed and choose categories to enable My Feed.");
                        personalized_message_sub_label.set_visible(true);
                    }
                    if (personalized_message_action != null) personalized_message_action.set_visible(true);
                    show_message = true;
                } else {
                    show_message = false;
                }
            } else {
                show_message = false;
            }

            personalized_message_box.set_visible(show_message);

            if (!initial_phase && window.main_content_container != null) {
                window.main_content_container.set_visible(!show_message);
            }
        } catch (GLib.Error e) { }

        try {
            if (loading_container != null && show_message) {
                loading_container.set_visible(false);
            }
        } catch (GLib.Error e) { }

        try {
            if (personalized_message_sub_label != null && !show_message) personalized_message_sub_label.set_visible(false);
        } catch (GLib.Error e) { }

        try { update_local_news_ui(); } catch (GLib.Error e) { }
    }

    public void update_local_news_ui() {
        if (local_news_message_box == null || window.main_content_container == null) return;
        var prefs = NewsPreferences.get_instance();
        bool needs_location = false;
        try {
            bool is_local = prefs.category == "local_news";
            bool has_location = (prefs.user_location != null && prefs.user_location.length > 0) || (prefs.user_location_city != null && prefs.user_location_city.length > 0);
            needs_location = is_local && !has_location;
        } catch (GLib.Error e) { needs_location = false; }

        try { local_news_message_box.set_visible(needs_location); } catch (GLib.Error e) { }
        try { if (!initial_phase) window.main_content_container.set_visible(!needs_location); } catch (GLib.Error e) { }
    }

    public void reveal_initial_content() {
        if (!initial_phase) return;
        initial_phase = false;
        hero_image_loaded = false;
        if (initial_reveal_timeout_id > 0) {
            Source.remove(initial_reveal_timeout_id);
            initial_reveal_timeout_id = 0;
        }
        hide_loading_spinner();
        try {
            bool pvis = personalized_message_box != null ? personalized_message_box.get_visible() : false;
            bool lvis = local_news_message_box != null ? local_news_message_box.get_visible() : false;
            if (!pvis && !lvis) {
                try { if (window.main_content_container != null) window.main_content_container.set_visible(true); } catch (GLib.Error e) { }
            }
        } catch (GLib.Error e) { }

        Timeout.add(500, () => {
            try { window.upgrade_images_after_initial(); } catch (GLib.Error e) { }
            return false;
        });
    }

    public void mark_initial_items_populated() {
        initial_items_populated = true;
        if (initial_phase && pending_images == 0) {
            reveal_initial_content();
        }
    }

    public void show_end_of_feed_message() {
        try {
            var children = window.content_box.observe_children();
            for (uint i = 0; i < children.get_n_items(); i++) {
                var child = children.get_item(i) as Gtk.Widget;
                if (child is Gtk.Label) {
                    var label = child as Gtk.Label;
                    var label_text = label.get_label();
                    if ((label_text == "<b>No more articles</b>" || label_text == "No more articles") && label.has_css_class("dim-label")) {
                        return;
                    }
                }
            }

            // Note: load_more_button is now managed by ArticleManager, so we don't need to remove it here
            var end_label = new Gtk.Label("<b>No more articles</b>");
            end_label.set_use_markup(true);
            end_label.add_css_class("dim-label");
            end_label.set_margin_top(20);
            end_label.set_margin_bottom(20);
            end_label.set_halign(Gtk.Align.CENTER);
            // Don't show the end-of-feed label if the ArticleManager
            // has (or is about to show) a Load More button to avoid
            // the visual overlap where both appear together.
            try {
                if (window.article_manager != null && window.article_manager.has_load_more_button()) {
                    return;
                }
            } catch (GLib.Error e) { }

            window.content_box.append(end_label);
        } catch (GLib.Error e) { }
    }
}

}
