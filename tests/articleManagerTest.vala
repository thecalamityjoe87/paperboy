/* Tests for ArticleManager's placement rules and bookkeeping: the "load more"
 * queue, per-row caps, the "Recommended for you" shortlist and panel choice,
 * and the view rules for heroes, carousel slides and overflow grouping.
 * These live in placementManager.vala and as static methods on ArticleManager,
 * apart from the widget code, so they run headless. */

using Managers;

ArticleItem article(string title, string category_id = "general", string? source_name = null) {
    return new ArticleItem(title, "https://x.example/" + title.replace(" ", "-"), null, category_id, source_name);
}

// A Front Page article: category_id is always "frontpage", the real category
// travels in the source label.
ArticleItem frontpage_article(string title, string category) {
    return article(title, "frontpage", SourceLabel.encode("Source", null, category));
}

string titles(Gee.List<ArticleItem> items) {
    var parts = new string[0];
    foreach (var it in items) parts += it.title;
    return string.joinv(",", parts);
}

string pick_titles(Gee.List<RecommendedPick> picks) {
    var parts = new string[0];
    foreach (var p in picks) parts += p.item.title;
    return string.joinv(",", parts);
}

// --- OverflowQueue ------------------------------------------------------

void test_overflow_counts_per_key() {
    var q = new OverflowQueue();
    q.add("sports", article("a"));
    q.add("world", article("b"));
    q.add("sports", article("c"));
    assert_cmpint(q.size, GLib.CompareOperator.EQ, 3);
    assert_cmpint(q.count_for("sports"), GLib.CompareOperator.EQ, 2);
    assert_cmpint(q.count_for("world"), GLib.CompareOperator.EQ, 1);
    assert_cmpint(q.count_for("missing"), GLib.CompareOperator.EQ, 0);
}

void test_overflow_take_oldest_first() {
    var q = new OverflowQueue();
    foreach (string t in new string[] { "a", "b", "c" }) q.add(t == "b" ? "world" : "sports", article(t));
    assert_cmpstr(titles(q.take(2)), GLib.CompareOperator.EQ, "a,b");
    assert_cmpint(q.count_for("sports"), GLib.CompareOperator.EQ, 1);
    assert_cmpint(q.count_for("world"), GLib.CompareOperator.EQ, 0);
    // Asking for more than is queued returns what's left.
    assert_cmpstr(titles(q.take(10)), GLib.CompareOperator.EQ, "c");
    assert_cmpint(q.size, GLib.CompareOperator.EQ, 0);
}

void test_overflow_take_for_key() {
    var q = new OverflowQueue();
    q.add("sports", article("s1"));
    q.add("world", article("w1"));
    q.add("sports", article("s2"));
    q.add("sports", article("s3"));
    q.add("world", article("w2"));

    assert_cmpstr(titles(q.take_for("sports", 2)), GLib.CompareOperator.EQ, "s1,s2");
    assert_cmpint(q.count_for("sports"), GLib.CompareOperator.EQ, 1);
    // Other keys keep their order.
    assert_cmpstr(titles(q.take(10)), GLib.CompareOperator.EQ, "w1,s3,w2");
    assert_cmpint(q.take_for("sports", 5).size, GLib.CompareOperator.EQ, 0);
}

void test_overflow_clear_resets_counts() {
    var q = new OverflowQueue();
    q.add("sports", article("a"));
    q.clear();
    assert_cmpint(q.size, GLib.CompareOperator.EQ, 0);
    // Stale counts made a row's arrow offer "load more" with nothing queued.
    assert_cmpint(q.count_for("sports"), GLib.CompareOperator.EQ, 0);
}

// --- RowCardCounts ------------------------------------------------------

