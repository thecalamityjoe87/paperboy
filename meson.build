project('paperboy', 'vala',
  version : '0.12.0a',
  meson_version : '>=0.59.0'
)

gtk = dependency('gtk4')
libsoup = dependency('libsoup-3.0')
json = dependency('json-glib-1.0')
gdkpixbuf = dependency('gdk-pixbuf-2.0')
adw = dependency('libadwaita-1')
xml2 = dependency('libxml-2.0')
gee = dependency('gee-0.8')
gio = dependency('gio-2.0')
sqlite = dependency('sqlite3')
webkit = dependency('webkitgtk-6.0')
geoclue = dependency('libgeoclue-2.0')
gst = dependency('gstreamer-1.0')
gst_player = dependency('gstreamer-player-1.0')
gst_audio = dependency('gstreamer-audio-1.0')
poppler = dependency('poppler-glib')
cairo = dependency('cairo')

  executable('paperboy', [
    'src/main.vala',

    # UI
    'src/ui/appWindow.vala',
    'src/ui/contentView.vala',
    'src/ui/sidebarView.vala',

    # UI components
    'src/ui/components/articles/articleCard.vala',
    'src/ui/components/articles/articlePane.vala',
    'src/ui/components/articles/articleSheet.vala',
    'src/ui/components/articles/categorySection.vala',
    'src/ui/components/articles/heroCard.vala',
    'src/ui/components/articles/heroCarousel.vala',
    'src/ui/components/articles/historyCard.vala',
    'src/ui/components/common/marqueeLabel.vala',
    'src/ui/components/common/scrollNavButtons.vala',
    'src/ui/components/common/toastWidget.vala',
    'src/ui/components/sports/leagueBadge.vala',
    'src/ui/components/sports/leagueBadgeCarousel.vala',
    'src/ui/components/markets/marketIndexCard.vala',
    'src/ui/components/sports/scoreCard.vala',
    'src/ui/components/magazines/magazineCard.vala',
    'src/ui/components/magazines/magazineReaderSheet.vala',
    'src/ui/components/magazines/magazineTocPane.vala',
    'src/ui/components/podcasts/podcastCard.vala',
    'src/ui/components/podcasts/podcastHeroCard.vala',
    'src/ui/components/podcasts/podcastPane.vala',
    'src/ui/components/podcasts/podcastPlayerBar.vala',
    'src/ui/components/reader/readerVideoEmbed.vala',
    'src/ui/components/reader/readerView.vala',

    # UI controllers
    'src/ui/controllers/fetchNewsController.vala',
    'src/ui/controllers/myFeedExtrasController.vala',
    'src/ui/controllers/searchController.vala',
    'src/ui/controllers/sportsScoresController.vala',
    'src/ui/controllers/stocksTickerController.vala',

    # UI dialogs
    'src/ui/dialogs/app/aboutDialog.vala',
    'src/ui/dialogs/app/locationDialog.vala',
    'src/ui/dialogs/app/onboardingDialog.vala',
    'src/ui/dialogs/app/prefsDialog.vala',
    'src/ui/dialogs/content/feedRenameDialog.vala',
    'src/ui/dialogs/content/imageViewerDialog.vala',
    'src/ui/dialogs/content/shareDialog.vala',
    'src/ui/dialogs/media/magazineOrganizeDialog.vala',
    'src/ui/dialogs/media/podcastDetailDialog.vala',
    'src/ui/dialogs/media/podcastPickerDialog.vala',
    'src/ui/dialogs/notes/noteEditorDialog.vala',
    'src/ui/dialogs/notes/notesBrowserDialog.vala',

    # UI menus
    'src/ui/menus/articleMenu.vala',
    'src/ui/menus/podcastMenu.vala',
    'src/ui/menus/sidebarMenu.vala',

    # Builders
    'src/builders/cardBuilder.vala',
    'src/builders/placeholderBuilder.vala',

    # Managers
    'src/managers/content/articleManager.vala',
    'src/managers/content/categoryManager.vala',
    'src/managers/content/feedUpdateManager.vala',
    'src/managers/content/imageManager.vala',
    'src/managers/content/searchManager.vala',
    'src/managers/content/sourceManager.vala',
    'src/managers/markets/marketStatusManager.vala',
    'src/managers/sports/sportsLiveIndicatorManager.vala',
    'src/managers/media/magazineLibraryManager.vala',
    'src/managers/media/podcastManager.vala',
    'src/managers/media/podcastPlaybackManager.vala',
    'src/managers/ui/animationManager.vala',
    'src/managers/ui/headerManager.vala',
    'src/managers/ui/layoutManager.vala',
    'src/managers/ui/loadingStateManager.vala',
    'src/managers/ui/sidebarManager.vala',
    'src/managers/ui/toastManager.vala',
    'src/managers/ui/viewStateManager.vala',

    # Services
    'src/services/articles/articleExtractorService.vala',
    'src/services/articles/articleShareService.vala',
    'src/services/articles/articleSnippetService.vala',
    'src/services/articles/articleStateStore.vala',
    'src/services/articles/renderedPageFetcher.vala',
    'src/services/articles/thumbnailBackfillService.vala',
    'src/services/cache/discoveredThumbnailCache.vala',
    'src/services/cache/feedHttpCache.vala',
    'src/services/cache/imageCache.vala',
    'src/services/cache/lruCache.vala',
    'src/services/cache/metaCache.vala',
    'src/services/cache/previewCache.vala',
    'src/services/cache/rssArticleCache.vala',
    'src/services/comments/commentsFeedService.vala',
    'src/services/comments/commentsUrlRegistry.vala',
    'src/services/comments/coralCommentsService.vala',
    'src/services/comments/disqusCommentsService.vala',
    'src/services/comments/hackerNewsCommentsService.vala',
    'src/services/comments/nativeCommentsDiscoveryService.vala',
    'src/services/comments/openWebCommentsService.vala',
    'src/services/comments/viafouraCommentsService.vala',
    'src/services/markets/marketIndicesService.vala',
    'src/services/sports/sportsScoresService.vala',
    'src/services/feeds/fetchContext.vala',
    'src/services/feeds/viewSession.vala',
    'src/services/feeds/generatedFeedService.vala',
    'src/services/feeds/locationLookupService.vala',
    'src/services/feeds/newsService.vala',
    'src/services/feeds/opmlService.vala',
    'src/services/feeds/rssSourceStore.vala',
    'src/services/feeds/sourceMetadata.vala',
    'src/services/feeds/unreadFetchService.vala',
    'src/services/magazines/magazineLibraryStore.vala',
    'src/services/magazines/magazinePdfImportService.vala',
    'src/services/magazines/magazineSourceScanner.vala',
    'src/services/notes/notesExportService.vala',
    'src/services/notes/notesStore.vala',
    'src/services/podcasts/podcastFeedResolver.vala',
    'src/services/podcasts/podcastIndexService.vala',
    'src/services/podcasts/podcastPlaybackStateStore.vala',
    'src/services/podcasts/podcastSubscriptionStore.vala',
    'src/services/settings/prefs.vala',

    # Resolvers
    'src/services/resolvers/articleSourceResolver.vala',
    'src/services/resolvers/googleNewsUrlResolver.vala',

    # Fetchers
    'src/services/fetchers/abcNewsFetcher.vala',
    'src/services/fetchers/articleScraper.vala',
    'src/services/fetchers/baseFetcher.vala',
    'src/services/fetchers/bbcFetcher.vala',
    'src/services/fetchers/bloombergFetcher.vala',
    'src/services/fetchers/fetcherUtils.vala',
    'src/services/fetchers/foxFetcher.vala',
    'src/services/fetchers/guardianFetcher.vala',
    'src/services/fetchers/nprFetcher.vala',
    'src/services/fetchers/nytFetcher.vala',
    'src/services/fetchers/paperboyFetcher.vala',
    'src/services/fetchers/pbsFetcher.vala',
    'src/services/fetchers/wsjFetcher.vala',

    # Models
    'src/models/sports/gameScore.vala',
    'src/models/markets/marketIndexHistory.vala',
    'src/models/markets/marketIndexQuote.vala',
    'src/models/media/imageModels.vala',
    'src/models/media/magazineModels.vala',
    'src/models/media/podcastModels.vala',
    'src/models/news/articleItem.vala',
    'src/models/news/articleNote.vala',
    'src/models/news/feedComment.vala',
    'src/models/news/localArea.vala',
    'src/models/news/newsArticle.vala',
    'src/models/news/rssSource.vala',

    # Utils
    'src/utils/core/appDebugger.vala',
    'src/utils/core/dataPathsUtils.vala',
    'src/utils/core/workerPool.vala',
    'src/utils/lookup/majorCitiesUtils.vala',
    'src/utils/lookup/sourceUtils.vala',
    'src/utils/net/browserUtils.vala',
    'src/utils/net/httpClientUtils.vala',
    'src/utils/net/urlUtils.vala',
    'src/utils/net/webViewUtils.vala',
    'src/utils/text/dateUtils.vala',
    'src/utils/text/sortUtils.vala',
    'src/utils/text/stripHtmlUtils.vala',
    'src/utils/ui/categoryIconsUtils.vala',
    'src/utils/ui/fixedSizeLayoutUtils.vala',
    'src/utils/ui/pixbufUtils.vala',
    'src/utils/ui/podcastImageUtils.vala',
    'src/utils/validation/pdfValidatorUtils.vala',
    'src/utils/validation/rssValidatorUtils.vala',

    # Processors (RSS/HTML/image processing)
    'src/processors/imageProcessor.vala',
    'src/processors/rssFeedProcessor.vala',

    # Sandboxed magazine-PDF thumbnail renderer; main.vala re-execs into it
    'src/tools/magazineThumbnailerTool.vala',
  ],
  dependencies : [gtk, libsoup, json, gdkpixbuf, adw, xml2, gee, gio, sqlite, webkit, geoclue, gst, gst_player, gst_audio, poppler, cairo],
  install : true,
  link_args : ['-lm']
)

