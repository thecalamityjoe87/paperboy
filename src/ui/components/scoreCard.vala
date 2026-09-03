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

/**
 * A single game score card for the Sports scores sections - sibling to
 * ArticleCard, not a reuse of it, since scores have no article/state-store
 * concept (no save/share/mark-read, no context menu). Reuses the ".card"
 * CSS class for consistent sizing/hover/shadow with the rest of the app.
 */
public class ScoreCard : GLib.Object {
    public const int CARD_WIDTH = 220;

    public Gtk.Box root;
    public string url;

    // Signal emitted when the card is activated (clicked/tapped)
    public signal void activated(string url);

    public ScoreCard(GameScore game) {
        GLib.Object();
        this.url = game.espn_link;

        root = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
        root.add_css_class("card");
        root.add_css_class("score-card");
        root.set_halign(Gtk.Align.START);
        // The team rows below push their score label to the far right via
        // hexpand on their name label, which otherwise bubbles all the way
        // up through this root box's own auto-computed hexpand and into the
        // section's card row - stretching each card's cell there and
        // leaving a large gap after every card (only visible once a row is
        // short enough to not already overflow the scroller, e.g. a league
        // with just a few games). Pin hexpand off here so that only affects
        // layout inside the card, not the row of cards it sits in.
        root.set_hexpand(false);
        root.set_size_request(CARD_WIDTH, -1);

        var status_row = build_status_row(game);
        root.append(status_row);

        root.append(build_team_row(game.away_team, game.away_team_abbr, game.away_logo_url, game.away_score, game.status));
        root.append(build_team_row(game.home_team, game.home_team_abbr, game.home_logo_url, game.home_score, game.status));

        var gesture = new Gtk.GestureClick();
        gesture.set_button(1);
        gesture.released.connect(() => {
            activated(url);
        });
        root.add_controller(gesture);

        var motion = new Gtk.EventControllerMotion();
        motion.enter.connect(() => { root.add_css_class("card-hover"); });
        motion.leave.connect(() => { root.remove_css_class("card-hover"); });
        root.add_controller(motion);
    }

    private Gtk.Widget build_status_row(GameScore game) {
        var label = new Gtk.Label(game.status_detail);
        label.set_xalign(0);
        label.add_css_class("caption");
        label.add_css_class("score-card-status");
        if (game.status == GameStatus.LIVE) {
            label.add_css_class("score-card-status-live");
        }
        return label;
    }

    private Gtk.Widget build_team_row(string team_name, string abbr, string? logo_url, string score, GameStatus status) {
        var row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
        row.set_hexpand(true);

        var logo = new Gtk.Picture();
        logo.set_size_request(24, 24);
        logo.set_content_fit(Gtk.ContentFit.CONTAIN);
        logo.set_can_shrink(true);
        row.append(logo);

        if (logo_url != null && logo_url.length > 0) {
            load_team_logo(logo, logo_url);
        }

        string display_name = team_name.length > 0 ? team_name : abbr;
        var name_label = new Gtk.Label(display_name);
        name_label.set_xalign(0);
        name_label.set_hexpand(true);
        name_label.set_ellipsize(Pango.EllipsizeMode.END);
        name_label.add_css_class("score-card-team");
        row.append(name_label);

        string score_text = (status == GameStatus.SCHEDULED) ? "" : score;
        var score_label = new Gtk.Label(score_text);
        score_label.set_xalign(1);
        score_label.add_css_class("score-card-score");
        row.append(score_label);

        return row;
    }

    // Team logos are small and few (max ~2 per card, ~15 cards per league
    // section) so a plain one-off fetch via the shared HTTP client is
    // enough - no need for the app's stateful image cache/defer pipeline
    // used for article thumbnails, which assumes callers pair it with
    // article-specific loading-state bookkeeping this card doesn't have.
    private void load_team_logo(Gtk.Picture picture, string logo_url) {
        var client = Paperboy.HttpClientUtils.get_default();
        client.fetch_bytes(logo_url, null, (response) => {
            if (!response.is_success() || response.body == null) return;
            try {
                var texture = Gdk.Texture.from_bytes(response.body);
                picture.set_paintable(texture);
            } catch (GLib.Error e) {
                // Missing/broken team logo - leave the placeholder blank
                // rather than failing the whole card.
            }
        });
    }
}
