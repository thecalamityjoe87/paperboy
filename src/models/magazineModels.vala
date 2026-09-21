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

    // A website the user has pointed Paperboy at to discover PDFs on -
    // persists so it can be rescanned later for newly-posted magazines,
    // mirroring RssSource's "followed source" idea but for PDF links
    // instead of RSS items.
    public class MagazineSource : GLib.Object {
        public int64 id;
        public string website_url;
        public string name;
        public int64 added_at;
        public int64 last_scanned_at;

        public MagazineSource() {
            id = 0;
            website_url = "";
            name = "";
            added_at = 0;
            last_scanned_at = 0;
        }

        // Deterministic and negative for the same reason as
        // PodcastFeedResolver.compute_synthetic_feed_id - no central
        // catalog assigns these ids, so one is derived from the url itself.
        public static int64 compute_id(string url) {
            return -((int64) str_hash(url));
        }
    }

    // A single imported PDF in the user's magazine library.
    public class MagazineEntry : GLib.Object {
        public int64 id;
        // 0 when added directly by PDF URL rather than discovered from a
        // MagazineSource scan.
        public int64 source_id;
        public string title;
        public string source_url;
        public string local_path;
        public string? thumbnail_path;
        public int64 added_at;
        // User-assigned, free-form (no built-in list) - null/empty means
        // uncategorized. See MagazineLibraryManager's category row grouping.
        public string? category;
        // Manual drag-and-drop display order (lower sorts first) - assigned
        // to the next available value on import (new entries go to the
        // end), rewritten by MagazineLibraryStore.reorder_entries() when
        // the user drags a card to a new position.
        public int64 sort_order;

        public MagazineEntry() {
            id = 0;
            source_id = 0;
            title = "";
            source_url = "";
            local_path = "";
            thumbnail_path = null;
            added_at = 0;
            category = null;
            sort_order = 0;
        }

        public static int64 compute_id(string source_url) {
            return -((int64) str_hash(source_url));
        }
    }
}
