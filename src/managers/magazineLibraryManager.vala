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

// Controller for the Magazines page - renders into ContentView's shared
// category_sections_container as one CategorySection row per user-assigned
// category (same containers Podcasts/Front Page use for their own category
// rows), plus its own title/"Add Magazine" row. Owns the whole "Add
// Magazine" flow: a pasted URL is either a direct PDF (imported
// immediately) or a website (scanned for PDF links, then the user picks
// which ones to import) - see MagazineSourceScanner and
// MagazinePdfImportService.
namespace Managers {
    public class MagazineLibraryManager : GLib.Object {
        private weak NewsWindow? window;
        private weak ContentView? content_view;
        private bool add_button_wired = false;
        private bool trash_zone_wired = false;
        // Coalesces bursts of entry_added/entry_removed/entry_updated
        // signals (e.g. the link picker importing several selected PDFs,
        // each completing its own async download independently) into a
        // single rebuild. Without this, render_library()'s full clear-
        // then-rebuild of category_sections_container could re-enter while
        // GTK was still mid-allocation from a previous rebuild's freshly-
        // appended cards - observed as a segfault deep inside
        // gtk_widget_allocate/g_sequence_iter_next when several magazines
        // finished importing close together.
        private bool render_pending = false;
        // Set right before this manager calls MagazineLibraryStore.
        // reorder_entries() itself (see handle_reorder_requested()), so the
        // entries_reordered signal that call fires doesn't also trigger a
        // full schedule_render() - the widgets were already moved in place
        // surgically, and rebuilding every card from scratch on top of that
        // is exactly the "whole view refreshes" flash a drag-drop shouldn't
        // cause. A signal from anywhere else (there currently is none, but
        // the store's API doesn't guarantee that) still renders normally.
        private bool suppress_next_reorder_render = false;
        // Same idea as suppress_next_reorder_render, for a single-card
        // removal (right-click "Remove from Library", or drag-to-trash) -
        // see handle_remove_requested(). Without it, removing one card
        // from a library of dozens meant clearing and rebuilding every
        // other card just to make one of them disappear.
        private bool suppress_next_removal_render = false;

        // Tracks each currently-live card's root widget by entry_id, kept
        // in sync on every render_library() pass, so handle_reorder_
        // requested() can move the real widgets in place instead of
        // clearing and rebuilding the whole view for a single drag-drop.
        // Explicit hash/equal funcs: Gee.HashMap<int64?, V> without them
        // defaults to pointer identity on the boxed key, not value
        // equality, so has_key()/get() would never match.
        private Gee.HashMap<int64?, Gtk.Widget> live_card_roots =
            new Gee.HashMap<int64?, Gtk.Widget>((v) => { return (uint) v; }, (a, b) => { return a == b; });

        public MagazineLibraryManager(NewsWindow? window, ContentView content_view) {
            this.window = window;
            this.content_view = content_view;

            var store = Paperboy.MagazineLibraryStore.get_instance();
            store.entry_added.connect((entry) => { schedule_render(); });
            store.entry_removed.connect((id) => {
                if (suppress_next_removal_render) {
                    suppress_next_removal_render = false;
                    return;
                }
                schedule_render();
            });
            store.entry_updated.connect((entry) => { schedule_render(); });
            store.entries_reordered.connect(() => {
                if (suppress_next_reorder_render) {
                    suppress_next_reorder_render = false;
                    return;
                }
                schedule_render();
            });
        }

        private void schedule_render() {
            if (!is_showing() || render_pending) return;
            render_pending = true;
            GLib.Idle.add(() => {
                render_pending = false;
                // Re-checked here, not just in schedule_render() above - the
                // user may have navigated away from Magazines by the time
                // this idle actually runs.
                if (is_showing()) render_library();
                return false;
            });
        }

        private bool is_showing() {
            return window != null && window.prefs.category == "magazines";
        }

        public void show() {
            prepare_containers();
            if (window != null) window.update_content_header_now();
            wire_add_button();
            wire_trash_zone();
            set_header_buttons_visible(true);
            render_library();
        }

