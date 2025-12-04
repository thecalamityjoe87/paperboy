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
using WebKit;
using Gdk;

public class ArticleSheet : GLib.Object {
    private NewsWindow parent_window;
    private Gtk.Box container; // top-level widget added as overlay
    private Gtk.Revealer revealer;
    private Gtk.Box content_box;
    private Gtk.Button? close_btn;
    private WebKit.WebView? webview;
    private string adblock_css = "";
    private string? current_url = null;

    // Track user-content objects so we can remove them when destroying
    private WebKit.UserContentManager? user_content_manager;
    private WebKit.UserStyleSheet? adblock_sheet;

    public ArticleSheet(NewsWindow parent) {
        parent_window = parent;

        container = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        container.set_hexpand(true);
        container.set_vexpand(true);
        // Start hidden so the overlay doesn't intercept input when not in use
        container.set_visible(false);

        revealer = new Gtk.Revealer();
        revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_UP);
        revealer.set_transition_duration(800);
        revealer.set_reveal_child(false);
        revealer.set_valign(Gtk.Align.FILL);
        revealer.add_css_class("article-sheet");

        content_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        /* Let the content expand to fill the revealer; this makes the
        sheet occupy the full content window by default when opened. */
        content_box.set_hexpand(true);
        content_box.set_vexpand(true);
        // Ensure the content box uses the standard card styling (solid background)
        content_box.add_css_class("sheet");

        // Header with close and external-open buttons
        var header = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        header.set_margin_top(8);
        header.set_margin_bottom(8);
        header.set_margin_start(8);
        header.set_margin_end(8);
        header.set_hexpand(true);
        header.add_css_class("sheet-header");

        // Use a button with icon and text
        close_btn = new Gtk.Button();
        var close_content = new Adw.ButtonContent();
        close_content.set_icon_name("window-close-symbolic");
        close_content.set_label("Close");
        close_btn.set_child(close_content);
        close_btn.set_tooltip_text("Close article");
        // Keep the button as a field so it is destroyed together with the sheet
        close_btn.clicked.connect(() => { try { dismiss(); } catch (GLib.Error e) { } });
        // Insert a flexible spacer so the close button appears at the top-right
        var spacer = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        spacer.set_hexpand(true);
        header.append(spacer);
        header.append(close_btn);

        content_box.append(header);

        // Load adblock CSS from data resources (development or installed locations)
        try {
            // The project keeps the stylesheet at `data/resources/adblock.css`.
            // Use the `resources/` prefix so DataPaths finds the existing file
            // in development and installed locations.
            string? css_path = DataPaths.find_data_file("resources/adblock.css");
            if (css_path != null) {
                string contents = "";
                try { GLib.FileUtils.get_contents(css_path, out contents); } catch (GLib.Error e) { contents = ""; }
                if (contents != null) adblock_css = contents;
            }
        } catch (GLib.Error e) { adblock_css = ""; }

        // WebView: create normally and then register the adblock stylesheet
        // with its UserContentManager if possible.
        webview = new WebKit.WebView();
        try {
            if (adblock_css != null && adblock_css.length > 0) {
                try {
                    user_content_manager = webview.get_user_content_manager();
                    adblock_sheet = new WebKit.UserStyleSheet(adblock_css,
                        WebKit.UserContentInjectedFrames.ALL_FRAMES,
                        WebKit.UserStyleLevel.USER, null, null);
                    user_content_manager.add_style_sheet(adblock_sheet);
                } catch (GLib.Error e) { }
            }
        } catch (GLib.Error e) { }
        webview.set_hexpand(true);
        webview.set_vexpand(true);

        // Prevent creation of new WebView windows (popups) at the API level
        try {
            webview.create.connect((view, nav) => {
                // Returning null prevents the embedder from creating a new view
                return null;
            });
        } catch (GLib.Error e) { }

