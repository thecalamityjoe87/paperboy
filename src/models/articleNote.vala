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

namespace Paperboy {
    // A single user-written note attached to an article's URL.
    public class ArticleNote : GLib.Object {
        public int64 id;
        public string url;
        public string title;
        public string content_html;
        public int64 created_at;
        public int64 updated_at;

        public ArticleNote(int64 id, string url, string title, string content_html, int64 created_at, int64 updated_at) {
            this.id = id;
            this.url = url;
            this.title = title;
            this.content_html = content_html;
            this.created_at = created_at;
            this.updated_at = updated_at;
        }
    }
}
