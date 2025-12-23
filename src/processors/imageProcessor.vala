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
using Paperboy;

namespace Tools {
	public class ImageProcessor {
		// Concurrency guard to avoid spawning too many short-lived threads
		private static GLib.Mutex _fetch_mutex = new GLib.Mutex();
		private static int _active_fetches = 0;
		private const int MAX_CONCURRENT_FETCHES = 6;
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
	// Strategy: Collect candidates from both <a href> and <img src>, then pick the best one
	// This handles cases like TechPowerUp where high-res images are in <a href> and low-res in <img src>
	public static string? extract_image_from_html_snippet(string html_snippet) {
		string? href_candidate = null;
		string? src_candidate = null;
		
		// FIRST: Look for <a href> tags pointing directly to image files
		// Pattern: <a href="https://example.com/image.jpg">
		try {
			var href_regex = new Regex("href=[\"']([^\"']+\\.(jpg|jpeg|png|webp|gif))[\"']", RegexCompileFlags.CASELESS);
			MatchInfo href_match;
			if (href_regex.match(html_snippet, 0, out href_match)) {
				string href_url = href_match.fetch(1);
				// Decode HTML entities
				href_url = href_url.replace("&amp;", "&");
				if (href_url.has_prefix("//")) href_url = "https:" + href_url;
				
				string href_lower = href_url.down();
				// Only accept if it's not tracking/thumbnail and looks valid
				bool is_tracking = href_lower.contains("tracking") || href_lower.contains("pixel") || href_lower.contains("1x1");
				bool is_thumbnail = href_lower.contains("_thm.") || href_lower.contains("/thumb/") || href_lower.contains("/thumbnail/");
				
				if (!is_tracking && !is_thumbnail && href_url.length >= 20 && (href_url.has_prefix("http") || href_url.has_prefix("https:"))) {
					href_candidate = href_url;
				}
			}
		} catch (GLib.Error e) {
			// Regex error, skip href extraction
		}

		// SECOND: Look for src/srcset attributes (existing logic)
		var attr_regex = new Regex("(src|data-src|srcset|data-srcset)=[\"']([^\"']+)[\"']", RegexCompileFlags.DEFAULT);
		MatchInfo m;
		if (attr_regex.match(html_snippet, 0, out m)) {
			do {
				string attr_name = m.fetch(1).down();
				string attr_val = m.fetch(2);

				// For srcset-like attributes, select the LARGEST image from the srcset
				if (attr_name.has_suffix("srcset")) {
					string? largest = parse_srcset_select_largest(attr_val);
					if (largest != null) {
						attr_val = largest;
					} else {
						// Fallback: take first URL if parsing fails
						string[] parts = attr_val.split(",");
						if (parts.length > 0) {
							attr_val = parts[0].strip();
							int space_idx = attr_val.index_of(" ");
							if (space_idx > 0) attr_val = attr_val.substring(0, space_idx);
						}
					}
				}

				string img_url = attr_val;
				// Decode HTML entities
				img_url = img_url.replace("&amp;", "&");
				img_url = img_url.replace("&lt;", "<");
				img_url = img_url.replace("&gt;", ">");
				img_url = img_url.replace("&quot;", "\"");
				// Basic URL decode
				img_url = img_url.replace("%3A", ":");
				img_url = img_url.replace("%2F", "/");
				img_url = img_url.replace("%3F", "?");
				img_url = img_url.replace("%3D", "=");
				img_url = img_url.replace("%26", "&");

				if (img_url.has_prefix("//")) img_url = "https:" + img_url;

				string img_url_lower = img_url.down();
				if (img_url_lower.has_prefix("data:") || img_url.length < 20) {
					continue;
				}

				bool is_tracking_pixel = img_url_lower.contains("tracking") || img_url_lower.contains("pixel") || img_url_lower.contains("1x1");
				bool is_thumbnail = img_url_lower.contains("_thm.") || img_url_lower.contains("/thumb/") || img_url_lower.contains("/thumbnail/");
				bool looks_like_image = img_url_lower.contains("jpg") || img_url_lower.contains("jpeg") || img_url_lower.contains("png") || img_url_lower.contains("webp") || img_url_lower.contains("gif");

				if (!is_tracking_pixel && looks_like_image && (img_url.has_prefix("http") || img_url.has_prefix("https:"))) {
					// Srcset has highest priority - return immediately
					if (attr_name.has_suffix("srcset")) {
						if (GLib.Environment.get_variable("PAPERBOY_DEBUG") != null) {
							GLib.warning("extract_image_from_html_snippet: returning srcset URL: %s", img_url.length > 80 ? img_url.substring(0, 80) + "..." : img_url);
						}
						return img_url;
					}
					// Save as src candidate if not a thumbnail
					if (src_candidate == null && !is_thumbnail) {
						src_candidate = img_url;
					}
				}
			} while (m.next());
		}

		// Decision logic: prefer href over src only if src is a thumbnail and href is not
		if (href_candidate != null && src_candidate != null) {
			string src_lower = src_candidate.down();
			bool src_is_thumb = src_lower.contains("_thm.") || src_lower.contains("/thumb/") || src_lower.contains("/thumbnail/");
			if (src_is_thumb) {
				if (GLib.Environment.get_variable("PAPERBOY_DEBUG") != null) {
					GLib.warning("extract_image_from_html_snippet: choosing href over thumbnail src: %s", href_candidate.length > 80 ? href_candidate.substring(0, 80) + "..." : href_candidate);
				}
				return href_candidate;
			}
		}
		
		// Return best candidate: href if no src, src if no href, or src if both are valid
		if (src_candidate != null) {
			if (GLib.Environment.get_variable("PAPERBOY_DEBUG") != null) {
				GLib.warning("extract_image_from_html_snippet: returning src candidate: %s", src_candidate.length > 80 ? src_candidate.substring(0, 80) + "..." : src_candidate);
			}
			return src_candidate;
		}
		
		if (href_candidate != null) {
			if (GLib.Environment.get_variable("PAPERBOY_DEBUG") != null) {
				GLib.warning("extract_image_from_html_snippet: returning href candidate: %s", href_candidate.length > 80 ? href_candidate.substring(0, 80) + "..." : href_candidate);
			}
			return href_candidate;
		}
		
		return null;
	}

