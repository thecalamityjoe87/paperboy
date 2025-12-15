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

namespace ArticleShareService {
    public enum ShareTarget {
        EMAIL,
        REDDIT,
        TWITTER,
        FACEBOOK
    }

    // Build a platform-neutral share URI for the given target.
    // This function is UI-agnostic and does not launch anything.
    public string build_share_uri(ShareTarget target, string url, string? title) {
        string encoded_url = Uri.escape_string(url, null, false);
        switch (target) {
            case ShareTarget.EMAIL:
                string article_title = title ?? "Check out this article";
                string subject = Uri.escape_string(article_title, null, false);
                string body = Uri.escape_string("I thought you might find this interesting:\n\n" + url, null, false);
                return "mailto:?subject=%s&body=%s".printf(subject, body);
            case ShareTarget.REDDIT:
                return "https://www.reddit.com/submit?url=%s".printf(encoded_url);
            case ShareTarget.TWITTER:
                string text = title != null ? Uri.escape_string(title, null, false) : "";
                return "https://twitter.com/intent/tweet?text=%s&url=%s".printf(text, encoded_url);
            case ShareTarget.FACEBOOK:
                return "https://www.facebook.com/sharer/sharer.php?u=%s".printf(encoded_url);
            default:
                return "";
        }
    }

    // Build text suitable for copying into the clipboard
    public string build_clipboard_text(string url) {
        return url;
    }
}
