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

// Implements Adw.Swipeable so a real Adw.SwipeTracker can drive the
// page-turn gesture - the same tracking mechanism Adw.NavigationView
// uses. Positions its 3 children (the page content, plus the next/prev
// peek) via MagazineSwipeLayout, a custom Gtk.LayoutManager that
// allocates each with a GskTransform translation, the same technique
// AdwNavigationView itself uses (gtk_widget_allocate() + GskTransform,
// driven by queue_allocate() - never a CSS transform). An earlier version
// used CSS transforms reparsed every frame via Gtk.CssProvider, which is
// CPU-heavier than direct widget allocation and was the actual cause of
// the swipe never feeling as smooth as native Adw widgets, confirmed
// against AdwNavigationView's real source before rewriting this.
public class MagazineSwipeSurface : Gtk.Widget, Adw.Swipeable {
    public double progress = 0;
    // Which directions currently have somewhere to go - false at either
    // end of the document, so Adw's own snap points (and its overshoot
    // handling) naturally replace the resistance math a hand-rolled
    // version needed.
    public bool can_go_next = true;
    public bool can_go_prev = true;

    public Gtk.Widget? content_child;
    public Gtk.Widget? peek_next_child;
    public Gtk.Widget? peek_prev_child;

    static construct {
        set_layout_manager_type(typeof(MagazineSwipeLayout));
    }

    public void set_content(Gtk.Widget child) {
        content_child = child;
        child.set_parent(this);
    }

    public void set_peeks(Gtk.Widget next, Gtk.Widget prev) {
        peek_next_child = next;
        next.set_parent(this);
        peek_prev_child = prev;
        prev.set_parent(this);
    }

    public double get_distance() {
        int w = get_width();
        return w > 0 ? w : 1;
    }

    // Both always 0, matching AdwNavigationView's own implementation -
    // Adw.SwipeTracker manages its own progress state internally and
    // doesn't need this widget to echo a live value back to it. The
    // earlier version tied this to a mutable field that both
    // update_swipe AND our own settle animation wrote to, which is what
    // made a new drag starting mid-settle fight the animation for that
    // same value.
    public double get_progress() {
        return 0;
    }

    public double get_cancel_progress() {
        return 0;
    }

    public double[] get_snap_points() {
        if (can_go_next && can_go_prev) return { -1.0, 0.0, 1.0 };
        if (can_go_next) return { -1.0, 0.0 };
        if (can_go_prev) return { 0.0, 1.0 };
        return { 0.0 };
    }

    public Gdk.Rectangle get_swipe_area(Adw.NavigationDirection direction, bool is_drag) {
        Gdk.Rectangle rect = { 0, 0, get_width(), get_height() };
        return rect;
    }
}

// content_child sits at progress*width; peek_next_child (revealed when
// progress < 0) at (1+progress)*width, fully off-screen right at rest and
// fully in view at progress=-1; peek_prev_child mirrors that on the left.
public class MagazineSwipeLayout : Gtk.LayoutManager {
    public override void measure(Gtk.Widget widget, Gtk.Orientation orientation, int for_size, out int minimum, out int natural, out int minimum_baseline, out int natural_baseline) {
        minimum_baseline = -1;
        natural_baseline = -1;
        var surface = (MagazineSwipeSurface) widget;
        if (surface.content_child != null) {
            surface.content_child.measure(orientation, for_size, out minimum, out natural, null, null);
        } else {
            minimum = 0;
            natural = 0;
        }
    }

    public override void allocate(Gtk.Widget widget, int width, int height, int baseline) {
        var surface = (MagazineSwipeSurface) widget;
        double progress = surface.progress;

        if (surface.content_child != null) {
            var t = new Gsk.Transform().translate(Graphene.Point() { x = (float) (progress * width), y = 0 });
            surface.content_child.allocate(width, height, baseline, (owned) t);
        }
        if (surface.peek_next_child != null) {
            var t = new Gsk.Transform().translate(Graphene.Point() { x = (float) ((1 + progress) * width), y = 0 });
            surface.peek_next_child.allocate(width, height, baseline, (owned) t);
        }
        if (surface.peek_prev_child != null) {
            var t = new Gsk.Transform().translate(Graphene.Point() { x = (float) ((progress - 1) * width), y = 0 });
            surface.peek_prev_child.allocate(width, height, baseline, (owned) t);
        }
    }
}

// Page-by-page PDF reader, built the same way as PodcastPane/ArticleSheet -
// a plain Gtk.Revealer (SLIDE_UP) mounted into root_overlay (see
// appWindow.vala), not a separate top-level window. Constructed once for
// the app's whole lifetime and reused across every open_for_entry() call.
// Unlike PodcastPane's ~1/3-height peek sheet, this fills the whole
// content view - reading a magazine page needs the space a detail peek
// doesn't.
public class MagazineReaderSheet : GLib.Object {
    // The revealer is what appWindow.vala adds as a root_overlay child -
    // root itself is just its content.
    public Gtk.Revealer revealer;
    public Gtk.Box root;

    private weak NewsWindow? window;

    private Gtk.Label title_label;
    private Gtk.Button spread_toggle_button;
    // Two full sets of page pictures ("slots"), swapped via pages_stack -
    // a page turn renders the new page(s) into the INACTIVE slot, then
    // transitions the stack to it with a slide, instead of overwriting the
    // visible picture's texture in place (which can't be animated, since
    // there'd be nothing to slide FROM once the old page's pixels are
    // already gone).
    private Gtk.Picture[] left_pictures = new Gtk.Picture[2];
    private Gtk.Picture[] right_pictures = new Gtk.Picture[2];
    private Gtk.Box[] slot_boxes = new Gtk.Box[2];
    private Gtk.Stack pages_stack;
    // Full-viewport peek pictures for the next/prev page during a swipe -
    // positioned via CSS transform, off-screen at rest, GPU-composited.
    private Gtk.Picture peek_prev;
    private Gtk.Picture peek_next;
    // Shown centered over the viewport only if a peek render is still
    // running after a short delay - avoids a flash on every swipe when
    // the render finishes in a frame or two, which is the common case.
    private Gtk.Spinner peek_spinner;
    private uint pending_peek_renders = 0;
    private uint peek_spinner_timeout_id = 0;
    // Rendered spreads for pages adjacent to current_page, keyed by page
    // index - populated both by prefetch_adjacent_pages() (ahead of any
    // gesture) and by render_peek() itself, so a swipe often just hits
    // this instead of rendering from scratch. A null value means a
    // render for that page is already in flight - not a cache miss, just
    // not ready yet. Invalidated wholesale (see ensure_spread_cache_valid)
    // whenever zoom/spread/viewport change, since those are baked into
    // the rendered bitmap.
    private Gee.HashMap<int, Gdk.Pixbuf?> spread_cache = new Gee.HashMap<int, Gdk.Pixbuf?>();
    private double spread_cache_zoom = -1;
    private bool spread_cache_spread_mode = false;
    private int spread_cache_viewport_w = -1;
    private int spread_cache_viewport_h = -1;
    private Paperboy.MagazineTocPane toc_pane;
    private MagazineSwipeSurface swipe_surface;
    private Adw.SwipeTracker swipe_tracker;
    // The in-flight commit/spring-back animation, if any - a new gesture
    // starting while one is still playing skips it to completion instead
    // of the two fighting over swipe_surface.progress.
    private Adw.Animation? active_swipe_animation = null;
    private int active_slot = 0;
    private Gtk.ScrolledWindow scroller;
    private Gtk.Label page_label;
    private Gtk.Button prev_button;
    private Gtk.Button next_button;
    private ScrollNavButtons nav_buttons;

