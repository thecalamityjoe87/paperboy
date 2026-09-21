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

// Validates downloaded magazine PDFs. Content-Type headers from arbitrary
// servers aren't trustworthy (some mislabel PDFs as octet-stream, some
// mislabel other files as PDFs), so the real check is the file's own magic
// bytes - mirrors RssValidatorUtils.is_valid_rss's role for feeds.
public class PdfValidatorUtils : GLib.Object {
    public static bool content_type_looks_like_pdf(string? content_type) {
        if (content_type == null) return true; // no header - decide from bytes instead
        string lower = content_type.down();
        return lower.contains("application/pdf") || lower.contains("application/octet-stream") || lower.contains("binary/octet-stream");
    }

    // The PDF header is "%PDF-" at byte 0 for almost every real-world file;
    // a handful of malformed-but-tolerated PDFs put it a few bytes in, so
    // scan a small prefix rather than requiring an exact offset-0 match.
    public static bool looks_like_pdf(uint8[] data) {
        if (data.length < 5) return false;
        int scan_limit = int.min(data.length - 5, 1024);
        for (int i = 0; i <= scan_limit; i++) {
            if (data[i] == '%' && data[i + 1] == 'P' && data[i + 2] == 'D' && data[i + 3] == 'F' && data[i + 4] == '-') {
                return true;
            }
        }
        return false;
    }
}
