# v0.14.1a - My Library for Your Podcasts, Recommendations From Your First Article, and a Feed Freeze Fix

- "Recommended for you" now appears on the Front Page as soon as you open or give a thumbs up to your first article, instead of after ten. It always fills with the articles that best match what you read and like, starting broad and getting more personal the more you read and rate
- Fixed Paperboy freezing while loading a feed whose articles contain certain malformed character codes
- Article cards appear faster, especially on busy pages or when you have many saved articles
- Feeds and article images are processed faster
- Preferences opens faster and no longer lags while opening, especially when you follow many feeds or have a large article cache. Your feed lists in Preferences also open without a pause, with each feed's logo appearing as it loads
- Fixed memory that kept growing while browsing podcasts, the Magazine Rack, and sports scores, and each time a right-click menu was opened, a link or video opened in its own page, or an article was saved
- Paperboy now logs an error when it can't save which articles you've read, or can't back up a damaged settings file, instead of failing silently
- The icon on onboarding's "Where Are You Reading From?" page is now the same soft grey as the large icons on the other pages, instead of solid black or white
- In reader view, right-clicking selected text now offers "Search Google for …", which opens a Google search for it in your browser
- Right-clicking a single selected word in reader view also offers "Define …", which shows its definition in a small popup right under the word, with its pronunciation and meanings grouped by noun, verb, and so on. Definitions come from Wiktionary through the Free Dictionary API, and are in English
- The add-note button in reader view, and the right-click menus in the sidebar and on article and podcast cards, now have a deeper shadow, so they stand out from what's behind them
- Fixed podcast cover art sometimes missing from the player bar and your desktop's media controls after reopening Paperboy in the middle of an episode. If the cover hasn't finished downloading when the episode loads, it now appears as soon as it arrives, and the media controls no longer show the previous episode's cover after you switch
- Added My Library, a new page for the podcasts you subscribe to, under Podcasts in the sidebar. Its badge counts the new episodes across all your shows
- My Library opens with Up Next: up to four episodes to listen to next, starting with ones you're partway through, then the newest unplayed episode from each show. Each card shows when the episode came out, a "New" tag for episodes released since you last opened the show, and a play button with the time left, such as "42m". Once you start an episode, a small progress bar slides out next to the time. Clicking a card plays it, and right-clicking it offers more info or removing the show
- Below Up Next, Your Shows lists every show you subscribe to as a grid of cover art, most recently updated first. Each card shows who makes the show, when it last had a new episode, and how many new episodes you haven't heard
- Searching on the My Library page searches your own shows by name, publisher, or category
- Your subscribed shows now appear in their own "Shows" list in the sidebar, which you can collapse, and each one shows its cover art instead of a generic microphone icon
- Sidebar icons now line up in a single column. Category icons sat slightly left of feed logos and podcast cover art, and the "+" on "Add RSS Feed" and "Add a Podcast" was off-center
- Fixed podcast cover art in the sidebar sometimes not appearing at startup, especially when an episode was loaded in the player

# v0.14.0a - Paperboy Goes International: Your Country's News, a Per-Country Front Page, and Translations in Twenty Languages

