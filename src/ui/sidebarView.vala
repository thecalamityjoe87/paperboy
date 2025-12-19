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
using Gee;
using GLib;
using Cairo;

/**
 * SidebarView - Pure UI component for sidebar rendering
 * Consumes data from SidebarManager and builds GTK widgets
 */
public class SidebarView : GLib.Object {
    private NewsWindow window;
    private SidebarManager manager;
    
    // UI widgets
    private Gtk.ListBox sidebar_list;
    private Gtk.ScrolledWindow sidebar_scrolled;
    private Gtk.Revealer sidebar_revealer;
    private Adw.NavigationPage sidebar_page;
    
    // Widget tracking for updates
    private Gee.HashMap<string, Gtk.Box> icon_holders;
    private Gee.HashMap<string, Gtk.Widget> badge_widgets;
    private Gee.HashMap<string, Gtk.Widget> section_containers;
    private Gtk.Widget? currently_selected_widget = null;
    private Gtk.Button? add_rss_button = null;
    
    // Context menu
    private SidebarMenu sidebar_menu;
    
    public SidebarView(NewsWindow window, SidebarManager manager) {
        this.window = window;
        this.manager = manager;
        this.icon_holders = new Gee.HashMap<string, Gtk.Box>();
        this.badge_widgets = new Gee.HashMap<string, Gtk.Widget>();
        this.section_containers = new Gee.HashMap<string, Gtk.Widget>();
        this.sidebar_menu = new SidebarMenu(window);
        
        build_ui();
        connect_signals();
    }
    
