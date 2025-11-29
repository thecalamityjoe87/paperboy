use clap::Parser;
use quick_xml::events::{BytesDecl, Event};
use quick_xml::Writer;
use reqwest::blocking::Client;
use reqwest::header::{USER_AGENT, ACCEPT, ACCEPT_LANGUAGE, CONNECTION};
use scraper::{Html, Selector, ElementRef};
use regex::Regex;
use unicode_normalization::UnicodeNormalization;
use html_escape::decode_html_entities;
use std::collections::HashSet;
use serde_json::Value as JsonValue;
use std::error::Error;
use std::io::{self, Write};
use std::time::Duration;
use std::thread::sleep;
use std::env;
use rand::{thread_rng, Rng};
use rand::seq::SliceRandom;
use url::Url;
use url::form_urlencoded;
use once_cell::sync::Lazy;
use chrono::DateTime;

/// html2rss - generate a simple RSS feed from a webpage
#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    /// URL of the page to convert to RSS
    url: String,

    /// Maximum number of pages to crawl (default: 20)
    #[arg(short = 'n', long = "max-pages", default_value_t = 20)]
    max_pages: usize,

    /// Timeout in milliseconds for network requests (default: 5000)
    #[arg(short = 't', long = "timeout-ms", default_value_t = 10000)]
    timeout_ms: u64,
}

fn main() {
    let args = Args::parse();

    match run(&args) {
        Ok(()) => std::process::exit(0),
        Err(e) => {
            eprintln!("error: {}", e);
            std::process::exit(4);
        }
    }
}

fn run(args: &Args) -> Result<(), Box<dyn Error>> {
    let timeout = Duration::from_millis(args.timeout_ms);
    let client = Client::builder()
        .timeout(timeout)
        .redirect(reqwest::redirect::Policy::limited(10))
        .build()?;

    let start_url = Url::parse(&args.url)?;

    // Fetch the page (with rotating UA, standard headers and modest delay)
    let body = get_text_with_headers(&client, &start_url, args.timeout_ms)?;
    let document = Html::parse_document(&body);

    // If the start page appears to be paywalled, bail out — unless domain is allowed
    if !allowed_domain(&start_url) && is_paywalled_page(&document) {
        eprintln!("Skipping start URL (paywalled): {}", start_url.as_str());
        return Err("start page appears to be paywalled".into());
    }

    // 1) detect linked RSS/Atom
    if let Some(feed_url) = find_linked_feed(&document, &start_url) {
        // Try to fetch the feed using the same helper (benefits from headers and delay)
        if let Ok(feed_text) = get_text_with_headers(&client, &feed_url, args.timeout_ms) {
                io::stdout().write_all(feed_text.as_bytes())?;
                io::stdout().write_all(b"\n")?;
                io::stdout().flush()?;
            return Ok(());
        }
    }

    // 2) try JSON-LD
    if let Some(items) = extract_from_json_ld(&document, &start_url) {
        // Filter out listing, blacklisted or error pages returned by JSON-LD
        let filtered: Vec<Item> = items.into_iter().filter(|it| {
            if is_error_page(&document, &it.title, &it.description) { return false; }
            if let Ok(u) = Url::parse(&it.link) {
                return !is_blacklisted_url(&u) && !is_listing_page(&u, &start_url);
            }
            true
        }).collect();
        if !filtered.is_empty() {
            write_rss(&start_url, &filtered)?;
            return Ok(());
        }
        // otherwise fall through to HTML extraction
    }

    // 3) fallback: extract article-like elements and optionally fetch candidate pages
    let items = extract_from_html(&client, &document, &start_url, args.max_pages, args.timeout_ms);
    if items.is_empty() {
        return Err("no articles found".into());
    }

    write_rss(&start_url, &items)?;
    Ok(())
}

#[derive(Debug)]
struct Item {
    title: String,
    link: String,
    description: Option<String>,
    pub_date: Option<String>,
    image: Option<String>,
}

