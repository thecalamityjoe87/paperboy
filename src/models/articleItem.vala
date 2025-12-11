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

/**
 * Represents an article item with its metadata for display in the UI
 */
public class ArticleItem : GLib.Object {
    public string title { get; set; }
    public string url { get; set; }
    public string? thumbnail_url { get; set; }
    public string category_id { get; set; }
    public string? source_name { get; set; }
    public string? published { get; set; }

    public ArticleItem(string title, string url, string? thumbnail_url, string category_id, string? source_name = null, string? published = null) {
        this.title = title;
        this.url = url;
        this.thumbnail_url = thumbnail_url;
        this.category_id = category_id;
        this.source_name = source_name;
        this.published = published;
    }
}
