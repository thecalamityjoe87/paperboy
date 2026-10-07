/* Tests for RssFeedProcessor.parse_rss_and_display against saved feed
 * fixtures (tests/fixtures/feeds). Offline: no feed_url is passed, so the
 * article cache is skipped, and PAPERBOY_ENABLE_BBC_EXTRACT=0 disables the
 * BBC image-upgrade thread. XDG dirs point at a scratch dir (see
 * tests/meson.build) since the reading-time cache writes to disk. */

class Collected : GLib.Object {
    public Gee.ArrayList<ArticleItem> items = new Gee.ArrayList<ArticleItem>();
    public Gee.ArrayList<string> labels = new Gee.ArrayList<string>();
    public int clears = 0;

    public ArticleItem? find(string url) {
        foreach (var it in items) if (it.url == url) return it;
        return null;
    }

    public string urls() {
        var parts = new string[0];
        foreach (var it in items) parts += it.url;
        return string.joinv(" ", parts);
    }
}

Soup.Session session;

string fixture(string name) {
    string path = GLib.Path.build_filename(GLib.Environment.get_variable("PAPERBOY_TEST_FIXTURES"), "feeds", name);
    string body;
    try {
        GLib.FileUtils.get_contents(path, out body);
    } catch (GLib.FileError e) {
        error("fixture %s: %s", path, e.message);
    }
    return body;
}

Collected parse(string body, string category_id = "general", string source_name = "Example", string query = "") {
    var c = new Collected();
    var sink = new FetchSink(null,
        (item) => { c.items.add(item); },
        (text, is_error) => { c.labels.add(text); },
        () => { c.clears++; });
    RssFeedProcessor.parse_rss_and_display(body, source_name, "World", category_id, query, sink, session);
    // Results arrive through nested Idle callbacks; run them all.
    var ctx = GLib.MainContext.default();
    while (ctx.pending()) ctx.iteration(false);
    return c;
}

// Marks a confirmed, not-yet-fixed bug: reported as an expected failure
// (TAP "TODO") so the suite stays green. Once the bug is fixed the
// condition holds and the test simply passes - then drop the wrapper.
void known_bug(bool ok, string what) {
    if (!ok) GLib.Test.incomplete("known bug: " + what);
}

// --- RSS 2.0 ----------------------------------------------------------

void test_rss2_items_and_label() {
    var c = parse(fixture("rss2.xml"));
    assert_cmpint(c.items.size, GLib.CompareOperator.EQ, 4);   // the link-less item is dropped
    assert_cmpint(c.clears, GLib.CompareOperator.EQ, 1);
    assert_cmpstr(c.labels[0], GLib.CompareOperator.EQ, "World — Example");
    // Feed order is preserved for non-local categories.
    assert_cmpstr(c.items[0].url, GLib.CompareOperator.EQ, "https://news.example.com/el-nino");
}

void test_rss2_title_entity_and_snippet() {
    var it = parse(fixture("rss2.xml")).find("https://news.example.com/el-nino");
    assert_cmpstr(it.title, GLib.CompareOperator.EQ, "El Niño returns");
    assert_cmpstr(it.snippet, GLib.CompareOperator.EQ, "Forecasters say warmer waters are back.");
    assert_cmpstr(it.published, GLib.CompareOperator.EQ, "Mon, 06 Oct 2026 10:00:00 +0000");
    assert_cmpstr(it.category_id, GLib.CompareOperator.EQ, "general");
    assert_cmpstr(it.source_name, GLib.CompareOperator.EQ, "Example");
}

void test_rss2_widest_media_thumbnail() {
    var it = parse(fixture("rss2.xml")).find("https://news.example.com/el-nino");
    assert_cmpstr(it.thumbnail_url, GLib.CompareOperator.EQ, "https://img.example.com/elnino-large.jpg");
}

void test_rss2_media_content_protocol_relative() {
    var it = parse(fixture("rss2.xml")).find("https://news.example.com/media");
    assert_cmpstr(it.thumbnail_url, GLib.CompareOperator.EQ, "https://cdn.example.com/photo.jpg");
}