- Paperboy now works outside the US. A new Country setting (Preferences → Personalization → Region) picks which country your news comes from, out of the 87 country and language editions Google News offers. It's searchable, and set to "Automatic" by default, which picks your country from your system's time zone and language
- Onboarding has a new "Where Are You Reading From?" page, second in the tour, so you can check the country Paperboy picked and change it before you start
- Outside the US, the "US News" category becomes your country's national news, such as "Brazil News", with headlines from Google News. Articles show the outlet that actually published them
- The national news category's icon is your country's flag, with versions for light and dark mode. Header icons are a little larger so the flags fit
- Outside the US, the Front Page and Trending now show your country's news. The Front Page leads with national headlines, followed by World, Business, Technology, Science, Health, Sports, and Entertainment, and Trending shows Google News' top stories for your country. Each country's Front Page is cached separately, so switching countries doesn't show the previous one's articles
- Outside the US, each category also shows your country's Google News section for it, in your language: World News, Business, Technology, Science, Health, Sports, and Entertainment. Politics and Lifestyle have no Google News section and are unchanged
- NPR, WSJ, the New York Times, and Bloomberg return a full set of articles whichever country you pick. Their searches always use Google News' US edition, since other countries' editions return few or none of their stories. Thanks to djairjr for the fix
- Local News now asks for a postal code instead of a ZIP code, with examples from outside the US, and postal code lookups prefer results in your country
- Place names that already have mixed casing are kept as written, such as "Rio de Janeiro", and two-letter town names are no longer capitalized as if they were US states
- Added translation support, and a Portuguese (Brazil) translation covering the whole interface, including menus, Preferences, onboarding, the reader, podcasts, magazines, notes, and weather conditions. Thanks to djairjr for the translation
- Paperboy is now translated into Spanish, French, German, Italian, Russian, Japanese, and Simplified Chinese, covering the whole interface. One Spanish, French, or German translation serves every country that speaks it, such as Mexico and Argentina, Canada and Belgium, or Austria and Switzerland
- Added Portuguese (Portugal), Dutch, Polish, Turkish, Korean, Ukrainian, Traditional Chinese (for Taiwan and Hong Kong), Indonesian, Vietnamese, Arabic, and Hebrew translations, covering the whole interface. Before, Paperboy was in English in Portugal, since the Brazilian translation isn't used there
- In Arabic and Hebrew, the arrow buttons on scrolling rows, the hero carousel, and the magazine reader stay on the side their arrow points to, and light up on the side your pointer is on. Scrolling titles in right-to-left scripts, such as an Arabic podcast name in the player bar, now start from the right and scroll the right way
- Paperboy's name, description, and search keywords in your app launcher and software center are now translated, so searching for words like "Nachrichten" or "notícias" finds it
- The AppImage now includes the translations, so it shows the interface in your language like the other builds do
- Country names in the Country setting are now shown in your language, and sorted alphabetically in it
- The national news category's name, such as "Brazil News", and Local News headers, such as "Dallas News", are now translated, along with "Automatic" in the Country setting and the category names in page headers
- Fixed some interface text never being offered for translation, including the Front Page and Trending headers and several loading and error messages
- Article times and dates now follow your language, both in wording and in date order: the "7m ago" on article cards, the date on cards older than a week, the date in page headers, article bylines, and game days on sports score cards. In German, for example, they read "vor 3 Std." and "5. Okt."
- Notifications, buttons, and dialogs that were still in English are now translated, including the messages when you follow a source, add a feed or podcast, go offline, or rate an article; the reading time on article cards; the built-in outlets' descriptions in Preferences; the Clear Cache and Reset confirmations; the "Go to" buttons in My Feed; and the subject and message of articles shared by email
- Counts now use the right plural in every language, including ones with more than one plural form such as Russian, for example in search results, saved articles, followed feeds, podcasts and their episodes, magazines, sources, categories, locations, and import messages. Search results are now translated as whole sentences, so they read naturally instead of having the word "articles", "podcasts", or "magazines" dropped into them
- Cache sizes in Preferences → App → Data now use your language's units and decimal separator, such as "2,5 MB" in German or "2,5 Mo" in French, and the RSS feed cache's article count uses the right plural
- Market index cards now format prices and changes with your locale's decimal separator and digit grouping, such as "51.234,50 $" in German, with the dollar sign where your language puts it. Prices are still in US dollars. The time shown when you hover over a chart now follows your 12-hour or 24-hour clock setting
- Translated the remaining English text, including the weather header's high and low, the follow button's tooltip on article cards, the messages when a podcast or magazine is added, the time left on podcast episodes, "By" in reader view bylines, magazine download errors, the confirmation when you remove a magazine source, and fallback names such as "Local News", "No title", and "Unknown". Messages that used to be built from pieces, such as "Podcast added: …", are now translated as whole sentences
- Article bylines now follow your system's 12-hour or 24-hour clock setting
- Fixed a failed feed showing a loading spinner until it timed out, instead of an error message, when Paperboy is in a language other than English
- Fixed dates on article cards older than a week sometimes being a day off, since they didn't use your time zone
- Fixed the page header's date padding the day with a zero, such as "October 05"
- Added a Contributors page to the About dialog, listing each contributor and what they contributed
- Websites are asked for pages in your language
- Fixed articles from pages that aren't in UTF-8, such as Chinese (GB2312) or Latin-1 pages, failing to open in reader view
- Fixed the Front Page's hero carousel sometimes not appearing after picking a new country, until you refreshed
- Sports score cards now cover individual sports: tennis (ATP and WTA), golf (PGA Tour, LPGA Tour, and DP World Tour), racing (Formula 1, NASCAR Cup Series, and IndyCar), and PFL. They're off by default; switch them on in Preferences → Personalization → Sports Score Cards → Leagues
- Golf and racing cards show the top three places, with each athlete's flag, and golfers level on score share a place, such as "T2". Tennis cards show the games won in each set
- Tennis, golf, and racing cards now show the name of the tournament or race, along with the round or session, such as the semifinal of the China Open or qualifying for the Bahrain Grand Prix
- Tennis shows main-draw singles matches from about the last day to the next day and a half, so a tournament's earlier rounds don't flood the row. Formula 1 shows qualifying and races, not practice sessions
- Golf tournaments that haven't started show their date instead of "TBD", and no longer show the day before in time zones west of US Eastern
- Added 16 regional football (soccer) and rugby leagues: La Liga, Bundesliga, Serie A, Ligue 1, Eredivisie, Primeira Liga, Süper Lig, the Europa League, Liga MX, the Brasileirão, Argentina's Liga Profesional, the Copa Libertadores, the J.League, the Saudi Pro League, the A-League, and the Six Nations. Each one is on by default in the countries that follow it, such as La Liga in Spain, the Bundesliga in Germany, Austria, and Switzerland, or Liga MX in Mexico and the US Spanish edition, and its section comes first in the Sports category there unless you've set your own section order. Everywhere else they're off until you switch them on
- Preferences → Personalization → Sports Score Cards has two new pages. Leagues lists every league under a region heading (International, Europe, United States and Canada, Latin America, and Asia and Oceania), with its sport underneath, so you can switch each one on or off. Section Order lets you drag the leagues that are on into the order their sections appear in the Sports category
- NFL, NBA, MLB, NHL, and MLS score cards are now on by default only in the US and Canada, and college leagues only in the US. Elsewhere they're off until you switch them on in Preferences → Personalization → Sports Score Cards → Leagues. If you already switched a league on or off yourself, your choice is kept
- Onboarding's Live Sports Scores page now groups leagues by region, with each league's sport underneath, the same as Preferences' Leagues page. Drag-to-reorder moved out of onboarding; set the order of league sections anytime in Preferences → Section Order
- Fixed Trending sometimes showing fewer than 10 articles when it first loads, with the rest appearing later