install_data('data/io.github.thecalamityjoe87.Paperboy.desktop', install_dir: join_paths(get_option('datadir'), 'applications'))

# Install and compile GSettings schema
install_data('data/resources/io.github.thecalamityjoe87.Paperboy.gschema.xml',
  install_dir: join_paths(get_option('datadir'), 'glib-2.0', 'schemas'))

gnome = import('gnome')
gnome.compile_schemas(depend_files: 'data/resources/io.github.thecalamityjoe87.Paperboy.gschema.xml')
gnome.post_install(glib_compile_schemas: true)

# Install app icons to system icon directories at different sizes
install_data('data/icons/128x128/paperboy.png', install_dir: join_paths(get_option('datadir'), 'icons', 'hicolor', '128x128', 'apps'))
install_data('data/icons/256x256/paperboy.png', install_dir: join_paths(get_option('datadir'), 'icons', 'hicolor', '256x256', 'apps'))
install_data('data/icons/512x512/paperboy.png', install_dir: join_paths(get_option('datadir'), 'icons', 'hicolor', '512x512', 'apps'))
install_data('data/icons/paperboy.png', install_dir: join_paths(get_option('datadir'), 'icons', 'hicolor', '1024x1024', 'apps'))

# Scalable SVG
install_data('data/icons/scalable/paperboy.svg', install_dir: join_paths(get_option('datadir'), 'icons', 'hicolor', 'scalable', 'apps'))

