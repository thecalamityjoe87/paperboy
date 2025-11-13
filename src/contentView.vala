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

public class ContentView : GLib.Object {
    public Gtk.ScrolledWindow main_scrolled;
    public Gtk.Box content_area;
    public Gtk.Box content_box;
    public Gtk.Box main_content_container;
    public Gtk.Box hero_container;
    public Gtk.Box featured_box;
    public Gtk.Box columns_row;
    public Gtk.Box category_icon_holder;
    public Gtk.Label category_label;
    public Gtk.Image source_logo;
    public Gtk.Label source_label;
    public Gtk.Overlay main_overlay;
    public Gtk.Box loading_container;
    public Gtk.Spinner loading_spinner;
    public Gtk.Label loading_label;
    public Gtk.Box personalized_message_box;
    public Gtk.Label personalized_message_label;
    public Gtk.Label personalized_message_sub_label;
    public Gtk.Button personalized_message_action;
    public Gtk.Box local_news_message_box;
    public Gtk.Label local_news_title;
    public Gtk.Label local_news_hint;
    public Gtk.Button local_news_button;
    public Gtk.Box error_message_box;
    public Gtk.Image error_icon;
    public Gtk.Label error_message_label;
    public Gtk.Button error_retry_button;

    public ContentView(NewsPreferences prefs) {
        // Scrolled viewport that will be pushed into the NavigationPage by the caller
        main_scrolled = new Gtk.ScrolledWindow();
        main_scrolled.set_vexpand(true);
        main_scrolled.set_hexpand(true);

        // Create a size-constraining container that responds to window size
        content_area = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        content_area.set_halign(Gtk.Align.FILL);
        content_area.set_hexpand(true);

        // Create a container for category label and grid
        content_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        content_box.set_hexpand(true);
        content_box.set_halign(Gtk.Align.FILL);

        // Create a container for category header (title + date)
        var header_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);
        header_box.set_margin_start(12);
        header_box.set_margin_end(12);
        header_box.set_margin_top(12);
        header_box.set_margin_bottom(6);

