/* Tests for the image caching layer ImageManager sits on: LruCache
 * (eviction, byte budget, callbacks) and ImageCache (pixbuf/texture
 * coherence, cover-crop). Pins current behavior ahead of the
 * imageManager.vala refactor. Headless - no display needed. */

Gdk.Pixbuf solid(int w, int h, int64 rgba) {
    var pb = new Gdk.Pixbuf(Gdk.Colorspace.RGB, true, 8, w, h);
    pb.fill((uint32) rgba);
    return pb;
}

uint8 alpha_at(Gdk.Pixbuf pb, int x, int y) {
    unowned uint8[] px = pb.get_pixels_with_length();
    return px[y * pb.rowstride + x * pb.n_channels + 3];
}

// --- LruCache ---------------------------------------------------------

void test_lru_evicts_least_recently_used() {
    var c = new LruCache<string, string>(2);
    c.set("a", "1");
    c.set("b", "2");
    c.get("a");          // a is now most recent
    c.set("c", "3");     // evicts b
    assert_nonnull(c.get("a"));
    assert_null(c.get("b"));
    assert_nonnull(c.get("c"));
    assert_cmpint(c.size(), GLib.CompareOperator.EQ, 2);
}

void test_lru_update_existing_keeps_size() {
    var c = new LruCache<string, string>(2);
    c.set("a", "1");
    c.set("a", "2");
    assert_cmpint(c.size(), GLib.CompareOperator.EQ, 1);
    assert_cmpstr(c.get("a"), GLib.CompareOperator.EQ, "2");
}

void test_lru_eviction_callback_fires() {
    var c = new LruCache<string, string>(1);
    var evicted = new Gee.ArrayList<string>();
    c.set_eviction_callback((k, v) => { evicted.add(k); });

    c.set("a", "1");
    c.set("b", "2");     // capacity eviction
    assert_true(evicted.size == 1 && evicted[0] == "a");

    assert_true(c.remove("b"));
    assert_true(evicted.size == 2 && evicted[1] == "b");
    assert_false(c.remove("missing"));

    c.set("c", "3");
    c.clear();
    assert_true(evicted.size == 3 && evicted[2] == "c");
    assert_cmpint(c.size(), GLib.CompareOperator.EQ, 0);
}

void test_lru_byte_budget() {
    var c = new LruCache<string, string>(100);
    c.set_byte_budget(10, (k, v) => { return (int64) v.length; });
    c.set("a", "xxxx");      // 4
    c.set("b", "xxxx");      // 8
    c.set("c", "xxxx");      // 12 > 10: evicts a
    assert_null(c.get("a"));
    assert_nonnull(c.get("b"));

    // Shrinking an existing entry must credit its old size back, so
    // this fits without evicting anything.
    c.set("b", "x");         // 5
    c.set("d", "xxxx");      // 9
    assert_nonnull(c.get("b"));
    assert_nonnull(c.get("c"));
    assert_nonnull(c.get("d"));
}

void test_lru_set_capacity_trims_and_defaults() {
    var c = new LruCache<string, string>(4);
    c.set("a", "1"); c.set("b", "2"); c.set("c", "3");
    c.set_capacity(1);
    assert_cmpint(c.size(), GLib.CompareOperator.EQ, 1);
    assert_nonnull(c.get("c"));

    c.set_capacity(0);       // ignored
    assert_cmpint(c.get_capacity(), GLib.CompareOperator.EQ, 1);
    assert_cmpint(new LruCache<string, string>(0).get_capacity(), GLib.CompareOperator.EQ, 128);
}

void test_lru_keys_in_lru_order() {
    var c = new LruCache<string, string>(4);
    c.set("a", "1"); c.set("b", "2"); c.set("c", "3");
    c.get("a");
    var keys = c.keys();
    assert_cmpstr(string.joinv(",", keys.to_array()), GLib.CompareOperator.EQ, "b,c,a");
}

// --- ImageCache -------------------------------------------------------

void test_cache_set_invalidates_texture() {
    var cache = new ImageCache(8);
    cache.set("k", solid(4, 4, 0xff0000ff));
    var t1 = cache.get_texture("k");
    assert_nonnull(t1);
    assert_true(cache.get_texture("k") == t1);   // reused, not re-uploaded

    cache.set("k", solid(8, 8, 0x00ff00ff));
    var t2 = cache.get_texture("k");
    assert_true(t2 != t1);
    assert_cmpint(t2.get_width(), GLib.CompareOperator.EQ, 8);
}

