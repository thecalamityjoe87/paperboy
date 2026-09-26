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
 * One league's badge in the Sports category's league carousel
 * (see SportsScoresController) - a colored circular badge showing that
 * league's shield logo, a "Live" pill overlaid on its corner when it has a
 * game in progress, and a short label underneath. Clicking selects the
 * badge (see set_selected()) and filters the score-card row below to just
 * that league.
 */
public class LeagueBadge : GLib.Object {
    public Gtk.Widget root;
    public signal void selected();

    private Gtk.Button button;
    private Gtk.Overlay badge_overlay;
    private Gtk.Box shape;
    private Gtk.Label live_pill;
    // Public so LeagueBadgeCarousel can center its nav buttons on the badge
    // circle itself, not the wrapper's full height (badge + caption label).
    public const int BASE_SIZE = 80;
    public const int SELECTED_SIZE = 105;
    private const int LOGO_SELECTED_SIZE = 65;
    // Corner offset for the live pill at SELECTED_SIZE (see position_pill());
    // negative pulls it out past the circle's own edge.
    private const int PILL_MARGIN_TOP = -3;
    private const int PILL_MARGIN_RIGHT = -6;
    private Gtk.Picture logo_picture;
    private Gtk.CssProvider shape_size_provider;
    private Gtk.CssProvider pill_position_provider;
    private string badge_color;

    public LeagueBadge(string league_key) {
        string display = league_key.up();

        var wrapper = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
        wrapper.set_halign(Gtk.Align.CENTER);
        // Centered (not the Box default of FILL) so badges of different
        // scales still share the same vertical center line within the
        // carousel row.
        wrapper.set_valign(Gtk.Align.CENTER);

        // badge_overlay is always allocated at the full SELECTED_SIZE
        // footprint (fixed, never changes) so the carousel row never
        // reflows - `shape` (the actual circle) is what resizes between
        // BASE_SIZE/SELECTED_SIZE within it, centered.
        //
        // A CSS `transform: scale()` on an ancestor was tried first to
        // animate the resize without triggering layout, but scaling a
        // rounded-rect + box-shadow node like this produces a real GTK/GSK
        // rendering seam - thin lines at the 0/90/180/270 degree points
        // where each corner's arc meets the straight edge, confirmed
        // visually. Real resizing (min-width/min-height, animated via a
        // plain CSS transition) doesn't rasterize-then-transform the
        // shadow, so it doesn't have this artifact.
        badge_overlay = new Gtk.Overlay();
        badge_overlay.set_halign(Gtk.Align.CENTER);
        badge_overlay.set_valign(Gtk.Align.CENTER);
        badge_overlay.set_size_request(SELECTED_SIZE, SELECTED_SIZE);

        shape = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        shape.add_css_class("league-badge");
        shape.set_halign(Gtk.Align.CENTER);
        shape.set_valign(Gtk.Align.CENTER);

        badge_color = SportsScoresService.badge_color_for(league_key);
        shape_size_provider = new Gtk.CssProvider();
        shape.get_style_context().add_provider(shape_size_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

        logo_picture = new Gtk.Picture();
        logo_picture.set_content_fit(Gtk.ContentFit.CONTAIN);
        logo_picture.set_can_shrink(true);
        logo_picture.set_halign(Gtk.Align.CENTER);
        logo_picture.set_valign(Gtk.Align.CENTER);
        shape.append(logo_picture);

        string? logo_url = SportsScoresService.logo_url_for(league_key);
        if (logo_url != null) {
            ScoreCard.load_team_logo(logo_picture, logo_url);
        }

        badge_overlay.set_child(shape);

        live_pill = new Gtk.Label("Live");
        live_pill.add_css_class("league-badge-live-pill");
        live_pill.set_halign(Gtk.Align.END);
        live_pill.set_valign(Gtk.Align.START);
        live_pill.set_visible(false);
        pill_position_provider = new Gtk.CssProvider();
        live_pill.get_style_context().add_provider(pill_position_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        badge_overlay.add_overlay(live_pill);

        apply_size(BASE_SIZE);

        button = new Gtk.Button();
        button.add_css_class("flat");
        button.add_css_class("circular");
        // Without this the button stretched to fill wrapper's own width,
        // making it wider than tall - "circular" then rendered as an oval
        // instead of a circle.
        button.set_halign(Gtk.Align.CENTER);
        button.set_child(badge_overlay);
        button.set_tooltip_text(SportsScoresService.display_name_for(league_key));
        button.clicked.connect(() => { selected(); });
        wrapper.append(button);

        var caption = new Gtk.Label(display);
        caption.add_css_class("caption");
        caption.add_css_class("dim-label");
        wrapper.append(caption);

        root = wrapper;
    }

    public void set_live(bool live) {
        live_pill.set_visible(live);
    }

    public void set_selected(bool is_selected) {
        int size = is_selected ? SELECTED_SIZE : BASE_SIZE;
        apply_size(size);
        if (is_selected) {
            shape.add_css_class("league-badge-selected");
        } else {
            shape.remove_css_class("league-badge-selected");
        }
    }

    // Real resize (animated via .league-badge's own CSS transition), not a
    // transform - see the constructor's comment for why. badge_overlay's
    // own footprint stays fixed at SELECTED_SIZE regardless, so the row
    // never reflows; `shape` just shrinks/grows centered within it.
    private void apply_size(int size) {
        try {
            shape_size_provider.load_from_data(".league-badge { background-color: %s; min-width: %dpx; min-height: %dpx; }".printf(badge_color, size, size).data);
        } catch (GLib.Error e) { }

        int logo_size = (int) Math.round(LOGO_SELECTED_SIZE * ((double) size / SELECTED_SIZE));
        logo_picture.set_size_request(logo_size, logo_size);

        position_pill(size);
    }

    // The live pill's overlay position is relative to badge_overlay's fixed
    // SELECTED_SIZE footprint, not to `shape`'s own (varying) size - so as
    // `shape` shrinks, the pill needs to move inward by half the size
    // difference on both axes to keep tracking the circle's actual edge.
    private void position_pill(int shape_size) {
        int inset = (SELECTED_SIZE - shape_size) / 2;
        try {
            pill_position_provider.load_from_data(".league-badge-live-pill { margin: %dpx %dpx 0 0; }".printf(PILL_MARGIN_TOP + inset, PILL_MARGIN_RIGHT + inset).data);
        } catch (GLib.Error e) { }
    }
}
