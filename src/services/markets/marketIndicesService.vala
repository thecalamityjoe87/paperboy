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
using Gee;

/**
 * Fetches cached market quotes from the Paperboy backend's Finnhub-backed
 * /news/markets/indices and /news/markets/crypto endpoints. Both are
 * read-only and never trigger a live upstream call - the backend refreshes
 * each on its own independent cron, so this just polls whatever each is
 * currently serving.
 */
public class MarketIndicesService : GLib.Object {
    private const string BASE_URL = "https://paperboybackend.onrender.com";

    public delegate void ResultCallback(Gee.ArrayList<MarketIndexQuote>? quotes);
    public delegate void HistoryCallback(MarketIndexHistory? history);

    // Fixed display order for the index ticker - a quote's key is simply
    // absent from the response if nothing has ever been cached yet for it.
    private static string[] index_symbols() {
        return { "SPY", "DIA", "QQQ", "VIXY", "IWM" };
    }

    public static void fetch_indices(owned ResultCallback callback) {
        fetch_quotes(BASE_URL + "/news/markets/indices", index_symbols(), (owned) callback);
    }

    // Crypto has no fixed symbol list to filter against (currently just
    // BTC, but more coins could be added on the backend later) - every
    // entry the response actually has is used, in whatever order the
    // backend returns them.
    public static void fetch_crypto(owned ResultCallback callback) {
        fetch_quotes(BASE_URL + "/news/markets/crypto", null, (owned) callback);
    }

    // GET /news/markets/indices/{symbol}/history - 404s for any symbol
    // outside the five fixed index_symbols(). Returns null on any failure
    // (network error, 404, unparseable body) so callers only need to
    // distinguish "null" (couldn't fetch) from "empty points" (fetched
    // fine, market just hasn't produced any intraday samples yet today).
    public static void fetch_history(string symbol, owned HistoryCallback callback) {
        fetch_history_from("indices", symbol, (owned) callback);
    }

    // GET /news/markets/crypto/{symbol}/history - same shape as the index
    // history endpoint, but crypto's day resets at UTC midnight (not a
    // market close) since it trades 24/7 - an empty or short "points" list
    // just means little time has passed since 00:00 UTC, not missing data.
    public static void fetch_crypto_history(string symbol, owned HistoryCallback callback) {
        fetch_history_from("crypto", symbol, (owned) callback);
    }

    private static void fetch_history_from(string category, string symbol, owned HistoryCallback callback) {
        var client = Paperboy.HttpClientUtils.get_default();
        string url = "%s/news/markets/%s/%s/history".printf(BASE_URL, category, Uri.escape_string(symbol, null, false));

        client.fetch_json(url, (response, parser, root) => {
            if (!response.is_success() || root == null) {
                callback(null);
                return;
            }

            try {
                var obj = root.get_object();
                var history = new MarketIndexHistory();
                history.symbol = json_get_string_safe(obj, "symbol") ?? symbol;
                history.display_name = json_get_string_safe(obj, "name") ?? history.symbol;

                if (obj.has_member("points")) {
                    var points_node = obj.get_member("points");
                    if (points_node != null && points_node.get_node_type() == Json.NodeType.ARRAY) {
                        foreach (var el in points_node.get_array().get_elements()) {
                            if (el.get_node_type() != Json.NodeType.OBJECT) continue;
                            var p_obj = el.get_object();
                            var point = new MarketIndexHistoryPoint();
                            point.symbol = json_get_string_safe(p_obj, "symbol") ?? history.symbol;
                            point.price = json_get_double_safe(p_obj, "price");
                            point.change = json_get_double_safe(p_obj, "change");
                            point.change_percent = json_get_double_safe(p_obj, "change_percent");
                            point.last_updated = json_get_string_safe(p_obj, "last_updated");
                            point.t = json_get_double_safe(p_obj, "t");
                            history.points.add(point);
                        }
                    }
                }
                callback(history);
            } catch (GLib.Error e) {
                warning("MarketIndicesService: failed to parse history response from %s: %s", url, e.message);
                callback(null);
            }
        });
    }