# v0.13.1a - Sidebar Footer with Notes and Now Playing

- Added a fixed footer to the bottom of the sidebar with Notes and a new Now Playing button, so they're always in reach without scrolling the list
- Notes moved from the sidebar list into the new footer
- Now Playing shows or hides the podcast controls without stopping playback. It's highlighted while the controls are open, and greyed out when nothing is loaded
- Now Playing shows animated bars while a podcast is playing, lined up with the sidebar's unread counts
- Added a minimize button next to the podcast controls' close button, so you can tuck them away without stopping playback. The close button's tooltip now says "Stop and close" to make the difference clear
- The podcast controls now stay hidden when the next episode starts on its own, instead of popping back up
- New Now Playing icon, with a white version for dark mode
- Sidebar icons and unread counts now sit closer to the edges of the sidebar, giving names a little more room
- Fixed the podcast controls showing 0:00 after reopening the app, even though the episode resumes where you left off. They now show your saved spot right away

# v0.13.0a - Categories First, Sources as Filters, and a New Categories Page

- Categories are now the main way to browse news. They're filled from the Paperboy service alongside your enabled sources, so a category never comes up empty or sends you back to the Front Page just because none of your sources cover it
- Turning a source off now works as a filter: its articles are hidden everywhere except Saved, History, and your own RSS feeds
- Added a Categories page to Preferences where you can switch categories on or off and drag them into the order you want. The same list drives the sidebar and My Feed, and all ten categories are on by default
- Renamed the sidebar's "Popular Categories" section to "Categories" and added a "Manage Categories" row to it
- Changes to categories and My Feed now apply right away, without the refresh prompt
- Onboarding has a new "What Do You Want to Read?" page, clearer wording on the sources page, and no longer shows the outdated "No Sources Enabled" warning
- There's no longer a single "default source," so Paperboy no longer falls back to The Guardian
- Removed the Markets, Industries, and Economics categories, which only Bloomberg provided
- Sources without a feed for a category now show nothing there instead of filling it with world news
- Added NPR's Business feed
- Turning off all your sources is now remembered instead of bringing the defaults back
- Confirmation prompts now look the same throughout the app, and icons in Preferences are a consistent size
- Fixed PBS being ignored when you turned it on or used it as your only source
- Fixed ABC News and WSJ articles being filed under Science, and NPR articles under Business, by mistake
- Fixed outlets with similar names getting another outlet's name and logo, such as TIME showing as the New York Times or Fox Sports as Fox News
- Fixed settings failing to load properly on first launch
- Fixed crashes when saving some settings and opening some dropdown menus
- Fixed empty spots in the Front Page's Trending grid when some trending stories came from sources you've turned off, and Trending repeating stories already shown in the hero carousel
- Fixed the follow button sliding under the thumbs up/down buttons on narrow Front Page cards, such as Trending, when the source has a long name. The name is now shortened to make room
- The thumbs up/down buttons on Front Page cards are now the same height as the source badge beside them
- Fixed a typo on the My Feed page when My Feed is turned off

