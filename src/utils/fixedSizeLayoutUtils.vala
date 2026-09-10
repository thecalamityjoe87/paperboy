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

namespace Paperboy {
    // Forces a widget to always report a fixed size to its parent, no
    // matter what its child actually wants.
    //
    // Normally you'd use set_size_request() for this, but that only sets a
    // *minimum* - a child can still ask for more. In practice this bit us
    // with cover art: a GtkPicture's requested size follows whatever image
    // is currently loaded into it, so an oversized or uncropped image
    // could push its container wider than intended and shove other
    // widgets out of place next to it.
    //
    // Subclassing Gtk.Widget and overriding measure() is the usual fix,
    // but that didn't work here - the override was silently never called
    // in this GTK4/Vala setup. Installing a Gtk.CustomLayout instead does
    // work, confirmed by testing both approaches directly.
    public class FixedSizeLayoutUtils : GLib.Object {
        public static void apply(Gtk.Widget container, int width, int height) {
            container.set_data<int>("fixed-size-w", width);
            container.set_data<int>("fixed-size-h", height);
            container.set_layout_manager(new Gtk.CustomLayout(null, measure_func, allocate_func));
        }

        private static void measure_func(Gtk.Widget widget, Gtk.Orientation orientation, int for_size,
                                          out int minimum, out int natural,
                                          out int minimum_baseline, out int natural_baseline) {
            int w = widget.get_data<int>("fixed-size-w");
            int h = widget.get_data<int>("fixed-size-h");
            int size = orientation == Gtk.Orientation.HORIZONTAL ? w : h;
            minimum = size;
            natural = size;
            minimum_baseline = -1;
            natural_baseline = -1;
        }

        private static void allocate_func(Gtk.Widget widget, int width, int height, int baseline) {
            Gtk.Widget? child = widget.get_first_child();
            if (child != null) child.allocate(width, height, baseline, null);
        }
    }
}
