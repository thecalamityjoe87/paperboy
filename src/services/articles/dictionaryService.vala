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

public class DictionaryMeaning : GLib.Object {
    public string part_of_speech = "";
    public Gee.ArrayList<string> definitions = new Gee.ArrayList<string>();
}

public class DictionaryEntry : GLib.Object {
    public string word = "";
    public string? phonetic = null;
    public Gee.ArrayList<DictionaryMeaning> meanings = new Gee.ArrayList<DictionaryMeaning>();
}

/**
 * English word lookups for the reader view's "Define" action, against the
 * free, keyless freedictionaryapi.com API (Wiktionary-backed). Its response
 * has one entry per part of speech, sometimes repeated across etymologies -
 * these are merged into a single DictionaryEntry grouped by part of speech,
 * since the popover only has room for a short summary anyway. An unknown
 * word comes back as 200 with an empty "entries" list.
 */
public class DictionaryService : GLib.Object {
    private const string BASE_URL = "https://freedictionaryapi.com/api/v1/entries/en/";
    private const int MAX_DEFINITIONS_PER_MEANING = 3;

    public delegate void LookupCallback(DictionaryEntry? entry);

    public static void lookup(string word, owned LookupCallback callback) {
        var client = Paperboy.HttpClientUtils.get_default();
        // Lowercased because a capitalized lookup returns the proper-noun
        // sense ("Running" the surname) instead of the ordinary word.
        string url = BASE_URL + Uri.escape_string(word.down(), null, false);

        client.fetch_json(url, (response, parser, root) => {
            if (!response.is_success() || root == null || root.get_node_type() != Json.NodeType.OBJECT) {
                callback(null);
                return;
            }

            var root_obj = root.get_object();
            var entry = new DictionaryEntry();
            entry.word = json_get_string_safe(root_obj, "word") ?? word;
            var by_pos = new Gee.HashMap<string, DictionaryMeaning>();

            var entries = json_get_array_safe(root_obj, "entries");
            if (entries != null) {
                foreach (var el in entries.get_elements()) {
                    if (el.get_node_type() != Json.NodeType.OBJECT) continue;
                    var obj = el.get_object();
                    if (entry.phonetic == null) entry.phonetic = first_ipa(obj);
                    string pos = json_get_string_safe(obj, "partOfSpeech") ?? "";

                    var meaning = by_pos.get(pos);
                    if (meaning == null) {
                        meaning = new DictionaryMeaning();
                        meaning.part_of_speech = pos;
                        by_pos.set(pos, meaning);
                        entry.meanings.add(meaning);
                    }

                    var senses = json_get_array_safe(obj, "senses");
                    if (senses == null) continue;
                    foreach (var s_el in senses.get_elements()) {
                        if (meaning.definitions.size >= MAX_DEFINITIONS_PER_MEANING) break;
                        if (s_el.get_node_type() != Json.NodeType.OBJECT) continue;
                        string? def = json_get_string_safe(s_el.get_object(), "definition");
                        if (def != null && def.strip().length > 0) meaning.definitions.add(def.strip());
                    }
                }
            }

            // Drop parts of speech that ended up with no usable definition.
            var with_defs = new Gee.ArrayList<DictionaryMeaning>();
            foreach (var m in entry.meanings) if (m.definitions.size > 0) with_defs.add(m);
            entry.meanings = with_defs;

            callback(entry.meanings.size > 0 ? entry : null);
        });
    }

    // First IPA transcription - "pronunciations" can also hold other
    // notations (e.g. enPR, rhymes) that aren't meant for display.
    private static string? first_ipa(Json.Object obj) {
        var prons = json_get_array_safe(obj, "pronunciations");
        if (prons == null) return null;
        foreach (var el in prons.get_elements()) {
            if (el.get_node_type() != Json.NodeType.OBJECT) continue;
            var p = el.get_object();
            if (json_get_string_safe(p, "type") != "ipa") continue;
            string? text = json_get_string_safe(p, "text");
            if (text != null && text.length > 0) return text;
        }
        return null;
    }

    private static Json.Array? json_get_array_safe(Json.Object obj, string member) {
        if (!obj.has_member(member)) return null;
        var node = obj.get_member(member);
        if (node == null || node.get_node_type() != Json.NodeType.ARRAY) return null;
        return node.get_array();
    }

    private static string? json_get_string_safe(Json.Object obj, string member) {
        if (!obj.has_member(member)) return null;
        var node = obj.get_member(member);
        if (node == null || node.get_node_type() != Json.NodeType.VALUE) return null;
        if (node.get_value_type() != typeof (string)) return null;
        return node.get_string();
    }
}