# Vendored copies of a few symbolic action icons (open-menu, sidebar-show,
# view-refresh), app-id-prefixed so they can't collide with or be
# shadowed by the system icon theme's own versions of those names -
# guarantees the current GNOME icon-library glyphs regardless of which
# icon theme (Adwaita, Yaru, etc.) the user has installed. See
# NewsWindow's header-bar setup for where these names are used.
install_data(
  'data/icons/hicolor/scalable/actions/io.github.thecalamityjoe87.Paperboy-open-menu-symbolic.svg',
  'data/icons/hicolor/scalable/actions/io.github.thecalamityjoe87.Paperboy-sidebar-show-symbolic.svg',
  'data/icons/hicolor/scalable/actions/io.github.thecalamityjoe87.Paperboy-view-refresh-symbolic.svg',
  'data/icons/hicolor/scalable/actions/io.github.thecalamityjoe87.Paperboy-comments-symbolic.svg',
  install_dir: join_paths(get_option('datadir'), 'icons', 'hicolor', 'scalable', 'actions')
)

# Install app data (styles, icons) to a namespaced datadir for runtime lookup
install_data('data/resources/style.css', install_dir: join_paths(get_option('datadir'), 'paperboy'))
install_data('data/release_notes.md', install_dir: join_paths(get_option('datadir'), 'paperboy'))
install_subdir('data/icons', install_dir: join_paths(get_option('datadir'), 'paperboy'))
install_subdir('data/images', install_dir: join_paths(get_option('datadir'), 'paperboy'))

# Ensure adblock stylesheet is installed under the namespaced datadir so
# runtime lookups like DataPaths.find_data_file("resources/adblock.css")
# can locate it both in development and when the app is installed.
install_data('data/resources/adblock.css', install_dir: join_paths(get_option('datadir'), 'paperboy', 'resources'))

# Mozilla's Readability.js (Apache-2.0), used by RenderedPageFetcher as the
# reader-view fallback's extraction engine - same install pattern as above.
install_data('data/resources/readability.js', install_dir: join_paths(get_option('datadir'), 'paperboy', 'resources'))