    private Poppler.Document? document = null;
    // Poppler isn't safe against concurrent access to the same Document
    // from multiple threads - guards every call into it, since renders
    // now happen on background threads (render_peek,
    // render_current_page_async) alongside the main thread's own.
    private static GLib.Mutex poppler_lock;
    private int current_page = 0;
    private Paperboy.MagazineEntry? open_entry = null;
    private int page_count = 0;
    private double zoom = 1.0;
    // Defaults on - a magazine reads as a two-page spread from the start,
    // same as a real print magazine open on a table.
    private bool spread_mode = true;
    // current_page's (and, in spread mode, its partner's) size in Poppler
    // points - refreshed once whenever current_page/spread_mode actually
    // change (see update_cached_content_size()), so swipe_should_be_enabled(),
    // set_zoom() and compute_fit_zoom() never have to touch Poppler (and
    // poppler_lock) synchronously on the main thread. They used to, and on
    // a fast series of swipes that meant "prepare" could stall waiting on
    // that lock behind a background peek/prefetch render still in flight.
    private double cached_content_w = 0;
    private double cached_content_h = 0;

    public MagazineReaderSheet(NewsWindow? window) {
        this.window = window;
        build();

        // resize_sheet() only ran once, at open_for_entry() - maximizing
        // or resizing the window afterward left root pinned to whatever
        // height it was opened at, so the sheet stopped filling the
        // window. "maximized" plus default-height/width between them
        // cover both a maximize/unmaximize and a plain drag-resize.
        if (window != null) {
            window.notify["maximized"].connect(() => { on_window_resized(); });
            window.notify["default-height"].connect(() => { on_window_resized(); });
            window.notify["default-width"].connect(() => { on_window_resized(); });
        }
    }

    // Re-runs resize_sheet() and re-centers the current page once the
    // window's own resize/maximize has actually settled - scroller's own
    // width/height (which centering reads) aren't updated yet at the
    // moment this notify fires, only after that layout pass.
    private void on_window_resized() {
        if (!is_open()) return;
        // A single Idle wasn't always enough for main_scrolled/scroller's
        // own size to have actually caught up to the resize yet - a short
        // timeout gives GTK's layout pass more room to finish first.
        GLib.Timeout.add(50, () => {
            resize_sheet();
            center_slot_if_smaller_than_viewport(active_slot);
            // A resize/maximize mid-gesture can leave swipe_tracker's own
            // internal recognizer stuck against a momentarily-degenerate
            // (e.g. zero) width from get_distance()/get_swipe_area() -
            // toggling enabled forces it to reset that internal state,
            // not just reassign the same value it already had.
            swipe_tracker.enabled = false;
            swipe_tracker.enabled = swipe_should_be_enabled();
            return false;
        });
    }

    // Poppler.Document.from_gfile() parses the whole document, and an
    // unusual/pathologically complex PDF can make that (or the first
    // page's render() below) take a very long time - this used to run
    // synchronously on the main thread, so a single such file froze the
    // entire app, not just the reader. Loading it on a background thread
    // and only touching the UI once it's ready keeps that from happening,
    // same idea as MagazinePdfImportService's own background-thread use
    // of Poppler.
    public void open_for_entry(Paperboy.MagazineEntry entry) {
        save_position();
        if (window != null && window.toast_manager != null) window.toast_manager.show_persistent_toast("Opening magazine…");

        new GLib.Thread<void*>("magazine-open", () => {
            Poppler.Document? loaded = null;
            string? error = null;
            try {
                var file = GLib.File.new_for_path(entry.local_path);
                loaded = new Poppler.Document.from_gfile(file, null);
                loaded.get_n_pages(); // force full parse here, off the main thread
            } catch (GLib.Error e) {
                error = e.message;
            }

            GLib.Idle.add(() => {
                finish_open_for_entry(entry, loaded, error);
                return false;
            });
            return null;
        });
    }

    private void finish_open_for_entry(Paperboy.MagazineEntry entry, Poppler.Document? loaded, string? error) {
        if (loaded == null) {
            GLib.warning("Failed to open magazine: %s", error ?? "unknown error");
            if (window != null && window.toast_manager != null) {
                window.toast_manager.clear_persistent_toast();
                window.toast_manager.show_toast("Failed to open magazine");
            }
            return;
        }
        document = loaded;
        spread_cache.clear(); // stale page indices from whatever was open before, if anything

        title_label.set_text(entry.title.length > 0 ? entry.title : "Magazine");
        page_count = document.get_n_pages();
        open_entry = entry;
        current_page = entry.last_page.clamp(0, int.max(page_count - 1, 0));
        if (spread_mode && current_page % 2 != 0) current_page -= 1;
        active_slot = 0;
        pages_stack.set_visible_child_name("slot0");
        update_cached_content_size();
        toc_pane.reset_for_document(page_count);
        toc_pane.set_current_page(current_page, spread_mode);

        resize_sheet();
        // The viewport often isn't sized yet at this point, so this fit
        // is only a best guess - corrected for real once the reveal
        // transition below has actually settled.
        zoom = compute_fit_zoom();
        // The actual Poppler render (not just parsing) can also be slow on
        // an image-heavy PDF, so it's backgrounded too - reveal (and clear
        // the toast) only once the first page is actually ready, same
        // reasoning as loading the document itself above.
        render_current_page_async(() => {
            if (window != null && window.toast_manager != null) window.toast_manager.clear_persistent_toast();
            revealer.set_reveal_child(true);
            prefetch_adjacent_pages();
            GLib.Timeout.add(280, () => {
                fit_to_view(); // may change zoom, invalidating the prefetch above - redone below at the final zoom
                prefetch_adjacent_pages();
                return false;
            });
            return false;
        });
    }

