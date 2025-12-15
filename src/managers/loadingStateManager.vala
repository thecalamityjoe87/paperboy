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
    private weak NewsWindow window;

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
    public uint absolute_reveal_timeout_id = 0;
    public bool network_failure_detected = false;
    public bool awaiting_adaptive_layout = false;
    public int64 initial_phase_start_time = 0;

    public LoadingStateManager(NewsWindow w) {
        window = w;
    }

    /**
     * Begin a new fetch - resets initial phase state and shows loading spinner.
     * Call this at the start of fetch_news() to initialize loading state.
     */
    public void begin_fetch() {
        // Reset initial-phase gating state
        initial_phase = true;
        hero_image_loaded = false;
        pending_images = 0;
        initial_items_populated = false;
        network_failure_detected = false;
        initial_phase_start_time = GLib.get_monotonic_time();

        // Clear image cache at startup to rule out stale cache data
        if (window.image_cache != null) window.image_cache.clear();

        // Don't reset awaiting_adaptive_layout - it may have been set before begin_fetch()

        // Cancel any pending initial reveal timeouts
        if (initial_reveal_timeout_id > 0) {
            Source.remove(initial_reveal_timeout_id);
            initial_reveal_timeout_id = 0;
        }
        if (absolute_reveal_timeout_id > 0) {
            Source.remove(absolute_reveal_timeout_id);
            absolute_reveal_timeout_id = 0;
        }

        // Set an absolute maximum timeout - but only reveal if content has actually arrived
        // This prevents showing a blank white area when content takes longer than expected
        absolute_reveal_timeout_id = GLib.Timeout.add(8000, () => {
            // Only reveal if we have content; otherwise keep spinner visible
            if (initial_items_populated) {
                reveal_initial_content();
            }
            // Don't clear the timeout ID here - let it be cleared by reveal_initial_content
            // or when content eventually arrives
            return false;
        });

        // Hide any previous error message
        hide_error_message();

        // Show loading spinner
        show_loading_spinner();
    }

    public void show_loading_spinner() {
        if (loading_container != null && loading_spinner != null && loading_label != null) {
            // Remove "No more articles" message when starting a new load
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

            // Hide My Feed instructions if switching away from My Feed
            update_personalization_ui();

            // If we're fetching Local News, show a more specific message
            var prefs_local = NewsPreferences.get_instance();
            if (prefs_local != null && prefs_local.category == "local_news") {
                loading_label.set_text("Loading local news...");
            } else {
                loading_label.set_text("Loading news...");
            }

            loading_container.set_visible(true);
            loading_spinner.start();
            if (window.main_content_container != null) window.main_content_container.set_visible(false);
        }
    }

    public void hide_loading_spinner() {
        if (loading_container != null && loading_spinner != null && loading_label != null) {
            loading_label.set_text("Loading news...");
            loading_container.set_visible(false);
            loading_spinner.stop();
            update_personalization_ui();
            update_local_news_ui();

            // Save article tracking and refresh sidebar badges after content is loaded
            if (window.article_state_store != null) {
                window.article_state_store.save_article_tracking_to_disk();
            }
            if (window.sidebar_manager != null) {
                window.sidebar_manager.refresh_all_badge_counts();
            }

            if (window.article_manager.remaining_articles != null && window.article_manager.remaining_articles.size > 0 && window.article_manager.articles_shown >= Managers.ArticleManager.INITIAL_ARTICLE_LIMIT) {
                window.article_manager.show_load_more_button();
            } else if (window.article_manager.remaining_articles == null || window.article_manager.remaining_articles.size == 0) {
                Timeout.add(800, () => {
                    // Safety check: window may have been destroyed (weak reference)
                    if (window == null) return false;
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
            hide_loading_spinner();
            if (personalized_message_box != null) personalized_message_box.set_visible(false);
            if (local_news_message_box != null) local_news_message_box.set_visible(false);
            if (window.main_content_container != null) window.main_content_container.set_visible(false);

            if (msg == null) msg = "No articles could be loaded. Try refreshing or check your source settings.";
            if (error_message_label != null && msg != null) error_message_label.set_text(msg);
            error_message_box.set_visible(true);
        }
    }

    public void hide_error_message() {
        if (error_message_box != null) {
            error_message_box.set_visible(false);
            // CRITICAL: Restore main content visibility when hiding error
            // show_error_message() hides main_content_container, so we must restore it
            // This fixes the dead-end issue where articles are invisible after clicking
            // a new category following an RSS timeout error
            if (window.main_content_container != null && !initial_phase) {
                window.main_content_container.set_visible(true);
            }
        }
    }

    public void update_personalization_ui() {
        if (personalized_message_box == null) return;
        var prefs = NewsPreferences.get_instance();
        bool enabled = prefs.personalized_feed_enabled;
        bool is_myfeed = prefs.category == "myfeed";
        bool has_personalized = prefs.personalized_categories != null && prefs.personalized_categories.size > 0;

        // Check if there are any custom RSS sources enabled
        bool has_custom_rss = false;
        var rss_store = Paperboy.RssSourceStore.get_instance();
        var all_custom = rss_store.get_all_sources();
        foreach (var src in all_custom) {
            if (prefs.preferred_source_enabled("custom:" + src.url)) {
                has_custom_rss = true;
                break;
            }
        }

        bool show_message = false;
        if (is_myfeed) {
            // Show message if personalized feed is disabled (no content will be fetched regardless of sources)
            if (!enabled) {
                if (personalized_message_label != null) personalized_message_label.set_text("Personalized feed is disabled.");
                if (personalized_message_sub_label != null) {
                    personalized_message_sub_label.set_text("Open the main menu (☰) → choose Preferences → 'Sources' tab → 'Enable Personalized Feed' toggle to see content from your sources.");
                    personalized_message_sub_label.set_visible(true);
                }
                if (personalized_message_action != null) personalized_message_action.set_visible(true);
                show_message = true;
            } else if (prefs.myfeed_custom_only && !has_custom_rss) {
                // Custom sources only mode is enabled but no RSS sources are followed
                if (personalized_message_label != null) personalized_message_label.set_text("No custom RSS sources followed.");
                if (personalized_message_sub_label != null) {
                    personalized_message_sub_label.set_text("You've enabled 'Custom sources only' mode. Follow and enable RSS feeds by clicking the button below or open the main menu (☰) → Preferences → 'Sources' tab.");
                    personalized_message_sub_label.set_visible(true);
                }
                if (personalized_message_action != null) personalized_message_action.set_visible(true);
                show_message = true;
            } else if (enabled && !has_personalized && !has_custom_rss) {
                if (personalized_message_label != null) personalized_message_label.set_text("Personalized Feed is enabled but no categories are selected.");
                if (personalized_message_sub_label != null) {
                    personalized_message_sub_label.set_text("Open the main menu (☰) → choose Preferences → 'Sources' tab → 'Enable Personalized Feed' toggle and click its settings icon to select categories, or follow custom RSS sources.");
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

        if (personalized_message_box != null) personalized_message_box.set_visible(show_message);

        // Hide main content when showing the overlay (regardless of initial_phase)
        // Also keep it hidden if we're waiting for adaptive layout to complete
        // CRITICAL: Also keep it hidden during initial_phase to prevent blank cards
        if (window.main_content_container != null) {
            if (show_message) {
                window.main_content_container.set_visible(false);
            } else if (!awaiting_adaptive_layout && !initial_phase) {
                window.main_content_container.set_visible(true);
            }
            // If awaiting_adaptive_layout OR initial_phase, keep it hidden (don't change visibility)
        }

        if (loading_container != null && show_message) {
            loading_container.set_visible(false);

            // Cancel the initial reveal timeout to prevent error overlay from showing
            if (initial_reveal_timeout_id > 0) {
                Source.remove(initial_reveal_timeout_id);
                initial_reveal_timeout_id = 0;
            }

            // Mark as populated and exit initial phase to prevent timeout from triggering error
            initial_items_populated = true;
            initial_phase = false;
        }

        if (personalized_message_sub_label != null && !show_message) personalized_message_sub_label.set_visible(false);

        update_local_news_ui();
    }

    public void update_local_news_ui() {
        if (local_news_message_box == null || window.main_content_container == null) return;
        var prefs = NewsPreferences.get_instance();
        bool needs_location = false;
        bool is_local = prefs.category == "local_news";
        bool has_location = (prefs.user_location != null && prefs.user_location.length > 0) || (prefs.user_location_city != null && prefs.user_location_city.length > 0);
        needs_location = is_local && !has_location;

        if (local_news_message_box != null) local_news_message_box.set_visible(needs_location);
        // Only show main content if not in initial phase and not awaiting adaptive layout
        if (!initial_phase && !awaiting_adaptive_layout && window.main_content_container != null) {
            window.main_content_container.set_visible(!needs_location);
        }
    }

    public void reveal_initial_content() {
        if (!initial_phase) return;
        // Don't reveal if we're still waiting for adaptive layout to complete
        if (awaiting_adaptive_layout) return;

        initial_phase = false;
        hero_image_loaded = false;
        if (initial_reveal_timeout_id > 0) {
            Source.remove(initial_reveal_timeout_id);
            initial_reveal_timeout_id = 0;
        }
        if (absolute_reveal_timeout_id > 0) {
            Source.remove(absolute_reveal_timeout_id);
            absolute_reveal_timeout_id = 0;
        }
        hide_loading_spinner();
        bool pvis = personalized_message_box != null ? personalized_message_box.get_visible() : false;
        bool lvis = local_news_message_box != null ? local_news_message_box.get_visible() : false;
        if (!pvis && !lvis) {
            if (window.main_content_container != null) window.main_content_container.set_visible(true);
        }

        Timeout.add(500, () => {
            if (window.image_manager != null) window.image_manager.upgrade_images_after_initial();
            // Save article tracking (disabled - no longer persisting)
            // Badge refreshes are now handled per-category/source in fetch_news()
            // to avoid race conditions and ensure accurate counts
                if (window.article_state_store != null) {
                    window.article_state_store.save_article_tracking_to_disk();
                }
                // CRITICAL: Now that initial_phase is complete, refresh badges
                // We deferred this during initial_phase to prevent widget tree
                // modifications from invalidating Picture widget paintables
                if (window.sidebar_manager != null) {
                    window.sidebar_manager.refresh_all_badge_counts();
                }
            return false;
        });
    }

    public void mark_initial_items_populated() {
        initial_items_populated = true;

        // Reset timeout every time a new article is added during initial phase
        // Use a short timeout (500ms) after each article - if no more articles arrive
        // within that window, we reveal. This ensures we wait for the batch to complete.
        if (initial_phase) {
            if (initial_reveal_timeout_id > 0) {
                Source.remove(initial_reveal_timeout_id);
            }
            // Short delay after last article to allow any remaining articles in the batch
            initial_reveal_timeout_id = GLib.Timeout.add(500, () => {
                // Clear the timeout ID since we're now executing
                initial_reveal_timeout_id = 0;

                // Only reveal if we have a reasonable number of articles
                // This prevents revealing with just 1-2 articles when more are expected
                int article_count = 0;
                    if (window.layout_manager != null && window.layout_manager.columns != null) {
                        foreach (var col in window.layout_manager.columns) {
                            if (col != null) {
                                var child = col.get_first_child();
                                while (child != null) {
                                    article_count++;
                                    child = child.get_next_sibling();
                                }
                            }
                        }
                    }
                    // Also count hero items
                    if (window.layout_manager != null && window.layout_manager.featured_box != null) {
                        var hero_child = window.layout_manager.featured_box.get_first_child();
                        while (hero_child != null) {
                            article_count++;
                            hero_child = hero_child.get_next_sibling();
                        }
                    }

                // Reveal if we have at least 3 articles, or if we've been waiting a while
                if (article_count >= 3) {
                    // CRITICAL: Don't use reveal_initial_content() - it exits early if initial_phase is false
                    // After RSS timeout, initial_phase is already false, so directly show the container
                        initial_phase = false;
                        hero_image_loaded = false;
                        if (initial_reveal_timeout_id > 0) {
                            Source.remove(initial_reveal_timeout_id);
                            initial_reveal_timeout_id = 0;
                        }
                        if (absolute_reveal_timeout_id > 0) {
                            Source.remove(absolute_reveal_timeout_id);
                            absolute_reveal_timeout_id = 0;
                        }
                        hide_loading_spinner();
                        if (window.main_content_container != null) {
                            window.main_content_container.set_visible(true);
                        }
                } else {
                    // Not enough articles yet - set a longer timeout
                    initial_reveal_timeout_id = GLib.Timeout.add(2000, () => {
                        initial_reveal_timeout_id = 0;
                        // CRITICAL: Same fix here
                            initial_phase = false;
                            hero_image_loaded = false;
                            hide_loading_spinner();
                            if (window.main_content_container != null) {
                                window.main_content_container.set_visible(true);
                            }
                        return false;
                    });
                }
                return false;
            });
        }
    }

    /**
     * Called when an image finished being set (success or fallback). During the
     * initial phase we decrement the pending counter and reveal the UI when all
     * initial items are populated and no pending image loads remain.
     */
    public void on_image_loaded(Gtk.Picture image) {
        if (!initial_phase) return;
        if (window.image_manager != null && window.image_manager.hero_requests.get(image) != null) {
            hero_image_loaded = true;
        }
        if (pending_images > 0) pending_images--;

        if (initial_items_populated && pending_images == 0) {
            // Don't reveal if waiting for adaptive layout
            if (!awaiting_adaptive_layout) {
                reveal_initial_content();
            }
        }
    }

    public void show_end_of_feed_message() {
        // Don't show "no more articles" if any instruction overlay is visible
            if (personalized_message_box != null && personalized_message_box.get_visible()) {
                return;
            }
            if (local_news_message_box != null && local_news_message_box.get_visible()) {
                return;
            }
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
            if (window.article_manager != null && window.article_manager.has_load_more_button()) {
                return;
            }

            window.content_box.append(end_label);
    }
}

}