    private void build_ui() {
        // Create list
        sidebar_list = new Gtk.ListBox();
        sidebar_list.add_css_class("navigation-sidebar");
        sidebar_list.set_selection_mode(Gtk.SelectionMode.NONE);
        sidebar_list.set_activate_on_single_click(true);
        
        // Create scrolled window
        sidebar_scrolled = new Gtk.ScrolledWindow();
        sidebar_scrolled.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        sidebar_scrolled.set_child(sidebar_list);
        
        // Create revealer
        sidebar_revealer = new Gtk.Revealer();
        sidebar_revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_RIGHT);
        sidebar_revealer.set_transition_duration(200);
        sidebar_revealer.set_reveal_child(true);
    }
    
    private void connect_signals() {
        manager.sidebar_rebuild_requested.connect(on_sidebar_rebuild_requested);
        manager.rss_source_added.connect(on_rss_source_added);
        manager.rss_source_removed.connect(on_rss_source_removed);
        manager.rss_source_updated.connect(on_rss_source_updated);
        manager.badge_updated.connect(on_badge_updated);
        manager.badge_updated_force.connect(on_badge_updated_force);
        manager.badge_placeholder_set.connect(on_badge_placeholder_set);
        manager.all_badges_refresh_requested.connect(on_all_badges_refresh);
        manager.expanded_state_changed.connect(on_expanded_state_changed);
        manager.selection_changed.connect(on_selection_changed);
    }
    
    private void on_sidebar_rebuild_requested(Gee.ArrayList<SidebarSectionData?> sections) {
        // Save scroll position
        double saved_value = 0.0;
        double saved_upper = 0.0;
        double saved_page = 0.0;
        var vadj = sidebar_scrolled.get_vadjustment();
        saved_value = vadj.get_value();
        saved_upper = vadj.get_upper();
        saved_page = vadj.get_page_size();
        
        // Clear existing rows
        clear_sidebar();
        
        // Build UI from data
        foreach (var section in sections) {
            build_section(section);
        }
        
        // Restore scroll position (clamped to valid range)
        vadj = sidebar_scrolled.get_vadjustment();
        double max_val = saved_upper - saved_page;
        if (max_val < 0) max_val = 0;
        double to_set = saved_value;
        if (to_set < 0) to_set = 0;
        if (to_set > max_val) to_set = max_val;
        vadj.set_value(to_set);
    }
    
    private void build_section(SidebarSectionData section) {
        if (section.is_expandable) {
            // Create the ExpanderRow with flat styling
            var expander = new Adw.ExpanderRow();
            expander.set_title(section.title);
            expander.set_expanded(section.is_expanded);
            expander.add_css_class("sidebar-expander");
            expander.add_css_class("flat");
            expander.set_enable_expansion(true);
            expander.set_show_enable_switch(false);

            // Store the last known expanded state to detect actual user changes
            expander.set_data("last_expanded_state", section.is_expanded);

            // Add items directly to the expander for smooth native animations
            foreach (var item in section.items) {
                Gtk.Widget item_widget;
                if (item.item_type == SidebarItemType.RSS_SOURCE) {
                    item_widget = build_rss_item_widget(item);
                } else {
                    item_widget = build_category_button(item);
                }

                // Wrap in a ListBoxRow for proper expander integration
                var row = new Gtk.ListBoxRow();
                row.set_child(item_widget);
                row.set_activatable(false);
                row.set_selectable(false);
                row.add_css_class("sidebar-expander-item");
                expander.add_row(row);
            }

            // Optional "Add RSS Feed" button
            if (section.section_id == "followed_sources") {
                var add_button = create_add_rss_button();
                var add_row = new Gtk.ListBoxRow();
                add_row.set_child(add_button);
                add_row.set_activatable(false);
                add_row.set_selectable(false);
                add_row.add_css_class("sidebar-expander-item");
                expander.add_row(add_row);
                add_rss_button = add_button;
            }

            // Track expansion state changes and notify manager
            // Use activate signal instead of notify to only catch actual user clicks
            expander.activate.connect(() => {
                manager.toggle_section_expanded(section.section_id);
            });

            // Store expander for later updates
            section_containers.set(section.section_id, expander);

            // Add ExpanderRow to the ListBox
            sidebar_list.append(expander);

        } else {
            // Non-expandable section: just append items directly
            foreach (var item in section.items) {
                sidebar_list.append(build_item_row(item));
            }
        }
    }

    private void build_expandable_header(SidebarSectionData section) {
        // DEPRECATED: This legacy function is no longer used.
        // All expandable sections now use Adw.ExpanderRow via build_section()
        // which provides smooth libadwaita animations while maintaining the flat look.
        // This function is kept only for compatibility in case external code references it.
    }
    
    private Gtk.ListBoxRow build_item_row(SidebarItemData item) {
        var row = new Adw.ActionRow();
        row.set_title(item.title);
        row.activatable = true;
        row.add_css_class("sidebar-item-row");
        
        // Create icon holder
        var icon_holder = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        icon_holder.set_hexpand(false);
        icon_holder.set_vexpand(false);
        
        var icon = CategoryIconsUtils.create_category_icon(item.icon_key);
        if (icon != null) {
            icon_holder.append(icon);
        }
        row.add_prefix(icon_holder);
        icon_holders.set(item.id, icon_holder);
        
        // Create badge
        var badge = build_badge_widget(item.unread_count,
                           item.item_type == SidebarItemType.RSS_SOURCE,
                           item.id);
        row.add_suffix(badge);
        badge_widgets.set(item.id, badge);
        
        // Store item ID for later reference
        row.set_data("item_id", item.id);
        
        // Selection state
        if (item.is_selected) {
            row.add_css_class("selected");
            currently_selected_widget = row;
        }
        
        // Click handler
        row.activated.connect(() => {
            // Close article sheet if open
            if (window.article_sheet != null) {
                window.article_sheet.dismiss();
            }
            manager.handle_item_activation(item.id, item.title);
        });
        
        row.set_can_focus(false);
        
        return row;
    }
    
    private Gtk.Widget build_category_button(SidebarItemData item) {
        var row_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        row_box.set_margin_start(12);
        row_box.set_margin_end(12);
        row_box.set_margin_top(4);
        row_box.set_margin_bottom(4);
        
        // Create icon holder
        var icon_holder = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        icon_holder.set_hexpand(false);
        icon_holder.set_vexpand(false);
        
        var icon = CategoryIconsUtils.create_category_icon(item.icon_key);
        if (icon != null) {
            icon_holder.append(icon);
        }
        row_box.append(icon_holder);
        icon_holders.set(item.id, icon_holder);
        
        var label = new Gtk.Label(item.title);
        label.set_xalign(0);
        label.set_hexpand(true);
        row_box.append(label);
        
        // Create badge
        var badge = build_badge_widget(item.unread_count, false, item.id);
        row_box.append(badge);
        badge_widgets.set(item.id, badge);
        
        var button = new Gtk.Button();
        button.set_child(row_box);
        button.add_css_class("flat");
        button.add_css_class("sidebar-item-row");
        button.set_can_focus(false);
        button.set_data("item_id", item.id);
        
        // Selection state
        if (item.is_selected) {
            button.add_css_class("selected");
            currently_selected_widget = button;
        }
        
        button.clicked.connect(() => {
            // Close article sheet if open
            if (window.article_sheet != null) {
                window.article_sheet.dismiss();
            }
            manager.handle_item_activation(item.id, item.title);
        });
        
        return button;
    }
    
    private Gtk.Widget build_rss_item_widget(SidebarItemData item) {
        var feed_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        feed_box.set_margin_start(12);
        feed_box.set_margin_end(12);
        feed_box.set_margin_top(4);
        feed_box.set_margin_bottom(4);
        
        // Create icon with proper RSS source handling
        var source_data = manager.get_rss_source_data(item.id.has_prefix("rssfeed:") ? item.id.substring(8) : "");
        Gtk.Widget icon_widget = create_rss_icon_widget(source_data);
        
        var icon_holder = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        icon_holder.add_css_class("circular-logo");
        icon_holder.set_size_request(CategoryIconsUtils.SIDEBAR_ICON_SIZE, CategoryIconsUtils.SIDEBAR_ICON_SIZE);
        icon_holder.set_valign(Gtk.Align.CENTER);
        icon_holder.set_halign(Gtk.Align.CENTER);
        icon_holder.append(icon_widget);
        feed_box.append(icon_holder);
        icon_holders.set(item.icon_key, icon_holder);
        
        var name_label = new Gtk.Label(item.title);
        if (source_data != null && source_data.display_name != null && source_data.display_name.length > 0) {
            name_label.set_text(source_data.display_name);
        }
        name_label.set_xalign(0);
        name_label.set_hexpand(true);
        name_label.set_ellipsize(Pango.EllipsizeMode.END);
        feed_box.append(name_label);
        
        // Create badge
        var badge = build_badge_widget(item.unread_count, true, item.id);
        feed_box.append(badge);
        badge_widgets.set(item.id, badge);
        
        var feed_button = new Gtk.Button();
        feed_button.set_child(feed_box);
        feed_button.set_can_focus(false);
        feed_button.add_css_class("flat");
        feed_button.add_css_class("sidebar-item-row");
        feed_button.set_data("item_id", item.id);
        feed_button.set_data("rss_url", item.id.has_prefix("rssfeed:") ? item.id.substring(8) : "");
        
        // Selection state
        if (item.is_selected) {
            feed_button.add_css_class("selected");
            currently_selected_widget = feed_button;
        }
        
        feed_button.clicked.connect(() => {
            // Close article sheet if open
            if (window.article_sheet != null) {
                window.article_sheet.dismiss();
            }
            manager.handle_item_activation(item.id, item.title);
        });
        
        // Add right-click context menu for RSS sources
        var right_click = new Gtk.GestureClick();
        right_click.set_button(3);  // Right mouse button
        right_click.pressed.connect((n_press, x, y) => {
            string url = item.id.has_prefix("rssfeed:") ? item.id.substring(8) : "";
            string name = source_data != null && source_data.display_name != null && source_data.display_name.length > 0 
                          ? source_data.display_name 
                          : item.title;
            sidebar_menu.show_for_source(feed_button, url, source_data != null ? source_data.name : item.title);
        });
        feed_button.add_controller(right_click);
        
        return feed_button;
    }
    
    private Gtk.Widget create_rss_icon_widget(RssSourceItemData? source_data) {
        int size = CategoryIconsUtils.SIDEBAR_ICON_SIZE;
        
        if (source_data == null) {
            var fallback = new Gtk.Image.from_icon_name("application-rss+xml-symbolic");
            fallback.set_pixel_size(size);
            return fallback;
        }
        
        // Priority 1: Check for saved icon file from struct data
        if (source_data.icon_path != null && source_data.icon_path.length > 0) {
            if (GLib.FileUtils.test(source_data.icon_path, GLib.FileTest.EXISTS)) {
                var probe = ImageCache.get_global().get_or_load_file("pixbuf::file:%s::%dx%d".printf(source_data.icon_path, 0, 0), source_data.icon_path, 0, 0);
                if (probe != null) {
                    int orig_w = probe.get_width();
                    int orig_h = probe.get_height();
                    double scale = 1.0;
                    if (orig_w > 0 && orig_h > 0) scale = double.max((double)size / orig_w, (double)size / orig_h);
                    int sw = (int)(orig_w * scale);
                    int sh = (int)(orig_h * scale);
                    if (sw < 1) sw = 1;
                    if (sh < 1) sh = 1;

                    var scaled_icon = ImageCache.get_global().get_or_load_file("pixbuf::file:%s::%dx%d".printf(source_data.icon_path, sw, sh), source_data.icon_path, sw, sh);

                    var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, size, size);
                    var cr = new Cairo.Context(surface);
                    int x = (size - sw) / 2;
                    int y = (size - sh) / 2;
                    Gdk.cairo_set_source_pixbuf(cr, scaled_icon, x, y);
                    cr.paint();
                    var surf_key = "pixbuf::surface:icon:%s::%dx%d".printf(source_data.icon_path, size, size);
                    var pb_surf = ImageCache.get_global().get_or_from_surface(surf_key, surface, 0, 0, size, size);

                    if (pb_surf != null) {
                        var pic = new Gtk.Picture();
                        pic.set_paintable(Gdk.Texture.for_pixbuf(pb_surf));
                        pic.set_size_request(size, size);
                        return pic;
                    }
                }
            }
        }
        
        // Priority 2: Try icon URL from struct data (metadata API logo or Google favicon)
        if (source_data.icon_url != null && source_data.icon_url.length > 0) {
            var pic = new Gtk.Picture();
            pic.set_size_request(size, size);
            if (window.image_manager != null) window.image_manager.load_image_async(pic, source_data.icon_url, size, size);
            return pic;
        }
        // Fallback: Generic RSS icon
        var fallback = new Gtk.Image.from_icon_name("application-rss+xml-symbolic");
        fallback.set_pixel_size(size);
        return fallback;
    }
    
    private Gtk.Button create_add_rss_button() {
        var button_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        button_box.set_margin_start(12);
        button_box.set_margin_end(12);
        button_box.set_margin_top(4);
        button_box.set_margin_bottom(4);
        
        var icon = new Gtk.Image.from_icon_name("list-add-symbolic");
        icon.set_pixel_size(CategoryIconsUtils.SIDEBAR_ICON_SIZE);
        button_box.append(icon);
        
        var label = new Gtk.Label("Add RSS Feed");
        label.set_xalign(0);
        label.set_hexpand(true);
        button_box.append(label);
        
        var add_button = new Gtk.Button();
        add_button.set_can_focus(false);
        add_button.set_child(button_box);
        add_button.add_css_class("flat");
        add_button.add_css_class("sidebar-item-row");
        
        add_button.clicked.connect(() => {
            show_add_rss_dialog();
        });
        
        return add_button;
    }
    
    private void show_add_rss_dialog() {
        var dialog = new Adw.MessageDialog((Gtk.Window)window, "Add RSS Feed", null);
        dialog.set_body("Enter the RSS feed URL:");
        
        var entry_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
        entry_box.set_margin_top(12);
        entry_box.set_margin_bottom(12);
        
        var url_entry = new Gtk.Entry();
        url_entry.set_placeholder_text("https://example.com/feed.xml");
        entry_box.append(url_entry);
        
        var name_entry = new Gtk.Entry();
        name_entry.set_placeholder_text("Feed name (optional)");
        entry_box.append(name_entry);
        
        dialog.set_extra_child(entry_box);
        dialog.add_response("cancel", "Cancel");
        dialog.add_response("add", "Add Feed");
        dialog.set_response_appearance("add", Adw.ResponseAppearance.SUGGESTED);
        
        dialog.response.connect((response) => {
            if (response == "add") {
                string url = url_entry.get_text().strip();
                string name = name_entry.get_text().strip();
                
                if (url.length > 0) {
                    add_rss_feed(name, url);
                }
            }
            dialog.close();
        });
        
        dialog.present();
    }
    
    private void add_rss_feed(string name, string url) {
        // Use the centralized ToastManager instead of creating Adw.Toast directly
        if (window.toast_manager != null) window.toast_manager.show_persistent_toast("Discovering feed...");

        manager.add_rss_feed(name, url, (success, discovered_name) => {
            if (window.toast_manager != null) window.toast_manager.clear_persistent_toast();

            if (success) {
                if (window.toast_manager != null) window.toast_manager.show_toast("RSS feed added: " + discovered_name);
            } else {
                if (window.toast_manager != null) window.toast_manager.show_toast("Failed to add RSS feed");
            }
        });
    }
    
    private bool is_special_category_id(string id) {
        return id == "frontpage" || id == "topten" ||
               id == "myfeed" || id == "local_news" ||
               id == "saved";
    }

    private Gtk.Widget build_badge_widget(int count, bool is_source, string item_id) {
        var label = new Gtk.Label(count > 99 ? "99+" : count.to_string());
        label.add_css_class("unread-count-badge");
        label.set_valign(Gtk.Align.CENTER);
        label.set_halign(Gtk.Align.END);
        label.set_data("unread_count", count);
        label.set_data("is_placeholder", false);
        
        var prefs = NewsPreferences.get_instance();

        bool base_flag = is_source
            ? prefs.unread_badges_sources
            : (is_special_category_id(item_id) ? prefs.unread_badges_special_categories
                                               : prefs.unread_badges_categories);

        bool should_show = prefs.unread_badges_enabled && base_flag && count > 0;
        label.set_visible(should_show);
        
        return label;
    }
    
    private void on_rss_source_added(RssSourceItemData source) {
        // Rebuild entire sidebar to maintain proper ordering
        manager.rebuild_sidebar();
    }
    
    private void on_rss_source_removed(string url) {
        // Rebuild entire sidebar
        manager.rebuild_sidebar();
    }
    
    private void on_rss_source_updated(RssSourceItemData source) {
        // Update icon for the RSS source
        string key = "rss:" + source.url;
        if (icon_holders.has_key(key)) {
            var holder = icon_holders.get(key);
            
            // Clear existing icon
            Gtk.Widget? child = holder.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                holder.remove(child);
                child = next;
            }
            
            // Create and add new icon
            var new_icon = create_rss_icon_widget(source);
            holder.append(new_icon);
        }
    }
    
    private void on_badge_updated(string item_id, int count, bool is_source) {
        if (badge_widgets.has_key(item_id)) {
            var badge = badge_widgets.get(item_id);
            if (badge is Gtk.Label) {
                var label = (Gtk.Label) badge;
                
                // Handle -1 as placeholder while waiting for initial metadata fetch
                if (count == -1) {
                    label.set_label("--");
                    label.set_data("unread_count", 0);
                    label.set_data("is_placeholder", true);

                    var prefs = NewsPreferences.get_instance();
                    bool is_special = !is_source && is_special_category_id(item_id);
                    bool base_flag = is_source
                        ? prefs.unread_badges_sources
                        : (is_special ? prefs.unread_badges_special_categories
                                      : prefs.unread_badges_categories);

                    bool should_show = prefs.unread_badges_enabled && base_flag;
                    badge.set_visible(should_show);
                } else {
                    label.set_label(count > 99 ? "99+" : count.to_string());
                    label.set_data("unread_count", count);
                    label.set_data("is_placeholder", false);

                    var prefs = NewsPreferences.get_instance();
                    bool is_special = !is_source && is_special_category_id(item_id);
                    bool base_flag = is_source
                        ? prefs.unread_badges_sources
                        : (is_special ? prefs.unread_badges_special_categories
                                      : prefs.unread_badges_categories);

                    bool should_show = prefs.unread_badges_enabled && base_flag && count > 0;
                    badge.set_visible(should_show);
                }
            }
        }
    }
    
    private void on_badge_updated_force(string item_id, int count, bool is_source) {
        // Force update badge even if showing placeholder (used to replace placeholder with final count)
        if (badge_widgets.has_key(item_id)) {
            var badge = badge_widgets.get(item_id);
            if (badge is Gtk.Label) {
                var label = (Gtk.Label) badge;
                label.set_label(count > 99 ? "99+" : count.to_string());
                label.set_data("unread_count", count);
                label.set_data("is_placeholder", false);

                var prefs = NewsPreferences.get_instance();
                bool is_special = !is_source && is_special_category_id(item_id);
                bool base_flag = is_source
                    ? prefs.unread_badges_sources
                    : (is_special ? prefs.unread_badges_special_categories
                                  : prefs.unread_badges_categories);

                bool should_show = prefs.unread_badges_enabled && base_flag && count > 0;
                badge.set_visible(should_show);
            }
        }
    }
    
    private void on_badge_placeholder_set(string item_id, bool is_source) {
        if (badge_widgets.has_key(item_id)) {
            var badge = badge_widgets.get(item_id);
            if (badge is Gtk.Label) {
                var label = (Gtk.Label) badge;
                label.set_label("--");
                label.set_data("is_placeholder", true);

                var prefs = NewsPreferences.get_instance();
                bool is_special = !is_source && is_special_category_id(item_id);
                bool base_flag = is_source
                    ? prefs.unread_badges_sources
                    : (is_special ? prefs.unread_badges_special_categories
                                  : prefs.unread_badges_categories);

                bool should_show = prefs.unread_badges_enabled && base_flag;
                badge.set_visible(should_show);
            }
        }
    }
    
    private void on_all_badges_refresh() {
        // Refresh all badges from current manager data
        // This updates both counts and visibility based on current preferences
        var sections = manager.get_sidebar_sections();
        foreach (var section in sections) {
            foreach (var item in section.items) {
                // Always update with the current count from the manager.
                // The item.unread_count is freshly computed by get_sidebar_sections()
                // so it reflects the actual unread state from ArticleStateStore.
                on_badge_updated(item.id, item.unread_count,
                                 item.item_type == SidebarItemType.RSS_SOURCE);
            }
        }
    }
    
    private void on_expanded_state_changed(string section_id, bool expanded) {
        // Update the expander's state with smooth libadwaita animation
        if (section_containers.has_key(section_id)) {
            var widget = section_containers.get(section_id);
            if (widget is Adw.ExpanderRow) {
                var exp = (Adw.ExpanderRow) widget;
                exp.set_expanded(expanded);
            } else {
                // Fallback for legacy containers
                widget.set_visible(expanded);
            }
        }
    }
    
    private void on_selection_changed(string? item_id) {
        // Clear previous selection
        if (currently_selected_widget != null) {
            currently_selected_widget.remove_css_class("selected");
            currently_selected_widget = null;
        }
        
        // Find and select new widget
        if (item_id != null) {
            // Search through all widgets to find the one with matching item_id
            find_and_select_widget(sidebar_list, item_id);
        }
    }
    
    private void find_and_select_widget(Gtk.Widget parent, string item_id) {
        if (parent is Gtk.ListBox) {
            var listbox = (Gtk.ListBox) parent;
            Gtk.Widget? child = listbox.get_first_child();
            while (child != null) {
                find_and_select_widget(child, item_id);
                child = child.get_next_sibling();
            }
        } else if (parent is Gtk.ListBoxRow) {
            var row = (Gtk.ListBoxRow) parent;
            string? stored_id = row.get_data<string>("item_id");
            if (stored_id != null && stored_id == item_id) {
                row.add_css_class("selected");
                currently_selected_widget = row;
                return;
            }
            var child = row.get_child();
            if (child != null) {
                find_and_select_widget(child, item_id);
            }
        } else if (parent is Gtk.Box) {
            var box = (Gtk.Box) parent;
            Gtk.Widget? child = box.get_first_child();
            while (child != null) {
                find_and_select_widget(child, item_id);
                child = child.get_next_sibling();
            }
        } else if (parent is Gtk.Button) {
            var button = (Gtk.Button) parent;
            string? stored_id = button.get_data<string>("item_id");
            if (stored_id != null && stored_id == item_id) {
                button.add_css_class("selected");
                currently_selected_widget = button;
                return;
            }
        }
    }
    
    public Adw.NavigationPage build_navigation_page(Adw.HeaderBar header) {
        var toolbar = new Adw.ToolbarView();
        toolbar.add_top_bar(header);
        toolbar.set_content(sidebar_scrolled);
        
        sidebar_revealer.set_child(toolbar);
        sidebar_page = new Adw.NavigationPage(sidebar_revealer, "Categories");
        return sidebar_page;
    }
    
    public Adw.NavigationPage get_page() {
        return sidebar_page;
    }
    
    public void show() {
        sidebar_revealer.set_reveal_child(true);
    }
    
    public void hide() {
        sidebar_revealer.set_reveal_child(false);
    }
    
    public void toggle() {
        sidebar_revealer.set_reveal_child(!sidebar_revealer.get_reveal_child());
    }
    
    public bool is_visible() {
        return sidebar_revealer.get_reveal_child();
    }
    
    public void set_revealed(bool revealed) {
        sidebar_revealer.set_reveal_child(revealed);
    }
    
    public void update_icons_for_theme() {
        // Rebuild icons for all tracked icon holders
        foreach (var entry in icon_holders.entries) {
            string key = entry.key;
            Gtk.Box holder = entry.value;
            
            // Clear existing icon
            Gtk.Widget? child = holder.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                holder.remove(child);
                child = next;
            }
            
            // Recreate icon
            if (key.has_prefix("rss:")) {
                // RSS source icon
                string url = key.substring(4);
                var source_data = manager.get_rss_source_data(url);
                var new_icon = create_rss_icon_widget(source_data);
                holder.append(new_icon);
            } else {
                // Category icon
                var icon = CategoryIconsUtils.create_category_icon(key);
                if (icon != null) {
                    holder.append(icon);
                }
            }
        }
    }
    
    private void clear_sidebar() {
        Gtk.Widget? child = sidebar_list.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            sidebar_list.remove(child);
            child = next;
        }
        
        icon_holders.clear();
        badge_widgets.clear();
        section_containers.clear();
        currently_selected_widget = null;
        add_rss_button = null;
    }
}