    public void close() {
        save_position();
        revealer.set_reveal_child(false);
        toc_pane.close();
    }

    // One write per close, not per page turn.
    public void save_position() {
        if (open_entry == null || open_entry.last_page == current_page) return;
        open_entry.last_page = current_page;
        Paperboy.MagazineLibraryStore.get_instance().update_last_page(open_entry.id, current_page);
    }

    public bool is_open() {
        return revealer.get_reveal_child();
    }

    private void build() {
        root = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        root.add_css_class("podcast-pane");
        root.set_hexpand(true);
        root.set_vexpand(true);
        root.set_halign(Gtk.Align.FILL);
        root.set_valign(Gtk.Align.FILL);

        revealer = new Gtk.Revealer();
        revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_UP);
        revealer.set_transition_duration(250);
        revealer.set_valign(Gtk.Align.END);
        revealer.set_halign(Gtk.Align.FILL);
        revealer.set_reveal_child(false);
        revealer.set_child(root);

        var header_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 12);
        header_row.set_margin_start(20);
        header_row.set_margin_end(12);
        header_row.set_margin_top(12);
        header_row.set_margin_bottom(12);

        title_label = new Gtk.Label("");
        title_label.add_css_class("title-2");
        title_label.set_xalign(0);
        title_label.set_hexpand(true);
        title_label.set_ellipsize(Pango.EllipsizeMode.END);
        header_row.append(title_label);

        spread_toggle_button = new Gtk.Button.with_label("Single Page");
        spread_toggle_button.set_tooltip_text("Toggle two-page spread");
        spread_toggle_button.clicked.connect(() => {
            spread_mode = !spread_mode;
            spread_toggle_button.set_label(spread_mode ? "Single Page" : "Two-Page");
            // Land on an even page so the spread reads as (2,3), (4,5), ...
            // rather than a half-page offset.
            if (spread_mode && current_page % 2 != 0 && current_page > 0) current_page -= 1;
            update_cached_content_size();
            render_current_page();
            prefetch_adjacent_pages();
            toc_pane.set_current_page(current_page, spread_mode);
        });
        header_row.append(spread_toggle_button);

        var toc_button = new Gtk.Button.from_icon_name("view-grid-symbolic");
        toc_button.add_css_class("flat");
        toc_button.set_tooltip_text("Browse pages");
        toc_button.clicked.connect(() => { toc_pane.toggle(); });
        header_row.append(toc_button);

        var zoom_out_button = new Gtk.Button.from_icon_name("zoom-out-symbolic");
        zoom_out_button.add_css_class("flat");
        zoom_out_button.set_tooltip_text("Zoom out");
        zoom_out_button.clicked.connect(() => { set_zoom(zoom - 0.25); });
        header_row.append(zoom_out_button);

        var zoom_fit_button = new Gtk.Button.from_icon_name("zoom-fit-best-symbolic");
        zoom_fit_button.add_css_class("flat");
        zoom_fit_button.set_tooltip_text("Fit to view");
        zoom_fit_button.clicked.connect(() => { fit_to_view(); });
        header_row.append(zoom_fit_button);

        var zoom_in_button = new Gtk.Button.from_icon_name("zoom-in-symbolic");
        zoom_in_button.add_css_class("flat");
        zoom_in_button.set_tooltip_text("Zoom in");
        zoom_in_button.clicked.connect(() => { set_zoom(zoom + 0.25); });
        header_row.append(zoom_in_button);

        var close_button = new Gtk.Button.from_icon_name("window-close-symbolic");
        close_button.add_css_class("flat");
        close_button.add_css_class("circular");
        close_button.set_tooltip_text("Close");
        close_button.clicked.connect(() => { close(); });
        header_row.append(close_button);

        root.append(header_row);

        var separator = new Gtk.Separator(Gtk.Orientation.HORIZONTAL);
        separator.add_css_class("section-divider");
        root.append(separator);

        scroller = new Gtk.ScrolledWindow();
        scroller.set_vexpand(true);
        scroller.set_hexpand(true);

        pages_stack = new Gtk.Stack();
        pages_stack.set_transition_duration(280);
        // Not homogeneous - that sizes to the largest of both double-
        // buffered slots, not just the visible one, which threw off the
        // zoom math below.
        pages_stack.set_hhomogeneous(false);
        pages_stack.set_vhomogeneous(false);
        for (int i = 0; i < 2; i++) {
            var slot_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 2);
            // START, not CENTER - CENTER fights an explicit scroll
            // position, which broke zoom-to-point.
            slot_box.set_halign(Gtk.Align.START);
            slot_box.set_valign(Gtk.Align.START);
            left_pictures[i] = build_page_picture();
            slot_box.append(left_pictures[i]);
            right_pictures[i] = build_page_picture();
            right_pictures[i].set_visible(spread_mode);
            slot_box.append(right_pictures[i]);
            slot_boxes[i] = slot_box;
            pages_stack.add_named(slot_box, "slot%d".printf(i));
        }
        pages_stack.set_visible_child_name("slot0");

        // swipe_surface positions the page stack and both peeks itself
        // (via MagazineSwipeLayout) and implements Adw.Swipeable for the
        // real Adw.SwipeTracker set up below. ScrollNavButtons still
        // needs an actual Gtk.Overlay for its own hover-reveal arrows, so
        // that's a separate outer layer - the swipeable content doesn't
        // need to share a widget tree with it.
        swipe_surface = new MagazineSwipeSurface();
        swipe_surface.set_content(pages_stack);

        peek_prev = build_peek_picture();
        peek_prev.set_visible(false);
        peek_next = build_peek_picture();
        peek_next.set_visible(false);
        swipe_surface.set_peeks(peek_next, peek_prev);

        var outer_overlay = new Gtk.Overlay();
        outer_overlay.set_child(swipe_surface);
        scroller.set_child(outer_overlay);

        // Left-edge "browse pages" panel - slides in over the content
        // rather than a modal dialog, so you can keep it open while
        // paging through the reader. Clicking the content area while it's
        // open dismisses it, same as clicking off a popover would.
        toc_pane = new Paperboy.MagazineTocPane((page_index, thumb_width) => {
            double points_w, points_h;
            poppler_get_page_size(page_index, out points_w, out points_h);
            double thumb_zoom = points_w > 0 ? thumb_width / points_w : 0.1;
            return render_page_pixbuf_at(page_index, thumb_zoom);
        });
        toc_pane.page_selected.connect((page_index) => { go_to_page(page_index, false); });

        var dismiss_toc_click = new Gtk.GestureClick();
        dismiss_toc_click.set_propagation_phase(Gtk.PropagationPhase.CAPTURE);
        dismiss_toc_click.pressed.connect((n_press, x, y) => {
            if (toc_pane.is_open()) {
                toc_pane.close();
                dismiss_toc_click.set_state(Gtk.EventSequenceState.CLAIMED);
            }
        });
        scroller.add_controller(dismiss_toc_click);

        var content_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        content_row.set_vexpand(true);
        content_row.append(toc_pane.revealer);
        content_row.append(scroller);
        root.append(content_row);

        peek_spinner = new Gtk.Spinner();
        peek_spinner.set_halign(Gtk.Align.CENTER);
        peek_spinner.set_valign(Gtk.Align.CENTER);
        peek_spinner.set_size_request(32, 32);
        peek_spinner.set_visible(false);
        outer_overlay.add_overlay(peek_spinner);
        outer_overlay.set_measure_overlay(peek_spinner, false);

        // edge_zone_width, not the default half-split - a magazine page
        // fills the whole overlay, so "which half" lit up an arrow from
        // anywhere across half the page instead of only near its actual
        // edge. 160px reads as "near the edge" without being so narrow
        // it's hard to land on.
        nav_buttons = new ScrollNavButtons(outer_overlay, "magazine-reader-nav", 8, 160);
        nav_buttons.prev_requested.connect(() => { go_to_page(current_page - (spread_mode ? 2 : 1)); });
        nav_buttons.next_requested.connect(() => { go_to_page(current_page + (spread_mode ? 2 : 1)); });

        // The actual Adw.SwipeTracker - handles gesture recognition,
        // per-frame progress, snap-point selection, and release velocity
        // itself, same as Adw.NavigationView. We only turn its progress
        // into a widget-allocation transform (update_swipe) and act on
        // where it decided to settle (end_swipe) - no hand-rolled
        // threshold/resistance/velocity-tracking code. velocity/progress
        // are used directly, in Adw's own units - no pixel conversion,
        // since MagazineSwipeLayout positions children from progress
        // itself, not from a pixel offset.
        swipe_tracker = new Adw.SwipeTracker(swipe_surface);
        swipe_tracker.orientation = Gtk.Orientation.HORIZONTAL;
        swipe_tracker.reversed = true;

        swipe_tracker.prepare.connect((direction) => {
            swipe_tracker.enabled = swipe_should_be_enabled();
            // Finish any still-playing settle instantly rather than
            // leaving a new gesture to fight it for swipe_surface.progress -
            // skip() still runs its on_done (the pending page turn lands
            // correctly), just without the rest of its animated duration.
            if (active_swipe_animation != null) active_swipe_animation.skip();
            int step = spread_mode ? 2 : 1;
            swipe_surface.can_go_next = current_page + step < page_count;
            swipe_surface.can_go_prev = current_page - step >= 0;
            // Rendered here, ahead of the actual drag, not on the first
            // update_swipe tick that needs it - that synchronous Poppler
            // render was blocking the very first frame of visual
            // feedback, which is what looked like the animation starting
            // later than the gesture itself.
            if (swipe_surface.can_go_next) render_peek(peek_next, current_page + step);
            if (swipe_surface.can_go_prev) render_peek(peek_prev, current_page - step);
        });

        swipe_tracker.update_swipe.connect((progress) => {
            swipe_surface.progress = progress;
            int step = spread_mode ? 2 : 1;
            bool show_next = progress < 0 && swipe_surface.can_go_next;
            bool show_prev = progress > 0 && swipe_surface.can_go_prev;
            if (show_next) {
                render_peek(peek_next, current_page + step);
            } else if (show_prev) {
                render_peek(peek_prev, current_page - step);
            }
            // Visibility as an explicit second guard, not just position -
            // a leftover peek from an interrupted gesture (e.g. a pinch
            // starting mid-swipe) previously stayed positioned off-screen
            // only via transform, which left it able to show through if
            // that math was ever wrong for any reason.
            peek_next.set_visible(show_next);
            peek_prev.set_visible(show_prev);
            swipe_surface.queue_allocate();
        });

        swipe_tracker.end_swipe.connect((velocity, to) => {
            double from_progress = swipe_surface.progress;
            int step = spread_mode ? 2 : 1;

            if (to < -0.5) {
                commit_swipe_turn(current_page + step, true, from_progress, velocity);
            } else if (to > 0.5) {
                commit_swipe_turn(current_page - step, false, from_progress, velocity);
            } else {
                spring_back_swipe(from_progress, velocity);
            }
        });

        // Trackpad pinch-to-zoom. Live preview is a cheap CSS transform
        // (no re-render per tick); the real Poppler re-render only happens
        // once, on gesture end.
        //
        // GestureZoom's scale is relative to gesture start, so the
        // absolute zoom is captured once and multiplied by it, not
        // reapplied cumulatively per tick.
        double zoom_at_gesture_start = zoom;
        double pending_zoom = zoom;
        // Pinch center, in scroller coords - captured once at gesture
        // begin so the CSS preview's transform-origin stays fixed.
        double pinch_anchor_x = 0;
        double pinch_anchor_y = 0;
        pages_stack.add_css_class("magazine-pinch-target");
        var pinch_provider = new Gtk.CssProvider();
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), pinch_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

        var zoom_gesture = new Gtk.GestureZoom();
        zoom_gesture.begin.connect((sequence) => {
            zoom_at_gesture_start = zoom;
            pending_zoom = zoom;
            zoom_gesture.get_bounding_box_center(out pinch_anchor_x, out pinch_anchor_y);
        });
        zoom_gesture.scale_changed.connect((scale) => {
            pending_zoom = double.max(0.5, double.min(3.0, zoom_at_gesture_start * scale));
            double preview_scale = pending_zoom / zoom;

            // Anchor the preview's transform-origin to the pinch point
            // (in pages_stack's own coords), not its default center.
            double origin_x, origin_y;
            scroller.translate_coordinates(pages_stack, pinch_anchor_x, pinch_anchor_y, out origin_x, out origin_y);
            pinch_provider.load_from_string(".magazine-pinch-target { transform-origin: %fpx %fpx; transform: scale(%f); }".printf(origin_x, origin_y, preview_scale));
        });
        zoom_gesture.end.connect((sequence) => {
            // set_zoom() applies the new scroll position synchronously, so
            // the preview can clear immediately with nothing left to fix up.
            set_zoom(pending_zoom, pinch_anchor_x, pinch_anchor_y);
            pinch_provider.load_from_string("");
        });
        zoom_gesture.cancel.connect((sequence) => {
            pinch_provider.load_from_string("");
        });
        scroller.add_controller(zoom_gesture);

        var bottom_bar = new Gtk.ActionBar();
        // Grouped together (prev, page counter, next) and centered as one
        // unit via set_center_widget, instead of pack_start/pack_end
        // spreading prev and next out to opposite ends of the bar with the
        // counter stranded in the middle on its own.
        var nav_group = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
        prev_button = new Gtk.Button.from_icon_name("go-previous-symbolic");
        prev_button.set_tooltip_text("Previous page");
        prev_button.clicked.connect(() => { go_to_page(current_page - (spread_mode ? 2 : 1)); });
        nav_group.append(prev_button);

        page_label = new Gtk.Label("");
        nav_group.append(page_label);

        next_button = new Gtk.Button.from_icon_name("go-next-symbolic");
        next_button.set_tooltip_text("Next page");
        next_button.clicked.connect(() => { go_to_page(current_page + (spread_mode ? 2 : 1)); });
        nav_group.append(next_button);

        bottom_bar.set_center_widget(nav_group);
        root.append(bottom_bar);

        var key_controller = new Gtk.EventControllerKey();
        key_controller.key_pressed.connect((keyval, keycode, state) => {
            if (!is_open()) return false;
            if (keyval == Gdk.Key.Escape) { close(); return true; }
            if (keyval == Gdk.Key.Left || keyval == Gdk.Key.Page_Up) { go_to_page(current_page - (spread_mode ? 2 : 1)); return true; }
            if (keyval == Gdk.Key.Right || keyval == Gdk.Key.Page_Down) { go_to_page(current_page + (spread_mode ? 2 : 1)); return true; }
            return false;
        });
        root.add_controller(key_controller);
    }

    // Full-viewport size, GPU-composited (Gdk.Texture, not a Cairo
    // draw_func) - see the peek_prev/peek_next field comment for why.
    private Gtk.Picture build_peek_picture() {
        var picture = new Gtk.Picture();
        picture.set_can_shrink(true);
        picture.set_content_fit(Gtk.ContentFit.CONTAIN);
        picture.set_hexpand(true);
        picture.set_vexpand(true);
        picture.set_halign(Gtk.Align.FILL);
        picture.set_valign(Gtk.Align.FILL);
        return picture;
    }

    private void clear_peek_spinner() {
        pending_peek_renders = 0;
        peek_spinner.stop();
        peek_spinner.set_visible(false);
        if (peek_spinner_timeout_id != 0) {
            GLib.Source.remove(peek_spinner_timeout_id);
            peek_spinner_timeout_id = 0;
        }
    }

    // Clears spread_cache whenever the parameters baked into its bitmaps
    // (zoom, spread mode, viewport size) have changed since it was built.
    private void ensure_spread_cache_valid() {
        double at_zoom = zoom;
        bool spread = spread_mode;
        int viewport_w = scroller.get_width();
        int viewport_h = scroller.get_height();
        if (spread_cache_zoom != at_zoom || spread_cache_spread_mode != spread
            || spread_cache_viewport_w != viewport_w || spread_cache_viewport_h != viewport_h) {
            spread_cache.clear();
            spread_cache_zoom = at_zoom;
            spread_cache_spread_mode = spread;
            spread_cache_viewport_w = viewport_w;
            spread_cache_viewport_h = viewport_h;
        }
    }

    // Only actually stores if the cache's params still match what this
    // render was started with - they may have moved on (zoom, resize)
    // while it was in flight, in which case the result is just stale.
    private void store_in_spread_cache(int page_index, double at_zoom, bool spread, int viewport_w, int viewport_h, Gdk.Pixbuf? pixbuf) {
        if (spread_cache_zoom == at_zoom && spread_cache_spread_mode == spread
            && spread_cache_viewport_w == viewport_w && spread_cache_viewport_h == viewport_h) {
            if (pixbuf != null) spread_cache[page_index] = pixbuf;
            else spread_cache.unset(page_index);
        }
    }

    // Renders adjacent pages ahead of any gesture, so a swipe often finds
    // its peek already sitting in spread_cache instead of having to
    // render it from scratch - called whenever current_page settles.
    // Bounded to just the immediate neighbors (not the whole document),
    // and stale entries are evicted as current_page moves so the cache
    // can't grow past a handful of pages on a heavy PDF.
    private void prefetch_adjacent_pages() {
        if (document == null) return;
        ensure_spread_cache_valid();
        int step = spread_mode ? 2 : 1;

        var keep = new Gee.HashSet<int>();
        keep.add(current_page);
        if (current_page + step < page_count) keep.add(current_page + step);
        if (current_page - step >= 0) keep.add(current_page - step);
        var stale = new Gee.ArrayList<int>();
        foreach (var key in spread_cache.keys) if (!(key in keep)) stale.add(key);
        foreach (var key in stale) spread_cache.unset(key);

        prefetch_page(current_page + step);
        prefetch_page(current_page - step);
    }

    private void prefetch_page(int page_index) {
        if (document == null || page_index < 0 || page_index >= page_count) return;
        if (spread_cache.has_key(page_index)) return; // already cached, or already being rendered

        double at_zoom = zoom;
        bool spread = spread_mode;
        int count = page_count;
        int viewport_w = scroller.get_width();
        int viewport_h = scroller.get_height();
        spread_cache[page_index] = null; // claimed - marks it as in flight, not a miss

        new GLib.Thread<void*>("magazine-prefetch-page", () => {
            var pixbuf = render_spread_pixbuf_at(page_index, at_zoom, spread, count, viewport_w, viewport_h);
            GLib.Idle.add(() => {
                store_in_spread_cache(page_index, at_zoom, spread, viewport_w, viewport_h, pixbuf);
                return false;
            });
            return null;
        });
    }

    // Renders page_index (and its spread partner, in spread mode) into a
    // peek's texture, unless it already holds (or is already rendering)
    // that same page - the swipe handler calls this every tick, but
    // Poppler rendering is too expensive to redo per pixel of drag.
    //
    // Checks spread_cache first - prefetch_adjacent_pages() has often
    // already rendered exactly this page by the time a swipe starts.
    //
    // Backgrounded, same reasoning as render_current_page_async - on a
    // heavy/image-dense PDF this render was blocking "prepare", which is
    // what made the gesture itself feel like it started a beat late.
    private void render_peek(Gtk.Picture picture, int page_index) {
        if (picture.get_data<int?>("peek-page") == page_index) return;
        picture.set_data<int?>("peek-page", page_index); // claimed now so repeated ticks don't re-request
        // Otherwise, on a slow render, whatever page this picture last held
        // stays fully visible until the new one's ready - looking like a
        // stale "ghost" of an unrelated page rather than just blank.
        picture.set_paintable(null);

        ensure_spread_cache_valid();
        Gdk.Pixbuf? cached = spread_cache.has_key(page_index) ? spread_cache[page_index] : null;
        if (cached != null) {
            picture.set_paintable(Gdk.Texture.for_pixbuf(cached));
            return;
        }

        double at_zoom = zoom;
        bool spread = spread_mode;
        int count = page_count;
        int viewport_w = scroller.get_width();
        int viewport_h = scroller.get_height();

        pending_peek_renders++;
        if (peek_spinner_timeout_id == 0) {
            peek_spinner_timeout_id = GLib.Timeout.add(150, () => {
                peek_spinner_timeout_id = 0;
                if (pending_peek_renders > 0) {
                    peek_spinner.set_visible(true);
                    peek_spinner.start();
                }
                return false;
            });
        }

        new GLib.Thread<void*>("magazine-render-peek", () => {
            var pixbuf = render_spread_pixbuf_at(page_index, at_zoom, spread, count, viewport_w, viewport_h);
            GLib.Idle.add(() => {
                store_in_spread_cache(page_index, at_zoom, spread, viewport_w, viewport_h, pixbuf);
                // Only apply if nothing else has since claimed this picture -
                // a fast direction reversal mid-drag can request a different
                // page before this one finishes.
                if (pixbuf != null && picture.get_data<int?>("peek-page") == page_index) {
                    picture.set_paintable(Gdk.Texture.for_pixbuf(pixbuf));
                }

                // Guarded (rather than unconditional --) since
                // clear_peek_spinner() below can already have reset this to
                // 0 by the time a stray in-flight render finishes.
                if (pending_peek_renders > 0) pending_peek_renders--;
                if (pending_peek_renders == 0) clear_peek_spinner();
                return false;
            });
            return null;
        });
    }

    // Same layout as slot_box: page_index's picture, plus its spread
    // partner (page_index + 1) side by side with a 2px gap, in spread
    // mode - padded to the viewport size and centered exactly like
    // center_slot_if_smaller_than_viewport does for the real slot, so the
    // peek is pixel-for-pixel what the real page will look like once
    // swapped in. Without this, a page smaller than the viewport (below
    // fit zoom) would show flush against the peek's edge, then visibly
    // resize/jump to its centered position the instant the swap happened.
    // Doesn't touch any widget state (viewport size is passed in), so
    // it's also safe to call from a background thread (see render_peek).
    private Gdk.Pixbuf? render_spread_pixbuf_at(int page_index, double at_zoom, bool spread, int count, int viewport_w, int viewport_h) {
        var left = render_page_pixbuf_at(page_index, at_zoom);
        if (left == null) return null;

        int right_index = page_index + 1;
        Gdk.Pixbuf? right = null;
        if (spread && right_index < count) right = render_page_pixbuf_at(right_index, at_zoom);

        int content_w = left.get_width() + (right != null ? 2 + right.get_width() : 0);
        int content_h = right != null ? int.max(left.get_height(), right.get_height()) : left.get_height();

        int canvas_w = int.max(content_w, viewport_w);
        int canvas_h = int.max(content_h, viewport_h);
        int margin_x = (viewport_w > content_w) ? (viewport_w - content_w) / 2 : 0;
        int margin_y = (viewport_h > content_h) ? (viewport_h - content_h) / 2 : 0;

        // Transparent padding (via Cairo, not Gdk.Pixbuf.fill - a plain
        // RGB pixbuf can't represent transparency at all, and painting it
        // opaque white was exactly what showed as a stray white flash:
        // the real slot's margin is transparent widget margin, not a
        // painted background.
        var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, canvas_w, canvas_h);
        var cr = new Cairo.Context(surface);
        Gdk.cairo_set_source_pixbuf(cr, left, margin_x, margin_y);
        cr.paint();
        if (right != null) {
            Gdk.cairo_set_source_pixbuf(cr, right, margin_x + left.get_width() + 2, margin_y);
            cr.paint();
        }
        return Gdk.pixbuf_get_from_surface(surface, 0, 0, canvas_w, canvas_h);
    }

    private Gtk.Picture build_page_picture() {
        var pic = new Gtk.Picture();
        // can_shrink(false) is what makes zoom work - true would let
        // CONTAIN shrink the picture back down to fit the viewport,
        // undoing any zoomed-in render.
        pic.set_can_shrink(false);
        pic.set_content_fit(Gtk.ContentFit.CONTAIN);
        return pic;
    }

    private delegate void SwipeSettledCallback();

    // Drives swipe_surface.progress with an Adw.TimedAnimation on GTK's
    // own frame clock, applied via queue_allocate() - not a CSS
    // transform, matching AdwNavigationView's own real implementation
    // (gtk_widget_allocate() + GskTransform, confirmed against its
    // source before rewriting this). No physics, no overshoot -
    // initial_velocity (the swipe's own release speed, in Adw's
    // progress-per-second units) only shortens/lengthens the duration.
    //
    // Doesn't disable swipe_tracker while this plays - AdwNavigationView
    // doesn't either (its own gesture_active flag only guards the actual
    // touch, not the settle afterward), and get_progress() always
    // returning 0 (matching Adw) means a new gesture no longer has
    // anything of ours to fight over. See swipe_tracker's "prepare"
    // handler for how an in-flight animation gets skipped to completion
    // if a new gesture does start before it finishes.
    private void animate_swipe_transform(double from_progress, double to_progress, double initial_velocity, owned SwipeSettledCallback on_done, uint? fixed_duration = null) {
        uint duration;
        if (fixed_duration != null) {
            duration = fixed_duration;
        } else {
            double travel = (to_progress - from_progress).abs();
            double speed = double.max(1.0, initial_velocity.abs());
            duration = (uint) (travel / speed * 1000.0).clamp(80.0, 280.0);
        }

        var target = new Adw.CallbackAnimationTarget((value) => {
            swipe_surface.progress = value;
            swipe_surface.queue_allocate();
        });
        var animation = new Adw.TimedAnimation(swipe_surface, from_progress, to_progress, duration, (owned) target);
        animation.set_easing(Adw.Easing.EASE_OUT_CUBIC);
        active_swipe_animation = animation;
        animation.done.connect(() => {
            active_swipe_animation = null;
            on_done();
        });
        animation.play();
    }

    // Eases the old page off (continuing smoothly from wherever the drag
    // left it - a swipe can commit before reaching the full edge, so
    // handing off to go_to_page()'s own Stack transition directly meant
    // an instant snap back to center right before Stack's separate slide
    // started, i.e. the page visibly moved twice) and the peek into
    // place, then swaps with no Stack transition once the peek already
    // covers the viewport - that swap itself isn't visible. Same 280ms
    // pages_stack itself uses, so it still feels like the same motion as
    // a nav-button turn.
    private void commit_swipe_turn(int target_page, bool going_next, double from_progress, double initial_velocity) {
        double to_progress = going_next ? -1.0 : 1.0;
        animate_swipe_transform(from_progress, to_progress, initial_velocity, () => {
            go_to_page(target_page, false);
            swipe_surface.progress = 0;
            peek_next.set_visible(false);
            peek_prev.set_visible(false);
            swipe_surface.queue_allocate();
            // The page is already up by now (go_to_page() just rendered it
            // synchronously) - don't leave the spinner up waiting on some
            // other, no-longer-relevant peek render still in flight.
            clear_peek_spinner();
        }, 280);
    }

    // Released before committing to a turn - eases back to center, no
    // bounce (Adw.TimedAnimation, not a spring - see animate_swipe_transform).
    private void spring_back_swipe(double from_progress, double initial_velocity) {
        animate_swipe_transform(from_progress, 0, initial_velocity, () => {
            swipe_surface.progress = 0;
            peek_next.set_visible(false);
            peek_prev.set_visible(false);
            swipe_surface.queue_allocate();
            clear_peek_spinner();
        });
    }

    private void go_to_page(int index, bool animate = true) {
        if (document == null || index < 0 || index >= page_count || index == current_page) return;
        bool forward = index > current_page;
        int next_slot = 1 - active_slot;
        // current_page has to be updated before render_into_slot() - it
        // reads that field directly, not a parameter.
        current_page = index;
        update_cached_content_size();
        render_into_slot(next_slot);
        pages_stack.set_transition_type(!animate ? Gtk.StackTransitionType.NONE : forward ? Gtk.StackTransitionType.SLIDE_LEFT : Gtk.StackTransitionType.SLIDE_RIGHT);
        pages_stack.set_visible_child_name("slot%d".printf(next_slot));
        active_slot = next_slot;
        update_page_indicator_and_buttons();
        prefetch_adjacent_pages();
        toc_pane.set_current_page(current_page, spread_mode);
    }

    // anchor_x/anchor_y (scroller-viewport coords, -1 to skip) is a point
    // that should stay under the same spot on screen after the zoom
    // changes - used by the pinch gesture. Computed analytically from the
    // document's own page size and applied in the same call as the
    // render, rather than reading GTK's adjustment bounds after the fact
    // (those lag a frame behind the resize).
    // Whether the current page, at the current zoom, actually needs
    // scrolling to see all of it - not just "zoom <= 1.0". Fit-to-view on
    // a large (e.g. just-maximized) window can legitimately compute a
    // zoom above 1.0 for a page whose natural size is smaller than the
    // viewport, and at that zoom the whole page is still fully visible -
    // nothing to pan, so swipe should still work. Gating on the zoom
    // number instead of on whether content overflows the viewport is
    // what disabled it in exactly that case.
    private bool swipe_should_be_enabled() {
        if (document == null) return false;
        double content_w = cached_content_w * zoom;
        double content_h = cached_content_h * zoom;
        return content_w <= scroller.get_width() + 1 && content_h <= scroller.get_height() + 1;
    }

    private void set_zoom(double new_zoom, double anchor_x = -1, double anchor_y = -1) {
        if (document == null) return;
        double old_zoom = zoom;
        zoom = double.max(0.5, double.min(3.0, new_zoom));
        // Checked here, not just in swipe_tracker's "prepare" handler - a
        // disabled tracker stops processing input entirely, so "prepare"
        // never fires again to re-enable it once it no longer needs to
        // be disabled.
        swipe_tracker.enabled = swipe_should_be_enabled();
        if (zoom == old_zoom) return;

        bool anchored = anchor_x >= 0 && anchor_y >= 0;
        Gtk.Adjustment? hadj = null;
        Gtk.Adjustment? vadj = null;
        double target_h = 0, target_v = 0;
        double new_upper_h = 0, new_upper_v = 0;
        double viewport_w = 0, viewport_h = 0;

        if (anchored) {
            hadj = scroller.get_hadjustment();
            vadj = scroller.get_vadjustment();

            double points_w = cached_content_w;
            double points_h = cached_content_h;

            viewport_w = scroller.get_width();
            viewport_h = scroller.get_height();

            double content_x = hadj.get_value() + anchor_x;
            double content_y = vadj.get_value() + anchor_y;
            double ratio = zoom / old_zoom;
            target_h = content_x * ratio - anchor_x;
            target_v = content_y * ratio - anchor_y;

            new_upper_h = double.max(points_w * zoom, viewport_w);
            new_upper_v = double.max(points_h * zoom, viewport_h);
        }

        render_current_page();

        if (anchored) {
            double value_h = target_h.clamp(0, double.max(0, new_upper_h - viewport_w));
            double value_v = target_v.clamp(0, double.max(0, new_upper_v - viewport_h));
            hadj.configure(value_h, 0, new_upper_h, viewport_w * 0.1, viewport_w * 0.9, viewport_w);
            vadj.configure(value_v, 0, new_upper_v, viewport_h * 0.1, viewport_h * 0.9, viewport_h);
        }
    }

    // Computes the zoom level that fits whatever's currently shown (one
    // page, or a full spread) inside the visible viewport, then applies
    // it - "fit to window", not a fixed 100% "reset". A flat 1.0 zoom
    // (rendering at the PDF's own point-size in pixels) rarely matches
    // the viewport well: it can be far smaller than the available space
    // on a big display, or still require scrolling on a small one.
    private void fit_to_view() {
        if (document == null) return;
        set_zoom(compute_fit_zoom());
    }

    // Shared by fit_to_view() and the initial open - the zoom that fits
    // whatever's currently shown (one page, or a full spread) inside the
    // current viewport, falling back to 1.0 if the viewport isn't sized
    // yet.
    private double compute_fit_zoom() {
        if (document == null) return 1.0;

        double content_w = cached_content_w;
        double content_h = cached_content_h;

        int viewport_w = scroller.get_width();
        int viewport_h = scroller.get_height();
        if (viewport_w <= 0 || viewport_h <= 0 || content_w <= 0 || content_h <= 0) return 1.0;

        // Margin so the page doesn't render flush against the viewport's
        // own edges.
        const int MARGIN = 32;
        return double.min(
            (viewport_w - MARGIN) / content_w,
            (viewport_h - MARGIN) / content_h);
    }

    // Redraws the currently-visible slot in place - no stack transition.
    private void render_current_page() {
        if (document == null) return;
        render_into_slot(active_slot);
        update_page_indicator_and_buttons();
    }

    // Background-thread variant of render_current_page(), used only for
    // the initial open where the render can be slow on an image-heavy PDF.
    private void render_current_page_async(owned GLib.SourceFunc on_done) {
        if (document == null) { on_done(); return; }

        int slot = active_slot;
        int page_index = current_page;
        int right_index = page_index + 1;
        bool render_right = spread_mode && right_index < page_count;
        double render_zoom = zoom;

        new GLib.Thread<void*>("magazine-render-first-page", () => {
            var left_pixbuf = render_page_pixbuf_at(page_index, render_zoom);
            Gdk.Pixbuf? right_pixbuf = render_right ? render_page_pixbuf_at(right_index, render_zoom) : null;

            GLib.Idle.add(() => {
                if (left_pixbuf != null) left_pictures[slot].set_paintable(Gdk.Texture.for_pixbuf(left_pixbuf));
                if (render_right) {
                    right_pictures[slot].set_visible(true);
                    if (right_pixbuf != null) right_pictures[slot].set_paintable(Gdk.Texture.for_pixbuf(right_pixbuf));
                } else {
                    right_pictures[slot].set_visible(spread_mode);
                    right_pictures[slot].set_paintable(null);
                }
                center_slot_if_smaller_than_viewport(slot);
                update_page_indicator_and_buttons();
                on_done();
                return false;
            });
            return null;
        });
    }

    private void render_into_slot(int slot) {
        render_page_into(left_pictures[slot], current_page);

        int right_index = current_page + 1;
        if (spread_mode && right_index < page_count) {
            right_pictures[slot].set_visible(true);
            render_page_into(right_pictures[slot], right_index);
        } else {
            right_pictures[slot].set_visible(spread_mode);
            right_pictures[slot].set_paintable(null);
        }

        center_slot_if_smaller_than_viewport(slot);
    }

    // slot_box is START-aligned, so below fit zoom it'd sit pinned in the
    // corner - recreate the centered look with a plain margin instead.
    private void center_slot_if_smaller_than_viewport(int slot) {
        double content_w = left_pictures[slot].get_paintable()?.get_intrinsic_width() ?? 0;
        double content_h = left_pictures[slot].get_paintable()?.get_intrinsic_height() ?? 0;
        if (right_pictures[slot].get_visible() && right_pictures[slot].get_paintable() != null) {
            content_w += 2 + right_pictures[slot].get_paintable().get_intrinsic_width();
            content_h = double.max(content_h, right_pictures[slot].get_paintable().get_intrinsic_height());
        }

        int viewport_w = scroller.get_width();
        int viewport_h = scroller.get_height();

        int margin_x = (viewport_w > content_w) ? (int) ((viewport_w - content_w) / 2) : 0;
        int margin_y = (viewport_h > content_h) ? (int) ((viewport_h - content_h) / 2) : 0;
        slot_boxes[slot].set_margin_start(margin_x);
        slot_boxes[slot].set_margin_top(margin_y);
    }

    private void update_page_indicator_and_buttons() {
        int right_index = current_page + 1;
        if (spread_mode && right_index < page_count) {
            page_label.set_text("Pages %d–%d of %d".printf(current_page + 1, right_index + 1, page_count));
        } else {
            page_label.set_text("Page %d of %d".printf(current_page + 1, page_count));
        }
        prev_button.set_sensitive(current_page > 0);
        next_button.set_sensitive(current_page + 1 < page_count);
        nav_buttons.left_button.set_sensitive(current_page > 0);
        nav_buttons.right_button.set_sensitive(current_page + 1 < page_count);
    }

    private void render_page_into(Gtk.Picture target, int page_index) {
        var pixbuf = render_page_pixbuf(page_index);
        if (pixbuf != null) target.set_paintable(Gdk.Texture.for_pixbuf(pixbuf));
    }

    private Gdk.Pixbuf? render_page_pixbuf(int page_index) {
        return render_page_pixbuf_at(page_index, zoom);
    }

    // Doesn't touch any widget state, so it's also safe to call from a
    // background thread (see render_current_page_async above) - Poppler
    // itself isn't thread-safe though, so every call into it is locked.
    private Gdk.Pixbuf? render_page_pixbuf_at(int page_index, double at_zoom) {
        poppler_lock.lock();
        try {
            var page = document.get_page(page_index);
            double w, h;
            page.get_size(out w, out h);

            int out_w = int.max(1, (int) (w * at_zoom));
            int out_h = int.max(1, (int) (h * at_zoom));

            var surface = new Cairo.ImageSurface(Cairo.Format.RGB24, out_w, out_h);
            var cr = new Cairo.Context(surface);
            cr.set_source_rgb(1, 1, 1);
            cr.paint();
            cr.scale(at_zoom, at_zoom);
            page.render(cr);

            return Gdk.pixbuf_get_from_surface(surface, 0, 0, out_w, out_h);
        } finally {
            poppler_lock.unlock();
        }
    }

    private void poppler_get_page_size(int page_index, out double w, out double h) {
        poppler_lock.lock();
        document.get_page(page_index).get_size(out w, out h);
        poppler_lock.unlock();
    }

    // Refreshes cached_content_w/h for the current page (and, in spread
    // mode, its partner) - called once whenever current_page or
    // spread_mode actually changes, not from the gesture-handling path
    // itself (see the cached_content_w/h field comment).
    private void update_cached_content_size() {
        if (document == null) { cached_content_w = 0; cached_content_h = 0; return; }
        double points_w, points_h;
        poppler_get_page_size(current_page, out points_w, out points_h);
        int right_index = current_page + 1;
        if (spread_mode && right_index < page_count) {
            double rw, rh;
            poppler_get_page_size(right_index, out rw, out rh);
            points_w += rw + 2; // + the gap between the two pictures
            points_h = double.max(points_h, rh);
        }
        cached_content_w = points_w;
        cached_content_h = points_h;
    }

    // Gtk.Revealer sizes to its child's natural size - cap root's height
    // explicitly, same idea as PodcastPane.resize_sheet(), but the full
    // content view height (not a peek fraction) since reading a page
    // needs all the space it can get.
    private void resize_sheet() {
        int content_h = (window != null && window.content_view != null && window.content_view.main_scrolled.get_height() > 0)
            ? window.content_view.main_scrolled.get_height()
            : (window != null ? window.get_height() : 800);
        if (content_h < 480) content_h = 480;
        root.set_size_request(-1, content_h);
    }
}