# v0.12.5a - Recommended For You, and Podcast Playback Order Fixes

- Added a personalized "Recommended for you" panel to the Front Page, based on the topics, sites, and categories you read most. It appears once you have some reading history
- Added thumbs up/down on Front Page cards — disliking an article fades it out and swaps in the next best pick; liking or disliking shapes future picks more than reading history alone
- Recommendations now rotate instead of repeating the same picks, and lean slightly toward newer articles
- Added a "Show recommendations" toggle under Personalization > Front Page to turn the section off entirely
- Fixed sports articles landing in "More Stories" instead of the Sports row
- Fixed the "More Stories" arrow never loading more articles
- Front Page rows now show a tidier number of articles sized to each row instead of a flat cutoff
- Fixed next/previous playing podcast episodes out of order — they now go by release date, so a show plays start to finish correctly
- Next/previous grey out at the start/end of a show's episodes and always follow whichever show is actually playing
- Your current show's episode list now works right after restarting the app, even offline
- Fixed a doubled-up line in the podcast episode list
- Fixed long source names pushing the article preview pane sideways

# v0.12.4a - ABC News Video, Article Link, and Follow Button Fixes

- Fixed every ABC News article without its own video playing the same generic "Headlines from ABC News Live" clip. Those articles (including all AP wire stories) now show no video, and ABC stories with their own clip play that clip
- Fixed articles whose links rely on a query string (such as ABC News's story?id= pages) opening to a "page unavailable" error. Articles now open, and are saved to History, with their full link
- The follow button on article cards now appears only on the Front Page and in search results, where you're likely to find sources you don't follow yet
- Search results now show a source badge on every article, including ones from your followed feeds, with the same follow button on hover
- Built-in sources now get the follow button too: a check shows when the source is enabled, and following a disabled one switches it back on. The card's right-click menu offers "Enable built-in source" for disabled ones
- Fixed cards showing a source as followed because of a different feed on the same site (for example, following Yahoo Finance marked every Yahoo article as followed)
- Fixed articles from other sites being treated as built-in sources when their link merely mentioned one (such as "bloomberg" in the article's address)
- Redesigned the checkmark used throughout the app (following, subscribed podcasts, magazine selection, and onboarding) as a smaller, cleaner check inside a white-ringed circle, drawn the same way regardless of your icon theme
- Onboarding's theme and source checkmarks now use your GNOME accent color instead of a fixed green
- Fixed the local weather staying in the header after starting a search from Local News or My Feed

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