        // "Add Magazine"/"Organize" float in the page's own in-content
        // header row (date_overlay, see ContentView - same corner
        // rss_podcast_button uses), not the OS window titlebar. Wired
        // once, shown/hidden per show()/category_selected based on
        // whether Magazines is the current page.
        private void wire_add_button() {
            if (add_button_wired || content_view == null || content_view.magazine_library_add_button == null) return;
            add_button_wired = true;
            content_view.magazine_library_add_button.clicked.connect(() => {
                show_add_magazine_dialog();
            });
            if (content_view.magazine_library_organize_button != null) {
                content_view.magazine_library_organize_button.clicked.connect(() => {
                    show_organize_dialog();
                });
            }
        }

        public void set_header_buttons_visible(bool visible) {
            if (content_view == null || content_view.magazine_library_header_actions == null) return;
            content_view.magazine_library_header_actions.set_visible(visible);
        }

        // Shows the trash zone only while a card is actively being dragged
        // - passed to MagazineCard.wire_interactions as on_drag_state_changed.
        private void handle_drag_state_changed(bool dragging) {
            if (content_view == null || content_view.magazine_library_trash_revealer == null) return;
            content_view.magazine_library_trash_revealer.set_reveal_child(dragging);
        }

        // Drag a card here to remove it - see MagazineCard.wire_interactions
        // for the matching Gtk.DragSource on each card. Wired once; only
        // its visibility changes per render (see render_library()).
        private void wire_trash_zone() {
            if (trash_zone_wired || content_view == null || content_view.magazine_library_trash_zone == null) return;
            trash_zone_wired = true;

            var zone = content_view.magazine_library_trash_zone;
            var drop_target = new Gtk.DropTarget(typeof(string), Gdk.DragAction.MOVE);
            drop_target.enter.connect((x, y) => {
                zone.add_css_class("magazine-drop-target");
                return Gdk.DragAction.MOVE;
            });
            drop_target.leave.connect(() => { zone.remove_css_class("magazine-drop-target"); });
            drop_target.drop.connect((value, x, y) => {
                zone.remove_css_class("magazine-drop-target");
                string? dragged_id_str = value.get_string();
                if (dragged_id_str == null) return false;
                int64 dragged_id = int64.parse(dragged_id_str);
                handle_remove_requested(dragged_id);
                if (window != null && window.toast_manager != null) window.toast_manager.show_toast("Removed from library");
                return true;
            });
            zone.add_controller(drop_target);
        }

        // Removes a single card without a full re-render, unless it's the
        // last card in its row/grid - then just let the normal re-render
        // tear down whatever container is now empty.
        private void handle_remove_requested(int64 entry_id) {
            Gtk.Widget? widget = live_card_roots.has_key(entry_id) ? live_card_roots.get(entry_id) : null;

            if (widget == null || widget.get_parent() == null || is_only_child(widget)) {
                Paperboy.MagazineLibraryStore.get_instance().remove_entry(entry_id);
                return;
            }

            suppress_next_removal_render = true;
            live_card_roots.unset(entry_id);
            Paperboy.MagazineLibraryStore.get_instance().remove_entry(entry_id);

            if (window != null && window.animation_manager != null) {
                window.animation_manager.animate_card_exit_and_remove(widget, 0);
            } else {
                widget.unparent();
            }
        }

        private bool is_only_child(Gtk.Widget widget) {
            var parent = widget.get_parent();
            if (parent == null) return true;
            // FlowBox children are wrapped in a FlowBoxChild - check that
            // wrapper's own siblings within the flow, not this widget's.
            if (parent is Gtk.FlowBoxChild) {
                var flow_parent = parent.get_parent();
                return flow_parent != null && flow_parent.get_first_child() == parent && parent.get_next_sibling() == null;
            }
            return parent.get_first_child() == widget && widget.get_next_sibling() == null;
        }

