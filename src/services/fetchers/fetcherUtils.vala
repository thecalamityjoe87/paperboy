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

namespace FetcherUtils {
    public string category_display_name(string cat) {
        switch (cat) {
            case "frontpage": return _("The Frontpage");
            case "myfeed": return _("My Feed");
            case "general": return _("World News");
            case "us": return GoogleNewsUtils.national_label();
            case "technology": return _("Technology");
            case "business": return _("Business");
            case "markets": return _("Markets");
            case "industries": return _("Industries");
            case "economics": return _("Economics");
            case "science": return _("Science");
            case "sports": return _("Sports");
            case "health": return _("Health");
            case "entertainment": return _("Entertainment");
            case "politics": return _("Politics");
            case "lifestyle": return _("Lifestyle");
        }
        return _("News");
    }
}
