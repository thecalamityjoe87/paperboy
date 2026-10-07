# Unit tests: each links paperboy-core (all app code except main()) and
# runs under GLib.Test. Keep them offline - feed parsers fixture files,
# never the network. Run with: meson test -C build
test_names = [
  'textUtils',
  'imageCache',
  'rssFeedProcessor',
]

# Some code under test writes caches/databases under the XDG dirs; point
# them (and HOME) at a scratch dir in the build tree so tests never touch
# the real profile.
test_home = meson.current_build_dir() / 'home'
test_env = environment({
  'G_DEBUG': 'fatal-criticals',
  'GSETTINGS_BACKEND': 'memory',
  'HOME': test_home,
  'XDG_CACHE_HOME': test_home / 'cache',
  'XDG_CONFIG_HOME': test_home / 'config',
  'XDG_DATA_HOME': test_home / 'data',
  'PAPERBOY_ENABLE_BBC_EXTRACT': '0',
  'PAPERBOY_TEST_FIXTURES': meson.current_source_dir() / 'fixtures',
})

foreach name : test_names
  exe = executable('test-' + name, name + 'Test.vala',
    dependencies : paperboy_core_dep,
  )
  test(name, exe, protocol : 'tap', args : ['--tap', '-k'], env : test_env)
endforeach
