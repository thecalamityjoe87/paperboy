project('paperboy', 'vala',
  version : '0.7.4a',
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
    'src/ui/components/heroCard.vala',
    'src/ui/components/heroCarousel.vala',
    'src/ui/components/toastWidget.vala',
    'src/ui/controllers/fetchNewsController.vala',
    'src/ui/controllers/searchController.vala',
    'src/ui/dialogs/prefsDialog.vala',
    'src/ui/dialogs/locationDialog.vala',
    'src/ui/dialogs/shareDialog.vala',
    'src/ui/menus/articleMenu.vala',
    'src/ui/menus/sidebarMenu.vala',

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
    'src/managers/searchManager.vala',

    # Services / models / resolvers
    'src/services/unreadFetchService.vala',
    'src/services/fetchContext.vala',
    'src/services/metaCache.vala',
    'src/services/articleStateStore.vala',
    'src/services/articleSnippetService.vala',
    'src/services/imageCache.vala',
    'src/services/newsService.vala',
    'src/services/prefs.vala',
    'src/services/lruCache.vala',
    'src/services/sourceMetadata.vala',
    'src/services/previewCache.vala',
    'src/services/rssFinderService.vala',
    'src/services/articleShareService.vala',
    'src/services/rssSourceStore.vala',
    'src/services/rssArticleCache.vala',
    'src/services/resolvers/articleSourceResolver.vala',
    'src/models/newsArticle.vala',
    'src/models/rssSource.vala',
    'src/models/articleItem.vala',
    'src/models/imageModels.vala',

    # Fetchers
    'src/services/fetchers/baseFetcher.vala',
    'src/services/fetchers/fetcherUtils.vala',
    'src/services/fetchers/bbcFetcher.vala',
    'src/services/fetchers/guardianFetcher.vala',
    'src/services/fetchers/nytFetcher.vala',
    'src/services/fetchers/wsjFetcher.vala',
    'src/services/fetchers/redditFetcher.vala',
    'src/services/fetchers/bloombergFetcher.vala',
    'src/services/fetchers/reutersFetcher.vala',
    'src/services/fetchers/nprFetcher.vala',
    'src/services/fetchers/foxFetcher.vala',
    'src/services/fetchers/paperboyFetcher.vala',

    # Utils
    'src/utils/appDebugger.vala',
    'src/utils/urlUtils.vala',
    'src/utils/browserUtils.vala',
    'src/utils/sourceUtils.vala',
    'src/utils/dateUtils.vala',
    'src/utils/dataPathsUtils.vala',
    'src/utils/categoryIconsUtils.vala',
    'src/utils/pixbufUtils.vala',
    'src/utils/workerPool.vala',
    'src/utils/httpClientUtils.vala',
    'src/utils/rssValidatorUtils.vala',
    'src/utils/stripHtmlUtils.vala',

    # Processors (RSS/HTML/image processing)
    'src/processors/rssFeedProcessor.vala',
    'src/processors/imageProcessor.vala',
    'tools/articleScraper.vala',
    'tools/zipLookup.vala',
  ],
  dependencies : [gtk, libsoup, json, gdkpixbuf, adw, xml2, gee, gio, sqlite, webkit],
  install : true,
  link_args : ['-lm']
)

  # Install the rssFinder helper as an internal binary per FHS 4.7.
  # This is only called by the Paperboy application, not by users directly.
  executable('rssFinder', 'tools/rssFinder.vala',
    dependencies : [gio],
    install : true,
    install_dir : join_paths(get_option('libexecdir'), 'paperboy')
  )

install_data('data/io.github.thecalamityjoe87.Paperboy.desktop', install_dir: join_paths(get_option('datadir'), 'applications'))

# Install and compile GSettings schema
install_data('data/resources/io.github.thecalamityjoe87.Paperboy.gschema.xml',
  install_dir: join_paths(get_option('datadir'), 'glib-2.0', 'schemas'))

gnome = import('gnome')
gnome.compile_schemas(depend_files: 'data/resources/io.github.thecalamityjoe87.Paperboy.gschema.xml')

# Install app icons to system icon directories at different sizes
install_data('data/icons/128x128/paperboy.png', install_dir: join_paths(get_option('datadir'), 'icons', 'hicolor', '128x128', 'apps'))
install_data('data/icons/256x256/paperboy.png', install_dir: join_paths(get_option('datadir'), 'icons', 'hicolor', '256x256', 'apps'))
install_data('data/icons/512x512/paperboy.png', install_dir: join_paths(get_option('datadir'), 'icons', 'hicolor', '512x512', 'apps'))
install_data('data/icons/paperboy.png', install_dir: join_paths(get_option('datadir'), 'icons', 'hicolor', '1024x1024', 'apps'))

# Scalable SVG
install_data('data/icons/scalable/paperboy.svg', install_dir: join_paths(get_option('datadir'), 'icons', 'hicolor', 'scalable', 'apps'))

# Install app data (styles, icons) to a namespaced datadir for runtime lookup
install_data('data/resources/style.css', install_dir: join_paths(get_option('datadir'), 'paperboy'))
install_subdir('data/icons', install_dir: join_paths(get_option('datadir'), 'paperboy'))
install_data('data/usZips.csv', install_dir: join_paths(get_option('datadir'), 'paperboy'))

# Ensure adblock stylesheet is installed under the namespaced datadir so
# runtime lookups like DataPaths.find_data_file("resources/adblock.css")
# can locate it both in development and when the app is installed.
install_data('data/resources/adblock.css', install_dir: join_paths(get_option('datadir'), 'paperboy', 'resources'))

# Build and install the html2rss helper via Cargo so it is available
# when running `ninja` / `ninja install`. We use a custom_target that
# invokes Cargo in the tool's directory and copies the produced binary
# into the Meson build directory as the target output. The resulting
# target is then installed into both the namespaced datadir and the
# bindir so the runtime can locate it either from the data dir or PATH.
if files('tools/html2rss/Cargo.toml').length() > 0
  message('Found html2rss Rust project; building with Cargo...')
  # Run cargo build at configure time so the produced binary is available
  # for installation and for runtime lookup paths used by the app.
  run_result = run_command('bash', '-lc', 'cd ' + meson.project_source_root() + '/tools/html2rss && cargo build --release', check: true)
  if run_result.returncode() != 0
    message('Warning: cargo build for html2rss failed; html2rss will not be installed')
  endif
endif

# Install the html2rss helper binary if present (built via Cargo).
# Per FHS 4.7, internal binaries run by other programs belong in libexecdir,
# not bindir or datadir. Use a namespaced subdirectory to avoid conflicts.
if files('tools/html2rss/target/release/html2rss').length() > 0
  install_data('tools/html2rss/target/release/html2rss', install_dir: join_paths(get_option('libexecdir'), 'paperboy'))
endif
