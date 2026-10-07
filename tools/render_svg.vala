// Renders SVGs to 72x72 PNGs with GdkPixbuf - which uses librsvg, the same
// renderer GTK uses for Paperboy's icons. Used by flag_levels.py.
//
// usage: render_svg IN.svg OUT.png [IN.svg OUT.png ...]
void main(string[] args) {
    for (int i = 1; i + 1 < args.length; i += 2) {
        try {
            var pb = new Gdk.Pixbuf.from_file_at_size(args[i], 72, 72);
            pb.savev(args[i + 1], "png", {}, {});
        } catch (Error e) {
            stderr.printf("%s: %s\n", args[i], e.message);
        }
    }
}