void test_row_caps_are_per_row() {
    var rows = new RowCardCounts();
    assert_true(rows.try_claim("guardian", 2));
    assert_true(rows.try_claim("guardian", 2));
    assert_false(rows.try_claim("guardian", 2));
    assert_true(rows.try_claim("technology", 2));   // a full row doesn't affect others
    assert_cmpint(rows.get_count("guardian"), GLib.CompareOperator.EQ, 2);

    rows.add("sports");
    rows.add("sports");
    assert_cmpint(rows.get_count("sports"), GLib.CompareOperator.EQ, 2);
    rows.clear();
    assert_cmpint(rows.get_count("guardian"), GLib.CompareOperator.EQ, 0);
}

// --- RecommendedShortlist -----------------------------------------------

void test_shortlist_accepts_until_full() {
    var s = new RecommendedShortlist();
    for (int i = 0; i < RecommendedShortlist.CAPACITY; i++) {
        assert_true(s.accepts(0.1));
        assert_null(s.hold(new RecommendedPick(article("a%d".printf(i)), 1.0 + i)));
    }
    // Full: only something better than the weakest (score 1.0) gets in.
    assert_false(s.accepts(1.0));
    assert_false(s.accepts(0.5));
    assert_true(s.accepts(1.5));
}

void test_shortlist_evicts_weakest() {
    var s = new RecommendedShortlist();
    for (int i = 0; i < RecommendedShortlist.CAPACITY; i++) s.hold(new RecommendedPick(article("a%d".printf(i)), 10.0 + i));
    var evicted = s.hold(new RecommendedPick(article("new"), 50.0));
    assert_nonnull(evicted);
    assert_cmpstr(evicted.item.title, GLib.CompareOperator.EQ, "a0");
    assert_cmpint(s.size, GLib.CompareOperator.EQ, RecommendedShortlist.CAPACITY);

    var all = s.take_all();
    assert_cmpint(all.size, GLib.CompareOperator.EQ, RecommendedShortlist.CAPACITY);
    assert_cmpint(s.size, GLib.CompareOperator.EQ, 0);
}

void test_story_key() {
    assert_cmpstr(RecommendedShortlist.story_key("  Big Story Here "), GLib.CompareOperator.EQ, "big story here");
}

Gee.ArrayList<RecommendedPick> sorted_picks(RecommendedPick[] picks) {
    var list = new Gee.ArrayList<RecommendedPick>();
    foreach (var p in picks) list.add(p);
    list.sort(RecommendedShortlist.by_score_desc);
    return list;
}

void test_choose_caps_then_tops_up_one_category() {
    // Eight sports stories: two pass the strict cap, the looser cap fills to four.
    var picks = new RecommendedPick[0];
    for (int i = 0; i < 8; i++) picks += new RecommendedPick(frontpage_article("s%d".printf(i), "sports"), 10.0 - i);
    var chosen = RecommendedShortlist.choose(sorted_picks(picks));
    assert_cmpstr(pick_titles(chosen), GLib.CompareOperator.EQ, "s0,s1,s2,s3");
}

void test_choose_trims_to_panel_layout() {
    // Six sports (high) and two tech (low): the strict pass takes 2+2, the fill pass
    // adds two more sports, and six trims to five (no partial grid row), dropping
    // the lowest score.
    var picks = new RecommendedPick[0];
    for (int i = 0; i < 6; i++) picks += new RecommendedPick(frontpage_article("s%d".printf(i), "sports"), 10.0 - i);
    picks += new RecommendedPick(frontpage_article("t0", "technology"), 2.0);
    picks += new RecommendedPick(frontpage_article("t1", "technology"), 1.0);
    var chosen = RecommendedShortlist.choose(sorted_picks(picks));
    assert_cmpint(chosen.size, GLib.CompareOperator.EQ, RecommendedSection.panel_size_for(6));
    assert_cmpstr(pick_titles(chosen), GLib.CompareOperator.EQ, "s0,s1,s2,s3,t0");
}

