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

/**
 * One market index quote from the backend's Finnhub-backed
 * /news/markets/indices endpoint, sibling to GameScore - not an extension of
 * ArticleItem, since quotes have no title/url/thumbnail shape.
 */
public class MarketIndexQuote : GLib.Object {
    public string symbol;          // e.g. "SPY"
    public string display_name;    // e.g. "S&P 500"
    public double price;
    public double change;
    public double change_percent;
    public string? last_updated;

    public MarketIndexQuote(string symbol, string display_name) {
        this.symbol = symbol;
        this.display_name = display_name;
        this.price = 0.0;
        this.change = 0.0;
        this.change_percent = 0.0;
        this.last_updated = null;
    }
}