void test_cache_eviction_drops_texture() {
    var cache = new ImageCache(1);
    cache.set("a", solid(4, 4, 0xff0000ff));
    assert_nonnull(cache.get_texture("a"));
    cache.set("b", solid(4, 4, 0xff0000ff));     // evicts a's pixbuf
    assert_null(cache.get("a"));
    assert_null(cache.get_texture("a"));
}

void test_cache_get_texture_missing_key() {
    assert_null(new ImageCache(4).get_texture("nope"));
}

void test_crop_produces_exact_size_and_caches() {
    var cache = new ImageCache(8);
    var src = solid(400, 100, 0x336699ff);
    var result = cache.get_or_scale_and_crop_pixbuf("k", src, 120, 90);
    assert_nonnull(result);
    assert_cmpint(result.width, GLib.CompareOperator.EQ, 120);
    assert_cmpint(result.height, GLib.CompareOperator.EQ, 90);

    // Second call is a cache hit: returns the stored result even if a
    // different source is passed.
    var again = cache.get_or_scale_and_crop_pixbuf("k", solid(10, 10, 0), 120, 90);
    assert_true(again == result);
}

void test_crop_center_keeps_middle() {
    // 300x100: left third red, middle green, right third blue. Cropping
    // to a square keeps the middle third, so the center is green and the
    // red/blue thirds are cut off entirely.
    var src = solid(300, 100, 0x00ff00ff);
    solid(100, 100, 0xff0000ff).copy_area(0, 0, 100, 100, src, 0, 0);
    solid(100, 100, 0x0000ffff).copy_area(0, 0, 100, 100, src, 200, 0);

    var result = new ImageCache(4).get_or_scale_and_crop_pixbuf("k", src, 50, 50);
    unowned uint8[] px = result.get_pixels_with_length();
    int mid = 25 * result.rowstride + 25 * result.n_channels;
    assert_cmpuint(px[mid], GLib.CompareOperator.LT, 32);       // R
    assert_cmpuint(px[mid + 1], GLib.CompareOperator.GT, 220);  // G
    assert_cmpuint(px[mid + 2], GLib.CompareOperator.LT, 32);   // B
}

void test_crop_edges_fully_opaque() {
    // A cover crop must fill the whole target. Truncating the scaled
    // size can leave it a pixel short, painting a transparent strip
    // along one edge.
    int[,] cases = {
        // src_w, src_h, dst_w, dst_h
        { 3, 3, 10, 10 },
        { 600, 400, 1000, 500 },
        { 7, 13, 100, 100 },
        { 1920, 1080, 333, 187 },
        { 640, 427, 1200, 675 },
    };
    for (int i = 0; i < cases.length[0]; i++) {
        var src = solid(cases[i, 0], cases[i, 1], 0x808080ff);
        int w = cases[i, 2], h = cases[i, 3];
        var result = new ImageCache(4).get_or_scale_and_crop_pixbuf("k", src, w, h);
        foreach (int x in new int[] { 0, w - 1 }) {
            foreach (int y in new int[] { 0, h / 2, h - 1 }) {
                if (alpha_at(result, x, y) != 255) {
                    GLib.Test.message("%dx%d -> %dx%d: alpha %u at (%d,%d)",
                        cases[i, 0], cases[i, 1], w, h, alpha_at(result, x, y), x, y);
                    GLib.Test.fail();
                }
            }
        }
        foreach (int y in new int[] { 0, h - 1 }) {
            if (alpha_at(result, w / 2, y) != 255) {
                GLib.Test.message("%dx%d -> %dx%d: alpha %u at (%d,%d)",
                    cases[i, 0], cases[i, 1], w, h, alpha_at(result, w / 2, y), w / 2, y);
                GLib.Test.fail();
            }
        }
    }
}

void test_load_file_missing_returns_null() {
    var cache = new ImageCache(4);
    assert_null(cache.get_or_load_file("k", "/nonexistent/x.png", 0, 0));
    assert_cmpint(cache.size(), GLib.CompareOperator.EQ, 0);
}

void test_load_file_roundtrip() throws GLib.Error {
    string dir = GLib.DirUtils.make_tmp("paperboy-test-XXXXXX");
    string path = GLib.Path.build_filename(dir, "img.png");
    solid(40, 20, 0xff0000ff).savev(path, "png", null, null);

    var cache = new ImageCache(4);
    var full = cache.get_or_load_file("full", path, 0, 0);
    assert_cmpint(full.width, GLib.CompareOperator.EQ, 40);
    var scaled = cache.get_or_load_file("scaled", path, 20, 20);   // keeps aspect
    assert_cmpint(scaled.width, GLib.CompareOperator.EQ, 20);
    assert_cmpint(scaled.height, GLib.CompareOperator.EQ, 10);
    assert_true(cache.get("full") == full);

    GLib.FileUtils.remove(path);
    GLib.DirUtils.remove(dir);
}

