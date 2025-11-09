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

using GLib;
using Paperboy;

namespace Tools {
public class ImageParser {
	// Minimal HTML image extractor placeholder. Scans for images hosted on
	// a given host substring and assigns them to articles lacking images.
	public static void extract_article_images_from_html(string html, Gee.ArrayList<Paperboy.NewsArticle> articles, string host_substring) {
		try {
			var img_regex = new Regex("<img[^>]*src=\\\"(https?://[^\\\"]+)\\\"[^>]*>", RegexCompileFlags.DEFAULT);
			MatchInfo m;
			if (!img_regex.match(html, 0, out m)) return;
			var found_urls = new Gee.ArrayList<string>();
			do {
				string src = m.fetch(1);
				if (src.contains(host_substring)) found_urls.add(src);
			} while (m.next());

			if (found_urls.size == 0) return;

			int idx = 0;
			foreach (var article in articles) {
				if (article.image_url == null && idx < found_urls.size) {
					article.image_url = found_urls.get(idx);
					idx++;
				}
				if (idx >= found_urls.size) break;
			}
		} catch (GLib.Error e) {
			// ignore parsing errors
		}
	}

	// Extract image URL from an HTML snippet (like RSS description or content:encoded).
	public static string? extract_image_from_html_snippet(string html_snippet) {
		// Look for img tags in the snippet
		int search_pos = 0;
		
		while (search_pos < html_snippet.length) {
			int img_pos = html_snippet.index_of("<img", search_pos);
			if (img_pos == -1) break;
			
			int src_start = html_snippet.index_of("src=\"", img_pos);
			if (src_start == -1) {
				src_start = html_snippet.index_of("src='", img_pos);
				if (src_start != -1) src_start += 5;
			} else {
				src_start += 5;
			}
			
			if (src_start != -1) {
				int src_end = html_snippet.index_of("\"", src_start);
				if (src_end == -1) {
					src_end = html_snippet.index_of("'", src_start);
				}
				
				if (src_end != -1) {
					string img_url = html_snippet.substring(src_start, src_end - src_start);
					
					// Decode HTML entities in the URL
					img_url = img_url.replace("&amp;", "&");
					img_url = img_url.replace("&lt;", "<");
					img_url = img_url.replace("&gt;", ">");
					img_url = img_url.replace("&quot;", "\"");
					
					// Basic URL decoding for NPR-style URLs
					img_url = img_url.replace("%3A", ":");
					img_url = img_url.replace("%2F", "/");
					img_url = img_url.replace("%3F", "?");
					img_url = img_url.replace("%3D", "=");
					img_url = img_url.replace("%26", "&");
					
					// Check if this is a NPR-style resizing URL with nested image URL
					if (img_url.contains("?url=http")) {
						int url_param_start = img_url.index_of("?url=") + 5;
						if (url_param_start > 4 && url_param_start < img_url.length) {
							string nested_url = img_url.substring(url_param_start);
							// If the nested URL looks like a proper image URL, use it instead
							if (nested_url.length > 30 && nested_url.has_prefix("http")) {
								img_url = nested_url;
							}
						}
					}
					
					string img_url_lower = img_url.down();
					
					// Enhanced filtering to skip unwanted images but allow more legitimate ones
					bool is_tracking_pixel = img_url_lower.contains("tracking") || 
									img_url_lower.contains("pixel") ||
									img_url_lower.contains("1x1") ||
									img_url.length < 30;
					
					bool is_valid_image = img_url.length > 30 && 
						!img_url_lower.contains("icon") && 
						!img_url_lower.contains("logo") && 
						!is_tracking_pixel &&
						(img_url.has_prefix("http") || img_url.has_prefix("//")) &&
						(img_url_lower.contains("jpg") || img_url_lower.contains("jpeg") || 
						 img_url_lower.contains("png") || img_url_lower.contains("webp") || 
						 img_url_lower.contains("gif")); // Must be an actual image format
					
					if (is_valid_image) {
						return img_url.has_prefix("//") ? "https:" + img_url : img_url;
					}
				}
			}
			
			search_pos = img_pos + 4; // Move past this <img tag
		}
		return null;
	}

	// Fetch Open Graph image and title from an article page and call add_item
	// to silently update the UI (same behavior previously implemented inline).
	public static void fetch_open_graph_image(string article_url, Soup.Session session, AddItemFunc add_item, string current_category, string? source_name) {
		new Thread<void*>("fetch-og-image", () => {
			try {
				var msg = new Soup.Message("GET", article_url);
				msg.request_headers.append("User-Agent", "Mozilla/5.0 (Linux; rv:91.0) Gecko/20100101 Firefox/91.0");
				session.send_message(msg);

				if (msg.status_code == 200) {
					string body = (string) msg.response_body.flatten().data;
					var og_regex = new Regex("<meta[^>]*property=\\\"og:image\\\"[^>]*content=\\\"([^\\\"]+)\\\"", RegexCompileFlags.DEFAULT);
					MatchInfo match_info;
					if (og_regex.match(body, 0, out match_info)) {
						string image_url = match_info.fetch(1);
						string title = "";
						var title_regex = new Regex("<meta[^>]*property=\\\"og:title\\\"[^>]*content=\\\"([^\\\"]+)\\\"", RegexCompileFlags.DEFAULT);
						MatchInfo t_info;
						if (title_regex.match(body, 0, out t_info)) {
							title = t_info.fetch(1);
						}
						if (title.length == 0) {
							var h1_regex = new Regex("<h1[^>]*>([^<]+)</h1>", RegexCompileFlags.DEFAULT);
							MatchInfo h1_info;
							if (h1_regex.match(body, 0, out h1_info)) {
								title = ImageParser.strip_html(h1_info.fetch(1)).strip();
							}
						}
						if (title.length == 0) title = article_url;

						Idle.add(() => {
							add_item(title, article_url, image_url, current_category, source_name);
							return false;
						});
					}
				}
			} catch (GLib.Error e) {
				// ignore
			}
			return null;
		});
	}

	private static string strip_html(string input) {
		var regex = new Regex("<[^>]+>", RegexCompileFlags.DEFAULT);
		return regex.replace(input, -1, 0, "");
	}
}
}

