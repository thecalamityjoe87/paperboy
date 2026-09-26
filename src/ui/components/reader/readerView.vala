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

using Gtk;
using GLib;

// One note's applied highlight - the tag driving its background color and
// the marker button/anchor placed after it, plus which TextView they're in.
// Kept so a deleted note's highlight can be undone precisely later.
private class ReaderNoteHighlight : GLib.Object {
    public Gtk.TextView tv;
    public Gtk.TextTag tag;
    public Gtk.Button marker;
}

/*
 * Distraction-free article view: renders an ExtractedArticle (title,
 * byline, hero image, body paragraphs) instead of the live webpage.
 */
public class ReaderView : GLib.Object {
    private Gtk.Stack stack;
    private Gtk.Box content_box;
    private Gtk.ScrolledWindow scroller;
    private Gtk.Box source_header_bar;
    private Gtk.Box source_header_row;
    private Gtk.Spinner spinner;
    private NewsWindow? parent_window;
    private Gtk.MenuButton settings_btn;

    private double font_scale = 1.0;
    private string font_family = "sans";
    private string color_scheme = "auto";

    // Drag-to-select autoscroll: the body text is a series of TextViews,
    // each with its own internal (disconnected) scroll adjustment, so their
    // built-in "scroll into view while selecting" never reaches the real
    // outer scroller. Tracked here from content_box, at capture phase, so
    // it still sees the pointer even once a TextView claims the drag for
    // its own text selection.
    private double pointer_x = 0;
    private double pointer_y = 0;
    private bool pointer_down = false;
    private uint autoscroll_source_id = 0;

    // One provider shared by every ReaderView instance - the settings are
    // global (backed by gschema), so there's no need for per-instance CSS.
    private static Gtk.CssProvider? style_provider = null;

    // Note-highlight bookkeeping, reset per article in clear_content().
    // Highlights are applied incrementally (never re-applied from scratch)
    // specifically so refreshing the notes panel never has to reset a
    // TextView's buffer text - doing that would wipe out any selection the
    // user currently has active, which is exactly how creating a note used
    // to silently lose its anchor.
    private Gee.HashMap<Gtk.TextView, int> anchor_shift_by_tv = new Gee.HashMap<Gtk.TextView, int>();
    // note.id -> (tv, tag, marker) for every highlight currently applied,
    // across every TextView - lets a deleted note's highlight be undone
    // immediately instead of only disappearing on the next full re-render.
    // Gee.HashMap<int64?, V> without explicit hash/equal funcs compares
    // boxed key pointers, not values - has_key()/get() would silently
    // fail for every lookup (even the exact same key right after insert),
    // so a value-based pair is required here.
    private Gee.HashMap<int64?, ReaderNoteHighlight> highlights_by_note_id = new Gee.HashMap<int64?, ReaderNoteHighlight>(
        (a) => { int64 v = a; return (uint) (v ^ (v >> 32)); },
        (a, b) => { int64 x = a; int64 y = b; return x == y; }
    );

    // Floating "add note" button shown near an active text selection, so
    // creating a note doesn't require opening the notes panel first.
    private Gtk.Popover? add_note_popover = null;
    private string? current_article_url = null;

    public ReaderView(NewsWindow? window) {
        parent_window = window;

        if (parent_window != null && parent_window.prefs != null) {
            font_scale = parent_window.prefs.reader_font_scale;
            font_family = parent_window.prefs.reader_font_family;
            color_scheme = parent_window.prefs.reader_color_scheme;
        }

        if (style_provider == null) {
            style_provider = new Gtk.CssProvider();
            Gtk.StyleContext.add_provider_for_display(
                Gdk.Display.get_default(),
                style_provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            );
        }
        apply_style();

        stack = new Gtk.Stack();
        stack.set_hexpand(true);
        stack.set_vexpand(true);

        var spinner_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
        spinner_box.set_valign(Gtk.Align.CENTER);
        spinner_box.set_halign(Gtk.Align.CENTER);
        spinner = new Gtk.Spinner();
        spinner.set_size_request(32, 32);
        spinner_box.append(spinner);
        var loading_label = new Gtk.Label("Loading reader view…");
        loading_label.add_css_class("dim-label");
        spinner_box.append(loading_label);
        stack.add_named(spinner_box, "loading");

        var error_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
        error_box.set_valign(Gtk.Align.CENTER);
        error_box.set_halign(Gtk.Align.CENTER);
        var error_label = new Gtk.Label("Couldn't extract a reader view for this article.\nTurn off reader view above to read it on the live webpage instead.");
        error_label.add_css_class("dim-label");
        error_label.set_wrap(true);
        error_label.set_justify(Gtk.Justification.CENTER);
        error_label.set_max_width_chars(40);
        error_box.append(error_label);
        stack.add_named(error_box, "error");

        scroller = new Gtk.ScrolledWindow();
        scroller.set_hexpand(true);
        scroller.set_vexpand(true);
        // Same class as content_box, so a custom color scheme's background
        // also covers the side gutters the Adw.Clamp leaves showing on wide
        // windows, instead of just the clamped text column.
        scroller.add_css_class("reader-view");

        var clamp = new Adw.Clamp();
        clamp.set_maximum_size(720);
        clamp.set_tightening_threshold(600);

        content_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 14);
        content_box.add_css_class("reader-view");
        content_box.set_margin_top(36);
        content_box.set_margin_bottom(48);
        content_box.set_margin_start(16);
        content_box.set_margin_end(16);

        clamp.set_child(content_box);