// --- ImageManager static helpers --------------------------------------

void test_preview_cache_key_format() {
    assert_cmpstr(ImageManager.make_preview_cache_key("https://x/a.jpg", 300, 200),
        GLib.CompareOperator.EQ, "https://x/a.jpg@300x200");
}

void test_upgraded_dimension() {
    assert_cmpint(ImageManager.upgraded_dimension(300), GLib.CompareOperator.EQ, 600);     // doubles
    assert_cmpint(ImageManager.upgraded_dimension(1000), GLib.CompareOperator.EQ, 1600);   // capped
    assert_cmpint(ImageManager.upgraded_dimension(1600), GLib.CompareOperator.EQ, 1600);
    // Already past the cap (e.g. a 6x hero): never shrink.
    assert_cmpint(ImageManager.upgraded_dimension(2400), GLib.CompareOperator.EQ, 2400);
}

void test_cache_key_format() {
    assert_cmpstr(ImageManager.make_cache_key("https://x/a.jpg", 120, 90),
        GLib.CompareOperator.EQ, "pixbuf::url:https://x/a.jpg::120x90");
}

void test_download_url_for() {
    // Guardian CDN: any width is rewritten to 1000px (it 403s above that).
    assert_cmpstr(ImageManager.download_url_for("https://i.guim.co.uk/img/media/abc/0_0_3000_1800/master/3000.jpg"),
        GLib.CompareOperator.EQ, "https://i.guim.co.uk/img/media/abc/0_0_3000_1800/master/3000.jpg");   // other host: untouched
    assert_cmpstr(ImageManager.download_url_for("https://media.guim.co.uk/abc/0_0_3000_1800/2000.JPG"),
        GLib.CompareOperator.EQ, "https://media.guim.co.uk/abc/0_0_3000_1800/1000.JPG");
    assert_cmpstr(ImageManager.download_url_for("https://media.guim.co.uk/abc/500.png"),
        GLib.CompareOperator.EQ, "https://media.guim.co.uk/abc/1000.png");
    // No trailing /<width>.<ext>: unchanged.
    assert_cmpstr(ImageManager.download_url_for("https://media.guim.co.uk/abc/photo.webp"),
        GLib.CompareOperator.EQ, "https://media.guim.co.uk/abc/photo.webp");
    assert_cmpstr(ImageManager.download_url_for("https://example.com/2000.jpg"),
        GLib.CompareOperator.EQ, "https://example.com/2000.jpg");
}

int main(string[] args) {
    GLib.Test.init(ref args);
    GLib.Test.add_func("/lru/evicts_lru", test_lru_evicts_least_recently_used);
    GLib.Test.add_func("/lru/update_existing", test_lru_update_existing_keeps_size);
    GLib.Test.add_func("/lru/eviction_callback", test_lru_eviction_callback_fires);
    GLib.Test.add_func("/lru/byte_budget", test_lru_byte_budget);
    GLib.Test.add_func("/lru/set_capacity", test_lru_set_capacity_trims_and_defaults);
    GLib.Test.add_func("/lru/keys_order", test_lru_keys_in_lru_order);
    GLib.Test.add_func("/image_cache/set_invalidates_texture", test_cache_set_invalidates_texture);
    GLib.Test.add_func("/image_cache/eviction_drops_texture", test_cache_eviction_drops_texture);
    GLib.Test.add_func("/image_cache/texture_missing", test_cache_get_texture_missing_key);
    GLib.Test.add_func("/image_cache/crop_size_and_cache", test_crop_produces_exact_size_and_caches);
    GLib.Test.add_func("/image_cache/crop_center", test_crop_center_keeps_middle);
    GLib.Test.add_func("/image_cache/crop_edges_opaque", test_crop_edges_fully_opaque);
    GLib.Test.add_func("/image_cache/load_missing", test_load_file_missing_returns_null);
    GLib.Test.add_func("/image_cache/load_roundtrip", () => {
        try { test_load_file_roundtrip(); } catch (GLib.Error e) { error(e.message); }
    });
    GLib.Test.add_func("/image_manager/preview_cache_key", test_preview_cache_key_format);
    GLib.Test.add_func("/image_manager/upgraded_dimension", test_upgraded_dimension);
    GLib.Test.add_func("/image_manager/cache_key", test_cache_key_format);
    GLib.Test.add_func("/image_manager/download_url_for", test_download_url_for);
    return GLib.Test.run();
}
