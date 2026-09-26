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

using GLib;

// One intraday sample from the backend's
// /news/markets/indices/{symbol}/history endpoint.
public class MarketIndexHistoryPoint : GLib.Object {
    public string symbol;
    public double price;
    public double change;
    public double change_percent;
    public string? last_updated;
    public double t; // Unix timestamp (seconds) - the chart's x-axis.
}

// The full response from that endpoint - "points" is oldest-first and may
// be empty (before market open, or before history has accumulated for the
// day yet).
public class MarketIndexHistory : GLib.Object {
    public string symbol;
    public string display_name;
    public Gee.ArrayList<MarketIndexHistoryPoint> points = new Gee.ArrayList<MarketIndexHistoryPoint>();
}
