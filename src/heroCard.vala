using Gtk;
using GLib;

public class HeroCard : GLib.Object {
    public Gtk.Box root;
    public Gtk.Overlay overlay;
    public Gtk.Picture image;
    public Gtk.Label title_label;
    public string url;

    // Signal emitted when the hero/slide is activated (clicked)
    public signal void activated(string url);

    public HeroCard(string title, string url, int max_total_height, int image_h, Gtk.Widget? chip) {
        GLib.Object();
        this.url = url;

        root = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        root.set_size_request(-1, max_total_height);
        root.set_hexpand(true);
        root.set_vexpand(false);
        root.set_halign(Gtk.Align.FILL);
        root.set_valign(Gtk.Align.START);
        root.set_margin_start(0);
        root.set_margin_end(0);

        image = new Gtk.Picture();
        image.set_halign(Gtk.Align.FILL);
        image.set_hexpand(true);
        image.set_size_request(-1, image_h);
        image.set_content_fit(Gtk.ContentFit.COVER);
        image.set_can_shrink(true);

        overlay = new Gtk.Overlay();
        overlay.set_child(image);
        if (chip != null) {
            try { overlay.add_overlay(chip); } catch (GLib.Error e) { }
        }

        root.append(overlay);

        var title_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
        title_box.set_margin_start(16);
        title_box.set_margin_end(16);
        title_box.set_margin_top(16);
        title_box.set_margin_bottom(16);
        title_box.set_vexpand(true);

        title_label = new Gtk.Label(title);
        title_label.set_ellipsize(Pango.EllipsizeMode.END);
        title_label.set_xalign(0);
        title_label.set_wrap(true);
        title_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        title_label.set_lines(8);
        title_label.set_max_width_chars(88);
        title_box.append(title_label);
        root.append(title_box);

        // Click gesture -> emit activated
        var gesture = new Gtk.GestureClick();
        try { gesture.set_button(1); } catch (GLib.Error e) { }
        gesture.released.connect(() => {
            try { activated(this.url); } catch (GLib.Error e) { }
        });
        root.add_controller(gesture);

        // Hover effects
        var motion = new Gtk.EventControllerMotion();
        motion.enter.connect(() => { root.add_css_class("card-hover"); });
        motion.leave.connect(() => { root.remove_css_class("card-hover"); });
        root.add_controller(motion);
    }
}