		// Fetch Open Graph image and title from an article page and call add_item
		// to silently update the UI (same behavior previously implemented inline).
		public static void fetch_open_graph_image(string article_url, Soup.Session session, AddItemFunc add_item, string current_category, string? source_name) {
			// Simple concurrency throttle: if too many fetch threads are active, retry later
			_fetch_mutex.lock();
			if (_active_fetches >= MAX_CONCURRENT_FETCHES) {
				_fetch_mutex.unlock();
				int d = Random.int_range(200, 1000);
				Timeout.add(d, () => {
					// retry the same fetch later
					ImageProcessor.fetch_open_graph_image(article_url, session, add_item, current_category, source_name);
					return false;
				});
				return;
			}
			_active_fetches++;
			_fetch_mutex.unlock();

			new Thread<void*>("fetch-og-image", () => {
				try {
					var client = Paperboy.HttpClientUtils.get_default();
					var options = new Paperboy.HttpClientUtils.RequestOptions().with_browser_headers();
					var http_response = client.fetch_sync(article_url, options);

					if (http_response.is_success() && http_response.body != null) {
						string body = http_response.get_body_string();
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
									title = ImageProcessor.strip_html(h1_info.fetch(1)).strip();
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
				} finally {
					_fetch_mutex.lock();
					_active_fetches--;
					_fetch_mutex.unlock();
				}
				return null;
			});
		}

		// BBC-specific best-effort high-resolution image fetcher.
		// BBC pages commonly use srcset/data-srcset, JSON-LD and lazy-loaded data-src/data-srcset
		// attributes rather than OG tags. This function scans those locations and picks the
		// largest candidate it can find, then calls `add_item` on the main loop to update
		// the article entry in-place.
		public static void fetch_bbc_highres_image(string article_url, Soup.Session session, AddItemFunc add_item, string current_category, string? source_name) {
			// Throttle concurrent BBC fetches similarly to OG fetches
			_fetch_mutex.lock();
			if (_active_fetches >= MAX_CONCURRENT_FETCHES) {
				_fetch_mutex.unlock();
				int d = Random.int_range(200, 1000);
				Timeout.add(d, () => {
					ImageProcessor.fetch_bbc_highres_image(article_url, session, add_item, current_category, source_name);
					return false;
				});
				return;
			}
			_active_fetches++;
			_fetch_mutex.unlock();

			new Thread<void*>("fetch-bbc-image", () => {
				try {
					var client = Paperboy.HttpClientUtils.get_default();
					var options = new Paperboy.HttpClientUtils.RequestOptions().with_browser_headers();
					var http_response = client.fetch_sync(article_url, options);

					if (!http_response.is_success() || http_response.body == null) return null;
					string body = http_response.get_body_string();

					string? best = null;

					// 1) Try to find image in JSON-LD blocks (application/ld+json)
					var jsonld_regex = new Regex("<script[^>]*type=\\\"application/ld\\+json\\\"[^>]*>([\\s\\S]*?)</script>", RegexCompileFlags.DEFAULT);
					MatchInfo mjson;
					if (jsonld_regex.match(body, 0, out mjson)) {
						do {
							string j = mjson.fetch(1);
							// Heuristics: look for "image": "url" or "image": { "url": "..." } or array
							var img_simple = new Regex("\\\"image\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"", RegexCompileFlags.DEFAULT);
							MatchInfo ms;
							if (img_simple.match(j, 0, out ms)) {
								best = ms.fetch(1);
								break;
							}
							var img_obj = new Regex("\\\"image\\\"\\s*:\\s*\\{[\\s\\S]*?\\\"url\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"", RegexCompileFlags.DEFAULT);
							if (img_obj.match(j, 0, out ms)) {
								best = ms.fetch(1);
								break;
							}
							var img_arr = new Regex("\\\"image\\\"\\s*:\\s*\\[\\s\\S]*?\\\"([^\\\"]+)\\\"", RegexCompileFlags.DEFAULT);
							if (img_arr.match(j, 0, out ms)) {
								best = ms.fetch(1);
								break;
							}
						} while (mjson.next());
					}

					// 2) If no JSON-LD result, parse srcset/data-srcset and data-src attributes across the page
					if (best == null) {
						var srcset_regex = new Regex("(srcset|data-srcset|data-src|src)=[\"']([^\"']+)[\"']", RegexCompileFlags.DEFAULT);
						MatchInfo ms2;
						if (srcset_regex.match(body, 0, out ms2)) {
							string candidate = null;
							do {
								string attr = ms2.fetch(1).down();
								string val = ms2.fetch(2);
								if (attr.has_suffix("srcset") || attr.has_suffix("data-srcset")) {
									string chosen = parse_srcset_select_largest(val);
									if (chosen != null && chosen.length > 0) candidate = chosen;
								} else {
									// src or data-src
									if (!val.has_prefix("data:")) candidate = val;
								}
								if (candidate != null) {
									best = candidate;
									break;
								}
							} while (ms2.next());
						}
					}

					// 3) Fallback: look for large images hosted on BBC image CDN (ichef.bbci.co.uk)
					if (best == null) {
						var bbc_img = new Regex("https?://ichef\\.bbci\\.co\\.[a-z]+/[^\"'\\s]+", RegexCompileFlags.DEFAULT);
						MatchInfo mb;
						if (bbc_img.match(body, 0, out mb)) {
							best = mb.fetch(0);
						}
					}

					if (best != null) {
						// Clean up simple encodings
						best = best.replace("&amp;", "&");
						if (best.has_prefix("//")) best = "https:" + best;
						// Prefer https
						if (best.has_prefix("http:") && !best.has_prefix("https:")) best = "https:" + best.substring(5);
						string final_url = best;
						if (GLib.Environment.get_variable("PAPERBOY_DEBUG") != null) {
							warning("fetch_bbc_highres_image: chosen candidate=%s for article=%s", final_url, article_url);
						}
						Idle.add(() => {
							add_item(article_url, article_url, final_url, current_category, source_name);
							return false;
						});
					}
				} catch (GLib.Error e) {
					// ignore
				} finally {
					_fetch_mutex.lock();
					_active_fetches--;
					_fetch_mutex.unlock();
				}
				return null;
			});
		}

		// Helper: parse a srcset string and return the URL with the largest width descriptor if present,
		// otherwise return the last URL.
		private static string? parse_srcset_select_largest(string srcset) {
			string[] parts = srcset.split(",");
			int best_w = -1;
			string? best_url = null;
			foreach (var p in parts) {
				string t = p.strip();
				if (t.length == 0) continue;
				// url [descriptor]
				int space_idx = t.index_of(" ");
				string url = space_idx > 0 ? t.substring(0, space_idx) : t;
				string desc = space_idx > 0 ? t.substring(space_idx + 1).strip() : "";
				int w = -1;
				if (desc.has_suffix("w")) {
					try { w = int.parse(desc.substring(0, desc.length - 1)); } catch (Error e) { w = -1; }
				}
				if (w > best_w) { best_w = w; best_url = url; }
				if (best_w == -1) best_url = url; // fallback to last seen
			}
			if (best_url != null) {
				best_url = best_url.replace("&amp;", "&");
				return best_url;
			}
		return null;
		}

		// Remove resize and size-limiting query parameters from image URLs.
		// Common on WordPress sites with image optimization plugins (Jetpack, WP Rocket, etc).
		// Examples: ?resize=406x232, ?w=300, ?width=300, ?fit=crop
		public static string strip_resize_params(string url) {
			try {
				int q_idx = url.index_of("?");
				if (q_idx < 0) return url; // No query params

				string base_url = url.substring(0, q_idx);
				string query = url.substring(q_idx + 1);

				// Split query string into parameters
				string[] params = query.split("&");
				var kept_params = new Gee.ArrayList<string>();

				foreach (string param in params) {
					string param_lower = param.down();
					// Strip common resize/dimension parameters
					if (param_lower.has_prefix("resize=") ||
						param_lower.has_prefix("w=") ||
						param_lower.has_prefix("h=") ||
						param_lower.has_prefix("width=") ||
						param_lower.has_prefix("height=") ||
						param_lower.has_prefix("fit=") ||
						param_lower.has_prefix("crop=") ||
						param_lower.has_prefix("quality=") ||
						param_lower.has_prefix("zoom=")) {
						continue; // Skip this parameter
					}
					kept_params.add(param);
				}

				// Rebuild URL with remaining params
				if (kept_params.size == 0) {
					return base_url;
				} else {
					return base_url + "?" + string.joinv("&", kept_params.to_array());
				}
			} catch (GLib.Error e) {
				return url;
			}
		}

		// Try to normalize BBC CDN image URLs to a larger variant when possible.
		// This uses a few safe heuristics:
		// - Replace "/news/<num>/" with "/news/1024/" if present
		// - Replace "/<w>x<h>/" path segments with "/1024x576/"
		// - Strip query parameters that constrain width/size
		// Returns the original URL if no changes are made or on error.
		public static string normalize_bbc_image_url(string url) {
			try {
				string u = url.replace("&amp;", "&");
				if (u.has_prefix("//")) u = "https:" + u;
				if (u.has_prefix("http:") && !u.has_prefix("https:")) u = "https:" + u.substring(5);
				// If the URL embeds a numeric news size segment, replace it with 1024
				var re_news_size = new Regex("/news/\\d+/", RegexCompileFlags.DEFAULT);
				MatchInfo m;
				if (re_news_size.match(u, 0, out m)) {
					u = re_news_size.replace(u, -1, 0, "/news/1024/");
				}

				// If an explicit WxH segment exists (e.g. /320x180/), prefer a larger ratio
				var re_xy = new Regex("/\\d+x\\d+/(?!cpsprodpb)", RegexCompileFlags.DEFAULT);
				if (re_xy.match(u, 0, out m)) {
					u = re_xy.replace(u, -1, 0, "/1024x576/");
				}

				// BBC-specific: common IChef patterns include /ace/standard/<size>/ or /ace/thumbnail/<size>/
				var re_ace_standard = new Regex("/ace/standard/\\d+/", RegexCompileFlags.DEFAULT);
				if (re_ace_standard.match(u, 0, out m)) {
					u = re_ace_standard.replace(u, -1, 0, "/ace/standard/1024/");
				}

				var re_ace_thumb = new Regex("/ace/(thumbnail|thumb|standard)/\\d+/", RegexCompileFlags.DEFAULT);
				if (re_ace_thumb.match(u, 0, out m)) {
					u = re_ace_thumb.replace(u, -1, 0, "/ace/standard/1024/");
				}

				// Some BBC URLs include /resize/<w>x<h>/ or /preview/<size>/ — rewrite to a larger resize when present
				var re_resize = new Regex("/(resize|preview)/\\d+x\\d+/(?!cpsprodpb)", RegexCompileFlags.DEFAULT);
				if (re_resize.match(u, 0, out m)) {
					u = re_resize.replace(u, -1, 0, "/resize/1024x576/");
				}

				// Insert a 1024 segment before cpsprodpb if present but no size segment exists
				var re_cps = new Regex("/news/(?:[^/]+/)*cpsprodpb/", RegexCompileFlags.DEFAULT);
				if (re_cps.match(u, 0, out m)) {
					// If we don't already contain /1024/ near the start, try adding it after /news/
					var re_news = new Regex("/news/(?!1024/)", RegexCompileFlags.DEFAULT);
					if (re_news.match(u, 0, out m)) {
						u = re_news.replace(u, -1, 0, "/news/1024/");
					}
				}

				// Some paths contain explicit small tokens; replace common "thumb"/"small"/"thumbnail" segments
				var re_small = new Regex("/(thumb|thumbnail|small|crop)/", RegexCompileFlags.DEFAULT);
				if (re_small.match(u, 0, out m)) {
					u = re_small.replace(u, -1, 0, "/1024x576/");
				}

				// Strip query parameters that constrain size (e.g., ?width=, ?w=)
				int q = u.index_of("?");
				if (q >= 0) u = u.substring(0, q);

				return u;
			} catch (GLib.Error e) {
				return url;
			}
		}

		private static string strip_html(string input) {
			var regex = new Regex("<[^>]+>", RegexCompileFlags.DEFAULT);
			return regex.replace(input, -1, 0, "");
		}
	}
}

