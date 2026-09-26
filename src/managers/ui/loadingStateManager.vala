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

    // Fired from show_loading_spinner()/hide_loading_spinner() so header UI
    // (the refresh button's icon<->spinner swap) can track fetch activity.
    public signal void fetch_started();
    public signal void fetch_finished();

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
    // Bundled icon the empty state is currently showing (null while the
    // overlay shows an error or is hidden) - kept so a light/dark switch
    // can re-resolve its themed variant, see refresh_empty_icon_for_theme().
    private string? empty_icon_file = null;

    // State flags (managed internally)
    public bool initial_phase = false;
    public bool hero_image_loaded = false;
    public int pending_images = 0;
    public bool initial_items_populated = false;
    public uint initial_reveal_timeout_id = 0;
    public uint absolute_reveal_timeout_id = 0;
    public bool network_failure_detected = false;
    public bool awaiting_adaptive_layout = false;
    // Front Page fires two independent backend fetches (frontpage list +
    // Trending) - held true until both report done, so the initial reveal
    // never fires with one section still empty.
    public bool awaiting_frontpage_endpoints = false;
    public int64 initial_phase_start_time = 0;

    // Extra bounded wait for background thumbnail backfill (see
    // ThumbnailBackfillService), so placeholder cards don't visibly pop to
    // a real image right after the view is revealed. Never delays the
    // reveal by more than BACKFILL_GRACE_MS - backfill is best-effort.
    private const int BACKFILL_GRACE_MS = 3000;
    public int pending_backfills = 0;
    private bool backfill_grace_expired = false;
    private uint backfill_grace_timeout_id = 0;
    private delegate void RevealAction();
    private RevealAction? pending_reveal_action = null;

    public LoadingStateManager(NewsWindow w) {
        window = w;
    }

    public void on_backfill_started() {
        if (initial_phase) pending_backfills++;
    }

    public void on_backfill_finished() {
        if (pending_backfills > 0) pending_backfills--;
        // The view may already have revealed via a different path (e.g.
        // on_image_loaded reaching pending_images == 0 first) while this
        // backfill was still running - a late arrival here must not
        // re-trigger a second reveal on top of that.
        if (!initial_phase) {
            pending_reveal_action = null;
            return;
        }
        // A backfilled thumbnail's own image download (see
        // ThumbnailBackfillService.apply_thumbnail) starts right as this
        // fires and is tracked via pending_images, not pending_backfills -
        // don't fire the stashed reveal until that's clear too.
        if (pending_backfills == 0 && pending_images == 0 && pending_reveal_action != null) {
            var action = (owned) pending_reveal_action;
            pending_reveal_action = null;
            action();
        }
    }

    // Runs `retry` immediately if backfill/images aren't blocking reveal
    // right now; otherwise holds it and arms a bounded grace timer,
    // returning false so the caller defers. `retry` is called again once
    // both clear or the grace period expires, whichever comes first.
    private bool ready_or_defer(owned RevealAction retry) {
        if ((pending_backfills == 0 && pending_images == 0) || backfill_grace_expired) return true;

        pending_reveal_action = (owned) retry;
        if (backfill_grace_timeout_id == 0) {
            backfill_grace_timeout_id = GLib.Timeout.add(BACKFILL_GRACE_MS, () => {
                backfill_grace_timeout_id = 0;
                backfill_grace_expired = true;
                if (pending_reveal_action != null) {
                    var action = (owned) pending_reveal_action;
                    pending_reveal_action = null;
                    action();
                }
                return false;
            });
        }
        return false;
    }

    private void force_reveal_now() {
        initial_phase = false;
        hero_image_loaded = false;
        pending_reveal_action = null;
        if (initial_reveal_timeout_id > 0) {
            Source.remove(initial_reveal_timeout_id);
            initial_reveal_timeout_id = 0;
        }
        if (absolute_reveal_timeout_id > 0) {
            Source.remove(absolute_reveal_timeout_id);
            absolute_reveal_timeout_id = 0;
        }
        hide_loading_spinner();
        trigger_initial_reveals();
    }

    // Call at the start of fetch_news() to reset initial-phase state and show the spinner.
    public void begin_fetch() {
        initial_phase = true;
        hero_image_loaded = false;
        pending_images = 0;
        initial_items_populated = false;
        network_failure_detected = false;
        initial_phase_start_time = GLib.get_monotonic_time();

        pending_backfills = 0;
        backfill_grace_expired = false;
        pending_reveal_action = null;
        if (backfill_grace_timeout_id > 0) {
            Source.remove(backfill_grace_timeout_id);
            backfill_grace_timeout_id = 0;
        }

        if (window.image_cache != null) window.image_cache.clear();

        // Don't reset awaiting_adaptive_layout - it may already be set from before begin_fetch()

        if (initial_reveal_timeout_id > 0) {
            Source.remove(initial_reveal_timeout_id);
            initial_reveal_timeout_id = 0;
        }
        if (absolute_reveal_timeout_id > 0) {
            Source.remove(absolute_reveal_timeout_id);
            absolute_reveal_timeout_id = 0;
        }

        // Absolute max wait before giving up on content and revealing anyway (avoids blank screen).
        absolute_reveal_timeout_id = GLib.Timeout.add(4000, () => {
            // Don't let a stuck/slow endpoint (e.g. Trending on Front Page)
            // hold the spinner up forever - show whatever landed by now.
            awaiting_frontpage_endpoints = false;
            if (initial_items_populated) {
                reveal_initial_content();
            }
            return false;
        });

        hide_error_message();
        show_loading_spinner();
    }

    public void show_loading_spinner() {
        fetch_started();
        if (loading_container != null && loading_spinner != null && loading_label != null) {
            // Remove "No more articles" message from the previous load, if any
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

            update_personalization_ui();

            var prefs_local = NewsPreferences.get_instance();
            if (prefs_local != null && prefs_local.category == "local_news") {
                loading_label.set_text("Loading local news...");
            } else {
                loading_label.set_text("Loading content...");
            }

            loading_container.set_visible(true);
            loading_spinner.start();
            if (window.main_content_container != null) window.main_content_container.set_visible(false);
        }
    }

    public void hide_loading_spinner() {
        fetch_finished();
        if (loading_container != null && loading_spinner != null && loading_label != null) {
            loading_container.set_visible(false);
            loading_spinner.stop();
            update_personalization_ui();
            update_local_news_ui();

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
                    if (window == null) return false; // weak ref; window may be gone
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
            // show_empty_message() reuses this overlay with its own icon and
            // no Refresh button - put the error presentation back.
            empty_icon_file = null;
            if (error_icon != null) {
                error_icon.set_from_icon_name("dialog-error-symbolic");
                error_icon.set_pixel_size(48);
                error_icon.set_opacity(1.0);
            }
            if (error_retry_button != null) error_retry_button.set_visible(true);
            hide_loading_spinner();
            if (personalized_message_box != null) personalized_message_box.set_visible(false);
            if (local_news_message_box != null) local_news_message_box.set_visible(false);
            if (window.main_content_container != null) window.main_content_container.set_visible(false);

            if (msg == null) msg = "No articles could be loaded. Try refreshing or check your source settings.";
            if (error_message_label != null && msg != null) error_message_label.set_text(msg);
            error_message_box.set_visible(true);
        }
    }

    // Centered empty state for a view that legitimately has nothing to
    // show (History/Saved/Magazines library when empty). `icon_file` is a
    // bundled "<name>-mono.svg" (the view's own header icon, or
    // search-mono.svg for an empty search), shown large and dimmed. Reuses the error overlay minus
    // its Refresh button. Also ends the initial phase and cancels the reveal
    // timeouts - left armed, INITIAL_MAX_WAIT_MS later fires
    // show_error_message() over this since no items were ever populated.
    public void show_empty_message(string icon_file, string msg = "Nothing here yet") {
        if (error_message_box == null) return;

        initial_phase = false;
        hero_image_loaded = false;
        pending_reveal_action = null;
        if (initial_reveal_timeout_id > 0) {
            Source.remove(initial_reveal_timeout_id);
            initial_reveal_timeout_id = 0;
        }
        if (absolute_reveal_timeout_id > 0) {
            Source.remove(absolute_reveal_timeout_id);
            absolute_reveal_timeout_id = 0;
        }

        if (loading_container != null && loading_container.get_visible()) hide_loading_spinner();
        if (window.content_view != null) window.content_view.remove_end_of_feed_message();
        if (window.main_content_container != null) window.main_content_container.set_visible(false);

        empty_icon_file = icon_file;
        if (error_icon != null) {
            apply_empty_icon();
            error_icon.set_pixel_size(80);
            // Explicit opacity rather than the dim-label class - that's
            // deprecated in libadwaita 1.7+ (now .dimmed) and didn't
            // visibly dim these bundled -mono icons.
            error_icon.set_opacity(0.4);
        }
        if (error_message_label != null) error_message_label.set_text(msg);
        if (error_retry_button != null) error_retry_button.set_visible(false);
        error_message_box.set_visible(true);
    }

    private void apply_empty_icon() {
        if (error_icon == null || empty_icon_file == null) return;
        string? icon_path = CategoryIconsUtils.resolve_themed_icon_path(empty_icon_file);
        if (icon_path != null) {
            error_icon.set_from_gicon(new GLib.FileIcon(GLib.File.new_for_path(icon_path)));
        } else {
            error_icon.set_from_icon_name("action-unavailable-symbolic");
        }
    }

    // Called on a light/dark switch so the empty state's bundled mono icon
    // swaps to/from its "-white" variant like the header/sidebar icons do.
    public void refresh_empty_icon_for_theme() {
        if (error_message_box == null || !error_message_box.get_visible()) return;
        apply_empty_icon();
    }

    // True when the article surface (hero, flat grid, or category sections)
    // holds no cards at all.
    private bool article_view_is_empty() {
        var lm = window.layout_manager;
        if (lm == null) return false;
        if (lm.featured_box != null && lm.featured_box.get_first_child() != null) return false;
        var cards = lm.get_cards_for_iteration();
        return cards == null || cards.get_n_items() == 0;
    }

    public void hide_error_message() {
        if (error_message_box != null) {
            error_message_box.set_visible(false);
            // show_error_message() hides main_content_container - restore it or articles stay invisible
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

        // Must match what fetchNewsController.vala actually fetches for My Feed
        // (enabled AND opted into My Feed), so the message doesn't disagree with the view.
        bool has_custom_rss = false;
        var rss_store = Paperboy.RssSourceStore.get_instance();
        var all_custom = rss_store.get_all_sources();
        foreach (var src in all_custom) {
            if (prefs.preferred_source_enabled("custom:" + src.url) && prefs.myfeed_feed_enabled(src.url)) {
                has_custom_rss = true;
                break;
            }
        }

        bool show_message = false;
        if (is_myfeed) {
            if (!enabled) {
                if (personalized_message_label != null) personalized_message_label.set_text("Personalized feed is disabled.");
                if (personalized_message_sub_label != null) {
                    personalized_message_sub_label.set_text("Open the main menu (☰) → choose Preferences → 'Personalization' tab → 'Enable prsonalized feed' toggle to see content from your feeds.");
                    personalized_message_sub_label.set_visible(true);
                }
                if (personalized_message_action != null) personalized_message_action.set_visible(true);
                show_message = true;
            } else if (prefs.myfeed_custom_only && !has_custom_rss) {
                if (personalized_message_label != null) personalized_message_label.set_text("No custom RSS feeds followed.");
                if (personalized_message_sub_label != null) {
                    personalized_message_sub_label.set_text("You've enabled 'Custom sources only' mode. Follow and enable RSS feeds by clicking the button below or open the main menu (☰) → Preferences → 'Personalization' tab.");
                    personalized_message_sub_label.set_visible(true);
                }
                if (personalized_message_action != null) personalized_message_action.set_visible(true);
                show_message = true;
            } else if (enabled && !has_personalized && !has_custom_rss) {
                if (personalized_message_label != null) personalized_message_label.set_text("Personalized Feed is enabled but no categories are selected.");
                if (personalized_message_sub_label != null) {
                    personalized_message_sub_label.set_text("Open the main menu (☰) → choose Preferences → 'Personalization' tab → 'Enable personalized feed' toggle and click its settings icon to select categories, or follow custom RSS feeds.");
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

        // Keep main content hidden while showing the overlay, or during initial_phase/adaptive layout
        // to avoid a flash of blank cards.
        if (window.main_content_container != null) {
            if (show_message) {
                window.main_content_container.set_visible(false);
            } else if (!awaiting_adaptive_layout && !initial_phase) {
                window.main_content_container.set_visible(true);
            }
        }

        if (loading_container != null && show_message) {
            loading_container.set_visible(false);

            if (initial_reveal_timeout_id > 0) {
                Source.remove(initial_reveal_timeout_id);
                initial_reveal_timeout_id = 0;
            }

            // Exit initial phase so the reveal timeout doesn't fire an error over this message
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
        bool has_location = prefs.get_local_areas().size > 0;
        needs_location = is_local && !has_location;

        if (local_news_message_box != null) local_news_message_box.set_visible(needs_location);
        // Don't re-show content underneath the My Feed message
        bool personalized_shown = personalized_message_box != null && personalized_message_box.get_visible();
        if (!personalized_shown && !initial_phase && !awaiting_adaptive_layout && window.main_content_container != null) {
            window.main_content_container.set_visible(!needs_location);
        }
    }

    public void reveal_initial_content() {
        if (!initial_phase) return;
        if (awaiting_adaptive_layout || awaiting_frontpage_endpoints) return;
        if (!ready_or_defer(reveal_initial_content)) return;

        initial_phase = false;
        hero_image_loaded = false;
        // Revealing via this path (e.g. on_image_loaded reaching
        // pending_images == 0) must not leave a stale action stashed by an
        // earlier ready_or_defer() call - a later backfill/grace callback
        // consuming it would fire a second, spurious reveal.
        pending_reveal_action = null;
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
            trigger_initial_reveals();
        }

        Timeout.add(180, () => {
            if (window.image_manager != null) window.image_manager.upgrade_images_after_initial();
            if (window.sidebar_manager != null) {
                window.sidebar_manager.refresh_all_badge_counts();
            }
            return false;
        });

        // Synchronous JSON write - scheduled past the entrance animation so it doesn't stall it.
        Timeout.add(600, () => {
            if (window.article_state_store != null) {
                window.article_state_store.save_article_tracking_to_disk();
            }
            return false;
        });
    }

    private void trigger_initial_reveals() {
        if (window == null || window.layout_manager == null || window.animation_manager == null) return;

        var cards = new Gee.ArrayList<Gtk.Widget>();
        if (window.layout_manager.featured_box != null) {
            var fchild = window.layout_manager.featured_box.get_first_child();
            while (fchild != null) {
                cards.add(fchild);
                fchild = fchild.get_next_sibling();
            }
        }
        if (window.layout_manager.columns_row != null) {
            var child = window.layout_manager.columns_row.get_first_child();
            while (child != null) {
                cards.add(child);
                child = child.get_next_sibling();
            }
        }

        // Hide cards before the container becomes visible, or they'd flash
        // at full opacity for a frame before animate_cards_entrance_batch
        // gets around to hiding them.
        foreach (var c in cards) c.set_opacity(0.0);

        if (window.main_content_container != null) window.main_content_container.set_visible(true);

        // Short delay so first-time layout of this subtree settles before the fade starts.
        GLib.Timeout.add(50, () => {
            window.animation_manager.animate_cards_entrance_batch(cards);
            return false;
        });
    }

    public void mark_initial_items_populated() {
        initial_items_populated = true;

        // Reset the timeout on each new article so we wait for the whole batch to land
        // before revealing, instead of revealing after the very first one.
        if (initial_phase) {
            if (initial_reveal_timeout_id > 0) {
                Source.remove(initial_reveal_timeout_id);
            }
            initial_reveal_timeout_id = GLib.Timeout.add(300, () => {
                initial_reveal_timeout_id = 0;

                if (awaiting_adaptive_layout || awaiting_frontpage_endpoints) {
                    return false;
                }

                // Front Page/My Feed route cards through category_sections_ rows, not
                // columns_row, so both need counting or this always undercounts those views.
                int article_count = 0;
                    if (window.layout_manager != null && window.layout_manager.is_using_category_sections()) {
                        var model = window.layout_manager.get_cards_for_iteration();
                        if (model != null) article_count += (int) model.get_n_items();
                    } else if (window.layout_manager != null && window.layout_manager.columns_row != null) {
                        var child = window.layout_manager.columns_row.get_first_child();
                        while (child != null) {
                            article_count++;
                            child = child.get_next_sibling();
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

                if (article_count >= 3) {
                    // Not reveal_initial_content() - it exits early once initial_phase is
                    // already false, which it can be here after an RSS timeout.
                    if (ready_or_defer(force_reveal_now)) force_reveal_now();
                } else {
                    // Too few articles yet; give it more time before revealing anyway.
                    initial_reveal_timeout_id = GLib.Timeout.add(1200, () => {
                        initial_reveal_timeout_id = 0;
                        if (awaiting_adaptive_layout || awaiting_frontpage_endpoints) {
                            return false;
                        }
                        if (ready_or_defer(force_reveal_now)) force_reveal_now();
                        return false;
                    });
                }
                return false;
            });
        }
    }

    // Marks `pic` as one the initial reveal must wait on, and increments
    // pending_images to match - on_image_loaded() only decrements for
    // pictures marked this way, so loads it was never told to wait for
    // (source logos, podcast art, sidebar icons, etc.) can't zero the
    // counter out early just by finishing first.
    public void track_pending_image(Gtk.Picture pic) {
        if (!initial_phase) return;
        pic.set_data<bool>("counts-toward-reveal", true);
        pending_images++;
    }

    public void on_image_loaded(Gtk.Picture image) {
        if (!initial_phase) return;
        if (window.image_manager != null && window.image_manager.hero_requests.get(image) != null) {
            hero_image_loaded = true;
        }
        if (!image.get_data<bool>("counts-toward-reveal")) return;
        image.set_data<bool>("counts-toward-reveal", false);
        if (pending_images > 0) pending_images--;

        if (initial_items_populated && pending_images == 0) {
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
            // Already showing an error or the empty state - nothing to append below.
            if (error_message_box != null && error_message_box.get_visible()) {
                return;
            }
            // "No more articles" under zero articles would sit alone at the top
            // of a blank page. Views that are legitimately empty (History,
            // Saved) show show_empty_message() instead; network views fall
            // through to the fetch error.
            if (article_view_is_empty()) {
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

            var end_label = new Gtk.Label("<b>No more articles</b>");
            end_label.set_use_markup(true);
            end_label.add_css_class("dim-label");
            end_label.set_margin_top(20);
            end_label.set_margin_bottom(20);
            end_label.set_halign(Gtk.Align.CENTER);
            // Avoid showing this alongside a Load More button
            if (window.article_manager != null && window.article_manager.has_load_more_button()) {
                return;
            }

            window.content_box.append(end_label);
    }
}

}
