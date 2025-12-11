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

/**
 * Small helper object to track hero image requests (size, multiplier, retries)
 */
public class HeroRequest : GLib.Object {
    public string url { get; set; }
    public int last_requested_w { get; set; }
    public int last_requested_h { get; set; }
    public int multiplier { get; set; }
    public int retries { get; set; }

    public HeroRequest(string url, int w, int h, int multiplier) {
        this.url = url;
        this.last_requested_w = w;
        this.last_requested_h = h;
        this.multiplier = multiplier;
        this.retries = 0;
    }
}

/**
 * Deferred request holder for widgets that postpone downloads until visible
 */
public class DeferredRequest : GLib.Object {
    public string url { get; set; }
    public int w { get; set; }
    public int h { get; set; }

    public DeferredRequest(string url, int w, int h) {
        this.url = url;
        this.w = w;
        this.h = h;
    }
}