fn find_linked_feed(document: &Html, base: &Url) -> Option<Url> {
    let sel = Selector::parse(r#"link[rel="alternate"]"#).ok()?;
    for node in document.select(&sel) {
        if let Some(t) = node.value().attr("type") {
            if t.contains("rss") || t.contains("atom") {
                if let Some(href) = node.value().attr("href") {
                    if let Ok(u) = base.join(href) {
                        return Some(u);
                    }
                }
            }
        }
    }
    None
}

fn extract_from_json_ld(document: &Html, base: &Url) -> Option<Vec<Item>> {
    let sel = Selector::parse("script[type=application/ld+json]").ok()?;
    // We try several JSON-LD shapes: object, array, and @graph.
    for node in document.select(&sel) {
        if let Some(text) = node.first_child().and_then(|n| n.value().as_text()) {
            if let Ok(json) = serde_json::from_str::<JsonValue>(text) {
                let mut items = Vec::new();

                // If it's an object with @graph, prefer graph members
                if json.is_object() {
                    let obj = json.as_object().unwrap();
                    if let Some(graph) = obj.get("@graph") {
                        if let Some(arr) = graph.as_array() {
                            for v in arr {
                                // only convert likely Article/NewsArticle nodes
                                if is_jsonld_article_node(v) {
                                    if let Some(it) = json_ld_to_item(v, base) {
                                        items.push(it);
                                    }
                                }
                            }
                        }
                    }

                    // If no graph results, try to convert the root object if it's an Article
                    if items.is_empty() && is_jsonld_article_node(&json) {
                        if let Some(it) = json_ld_to_item(&json, base) {
                            items.push(it);
                        }
                    }
                }

                // If it's an array, iterate and pick Article-like nodes
                if items.is_empty() && json.is_array() {
                    if let Some(arr) = json.as_array() {
                        for v in arr {
                            if is_jsonld_article_node(v) {
                                if let Some(it) = json_ld_to_item(v, base) {
                                    items.push(it);
                                }
                            }
                        }
                    }
                }

                // If we found items, return them
                if !items.is_empty() {
                    return Some(items);
                }

                // As a fallback, if the root has a mainEntityOfPage pointing to an Article object, handle it
                if json.is_object() {
                    let obj = json.as_object().unwrap();
                    if let Some(me) = obj.get("mainEntityOfPage") {
                        if is_jsonld_article_node(me) {
                            if let Some(it) = json_ld_to_item(me, base) {
                                items.push(it);
                                return Some(items);
                            }
                        }
                    }
                }
            }
        }
    }
    None
}

// Heuristic to detect pages that are error/placeholder pages and should be skipped.
fn is_error_page(document: &Html, title: &str, description: &Option<String>) -> bool {
    let low_title = title.to_lowercase();
    // Common error or non-content titles (login/sign-in, 404, error pages)
    if low_title.contains("uh-oh") || low_title.contains("uh oh") || low_title.contains("error") || low_title.contains("404") || low_title.contains("page not found") || low_title.contains("not found") || low_title.contains("we're sorry") || low_title.contains("sorry") {
        return true;
    }

    // Avoid login or sign-in pages being treated as articles
    if low_title.contains("login") || low_title.contains("log in") || low_title.contains("sign in") || low_title.contains("sign-in") || low_title.contains("sign in to") {
        return true;
    }

    if let Some(d) = description {
        let ld = d.to_lowercase();
        if ld.contains("error") || ld.contains("not found") || ld.contains("page not found") || ld.contains("uh-oh") { return true; }
    }

    // Inspect body text for common error phrases (small scan)
    if let Ok(sel_body) = Selector::parse("body") {
        if let Some(body) = document.select(&sel_body).next() {
            let text = body.text().take(200).collect::<Vec<_>>().join(" ").to_lowercase();
            if text.contains("uh-oh") || text.contains("page not found") || text.contains("an error occurred") || text.contains("we\u{2019}re sorry") || text.contains("we are sorry") || text.contains("sorry, an error") {
                return true;
            }
        }
    }

    false
}

fn is_jsonld_article_node(v: &JsonValue) -> bool {
    if v.is_object() {
        let obj = v.as_object().unwrap();
        // check @type or type, could be string or array
        if let Some(t) = obj.get("@type").or_else(|| obj.get("type")) {
            if t.is_string() {
                let s = t.as_str().unwrap_or("").to_lowercase();
                return s.contains("article") || s.contains("newsarticle") || s.contains("report");
            } else if t.is_array() {
                for el in t.as_array().unwrap() {
                    if let Some(s) = el.as_str() {
                        let sl = s.to_lowercase();
                        if sl.contains("article") || sl.contains("newsarticle") || sl.contains("report") { return true; }
                    }
                }
            }
        }
    }
    false
}

fn json_ld_to_item(v: &JsonValue, base: &Url) -> Option<Item> {
    if !v.is_object() {
        return None;
    }
    let obj = v.as_object().unwrap();
    // look for @type or type field
    let typ = obj.get("@type").or_else(|| obj.get("type")).and_then(|t| t.as_str()).unwrap_or("");
    if !(typ.eq_ignore_ascii_case("NewsArticle") || typ.eq_ignore_ascii_case("Article") || typ.eq_ignore_ascii_case("Report")) {
        // not necessarily an article, but still try
    }

    let title_raw = obj.get("headline").and_then(|s| s.as_str()).or_else(|| obj.get("name").and_then(|s| s.as_str())).map(|s| s.to_string())?;
    let title = fix_mojibake(&title_raw);
    // normalize link (make absolute when possible)
    let link = obj.get("url").and_then(|s| s.as_str()).and_then(|s| normalize_maybe_url(base, s)).or_else(|| Some(base.as_str().to_string()))?;
    let description = obj.get("description").and_then(|s| s.as_str()).map(|s| fix_mojibake(&s.to_string()));
    let pub_date = obj.get("datePublished").and_then(|s| s.as_str()).map(|s| s.to_string());
    // image can be string or object or array
    let image = if let Some(img) = obj.get("image") {
        if img.is_string() {
            img.as_str().and_then(|s| normalize_maybe_url(base, s))
        } else if img.is_object() {
            img.get("url").and_then(|u| u.as_str()).and_then(|s| normalize_maybe_url(base, s))
        } else if img.is_array() {
            img.as_array().and_then(|arr| arr.get(0)).and_then(|v| v.as_str()).and_then(|s| normalize_maybe_url(base, s))
        } else {
            None
        }
    } else {
        None
    };

    Some(Item { title, link, description, pub_date, image })
}

// Attempt to repair common mojibake where UTF-8 bytes were decoded as Latin-1/Windows-1252
fn fix_mojibake(s: &str) -> String {
    // Normalize and repair mojibake / whitespace across extracted strings.
    // Strategy:
    // 1. If the string appears clean, run Unicode NFKC normalization and collapse whitespace.
    // 2. Otherwise attempt up to 3 passes of: reinterpret low-8-bit bytes as UTF-8, else decode as Windows-1252.
    // 3. After decoding passes, perform Unicode normalization and whitespace collapse.

    fn collapse_and_normalize(inp: String) -> String {
        let mut out = inp.nfkc().collect::<String>();
        out = out.replace('\u{00A0}', " ");
        out = RE_WHITESPACE.replace_all(&out, " ").to_string();
        out.trim().to_string()
    }

    // quick check for common mojibake markers — if absent, still normalize whitespace/Unicode
    if !s.contains('Ã') && !s.contains('â') && !s.contains('�') {
        return collapse_and_normalize(s.to_string());
    }

    let mut cur = s.to_string();
    for _ in 0..3 {
        let mut bytes: Vec<u8> = Vec::with_capacity(cur.len());
        for ch in cur.chars() {
            let code = ch as u32;
            if code <= 0xFF {
                bytes.push(code as u8);
            } else {
                bytes.extend_from_slice(ch.to_string().as_bytes());
            }
        }

        if let Ok(redecoded) = String::from_utf8(bytes.clone()) {
            if redecoded == cur { break; }
            cur = redecoded;
            if !cur.contains('Ã') && !cur.contains('â') && !cur.contains('�') { break; }
            continue;
        }

        // try Windows-1252
        let (cow, _had_errors) = encoding_rs::WINDOWS_1252.decode_without_bom_handling(&bytes);
        let redecoded = cow.into_owned();
        if redecoded == cur { break; }
        cur = redecoded;
        if !cur.contains('Ã') && !cur.contains('â') && !cur.contains('�') { break; }
    }

    collapse_and_normalize(cur)
}

// Try to parse a URL as absolute, or join it with base when relative.
fn normalize_maybe_url(base: &Url, s: &str) -> Option<String> {
    // quick reject empty
    let s = s.trim();
    if s.is_empty() { return None; }

    // If it already parses as absolute URL, sanitize query-embedded urls
    if let Ok(u) = Url::parse(s) {
        if let Some(inner) = extract_inner_query_url(&u) {
            return Some(inner);
        }
        return Some(Into::<String>::into(u));
    }

    // Try to join relative URLs against base
    if let Ok(u) = base.join(s) {
        if let Some(inner) = extract_inner_query_url(&u) {
            return Some(inner);
        }
        return Some(Into::<String>::into(u));
    }

    // Last resort: look for encoded url=... inside the string
    if let Some(idx) = s.find("url=") {
        let after = &s[idx + 4..];
        for (_k, v) in form_urlencoded::parse(after.as_bytes()) {
            return Some(v.into_owned());
        }
    }

    None
}

// If a URL contains a query parameter like url=https%3A%2F%2F..., extract and return the inner decoded URL.
fn extract_inner_query_url(u: &Url) -> Option<String> {
    if let Some(q) = u.query() {
        for (k, v) in form_urlencoded::parse(q.as_bytes()) {
            if k == "url" || k == "u" {
                return Some(v.into_owned());
            }
        }
    }
    None
}

// Check environment allowlist: comma-separated domains in HTML2RSS_ALLOW_PAYWALL_DOMAINS
fn allowed_domain(u: &Url) -> bool {
    if let Some(host) = u.host_str() {
        if let Ok(val) = env::var("HTML2RSS_ALLOW_PAYWALL_DOMAINS") {
            if val.trim().is_empty() { return false; }
            for part in val.split(',') {
                let p = part.trim().to_lowercase();
                if p.is_empty() { continue; }
                if host.eq_ignore_ascii_case(&p) || host.to_lowercase().ends_with(&format!(".{}", p)) {
                    return true;
                }
            }
        }
    }
    false
}

// Pick a random common browser user-agent string
fn pick_user_agent() -> String {
    let agents = [
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/117.0 Safari/537.36",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:120.0) Gecko/20100101 Firefox/120.0",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
    ];
    let mut rng = thread_rng();
    agents.choose(&mut rng).unwrap_or(&agents[0]).to_string()
}

// Sleep a small randomized amount to mimic human browsing (200-600ms)
fn maybe_sleep() {
    let mut rng = thread_rng();
    let ms = rng.gen_range(200..=600);
    sleep(Duration::from_millis(ms));
}

// Heuristic URL-level paywall checks (avoid fetching if URL strongly indicates paywall)
fn is_paywalled_url(_u: &Url) -> bool {
    // paywall detection disabled — always allow
    false
}

// Heuristic page-level paywall detection (inspect classes, meta tags and body text)
fn is_paywalled_page(_document: &Html) -> bool {
    // paywall detection disabled — always allow
    false
}

// Fetch a URL's text while applying rotating headers, small randomized delay, and paywall checks.
fn get_text_with_headers(client: &Client, url: &Url, _timeout_ms: u64) -> Result<String, Box<dyn Error>> {
    // Avoid fetching clearly paywalled URLs
    if is_paywalled_url(url) {
        eprintln!("Skipping paywalled URL (pattern): {}", url.as_str());
        return Err("paywalled URL".into());
    }

    maybe_sleep();

    let ua = pick_user_agent();
    let resp = client
        .get(url.as_str())
        .header(USER_AGENT, ua)
        .header(ACCEPT, "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
        .header(ACCEPT_LANGUAGE, "en-US,en;q=0.9")
        .header(CONNECTION, "keep-alive")
        .send()?;

    if !resp.status().is_success() {
        return Err(format!("HTTP error: {}", resp.status()).into());
    }

    let body = resp.text()?;
    let doc = Html::parse_document(&body);
    // Skip page-level paywall detection for allowed domains
    if !allowed_domain(url) && is_paywalled_page(&doc) {
        eprintln!("Skipping paywalled page detected after fetch: {}", url.as_str());
        return Err("paywalled page".into());
    }

    Ok(body)
}

// Fetch with retry logic and exponential backoff
fn get_text_with_headers_retry(client: &Client, url: &Url, timeout_ms: u64, max_retries: u32) -> Result<String, Box<dyn Error>> {
    let mut last_error = None;
    
    for attempt in 0..=max_retries {
        if attempt > 0 {
            let backoff = Duration::from_millis(1000 * 2_u64.pow(attempt - 1));
            let backoff_capped = backoff.min(Duration::from_secs(10));
            eprintln!("Retrying {} after {:?} (attempt {}/{})", url, backoff_capped, attempt + 1, max_retries + 1);
            sleep(backoff_capped);
        }
        
        match get_text_with_headers(client, url, timeout_ms) {
            Ok(body) => return Ok(body),
            Err(e) => {
                if attempt < max_retries {
                    eprintln!("Attempt {}/{} failed for {}: {}", attempt + 1, max_retries + 1, url, e);
                }
                last_error = Some(e);
            }
        }
    }
    
    Err(last_error.unwrap())
}

fn extract_from_html(
    client: &Client,
    document: &Html,
    base: &Url,
    max_pages: usize,
    timeout_ms: u64,
) -> Vec<Item> {
    let mut items: Vec<Item> = Vec::new();

    // 1) Extract local <article> elements
    extract_article_elements(document, base, max_pages, &mut items);

    if items.len() >= max_pages && !items.is_empty() {
        return items;
    }

    // 2) Extract related articles if page looks like a single article
    if looks_like_single_article(document) {
        extract_related_articles(document, base, max_pages, &mut items);
    }

    // 3) Build candidate URLs from anchors and headings
    let candidates = build_candidate_list(document, base, max_pages);

    // 4) Fetch and parse candidates
    fetch_candidates(client, &candidates, base, max_pages, timeout_ms, &mut items);

    // 5) Filter and deduplicate
    filter_items(base, &mut items);

    items
}

// ================= Helper Functions =================

fn extract_article_elements(document: &Html, base: &Url, max_pages: usize, items: &mut Vec<Item>) {
    if let Ok(sel) = Selector::parse("article") {
        for art in document.select(&sel).take(50) {
            if items.len() >= max_pages { break; }

            let title = art.select(&Selector::parse("h1,h2,h3").unwrap())
                .next()
                .and_then(|n| n.text().next())
                .map(|s| fix_mojibake(&s.trim().to_string()));

            if let Some(title) = title {
                if title.trim().is_empty() { continue; }

                let link = art.select(&Selector::parse("a").unwrap())
                    .next()
                    .and_then(|a| a.value().attr("href"))
                    .and_then(|h| base.join(h).ok())
                    .map(|u| u.as_str().to_string())
                    .unwrap_or(base.as_str().to_string());

                let desc = art.select(&Selector::parse("p").unwrap())
                    .next()
                    .map(|p| fix_mojibake(&p.text().collect::<Vec<_>>().join(" ")));

                if is_error_page(document, &title, &desc) { continue; }

                if let Ok(link_url) = Url::parse(&link) {
                    if !is_blacklisted_url(&link_url) && !is_listing_page(&link_url, base) {
                        items.push(Item { title, link, description: desc, pub_date: None, image: None });
                    }
                } else {
                    items.push(Item { title, link, description: desc, pub_date: None, image: None });
                }
            }
        }
    }
}

fn looks_like_single_article(document: &Html) -> bool {
    if let Ok(sel_meta) = Selector::parse("meta[property], meta[name]") {
        for m in document.select(&sel_meta) {
            if let Some(name) = m.value().attr("property").or_else(|| m.value().attr("name")) {
                let nl = name.to_lowercase();
                if nl == "og:type" {
                    if let Some(content) = m.value().attr("content") {
                        if content.to_lowercase().contains("article") { return true; }
                    }
                }
                if nl == "article:published_time" || nl == "pubdate" { return true; }
            }
        }
    }
    false
}

fn extract_related_articles(document: &Html, base: &Url, max_pages: usize, items: &mut Vec<Item>) {
    let related_selectors = [
        ".related", ".related-articles", ".related-content", ".more-from",
        ".more-articles", ".promo-list", ".card-list"
    ];
    for sel_s in &related_selectors {
        if items.len() >= max_pages { break; }
        if let Ok(sel) = Selector::parse(sel_s) {
            for node in document.select(&sel) {
                for a in node.select(&Selector::parse("a").unwrap()) {
                    if items.len() >= max_pages { break; }
                    if let Some(href) = a.value().attr("href") {
                        if let Ok(abs) = base.join(href) {
                            if abs.domain() == base.domain() {
                                let s = abs.as_str().to_string();
                                if items.iter().any(|it| it.link == s) { continue; }
                                if is_blacklisted_url(&abs) || is_listing_page(&abs, base) { continue; }
                                let title = fix_mojibake(&a.text().collect::<Vec<_>>().join(" ").trim().to_string());
                                if title.is_empty() || is_error_page(document, &title, &None) { continue; }
                                items.push(Item { title, link: s, description: None, pub_date: None, image: None });
                            }
                        }
                    }
                }
            }
        }
    }
}

// Cached regex patterns for performance
static RE_DATE: Lazy<Regex> = Lazy::new(|| Regex::new(r"/\d{4}/\d{1,2}/\d{1,2}/").unwrap());
static RE_ARTICLE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)(/article/|/articles/|/story/|/stories/|/\d{4}-\d{2}-\d{2})").unwrap());
static RE_HUFF_ENTRY: Lazy<Regex> = Lazy::new(|| Regex::new(r"/entry/[^/]+_[0-9]+$").unwrap());
static RE_WHITESPACE: Lazy<Regex> = Lazy::new(|| Regex::new(r"\s+").unwrap());

// Cap text elements to avoid enormous feed entries (truncate with ellipsis)
const MAX_TEXT_LEN: usize = 4096;

fn build_candidate_list(document: &Html, base: &Url, max_pages: usize) -> Vec<Url> {
    let mut seen = HashSet::new();
    let mut candidates: Vec<Url> = Vec::new();

    if let Ok(sel_a) = Selector::parse("a") {
        for a in document.select(&sel_a).take(2000) {
            if let Some(href) = a.value().attr("href") {
                if let Ok(abs) = base.join(href) {
                    if abs.domain() != base.domain() { continue; }
                    let s = abs.as_str().to_string();
                    if seen.contains(&s) { continue; }

                    let link_text = fix_mojibake(&a.text().collect::<Vec<_>>().join(" ").trim().to_string());
                    let has_img = a.select(&Selector::parse("img").unwrap()).next().is_some();
                    let mut parent_is_card = false;
                    let mut p = a.parent(); let mut depth = 0;
                    while let Some(parent_node) = p {
                        if let Some(elem) = ElementRef::wrap(parent_node) {
                            if let Some(class_attr) = elem.value().attr("class") {
                                let cls = class_attr.to_lowercase();
                                if cls.contains("card") || cls.contains("teaser") || cls.contains("promo") ||
                                   cls.contains("headline") || cls.contains("story") || cls.contains("article") {
                                    parent_is_card = true; break;
                                }
                            }
                        }
                        p = p.and_then(|n| n.parent()); depth += 1; if depth >= 4 { break; }
                    }

                    let mut is_article_like = RE_DATE.is_match(&s) || RE_ARTICLE.is_match(&s) || link_text.len() > 25 || has_img || parent_is_card;
                    if let Some(host) = base.host_str() {
                        if host.to_lowercase().contains("huffpost") {
                            if RE_HUFF_ENTRY.is_match(&s) { is_article_like = true; }
                            else if s.ends_with("/news") || s.ends_with("/news/") || s.ends_with("/all") { is_article_like = false; }
                        }
                    }

                    if is_article_like && !is_blacklisted_url(&abs) {
                        seen.insert(s.clone());
                        candidates.push(abs);
                        if candidates.len() >= max_pages { break; }
                    }
                }
            }
        }
    }

    candidates
}

fn fetch_candidates(
    client: &Client,
    candidates: &[Url],
    base: &Url,
    max_pages: usize,
    timeout_ms: u64,
    items: &mut Vec<Item>,
) {
    for cand in candidates.iter() {
        if items.len() >= max_pages { break; }

        if is_listing_page(cand, base) {
            if is_paywalled_url(cand) { eprintln!("Skipping listing URL (paywalled): {}", cand.as_str()); continue; }
            if let Ok(text_list) = get_text_with_headers(client, cand, timeout_ms) {
                let doc_list = Html::parse_document(&text_list);
                extract_from_listing_page(client, &doc_list, cand, base, max_pages, items);
            }
            continue;
        }

        // Non-listing candidate: fetch directly
        if is_paywalled_url(cand) { eprintln!("Skipping candidate URL (paywalled): {}", cand.as_str()); continue; }
        if let Ok(text) = get_text_with_headers(client, cand, timeout_ms) {
            let doc = Html::parse_document(&text);
            extract_item_from_doc(&doc, cand, base, items);
        }
    }
}

fn extract_from_listing_page(
    client: &Client,
    doc_list: &Html,
    cand: &Url,
    base: &Url,
    max_pages: usize,
    items: &mut Vec<Item>
) {
    if let Ok(sel_a) = Selector::parse("a") {
        for a in doc_list.select(&sel_a) {
            if items.len() >= max_pages { break; }
            if let Some(href) = a.value().attr("href") {
                if let Ok(abs) = cand.join(href) {
                    if abs.domain() != base.domain() { continue; }
                    if items.iter().any(|it| it.link == abs.as_str()) { continue; }

                    let is_article_candidate = RE_DATE.is_match(abs.as_str()) || RE_ARTICLE.is_match(abs.as_str()) || a.select(&Selector::parse("img").unwrap()).next().is_some();
                    if is_article_candidate {
                        if let Ok(text) = get_text_with_headers_retry(client, &abs, 10000, 2) {
                            let doc = Html::parse_document(&text);
                            extract_item_from_doc(&doc, &abs, base, items);
                        }
                    }
                }
            }
        }
    }
}

fn extract_item_from_doc(doc: &Html, cand: &Url, base: &Url, items: &mut Vec<Item>) {
    if let Some(mut jitems) = extract_from_json_ld(doc, cand) {
        if let Some(mut it) = jitems.pop() {
            if it.link.is_empty() { it.link = cand.as_str().to_string(); }
            if !is_error_page(doc, &it.title, &it.description) {
                if let Ok(url) = Url::parse(&it.link) {
                    if !is_blacklisted_url(&url) && !is_listing_page(&url, base) {
                        items.push(it);
                        return;
                    }
                }
                items.push(it);
                return;
            }
        }
    }

    // Meta/title fallback
    let mut found_title: Option<String> = None;
    let mut found_desc: Option<String> = None;
    let mut found_date: Option<String> = None;
    let mut found_image: Option<String> = None;

    if let Ok(sel_meta) = Selector::parse("meta") {
        for m in doc.select(&sel_meta) {
            if let Some(name) = m.value().attr("property").or_else(|| m.value().attr("name")) {
                if let Some(content) = m.value().attr("content") {
                    match name.to_lowercase().as_str() {
                        "og:title" | "twitter:title" | "title" => if found_title.is_none() { found_title = Some(fix_mojibake(&content.to_string())); },
                        "og:description" | "twitter:description" | "description" => if found_desc.is_none() { found_desc = Some(fix_mojibake(&content.to_string())); },
                        "og:image" | "twitter:image" | "image" => if found_image.is_none() { found_image = normalize_maybe_url(cand, content); },
                        "article:published_time" | "pubdate" | "date" => if found_date.is_none() { found_date = Some(content.to_string()); },
                        _ => (),
                    }
                }
            }
        }
    }

    // Fallback to <h1,h2> or <title> if missing
    if found_title.is_none() {
        if let Ok(sel_h) = Selector::parse("h1,h2") {
            if let Some(hn) = doc.select(&sel_h).next() {
                if let Some(t) = hn.text().next() { found_title = Some(fix_mojibake(&t.trim().to_string())); }
            }
        }
    }
    if found_title.is_none() {
        if let Ok(sel_title) = Selector::parse("title") {
            if let Some(tn) = doc.select(&sel_title).next() {
                if let Some(t) = tn.text().next() { found_title = Some(fix_mojibake(&t.trim().to_string())); }
            }
        }
    }

    if found_image.is_none() {
        if let Ok(sel_img) = Selector::parse("img") {
            if let Some(imgn) = doc.select(&sel_img).next() {
                if let Some(src) = imgn.value().attr("src") {
                    found_image = normalize_maybe_url(cand, src);
                }
            }
        }
    }

    if let Some(title) = found_title {
        if !is_error_page(doc, &title, &found_desc) {
            let link_s = cand.as_str().to_string();
            if let Ok(link_url) = Url::parse(&link_s) {
                if !is_blacklisted_url(&link_url) && !is_listing_page(&link_url, base) {
                    items.push(Item { title, link: link_s, description: found_desc, pub_date: found_date, image: found_image });
                }
            } else {
                items.push(Item { title, link: link_s, description: found_desc, pub_date: found_date, image: found_image });
            }
        }
    }
}

fn filter_items(base: &Url, items: &mut Vec<Item>) {
    let mut seen_links = HashSet::new();
    items.retain(|it| {
        let canon = canonicalize_url_str(&it.link);

        if let Ok(u) = Url::parse(&canon) {
            if is_blacklisted_url(&u) || is_listing_page(&u, base) { return false; }
            let path = u.path().to_lowercase();
            if path.contains("/store") || path.contains("/subscribe") || path.contains("/subscriptions") || path.contains("/donate") {
                return false;
            }
        }

        let title_low = it.title.to_lowercase();
        let promo_words = ["subscribe", "subscription", "donate", "support", "newsletter", "become a member", "subscribe to", "subscribe now"];
        if promo_words.iter().any(|pw| title_low.contains(pw)) { return false; }

        if seen_links.contains(&canon) { return false; }
        seen_links.insert(canon);
        true
    });
}



// Heuristic: determine if a URL is a listing/section page rather than an article
fn is_listing_page(u: &Url, base: &Url) -> bool {
    // same-origin required
    if u.domain() != base.domain() { return false; }
    let path = u.path();
    // root path is a listing
    if path == "/" || path.is_empty() { return true; }
    // If path contains known section keywords
    let lower = path.to_lowercase();
    let section_keywords = ["/news", "/section/", "/category/", "/topic/", "/topics/", "/tag/", "/tags/", "/category/"];
    for kw in &section_keywords {
        if lower.contains(kw) { return true; }
    }
    // If path segments are short (<=2) and no date/article pattern, consider it a listing
    let segs: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    if segs.len() <= 2 {
        // if it doesn't look like an article URL (no date or article token), treat as listing
        let re_date_local = Regex::new(r"/\d{4}/\d{1,2}/\d{1,2}/").unwrap();
        let re_article_local = Regex::new(r"(?i)(/article/|/articles/|/story/|/stories/|/entry/|/\d{4}-\d{2}-\d{2})").unwrap();
        if !re_date_local.is_match(path) && !re_article_local.is_match(path) {
            return true;
        }
    }
    false
}

fn is_blacklisted_url(u: &Url) -> bool {
    // blacklist obvious non-article keywords in path or query
    if let Some(q) = u.query() {
        let ql = q.to_lowercase();
        if ql.contains("newsletter") || ql.contains("subscribe") || ql.contains("signup") { return true; }
    }
    let path = u.path().to_lowercase();
    let bad = ["newsletter", "subscribe", "signup", "quizzes", "quiz", "jobs", "careers", "advert", "ads", "promo", "subscribe", "privacy", "terms", "/about", "login", "signin", "/stories/new", "/store", "/subscriptions", "/donate"]; 
    for b in &bad {
        if path.contains(b) { return true; }
    }
    false
}

// Produce a canonical form for URL string comparisons: remove fragment and common tracking query params
fn canonicalize_url_str(s: &str) -> String {
    if let Ok(mut u) = Url::parse(s) {
        // remove fragment
        u.set_fragment(None);
        // filter query params
        if let Some(q) = u.query() {
            let pairs = form_urlencoded::parse(q.as_bytes()).into_owned().filter(|(k, _)| {
                let kl = k.to_lowercase();
                !(kl.starts_with("utm_") || kl == "fbclid" || kl == "gclid")
            }).collect::<Vec<(String, String)>>();
            // rebuild query
            if pairs.is_empty() {
                u.set_query(None);
            } else {
                let mut ser = form_urlencoded::Serializer::new(String::new());
                for (k, v) in pairs.into_iter() { ser.append_pair(&k, &v); }
                let newq = ser.finish();
                u.set_query(Some(&newq));
            }
        }
        return Into::<String>::into(u);
    }
    s.to_string()
}

use quick_xml::events::{BytesStart, BytesEnd, BytesText};

fn write_text_element<W: Write>(w: &mut Writer<W>, name: &str, text: &str) -> Result<(), Box<dyn Error>> {
    w.write_event(Event::Start(BytesStart::new(name)))?;
    // sanitize text: decode HTML entities once, remove control characters that are invalid in XML
    let mut s = sanitize_text(text);
    if s.len() > MAX_TEXT_LEN {
        s.truncate(MAX_TEXT_LEN);
        s.push_str("… (truncated)");
    }
    w.write_event(Event::Text(BytesText::new(&s)))?;
    w.write_event(Event::End(BytesEnd::new(name)))?;
    Ok(())
}

// Decode HTML entities once and strip disallowed XML control characters.
fn sanitize_text(input: &str) -> String {
    // decode entities like &amp; &quot; etc. into Unicode
    let decoded = decode_html_entities(input).to_string();

    // Remove Cc control characters except tab(0x09), LF(0x0A), CR(0x0D)
    decoded.chars()
        .filter(|&c| {
            let code = c as u32;
            if code == 0x09 || code == 0x0A || code == 0x0D { return true; }
            // allow printable characters and other unicode categories (>= 0x20)
            code >= 0x20
        })
        .collect::<String>()
}

// Try to produce RFC-2822 (RFC822 compatible) pubDate values. Fall back to original raw string.
fn format_pub_date(raw: &str) -> String {
    // Try RFC3339 (ISO 8601) first, then RFC2822, otherwise return raw
    if let Ok(dt) = DateTime::parse_from_rfc3339(raw) {
        return dt.to_rfc2822();
    }
    if let Ok(dt) = DateTime::parse_from_rfc2822(raw) {
        return dt.to_rfc2822();
    }
    raw.to_string()
}

fn write_rss(base: &Url, items: &Vec<Item>) -> Result<(), Box<dyn Error>> {
    let mut writer = Writer::new_with_indent(Vec::new(), b' ', 2);
    writer.write_event(Event::Decl(BytesDecl::new("1.0", Some("utf-8"), None)))?;

    // write <rss version="2.0">
    let mut rss_start = BytesStart::new("rss");
    rss_start.push_attribute(("version", "2.0"));
    writer.write_event(Event::Start(rss_start))?;
    writer.write_event(Event::Start(BytesStart::new("channel")))?;
    write_text_element(&mut writer, "title", &format!("Feed for {}", base.host_str().unwrap_or(base.as_str())))?;
    write_text_element(&mut writer, "link", base.as_str())?;
    write_text_element(&mut writer, "description", "Generated by html2rss")?;

    for it in items {
        writer.write_event(Event::Start(BytesStart::new("item")))?;
        write_text_element(&mut writer, "title", &it.title)?;
        write_text_element(&mut writer, "link", &it.link)?;
        if let Some(desc) = &it.description {
            write_text_element(&mut writer, "description", desc)?;
        }
        if let Some(date) = &it.pub_date {
            write_text_element(&mut writer, "pubDate", &format_pub_date(date))?;
        }
        // include image as enclosure when available
        if let Some(img) = &it.image {
            let mut enc = BytesStart::new("enclosure");
            enc.push_attribute(("url", img.as_str()));
            // leave type unspecified; some readers accept enclosure without type
            writer.write_event(Event::Empty(enc))?;
        }
        writer.write_event(Event::End(BytesEnd::new("item")))?;
    }

    writer.write_event(Event::End(BytesEnd::new("channel")))?;
    writer.write_event(Event::End(BytesEnd::new("rss")))?;

    let out = writer.into_inner();
    io::stdout().write_all(&out)?;
    io::stdout().write_all(b"\n")?;
    io::stdout().flush()?;
    Ok(())
}
