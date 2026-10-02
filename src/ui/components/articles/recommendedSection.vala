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

/*
 * Front Page "Recommended for you" panel: a lead story (stacked HeroCard),
 * a rail of compact HistoryCard rows beside it, and a row of ArticleCards below.
 */
public class RecommendedSection : GLib.Object {
    // Lead plus at least 3 rail rows, so the rail never has to stretch.
    public const int MIN_PICKS = 4;
    public const int MAX_RAIL_ROWS = 4;
    public const int MAX_GRID_CARDS = 3;

    private const int PANEL_PADDING = 24;
    private const int GAP = 16;
    private const int RAIL_GAP = 12;
    // Lead spans 3 of 5 equal columns, the rail 2.
    private const int COLUMNS = 5;
    private const int LEAD_COLUMNS = 3;
    // A compact row's text needs ~133px.
    public const int RAIL_ROW_HEIGHT = 136;
    // Lead's text area incl. margins: category, 3-line title and time (no snippet), as measured.
    public const int LEAD_TEXT_HEIGHT = 216;
    // Card minimums stay well under the available width (cards stretch to fill), so the panel never forces a horizontal scrollbar.
    private const int MAX_GRID_CARD_MIN = 280;
    private const int MAX_RAIL_MIN = 320;

    public Gtk.Box wrapper;
    private Gtk.Box lead_slot;
    private Gtk.Box rail;
    private Gtk.Box grid;
    private Gtk.Box[] grid_slots;
    private int grid_count = 0;

    public int lead_width { get; private set; }
    public int rail_min_width { get; private set; }
    public int grid_card_min_width { get; private set; }

    public RecommendedSection(int content_width) {
        // Panel padding + border on both sides, plus a little slack.
        int inner = content_width - (PANEL_PADDING * 2) - 4;
        int column = (inner - GAP * (COLUMNS - 1)) / COLUMNS;
        lead_width = column * LEAD_COLUMNS + GAP * (LEAD_COLUMNS - 1);
        int rail_columns = COLUMNS - LEAD_COLUMNS;
        rail_min_width = int.min(column * rail_columns + GAP * (rail_columns - 1), MAX_RAIL_MIN);
        grid_card_min_width = int.min((inner - GAP * (MAX_GRID_CARDS - 1)) / MAX_GRID_CARDS, MAX_GRID_CARD_MIN);

        wrapper = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        wrapper.set_hexpand(true);
        wrapper.set_visible(false);

        var panel = new Gtk.Box(Gtk.Orientation.VERTICAL, 20);
        panel.add_css_class("recommended-panel");
        wrapper.append(panel);

        var header = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);
        var title = new Gtk.Label("RECOMMENDED FOR YOU");
        title.add_css_class("recommended-title");
        title.set_xalign(0);
        header.append(title);
        var subtitle = new Gtk.Label("Picked from the topics and sites you read");
        subtitle.add_css_class("recommended-subtitle");
        subtitle.set_xalign(0);
        header.append(subtitle);
        panel.append(header);

        // Equal columns hold the 60/40 split; a Box let long rail titles squeeze the lead.
        var top = new Gtk.Grid();
        top.set_column_homogeneous(true);
        top.set_column_spacing(GAP);
        // Card images are vexpand; don't let that stretch the panel into spare page height.
        top.set_vexpand(false);
        lead_slot = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        top.attach(lead_slot, 0, 0, LEAD_COLUMNS, 1);
        rail = new Gtk.Box(Gtk.Orientation.VERTICAL, RAIL_GAP);
        // Rows stretch evenly to the lead's height, so short rails still line up.
        rail.set_homogeneous(true);
        rail.set_valign(Gtk.Align.FILL);
        top.attach(rail, LEAD_COLUMNS, 0, COLUMNS - LEAD_COLUMNS, 1);
        panel.append(top);

        // Fixed equal slots so a short row keeps its cards at a third of the width.
        grid = new Gtk.Box(Gtk.Orientation.HORIZONTAL, GAP);
        grid.set_homogeneous(true);
        grid.set_visible(false);
        grid_slots = new Gtk.Box[MAX_GRID_CARDS];
        for (int i = 0; i < MAX_GRID_CARDS; i++) {
            grid_slots[i] = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            grid.append(grid_slots[i]);
        }
        panel.append(grid);
    }

    // Lead matches the rail's height so the two columns line up.
    public int lead_height(int rail_rows) {
        // +2 for each row card's top/bottom border.
        return rail_rows * (RAIL_ROW_HEIGHT + 2) + int.max(0, rail_rows - 1) * RAIL_GAP;
    }

    // How many of n picks go in the rail; the rest after the lead go in the grid.
    public static int rail_rows_for(int picks) {
        return picks >= 8 ? MAX_RAIL_ROWS : int.min(picks - 1, MAX_RAIL_ROWS - 1);
    }

    public void set_lead(Gtk.Widget card_root) {
        lead_slot.append(card_root);
        wrapper.set_visible(true);
    }

    public void add_rail(Gtk.Widget card_root) {
        rail.append(card_root);
    }

    public void add_grid(Gtk.Widget card_root) {
        if (grid_count >= MAX_GRID_CARDS) return;
        grid_slots[grid_count++].append(card_root);
        grid.set_visible(true);
    }
}