        // The source header bar is edge-to-edge across the whole scroller
        // (unlike content_box, which is width-limited by the clamp above),
        // so its own row of logo/name is wrapped in a matching clamp to
        // keep it lined up with the body text below.
        source_header_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
        source_header_row.set_margin_top(22);
        source_header_row.set_margin_bottom(22);
        var source_header_clamp = new Adw.Clamp();
        source_header_clamp.set_maximum_size(720);
        source_header_clamp.set_tightening_threshold(600);
        source_header_clamp.set_margin_start(16);
        source_header_clamp.set_margin_end(16);
        source_header_clamp.set_child(source_header_row);

        source_header_bar = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        source_header_bar.add_css_class("reader-source-header");
        source_header_bar.append(source_header_clamp);
        source_header_bar.set_visible(false);

        var content_column = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        content_column.append(source_header_bar);
        content_column.append(clamp);

        scroller.set_child(content_column);
        stack.add_named(scroller, "content");

        // Prevent the auto-created Viewport from jumping the scroll
        // position to whichever TextView regains focus (e.g. when a
        // context-menu action like Copy closes the popover).
        var viewport = scroller.get_child() as Gtk.Viewport;
        if (viewport != null) viewport.set_scroll_to_focus(false);

        // The "add note" popover is positioned at a fixed point computed
        // at show-time - scrolling would leave it pointing at stale
        // coordinates, so just hide it instead of trying to track it.
        scroller.get_vadjustment().value_changed.connect(hide_add_note_popover);

        // Same rubber-band bounce as the main feed (see ContentView.set_window()).
        var reader_vadj = scroller.get_vadjustment();
        bool reader_was_at_top = reader_vadj.get_value() <= reader_vadj.get_lower() + 0.5;
        bool reader_was_at_bottom = reader_vadj.get_value() >= reader_vadj.get_upper() - reader_vadj.get_page_size() - 0.5;
        reader_vadj.value_changed.connect(() => {
            bool at_top = reader_vadj.get_value() <= reader_vadj.get_lower() + 0.5;
            bool at_bottom = reader_vadj.get_value() >= reader_vadj.get_upper() - reader_vadj.get_page_size() - 0.5;
            if (parent_window != null && parent_window.animation_manager != null) {
                if (at_top && !reader_was_at_top) {
                    parent_window.animation_manager.bounce_scroll_edge(content_column, Managers.BounceEdge.TOP, 500.0);
                }
                if (at_bottom && !reader_was_at_bottom) {
                    parent_window.animation_manager.bounce_scroll_edge(content_column, Managers.BounceEdge.BOTTOM, 500.0);
                }
            }
            reader_was_at_top = at_top;
            reader_was_at_bottom = at_bottom;
        });

        // Catches continued overscroll once already pinned.
        var reader_scroll_controller = new Gtk.EventControllerScroll(Gtk.EventControllerScrollFlags.VERTICAL);
        reader_scroll_controller.set_propagation_phase(Gtk.PropagationPhase.CAPTURE);
        scroller.add_controller(reader_scroll_controller);
        reader_scroll_controller.scroll.connect((dx, dy) => {
            if (parent_window == null || parent_window.animation_manager == null) return false;
            bool at_top = reader_vadj.get_value() <= reader_vadj.get_lower() + 0.5;
            bool at_bottom = reader_vadj.get_value() >= reader_vadj.get_upper() - reader_vadj.get_page_size() - 0.5;
            if (dy < 0 && at_top) {
                parent_window.animation_manager.bounce_scroll_edge(content_column, Managers.BounceEdge.TOP, 500.0);
            } else if (dy > 0 && at_bottom) {
                parent_window.animation_manager.bounce_scroll_edge(content_column, Managers.BounceEdge.BOTTOM, 500.0);
            }
            return false;
        });