void test_rss2_image_from_content_encoded() {
    var it = parse(fixture("rss2.xml")).find("https://news.example.com/encoded");
    assert_cmpstr(it.thumbnail_url, GLib.CompareOperator.EQ, "https://img.example.com/inline.jpg");
}

void test_rss2_comments_url_registered() {
    parse(fixture("rss2.xml"));
    assert_cmpstr(Paperboy.CommentsUrlRegistry.lookup("https://news.example.com/el-nino"),
        GLib.CompareOperator.EQ, "https://news.example.com/el-nino/feed/");
}

void test_rss2_dc_date() {
    // The Atom branch accepts dc:date; RSS 2.0 items using it should get a date too.
    var it = parse(fixture("rss2.xml")).find("https://news.example.com/dc-date");
    assert_nonnull(it);
    assert_cmpstr(it.published, GLib.CompareOperator.EQ, "2026-10-06T07:00:00Z");
}

// --- Atom -------------------------------------------------------------

void test_atom_entries() {
    var c = parse(fixture("atom.xml"));
    assert_cmpint(c.items.size, GLib.CompareOperator.EQ, 3);

    var first = c.find("https://blog.example.com/first");
    assert_nonnull(first);
    assert_cmpstr(first.published, GLib.CompareOperator.EQ, "2026-10-05T12:00:00Z");   // published beats updated
    assert_cmpstr(first.snippet, GLib.CompareOperator.EQ, "A short summary.");
    assert_cmpstr(first.thumbnail_url, GLib.CompareOperator.EQ, "https://img.example.com/first.png");

    var second = c.find("https://blog.example.com/second");
    assert_nonnull(second);
    assert_cmpstr(second.published, GLib.CompareOperator.EQ, "2026-10-04T12:00:00Z");  // updated as fallback
}

void test_atom_prefers_alternate_link() {
    // WordPress-style entries list rel="replies" after rel="alternate";
    // the article URL is the alternate one, not the comments feed.
    var c = parse(fixture("atom.xml"));
    assert_nonnull(c.find("https://blog.example.com/third"));
    assert_null(c.find("https://blog.example.com/third/comments/feed"));
}

void test_atom_link_fallbacks() {
    // No rel means alternate; with only non-alternate rels, the first is used
    // rather than dropping the entry.
    string body = """<feed xmlns="http://www.w3.org/2005/Atom">
  <entry><title>a</title><link rel="replies" href="https://x.example/a/comments"/><link href="https://x.example/a"/></entry>
  <entry><title>b</title><link rel="related" href="https://x.example/b-related"/><link rel="replies" href="https://x.example/b/comments"/></entry>
</feed>""";
    var c = parse(body);
    assert_cmpstr(c.urls(), GLib.CompareOperator.EQ, "https://x.example/a https://x.example/b-related");
}

// --- RSS 1.0 (RDF) ----------------------------------------------------

void test_rdf_items() {
    // In RSS 1.0, <item> elements are siblings of <channel>, not children.
    var c = parse(fixture("rdf.xml"));
    assert_cmpint(c.items.size, GLib.CompareOperator.EQ, 1);
    assert_cmpstr(c.items[0].url, GLib.CompareOperator.EQ, "https://rdf.example.com/one");
    assert_cmpstr(c.items[0].title, GLib.CompareOperator.EQ, "RSS 1.0 item");
    assert_cmpstr(c.items[0].published, GLib.CompareOperator.EQ, "2026-10-06T07:00:00Z");
}

// --- Google News / local news -----------------------------------------

void test_google_news_publisher() {
    var c = parse(fixture("googlenews.xml"), "general", GoogleNewsUtils.AGGREGATOR_NAME);
    var it = c.find("https://news.google.com/rss/articles/abc");
    assert_cmpstr(it.title, GLib.CompareOperator.EQ, "Council approves budget");   // " - Publisher" stripped
    assert_cmpstr(SourceLabel.name_of(it.source_name), GLib.CompareOperator.EQ, "Springfield Gazette");
    assert_nonnull(SourceLabel.parse(it.source_name).logo_url);
}

