# v0.12.3a - Fixes for Background Article Audio, Stalled Page Loads, and a Front Page Freeze

- Fixed articles opened in reader view still loading the full page in the background, which on sites like ABC News played the lead video behind the reader and kept its audio going after the video dialog closed. The web page now loads only when you switch to it, and opening another article clears out the previous page
- "Save for later" in reader view now uses the article's actual title
- Fixed articles and feeds from some sites (such as Cosmopolitan, Elle, Esquire, and Road & Track) hanging for up to 30 seconds before loading, due to an HTTP/2 bug in libsoup. These requests now switch to HTTP/1.1 right away
- Fixed the app freezing on the Front Page for up to 20 seconds, sometimes bringing up GNOME's "not responding" prompt, while the Paperboy backend was starting up

# v0.12.2a - Follow Sources From Cards, Local News Menu, and Video Fixes

- Added a follow button that slides out of the source badge when you hover an article card, the hero card, or hero carousel slides. Sites you already follow show an accent checkmark, and built-in sources don't get the button
- Moved the reader view and preview buttons from the center of the card image to a small pill in the image's top-right corner
- Added a right-click menu to Local News cities in the sidebar with "Change location" and "Remove location"
- Category labels on article cards now use your GNOME accent color instead of a fixed blue, and stay readable in light and dark mode
- Fixed Brightcove videos (such as Al Jazeera's) stopping after about 10 seconds

# v0.12.1a - Sports Highlights & In-App Video, Reading Times, Local Weather, and MPRIS

- Added a Highlights row to the Sports page with up to 12 ESPN video clips from your enabled leagues. Clips of your favorite teams come first, and the row refreshes every 30 minutes while Sports is open
- Added in-app video playback across news sites: reader view now finds an article's lead video using the standard tags most publishers include, and plays it in a new video player dialog with autoplay and fullscreen
- The video player handles publisher players, YouTube, Vimeo, Dailymotion, and MP4/HLS streams (via bundled hls.js), with site-specific tweaks for ESPN, Fox News, Fox Business, ABC News, and PBS
- Video-only pages now open in reader view as a title and video instead of failing, and the reader no longer shows a duplicate hero image when the video already uses it as its poster
- Added "N min read" to article, hero, and history cards, using the site's own reading time when it publishes one. For feeds that only include an excerpt, the article is fetched in the background to get it
- Added current weather and today's high/low for your local area to the Local News header and My Feed (via Open-Meteo, in °F or °C to match your locale); clicking it opens GNOME Weather if installed
- Added MPRIS support so podcast playback shows up in GNOME media controls and on the lock screen, and responds to media keys
- Added a dedicated search to Magazine Rack that filters your library by title, category, or source
- The Saved page header now shows your saved article count instead of the date, and History hides the date row and moves "Clear History" up next to the title
- The header date now stays correct past midnight
- The image viewer and video player now center over the content area, with the sidebar dimmed along with it
- Fixed Local News articles appearing out of order: they now show newest-first, cached and live results are merged without duplicates, and newer stories are no longer cut by the item cap
- Fixed favorite-team scores not showing, and game start times failing to parse (which also broke score polling and My Feed's game filter)
- Game times now follow your time zone and GNOME clock format, finished games show their date, unscheduled games show "TBD", and postponed or canceled games no longer show 0-0
- Scores rows are now sorted by start time and open on the first live game (or the latest result), include upcoming soccer fixtures and the next day's games, and My Teams is trimmed to the last 5 results and next 5 games
- Fixed a full-page error staying over loaded articles when just one source failed on Sports, multi-source categories, or My Feed
- Fixed dark logos with transparent backgrounds disappearing on dark themes by giving circular source logos a light backing

# v0.12.0a - Magazine Rack & PDF Reader, Reading History, My Feed Extras, and a Feed Refresh Overhaul

- Added Magazine Rack to import, organize, and read PDF magazines with two-page spreads, pinch/button zoom, swipe page turning with live drag-peek, and a slide-out table of contents panel
- Added an "Organize Rack" drag-and-drop dialog to sort magazines into custom categories, reorder category rows, and toggle flat-grid or category-row views
- Added multi-select to Magazine Rack (right-click "Select", Ctrl+click, or Ctrl+A) with a bottom action bar for batch deletion
- Magazines now reopen at the page you left off on
- Integrated a sandboxed PDF thumbnailer subprocess running via internal re-exec (--internal-magazine-thumbnailer) with crash containment and prefetch caching
- Added a dedicated History view displaying previously read articles in a compact horizontal card layout with relative viewed timestamps, search, and a "Clear History" confirmation dialog
- Added centered empty states for History, Saved, and Magazines, replacing the false "No articles could be loaded" error
- Updated article card styling to display category names as colored accent text above the title instead of floating badges
- Added customizable preview rows at the top of My Feed for Sports scores, Markets, Podcasts, and Magazines with quick "Go to" buttons
- Personalized the My Feed sports row: it follows your league order and favorite teams, puts favorites and live games first, and skips leagues in their off-season
- Fixed the My Feed unread badge resetting on restart, and made disabling My Feed fully clear its content, extras rows, and badge
- Added support for up to 5 Local News cities, each with its own expandable sidebar row and unread count, plus a Preferences group to reorder, change, add, and remove them
- Replaced geocode-glib with direct Nominatim lookups for more accurate town, ZIP, and nearby-metro (within 200 km) results, and removed the dependency
- Improved Local News articles to show the real publisher name, logo, and source badge, and to strip the " - Publisher" suffix from titles
- Fixed the Local News reader view and thumbnails by decoding Google News redirect links, and stopped Google's logo from being used as article thumbnails
- Added renaming for followed feeds from the sidebar right-click menu or Preferences > Feeds
- Added new-episode dots to podcast shows in the sidebar (and to collapsed Podcasts and Popular sections), plus a "More info" item in the podcast right-click menu
- Split the Preferences Sources tab into Built-in sources and Custom feeds subpages, and added Podcasts and Magazines groups to manage subscribed shows and magazine sources
- Added pinch-to-zoom, zoom buttons, and click-and-drag panning to the image viewer
- Reworked background feed refresh into a per-feed scheduler with adaptive intervals, exponential backoff on failures, and pausing while the window is hidden (slower on metered connections and power-saver mode)
- Added conditional GET (ETag/Last-Modified) caching for RSS feeds, so unchanged feeds are served from disk
- Added a memory watchdog that kills runaway WebKit pages over 1.5 GB, and capped merged generated feeds at 100 items
- Improved publish-date extraction for generated feeds and fixed blank card times on sites like AP News; outdated generated feeds now regenerate automatically and are no longer lost if a rewrite fails
- The Guardian now loads through the Paperboy backend after its public API key stopped working, and Guardian and Fox articles now appear in search
- Removed Reddit as a built-in news source (Share to Reddit and user-added Reddit RSS feeds still work)
- Fixed feeds stalling on some HTTP/2 servers by falling back to HTTP/1.1, fixed request timeouts getting stuck at 8s, and silenced parser noise from slightly malformed feeds
- Each view now owns its requests, timers, and on-screen messages, and cleans them all up on exit, so articles, loading spinners, "No more articles", and load-more buttons no longer leak into the next view
- Unified page container ownership and cleanup logic, preventing lingering widgets across page switches, and reset scroll position when navigating categories
- Search now uses its own standard grid layout instead of inheriting the Front Page layout
- Fixed several memory leaks that kept cards, sections, and animations alive after leaving a page
- Fixed Sports and Markets rows going empty after switching pages
- Fixed the article extractor discarding real article bodies on some WordPress sites, and bundled readability.js in the AppImage so the rendered-page fallback works
- Fixed the first-run landing page to open Front Page, and made factory resets save properly
- Fixed a UI deadlock from overlapping feed generation requests, and "WebProcess didn't exit" aborts when quitting mid-render
- Fixed oversized and blurry source badge logos on fractional-scale and HiDPI displays
- Fixed sidebar sections not remembering their expanded state, the expander caret over-rotating, and lists jumping after closing a dialog
- Consolidated redundant symbolic icon size tiers into a single resolution-independent icon directory
- Reorganized the source tree into feature subfolders

# v0.11.3a - Hotfix: Image Viewer Memory Leak

- Fixed a memory leak when closing the full-size image viewer dialog
- Removed a redundant duplicate banner image copy from the AppImage build

# v0.11.2a - Hotfix: Fix Missing Resources Needed for About Dialog

- Fixed missing resources (banner image and release notes) needed for the about dialog

# v0.11.1a - Backup & Restore, WebKit Extraction Rewrite, and a Stability Pass

- Fixed a reader-view crash when adding a note, plus added numbered badges linking note markers to their cards
- Added factory reset and full backup/restore (OPML for feeds/podcasts, JSON for notes) in Preferences
- Replaced the html2rss extraction backend with WebKit-based JavaScript extraction for JS-rendered pages
- Reworked sports score cards to update in place instead of rebuilding each poll, fixing a GTK4 leak, and added a league badge carousel and My Teams row
- Reader images can now pop out into a full-bleed viewer dialog
- Fixed a FeedUpdateManager deadlock, a WebKitGTK crash on regeneration timeouts, and several Front Page/My Feed reveal-timing glitches

# v0.11.0a - Market Index Cards, Article Notes, Gestures & Thumbnail Backfill

- Added market index cards with live intraday price charts for major indices and BTC, plus a hover readout showing price/time at any point
- Added per-article notes with rich-text editing (bold, italic, highlights, lists) and a dedicated Notes sidebar listing every note
- Added automatic thumbnail backfill so articles missing a real image get one extracted in the background
- Replaced the reader's hand-rolled swipe-to-close gesture with a native libadwaita navigation gesture
- Fixed reader view scroll/selection glitches, blurry HiDPI sidebar icons, and malformed author/date extraction on some sites

# v0.10.1a - Hotfix: Reader View Memory Leak

- Fixed WebKit reader web processes never terminating, leaking a sandboxed process every time reader view was used

# v0.10.0a - In-App Reader View & Native Article Comments

- Added a distraction-free reader view with title/byline/hero image/body extraction, video and embed support, and customizable text size, font, and color scheme
- Added native article comments pulled from RSS, Disqus, Hacker News, and three reverse-engineered comment platforms (Coral, OpenWeb, Viafoura), shown in a slide-in comments pane
- Added hover quick-action buttons on article cards to jump straight into reader view
- Added podcast discovery for followed RSS feeds, letting you find and subscribe to a site's podcast directly from its feed
- Fixed podcast mini-player cover art missing after app restart, and several Saved Articles/reader hero image and theming glitches

# v0.9.0a - Podcasts, Global Search & Memory Fixes

- Added a full podcast experience: discovery with hero cards and category rows, GStreamer playback with a persistent mini-player, SQLite-backed subscriptions, and played/new episode tracking
- Replaced category-scoped search with a fuzzy global search across every cached article's title, source, and URL
- Generalized stale-fetch protection into a shared view-ownership guard applied across news, Podcasts, and Sports Scores
- Fixed several Podcasts memory/rendering issues, including a shared image cache being crushed on every fetch and cover art growing past its fixed size
- New app icon, credited to @hyprlab

# v0.8.1a - My Feed Redesign, Memory Fixes & Row Navigation

- Redesigned My Feed as interleaved source/category rows, mirroring Front Page's card layout, with custom RSS feeds able to opt in independently via a new Personalization subpage
- Fixed a memory/freeze regression from that redesign by capping live card widgets per row and tightening HTTP concurrency
- Fixed built-in sources disappearing from My Feed under load, and circular logos being stretched instead of center-cropped
- Fixed Sports' hero carousel staying empty on first load, and My Feed's sidebar unread badge showing inflated counts
- Added a "Go to category" button on Front Page/My Feed rows for quick navigation to the full category page
