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
    private Gtk.Box container;
    private Gtk.Revealer revealer;
    private Gtk.Box content_box;
    private Gtk.Button? close_btn;
    private Gtk.Button? back_btn;
    private Gtk.Button? forward_btn;
    private Gtk.Button? refresh_btn;
    private WebKit.WebView? webview;
    private string adblock_css = "";
    private string? current_url = null;

    private WebKit.UserContentManager? user_content_manager;
    private WebKit.UserStyleSheet? adblock_sheet;

    public signal void closed();
    private bool is_destroyed = false;

    public ArticleSheet(NewsWindow parent) {
        parent_window = parent;

        // Top-level container
        container = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        container.set_hexpand(true);
        container.set_vexpand(true);
        container.set_visible(false);

        // Revealer
        revealer = new Gtk.Revealer();
        revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_UP);
        revealer.set_transition_duration(800);
        revealer.set_reveal_child(false);
        revealer.set_valign(Gtk.Align.FILL);
        revealer.add_css_class("article-sheet");

        // Content box
        content_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        content_box.set_hexpand(true);
        content_box.set_vexpand(true);
        content_box.add_css_class("sheet");

        // Header with navigation buttons
        var header = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        header.set_margin_top(8);
        header.set_margin_bottom(8);
        header.set_margin_start(8);
        header.set_margin_end(8);
        header.set_hexpand(true);
        header.add_css_class("sheet-header");

        back_btn = new Gtk.Button.from_icon_name("go-previous-symbolic");
        back_btn.set_tooltip_text("Back");
        back_btn.set_can_focus(false);
        back_btn.clicked.connect(() => { if (!is_destroyed && webview != null) webview.go_back(); });

        forward_btn = new Gtk.Button.from_icon_name("go-next-symbolic");
        forward_btn.set_tooltip_text("Forward");
        forward_btn.set_can_focus(false);
        forward_btn.clicked.connect(() => { if (!is_destroyed && webview != null) webview.go_forward(); });

        refresh_btn = new Gtk.Button.from_icon_name("view-refresh-symbolic");
        refresh_btn.set_tooltip_text("Reload article");
        refresh_btn.clicked.connect(() => {
            if (!is_destroyed && webview != null) webview.reload();
        });
        
        var spacer = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        spacer.set_hexpand(true);

        close_btn = new Gtk.Button();
        var close_content = new Adw.ButtonContent();
        close_content.set_icon_name("window-close-symbolic");
        close_content.set_label("Close");
        close_btn.set_child(close_content);
        close_btn.set_tooltip_text("Close article");
        close_btn.clicked.connect(() => { if (!is_destroyed) dismiss(); });

        header.append(back_btn);
        header.append(forward_btn);
        header.append(refresh_btn);
        header.append(spacer);
        header.append(close_btn);

        content_box.append(header);
        revealer.set_child(content_box);
        container.append(revealer);


        // Load adblock CSS
        adblock_css = "";
        string? css_path = DataPathsUtils.find_data_file("resources/adblock.css");
        if (css_path != null) {
            try {
                GLib.FileUtils.get_contents(css_path, out adblock_css);
            } catch (GLib.Error e) {
                adblock_css = "";
            }
        } else {
            adblock_css = "";
        }

        // Clicking outside content dismisses the sheet
        var click = new Gtk.GestureClick();
        click.set_propagation_phase(Gtk.PropagationPhase.CAPTURE);
        container.add_controller(click);
        click.pressed.connect((g, n_press, x, y) => {
            if (is_destroyed || !revealer.get_reveal_child()) return;
            double cxd = 0, cyd = 0;
            content_box.translate_coordinates(container, 0, 0, out cxd, out cyd);
            int cx = (int)cxd, cy = (int)cyd, cw = content_box.get_allocated_width(), ch = content_box.get_allocated_height();
            if (x < cx || x > (cx + cw) || y < cy || y > (cy + ch)) dismiss();
        });

        // Create initial WebView
        setup_webview();

        // Hide container when revealer fully hides
        revealer.notify["reveal-child"].connect(() => {
            if (!revealer.get_reveal_child()) {
                container.set_visible(false);
                if (webview != null) {
                    webview.stop_loading(); webview.load_uri("about:blank");
                }
                closed();
            }
        });
    }

    private void update_nav_buttons() {
        if (back_btn != null) back_btn.set_sensitive(webview != null ? webview.can_go_back() : false);
        if (forward_btn != null) forward_btn.set_sensitive(webview != null ? webview.can_go_forward() : false);
    }

    private void setup_webview() {
        if (webview != null) {
            webview.stop_loading();
            if (user_content_manager != null && adblock_sheet != null) {
                user_content_manager.remove_style_sheet(adblock_sheet);
            }
            content_box.remove(webview);
            webview = null;
            user_content_manager = null;
            adblock_sheet = null;
        }

        webview = new WebKit.WebView();
        if (adblock_css.length > 0) {
            user_content_manager = webview.get_user_content_manager();
            adblock_sheet = new WebKit.UserStyleSheet(adblock_css, WebKit.UserContentInjectedFrames.ALL_FRAMES, WebKit.UserStyleLevel.USER, null, null);
            user_content_manager.add_style_sheet(adblock_sheet);
        }
        webview.set_hexpand(true);
        webview.set_vexpand(true);

        // Popup/new window handling
        webview.create.connect((view, nav) => {
            if (is_destroyed) return null;
            var new_sheet = new ArticleSheet(parent_window);
            parent_window.root_overlay.add_overlay(new_sheet.get_widget());
            new_sheet.closed.connect(() => {
                parent_window.root_overlay.remove_overlay(new_sheet.get_widget()); new_sheet.destroy();
            });
            return new_sheet.webview;
        });

        // Load state changes update navigation and refresh buttons
        webview.load_changed.connect((_) => {
            if (is_destroyed) return;
                update_nav_buttons();
                if (refresh_btn != null && webview != null) {
                    refresh_btn.set_sensitive(!webview.is_loading);
                }
        });

        // Link-click interception
        webview.decide_policy.connect((decision, decision_type) => {
            if (is_destroyed) return false;
            if (decision_type != WebKit.PolicyDecisionType.NAVIGATION_ACTION) return false;

            var nav_decision = (WebKit.NavigationPolicyDecision)decision;
            var nav_action = nav_decision.get_navigation_action();
            if (nav_action == null || nav_action.get_navigation_type() != WebKit.NavigationType.LINK_CLICKED) return false;

            bool wants_new_sheet = false;
            uint btn = nav_action.get_mouse_button();
            if (btn == 2) wants_new_sheet = true;
            var mods = nav_action.get_modifiers();
            if ((mods & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.META_MASK)) != 0) wants_new_sheet = true;

            if (!wants_new_sheet) return false;

            string? uri = null;
            uri = nav_action.get_request()?.get_uri();

            if (uri != null) {
                var new_sheet = new ArticleSheet(parent_window);
                parent_window.root_overlay.add_overlay(new_sheet.get_widget()); new_sheet.open(uri);
                new_sheet.closed.connect(() => {
                    parent_window.root_overlay.remove_overlay(new_sheet.get_widget()); new_sheet.destroy();
                });
                nav_decision.ignore();
                return true;
            }

            return false;
        });

        content_box.append(webview);
    }

    public Gtk.Widget get_widget() {
        return container;
    }

    public bool is_open() {
        return revealer.get_reveal_child();
    }

    public void open(string url) {
        if (url == null) return;
        current_url = url;
        setup_webview();
        if (webview != null) webview.load_uri(url);
        container.set_visible(true);
        revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_UP);
        revealer.set_reveal_child(true);

        Idle.add(() => { update_nav_buttons(); return false; });
    }

    public void dismiss() {
        revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_DOWN);
        revealer.set_reveal_child(false);
    }

    public void destroy() {
        is_destroyed = true;

        if (webview != null) {
            webview.stop_loading();
            if (user_content_manager != null && adblock_sheet != null) {
                user_content_manager.remove_style_sheet(adblock_sheet);
            }
        }

        container.destroy();

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
        destroy();
        base.dispose();
    }
}