void test_local_news_sorted_newest_first() {
    var c = parse(fixture("googlenews.xml"), "local_news");
    assert_cmpint(c.items.size, GLib.CompareOperator.EQ, 3);
    assert_cmpstr(c.items[0].url, GLib.CompareOperator.EQ, "https://news.google.com/rss/articles/def");
    assert_cmpstr(c.items[1].url, GLib.CompareOperator.EQ, "https://news.google.com/rss/articles/abc");
    assert_cmpstr(c.items[2].url, GLib.CompareOperator.EQ, "https://news.google.com/rss/articles/ghi");   // undated last
}

void test_local_news_capped_at_30() {
    var sb = new StringBuilder("<rss><channel>");
    for (int i = 0; i < 45; i++) {
        sb.append_printf("<item><title>T%d</title><link>https://x.example/%d</link><pubDate>Mon, 06 Oct 2026 %02d:%02d:00 +0000</pubDate></item>", i, i, i / 60, i % 60);
    }
    sb.append("</channel></rss>");
    var c = parse(sb.str, "local_news");
    assert_cmpint(c.items.size, GLib.CompareOperator.EQ, 30);
    assert_cmpstr(c.items[0].url, GLib.CompareOperator.EQ, "https://x.example/44");
}

// --- Enclosures -------------------------------------------------------

void test_image_enclosure_used() {
    var it = parse(fixture("podcast.xml")).find("https://pod.example.com/img");
    assert_cmpstr(it.thumbnail_url, GLib.CompareOperator.EQ, "https://pod.example.com/cover.jpg?a=1&b=2");
}

void test_audio_enclosure_not_thumbnail() {
    // An mp3 is not an image; using it as a thumbnail makes the image
    // pipeline download the whole file into memory before failing to decode.
    var it = parse(fixture("podcast.xml")).find("https://pod.example.com/12");
    assert_null(it.thumbnail_url);
}

// --- Search filtering & robustness ------------------------------------

void test_search_filters_by_title_or_url() {
    var c = parse(fixture("rss2.xml"), "general", "Example", "NIÑO");
    // Case-insensitive match on title; the label names the query.
    assert_cmpint(c.items.size, GLib.CompareOperator.EQ, 1);
    assert_true(c.labels[0].has_prefix("Search Results: \"NIÑO\""));

    c = parse(fixture("rss2.xml"), "general", "Example", "dc-date");   // url match
    assert_cmpint(c.items.size, GLib.CompareOperator.EQ, 1);
}

void test_control_chars_and_invalid_utf8_tolerated() {
    // A stray invalid UTF-8 byte plus C0 control chars inside the title.
    uint8[] stray = { 0xff, 0 };
    string body = "<rss><channel><item><title>Ba" + (string) stray + "d\x01 \x0b" + "chars</title><link>https://x.example/a</link></item></channel></rss>";
    var c = parse(body);
    assert_cmpint(c.items.size, GLib.CompareOperator.EQ, 1);
    assert_true(c.items[0].title.validate());
    assert_cmpstr(c.items[0].title, GLib.CompareOperator.EQ, "Bad chars");
}

void test_garbage_produces_no_items() {
    // The parser warns on input libxml2 can't recover into a document;
    // that warning is expected here, anything else stays fatal.
    var prev = GLib.Log.set_always_fatal(GLib.LogLevelFlags.LEVEL_ERROR | GLib.LogLevelFlags.LEVEL_CRITICAL);
    foreach (string body in new string[] { "", "not xml at all", "<html><body>404</body></html>" }) {
        var c = parse(body);
        assert_cmpint(c.items.size, GLib.CompareOperator.EQ, 0);
    }
    GLib.Log.set_always_fatal(prev);
}