        // Splices dragged_id out of the library's current global order and
        // back in next to target_id, then persists that as the new order
        // for every entry - this part happens regardless of whether the
        // drop landed inside the same row/grid or a different category's
        // row, since it never touches the dragged entry's own category.
        // Direction-aware the same way move_card_widget() is (see its own
        // comment for why "always before target" is wrong): whichever
        // side of target the card visually lands on, the persisted order
        // has to end up matching, or the very next render (e.g. after
        // restarting the app) would silently snap it back.
        //
        // The VISUAL update is handled two different ways depending on
        // that: if both cards share the same container (reordering within
        // one grid/row), the widgets are moved in place immediately (see
        // move_card_widget()) and the redundant re-render that would
        // otherwise follow from persisting the order is suppressed - no
        // clear-and-rebuild flash for what's visually just one card
        // sliding to a new spot. A cross-category drop can't be reflected
        // that cheaply (the dragged card would need to jump to a different
        // row entirely), so that case just falls through to the normal
        // full re-render instead.
        private void handle_reorder_requested(int64 dragged_id, int64 target_id) {
            var current = Paperboy.MagazineLibraryStore.get_instance().get_all_entries();

            int dragged_original_index = -1;
            int target_original_index = -1;
            for (int i = 0; i < current.size; i++) {
                if (current.get(i).id == dragged_id) dragged_original_index = i;
                if (current.get(i).id == target_id) target_original_index = i;
            }
            if (dragged_original_index < 0 || target_original_index < 0) return;
            bool moving_right = dragged_original_index < target_original_index;

            var ordered_ids = new Gee.ArrayList<int64?>();
            foreach (var entry in current) {
                if (entry.id == dragged_id) continue;
                ordered_ids.add(entry.id);
            }

            int target_index = 0;
            for (int i = 0; i < ordered_ids.size; i++) {
                if (ordered_ids.get(i) == target_id) { target_index = i; break; }
            }
            int insert_pos = moving_right ? target_index + 1 : target_index;
            ordered_ids.insert(insert_pos, dragged_id);

            if (move_card_widget(dragged_id, target_id)) {
                suppress_next_reorder_render = true;
            }

            Paperboy.MagazineLibraryStore.get_instance().reorder_entries(ordered_ids);
        }

        // Moves dragged_widget to sit immediately before target_widget in
        // their shared parent container, without destroying/recreating
        // either widget. Returns false (doing nothing) if either widget
        // isn't currently live or they don't share a parent - the caller
        // falls back to a full re-render in that case.
        // "Drop onto target" is direction-aware, matching how basically
        // every other drag-reorder UI behaves: dragging RIGHT past a
        // target settles the card immediately AFTER it (you're pushing it
        // past that point), dragging LEFT settles it immediately BEFORE.
        // A direction-agnostic "always insert before target" rule (tried
        // first) makes dragging a card onto its own immediate right
        // neighbor compute back to the card's own original position - a
        // silent no-op - since a card is already "immediately before" its
        // right neighbor before anything moves. That exactly matched what
        // was reported: reordering worked when dragging left, but
        // dragging onto the very next card to the right did nothing until
        // the drag went two cards over.
        private bool move_card_widget(int64 dragged_id, int64 target_id) {
            if (!live_card_roots.has_key(dragged_id) || !live_card_roots.has_key(target_id)) return false;
            var dragged_widget = live_card_roots.get(dragged_id);
            var target_widget = live_card_roots.get(target_id);
            if (dragged_widget == target_widget) return false;

            var dragged_parent = dragged_widget.get_parent();
            var target_parent = target_widget.get_parent();
            if (dragged_parent == null || target_parent == null) return false;

            // Flat grid: cards are wrapped in an auto-created
            // Gtk.FlowBoxChild, so the actual move happens by index on the
            // FlowBox itself, not on the wrapper. Both indices are read
            // BEFORE any mutation - re-querying after remove() isn't
            // guaranteed to reflect the post-removal order synchronously.
            if (content_view != null && content_view.magazine_library_flow != null
                && dragged_parent is Gtk.FlowBoxChild && target_parent is Gtk.FlowBoxChild
                && dragged_parent.get_parent() == target_parent.get_parent()) {
                var flow = content_view.magazine_library_flow;
                var dragged_wrapper = (Gtk.FlowBoxChild) dragged_parent;
                var target_wrapper = (Gtk.FlowBoxChild) target_parent;
                int target_index = target_wrapper.get_index();

                // flow.remove(dragged_widget) alone left dragged_widget
                // still parented to its old FlowBoxChild wrapper (GTK
                // CRITICAL from gtk_flow_box_child_set_child on the
                // following insert() - "child == NULL ... failed") -
                // explicitly detach it from the wrapper first via the
                // wrapper's own API, then remove the now-empty wrapper.
                dragged_wrapper.set_child(null);
                flow.remove(dragged_wrapper);

                // Inserting at target's own (pre-removal) index lands
                // dragged exactly at target's old slot either way - which
                // is "immediately before target" if dragged came from
                // later in the list (nothing before target shifted), or
                // "immediately after target" if dragged came from earlier
                // (target's own real position already shifted down by one
                // from the removal, so target's *old* index now IS one
                // past target's new position). Verified against both
                // directions, adjacent and non-adjacent, via an isolated
                // Gtk.FlowBox repro before applying here.
                flow.insert(dragged_widget, target_index);
                return true;
            }

            // Category row: card_root is CategorySection.row's direct
            // child (see CategorySection.add_card()), no wrapper. Same
            // direction-aware placement as the FlowBox branch above, via
            // Gtk.Box.reorder_child_after's anchor-widget semantics
            // instead of an index: anchor on target itself (dragged lands
            // right after it) when dragged started earlier in the row,
            // or on target's previous sibling (dragged lands right before
            // it) when dragged started later.
            if (dragged_parent is Gtk.Box && dragged_parent == target_parent) {
                bool dragged_was_before_target = false;
                Gtk.Widget? probe = dragged_widget.get_next_sibling();
                while (probe != null) {
                    if (probe == target_widget) { dragged_was_before_target = true; break; }
                    probe = probe.get_next_sibling();
                }
                Gtk.Widget? anchor = dragged_was_before_target ? target_widget : target_widget.get_prev_sibling();
                ((Gtk.Box) target_parent).reorder_child_after(dragged_widget, anchor);
                return true;
            }

            return false;
        }