        // Create horizontal box for category label and source info
        var title_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);

        // Add category label (bigger size) - left aligned
        category_label = new Gtk.Label("World News");
        category_label.set_xalign(0);
        category_label.set_hexpand(true);
        category_label.add_css_class("heading");
        category_label.add_css_class("title-1");
        var category_attrs = new Pango.AttrList();
        category_attrs.insert(Pango.attr_scale_new(1.3));
        category_attrs.insert(Pango.attr_weight_new(Pango.Weight.BOLD));
        category_label.set_attributes(category_attrs);

        // Create a small icon holder and a title container so we can
        // display a category icon to the left of the title text.
        category_icon_holder = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);

        var cat_title_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
        cat_title_box.append(category_icon_holder);
        cat_title_box.append(category_label);
        title_row.append(cat_title_box);

        // Create source info box (logo + text) - right aligned
        var source_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        source_box.set_valign(Gtk.Align.CENTER);

        // Add source logo placeholder
        source_logo = new Gtk.Image();
        source_logo.set_pixel_size(32);
        source_logo.set_valign(Gtk.Align.CENTER);
        source_box.append(source_logo);

        // Add source label
        source_label = new Gtk.Label("The Guardian");
        source_label.set_xalign(1);
        source_label.add_css_class("dim-label");
        source_label.add_css_class("title-4");
        var source_attrs = new Pango.AttrList();
        source_attrs.insert(Pango.attr_scale_new(1.2));
        source_attrs.insert(Pango.attr_weight_new(Pango.Weight.MEDIUM));
        source_label.set_attributes(source_attrs);
        source_box.append(source_label);

        title_row.append(source_box);
        header_box.append(title_row);

        // Add current date label (smaller text)
        var date = new DateTime.now_local();
        var date_str = date.format("%A, %B %d, %Y");
        var date_label = new Gtk.Label(date_str);
        date_label.set_xalign(0);
        date_label.add_css_class("dim-label");
        date_label.add_css_class("body");
        header_box.append(date_label);

        content_box.append(header_box);

        // Create a main content container that holds both hero and columns
        main_content_container = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
        main_content_container.set_halign(Gtk.Align.FILL);
        main_content_container.set_hexpand(true);
        main_content_container.set_margin_start(12);
        main_content_container.set_margin_end(12);
        main_content_container.set_margin_top(6);
        main_content_container.set_margin_bottom(12);

        // Hero container - fill the main container width
        hero_container = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        hero_container.set_halign(Gtk.Align.FILL);
        hero_container.set_hexpand(true);

        featured_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        featured_box.set_halign(Gtk.Align.FILL);
        featured_box.set_hexpand(true);

        hero_container.append(featured_box);
        main_content_container.append(hero_container);

        // Masonry columns container - also within main container
        columns_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 12);
        columns_row.set_halign(Gtk.Align.FILL);
        columns_row.set_valign(Gtk.Align.START);
        columns_row.set_hexpand(true);
        columns_row.set_vexpand(true);
        columns_row.set_homogeneous(true);

        // Do not call rebuild_columns here; caller will arrange columns
        main_content_container.append(columns_row);

        // Create an overlay container for main content and loading spinner
        main_overlay = new Gtk.Overlay();
        main_overlay.set_child(main_content_container);

        // Loading spinner container (initially hidden) - centered over main content
        loading_container = new Gtk.Box(Gtk.Orientation.VERTICAL, 16);
        loading_container.set_halign(Gtk.Align.CENTER);
        loading_container.set_valign(Gtk.Align.CENTER);
        loading_container.set_hexpand(false);
        loading_container.set_vexpand(false);
        loading_container.set_visible(false);

        loading_spinner = new Gtk.Spinner();
        loading_spinner.set_size_request(48, 48);
        loading_container.append(loading_spinner);

        loading_label = new Gtk.Label("Loading news...");
        loading_label.add_css_class("dim-label");
        loading_label.add_css_class("title-4");
        loading_container.append(loading_label);

        // Add loading spinner as overlay on top of main content area
        main_overlay.add_overlay(loading_container);

        // Personalized feed disabled message (centered). This overlays the
        // main content area and is visible only when the personalized feed
        // option is turned off.
        personalized_message_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
        personalized_message_box.set_halign(Gtk.Align.FILL);
        personalized_message_box.set_valign(Gtk.Align.FILL);
        personalized_message_box.set_hexpand(true);
        personalized_message_box.set_vexpand(true);

        var inner_center = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        inner_center.set_hexpand(true);
        inner_center.set_vexpand(true);
        inner_center.set_halign(Gtk.Align.CENTER);
        inner_center.set_valign(Gtk.Align.CENTER);

        personalized_message_label = new Gtk.Label("");
        personalized_message_label.add_css_class("dim-label");
        personalized_message_label.add_css_class("title-4");
        personalized_message_label.set_halign(Gtk.Align.CENTER);
        personalized_message_label.set_valign(Gtk.Align.CENTER);
        try { personalized_message_label.set_justify(Gtk.Justification.CENTER); } catch (GLib.Error e) { }
        try { personalized_message_label.set_xalign(0.5f); } catch (GLib.Error e) { }
        try { personalized_message_label.set_wrap(true); } catch (GLib.Error e) { }
        try { personalized_message_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR); } catch (GLib.Error e) { }
        inner_center.append(personalized_message_label);

        personalized_message_sub_label = new Gtk.Label("");
        personalized_message_sub_label.add_css_class("dim-label");
        personalized_message_sub_label.add_css_class("caption");
        personalized_message_sub_label.set_halign(Gtk.Align.CENTER);
        personalized_message_sub_label.set_valign(Gtk.Align.CENTER);
        try { personalized_message_sub_label.set_justify(Gtk.Justification.CENTER); } catch (GLib.Error e) { }
        try { personalized_message_sub_label.set_wrap(true); } catch (GLib.Error e) { }
        try { personalized_message_sub_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR); } catch (GLib.Error e) { }
        personalized_message_sub_label.set_margin_top(6);
        personalized_message_sub_label.set_visible(false);
        inner_center.append(personalized_message_sub_label);

        personalized_message_action = new Gtk.Button.with_label("Set Source Options");
        personalized_message_action.set_halign(Gtk.Align.CENTER);
        personalized_message_action.set_valign(Gtk.Align.CENTER);
        personalized_message_action.set_margin_top(8);
        personalized_message_action.set_visible(false);
        inner_center.append(personalized_message_action);

        personalized_message_box.append(inner_center);

        // Local News overlay
        local_news_message_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
        local_news_message_box.set_halign(Gtk.Align.FILL);
        local_news_message_box.set_valign(Gtk.Align.FILL);
        local_news_message_box.set_hexpand(true);
        local_news_message_box.set_vexpand(true);

        var ln_inner = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        ln_inner.set_hexpand(true);
        ln_inner.set_vexpand(true);
        ln_inner.set_halign(Gtk.Align.CENTER);
        ln_inner.set_valign(Gtk.Align.CENTER);

        local_news_title = new Gtk.Label("To See Local News, Set Your Location in Preferences");
        local_news_title.add_css_class("title-4");
        local_news_title.add_css_class("dim-label");
        local_news_title.set_halign(Gtk.Align.CENTER);
        local_news_title.set_valign(Gtk.Align.CENTER);
        try { local_news_title.set_justify(Gtk.Justification.CENTER); } catch (GLib.Error e) { }
        try { local_news_title.set_wrap(true); } catch (GLib.Error e) { }
        ln_inner.append(local_news_title);

        local_news_hint = new Gtk.Label("Open the main menu (☰) and choose 'Set User Location' to configure your city or ZIP code.");
        local_news_hint.add_css_class("dim-label");
        local_news_hint.set_halign(Gtk.Align.CENTER);
        local_news_hint.set_valign(Gtk.Align.CENTER);
        try { local_news_hint.set_wrap(true); } catch (GLib.Error e) { }
        local_news_hint.set_margin_top(6);
        ln_inner.append(local_news_hint);

        local_news_button = new Gtk.Button.with_label("Set Location");
        local_news_button.set_halign(Gtk.Align.CENTER);
        local_news_button.set_valign(Gtk.Align.CENTER);
        local_news_button.set_margin_top(12);
        ln_inner.append(local_news_button);

        local_news_message_box.append(ln_inner);
        local_news_message_box.set_visible(false);

        // Error message overlay (for fetch failures)
        error_message_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
        error_message_box.set_halign(Gtk.Align.FILL);
        error_message_box.set_valign(Gtk.Align.FILL);
        error_message_box.set_hexpand(true);
        error_message_box.set_vexpand(true);

        var error_inner = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
        error_inner.set_hexpand(true);
        error_inner.set_vexpand(true);
        error_inner.set_halign(Gtk.Align.CENTER);
        error_inner.set_valign(Gtk.Align.CENTER);

        error_icon = new Gtk.Image.from_icon_name("dialog-error-symbolic");
        error_icon.set_pixel_size(48);
        error_icon.set_halign(Gtk.Align.CENTER);
        error_inner.append(error_icon);

        error_message_label = new Gtk.Label("Something went wrong. Try refreshing...");
        error_message_label.add_css_class("title-4");
        error_message_label.set_halign(Gtk.Align.CENTER);
        error_message_label.set_valign(Gtk.Align.CENTER);
        try { error_message_label.set_justify(Gtk.Justification.CENTER); } catch (GLib.Error e) { }
        try { error_message_label.set_wrap(true); } catch (GLib.Error e) { }
        error_inner.append(error_message_label);

        error_retry_button = new Gtk.Button.with_label("Refresh");
        error_retry_button.set_halign(Gtk.Align.CENTER);
        error_retry_button.set_valign(Gtk.Align.CENTER);
        error_retry_button.add_css_class("suggested-action");
        error_inner.append(error_retry_button);

        error_message_box.append(error_inner);
        error_message_box.set_visible(false);

        // Compose content area
        // Ensure the main content (wrapped in an overlay) is part of the
        // content box so it becomes visible inside the scrolled viewport.
        // The overlay contains the main_content_container as its child and
        // any loading overlays; append the overlay rather than the raw
        // container so overlays render correctly on top of content.
        content_box.append(main_overlay);
        content_area.append(content_box);
        main_scrolled.set_child(content_area);
    }
}