void test_external_entity_not_loaded() {
    // XXE guard: a SYSTEM entity must never pull in a local file.
    string body = """<?xml version="1.0"?>
<!DOCTYPE rss [ <!ENTITY xxe SYSTEM "file:///etc/passwd"> ]>
<rss><channel><item><title>x&xxe;</title><link>https://x.example/e</link></item></channel></rss>""";
    var c = parse(body);
    foreach (var it in c.items) assert_false(it.title.contains("root:"));
}

void test_entity_amplification_bounded() {
    // Billion laughs: 10 levels of 10x expansion would be ~10 GB of text.
    // libxml2's amplification guard must stop it quickly with bounded output.
    var sb = new StringBuilder("<?xml version=\"1.0\"?>\n<!DOCTYPE rss [\n<!ENTITY l0 \"lol\">\n");
    for (int i = 1; i <= 10; i++) {
        sb.append_printf("<!ENTITY l%d \"", i);
        for (int j = 0; j < 10; j++) sb.append_printf("&l%d;", i - 1);
        sb.append("\">\n");
    }
    sb.append("]>\n<rss><channel><item><title>&l10;</title><link>https://x.example/b</link></item></channel></rss>");

    var prev = GLib.Log.set_always_fatal(GLib.LogLevelFlags.LEVEL_ERROR | GLib.LogLevelFlags.LEVEL_CRITICAL);
    int64 start = GLib.get_monotonic_time();
    var c = parse(sb.str);
    int64 elapsed_ms = (GLib.get_monotonic_time() - start) / 1000;
    GLib.Log.set_always_fatal(prev);

    assert_true(elapsed_ms < 2000);
    foreach (var it in c.items) assert_cmpint(it.title.length, GLib.CompareOperator.LT, 1024 * 1024);
}

int main(string[] args) {
    GLib.Test.init(ref args);
    session = new Soup.Session();

    GLib.Test.add_func("/rss/rss2/items_and_label", test_rss2_items_and_label);
    GLib.Test.add_func("/rss/rss2/title_entity_and_snippet", test_rss2_title_entity_and_snippet);
    GLib.Test.add_func("/rss/rss2/widest_media_thumbnail", test_rss2_widest_media_thumbnail);
    GLib.Test.add_func("/rss/rss2/media_content", test_rss2_media_content_protocol_relative);
    GLib.Test.add_func("/rss/rss2/content_encoded_image", test_rss2_image_from_content_encoded);
    GLib.Test.add_func("/rss/rss2/comments_url", test_rss2_comments_url_registered);
    GLib.Test.add_func("/rss/rss2/dc_date", test_rss2_dc_date);
    GLib.Test.add_func("/rss/atom/entries", test_atom_entries);
    GLib.Test.add_func("/rss/atom/alternate_link", test_atom_prefers_alternate_link);
    GLib.Test.add_func("/rss/atom/link_fallbacks", test_atom_link_fallbacks);
    GLib.Test.add_func("/rss/rdf/items", test_rdf_items);
    GLib.Test.add_func("/rss/google_news/publisher", test_google_news_publisher);
    GLib.Test.add_func("/rss/local_news/sorted", test_local_news_sorted_newest_first);
    GLib.Test.add_func("/rss/local_news/capped", test_local_news_capped_at_30);
    GLib.Test.add_func("/rss/enclosure/image", test_image_enclosure_used);
    GLib.Test.add_func("/rss/enclosure/audio", test_audio_enclosure_not_thumbnail);
    GLib.Test.add_func("/rss/search/filter", test_search_filters_by_title_or_url);
    GLib.Test.add_func("/rss/robust/control_chars", test_control_chars_and_invalid_utf8_tolerated);
    GLib.Test.add_func("/rss/robust/garbage", test_garbage_produces_no_items);
    GLib.Test.add_func("/rss/robust/xxe", test_external_entity_not_loaded);
    GLib.Test.add_func("/rss/robust/entity_amplification", test_entity_amplification_bounded);
    return GLib.Test.run();
}
