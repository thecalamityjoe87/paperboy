/*
 * Copyright (C) 2025  Isaac Joseph <calamityjoe87@gmail.com>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

using Gtk;
using Adw;
using Soup;

public class ArticleWindow : GLib.Object {
    private Adw.NavigationView nav_view;
    private Gtk.Button back_btn;
    private Soup.Session session;
    private NewsWindow parent_window;

    // Callback type for snippet results
    private delegate void SnippetCallback(string text);

    public ArticleWindow(Adw.NavigationView navigation_view, Gtk.Button back_button, Soup.Session soup_session, NewsWindow window) {
        nav_view = navigation_view;
        back_btn = back_button;
        session = soup_session;
        parent_window = window;
    }

    // Show a modal preview with image and a small snippet
    public void show_article_preview(string title, string url, string? thumbnail_url) {
        // Build a scrolling preview page with a max height constraint
        var outer = new Gtk.Box(Orientation.VERTICAL, 0);

        // Set a maximum height for the preview content (e.g., 700px)
        const int MAX_PREVIEW_HEIGHT = 700;
        outer.set_vexpand(false);
        outer.set_hexpand(true);
        outer.set_size_request(-1, MAX_PREVIEW_HEIGHT);

        // Title label
        var title_wrap = new Gtk.Box(Orientation.VERTICAL, 8);
        title_wrap.set_margin_start(16);
        title_wrap.set_margin_end(16);
        title_wrap.set_margin_top(16);
        title_wrap.set_halign(Gtk.Align.FILL);
        title_wrap.set_hexpand(true);
        var ttl = new Gtk.Label(title);
        ttl.add_css_class("title-2");
        ttl.set_xalign(0);
        ttl.set_wrap(true);
        ttl.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        ttl.set_lines(4);
        ttl.set_selectable(true);
        ttl.set_justify(Gtk.Justification.LEFT);
        title_wrap.append(ttl);
        outer.append(title_wrap);

        // Image (constrained)
        int img_w = estimate_content_width();
        int img_h = clampi((int)(img_w * 9.0 / 16.0), 240, 420);
        var pic_box = new Gtk.Box(Orientation.VERTICAL, 0);
        pic_box.set_vexpand(false);
        pic_box.set_hexpand(true);
        pic_box.set_size_request(-1, img_h);
        var pic = new Gtk.Picture();
        pic.set_halign(Gtk.Align.FILL);
        pic.set_hexpand(true);
        pic.set_size_request(-1, img_h);
        pic.set_content_fit(Gtk.ContentFit.COVER);
        pic.set_can_shrink(true);
        pic.set_margin_start(16);
        pic.set_margin_end(16);
        pic.set_margin_top(8);
        pic.set_margin_bottom(8);
        set_placeholder_image(pic, img_w, img_h);
        if (thumbnail_url != null && thumbnail_url.length > 0 && (thumbnail_url.has_prefix("http://") || thumbnail_url.has_prefix("https://"))) {
            var prefs = NewsPreferences.get_instance();
            int multiplier = (prefs.news_source == NewsSource.REDDIT) ? 2 : 3;
            int target_w = img_w * multiplier;
            int target_h = img_h * multiplier;
            load_image_async(pic, thumbnail_url, target_w, target_h);
        }
        pic_box.append(pic);
        outer.append(pic_box);

        // Snippet area
        var pad = new Gtk.Box(Orientation.VERTICAL, 8);
        pad.set_margin_start(16);
        pad.set_margin_end(16);
        pad.set_margin_top(16);
        pad.set_margin_bottom(16);
        var snippet_label = new Gtk.Label("Loading snippet…");
        snippet_label.set_xalign(0);
        snippet_label.set_wrap(true);
        snippet_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR);
        // Allow more lines in the preview (user requested more article text). The
        // scrolled container already constrains total height so this can expand
        // and be scrollable.
        snippet_label.set_lines(12);
        snippet_label.set_selectable(true);
        snippet_label.set_justify(Gtk.Justification.LEFT);
        pad.append(snippet_label);

    
        outer.append(pad);

        // Buttons row
        var actions = new Gtk.Box(Orientation.HORIZONTAL, 8);
        actions.set_margin_start(16);
        actions.set_margin_end(16);
        actions.set_margin_bottom(24);
        actions.set_halign(Gtk.Align.END);
        var open_btn = new Gtk.Button.with_label("Open in browser");
        open_btn.add_css_class("suggested-action");
        open_btn.clicked.connect(() => { try { AppInfo.launch_default_for_uri(url, null); } catch (GLib.Error e) { } });
        var back_local = new Gtk.Button.with_label("Back");
        back_local.clicked.connect(() => {
            if (nav_view != null) nav_view.pop();
            back_btn.set_visible(false);
        });
        actions.append(back_local);
        actions.append(open_btn);
        outer.append(actions);

        // Put content into a scrolled window for overflow
        var sc = new Gtk.ScrolledWindow();
        sc.set_vexpand(true);
        sc.set_hexpand(true);
        sc.set_child(outer);

        var page = new Adw.NavigationPage(sc, "Article");
        nav_view.push(page);
        back_btn.set_visible(true);

        // Use homepage snippet for Fox News if available
        var prefs = NewsPreferences.get_instance();
        if (prefs.news_source == NewsSource.FOX) {
            // Try to get snippet from parent_window/article_buffer
            string? homepage_snippet = null;
            foreach (var item in parent_window.article_buffer) {
                if (item.url == url && item.get_type().name() == "Paperboy.NewsArticle") {
                    homepage_snippet = ((Paperboy.NewsArticle)item).snippet;
                    break;
                }
            }
            if (homepage_snippet != null && homepage_snippet.length > 0) {
                snippet_label.set_text(homepage_snippet);
                return;
            }
        }
        // Otherwise, fetch snippet asynchronously
        fetch_snippet_async(url, (text) => {
            string to_show = text.length > 0 ? text : "No preview available. Open the article to read more.";
            snippet_label.set_text(to_show);
        });
    }

    private void load_image_async(Gtk.Picture image, string url, int target_w, int target_h) {
        new Thread<void*>("load-image", () => {
            try {
                // download initiated
                var msg = new Soup.Message("GET", url);
                
                // Optimize headers based on source
                var prefs_instance = NewsPreferences.get_instance();
                if (prefs_instance.news_source == NewsSource.REDDIT) {
                    msg.request_headers.append("User-Agent", "Mozilla/5.0 (compatible; Paperboy/1.0)");
                    // Reddit-specific optimizations
                    msg.request_headers.append("Accept", "image/jpeg,image/png,image/webp,image/*;q=0.8");
                    msg.request_headers.append("Cache-Control", "max-age=3600");
                } else {
                    msg.request_headers.append("User-Agent", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36");
                    msg.request_headers.append("Accept", "image/webp,image/png,image/jpeg,image/*;q=0.8");
                }
                msg.request_headers.append("Accept-Encoding", "gzip, deflate, br");
                
                session.send_message(msg);
                
                // status received
                
                // Skip extremely large images to prevent slowdowns (especially for Reddit)
                if (prefs_instance.news_source == NewsSource.REDDIT && msg.response_body.length > 2 * 1024 * 1024) {
                    print("Skipping large Reddit image (%ld bytes), using placeholder\n", (long)msg.response_body.length);
                    Idle.add(() => {
                        set_placeholder_image(image, target_w, target_h);
                        return false;
                    });
                    return null;
                }
                
                if (msg.status_code == 200 && msg.response_body.length > 0) {
                    // Create a loader that can auto-detect format
                    Idle.add(() => {
                        try {
                            // creating pixbuf loader
                            var loader = new Gdk.PixbufLoader();
                            
                            // Write data to loader
                            uint8[] data = new uint8[msg.response_body.length];
                            Memory.copy(data, msg.response_body.data, (size_t)msg.response_body.length);
                            loader.write(data);
                            loader.close();
                            
                            var pixbuf = loader.get_pixbuf();
                            // pixbuf loaded check
                            
                            if (pixbuf != null) {
                                // Scale to fit if needed (only scale down for better quality)
                                int width = pixbuf.get_width();
                                int height = pixbuf.get_height();
                                // image size available
                                
                                // Only scale down if image is larger than target, preserve quality
                                if (width > target_w || height > target_h) {
                                    double scale = double.min((double) target_w / width, (double) target_h / height);
                                    int new_width = (int)(width * scale);
                                    int new_height = (int)(height * scale);
                                    // Ensure minimum quality - don't scale below reasonable size
                                    if (new_width >= 64 && new_height >= 64) {
                                        // Use HYPER interpolation for best quality when scaling down
                                        pixbuf = pixbuf.scale_simple(new_width, new_height, Gdk.InterpType.HYPER);
                                        print("Scaled to: %dx%d\n", new_width, new_height);
                                    } else {
                                        print("Keeping original size - would scale too small\n");
                                    }
                                } else {
                                    print("Keeping original size for better quality\n");
                                }
                                
                                var texture = Gdk.Texture.for_pixbuf(pixbuf);
                                image.set_paintable(texture);
                                print("✓ Image set successfully\n");
                            } else {
                                // pixbuf null -> use placeholder
                                set_placeholder_image(image, target_w, target_h);
                            }
                        } catch (GLib.Error e) {
                            // error loading image
                            set_placeholder_image(image, target_w, target_h);
                        }
                        return false;
                    });
                } else {
                    // HTTP error or empty body
                    Idle.add(() => {
                        set_placeholder_image(image, target_w, target_h);
                        return false;
                    });
                }
            } catch (GLib.Error e) {
                // download error
                Idle.add(() => {
                    set_placeholder_image(image, target_w, target_h);
                    return false;
                });
            }
            return null;
        });
    }

    private string get_source_name(NewsSource source) {
        switch (source) {
            case NewsSource.GUARDIAN:
                return "The Guardian";
            case NewsSource.WALL_STREET_JOURNAL:
                return "Wall Street Journal";
            case NewsSource.BBC:
                return "BBC News";
            case NewsSource.REDDIT:
                return "Reddit";
            case NewsSource.NEW_YORK_TIMES:
                return "NY Times";
            case NewsSource.BLOOMBERG:
                return "Bloomberg";
            case NewsSource.REUTERS:
                return "Reuters";
            case NewsSource.NPR:
                return "NPR";
            case NewsSource.FOX:
                return "Fox News";
            default:
                return "News";
        }
    }

    private string? get_source_icon_path(NewsSource source) {
        string icon_filename;
        switch (source) {
            case NewsSource.GUARDIAN:
                icon_filename = "guardian-logo.png";
                break;
            case NewsSource.BBC:
                icon_filename = "bbc-logo.png";
                break;
            case NewsSource.REDDIT:
                icon_filename = "reddit-logo.png";
                break;
            case NewsSource.NEW_YORK_TIMES:
                icon_filename = "nytimes-logo.png";
                break;
            case NewsSource.BLOOMBERG:
                icon_filename = "bloomberg-logo.png";
                break;
            case NewsSource.REUTERS:
                icon_filename = "reuters-logo.png";
                break;
            case NewsSource.NPR:
                icon_filename = "npr-logo.png";
                break;
            case NewsSource.FOX:
                icon_filename = "foxnews-logo.png";
                break;
            case NewsSource.WALL_STREET_JOURNAL:
                icon_filename = "wsj-logo.png";
                break;
            default:
                return null;
        }
        
        // Try to find icon in data directory using the same method as main window
        string[] prefixes = {
            "/home/dev/paperboy/data/",
            "./data/",
            "../data/",
            "/usr/share/paperboy/"
        };
        
        foreach (string prefix in prefixes) {
            string full_path = prefix + "icons/" + icon_filename;
            if (FileUtils.test(full_path, FileTest.EXISTS)) {
                return full_path;
            }
        }
        
        return null;
    }

    private void create_icon_placeholder(Gtk.Picture image, string icon_path, NewsSource source, int width, int height) {
        try {
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, width, height);
            var cr = new Cairo.Context(surface);

            // Create gradient background matching source brand colors
            var gradient = new Cairo.Pattern.linear(0, 0, 0, height);
            
            switch (source) {
                case NewsSource.GUARDIAN:
                    gradient.add_color_stop_rgb(0, 0.0, 0.2, 0.4);  // Guardian blue
                    gradient.add_color_stop_rgb(1, 0.0, 0.4, 0.6);
                    break;
                case NewsSource.BBC:
                    gradient.add_color_stop_rgb(0, 0.6, 0.0, 0.0);  // BBC red
                    gradient.add_color_stop_rgb(1, 0.8, 0.1, 0.1);
                    break;
                case NewsSource.REDDIT:
                    gradient.add_color_stop_rgb(0, 1.0, 0.2, 0.0);  // Reddit orange
                    gradient.add_color_stop_rgb(1, 1.0, 0.4, 0.1);
                    break;
                case NewsSource.NEW_YORK_TIMES:
                    gradient.add_color_stop_rgb(0, 0.1, 0.1, 0.1);  // NYT dark
                    gradient.add_color_stop_rgb(1, 0.3, 0.3, 0.3);
                    break;
                case NewsSource.BLOOMBERG:
                    gradient.add_color_stop_rgb(0, 0.0, 0.3, 0.7);  // Bloomberg blue
                    gradient.add_color_stop_rgb(1, 0.1, 0.5, 0.9);
                    break;
                case NewsSource.REUTERS:
                    gradient.add_color_stop_rgb(0, 0.3, 0.3, 0.4);  // Neutral gray for Reuters logo visibility
                    gradient.add_color_stop_rgb(1, 0.5, 0.5, 0.6);
                    break;
                case NewsSource.NPR:
                    gradient.add_color_stop_rgb(0, 0.1, 0.2, 0.5);  // NPR blue
                    gradient.add_color_stop_rgb(1, 0.2, 0.3, 0.7);
                    break;
                case NewsSource.FOX:
                    gradient.add_color_stop_rgb(0, 0.0, 0.2, 0.6);  // Fox blue
                    gradient.add_color_stop_rgb(1, 0.1, 0.3, 0.8);
                    break;
                default:
                    gradient.add_color_stop_rgb(0, 0.3, 0.3, 0.4);
                    gradient.add_color_stop_rgb(1, 0.5, 0.5, 0.6);
                    break;
            }

            cr.set_source(gradient);
            cr.rectangle(0, 0, width, height);
            cr.fill();

            // Load and draw the source icon
            var icon_pixbuf = new Gdk.Pixbuf.from_file(icon_path);
            if (icon_pixbuf != null) {
                // Calculate scaled size preserving aspect ratio (max 50% of placeholder)
                int orig_width = icon_pixbuf.get_width();
                int orig_height = icon_pixbuf.get_height();
                
                double max_size = double.min(width, height) * 0.5;
                double scale_factor = double.min(max_size / orig_width, max_size / orig_height);
                
                int scaled_width = (int)(orig_width * scale_factor);
                int scaled_height = (int)(orig_height * scale_factor);
                
                var scaled_icon = icon_pixbuf.scale_simple(scaled_width, scaled_height, Gdk.InterpType.BILINEAR);
                
                // Center the icon
                int x = (width - scaled_width) / 2;
                int y = (height - scaled_height) / 2;
                
                // Draw icon with slight transparency for elegance
                cr.save();
                cr.set_source_rgba(1, 1, 1, 0.9);
                Gdk.cairo_set_source_pixbuf(cr, scaled_icon, x, y);
                cr.paint_with_alpha(0.95);
                cr.restore();
            }

            var texture = Gdk.Texture.for_pixbuf(Gdk.pixbuf_get_from_surface(surface, 0, 0, width, height));
            image.set_paintable(texture);

        } catch (GLib.Error e) {
            print("✗ Error creating icon placeholder: %s\n", e.message);
            // Fallback to text placeholder
            string source_name = get_source_name(source);
            create_source_text_placeholder(image, source_name, source, width, height);
        }
    }

    private void create_source_text_placeholder(Gtk.Picture image, string source_name, NewsSource source, int width, int height) {
        try {
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, width, height);
            var cr = new Cairo.Context(surface);

            // Create gradient background based on source
            var gradient = new Cairo.Pattern.linear(0, 0, 0, height);
            
            // Use different colors for different sources
            switch (source) {
                case NewsSource.GUARDIAN:
                    gradient.add_color_stop_rgb(0, 0.0, 0.3, 0.6);  // Guardian blue
                    gradient.add_color_stop_rgb(1, 0.0, 0.5, 0.8);
                    break;
                case NewsSource.BBC:
                    gradient.add_color_stop_rgb(0, 0.7, 0.0, 0.0);  // BBC red
                    gradient.add_color_stop_rgb(1, 0.9, 0.2, 0.2);
                    break;
                case NewsSource.REDDIT:
                    gradient.add_color_stop_rgb(0, 1.0, 0.3, 0.0);  // Reddit orange
                    gradient.add_color_stop_rgb(1, 1.0, 0.5, 0.2);
                    break;
                case NewsSource.NEW_YORK_TIMES:
                    gradient.add_color_stop_rgb(0, 0.0, 0.0, 0.0);  // NYT black
                    gradient.add_color_stop_rgb(1, 0.2, 0.2, 0.2);
                    break;
                case NewsSource.BLOOMBERG:
                    gradient.add_color_stop_rgb(0, 0.0, 0.4, 0.8);  // Bloomberg blue
                    gradient.add_color_stop_rgb(1, 0.2, 0.6, 1.0);
                    break;
                case NewsSource.REUTERS:
                    gradient.add_color_stop_rgb(0, 0.4, 0.4, 0.4);  // Neutral gray for Reuters
                    gradient.add_color_stop_rgb(1, 0.6, 0.6, 0.6);
                    break;
                case NewsSource.NPR:
                    gradient.add_color_stop_rgb(0, 0.2, 0.2, 0.6);  // NPR blue
                    gradient.add_color_stop_rgb(1, 0.4, 0.4, 0.8);
                    break;
                case NewsSource.FOX:
                    gradient.add_color_stop_rgb(0, 0.0, 0.3, 0.7);  // Fox blue
                    gradient.add_color_stop_rgb(1, 0.2, 0.5, 0.9);
                    break;
                default:
                    gradient.add_color_stop_rgb(0, 0.4, 0.4, 0.4);
                    gradient.add_color_stop_rgb(1, 0.6, 0.6, 0.6);
                    break;
            }

            cr.set_source(gradient);
            cr.rectangle(0, 0, width, height);
            cr.fill();

            // Add source name text
            cr.select_font_face("Sans", Cairo.FontSlant.NORMAL, Cairo.FontWeight.BOLD);
            
            // Calculate font size based on dimensions
            double font_size = double.min(width / 8.0, height / 4.0);
            font_size = double.max(font_size, 12.0);
            cr.set_font_size(font_size);

            Cairo.TextExtents extents;
            cr.text_extents(source_name, out extents);

            // Center the text
            double x = (width - extents.width) / 2;
            double y = (height + extents.height) / 2;

            // White text with shadow
            cr.set_source_rgba(0, 0, 0, 0.5);
            cr.move_to(x + 2, y + 2);
            cr.show_text(source_name);

            cr.set_source_rgba(1, 1, 1, 0.9);
            cr.move_to(x, y);
            cr.show_text(source_name);

            var texture = Gdk.Texture.for_pixbuf(Gdk.pixbuf_get_from_surface(surface, 0, 0, width, height));
            image.set_paintable(texture);

        } catch (GLib.Error e) {
            print("✗ Error creating source placeholder: %s\n", e.message);
            // Simple fallback
            create_gradient_placeholder(image, width, height);
        }
    }

    private void set_placeholder_image(Gtk.Picture image, int width, int height) {
        // Get source icon and create branded placeholder
        var prefs = NewsPreferences.get_instance();
        string? icon_path = get_source_icon_path(prefs.news_source);
        string source_name = get_source_name(prefs.news_source);
        if (icon_path != null) {
            create_icon_placeholder(image, icon_path, prefs.news_source, width, height);
        } else {
            // Fallback to text-based placeholder
            create_source_text_placeholder(image, source_name, prefs.news_source, width, height);
        }
    }

    private void load_source_logo_placeholder(Gtk.Picture image, string logo_url, int width, int height) {
        new Thread<void*>("load-logo", () => {
            try {
                var msg = new Soup.Message("GET", logo_url);
                msg.request_headers.append("User-Agent", "Mozilla/5.0 (Linux; rv:91.0) Gecko/20100101 Firefox/91.0");
                session.send_message(msg);

                if (msg.status_code == 200) {
                    uint8[] data = new uint8[msg.response_body.length];
                    Memory.copy(data, msg.response_body.data, (size_t)msg.response_body.length);
                    
                    var loader = new Gdk.PixbufLoader();
                    loader.write(data);
                    loader.close();
                    
                    var pixbuf = loader.get_pixbuf();
                    if (pixbuf != null) {
                        // Scale logo to fit nicely within the placeholder area
                        int logo_size = int.min(width, height) / 2;
                        var scaled = pixbuf.scale_simple(logo_size, logo_size, Gdk.InterpType.BILINEAR);
                        
                        // Create placeholder with logo centered on gradient background
                        Idle.add(() => {
                            create_logo_placeholder(image, scaled, width, height);
                            return false;
                        });
                        return null;
                    }
                }
            } catch (GLib.Error e) {
                // Logo loading failed, use gradient fallback
            }
            
            // Fallback to gradient placeholder
            Idle.add(() => {
                create_gradient_placeholder(image, width, height);
                return false;
            });
            return null;
        });
    }

    private void create_logo_placeholder(Gtk.Picture image, Gdk.Pixbuf logo, int width, int height) {
        try {
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, width, height);
            var cr = new Cairo.Context(surface);

            // Subtle gradient background
            var pattern = new Cairo.Pattern.linear(0, 0, width, height);
            pattern.add_color_stop_rgb(0, 0.95, 0.95, 0.97);
            pattern.add_color_stop_rgb(1, 0.88, 0.88, 0.92);
            cr.set_source(pattern);
            cr.paint();

            // Center the logo
            int logo_w = logo.get_width();
            int logo_h = logo.get_height();
            double x = (width - logo_w) / 2.0;
            double y = (height - logo_h) / 2.0;
            
            Gdk.cairo_set_source_pixbuf(cr, logo, x, y);
            cr.paint_with_alpha(0.7); // Slight transparency

            var texture = Gdk.Texture.for_pixbuf(Gdk.pixbuf_get_from_surface(surface, 0, 0, width, height));
            image.set_paintable(texture);
        } catch (GLib.Error e) {
            create_gradient_placeholder(image, width, height);
        }
    }

    private void create_gradient_placeholder(Gtk.Picture image, int width, int height) {
        try {
            var surface = new Cairo.ImageSurface(Cairo.Format.RGB24, width, height);
            var cr = new Cairo.Context(surface);

            // Gradient background
            var pattern = new Cairo.Pattern.linear(0, 0, width, height);
            pattern.add_color_stop_rgb(0, 0.2, 0.4, 0.8);
            pattern.add_color_stop_rgb(1, 0.1, 0.3, 0.6);
            cr.set_source(pattern);
            cr.paint();

            // Centered text
            cr.set_source_rgb(1.0, 1.0, 1.0);
            cr.select_font_face("Sans", Cairo.FontSlant.NORMAL, Cairo.FontWeight.BOLD);
            double font_size = double.max(12.0, height * 0.12);
            cr.set_font_size(font_size);
            Cairo.TextExtents extents;
            cr.text_extents("No Image", out extents);
            double tx = (width - extents.width) / 2.0 - extents.x_bearing;
            double ty = (height - extents.height) / 2.0 - extents.y_bearing;
            cr.move_to(tx, ty);
            cr.show_text("No Image");

            var texture = Gdk.Texture.for_pixbuf(Gdk.pixbuf_get_from_surface(surface, 0, 0, width, height));
            image.set_paintable(texture);
        } catch (GLib.Error e) {
            // If placeholder fails, just leave it blank
        }
    }

    // Fetch a short snippet from an article URL using common meta tags or first paragraph
    private void fetch_snippet_async(string url, SnippetCallback on_done) {
        new Thread<void*>("snippet-fetch", () => {
            string result = "";
            try {
                var msg = new Soup.Message("GET", url);
                msg.request_headers.append("User-Agent", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36");
                session.send_message(msg);
                if (msg.status_code == 200 && msg.response_body.length > 0) {
                    // Copy to a null-terminated buffer
                    uint8[] buf = new uint8[msg.response_body.length + 1];
                    Memory.copy(buf, msg.response_body.data, (size_t) msg.response_body.length);
                    buf[msg.response_body.length] = 0;
                    string html = (string) buf;
                    result = extract_snippet_from_html(html);
                }
            } catch (GLib.Error e) {
                // ignore, use empty result
            }
            string final = result;
            Idle.add(() => { on_done(final); return false; });
            return null;
        });
    }

    private string extract_attr(string tag, string attr) {
        // naive attribute extractor attr="..."
        int ai = tag.index_of(attr + "=");
        if (ai < 0) return "";
        ai += attr.length + 1;
        if (ai >= tag.length) return "";
        char quote = tag[ai];
        if (quote != '"' && quote != '\'') return "";
        int start = ai + 1;
        int end = tag.index_of_char(quote, start);
        if (end <= start) return "";
        return tag.substring(start, end - start);
    }

    private string extract_snippet_from_html(string html) {
        string lower = html.down();
        // Try OpenGraph description
        int pos = 0;
        while ((pos = lower.index_of("<meta", pos)) >= 0) {
            int end = lower.index_of(">", pos);
            if (end < 0) break;
            string tag = html.substring(pos, end - pos + 1);
            string tl = lower.substring(pos, end - pos + 1);
            bool matches = tl.index_of("property=\"og:description\"") >= 0 ||
                           tl.index_of("name=\"description\"") >= 0 ||
                           tl.index_of("name=\"twitter:description\"") >= 0;
            if (matches) {
                string content = extract_attr(tag, "content");
                if (content != null && content.strip().length > 0) {
                    return truncate_snippet(strip_html(content), 280);
                }
            }
            pos = end + 1;
        }

        // Fallback: first paragraph
        int p1 = lower.index_of("<p");
        if (p1 >= 0) {
            int p1end = lower.index_of(">", p1);
            if (p1end > p1) {
                int p2 = lower.index_of("</p>", p1end);
                if (p2 > p1end) {
                    string inner = html.substring(p1end + 1, p2 - (p1end + 1));
                    return truncate_snippet(strip_html(inner), 280);
                }
            }
        }
        return "";
    }

    private string strip_html(string s) {
        var sb = new StringBuilder();
        bool intag = false;
        for (int i = 0; i < s.length; i++) {
            char c = s[i];
            if (c == '<') { intag = true; continue; }
            if (c == '>') { intag = false; continue; }
            if (!intag) sb.append_c(c);
        }
        string out = sb.str;

        // First decode numeric HTML entities (both decimal and hexadecimal)
        out = out.replace("&#x27;", "'");   // apostrophe
        out = out.replace("&#X27;", "'");   // apostrophe (uppercase)
        out = out.replace("&#x22;", "\"");  // quotation mark
        out = out.replace("&#X22;", "\"");  // quotation mark (uppercase)
        out = out.replace("&#x26;", "&");   // ampersand
        out = out.replace("&#X26;", "&");   // ampersand (uppercase)
        out = out.replace("&#x3C;", "<");   // less than
        out = out.replace("&#X3C;", "<");   // less than (uppercase)
        out = out.replace("&#x3E;", ">");   // greater than
        out = out.replace("&#X3E;", ">");   // greater than (uppercase)
        out = out.replace("&#x20;", " ");   // space  
        out = out.replace("&#X20;", " ");   // space (uppercase)
        out = out.replace("&#x2019;", "'"); // right single quotation mark
        out = out.replace("&#X2019;", "'"); // right single quotation mark (uppercase)
        out = out.replace("&#x201C;", """); // left double quotation mark
        out = out.replace("&#X201C;", """); // left double quotation mark (uppercase)
        out = out.replace("&#x201D;", """); // right double quotation mark
        out = out.replace("&#X201D;", """); // right double quotation mark (uppercase)
        out = out.replace("&#x2013;", "–"); // en dash
        out = out.replace("&#X2013;", "–"); // en dash (uppercase)
        out = out.replace("&#x2014;", "—"); // em dash
        out = out.replace("&#X2014;", "—"); // em dash (uppercase)

        // Common invisible / zero-width characters that appear in some feeds
        out = out.replace("&#x200B;", ""); // zero-width space
        out = out.replace("&#X200B;", ""); // zero-width space (uppercase X)
        out = out.replace("&#8203;", ""); // zero-width space (decimal)
        // Also remove any literal ZERO WIDTH chars that may have survived
        out = out.replace("\u200B", "");
        out = out.replace("\uFEFF", ""); // zero-width no-break space / BOM

        // Then decode named HTML entities
        out = out.replace("&amp;", "&");
        out = out.replace("&lt;", "<");
        out = out.replace("&gt;", ">");
        out = out.replace("&quot;", "\"");
        out = out.replace("&#39;", "'");
        out = out.replace("&apos;", "'");
        out = out.replace("&nbsp;", " ");
        out = out.replace("&mdash;", "—");
        out = out.replace("&ndash;", "–");
        out = out.replace("&hellip;", "…");
        out = out.replace("&rsquo;", "'");
        out = out.replace("&lsquo;", "'");
        out = out.replace("&rdquo;", """);
        out = out.replace("&ldquo;", """);

        // Clean whitespace
        out = out.replace("\n", " ").replace("\r", " ").replace("\t", " ");
        // collapse multiple spaces
        while (out.index_of("  ") >= 0) out = out.replace("  ", " ");
        return out.strip();
    }

    private string truncate_snippet(string s, int maxlen) {
        if (s.length <= maxlen) return s;
        return s.substring(0, maxlen - 1) + "…";
    }

    // Helper: clamp integer between bounds
    private int clampi(int v, int min, int max) {
        if (v < min) return min;
        if (v > max) return max;
        return v;
    }

    // Estimate the content width inside margins
    private int estimate_content_width() {
        int w = parent_window.get_width();
        if (w <= 0) w = 1280; // fall back to a reasonable default
        // Use the same margins as the main window
        const int H_MARGIN = 12;
        return clampi(w - (H_MARGIN * 2), 600, 4096);
    }
}