        // Hides every other page's containers - render_library() then
        // decides per-call whether Magazines itself shows the flat grid or
        // category rows in category_sections_container, so both stay hidden
        // here rather than this method picking one.
        private void prepare_containers() {
            if (content_view == null) return;
            content_view.hide_all_pages();
        }

        private void clear_children(Gtk.Box box) {
            Gtk.Widget? child = box.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                box.remove(child);
                child = next;
            }
        }

        private void clear_flowbox_children(Gtk.FlowBox box) {
            Gtk.Widget? child = box.get_first_child();
            while (child != null) {
                Gtk.Widget? next = child.get_next_sibling();
                box.remove(child);
                child = next;
            }
        }

        // Entries with no category (null/blank) land in this bucket's row,
        // shown last regardless of how the other category names sort.
        private const string UNCATEGORIZED = "Uncategorized";

        private void render_library() {
            if (content_view == null) return;
            live_card_roots.clear();
            clear_children(content_view.category_sections_container);
            content_view.category_sections_container.set_visible(false);
            if (content_view.hero_frontpage_separator != null) content_view.hero_frontpage_separator.set_visible(false);
            if (content_view.magazine_library_flow != null) {
                clear_flowbox_children(content_view.magazine_library_flow);
                content_view.magazine_library_flow.set_visible(false);
            }

            var entries = Paperboy.MagazineLibraryStore.get_instance().get_all_entries();
            content_view.magazine_library_empty_label.set_visible(entries.size == 0);
            if (entries.size == 0) return;

            var by_category = new Gee.HashMap<string, Gee.ArrayList<Paperboy.MagazineEntry>>();
            foreach (var entry in entries) {
                string category = (entry.category != null && entry.category.strip().length > 0) ? entry.category.strip() : UNCATEGORIZED;
                if (!by_category.has_key(category)) by_category.set(category, new Gee.ArrayList<Paperboy.MagazineEntry>());
                by_category.get(category).add(entry);
            }

            // Nothing actually organized yet (every entry landed in the
            // Uncategorized bucket) - a flat grid, not one giant row
            // labeled "Uncategorized", is the right default. Only switch
            // to category rows once the user has assigned at least one
            // real category (via the Add dialog, a card's right-click
            // menu, or the Organize tool).
            if (by_category.size == 1 && by_category.has_key(UNCATEGORIZED)) {
                render_flat_grid(entries);
                return;
            }

            var category_names = new Gee.ArrayList<string>();
            category_names.add_all(by_category.keys);
            category_names.sort((a, b) => {
                if (a == UNCATEGORIZED && b != UNCATEGORIZED) return 1;
                if (b == UNCATEGORIZED && a != UNCATEGORIZED) return -1;
                return SortUtils.compare_titles(a, b);
            });

            content_view.category_sections_container.set_visible(true);
            // hero_frontpage_separator belongs between a hero carousel and
            // the rows below it - Magazines has no hero section above its
            // rows, so it never needs showing here (unlike Front Page/
            // Podcasts, which do).
            foreach (var category in category_names) {
                build_category_row(category, by_category.get(category));
            }
        }