void test_choose_full_panel_across_categories() {
    var picks = new RecommendedPick[0];
    string[] cats = { "sports", "world", "technology", "business", "science" };
    for (int i = 0; i < 10; i++) picks += new RecommendedPick(frontpage_article("p%d".printf(i), cats[i % 5]), 20.0 - i);
    var chosen = RecommendedShortlist.choose(sorted_picks(picks));
    assert_cmpint(chosen.size, GLib.CompareOperator.EQ, RecommendedShortlist.MAX_PICKS);
    assert_cmpstr(pick_titles(chosen), GLib.CompareOperator.EQ, "p0,p1,p2,p3,p4,p5,p6,p7");
}

void test_choose_one_card_per_story() {
    // The same headline from two outlets (different URLs) only appears once.
    var picks = new RecommendedPick[0];
    picks += new RecommendedPick(new ArticleItem("Big Story", "https://a.example/1", null, "frontpage", SourceLabel.encode("A", null, "world")), 9.0);
    picks += new RecommendedPick(new ArticleItem("big story ", "https://b.example/2", null, "frontpage", SourceLabel.encode("B", null, "business")), 8.0);
    string[] cats = { "sports", "technology", "science", "health" };
    for (int i = 0; i < 4; i++) picks += new RecommendedPick(frontpage_article("other%d".printf(i), cats[i]), 5.0 - i);
    var chosen = RecommendedShortlist.choose(sorted_picks(picks));
    int big = 0;
    foreach (var p in chosen) if (RecommendedShortlist.story_key(p.item.title) == "big story") big++;
    assert_cmpint(big, GLib.CompareOperator.EQ, 1);
    assert_cmpstr(chosen[0].item.url, GLib.CompareOperator.EQ, "https://a.example/1");   // the higher-scored copy
}

void test_choose_too_few_for_panel() {
    var picks = new RecommendedPick[0];
    string[] cats = { "sports", "world", "technology" };
    for (int i = 0; i < RecommendedSection.MIN_PICKS - 1; i++) picks += new RecommendedPick(frontpage_article("p%d".printf(i), cats[i]), 5.0 - i);
    assert_cmpint(RecommendedShortlist.choose(sorted_picks(picks)).size, GLib.CompareOperator.EQ, 0);
}

// --- View rules -----------------------------------------------------------

void test_display_category() {
    assert_cmpstr(ArticleManager.resolve_display_category("frontpage", SourceLabel.encode("BBC", null, "world")), GLib.CompareOperator.EQ, "world");
    assert_cmpstr(ArticleManager.resolve_display_category("frontpage", "BBC"), GLib.CompareOperator.EQ, "frontpage");
    assert_cmpstr(ArticleManager.resolve_display_category("technology", SourceLabel.encode("BBC", null, "world")), GLib.CompareOperator.EQ, "technology");
}

void test_overflow_key() {
    // Front Page groups by row: subcategories fold into their row, unknowns into "more".
    assert_cmpstr(ArticleManager.overflow_key("frontpage", "frontpage", SourceLabel.encode("X", null, "football")), GLib.CompareOperator.EQ, "sports");
    assert_cmpstr(ArticleManager.overflow_key("frontpage", "frontpage", SourceLabel.encode("X", null, "world")), GLib.CompareOperator.EQ, "world");
    assert_cmpstr(ArticleManager.overflow_key("frontpage", "frontpage", SourceLabel.encode("X", null, "astrology")), GLib.CompareOperator.EQ, "more");
    // Elsewhere, by category as-is.
    assert_cmpstr(ArticleManager.overflow_key("sports", "football", null), GLib.CompareOperator.EQ, "football");
}

void test_view_allows() {
    assert_true(ArticleManager.view_allows("technology", "sports"));   // filtering happens elsewhere
    assert_true(ArticleManager.view_allows("saved", "saved"));
    assert_false(ArticleManager.view_allows("saved", "technology"));
    assert_false(ArticleManager.view_allows("history", "frontpage"));
    assert_true(ArticleManager.view_allows(null, "general"));
}

