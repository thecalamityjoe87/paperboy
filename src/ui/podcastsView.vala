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
 * Pure widget construction for the Podcasts page - deliberately much
 * simpler than ContentView (no adaptive layout, no search-filter
 * restoration, no multi-source buffering), since it isn't routed through
 * FetchNewsController/ArticleManager/LayoutManager at all (see
 * Managers.PodcastManager, which populates this view's containers
 * directly). Mounted as a second named child of a Gtk.Stack alongside
 * ContentView's own root (see NewsWindow's content_stack), so switching
 * pages never touches ContentView's own state.
 */
public class PodcastsView : GLib.Object {
    public Gtk.ScrolledWindow main_scrolled;
    public Gtk.Box content_box;
    public Gtk.FlowBox hero_flow;
    // Faint divider between the hero row and the category sections below,
    // matching Front Page's hero_frontpage_separator (see contentView.vala/
    // layoutManager.vala) - hidden until the first category section is
    // added, since sections populate asynchronously.
    public Gtk.Separator hero_sections_separator;
    public Gtk.Box category_sections_container;

    public Gtk.Box loading_container;
    public Gtk.Spinner loading_spinner;

    public Gtk.Box error_message_box;
    public Gtk.Label error_message_label;
    public Gtk.Button error_retry_button;

    public PodcastsView() {
        content_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 28);
        content_box.set_margin_start(24);
        content_box.set_margin_end(24);
        content_box.set_margin_top(20);
        content_box.set_margin_bottom(40);

        var title_label = new Gtk.Label("Podcasts");
        title_label.add_css_class("header-date-label");
        title_label.set_xalign(0);
        content_box.append(title_label);

        hero_flow = new Gtk.FlowBox();
        hero_flow.set_min_children_per_line(4);
        hero_flow.set_max_children_per_line(4);
        hero_flow.set_selection_mode(Gtk.SelectionMode.NONE);
        hero_flow.set_row_spacing(16);
        hero_flow.set_column_spacing(16);
        hero_flow.set_homogeneous(true);
        content_box.append(hero_flow);

        hero_sections_separator = new Gtk.Separator(Gtk.Orientation.HORIZONTAL);
        hero_sections_separator.add_css_class("section-divider");
        hero_sections_separator.set_margin_top(4);
        hero_sections_separator.set_margin_bottom(4);
        hero_sections_separator.set_visible(false);
        content_box.append(hero_sections_separator);

        category_sections_container = new Gtk.Box(Gtk.Orientation.VERTICAL, 24);
        content_box.append(category_sections_container);

        // Loading spinner, shown while the first fetch is in flight.
        loading_container = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
        loading_container.set_halign(Gtk.Align.CENTER);
        loading_container.set_valign(Gtk.Align.CENTER);
        loading_container.set_vexpand(true);
        loading_spinner = new Gtk.Spinner();
        loading_spinner.set_size_request(32, 32);
        loading_container.append(loading_spinner);
        content_box.append(loading_container);

        // Error state (e.g. paperboyBackend unreachable), same affordance
        // shape as ContentView's own error_message_box.
        error_message_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
        error_message_box.set_halign(Gtk.Align.CENTER);
        error_message_box.set_valign(Gtk.Align.CENTER);
        error_message_box.set_vexpand(true);
        error_message_box.set_visible(false);
        error_message_label = new Gtk.Label("Couldn't load podcasts.");
        error_message_label.add_css_class("title-4");
        error_message_box.append(error_message_label);
        error_retry_button = new Gtk.Button.with_label("Retry");
        error_message_box.append(error_retry_button);
        content_box.append(error_message_box);

        main_scrolled = new Gtk.ScrolledWindow();
        main_scrolled.set_vexpand(true);
        main_scrolled.set_hexpand(true);
        main_scrolled.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        main_scrolled.set_child(content_box);
    }

    public void set_loading(bool loading) {
        loading_container.set_visible(loading);
        if (loading) loading_spinner.start(); else loading_spinner.stop();
    }

    public void set_error(bool has_error) {
        error_message_box.set_visible(has_error);
    }

    // Remove every existing category section so a fresh show() call
    // rebuilds cleanly rather than appending duplicates on top.
    public void clear_category_sections() {
        Gtk.Widget? child = category_sections_container.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            category_sections_container.remove(child);
            child = next;
        }
    }

    public void clear_hero_cards() {
        Gtk.Widget? child = hero_flow.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            hero_flow.remove(child);
            child = next;
        }
    }
}
