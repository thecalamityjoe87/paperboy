project('paperboy', 'vala',
  version : '0.7.0a',
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
# installed data and binaries. This avoids hardcoding candidate paths
# like /usr/local/bin in the source; the path is templated at build
# time and respects Meson's prefix/bindir settings.
conf = configuration_data()
conf.set('bindir', get_option('bindir'))
build_constants = configure_file(input: 'meson-templates/build_constants.vala.in',
                                 output: 'buildConstants.vala',
                                 configuration: conf)

  
  executable('paperboy', [
    build_constants,
    'src/main.vala',

    # UI
    'src/ui/appWindow.vala',
    'src/ui/prefsDialog.vala',
    'src/ui/locationDialog.vala',
    'src/ui/contentView.vala',
    'src/ui/articlePane.vala',
    'src/ui/articleCard.vala',
    'src/ui/articleSheet.vala',
    'src/ui/heroCard.vala',
    'src/ui/heroCarousel.vala',
    'src/ui/shareDialog.vala',
    'src/ui/menus/articleMenu.vala',

    # Builders
    'src/builders/cardBuilder.vala',
    'src/builders/placeholderBuilder.vala',

    # Actions
    'src/actions/articleActions.vala',

    # Managers
    'src/managers/sourceManager.vala',
    'src/managers/categoryManager.vala',
    'src/managers/headerManager.vala',
    'src/managers/loadingStateManager.vala',
    'src/managers/viewStateManager.vala',
    'src/managers/layoutManager.vala',
    'src/managers/articleManager.vala',
    'src/managers/sidebarManager.vala',
    'src/managers/imageHandler.vala',
    'src/managers/toastManager.vala',
    'src/managers/feedUpdateManager.vala',

    # Services / models
    'src/services/metaCache.vala',
    'src/services/articleStateStore.vala',
    'src/services/imageCache.vala',
    'src/services/newsSources.vala',
    'src/services/prefs.vala',
    'src/services/lruCache.vala',
    'src/services/sourceMetadata.vala',
    'src/services/previewCache.vala',
    'src/services/rssFinderService.vala',
    'src/services/rssSourceStore.vala',
    'src/models/newsArticle.vala',
    'src/models/rssSource.vala',

    # Utils
    'src/utils/appDebugger.vala',
    'src/utils/urlUtils.vala',
    'src/utils/sourceUtils.vala',
    'src/utils/dateUtils.vala',
    'src/utils/dataPaths.vala',
    'src/utils/categoryIcons.vala',
    'src/utils/pixbufUtils.vala',
    'src/utils/workerPool.vala',
    'src/utils/httpClient.vala',
    'src/utils/rssValidator.vala',

    # Tools used at build/runtime
    'tools/rssParser.vala',
    'tools/imageParser.vala',
    'tools/articleScraper.vala',
    'tools/stripHTML.vala',
    'tools/zipLookup.vala',
  ],
  dependencies : [gtk, libsoup, json, gdkpixbuf, adw, xml2, gee, gio, sqlite, webkit],
  install : true,
  link_args : ['-lm']
)

  # Install the rssFinder helper as a separate executable so it is
  # available in the user's PATH after "ninja install". Keep the
  # name in camel-case so `prefsDialog` can find it at
  # /usr/local/bin/rssFinder (the preference logic expects this name).
  executable('rssFinder', 'tools/rssFinder.vala',
    dependencies : [gio],
    install : true
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
# Place it under the app's namespaced datadir and also into bindir so the
# runtime can find it either as a tool in the data dir or in PATH.
if files('tools/html2rss/target/release/html2rss').length() > 0
  install_data('tools/html2rss/target/release/html2rss', install_dir: join_paths(get_option('datadir'), 'org.gnome.Paperboy', 'tools'))
  install_data('tools/html2rss/target/release/html2rss', install_dir: get_option('bindir'))
endif
