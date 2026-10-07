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

// ArticleManager's bookkeeping, kept free of widgets so it can be unit tested.

namespace Managers {
    // Articles waiting for "load more", grouped by key (a Front Page row, or the
    // category elsewhere). Each article's key is fixed when it's queued.
    public class OverflowQueue : GLib.Object {
        private class Entry {
            public string key;
            public ArticleItem item;
        }

        private Gee.ArrayList<Entry> entries = new Gee.ArrayList<Entry>();
        private Gee.HashMap<string, int> counts = new Gee.HashMap<string, int>();

        public int size {
            get { return entries.size; }
        }

        public void add(string key, ArticleItem item) {
            var entry = new Entry();
            entry.key = key;
            entry.item = item;
            entries.add(entry);
            counts.set(key, count_for(key) + 1);
        }

        public int count_for(string key) {
            return counts.has_key(key) ? counts.get(key) : 0;
        }

        // Removes and returns up to `max` articles, oldest first.
        public Gee.ArrayList<ArticleItem> take(int max) {
            var taken = new Gee.ArrayList<ArticleItem>();
            while (taken.size < max && entries.size > 0) taken.add(remove_entry(0));
            return taken;
        }

        // Removes and returns up to `max` articles with this key, oldest first.
        public Gee.ArrayList<ArticleItem> take_for(string key, int max) {
            var taken = new Gee.ArrayList<ArticleItem>();
            int i = 0;
            while (i < entries.size && taken.size < max) {
                if (entries[i].key == key) {
                    taken.add(remove_entry(i));
                } else {
                    i++;
                }
            }
            return taken;
        }

        public void clear() {
            entries.clear();
            counts.clear();
        }

        private ArticleItem remove_entry(int index) {
            var entry = entries.remove_at(index);
            int left = count_for(entry.key) - 1;
            if (left > 0) {
                counts.set(entry.key, left);
            } else {
                counts.unset(entry.key);
            }
            return entry.item;
        }
    }

    // Real cards placed per row this view, for per-row caps.
    public class RowCardCounts : GLib.Object {
        private Gee.HashMap<string, int> counts = new Gee.HashMap<string, int>();

        public int get_count(string key) {
            return counts.has_key(key) ? counts.get(key) : 0;
        }

        public void add(string key) {
            counts.set(key, get_count(key) + 1);
        }

        // Counts a card for `key` unless the row already holds `cap`. False if full.
        public bool try_claim(string key, int cap) {
            if (get_count(key) >= cap) return false;
            add(key);
            return true;
        }

        public void clear() {
            counts.clear();
        }
    }

    public class RecommendedPick {
        public ArticleItem item;
        public double score;
        // Source name before normalization, for row caps if it's evicted.
        public string? raw_source_name;

        public RecommendedPick(ArticleItem item, double score, string? raw_source_name = null) {
            this.item = item;
            this.score = score;
            this.raw_source_name = raw_source_name;
        }
    }

    // "Recommended for you" candidates held during a fetch, and the rule for
    // choosing the panel from them.
    public class RecommendedShortlist {
        public const int MAX_PICKS = 8;
        public const int MAX_PER_CATEGORY = 2;
        public const int FILL_PER_CATEGORY = 4;   // looser cap, only to top up a short panel
        // A full panel plus as many dislike replacements. Bounded so the rest of
        // the Front Page still gets its normal rows.
        public const int CAPACITY = MAX_PICKS * 2;

        private Gee.ArrayList<RecommendedPick> picks = new Gee.ArrayList<RecommendedPick>();

        public int size {
            get { return picks.size; }
        }

        public bool accepts(double score) {
            return picks.size < CAPACITY || score > weakest().score;
        }

        // Holds a pick. Returns the weakest one if that put the list over capacity.
        public RecommendedPick? hold(RecommendedPick pick) {
            picks.add(pick);
            if (picks.size <= CAPACITY) return null;
            var evicted = weakest();
            picks.remove(evicted);
            return evicted;
        }

        public Gee.ArrayList<RecommendedPick> take_all() {
            var all = picks;
            picks = new Gee.ArrayList<RecommendedPick>();
            return all;
        }

        public void clear() {
            picks.clear();
        }

        private RecommendedPick weakest() {
            var weakest = picks.get(0);
            foreach (var p in picks) {
                if (p.score < weakest.score) weakest = p;
            }
            return weakest;
        }

        public static int by_score_desc(RecommendedPick a, RecommendedPick b) {
            return a.score < b.score ? 1 : (a.score > b.score ? -1 : 0);
        }

        // The same story can arrive under several URLs.
        public static string story_key(string title) {
            return title.strip().down();
        }

        // The panel's picks from `sorted` (best first): at most MAX_PER_CATEGORY
        // per category, topped up to FILL_PER_CATEGORY if that leaves gaps, one per
        // story, then trimmed to a size the panel layout can show (none if too few).
        public static Gee.ArrayList<RecommendedPick> choose(Gee.List<RecommendedPick> sorted) {
            var chosen = new Gee.ArrayList<RecommendedPick>();
            var per_category = new Gee.HashMap<string, int>();
            var chosen_titles = new Gee.HashSet<string>();
            foreach (int cap in new int[] { MAX_PER_CATEGORY, FILL_PER_CATEGORY }) {
                foreach (var pick in sorted) {
                    string cat = ArticleManager.resolve_display_category(pick.item.category_id, pick.item.source_name);
                    string title_key = story_key(pick.item.title);
                    if (chosen.size < MAX_PICKS && !chosen.contains(pick) && !chosen_titles.contains(title_key) && per_category.get(cat) < cap) {
                        chosen.add(pick);
                        chosen_titles.add(title_key);
                        per_category.set(cat, per_category.get(cat) + 1);
                    }
                }
            }
            chosen.sort(by_score_desc);
            while (chosen.size > RecommendedSection.panel_size_for(chosen.size)) chosen.remove_at(chosen.size - 1);
            return chosen;
        }
    }
}
