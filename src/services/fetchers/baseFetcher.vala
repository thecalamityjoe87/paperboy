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
using Soup;

public delegate void SetLabelFunc(string text);
public delegate void ClearItemsFunc();
public delegate void AddItemFunc(string title, string url, string? thumbnail_url, string category_id, string? source_name);

public abstract class BaseFetcher : GLib.Object {
    protected SetLabelFunc set_label;
    protected ClearItemsFunc clear_items;
    protected AddItemFunc add_item;

    protected BaseFetcher(SetLabelFunc set_label_func, ClearItemsFunc clear_items_func, AddItemFunc add_item_func) {
        this.set_label = set_label_func;
        this.clear_items = clear_items_func;
        this.add_item = add_item_func;
    }

    // Abstract method that each fetcher must implement
    public abstract void fetch(string category, string search_query, Soup.Session session);

    // Get the source name for this fetcher
    public abstract string get_source_name();
}
