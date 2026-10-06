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

// glibc-specific: malloc_trim() forces freed heap pages back to the OS
// immediately instead of waiting on glibc's own heuristics.
[CCode (cname = "malloc_trim", cheader_filename = "malloc.h")]
private static extern int memory_utils_malloc_trim(size_t pad);

public class MemoryUtils {
    // Returns freed heap to the OS. Call right after dropping the last
    // references to a large batch of objects (card widget trees and their
    // textures, a finished WebView), so RSS drops with them rather than
    // staying elevated even though everything was properly freed.
    public static void trim_heap() {
        memory_utils_malloc_trim(0);
    }
}
