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

// Left-edge "browse pages" panel for MagazineReaderSheet - every page as a
// small thumbnail you can tap to jump straight to it. Poppler
// outlines/bookmarks aren't reliable enough to build a real table of
// contents from (most consumer magazine PDFs don't embed any), so this is
// a page browser instead, same idea as Apple Books/Preview's grid view,
// just docked to the edge (Gtk.Revealer, SLIDE_RIGHT) rather than modal.
//
// Doesn't touch Poppler directly - MagazineReaderSheet owns the document
// (and the mutex guarding concurrent access to it), so thumbnail pixel
// data is fetched through the render_thumbnail delegate passed into the
// constructor instead.
namespace Paperboy {
    public class MagazineTocPane : GLib.Object {
        public delegate Gdk.Pixbuf? RenderThumbnailFunc(int page_index, int thumb_width);

        public Gtk.Revealer revealer;
        public signal void page_selected(int page_index);

        private const int THUMB_WIDTH = 96;

        private owned RenderThumbnailFunc render_thumbnail_func;
        private Gtk.Box list_box;
        private Gtk.Button[] buttons;
        private Gtk.Picture[] pictures;
        private int page_count = 0;
        private int current_page = -1;
        private bool spread_mode = false;

        // Rendered thumbnails, kept across toggles/reset_for_document
        // calls within the same document - only cleared when a new
        // document loads. A null value means a render for that page is
        // already in flight, not a miss.
        private Gee.HashMap<int, Gdk.Texture> thumbnail_cache = new Gee.HashMap<int, Gdk.Texture>();
        private bool thumbnails_requested = false;
        // Bumped whenever a new document loads, so a thumbnail render left
        // over from the previous magazine knows not to touch its now-stale
        // Picture widgets (the panel is rebuilt fresh per document).
        private uint generation = 0;

        public MagazineTocPane(owned RenderThumbnailFunc render_thumbnail_func) {
            this.render_thumbnail_func = (owned) render_thumbnail_func;

            list_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
            list_box.set_margin_top(12);
            list_box.set_margin_bottom(12);
            list_box.set_margin_start(12);
            list_box.set_margin_end(12);

            var scroller = new Gtk.ScrolledWindow();
            scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
            scroller.set_vexpand(true);
            scroller.set_size_request(THUMB_WIDTH + 40, -1);
            scroller.set_child(list_box);

            var panel = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            panel.append(scroller);
            panel.append(new Gtk.Separator(Gtk.Orientation.VERTICAL));

            revealer = new Gtk.Revealer();
            revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_RIGHT);
            revealer.set_reveal_child(false);
            revealer.set_child(panel);
        }

        public bool is_open() {
            return revealer.get_reveal_child();
        }

        public void close() {
            revealer.set_reveal_child(false);
        }

        public void toggle() {
            bool now_open = !revealer.get_reveal_child();
            revealer.set_reveal_child(now_open);
            if (!now_open || thumbnails_requested) return;

            thumbnails_requested = true;
            uint gen = generation;
            for (int i = 0; i < page_count; i++) {
                if (!thumbnail_cache.has_key(i)) render_thumbnail(i, gen);
            }
        }

        // Rebuilds the button list from scratch and clears cached
        // thumbnails - call once per document, right after page_count is
        // known. Thumbnails themselves aren't rendered here; toggle()
        // kicks those off lazily the first time the panel's actually
        // opened, so a magazine you never browse the pages of doesn't pay
        // for renders nobody sees.
        public void reset_for_document(int page_count) {
            this.page_count = page_count;
            current_page = -1;
            thumbnail_cache.clear();
            thumbnails_requested = false;
            generation++;
            revealer.set_reveal_child(false);

            Gtk.Widget? child = list_box.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                list_box.remove(child);
                child = next;
            }

            buttons = new Gtk.Button[page_count];
            pictures = new Gtk.Picture[page_count];

            for (int i = 0; i < page_count; i++) {
                int target_page = i;

                var picture = new Gtk.Picture();
                picture.set_content_fit(Gtk.ContentFit.CONTAIN);
                picture.set_can_shrink(true);
                picture.set_size_request(THUMB_WIDTH, THUMB_WIDTH * 4 / 3); // typical portrait aspect - letterboxed if a page is a different shape

                var label = new Gtk.Label("%d".printf(i + 1));
                label.add_css_class("caption");

                var item_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);
                item_box.set_halign(Gtk.Align.CENTER);
                item_box.append(picture);
                item_box.append(label);

                var button = new Gtk.Button();
                button.add_css_class("flat");
                button.add_css_class("magazine-toc-item");
                button.set_child(item_box);
                button.clicked.connect(() => page_selected(target_page));

                list_box.append(button);
                buttons[i] = button;
                pictures[i] = picture;

                if (thumbnail_cache.has_key(target_page)) picture.set_paintable(thumbnail_cache[target_page]);
            }
        }

        // Highlights whichever page(s) are currently on screen - just
        // page_index in single-page mode, page_index and its spread
        // partner in spread mode.
        public void set_current_page(int page_index, bool spread_mode) {
            if (current_page == page_index && this.spread_mode == spread_mode) return;
            current_page = page_index;
            this.spread_mode = spread_mode;

            int partner = spread_mode ? page_index + 1 : -1;
            for (int i = 0; i < buttons.length; i++) {
                bool current = i == page_index || i == partner;
                if (current) buttons[i].add_css_class("magazine-toc-item-current");
                else buttons[i].remove_css_class("magazine-toc-item-current");
            }
        }

        private void render_thumbnail(int page_index, uint gen) {
            new GLib.Thread<void*>("magazine-render-thumb", () => {
                var pixbuf = render_thumbnail_func(page_index, THUMB_WIDTH);
                GLib.Idle.add(() => {
                    if (pixbuf != null) {
                        var texture = Gdk.Texture.for_pixbuf(pixbuf);
                        thumbnail_cache[page_index] = texture; // cached regardless, even if a newer document's since replaced this panel
                        if (gen == generation && page_index < pictures.length) pictures[page_index].set_paintable(texture);
                    }
                    return false;
                });
                return null;
            });
        }
    }
}
