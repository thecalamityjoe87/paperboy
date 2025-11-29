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
    public class RssSource : GLib.Object {
        public int64 id { get; set; }
        public string name { get; set; }
        public string url { get; set; }
        public string? icon_filename { get; set; }
        public string? favicon_url { get; set; }
        public int64 created_at { get; set; }
        public int64 last_fetched_at { get; set; }

        public RssSource() {
            id = -1;
            name = "";
            url = "";
            icon_filename = null;
            favicon_url = null;
            created_at = 0;
            last_fetched_at = 0;
        }

        public RssSource.with_data(int64 id, string name, string url, string? icon_filename, int64 created_at, int64 last_fetched_at) {
            this.id = id;
            this.name = name;
            this.url = url;
            this.icon_filename = icon_filename;
            this.favicon_url = null;
            this.created_at = created_at;
            this.last_fetched_at = last_fetched_at;
        }
    }
}