        private void render_flat_grid(Gee.ArrayList<Paperboy.MagazineEntry> entries) {
            if (content_view == null || content_view.magazine_library_flow == null) return;
            content_view.magazine_library_flow.set_visible(true);

            foreach (var entry in entries) {
                var card = new MagazineCard.for_entry(entry);
                // Fills its FlowBox column - a flat grid has no other
                // rows for its cards to stay size-consistent with, so
                // letting them grow gives a fuller-looking grid.
                card.root.set_hexpand(true);
                card.root.set_halign(Gtk.Align.FILL);
                MagazineCard.wire_interactions(card.root, entry.id, (entry_id) => {
                    open_entry(entry_id);
                }, (entry_id) => {
                    handle_remove_requested(entry_id);
                    if (window != null && window.toast_manager != null) window.toast_manager.show_toast("Removed from library");
                }, (entry_id) => {
                    show_set_category_dialog(entry_id);
                }, (dragged_id, target_id) => {
                    handle_reorder_requested(dragged_id, target_id);
                }, (dragging) => {
                    handle_drag_state_changed(dragging);
                });
                live_card_roots.set(entry.id, card.root);
                content_view.magazine_library_flow.append(card.root);
            }

            if (window != null && window.animation_manager != null) {
                var anim_mgr = window.animation_manager;
                var flow = content_view.magazine_library_flow;
                GLib.Idle.add(() => {
                    var cards = new Gee.ArrayList<Gtk.Widget>();
                    Gtk.Widget? cell = flow.get_first_child();
                    while (cell != null) {
                        cards.add(cell);
                        cell = cell.get_next_sibling();
                    }
                    anim_mgr.animate_cards_entrance_batch(cards);
                    return false;
                });
            }
        }

        private void build_category_row(string category_name, Gee.ArrayList<Paperboy.MagazineEntry> category_entries) {
            if (content_view == null) return;

            var section = new CategorySection(window, category_name, "magazine:" + category_name.down());
            section.wrapper.add_css_class("frontpage-section-divider");
            content_view.category_sections_container.append(section.wrapper);

            foreach (var entry in category_entries) {
                var card = new MagazineCard.for_entry(entry);
                // Fixed at its natural 220x300 - a category row is a
                // horizontal Box in a ScrolledWindow, so this doesn't
                // actually change layout today (the row never has spare
                // width to over-allocate into anyway), but keeps card
                // size explicit and independent of the flat grid's own
                // FILL/hexpand rather than relying on that coincidence.
                card.root.set_hexpand(false);
                card.root.set_halign(Gtk.Align.CENTER);
                MagazineCard.wire_interactions(card.root, entry.id, (entry_id) => {
                    open_entry(entry_id);
                }, (entry_id) => {
                    handle_remove_requested(entry_id);
                    if (window != null && window.toast_manager != null) window.toast_manager.show_toast("Removed from library");
                }, (entry_id) => {
                    show_set_category_dialog(entry_id);
                }, (dragged_id, target_id) => {
                    handle_reorder_requested(dragged_id, target_id);
                }, (dragging) => {
                    handle_drag_state_changed(dragging);
                });
                live_card_roots.set(entry.id, card.root);
                section.add_card(card.root);
            }

            if (window != null && window.animation_manager != null) {
                var anim_mgr = window.animation_manager;
                var row = section.row;
                GLib.Idle.add(() => {
                    var cards = new Gee.ArrayList<Gtk.Widget>();
                    Gtk.Widget? child = row.get_first_child();
                    while (child != null) {
                        cards.add(child);
                        child = child.get_next_sibling();
                    }
                    anim_mgr.animate_cards_entrance_batch(cards);
                    return false;
                });
            }
        }

        private void show_set_category_dialog(int64 entry_id) {
            if (window == null) return;
            var entry = Paperboy.MagazineLibraryStore.get_instance().get_entry(entry_id);
            if (entry == null) return;

            var dialog = new Adw.MessageDialog((Gtk.Window) window, "Set Category",
                "Group \"%s\" under a category - leave blank for Uncategorized.".printf(entry.title));

            var category_entry = new Gtk.Entry();
            category_entry.set_placeholder_text("e.g. Technology, History, Comics");
            if (entry.category != null) category_entry.set_text(entry.category);
            category_entry.set_margin_top(12);
            category_entry.set_margin_bottom(12);
            dialog.set_extra_child(category_entry);

            dialog.add_response("cancel", "Cancel");
            dialog.add_response("set", "Set");
            dialog.set_response_appearance("set", Adw.ResponseAppearance.SUGGESTED);

            dialog.response.connect((response) => {
                if (response == "set") {
                    Paperboy.MagazineLibraryStore.get_instance().update_category(entry_id, category_entry.get_text().strip());
                }
                dialog.close();
            });

            dialog.present();
        }

