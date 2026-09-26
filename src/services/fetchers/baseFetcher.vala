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
public delegate void AddItemFunc(string title, string url, string? thumbnail_url, string category_id, string? source_name, string? published = null, string? snippet = null);
public delegate void FetchDoneFunc();

public abstract class BaseFetcher : GLib.Object {
    // Bound to the view session that started this fetch; output is dropped once it closes.
    protected FetchSink sink;

    protected BaseFetcher(FetchSink sink) {
        this.sink = sink;
    }

    protected GLib.Cancellable? cancellable { get { return sink.cancellable; } }

    protected void set_label(string text) { sink.set_label(text); }
    protected void clear_items() { sink.clear_items(); }
    protected void add_item(string title, string url, string? thumbnail_url, string category_id, string? source_name, string? published = null, string? snippet = null) {
        if (caches_for_search) {
            Paperboy.RssArticleCache.get_instance().cache_article(
                url, title, thumbnail_url, published,
                "fetcher:%s:%s".printf(get_source_name(), category_id),
                source_name, null, category_id
            );
        }
        sink.add_item(title, url, thumbnail_url, category_id, source_name, published, snippet);
    }
    // Global search only reads RssArticleCache; RSS-based fetchers already write to it.
    protected virtual bool caches_for_search { get { return true; } }
    // Fires once a fetch's network request has concluded, success or not.
    protected void done() { sink.done(); }

    // Abstract method that each fetcher must implement
    public abstract void fetch(string category, string search_query, Soup.Session session);

    // Get the source name for this fetcher
    public abstract string get_source_name();
}
