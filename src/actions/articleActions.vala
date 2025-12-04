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

namespace ArticleActions {
    // Share article via email
    public void share_via_email(string url, string? title, Gtk.Window parent_window) {
        try {
            string article_title = title ?? "Check out this article";
            string subject = Uri.escape_string(article_title, null, false);
            string body = Uri.escape_string("I thought you might find this interesting:\n\n" + url, null, false);
            string mailto_uri = "mailto:?subject=%s&body=%s".printf(subject, body);

            var launcher = new Gtk.UriLauncher(mailto_uri);
            launcher.launch.begin(parent_window, null);
        } catch (GLib.Error e) {
            warning("Failed to open email client: %s", e.message);
            show_toast(parent_window, "Could not open email client");
        }
    }

    // Share to Reddit
    public void share_to_reddit(string url, Gtk.Window parent_window) {
        try {
            string encoded_url = Uri.escape_string(url, null, false);
            string reddit_url = "https://www.reddit.com/submit?url=%s".printf(encoded_url);

            var launcher = new Gtk.UriLauncher(reddit_url);
            launcher.launch.begin(parent_window, null);
        } catch (GLib.Error e) {
            warning("Failed to open Reddit: %s", e.message);
            show_toast(parent_window, "Could not open Reddit");
        }
    }

    // Share to Twitter/X
    public void share_to_twitter(string url, string? title, Gtk.Window parent_window) {
        try {
            string article_title = title ?? "";
            string text = Uri.escape_string(article_title, null, false);
            string encoded_url = Uri.escape_string(url, null, false);
            string twitter_url = "https://twitter.com/intent/tweet?text=%s&url=%s".printf(text, encoded_url);

            var launcher = new Gtk.UriLauncher(twitter_url);
            launcher.launch.begin(parent_window, null);
        } catch (GLib.Error e) {
            warning("Failed to open Twitter: %s", e.message);
            show_toast(parent_window, "Could not open Twitter");
        }
    }

    // Share to Facebook
    public void share_to_facebook(string url, Gtk.Window parent_window) {
        try {
            string encoded_url = Uri.escape_string(url, null, false);
            string facebook_url = "https://www.facebook.com/sharer/sharer.php?u=%s".printf(encoded_url);

            var launcher = new Gtk.UriLauncher(facebook_url);
            launcher.launch.begin(parent_window, null);
        } catch (GLib.Error e) {
            warning("Failed to open Facebook: %s", e.message);
            show_toast(parent_window, "Could not open Facebook");
        }
    }

    // Copy to clipboard
    public void copy_to_clipboard(string url, Gtk.Window parent_window) {
        var clipboard = parent_window.get_clipboard();
        clipboard.set_text(url);
        show_toast(parent_window, "Link copied to clipboard");
    }

    // Helper to show toast (works with NewsWindow)
    private void show_toast(Gtk.Window window, string message) {
        if (window is NewsWindow) {
            ((NewsWindow)window).show_toast(message);
        }
    }
}