        // Small row-state holder for show_organize_dialog() - not a
        // Gee.HashMap<int64?, Gtk.Entry> keyed by entry_id, since that
        // combination has previously misbehaved in this codebase (boxed
        // int64? keys hash/compare by pointer identity without explicit
        // hash/equal funcs, so has_key()/get() silently never match). This
        // only ever needs a plain list walked once on Save, so a small
        // holder class sidesteps the whole issue.
        private class CategoryEditRow : GLib.Object {
            public int64 entry_id;
            public Gtk.Entry field;
        }

        // Lets the user set every magazine's category from one screen,
        // rather than one at a time via each card's right-click menu -
        // useful the first time this feature is used on an existing
        // library, since entries added before it existed have no category
        // to show until one is assigned.
        private void show_organize_dialog() {
            if (window == null) return;
            var entries = Paperboy.MagazineLibraryStore.get_instance().get_all_entries();
            if (entries.size == 0) {
                if (window.toast_manager != null) window.toast_manager.show_toast("Your library is empty");
                return;
            }

            var dialog = new Adw.MessageDialog((Gtk.Window) window, "Organize Magazines",
                "Set a category for each magazine, or leave it blank for Uncategorized.");

            var scroller = new Gtk.ScrolledWindow();
            scroller.set_min_content_height(int.min(480, 56 * entries.size));
            scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);

            // Grouped by current category (blank/Uncategorized first) so
            // already-sorted magazines are easy to scan past, and the ones
            // that actually need attention float to the top.
            var sorted = new Gee.ArrayList<Paperboy.MagazineEntry>();
            sorted.add_all(entries);
            sorted.sort((a, b) => {
                string cat_a = (a.category != null) ? a.category : "";
                string cat_b = (b.category != null) ? b.category : "";
                int c = SortUtils.compare_titles(cat_a, cat_b);
                if (c != 0) return c;
                return SortUtils.compare_titles(a.title, b.title);
            });

            var list_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
            var rows = new Gee.ArrayList<CategoryEditRow>();
            foreach (var entry in sorted) {
                var row_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);

                var title_label = new Gtk.Label(entry.title);
                title_label.set_xalign(0);
                title_label.set_ellipsize(Pango.EllipsizeMode.END);
                title_label.set_hexpand(true);
                title_label.set_max_width_chars(1);
                row_box.append(title_label);

                var category_field = new Gtk.Entry();
                category_field.set_placeholder_text("Uncategorized");
                if (entry.category != null) category_field.set_text(entry.category);
                category_field.set_width_chars(16);
                row_box.append(category_field);

                var edit_row = new CategoryEditRow();
                edit_row.entry_id = entry.id;
                edit_row.field = category_field;
                rows.add(edit_row);