        content_box.append(webview);
        revealer.set_child(content_box);
        // When the revealer finishes hiding, hide the top-level container
        revealer.notify["reveal-child"].connect(() => {
            try {
                if (!revealer.get_reveal_child()) {
                    try { container.set_visible(false); } catch (GLib.Error e) { }
                    // When hidden, clear the WebView content so a reopened sheet doesn't
                    // briefly show the previous article while a new one loads.
                    try {
                        if (webview != null) {
                            try { webview.stop_loading(); } catch (GLib.Error _e) { }
                            try { webview.load_uri("about:blank"); } catch (GLib.Error _e) { }
                        }
                    } catch (GLib.Error e) { }
                }
            } catch (GLib.Error e) { }
        });

        container.append(revealer);

        // Close the sheet when clicking outside the content area.
        try {
            var click = new Gtk.GestureClick();
            // Ensure the gesture receives events in the capture phase so
            // clicks on other widgets (sidebar/toolbar) are seen here first
            // and can be used to dismiss the sheet.
            try { click.set_propagation_phase(Gtk.PropagationPhase.CAPTURE); } catch (GLib.Error e) { }
            container.add_controller(click);
            click.pressed.connect((g, n_press, x, y) => {
                try {
                    // Only consider outside-clicks when the sheet is currently revealed
                    try { if (!revealer.get_reveal_child()) return; } catch (GLib.Error _e) { }
                    if (content_box != null) {
                        try {
                            double cxd = 0;
                            double cyd = 0;
                            // Translate content_box origin into container coordinates
                            content_box.translate_coordinates(container, 0, 0, out cxd, out cyd);
                            int cx = (int) cxd;
                            int cy = (int) cyd;
                            int cw = content_box.get_allocated_width();
                            int ch = content_box.get_allocated_height();
                            // x,y are in container coordinates; if outside content_box, dismiss
                            if (x < (double)cx || x > (double)(cx + cw) || y < (double)cy || y > (double)(cy + ch)) {
                                try { dismiss(); } catch (GLib.Error e) { }
                            }
                        } catch (GLib.Error e) { }
                    }
                } catch (GLib.Error e) { }
            });
        } catch (GLib.Error e) { }
    }

    public Gtk.Widget get_widget() {
        return (Gtk.Widget) container;
    }

    // Return whether the sheet is currently revealed/open.
    public bool is_open() {
        try { return revealer != null ? revealer.get_reveal_child() : false; } catch (GLib.Error e) { return false; }
    }

    public void open(string url) {
        if (url == null) return;
        current_url = url;
        try {
            webview.load_uri(url);
        } catch (GLib.Error e) { }
        try {
            // Make the container visible so it can receive events for the sheet
            container.set_visible(true);
        } catch (GLib.Error e) { }
        try {
            // Ensure the transition for opening is a slide-up (sheet rising)
            revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_UP);
        } catch (GLib.Error e) { }
        try { revealer.set_reveal_child(true); } catch (GLib.Error e) { }
    }

    public void dismiss() {
        try {
            // Use slide-down when dismissing so the sheet animates downward
            revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_DOWN);
        } catch (GLib.Error e) { }
        try { revealer.set_reveal_child(false); } catch (GLib.Error e) { }
    }

    // Public destroy method to explicitly clean up resources held by the sheet.
    public void destroy() {
        try {
            if (webview != null) {
                try { webview.stop_loading(); } catch (GLib.Error e) { }
                // Remove adblock style sheet if possible
                try {
                    if (user_content_manager != null && adblock_sheet != null) {
                        user_content_manager.remove_style_sheet(adblock_sheet);
                    }
                } catch (GLib.Error e) { }
            }
        } catch (GLib.Error e) { }

        // Destroy the top-level container which will destroy children/widgets
        try {
            if (container != null) container.destroy();
        } catch (GLib.Error e) { }

        // Clear references so GC can reclaim
        webview = null;
        adblock_sheet = null;
        user_content_manager = null;
        container = null;
        revealer = null;
        content_box = null;
        close_btn = null;
        current_url = null;
        parent_window = null;
    }

    protected override void dispose() {
        // Ensure explicit cleanup when the GObject is disposed
        try { destroy(); } catch (GLib.Error e) { }
        base.dispose();
    }
}
