project('paperboy', 'vala',
  version : '0.11.3a',
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
geocode = dependency('geocode-glib-2.0')
gst = dependency('gstreamer-1.0')
gst_player = dependency('gstreamer-player-1.0')
gst_audio = dependency('gstreamer-audio-1.0')

# Generate build-time constants so the application knows where meson
# installed internal binaries. This avoids hardcoding candidate paths
# like /usr/local/libexec in the source; the path is templated at build
# time and respects Meson's prefix/libexecdir settings.
conf = configuration_data()
conf.set('libexecdir', get_option('libexecdir'))
build_constants = configure_file(input: 'meson-templates/build_constants.vala.in',
                                 output: 'buildConstants.vala',
                                 configuration: conf)

  
  executable('paperboy', [
    build_constants,
    'src/main.vala',

    # UI
    'src/ui/appWindow.vala',
    'src/ui/contentView.vala',
    'src/ui/sidebarView.vala',
    'src/ui/components/articlePane.vala',
    'src/ui/components/articleCard.vala',
    'src/ui/components/articleSheet.vala',
    'src/ui/components/readerView.vala',
    'src/ui/components/readerVideoEmbed.vala',
    'src/ui/components/heroCard.vala',
    'src/ui/components/heroCarousel.vala',
    'src/ui/components/scrollNavButtons.vala',
    'src/ui/components/categorySection.vala',
    'src/ui/components/scoreCard.vala',
    'src/ui/components/leagueBadge.vala',
    'src/ui/components/leagueBadgeCarousel.vala',
    'src/ui/components/marketIndexCard.vala',
    'src/ui/components/toastWidget.vala',
    'src/ui/components/podcastHeroCard.vala',
    'src/ui/components/podcastCard.vala',
    'src/ui/components/podcastPlayerBar.vala',
    'src/ui/components/podcastPane.vala',
    'src/ui/components/marqueeLabel.vala',
    'src/ui/controllers/fetchNewsController.vala',
    'src/ui/controllers/searchController.vala',
    'src/ui/controllers/sportsScoresController.vala',
    'src/ui/controllers/stocksTickerController.vala',
    'src/ui/dialogs/prefsDialog.vala',
    'src/ui/dialogs/aboutDialog.vala',
    'src/ui/dialogs/locationDialog.vala',
    'src/ui/dialogs/shareDialog.vala',
    'src/ui/dialogs/onboardingDialog.vala',
    'src/ui/dialogs/podcastDetailDialog.vala',
    'src/ui/dialogs/podcastPickerDialog.vala',
    'src/ui/dialogs/noteEditorDialog.vala',
    'src/ui/dialogs/notesBrowserDialog.vala',
    'src/ui/dialogs/imageViewerDialog.vala',
    'src/ui/menus/articleMenu.vala',
    'src/ui/menus/sidebarMenu.vala',
    'src/ui/menus/podcastMenu.vala',

    # Builders
    'src/builders/cardBuilder.vala',
    'src/builders/placeholderBuilder.vala',

    # Managers
    'src/managers/sourceManager.vala',
    'src/managers/categoryManager.vala',
    'src/managers/headerManager.vala',
    'src/managers/loadingStateManager.vala',
    'src/managers/viewStateManager.vala',
    'src/managers/layoutManager.vala',
    'src/managers/articleManager.vala',
    'src/managers/sidebarManager.vala',
    'src/managers/imageManager.vala',
    'src/managers/toastManager.vala',
    'src/managers/feedUpdateManager.vala',
    'src/managers/sportsLiveIndicatorManager.vala',
    'src/managers/marketStatusManager.vala',
    'src/managers/searchManager.vala',
    'src/managers/animationManager.vala',
    'src/managers/podcastManager.vala',
    'src/managers/podcastPlaybackManager.vala',

    # Services / models / resolvers
    'src/services/unreadFetchService.vala',
    'src/services/fetchContext.vala',
    'src/services/metaCache.vala',
    'src/services/articleStateStore.vala',
    'src/services/articleSnippetService.vala',
    'src/services/articleExtractorService.vala',
    'src/services/renderedPageFetcher.vala',
    'src/services/thumbnailBackfillService.vala',
    'src/services/discoveredThumbnailCache.vala',
    'src/services/imageCache.vala',
    'src/services/newsService.vala',
    'src/services/prefs.vala',
    'src/services/lruCache.vala',
    'src/services/sourceMetadata.vala',
    'src/services/previewCache.vala',
    'src/services/articleShareService.vala',
    'src/services/rssSourceStore.vala',
    'src/services/rssArticleCache.vala',
    'src/services/commentsUrlRegistry.vala',
    'src/services/commentsFeedService.vala',
    'src/services/hackerNewsCommentsService.vala',
    'src/services/disqusCommentsService.vala',
    'src/services/openWebCommentsService.vala',
    'src/services/coralCommentsService.vala',
    'src/services/viafouraCommentsService.vala',
    'src/services/nativeCommentsDiscoveryService.vala',
    'src/services/locationLookupService.vala',
    'src/services/sportsScoresService.vala',
    'src/services/marketIndicesService.vala',
    'src/services/podcastIndexService.vala',
    'src/services/podcastFeedResolver.vala',
    'src/services/podcastSubscriptionStore.vala',
    'src/services/podcastPlaybackStateStore.vala',
    'src/services/notesStore.vala',
    'src/services/opmlService.vala',
    'src/services/notesExportService.vala',
    'src/services/generatedFeedService.vala',
    'src/services/resolvers/articleSourceResolver.vala',
    'src/models/newsArticle.vala',
    'src/models/rssSource.vala',
    'src/models/articleItem.vala',
    'src/models/feedComment.vala',
    'src/models/articleNote.vala',
    'src/models/imageModels.vala',
    'src/models/marketIndexHistory.vala',
    'src/models/gameScore.vala',
    'src/models/marketIndexQuote.vala',
    'src/models/podcastModels.vala',

    # Fetchers
    'src/services/fetchers/baseFetcher.vala',
    'src/services/fetchers/fetcherUtils.vala',
    'src/services/fetchers/articleScraper.vala',
    'src/services/fetchers/bbcFetcher.vala',
    'src/services/fetchers/guardianFetcher.vala',
    'src/services/fetchers/nytFetcher.vala',
    'src/services/fetchers/wsjFetcher.vala',
    'src/services/fetchers/redditFetcher.vala',
    'src/services/fetchers/bloombergFetcher.vala',
    'src/services/fetchers/abcNewsFetcher.vala',
    'src/services/fetchers/nprFetcher.vala',
    'src/services/fetchers/foxFetcher.vala',
    'src/services/fetchers/pbsFetcher.vala',
    'src/services/fetchers/paperboyFetcher.vala',

    # Utils
    'src/utils/appDebugger.vala',
    'src/utils/urlUtils.vala',
    'src/utils/sortUtils.vala',
    'src/utils/browserUtils.vala',
    'src/utils/sourceUtils.vala',
    'src/utils/dateUtils.vala',
    'src/utils/dataPathsUtils.vala',
    'src/utils/webViewUtils.vala',
    'src/utils/categoryIconsUtils.vala',
    'src/utils/pixbufUtils.vala',
    'src/utils/fixedSizeLayoutUtils.vala',
    'src/utils/workerPool.vala',
    'src/utils/httpClientUtils.vala',
    'src/utils/rssValidatorUtils.vala',
    'src/utils/podcastImageUtils.vala',
    'src/utils/stripHtmlUtils.vala',
    'src/utils/majorCitiesUtils.vala',

    # Processors (RSS/HTML/image processing)
    'src/processors/rssFeedProcessor.vala',
    'src/processors/imageProcessor.vala',
  ],
  dependencies : [gtk, libsoup, json, gdkpixbuf, adw, xml2, gee, gio, sqlite, webkit, geoclue, geocode, gst, gst_player, gst_audio],
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