                list_box.append(row_box);
            }
            scroller.set_child(list_box);
            dialog.set_extra_child(scroller);

            dialog.add_response("cancel", "Cancel");
            dialog.add_response("save", "Save");
            dialog.set_response_appearance("save", Adw.ResponseAppearance.SUGGESTED);

            dialog.response.connect((response) => {
                if (response == "save") {
                    var store = Paperboy.MagazineLibraryStore.get_instance();
                    foreach (var edit_row in rows) {
                        string new_category = edit_row.field.get_text().strip();
                        store.update_category(edit_row.entry_id, new_category.length > 0 ? new_category : null);
                    }
                }
                dialog.close();
            });

            dialog.present();
        }

        private void open_entry(int64 entry_id) {
            var entry = Paperboy.MagazineLibraryStore.get_instance().get_entry(entry_id);
            if (entry == null || window == null || window.magazine_reader_sheet == null) return;
            window.magazine_reader_sheet.open_for_entry(entry);
        }

        private void show_add_magazine_dialog() {
            if (window == null) return;
            var dialog = new Adw.MessageDialog((Gtk.Window) window, "Add Magazines",
                "Enter a direct link to a PDF, a webpage that links to one or more PDFs, or choose a PDF you've already downloaded.");

            var entry_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
            entry_box.set_margin_top(12);
            entry_box.set_margin_bottom(12);

            var url_entry = new Gtk.Entry();
            url_entry.set_placeholder_text("https://example.com/your-file.pdf");
            entry_box.append(url_entry);

            var title_entry = new Gtk.Entry();
            title_entry.set_placeholder_text("Title (optional, direct PDF links/local files only)");
            entry_box.append(title_entry);

            var category_entry = new Gtk.Entry();
            category_entry.set_placeholder_text("Category (optional, e.g. Technology, History)");
            entry_box.append(category_entry);

            // Local file import - shares the title/category fields above,
            // just skips the URL field and closes this dialog immediately
            // rather than waiting for "Add" (there's no URL to type once a
            // file is picked).
            var file_button = new Gtk.Button.with_label("Choose a PDF on This Computer…");
            file_button.set_margin_top(6);
            file_button.clicked.connect(() => {
                string title = title_entry.get_text().strip();
                string category = category_entry.get_text().strip();
                dialog.close();
                show_local_file_picker(title.length > 0 ? title : null, category.length > 0 ? category : null);
            });
            entry_box.append(file_button);

            dialog.set_extra_child(entry_box);
            dialog.add_response("cancel", "Cancel");
            dialog.add_response("add", "Add");
            dialog.set_response_appearance("add", Adw.ResponseAppearance.SUGGESTED);

            dialog.response.connect((response) => {
                if (response == "add") {
                    string url = url_entry.get_text().strip();
                    string title = title_entry.get_text().strip();
                    string category = category_entry.get_text().strip();
                    if (url.length > 0) {
                        add_magazine_or_source(url, title.length > 0 ? title : null, category.length > 0 ? category : null);
                    }
                }
                dialog.close();
            });

            dialog.present();
        }

        private void show_local_file_picker(string? title_override, string? category) {
            if (window == null) return;

            var file_dialog = new Gtk.FileDialog();
            file_dialog.set_title("Choose a PDF");

            var pdf_filter = new Gtk.FileFilter();
            pdf_filter.name = "PDF files";
            pdf_filter.add_mime_type("application/pdf");
            pdf_filter.add_suffix("pdf");
            var filters = new GLib.ListStore(typeof(Gtk.FileFilter));
            filters.append(pdf_filter);
            file_dialog.set_filters(filters);
            file_dialog.set_default_filter(pdf_filter);

            file_dialog.open.begin((Gtk.Window) window, null, (obj, res) => {
                try {
                    var file = file_dialog.open.end(res);
                    if (file == null) return;
                    string? path = file.get_path();
                    if (path == null) return;
                    import_pdf_from_path(path, title_override, category);
                } catch (GLib.Error e) {
                    // Most commonly a plain user cancel, not a real
                    // failure - nothing to import either way, and no
                    // toast needed for "changed my mind and closed it".
                }
            });
        }

        public void add_magazine_or_source(string url, string? title_override, string? category = null) {
            if (window == null) return;

            if (!url.has_prefix("https://")) {
                if (window.toast_manager != null) window.toast_manager.show_toast("Only https:// links are supported");
                return;
            }

            if (looks_like_direct_pdf(url)) {
                import_pdf(url, title_override, 0, category);
                return;
            }

            // Treat it as a website: persist it as a recurring source (so
            // it can be rescanned later for newly-posted issues) and scan
            // it now for PDF links to offer in a picker.
            var store = Paperboy.MagazineLibraryStore.get_instance();
            var existing = store.get_source_by_url(url);
            Paperboy.MagazineSource source;
            if (existing != null) {
                source = existing;
            } else {
                source = new Paperboy.MagazineSource();
                source.id = Paperboy.MagazineSource.compute_id(url);
                source.website_url = url;
                source.name = UrlUtils.extract_host_from_url(url) ?? url;
                source.added_at = GLib.get_real_time() / 1000000;
                store.add_source(source);
            }

            scan_source(source, category);
        }

        public void scan_source(Paperboy.MagazineSource source, string? category = null) {
            if (window == null) return;
            if (window.toast_manager != null) window.toast_manager.show_persistent_toast("Scanning for PDFs…");

            var scanner = Paperboy.MagazineSourceScanner.get_instance();
            scanner.scan(source.website_url, window.session, (success, links, error_message) => {
                if (window == null || window.toast_manager == null) return;
                window.toast_manager.clear_persistent_toast();

                Paperboy.MagazineLibraryStore.get_instance().update_last_scanned(source.id);

                if (!success || links.size == 0) {
                    window.toast_manager.show_toast(error_message ?? "No PDF links found on that page");
                    return;
                }

                var store = Paperboy.MagazineLibraryStore.get_instance();
                var new_links = new Gee.ArrayList<Paperboy.MagazineLink>();
                foreach (var link in links) {
                    if (!store.entry_exists_for_url(link.url)) new_links.add(link);
                }

                if (new_links.size == 0) {
                    window.toast_manager.show_toast("No new PDFs found - everything's already in your library");
                    return;
                }

                show_link_picker_dialog(source, new_links, category);
            });
        }

        private void show_link_picker_dialog(Paperboy.MagazineSource source, Gee.ArrayList<Paperboy.MagazineLink> links, string? category) {
            if (window == null) return;

            var dialog = new Adw.MessageDialog((Gtk.Window) window, "Select magazines to add",
                "Found %d PDF %s on %s.".printf(links.size, links.size == 1 ? "link" : "links", source.name));

            var scroller = new Gtk.ScrolledWindow();
            scroller.set_min_content_height(int.min(360, 44 * links.size));
            scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);

            var list_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);
            var checks = new Gee.ArrayList<Gtk.CheckButton>();
            foreach (var link in links) {
                string label = link.link_text != null && link.link_text.length > 0 ? link.link_text : link.url;
                var check = new Gtk.CheckButton.with_label(label);
                check.set_active(true);
                check.set_data("link-url", link.url);
                checks.add(check);
                list_box.append(check);
            }
            scroller.set_child(list_box);
            dialog.set_extra_child(scroller);

            dialog.add_response("cancel", "Cancel");
            dialog.add_response("add", "Add Selected");
            dialog.set_response_appearance("add", Adw.ResponseAppearance.SUGGESTED);

            dialog.response.connect((response) => {
                if (response == "add") {
                    foreach (var check in checks) {
                        if (!check.get_active()) continue;
                        string pdf_url = check.get_data<string>("link-url");
                        import_pdf(pdf_url, null, source.id, category);
                    }
                }
                dialog.close();
            });

            dialog.present();
        }

        private void import_pdf(string pdf_url, string? title_override, int64 source_id, string? category = null) {
            if (window == null) return;
            if (window.toast_manager != null) window.toast_manager.show_persistent_toast("Downloading magazine…");

            var service = Paperboy.MagazinePdfImportService.get_instance();
            service.import_from_url(pdf_url, title_override, source_id, window.session, (success, entry, error_message) => {
                if (window == null || window.toast_manager == null) return;
                window.toast_manager.clear_persistent_toast();

                if (success && entry != null) {
                    if (category != null && category.strip().length > 0) {
                        Paperboy.MagazineLibraryStore.get_instance().update_category(entry.id, category);
                    }
                    window.toast_manager.show_toast("Added: " + entry.title);
                } else {
                    window.toast_manager.show_toast(error_message ?? "Failed to add magazine");
                }
            });
        }

        private void import_pdf_from_path(string path, string? title_override, string? category) {
            if (window == null) return;
            if (window.toast_manager != null) window.toast_manager.show_persistent_toast("Adding magazines…");

            var service = Paperboy.MagazinePdfImportService.get_instance();
            service.import_from_path(path, title_override, 0, (success, entry, error_message) => {
                if (window == null || window.toast_manager == null) return;
                window.toast_manager.clear_persistent_toast();

                if (success && entry != null) {
                    if (category != null && category.strip().length > 0) {
                        Paperboy.MagazineLibraryStore.get_instance().update_category(entry.id, category);
                    }
                    window.toast_manager.show_toast("Added: " + entry.title);
                } else {
                    window.toast_manager.show_toast(error_message ?? "Failed to add magazine");
                }
            });
        }

        private bool looks_like_direct_pdf(string url) {
            string path = url;
            int q = path.index_of_char('?');
            if (q >= 0) path = path.substring(0, q);
            return path.down().has_suffix(".pdf");
        }
    }
}