void test_takes_hero_slot() {
    // view, is_rss, is_trending, featured_used, trending_heroes
    assert_true(ArticleManager.takes_hero_slot("technology", false, false, false, 0));
    assert_false(ArticleManager.takes_hero_slot("technology", false, false, true, 0));
    assert_true(ArticleManager.takes_hero_slot("frontpage", false, false, false, 0));
    assert_false(ArticleManager.takes_hero_slot("saved", false, false, false, 0));
    assert_false(ArticleManager.takes_hero_slot("history", false, true, false, 0));
    assert_false(ArticleManager.takes_hero_slot("rssfeed:https://x/feed", true, false, false, 0));
    // Trending has two heroes of its own, whatever featured_used says.
    assert_true(ArticleManager.takes_hero_slot("frontpage", false, true, true, 1));
    assert_false(ArticleManager.takes_hero_slot("frontpage", false, true, false, 2));
}

void test_carousel_accepts() {
    var followed = new Gee.ArrayList<string>();
    followed.add("technology");
    followed.add("science");

    // Single-category views: same category only.
    assert_true(ArticleManager.carousel_accepts_for("technology", "technology", false, false, null, null));
    assert_false(ArticleManager.carousel_accepts_for("sports", "technology", false, false, null, null));
    // Personalized My Feed: custom feeds, followed categories, or the hero's own.
    assert_true(ArticleManager.carousel_accepts_for("myfeed", "myfeed", true, false, followed, "technology"));
    assert_true(ArticleManager.carousel_accepts_for("science", "myfeed", true, false, followed, "technology"));
    assert_true(ArticleManager.carousel_accepts_for("sports", "myfeed", true, false, followed, "sports"));
    assert_false(ArticleManager.carousel_accepts_for("sports", "myfeed", true, false, followed, "technology"));
    assert_true(ArticleManager.carousel_accepts_for("sports", "myfeed", true, false, new Gee.ArrayList<string>(), null));
    // RSS feed views: feed articles only.
    assert_true(ArticleManager.carousel_accepts_for("rssfeed:https://x/feed", "rssfeed:https://x/feed", false, true, null, null));
    assert_false(ArticleManager.carousel_accepts_for("general", "rssfeed:https://x/feed", false, true, null, null));
}

int main(string[] args) {
    GLib.Test.init(ref args);
    GLib.Test.add_func("/article/overflow/counts", test_overflow_counts_per_key);
    GLib.Test.add_func("/article/overflow/take", test_overflow_take_oldest_first);
    GLib.Test.add_func("/article/overflow/take_for", test_overflow_take_for_key);
    GLib.Test.add_func("/article/overflow/clear", test_overflow_clear_resets_counts);
    GLib.Test.add_func("/article/rows/caps", test_row_caps_are_per_row);
    GLib.Test.add_func("/article/recommended/accepts", test_shortlist_accepts_until_full);
    GLib.Test.add_func("/article/recommended/evicts", test_shortlist_evicts_weakest);
    GLib.Test.add_func("/article/recommended/story_key", test_story_key);
    GLib.Test.add_func("/article/recommended/choose_top_up", test_choose_caps_then_tops_up_one_category);
    GLib.Test.add_func("/article/recommended/choose_trim", test_choose_trims_to_panel_layout);
    GLib.Test.add_func("/article/recommended/choose_full", test_choose_full_panel_across_categories);
    GLib.Test.add_func("/article/recommended/choose_story", test_choose_one_card_per_story);
    GLib.Test.add_func("/article/recommended/choose_too_few", test_choose_too_few_for_panel);
    GLib.Test.add_func("/article/rules/display_category", test_display_category);
    GLib.Test.add_func("/article/rules/overflow_key", test_overflow_key);
    GLib.Test.add_func("/article/rules/view_allows", test_view_allows);
    GLib.Test.add_func("/article/rules/hero_slot", test_takes_hero_slot);
    GLib.Test.add_func("/article/rules/carousel", test_carousel_accepts);
    return GLib.Test.run();
}
