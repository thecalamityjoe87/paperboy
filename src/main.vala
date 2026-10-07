/* Paperboy - An all-in-one news app written in Vala, built with GTK4 and Libadwaita.
 * 
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

// Setting MALLOC_ARENA_MAX via env var is too late once main() is already
// running, so cap it directly with mallopt() instead.
[CCode (cname = "mallopt")]
private static extern int mallopt(int param, int val);
private const int M_ARENA_MAX = -8;
private const int M_ARENA_TEST = -7;

public static int main(string[] args) {
    // Re-exec'd by MagazinePdfImportService to sandbox untrusted PDF
    // parsing in its own process (see MagazineThumbnailerTool) - handled
    // before anything else here so that process never touches GTK/Adw/GST
    // init or the malloc tuning below, same as a genuinely separate
    // binary would.
    if (args.length >= 2 && args[1] == Paperboy.MagazineThumbnailerTool.INTERNAL_FLAG) {
        return Paperboy.MagazineThumbnailerTool.run(args[1:args.length]);
    }

    // Caps glibc's malloc arenas: uncapped, concurrent image/XML worker
    // churn fragments memory across arenas and balloons RSS. 4 is enough
    // for HttpClientUtils.MAX_CONCURRENT_REQUESTS worker threads to avoid
    // serializing on too few arena locks, while staying well under
    // glibc's default (which scales with core count).
    mallopt(M_ARENA_MAX, 4);
    mallopt(M_ARENA_TEST, 1);

    // Set up gettext before any UI string is created: adopt the user's
    // locale, then point the domain at the installed catalog so _() can
    // translate. Falls back to the original English strings when the
    // locale has no catalog.
    Intl.setlocale(GLib.LocaleCategory.ALL, "");
    Intl.bindtextdomain(GETTEXT_PACKAGE, DataPathsUtils.get_locale_dir(LOCALEDIR));
    Intl.bind_textdomain_codeset(GETTEXT_PACKAGE, "UTF-8");
    Intl.textdomain(GETTEXT_PACKAGE);

    Gst.init(ref args);

    var app = new PaperboyApp();
    return app.run(args);
}
