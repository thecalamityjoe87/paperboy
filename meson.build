project('paperboy', 'vala',
  version : '0.1.0'
)

gtk = dependency('gtk4')
libsoup = dependency('libsoup-2.4')
json = dependency('json-glib-1.0')
gdkpixbuf = dependency('gdk-pixbuf-2.0')
adw = dependency('libadwaita-1')
xml2 = dependency('libxml-2.0')
gee = dependency('gee-0.8')
gio = dependency('gio-2.0')

# Generate build-time constants so the application knows where meson
# installed data and binaries. This avoids hardcoding candidate paths
# like /usr/local/bin in the source; the path is templated at build
# time and respects Meson's prefix/bindir settings.
conf = configuration_data()
conf.set('bindir', get_option('bindir'))
build_constants = configure_file(input: 'meson-templates/build_constants.vala.in',
                                 output: 'build_constants.vala',
                                 configuration: conf)

  
  executable('paperboy', [build_constants, 'src/main.vala', 'src/appWindow.vala', 'src/contentView.vala', 'src/articleCard.vala', 'src/heroCard.vala', 'src/heroCarousel.vala', 'src/newsSources.vala', 'tools/rssParser.vala', 'src/articlePane.vala', 'src/metaCache.vala', 'src/prefs.vala', 'src/prefsDialog.vala', 'tools/zipLookup.vala', 'tools/imageParser.vala', 'tools/articleScraper.vala', 'tools/stripHTML.vala', 'src/newsArticle.vala', 'src/utils/urlUtils.vala', 'src/utils/appDebugger.vala', 'src/utils/dataPaths.vala', 'src/utils/sourceLogos.vala', 'src/utils/categoryIcons.vala', 'src/utils/lruCache.vala', 'src/imageHandler.vala', 'src/utils/workerPool.vala', 'src/sidebarManager.vala', 'src/placeholderBuilder.vala', 'src/utils/previewCache.vala', 'src/builders/cardBuilder.vala', 'src/managers/headerManager.vala', 'src/managers/loadingStateManager.vala', 'src/managers/viewStateManager.vala', 'src/managers/layoutManager.vala', 'src/managers/articleManager.vala'],
  dependencies : [gtk, libsoup, json, gdkpixbuf, adw, xml2, gee, gio],
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

install_data('data/org.gnome.Paperboy.desktop', install_dir: join_paths(get_option('datadir'), 'applications'))

# Install app icons to system icon directories at different sizes
install_data('data/icons/128x128/paperboy.png', install_dir: join_paths(get_option('datadir'), 'icons', 'hicolor', '128x128', 'apps'))
install_data('data/icons/256x256/paperboy.png', install_dir: join_paths(get_option('datadir'), 'icons', 'hicolor', '256x256', 'apps'))
install_data('data/icons/512x512/paperboy.png', install_dir: join_paths(get_option('datadir'), 'icons', 'hicolor', '512x512', 'apps'))
install_data('data/icons/paperboy.png', install_dir: join_paths(get_option('datadir'), 'icons', 'hicolor', '1024x1024', 'apps'))

# Install app data (styles, icons) to a namespaced datadir for runtime lookup
install_data('data/style.css', install_dir: join_paths(get_option('datadir'), 'paperboy'))
install_subdir('data/icons', install_dir: join_paths(get_option('datadir'), 'paperboy'))
install_data('data/us_zips.csv', install_dir: join_paths(get_option('datadir'), 'paperboy'))