    // only_symbols must be `owned`: it's read inside fetch_json's callback
    // below, which runs asynchronously after this method has already
    // returned. An unowned array parameter is only borrowed for the
    // duration of this call - the caller's temporary (index_symbols()'s
    // return value) was being freed as soon as fetch_quotes() returned,
    // leaving the escaping closure holding a dangling pointer into freed
    // memory (a real crash: SIGSEGV in g_strdup while duplicating a
    // garbage array element). `owned` here keeps it alive for as long as
    // the closure that captures it does, same reason `callback` is owned.
    private static void fetch_quotes(string url, owned string[]? only_symbols, owned ResultCallback callback) {
        var client = Paperboy.HttpClientUtils.get_default();

        client.fetch_json(url, (response, parser, root) => {
            if (!response.is_success() || root == null) {
                callback(null);
                return;
            }

            try {
                var obj = root.get_object();
                if (!obj.has_member("quotes")) {
                    callback(null);
                    return;
                }
                var quotes_node = obj.get_member("quotes");
                if (quotes_node == null || quotes_node.get_node_type() != Json.NodeType.OBJECT) {
                    callback(null);
                    return;
                }
                var quotes_obj = quotes_node.get_object();

                string[] keys;
                if (only_symbols != null) {
                    keys = only_symbols;
                } else {
                    // get_members() returns member names owned by quotes_obj,
                    // not by us - quotes_obj (and its Json.Parser) only lives
                    // for this callback, so each name must be explicitly
                    // duplicated. Plain array-element assignment (keys[idx] = m)
                    // doesn't reliably copy an unowned string in Vala, which
                    // left this array holding dangling pointers once the
                    // parser went out of scope - a real crash (SIGSEGV in
                    // strlen) hit further downstream wherever a symbol string
                    // was later read.
                    var members = quotes_obj.get_members();
                    keys = new string[members.length()];
                    int idx = 0;
                    foreach (var m in members) keys[idx++] = m.dup();
                }

                var results = new Gee.ArrayList<MarketIndexQuote>();
                foreach (var symbol in keys) {
                    if (!quotes_obj.has_member(symbol)) continue;
                    var q_node = quotes_obj.get_member(symbol);
                    if (q_node == null || q_node.get_node_type() != Json.NodeType.OBJECT) continue;
                    var q = q_node.get_object();

                    // "name" is already a human-readable display label
                    // ("S&P 500", "Bitcoin") - fall back to the raw symbol
                    // only if the backend ever omits it.
                    string display_name = json_get_string_safe(q, "name") ?? symbol;
                    var quote = new MarketIndexQuote(symbol, display_name);
                    quote.price = json_get_double_safe(q, "price");
                    quote.change = json_get_double_safe(q, "change");
                    quote.change_percent = json_get_double_safe(q, "change_percent");
                    quote.last_updated = json_get_string_safe(q, "last_updated");
                    results.add(quote);
                }
                callback(results);
            } catch (GLib.Error e) {
                warning("MarketIndicesService: failed to parse response from %s: %s", url, e.message);
                callback(null);
            }
        });
    }

    private static double json_get_double_safe(Json.Object obj, string member) {
        try {
            if (!obj.has_member(member)) return 0.0;
            var node = obj.get_member(member);
            if (node == null || node.get_node_type() != Json.NodeType.VALUE) return 0.0;
            return node.get_double();
        } catch (GLib.Error e) {
            return 0.0;
        }
    }

    private static string? json_get_string_safe(Json.Object obj, string member) {
        try {
            if (!obj.has_member(member)) return null;
            var node = obj.get_member(member);
            if (node == null || node.get_node_type() != Json.NodeType.VALUE) return null;
            try {
                return node.get_string();
            } catch (GLib.Error e) {
                return null;
            }
        } catch (GLib.Error e) {
            return null;
        }
    }
}
