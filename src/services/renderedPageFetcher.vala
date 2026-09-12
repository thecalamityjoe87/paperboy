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

using GLib;

// Readability's cleaned output for one page - content_html feeds into
// ArticleExtractorService's normal block-walking logic.
public class ReadabilityResult : GLib.Object {
    public string? title;
    public string? byline;
    public string? site_name;
    public string? published;
    public string content_html;
    public int text_length;
}

public delegate void ReadabilityCallback(ReadabilityResult? result);
internal delegate void SnapshotFunc(int index);

// Renders a URL in a hidden WebView and runs Readability.js against it -
// the fallback for pages a plain fetch can't read (bot challenges,
// JS-hydrated pages). Must run on the main thread (GTK/WebKit).
public class RenderedPageFetcher : GLib.Object {
    // Some sites briefly show the full article then swap in a shorter
    // teaser (paywall) - snapshot a few times and keep the longest.
    private const uint[] SNAPSHOT_DELAYS_MS = { 400, 1200, 2500 };
    private const uint OVERALL_TIMEOUT_MS = 15000;

    private static string? readability_js_cache = null;

    private static string? readability_js() {
        if (readability_js_cache == null) {
            string? path = DataPathsUtils.find_data_file("resources/readability.js");
            if (path != null) {
                try {
                    string contents;
                    GLib.FileUtils.get_contents(path, out contents);
                    readability_js_cache = contents;
                } catch (GLib.Error e) {
                    readability_js_cache = null;
                }
            }
        }
        return readability_js_cache;
    }

    public static void fetch_async(string url, owned ReadabilityCallback on_done) {
        string? js_source = readability_js();
        if (js_source == null) {
            on_done(null);
            return;
        }

        var win = new Gtk.Window();
        var webview = new WebKit.WebView();
        win.set_child(webview);

        bool done = false;
        ReadabilityCallback? callback = (owned) on_done;
        ReadabilityResult? best_result = null;

        void finish() {
            if (done) return;
            done = true;
            callback(best_result);
            callback = null;
            win.set_child(null);
            win.destroy();
        }

        uint timeout_id = Timeout.add(OVERALL_TIMEOUT_MS, () => {
            finish();
            return false;
        });

        int prev_text_length = -1;

        // Stop early once text length stops growing between snapshots -
        // no need to idle out the rest of the schedule once it's stable.
        SnapshotFunc? take_snapshot = null;
        take_snapshot = (index) => {
            string js = js_source +
                "\n;JSON.stringify((function(){ try { var a = new Readability(document.cloneNode(true)).parse(); " +
                "return a ? {title:a.title, byline:a.byline, siteName:a.siteName, publishedTime:a.publishedTime, content:a.content, textLength:a.length} : null; " +
                "} catch(e) { return null; } })())";

            webview.evaluate_javascript.begin(js, -1, null, null, null, (obj, res) => {
                if (done) return;

                int text_length = -1;
                try {
                    var value = webview.evaluate_javascript.end(res);
                    string? json_str = value.to_string();
                    if (json_str != null && json_str != "null") {
                        var parser = new Json.Parser();
                        parser.load_from_data(json_str);
                        var obj_node = parser.get_root().get_object();
                        text_length = (int) obj_node.get_int_member("textLength");
                        if (text_length > (best_result != null ? best_result.text_length : -1)) {
                            var result = new ReadabilityResult();
                            result.title = obj_node.get_string_member("title");
                            result.byline = obj_node.get_string_member("byline");
                            result.site_name = obj_node.get_string_member("siteName");
                            result.published = obj_node.get_string_member("publishedTime");
                            result.content_html = obj_node.get_string_member("content") ?? "";
                            result.text_length = text_length;
                            best_result = result;
                        }
                    }
                } catch (GLib.Error e) {
                    // Keep whatever snapshot (if any) already won.
                }

                bool have_substance = prev_text_length >= 300;
                bool still_growing = prev_text_length < 0 || text_length > prev_text_length * 1.1;
                bool is_last = index >= SNAPSHOT_DELAYS_MS.length - 1;
                prev_text_length = text_length;

                if (is_last || (have_substance && !still_growing)) {
                    Source.remove(timeout_id);
                    finish();
                    return;
                }

                Timeout.add(SNAPSHOT_DELAYS_MS[index + 1] - SNAPSHOT_DELAYS_MS[index], () => {
                    if (!done) take_snapshot(index + 1);
                    return false;
                });
            });
        };

        bool started = false;
        webview.load_changed.connect((ev) => {
            if (done || started || ev != WebKit.LoadEvent.COMMITTED) return;
            started = true;

            Timeout.add(SNAPSHOT_DELAYS_MS[0], () => {
                if (!done) take_snapshot(0);
                return false;
            });
        });

        webview.load_failed.connect((ev, failing_uri, error) => {
            if (!done) {
                Source.remove(timeout_id);
                finish();
            }
            return true;
        });

        webview.load_uri(url);
    }
}
