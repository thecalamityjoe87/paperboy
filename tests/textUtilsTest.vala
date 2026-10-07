/* Tests for the pure string helpers in src/utils/text. */

void test_title_sort_key_drops_leading_article() {
    assert_cmpstr(SortUtils.title_sort_key("The Verge"), GLib.CompareOperator.EQ, "verge");
    assert_cmpstr(SortUtils.title_sort_key("  Theatre Weekly "), GLib.CompareOperator.EQ, "theatre weekly");
    // A title that is only the article keeps it rather than becoming empty.
    assert_cmpstr(SortUtils.title_sort_key("The "), GLib.CompareOperator.EQ, "the");
}

void test_compare_titles_ignores_article() {
    assert_true(SortUtils.compare_titles("The Atlantic", "BBC") < 0);
    assert_true(SortUtils.compare_titles("bbc", "BBC") == 0);
}

void test_truncate_snippet_ascii() {
    assert_cmpstr(stripHtmlUtils.truncate_snippet("short", 10), GLib.CompareOperator.EQ, "short");
    assert_cmpstr(stripHtmlUtils.truncate_snippet("abcdefghij", 5), GLib.CompareOperator.EQ, "abcd…");
}

int main(string[] args) {
    GLib.Test.init(ref args);
    GLib.Test.add_func("/text/sort/title_sort_key", test_title_sort_key_drops_leading_article);
    GLib.Test.add_func("/text/sort/compare_titles", test_compare_titles_ignores_article);
    GLib.Test.add_func("/text/snippet/truncate_ascii", test_truncate_snippet_ascii);
    return GLib.Test.run();
}
