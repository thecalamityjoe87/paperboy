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
using Adw;

public class ShareDialog : GLib.Object {
    public static void show(string url, string? title, Gtk.Window parent_window) {
        var dialog = new Adw.Dialog();
        dialog.set_content_width(350);
        dialog.set_content_height(400);

        var content_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
        content_box.set_margin_start(24);
        content_box.set_margin_end(24);
        content_box.set_margin_top(24);
        content_box.set_margin_bottom(24);

        var title_label = new Gtk.Label("Share Article");
        title_label.add_css_class("title-2");
        title_label.set_halign(Gtk.Align.START);
        content_box.append(title_label);

        // Email section
        var email_label = new Gtk.Label("Share via email");
        email_label.add_css_class("dim-label");
        email_label.set_halign(Gtk.Align.START);
        email_label.set_margin_top(6);
        content_box.append(email_label);

        // Email
        var email_btn = create_menu_button(
            "mail-send-symbolic",
            "Send link",
            () => {
                ArticleShare.share_via_email(url, title, parent_window);
                dialog.close();
            }
        );
        content_box.append(email_btn);

        // Social media section
        var social_label = new Gtk.Label("Share on social media");
        social_label.add_css_class("dim-label");
        social_label.set_halign(Gtk.Align.START);
        social_label.set_margin_top(6);
        content_box.append(social_label);

        // Reddit
        var reddit_btn = create_menu_button(
            "reddit-mono",
            "Reddit",
            () => {
                ArticleShare.share_to_reddit(url, parent_window);
                dialog.close();
            }
        );
        content_box.append(reddit_btn);

        // Twitter/X
        var twitter_btn = create_menu_button(
            "x-mono",
            "X (Twitter)",
            () => {
                ArticleShare.share_to_twitter(url, title, parent_window);
                dialog.close();
            }
        );
        content_box.append(twitter_btn);

        // Facebook
        var facebook_btn = create_menu_button(
            "facebook-mono",
            "Facebook",
            () => {
                ArticleShare.share_to_facebook(url, parent_window);
                dialog.close();
            }
        );
        content_box.append(facebook_btn);

        // Copy link section
        var copy_label = new Gtk.Label("Share via copied link");
        copy_label.add_css_class("dim-label");
        copy_label.set_halign(Gtk.Align.START);
        copy_label.set_margin_top(6);
        content_box.append(copy_label);

        // Copy link
        var copy_btn = create_menu_button(
            "edit-copy-symbolic",
            "Copy link to clipboard",
            () => {
                ArticleShare.copy_to_clipboard(url, parent_window);
                dialog.close();
            }
        );
        content_box.append(copy_btn);

        // Cancel button at bottom
        var button_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        button_box.set_halign(Gtk.Align.END);
        button_box.set_margin_top(12);
        var cancel_btn = new Gtk.Button.with_label("Cancel");
        cancel_btn.clicked.connect(() => { dialog.close(); });
        button_box.append(cancel_btn);
        content_box.append(button_box);

        dialog.set_child(content_box);
        dialog.present(parent_window);
    }

    private static Gtk.Button create_menu_button(string icon_name, string label_text, owned VoidFunc callback) {
        var btn = new Gtk.Button();
        btn.set_halign(Gtk.Align.START);

        var box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 12);
        
        // Try to load custom icon from file first (for social media icons)
        Gtk.Image? icon = null;
        string[] custom_icons = {"reddit-mono", "x-mono", "facebook-mono"};
        bool is_custom = false;
        foreach (var custom in custom_icons) {
            if (icon_name == custom) {
                is_custom = true;
                break;
            }
        }
        
        if (is_custom) {
            // Load from file using DataPaths
            string filename = icon_name + ".svg";
            string[] candidates = {
                GLib.Path.build_filename("icons", "symbolic", "24x24", filename),
                GLib.Path.build_filename("icons", "symbolic", filename),
                GLib.Path.build_filename("icons", filename)
            };
            string? icon_path = null;
            foreach (var c in candidates) {
                icon_path = DataPathsUtils.find_data_file(c);
                if (icon_path != null) break;
            }
            
            if (icon_path != null) {
                try {
                    icon = new Gtk.Image.from_file(icon_path);
                    icon.set_pixel_size(16);
                } catch (GLib.Error e) {
                    warning("Failed to load custom icon %s: %s", icon_path, e.message);
                }
            }
        }
        
        // Fall back to icon theme if custom icon not found
        if (icon == null) {
            icon = new Gtk.Image.from_icon_name(icon_name);
        }
        
        var label = new Gtk.Label(label_text);
        label.set_halign(Gtk.Align.START);
        label.set_hexpand(true);

        box.append(icon);
        box.append(label);
        btn.set_child(box);
        btn.add_css_class("flat");

        btn.clicked.connect(() => {
            callback();
        });

        return btn;
    }

    private delegate void VoidFunc();
}
