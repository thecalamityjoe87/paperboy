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

// Compact row card used only by the History page - a short row with a
// thumbnail bleeding edge-to-edge on the left and a wide text area on the
// right (title, source, "viewed" caption), instead of the full vertical
// image-on-top layout ArticleCard uses everywhere else. History is a flat
// list of already-read articles, not a traditional grid.
public class HistoryCard : GLib.Object {
    // The image gets 30% of the card's width, text gets the other 70% -
    // proportional to the card's actual (full content-width) size rather
    // than a fixed pixel count, so it scales with the window.
    public const double IMAGE_WIDTH_FRACTION = 0.3;
    // Maintains the card proportions defined by the History page design.
    public const double CARD_ASPECT_RATIO = 2.90;

    public Gtk.Box root;
    public Gtk.Overlay overlay;
    public Gtk.Picture image;
    public Gtk.Widget category_label;
    public Gtk.Label title_label;
    public Gtk.Label time_label;
    // Bottom-right of the text area, opposite time_label - where the
    // source badge goes (see ArticleManager.place_history_card()), not
    // overlaid on the image like every other card type.
    public Gtk.Box badge_slot;
    public string url;
    public string title_text;
    public string? source_name;
    public string? category_id;
    public string? thumbnail_url;
    // Actual pixel width the image was built at (30% of col_w) - callers
    // use this instead of a fixed constant when requesting image data.
    public int image_width;

    // `viewed_timestamp` is Unix seconds - when the user actually read this
    // article, not when it was published, since that's what History cards
    // need to tell the user ("Viewed 3h ago"). `category_display_name` is
    // the article's real category ("Markets", "Technology", ...), shown as
    // plain blue text above the title rather than an overlay chip on the
    // image. `col_w` is the full content width (a single wide row, not a
    // grid column) - without an explicit width the row shrinks to its
    // content instead of spanning the page.
    public HistoryCard(string title, string url, string? source_name, int64 viewed_timestamp, string? category_display_name, int col_w) {
        GLib.Object();
        this.url = url;
        this.title_text = title;
        this.source_name = source_name;
        this.image_width = (int)(col_w * IMAGE_WIDTH_FRACTION);
        int card_height = (int)(col_w / CARD_ASPECT_RATIO);

        root = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        root.add_css_class("card");
        root.add_css_class("history-card");
        root.set_hexpand(true);
        root.set_halign(Gtk.Align.FILL);
        // Always exactly col_w - never wider. A card widening itself
        // beyond its assigned grid column pushes the whole row/page wider
        // (already happened once from a stray text_box size_request; never
        // let a card's own content dictate the page's width again).
        root.set_size_request(col_w, card_height);
        root.set_overflow(Gtk.Overflow.HIDDEN);

        // Bleeds edge-to-edge in its own area - no margin, matching the
        // card's own measured-ratio height exactly.
        image = new Gtk.Picture();
        image.set_size_request(image_width, card_height);
        image.set_content_fit(Gtk.ContentFit.COVER);
        image.set_can_shrink(true);
        // Without this, a loaded texture's own aspect ratio overrides the
        // explicit width above once it loads - every other horizontal
        // cover-art usage in this codebase (podcastCard.vala etc.) already
        // disables it for the same reason.
        image.set_keep_aspect_ratio(false);
        image.set_hexpand(false);
        image.set_vexpand(true);
        image.set_halign(Gtk.Align.FILL);
        image.set_valign(Gtk.Align.FILL);

        overlay = new Gtk.Overlay();
        overlay.set_child(image);
        overlay.set_size_request(image_width, card_height);
        overlay.set_hexpand(false);
        overlay.set_vexpand(true);
        overlay.set_halign(Gtk.Align.FILL);
        overlay.set_valign(Gtk.Align.FILL);
        root.append(overlay);

        var text_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        text_box.set_valign(Gtk.Align.FILL);
        text_box.set_vexpand(true);
        text_box.set_hexpand(true);
        // No explicit size_request here - title_label's own margin-adjusted
        // minimum (below) already gives text_box its correct floor via its
        // child. Requesting the full 70% again on top of that, without
        // accounting for the margins set below, made this box's real
        // footprint col_w+26 instead of col_w - 26px too wide per card,
        // per column, which added up to widening the whole page.
        text_box.set_margin_start(12);
        text_box.set_margin_top(8);
        text_box.set_margin_bottom(4);
        text_box.set_margin_end(14);

        if (category_display_name != null && category_display_name.length > 0) {
            category_label = CardBuilder.build_category_label(category_display_name);
            text_box.append(category_label);
        }

        title_label = new Gtk.Label(title);
        title_label.add_css_class("article-card-title");
        title_label.set_ellipsize(Pango.EllipsizeMode.END);
        title_label.set_xalign(0);
        title_label.set_valign(Gtk.Align.START);
        title_label.set_wrap(true);
        title_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        title_label.set_lines(2);
        // Same idea as ArticleCard's own title_label sizing - an
        // unconstrained label (e.g. a long URL used as a fallback title)
        // can request more than its column, pushing the image wider than
        // its 30% share to make room.
        title_label.set_size_request((int)(col_w * (1.0 - IMAGE_WIDTH_FRACTION)) - 26, -1);
        text_box.append(title_label);

        // A plain filler consumes all the leftover vertical space itself,
        // so bottom_row (appended after it, with no vexpand of its own)
        // sits flush at the very bottom edge - vexpand directly on
        // bottom_row instead centered it within the expanded area rather
        // than anchoring it to the edge.
        var spacer = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        // Creates a minimum gap between the title and bottom row.
        spacer.set_size_request(-1, 22);
        spacer.set_vexpand(true);
        text_box.append(spacer);

        var bottom_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);

        string viewed_text = "Viewed " + DateUtils.time_ago(viewed_timestamp.to_string());
        time_label = new Gtk.Label(viewed_text);
        time_label.add_css_class("article-card-time");
        time_label.set_xalign(0);
        time_label.set_hexpand(true);
        time_label.set_ellipsize(Pango.EllipsizeMode.END);
        bottom_row.append(time_label);

        // Caller (ArticleManager.place_history_card()) appends the source
        // badge here instead of overlaying it on the image. Must stay
        // within the card's existing col_w - see the "never wider than
        // col_w" note on root above.
        badge_slot = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        badge_slot.set_hexpand(false);
        badge_slot.set_halign(Gtk.Align.END);
        badge_slot.set_valign(Gtk.Align.CENTER);
        bottom_row.append(badge_slot);

        text_box.append(bottom_row);

        root.append(text_box);

        root.set_data("article-url", url);
        root.set_data("article-title-text", title);
        root.set_data("article-time-label", time_label);
    }
}