        setup_drag_autoscroll();
        build_settings_button();
    }

    private void setup_drag_autoscroll() {
        var motion = new Gtk.EventControllerMotion();
        motion.set_propagation_phase(Gtk.PropagationPhase.CAPTURE);
        content_box.add_controller(motion);
        motion.motion.connect((x, y) => {
            pointer_x = x;
            pointer_y = y;
        });

        // Only the primary button drives drag-autoscroll - claiming button
        // 0 (all buttons) here at capture phase was swallowing right-click
        // before the TextView's own secondary-click handling could show its
        // context menu.
        var click = new Gtk.GestureClick();
        click.set_button(Gdk.BUTTON_PRIMARY);
        click.set_propagation_phase(Gtk.PropagationPhase.CAPTURE);
        content_box.add_controller(click);
        click.pressed.connect((g, n_press, x, y) => {
            pointer_x = x;
            pointer_y = y;
            pointer_down = true;
            if (autoscroll_source_id == 0) {
                autoscroll_source_id = Timeout.add(30, on_autoscroll_tick);
            }
        });
        click.released.connect((g, n_press, x, y) => {
            pointer_down = false;
        });

        // A real click-drag-to-select causes GtkTextView's own internal
        // drag gesture to claim the button sequence, which stops the
        // GestureClick above from ever seeing "released" for it (a plain
        // click/double-click, with no meaningful drag, doesn't get
        // claimed the same way, which is why that alone worked). A
        // legacy controller observes raw events directly and isn't
        // subject to gesture claim/deny, so it fires reliably either way.
        var legacy = new Gtk.EventControllerLegacy();
        legacy.set_propagation_phase(Gtk.PropagationPhase.CAPTURE);
        content_box.add_controller(legacy);
        legacy.event.connect((event) => {
            var event_type = event.get_event_type();
            // triggers_context_menu() is only meaningful on the press event
            // (platform convention ties it to press, not release) - reading
            // it off a release event was silently always false, which is
            // why the primary-button guard below never actually filtered
            // out a right-click release. Get the button directly instead,
            // valid for both PRESS and RELEASE.
            bool is_primary = true;
            if (event_type == Gdk.EventType.BUTTON_PRESS || event_type == Gdk.EventType.BUTTON_RELEASE) {
                is_primary = ((Gdk.ButtonEvent) event).get_button() == Gdk.BUTTON_PRIMARY;
            }

            // A primary click anywhere else in the body dismisses the
            // popover (autohide used to cover this, but its grab was also
            // swallowing right-clicks before they could reach the
            // TextView's own context menu - see set_autohide(false) below).
            if (event_type == Gdk.EventType.BUTTON_PRESS && is_primary
                && add_note_popover != null && add_note_popover.get_visible()) {
                add_note_popover.popdown();
            }

            // Only the primary button drives our own "add note" popover -
            // a right-click release used to reach this too, racing our
            // popup() against GTK's native context-menu popup for the same
            // click and crashing (gtk_widget_realize on a widget not yet
            // back in a toplevel).
            if (event_type == Gdk.EventType.BUTTON_RELEASE && is_primary) {
                // The TextView's own release handling (which finalizes
                // the drag selection) hasn't necessarily run yet either -
                // same idle-defer reasoning as above.
                GLib.Idle.add(() => {
                    check_selection_for_add_note_popover();
                    return false;
                });
            }
            return false;
        });
    }

    private void check_selection_for_add_note_popover() {
        Gtk.Widget? child = content_box.get_first_child();
        while (child != null) {
            if (child is Gtk.TextView) {
                var tv = (Gtk.TextView) child;
                if (tv.get_buffer().has_selection) {
                    show_add_note_popover(tv);
                    return;
                }
            }
            child = child.get_next_sibling();
        }
        hide_add_note_popover();
    }

    private bool on_autoscroll_tick() {
        if (!pointer_down) {
            autoscroll_source_id = 0;
            return false;
        }

        double sx, sy;
        content_box.translate_coordinates(scroller, pointer_x, pointer_y, out sx, out sy);
        int visible_h = scroller.get_allocated_height();
        int margin = 32;
        var adj = scroller.get_vadjustment();

        if (sy < margin) {
            adj.set_value(double.max(adj.get_lower(), adj.get_value() - 14));
        } else if (sy > visible_h - margin) {
            adj.set_value(double.min(adj.get_upper() - adj.get_page_size(), adj.get_value() + 14));
        }

        return true;
    }

    public Gtk.Widget get_widget() {
        return stack;
    }

    // Currently selected text in whichever body TextView has a selection,
    // if any - used to anchor a new note to the exact passage the user
    // meant, since the body is split across several TextViews (see
    // flush_text_run) and selection can't span more than one of them.
    public string? get_selected_text() {
        Gtk.Widget? child = content_box.get_first_child();
        while (child != null) {
            if (child is Gtk.TextView) {
                var tv = (Gtk.TextView) child;
                Gtk.TextIter start, end;
                if (tv.get_buffer().get_selection_bounds(out start, out end)) {
                    // A selection can span across an existing note's marker
                    // button, which is a real object-replacement character
                    // (U+FFFC) in the buffer - strip it so the captured
                    // quote still matches the pristine article text.
                    string text = tv.get_buffer().get_text(start, end, false).replace("￼", "").strip();
                    if (text.length > 0) return text;
                }
            }
            child = child.get_next_sibling();
        }
        return null;
    }

    // Re-finds each note's saved quote in the current article's body text,
    // highlights it, and drops a small numbered button right after it -
    // clicking the number (not the highlight itself, which was confusing)
    // opens that note. Notes whose quote no longer appears (article
    // re-scraped, content changed) are simply skipped, not treated as an
    // error.
    //
    // This only ever adds new highlights, never resets or re-derives
    // existing ones: this method gets called on every notes-panel refresh
    // (open the panel, add/edit/remove any note), and a destructive
    // buffer.set_text() reset-then-reapply used to wipe out whatever
    // selection the user currently had active - which is exactly how
    // creating a note from a fresh selection lost its anchor, since simply
    // opening the notes panel to reach "New note" already cleared it.
    public void highlight_notes(Gee.Collection<Paperboy.ArticleNote> notes) {
        var textviews = new Gee.ArrayList<Gtk.TextView>();
        Gtk.Widget? child = content_box.get_first_child();
        while (child != null) {
            if (child is Gtk.TextView) textviews.add((Gtk.TextView) child);
            child = child.get_next_sibling();
        }

        // Stable order so numbering is consistent regardless of call order.
        var sorted_notes = new Gee.ArrayList<Paperboy.ArticleNote>();
        sorted_notes.add_all(notes);
        sorted_notes.sort((a, b) => (int) (a.id - b.id));

        foreach (var tv in textviews) {
            string? pristine = tv.get_data<string>("reader-plain-text");
            if (pristine == null) continue;

            int shift = anchor_shift_by_tv.has_key(tv) ? anchor_shift_by_tv.get(tv) : 0;

            foreach (var note in sorted_notes) {
                if (note.quote == null || note.quote.strip().length == 0) continue;
                if (highlights_by_note_id.has_key(note.id)) continue;

                int byte_idx = pristine.index_of(note.quote);
                if (byte_idx < 0) continue;

                int start_offset = pristine.substring(0, byte_idx).char_count() + shift;
                int end_offset = start_offset + note.quote.char_count();

                highlights_by_note_id.set(note.id, apply_single_highlight(tv, note, start_offset, end_offset));
                shift += 1;
            }

            anchor_shift_by_tv.set(tv, shift);
        }

        // Renumber every currently-highlighted note to stay contiguous
        // 1..N - just a label update on the existing marker buttons, not a
        // buffer change, so it's safe to do on every call. Without this,
        // numbers would only ever grow (a deleted or never-matched note
        // leaves a permanent gap).
        note_display_numbers.clear();
        int display_number = 1;
        foreach (var note in sorted_notes) {
            var entry = highlights_by_note_id.get(note.id);
            if (entry == null) continue;
            entry.marker.set_label(display_number.to_string());
            note_display_numbers.set(note.id, display_number);
            display_number++;
        }
    }

    // note.id -> in-text marker number, refreshed on every highlight_notes()
    // call, so the notes panel can show a matching badge on each card.
    private Gee.HashMap<int64?, int> note_display_numbers = new Gee.HashMap<int64?, int>(
        (a) => { int64 v = a; return (uint) (v ^ (v >> 32)); },
        (a, b) => { int64 x = a; int64 y = b; return x == y; }
    );

    public int get_note_display_number(int64 note_id) {
        return note_display_numbers.has_key(note_id) ? note_display_numbers.get(note_id) : 0;
    }

    // Undoes one note's highlight/marker immediately (e.g. on delete),
    // rather than waiting for the next highlight_notes() call - which
    // wouldn't remove it anyway, since that only ever adds highlights.
    public void remove_note_highlight(int64 note_id) {
        var entry = highlights_by_note_id.get(note_id);
        if (entry == null) return;

        var buffer = entry.tv.get_buffer();
        Gtk.TextIter buf_start, buf_end;
        buffer.get_bounds(out buf_start, out buf_end);
        buffer.remove_tag(entry.tag, buf_start, buf_end);
        entry.marker.set_visible(false);

        highlights_by_note_id.unset(note_id);
    }

    private ReaderNoteHighlight apply_single_highlight(Gtk.TextView tv, Paperboy.ArticleNote note, int start_offset, int end_offset) {
        var buffer = tv.get_buffer();

        Gtk.TextIter start_iter, end_iter;
        buffer.get_iter_at_offset(out start_iter, start_offset);
        buffer.get_iter_at_offset(out end_iter, end_offset);
        var tag = buffer.create_tag(null, "background", "rgba(255,213,79,0.35)");
        buffer.apply_tag(tag, start_iter, end_iter);

        Gtk.TextIter anchor_iter;
        buffer.get_iter_at_offset(out anchor_iter, end_offset);
        var anchor = buffer.create_child_anchor(anchor_iter);

        // Label is a placeholder - highlight_notes() renumbers every
        // marker (including this one) right after this call returns.
        var marker_btn = new Gtk.Button.with_label("");
        marker_btn.add_css_class("reader-note-marker");
        marker_btn.set_tooltip_text("Open note");
        marker_btn.set_valign(Gtk.Align.BASELINE);
        marker_btn.clicked.connect(() => {
            if (parent_window == null) return;
            // Re-fetch by id rather than closing over `note` - it may have
            // been edited since this highlight was first applied.
            var latest = Paperboy.NotesStore.get_instance().get_note(note.id);
            NoteEditorDialog.show(parent_window, note.url, latest ?? note);
        });
        tv.add_child_at_anchor(marker_btn, anchor);

        var entry = new ReaderNoteHighlight();
        entry.tv = tv;
        entry.tag = tag;
        entry.marker = marker_btn;
        return entry;
    }


    // Placed in ArticleSheet's header, next to the reader-view toggle -
    // only meaningful while reader view is showing, so ArticleSheet toggles
    // its visibility alongside the view itself.
    public Gtk.Widget get_settings_button() {
        return settings_btn;
    }

    private void build_settings_button() {
        settings_btn = new Gtk.MenuButton();
        settings_btn.set_icon_name("font-x-generic-symbolic");
        settings_btn.set_tooltip_text("Reader view settings");
        settings_btn.set_can_focus(false);
        settings_btn.set_visible(false);
        settings_btn.add_css_class("flat");

        var popover_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 16);
        popover_box.set_margin_top(12);
        popover_box.set_margin_bottom(12);
        popover_box.set_margin_start(12);
        popover_box.set_margin_end(12);
        popover_box.set_size_request(230, -1);

        // ---- Text size ----
        var size_heading = new Gtk.Label("Text size");
        size_heading.add_css_class("heading");
        size_heading.set_xalign(0);
        popover_box.append(size_heading);

        var size_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
        var decrease_btn = new Gtk.Button.from_icon_name("value-decrease-symbolic");
        decrease_btn.set_tooltip_text("Decrease text size");
        var size_pct_label = new Gtk.Label(font_scale_label());
        size_pct_label.set_hexpand(true);
        size_pct_label.set_halign(Gtk.Align.CENTER);
        var increase_btn = new Gtk.Button.from_icon_name("value-increase-symbolic");
        increase_btn.set_tooltip_text("Increase text size");

        decrease_btn.clicked.connect(() => {
            font_scale = double.max(0.8, Math.round((font_scale - 0.1) * 10) / 10.0);
            size_pct_label.set_text(font_scale_label());
            save_and_apply();
        });
        increase_btn.clicked.connect(() => {
            font_scale = double.min(1.6, Math.round((font_scale + 0.1) * 10) / 10.0);
            size_pct_label.set_text(font_scale_label());
            save_and_apply();
        });

        size_row.append(decrease_btn);
        size_row.append(size_pct_label);
        size_row.append(increase_btn);
        popover_box.append(size_row);

        // ---- Font family ----
        var family_heading = new Gtk.Label("Font");
        family_heading.add_css_class("heading");
        family_heading.set_xalign(0);
        popover_box.append(family_heading);

        var family_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        family_row.add_css_class("linked");
        var sans_btn = new Gtk.ToggleButton() { label = "Sans" };
        var serif_btn = new Gtk.ToggleButton() { label = "Serif" };
        var mono_btn = new Gtk.ToggleButton() { label = "Mono" };
        serif_btn.set_group(sans_btn);
        mono_btn.set_group(sans_btn);
        sans_btn.set_active(font_family == "sans");
        serif_btn.set_active(font_family == "serif");
        mono_btn.set_active(font_family == "monospace");
        sans_btn.set_hexpand(true);
        serif_btn.set_hexpand(true);
        mono_btn.set_hexpand(true);

        sans_btn.toggled.connect(() => { if (sans_btn.get_active()) { font_family = "sans"; save_and_apply(); } });
        serif_btn.toggled.connect(() => { if (serif_btn.get_active()) { font_family = "serif"; save_and_apply(); } });
        mono_btn.toggled.connect(() => { if (mono_btn.get_active()) { font_family = "monospace"; save_and_apply(); } });

        family_row.append(sans_btn);
        family_row.append(serif_btn);
        family_row.append(mono_btn);
        popover_box.append(family_row);

        // ---- Color scheme ----
        var color_heading = new Gtk.Label("Color");
        color_heading.add_css_class("heading");
        color_heading.set_xalign(0);
        popover_box.append(color_heading);

        var color_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
        color_row.set_halign(Gtk.Align.START);

        Gtk.ToggleButton? first_swatch = null;
        foreach (var scheme in new string[] { "auto", "light", "sepia", "gray", "dark", "night" }) {
            var swatch = build_color_swatch(scheme);
            if (first_swatch == null) {
                first_swatch = swatch;
            } else {
                swatch.set_group(first_swatch);
            }
            swatch.set_active(color_scheme == scheme);
            swatch.toggled.connect(() => {
                if (swatch.get_active()) { color_scheme = scheme; save_and_apply(); }
            });
            color_row.append(swatch);
        }
        popover_box.append(color_row);

        var popover = new Gtk.Popover();
        popover.set_child(popover_box);
        settings_btn.set_popover(popover);
    }

    private Gtk.ToggleButton build_color_swatch(string scheme) {
        var swatch = new Gtk.ToggleButton();
        swatch.add_css_class("reader-color-swatch");
        swatch.set_tooltip_text(scheme_label(scheme));
        var provider = new Gtk.CssProvider();
        string bg_css = scheme == "auto"
            ? "background-image: linear-gradient(135deg, #ffffff 50%, #1c1c1e 50%);"
            : "background-color: %s;".printf(swatch_css_color(scheme));
        provider.load_from_string(".reader-color-swatch { min-width: 24px; min-height: 24px; border-radius: 50%; padding: 0; border: 1px solid alpha(currentColor, 0.35); %s }".printf(bg_css));
        swatch.get_style_context().add_provider(provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        return swatch;
    }

    private string scheme_label(string scheme) {
        switch (scheme) {
            case "light": return "Light";
            case "sepia": return "Sepia";
            case "gray": return "Gray";
            case "dark": return "Dark";
            case "night": return "Night";
            default: return "Auto (match app theme)";
        }
    }

    private string swatch_css_color(string scheme) {
        switch (scheme) {
            case "light": return "#ffffff";
            case "sepia": return "#f4ecd8";
            case "gray": return "#e8e8e8";
            case "dark": return "#1c1c1e";
            case "night": return "#173a5e";
            default: return "linear-gradient(135deg, #ffffff 50%, #1c1c1e 50%)";
        }
    }

    private string font_scale_label() {
        return "%d%%".printf((int) Math.round(font_scale * 100));
    }

    private void save_and_apply() {
        if (parent_window != null && parent_window.prefs != null) {
            parent_window.prefs.reader_font_scale = font_scale;
            parent_window.prefs.reader_font_family = font_family;
            parent_window.prefs.reader_color_scheme = color_scheme;
        }
        apply_style();
    }

    // Regenerates the shared CSS provider from the current settings.
    // "auto" leaves background/foreground unset so the reader inherits the
    // app's normal theme colors (see .reader-view in style.css); the named
    // schemes override both to a fixed e-reader-style palette.
    private void apply_style() {
        if (style_provider == null) return;

        string bg = "";
        string fg = "";
        string dim_fg = "";
        switch (color_scheme) {
            case "light":
                bg = "#ffffff"; fg = "#1a1a1a"; dim_fg = "rgba(26,26,26,0.6)";
                break;
            case "sepia":
                bg = "#f4ecd8"; fg = "#5b4636"; dim_fg = "rgba(91,70,54,0.65)";
                break;
            case "gray":
                bg = "#e8e8e8"; fg = "#2b2b2b"; dim_fg = "rgba(43,43,43,0.6)";
                break;
            case "dark":
                // Pure white, not a dimmer off-white - that read as flat
                // gray and was hard to read against #1c1c1e.
                bg = "#1c1c1e"; fg = "#ffffff"; dim_fg = "rgba(255,255,255,0.65)";
                break;
            case "night":
                // Swatch stays a vivid navy so the option reads clearly as
                // "blue" in the picker, but the actual reading background is
                // desaturated further so it's easier on the eyes than the
                // swatch's own more saturated preview color. Text is pure
                // white for the same reason as "dark" above.
                bg = "#1a2332"; fg = "#ffffff"; dim_fg = "rgba(255,255,255,0.65)";
                break;
        }

        string family_css;
        switch (font_family) {
            case "serif": family_css = "serif"; break;
            case "monospace": family_css = "monospace"; break;
            default: family_css = "sans-serif"; break;
        }

        double title_size = 1.8 * font_scale;
        double byline_size = 0.95 * font_scale;
        double para_size = 1.15 * font_scale;

        var sb = new StringBuilder();
        if (bg.length > 0) {
            sb.append_printf(".reader-view { background-color: %s; }\n", bg);
        }
        sb.append_printf(
            ".reader-view .reader-title { font-family: %s; font-size: %.2fem; font-weight: 800; line-height: 1.25; %s }\n",
            family_css, title_size, fg.length > 0 ? ("color: " + fg + ";") : ""
        );
        sb.append_printf(
            ".reader-view .reader-byline { font-family: %s; font-size: %.2fem; %s }\n",
            family_css, byline_size, dim_fg.length > 0 ? ("color: " + dim_fg + ";") : "color: alpha(currentColor, 0.6);"
        );
        sb.append_printf(
            // background: none - a bare Gtk.TextView otherwise paints its
            // own opaque page-colored background instead of blending into
            // .reader-view's background like the old per-paragraph labels did.
            ".reader-view .reader-paragraph { font-family: %s; font-size: %.2fem; line-height: 1.6; background: none; %s }\n",
            family_css, para_size, fg.length > 0 ? ("color: " + fg + ";") : ""
        );
        sb.append_printf(
            ".reader-view .reader-source-name { %s }\n",
            fg.length > 0 ? ("color: " + fg + ";") : ""
        );
        // The source header bar is always black regardless of reading color
        // scheme, so its text needs to stay white rather than following
        // the per-scheme foreground color above.
        sb.append(".reader-source-header .reader-source-name { color: #ffffff; }\n");
        // The hero image border and the byline separator otherwise fall
        // back to the ambient system-theme color rather than the reader's
        // own chosen scheme - invisible whenever that ambient color is too
        // close to this scheme's own background (e.g. a light system theme
        // behind the "dark"/"night" reader schemes).
        sb.append_printf(
            ".reader-view .reader-hero-image { border-color: %s; }\n",
            fg.length > 0 ? ("alpha(" + fg + ", 0.18)") : "alpha(currentColor, 0.12)"
        );
        sb.append_printf(
            ".reader-view .reader-separator { background-color: %s; }\n",
            fg.length > 0 ? ("alpha(" + fg + ", 0.15)") : "alpha(currentColor, 0.15)"
        );

        style_provider.load_from_string(sb.str);
    }

    public void show_loading() {
        spinner.start();
        stack.set_visible_child_name("loading");
    }

    public void show_error() {
        spinner.stop();
        stack.set_visible_child_name("error");
    }

    // Stops any playing video, clears the article out, and scrolls back to
    // the top - called on close and before loading a new article so state
    // never leaks from one article into the next.
    public void reset() {
        clear_content();
        show_loading();
    }

    private void clear_content() {
        Gtk.Widget? child = content_box.get_first_child();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling();
            if (child is ReaderVideoEmbed) ((ReaderVideoEmbed) child).stop_playback();
            content_box.remove(child);
            child = next;
        }

        Gtk.Widget? header_child = source_header_row.get_first_child();
        while (header_child != null) {
            Gtk.Widget? next = header_child.get_next_sibling();
            source_header_row.remove(header_child);
            header_child = next;
        }
        source_header_bar.set_visible(false);

        scroller.get_vadjustment().set_value(0);
        anchor_shift_by_tv.clear();
        highlights_by_note_id.clear();
        hide_add_note_popover();
    }

    public void show_article(ExtractedArticle article, string article_url, string? source_name_encoded = null) {
        spinner.stop();

        clear_content();
        current_article_url = article_url;

        string? src_display_name;
        string? src_logo_url;
        string? local_logo_path;
        SourceMetadata.resolve_source_icon(source_name_encoded, article_url, null, out src_display_name, out src_logo_url, out local_logo_path);
        if (src_display_name == null || src_display_name.length == 0) src_display_name = article.site_name;

        if ((src_display_name != null && src_display_name.length > 0) || local_logo_path != null || (src_logo_url != null && src_logo_url.length > 0)) {
            if (local_logo_path != null || (src_logo_url != null && src_logo_url.length > 0)) {
                var logo_wrapper = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
                logo_wrapper.add_css_class("circular-logo");
                logo_wrapper.set_size_request(44, 44);
                logo_wrapper.set_valign(Gtk.Align.CENTER);

                var logo_pic = new Gtk.Picture();
                logo_pic.set_content_fit(Gtk.ContentFit.COVER);
                logo_pic.set_size_request(44, 44);
                logo_wrapper.append(logo_pic);
                source_header_row.append(logo_wrapper);

                if (local_logo_path != null) {
                    logo_pic.set_filename(local_logo_path);
                } else if (parent_window != null && parent_window.image_manager != null) {
                    parent_window.image_manager.load_image_async(logo_pic, src_logo_url, 44, 44);
                }
            }

            if (src_display_name != null && src_display_name.length > 0) {
                var source_label = new Gtk.Label(src_display_name);
                source_label.add_css_class("reader-source-name");
                source_label.set_valign(Gtk.Align.CENTER);
                source_header_row.append(source_label);
            }

            source_header_bar.set_visible(true);
        }

        if (article.hero_image_url != null && article.hero_image_url.length > 0) {
            var hero_image = new Gtk.Picture();
            hero_image.set_content_fit(Gtk.ContentFit.COVER);
            hero_image.set_size_request(-1, 320);
            hero_image.add_css_class("reader-hero-image");
            content_box.append(wrap_expandable_image(hero_image, article.hero_image_url));
            if (parent_window != null && parent_window.image_manager != null) {
                parent_window.image_manager.load_image_async(hero_image, article.hero_image_url, 720, 320);
            }
        }

        var title_label = new Gtk.Label(article.title.length > 0 ? article.title : "Untitled article");
        title_label.add_css_class("reader-title");
        title_label.set_wrap(true);
        title_label.set_xalign(0);
        title_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        content_box.append(title_label);

        string byline_text = build_byline(article);
        if (byline_text.length > 0) {
            var byline_label = new Gtk.Label(byline_text);
            byline_label.add_css_class("reader-byline");
            byline_label.set_xalign(0);
            content_box.append(byline_label);
        }

        var sep = new Gtk.Separator(Gtk.Orientation.HORIZONTAL);
        sep.add_css_class("reader-separator");
        sep.set_margin_top(6);
        sep.set_margin_bottom(6);
        content_box.append(sep);

        // Blocks are walked in document order; runs of consecutive TEXT
        // blocks are batched into one Gtk.TextView (not one Gtk.Label per
        // paragraph) so a mouse drag can select continuously within a run -
        // GTK has no way to select text spanning separate widgets, which is
        // why each run still gets its own TextView rather than one shared
        // across an inline image/video. Blank lines between paragraphs
        // stand in for the vertical spacing/wrap-mode labels used to
        // provide.
        var text_run = new Gee.ArrayList<string>();
        foreach (var block in article.blocks) {
            if (block.kind == ArticleBlockKind.TEXT) {
                text_run.add(block.text);
                continue;
            }

            flush_text_run(text_run);

            if (block.kind == ArticleBlockKind.IMAGE && block.image_url != null) {
                var body_image = new Gtk.Picture();
                body_image.set_content_fit(Gtk.ContentFit.COVER);
                body_image.set_size_request(-1, 320);
                body_image.add_css_class("reader-hero-image");
                content_box.append(wrap_expandable_image(body_image, block.image_url));
                if (parent_window != null && parent_window.image_manager != null) {
                    parent_window.image_manager.load_image_async(body_image, block.image_url, 720, 320);
                }
            } else if (block.kind == ArticleBlockKind.VIDEO_FILE || block.kind == ArticleBlockKind.VIDEO_EMBED || block.kind == ArticleBlockKind.VIDEO_LINK) {
                if (block.video_url != null) {
                    var embed = new ReaderVideoEmbed(block.kind, block.video_url, block.image_url, parent_window);
                    content_box.append(embed);
                }
            }
        }
        flush_text_run(text_run);

        stack.set_visible_child_name("content");

        // The TextViews' wrapped-text height isn't settled yet on the
        // frame they're built, so the scroller's adjustment.upper comes
        // out far too small (matching the viewport, not the real content
        // height) until something forces a relayout - queue it once the
        // main loop is idle, after the first layout pass has run.
        GLib.Idle.add(() => {
            content_box.queue_resize();
            return false;
        });
    }

    private void flush_text_run(Gee.ArrayList<string> text_run) {
        if (text_run.size == 0) return;

        var body_view = new Gtk.TextView();
        body_view.add_css_class("reader-paragraph");
        body_view.set_editable(false);
        body_view.set_cursor_visible(false);
        body_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR);
        body_view.set_hexpand(true);
        body_view.set_left_margin(0);
        body_view.set_right_margin(0);
        var body_buffer = body_view.get_buffer();
        string joined_text = string.joinv("\n\n", text_run.to_array());
        body_buffer.set_text(joined_text);
        body_view.set_data<string>("reader-plain-text", joined_text);
        content_box.append(body_view);

        // Only reacts to the selection clearing (e.g. clicking elsewhere) -
        // showing the popover is handled on gesture release instead, so it
        // doesn't pop up mid-drag before the user's finished selecting.
        body_buffer.notify["has-selection"].connect(() => {
            if (!body_buffer.has_selection) hide_add_note_popover();
        });

        text_run.clear();
    }

    // Shown near an active text selection so creating a note anchored to
    // it doesn't require opening the notes panel first (select -> one
    // click, instead of select -> open panel -> "New note").
    // (tv, start_offset, end_offset) of whichever selection the popover is
    // currently shown for - lets show_add_note_popover() skip a redundant
    // popup() call when nothing actually changed (see below).
    private Gtk.TextView? shown_for_tv = null;
    private int shown_for_start = -1;
    private int shown_for_end = -1;

    private void show_add_note_popover(Gtk.TextView tv) {
        if (current_article_url == null) return;

        Gtk.TextIter sel_start, sel_end;
        if (!tv.get_buffer().get_selection_bounds(out sel_start, out sel_end)) return;

        int start_offset = sel_start.get_offset();
        int end_offset = sel_end.get_offset();

        // Every click anywhere in the reader body ends up here (via the
        // release listener below), including clicks meant to dismiss an
        // already-open popover - re-popping it every time would fight its
        // own autohide and make it undismissable. Only (re)show when the
        // selection actually changed.
        if (add_note_popover != null && add_note_popover.get_visible()
            && shown_for_tv == tv && shown_for_start == start_offset && shown_for_end == end_offset) {
            return;
        }

        Gdk.Rectangle rect;
        tv.get_iter_location(sel_end, out rect);
        int wx, wy;
        tv.buffer_to_window_coords(Gtk.TextWindowType.WIDGET, rect.x, rect.y, out wx, out wy);
        double cx, cy;
        if (!tv.translate_coordinates(content_box, wx, wy, out cx, out cy)) return;

        // A popover's parent link can go stale across a reader-view
        // close/reopen cycle (its own realize state doesn't survive that,
        // even though content_box itself is never reassigned) - confirmed
        // via diagnostic: get_parent() != content_box after reopening,
        // which then crashes GTK trying to realize it. Discard and rebuild
        // rather than reuse a popover whose parent link no longer matches.
        if (add_note_popover != null && add_note_popover.get_parent() != content_box) {
            add_note_popover.unparent();
            add_note_popover = null;
        }

        if (add_note_popover == null) {
            var btn = new Gtk.Button.from_icon_name("document-edit-symbolic");
            btn.set_tooltip_text("Add note");
            btn.add_css_class("reader-add-note-btn");
            btn.set_size_request(24, 24);
            // Default halign/valign is FILL, so without this the button
            // stretches to whatever size the popover's content area
            // allocates (not necessarily square) instead of staying at
            // its own natural size - that's what was distorting it.
            btn.set_halign(Gtk.Align.CENTER);
            btn.set_valign(Gtk.Align.CENTER);
            btn.set_tooltip_text("Add note");
            // Without this, the button (and popover) grabs keyboard focus
            // away from the TextView, which then renders its selection in
            // the dimmed "unfocused" style instead of the normal highlight
            // - same fix as the toolbar buttons in NoteEditorDialog.
            btn.set_can_focus(false);
            btn.clicked.connect(() => {
                if (parent_window == null || current_article_url == null) return;
                string? quote = get_selected_text();
                hide_add_note_popover();
                NoteEditorDialog.show(parent_window, current_article_url, null, quote);
            });
            add_note_popover = new Gtk.Popover();
            add_note_popover.add_css_class("reader-add-note-popover");
            add_note_popover.set_child(btn);
            add_note_popover.set_can_focus(false);
            // Not autohide - that grabs the pointer for any outside click,
            // including a right-click on the still-selected text, which
            // swallowed it before the TextView's own context menu ever saw
            // it. Dismissal is handled explicitly instead (see the primary-
            // button press handler above and the has-selection listener
            // below), which only reacts to real widget events and so never
            // blocks a right-click from reaching the TextView normally.
            add_note_popover.set_autohide(false);
            // The arrow decoration reserves extra horizontal space around
            // its content node without a matching vertical amount -
            // that's what was actually stretching this into an oval
            // around a small circular button (measured via an isolated
            // Gtk.Popover repro: content node was 36x24 with the arrow on,
            // a clean 24x24 square with it off).
            add_note_popover.set_has_arrow(false);
            add_note_popover.set_parent(content_box);
            // A primary click that dismisses this popover also collapses
            // the selection it was anchored to.
            add_note_popover.closed.connect(() => {
                if (shown_for_tv != null) {
                    Gtk.TextIter cursor_iter;
                    var buf = shown_for_tv.get_buffer();
                    buf.get_iter_at_offset(out cursor_iter, shown_for_end);
                    buf.place_cursor(cursor_iter);
                }
                shown_for_tv = null;
                shown_for_start = -1;
                shown_for_end = -1;
            });
        }

        Gdk.Rectangle point_to = { (int) cx, (int) cy, 1, rect.height };
        add_note_popover.set_pointing_to(point_to);
        add_note_popover.popup();
        shown_for_tv = tv;
        shown_for_start = start_offset;
        shown_for_end = end_offset;
    }

    public void hide_add_note_popover() {
        if (add_note_popover != null) add_note_popover.popdown();
        shown_for_tv = null;
        shown_for_start = -1;
        shown_for_end = -1;
    }

    // Wraps a reader-view image in an Overlay with a bottom-right expand
    // button that opens it full-size in ImageViewerDialog - same
    // Overlay+corner-button shape PodcastCard uses for its own play/
    // subscribe badges. Shows whatever paintable is already loaded on the
    // Picture at click time (no re-fetch), so it does nothing if clicked
    // before the image has finished loading.
    private Gtk.Widget wrap_expandable_image(Gtk.Picture picture, string image_url) {
        var overlay = new Gtk.Overlay();
        overlay.set_child(picture);

        var expand_button = new Gtk.Button.from_icon_name("view-fullscreen-symbolic");
        expand_button.add_css_class("podcast-card-badge-btn");
        expand_button.set_tooltip_text("View full size");
        expand_button.set_halign(Gtk.Align.END);
        expand_button.set_valign(Gtk.Align.END);
        expand_button.set_margin_end(8);
        expand_button.set_margin_bottom(8);
        expand_button.clicked.connect(() => {
            var paintable = picture.get_paintable();
            if (paintable == null || parent_window == null) return;
            ImageViewerDialog.show(parent_window, paintable, image_url);
        });
        overlay.add_overlay(expand_button);

        return overlay;
    }

    private string build_byline(ExtractedArticle article) {
        var parts = new Gee.ArrayList<string>();
        if (article.author != null && article.author.length > 0) parts.add("By " + article.author);
        if (article.published != null && article.published.length > 0) {
            string rel = DateUtils.time_ago(article.published);
            parts.add(rel.length > 0 ? rel : article.published);
        }
        if (article.site_name != null && article.site_name.length > 0) parts.add(article.site_name);
        return string.joinv(" · ", parts.to_array());
    }
}
