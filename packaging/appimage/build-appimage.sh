#!/usr/bin/env bash
set -euo pipefail

# Usage: ./packaging/appimage/build-appimage.sh [AppImageBase] [--meson-version|-M]
# Examples:
#   ./packaging/appimage/build-appimage.sh                -> paperboy-<ver>-<arch>.AppImage (if meson version found)
#   ./packaging/appimage/build-appimage.sh paperboy       -> paperboy.AppImage
#   ./packaging/appimage/build-appimage.sh paperboy -M    -> paperboy-<ver>-<arch>.AppImage
# Default base name (when not provided) is `paperboy`.
APP_BASE_DEFAULT="paperboy"
USE_MESON_VERSION=0
APP_BASE=""

# Simple args parsing: accept one optional non-flag base name and a --meson-version / -M flag
for arg in "$@"; do
  case "$arg" in
    --meson-version|-M)
      USE_MESON_VERSION=1
      ;;
    --help|-h)
      echo "Usage: $0 [AppImageBase] [--meson-version|-M]" && exit 0
      ;;
    *)
      # First non-flag arg is treated as base name
      if [ -z "$APP_BASE" ]; then
        APP_BASE="$arg"
      fi
      ;;
  esac
done

# If no base supplied, use default
if [ -z "$APP_BASE" ]; then
  APP_BASE="$APP_BASE_DEFAULT"
fi



# If user passed a full filename (ending with .AppImage) as the single positional
# arg and did not request meson versioning, allow using that directly.
if [ "$#" -eq 1 ] && [ "$USE_MESON_VERSION" -eq 0 ] && [[ "$APP_BASE" == *.AppImage || "$APP_BASE" == *.appimage ]]; then
  APP="$APP_BASE"
else
  APP="${APP_BASE}.AppImage"
fi

# When run from packaging/appimage, repository root is two levels up
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APPDIR="$ROOT_DIR/AppDir"

# If the user requested meson-based versioning (or provided no explicit filename),
# try to read the project version from meson.build and use it to set a sensible
# output filename like `paperboy-<version>-<arch>.AppImage`.
if [ "$USE_MESON_VERSION" -eq 1 ] || ( [ "$#" -eq 0 ] && [ -z "$APP_BASE" ] ); then
  # Normalize host architecture for inclusion in the filename
  UNAME_M=$(uname -m)
  case "$UNAME_M" in
    x86_64|amd64) ARCH="x86_64" ;;
    aarch64|arm64) ARCH="aarch64" ;;
    armv7l) ARCH="armv7l" ;;
    i386|i686) ARCH="i386" ;;
    *) ARCH="$UNAME_M" ;;
  esac

  MESON_FILE="$ROOT_DIR/meson.build"
  if [ -f "$MESON_FILE" ]; then
    VERSION=$(sed -n "s/.*version *: *'\([^']*\)'.*/\1/p" "$MESON_FILE" | head -n1)
    if [ -n "$VERSION" ]; then
      APP="${APP_BASE}-${VERSION}-${ARCH}.AppImage"
    else
      APP="${APP_BASE}-${ARCH}.AppImage"
    fi
  else
    APP="${APP_BASE}-${ARCH}.AppImage"
  fi
fi

echo "Building AppDir at $APPDIR"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/512x512/apps" "$APPDIR/usr/share/icons/hicolor/256x256/apps" "$APPDIR/usr/share/icons/hicolor/128x128/apps" "$APPDIR/usr/share/icons/hicolor/scalable/apps"

# Create directory for shared data files
mkdir -p "$APPDIR/usr/share/paperboy"
mkdir -p "$APPDIR/usr/share/paperboy/icons"

# Copy the built binary
if [ ! -x "$BUILD_DIR/paperboy" ]; then
  echo "Error: built binary not found at $BUILD_DIR/paperboy"
  echo "Run: ninja -C build/"
  exit 1
fi
cp "$BUILD_DIR/paperboy" "$APPDIR/usr/bin/paperboy"
chmod +x "$APPDIR/usr/bin/paperboy"

# Copy helper binaries (rssFinder) - install in libexec per FHS 4.7
if [ -x "$BUILD_DIR/rssFinder" ]; then
  mkdir -p "$APPDIR/usr/libexec/paperboy"
  cp "$BUILD_DIR/rssFinder" "$APPDIR/usr/libexec/paperboy/rssFinder"
  chmod +x "$APPDIR/usr/libexec/paperboy/rssFinder"
else
  echo "Warning: rssFinder binary not found at $BUILD_DIR/rssFinder"
fi

# Attempt to locate html2rss built by Cargo in common build locations and copy
# it into the AppDir. Per FHS 4.7, internal binaries belong in libexecdir.
HTML2RSS_CANDIDATES=(
  "$BUILD_DIR/tools/html2rss/target/release/html2rss"
  "$BUILD_DIR/html2rss"
  "$ROOT_DIR/tools/html2rss/target/release/html2rss"
  "$ROOT_DIR/target/release/html2rss"
)
HTML2RSS_FOUND=""
for c in "${HTML2RSS_CANDIDATES[@]}"; do
  if [ -x "$c" ]; then
    HTML2RSS_FOUND="$c"
    break
  fi
done

if [ -n "$HTML2RSS_FOUND" ]; then
  mkdir -p "$APPDIR/usr/libexec/paperboy"
  cp "$HTML2RSS_FOUND" "$APPDIR/usr/libexec/paperboy/html2rss"
  chmod +x "$APPDIR/usr/libexec/paperboy/html2rss"
  echo "Copied html2rss into AppDir libexec from: $HTML2RSS_FOUND"
else
  echo "Warning: html2rss binary not found in expected build locations"
fi

# Copy adblock stylesheet into AppDir data dir so DataPaths finds it at runtime
if [ -f "$ROOT_DIR/data/resources/adblock.css" ]; then
  mkdir -p "$APPDIR/usr/share/paperboy/resources"
  cp "$ROOT_DIR/data/resources/adblock.css" "$APPDIR/usr/share/paperboy/resources/adblock.css"
else
  echo "Warning: data/resources/adblock.css not found in source tree"
fi

# Copy desktop file (use reverse-domain application id filename)
cp "$ROOT_DIR/data/io.github.thecalamityjoe87.Paperboy.desktop" "$APPDIR/usr/share/applications/io.github.thecalamityjoe87.Paperboy.desktop"
# Also copy the desktop file to the AppDir root (required by appimagetool)
cp "$ROOT_DIR/data/io.github.thecalamityjoe87.Paperboy.desktop" "$APPDIR/io.github.thecalamityjoe87.Paperboy.desktop"

# If we discovered a Meson project version, embed it in desktop and appdata
# so software centers / AppImage tools can show the real version instead of a hash.
if [ -n "${VERSION-}" ]; then
  DESKTOP_ID="io.github.thecalamityjoe87.Paperboy"
  TOP_DESKTOP="${APPDIR}/${DESKTOP_ID}.desktop"
  APP_DESKTOP="${APPDIR}/usr/share/applications/${DESKTOP_ID}.desktop"

  for d in "$TOP_DESKTOP" "$APP_DESKTOP"; do
    if [ -f "$d" ]; then
      if grep -q '^X-AppImage-Version=' "$d"; then
        sed -i "s/^X-AppImage-Version=.*/X-AppImage-Version=${VERSION}/" "$d"
      else
        printf "\nX-AppImage-Version=%s\n" "$VERSION" >> "$d"
      fi
    fi
  done

  # Create AppStream appdata so GNOME Software / centers show the version
  METAFILE="$APPDIR/usr/share/metainfo/${DESKTOP_ID}.appdata.xml"
  mkdir -p "$(dirname "$METAFILE")"
  cat > "$METAFILE" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<component type="desktop">
  <id>${DESKTOP_ID}</id>
  <metadata_license>CC0-1.0</metadata_license>
  <name>Paperboy</name>
  <summary>Simple news and RSS reader</summary>
  <description>
    <p>Paperboy is a simple news app written in Vala built with GTK4 and Libadwaita.</p>
  </description>
  <url type="homepage">https://github.com/thecalamityjoe87/paperboy</url>
  <launchable type="desktop-id">io.github.thecalamityjoe87.Paperboy.desktop</launchable>
  <project_license>GPL-3.0-or-later</project_license>
  <developer_name>Isaac Joseph</developer_name>
  <releases>
    <release version="${VERSION}" date="$(date -I)">
    </release>
  </releases>
</component>
EOF
fi

# Copy GSettings schema (prefer new data/resources/ location)
SCHEMA_SRC="$ROOT_DIR/data/resources/io.github.thecalamityjoe87.Paperboy.gschema.xml"
if [ -f "$SCHEMA_SRC" ]; then
  mkdir -p "$APPDIR/usr/share/glib-2.0/schemas"
  cp "$SCHEMA_SRC" "$APPDIR/usr/share/glib-2.0/schemas/"
elif [ -f "$ROOT_DIR/data/io.github.thecalamityjoe87.Paperboy.gschema.xml" ]; then
  mkdir -p "$APPDIR/usr/share/glib-2.0/schemas"
  cp "$ROOT_DIR/data/io.github.thecalamityjoe87.Paperboy.gschema.xml" "$APPDIR/usr/share/glib-2.0/schemas/"
else
  echo "Warning: GSettings schema not found in data/resources or data"
fi

# Compile schemas inside AppDir so the runtime can find them
if command -v glib-compile-schemas >/dev/null 2>&1; then
  glib-compile-schemas "$APPDIR/usr/share/glib-2.0/schemas"
else
  echo "Warning: glib-compile-schemas not found; compiled schemas may be missing in AppDir"
fi

# Copy icons (fall back if not present)
ICON_SRC_DIR="$ROOT_DIR/data/icons"
if [ -d "$ICON_SRC_DIR" ]; then
  cp "$ICON_SRC_DIR/512x512/paperboy.png" "$APPDIR/usr/share/icons/hicolor/512x512/apps/paperboy.png" 2>/dev/null || true
  cp "$ICON_SRC_DIR/256x256/paperboy.png" "$APPDIR/usr/share/icons/hicolor/256x256/apps/paperboy.png" 2>/dev/null || true
  cp "$ICON_SRC_DIR/128x128/paperboy.png" "$APPDIR/usr/share/icons/hicolor/128x128/apps/paperboy.png" 2>/dev/null || true
  # symbolic/scalable if exists
  if [ -f "$ICON_SRC_DIR/symbolic/paperboy.svg" ]; then
    mkdir -p "$APPDIR/usr/share/icons/hicolor/scalable/apps"
    cp "$ICON_SRC_DIR/symbolic/paperboy.svg" "$APPDIR/usr/share/icons/hicolor/scalable/apps/paperboy.svg"
  fi
  # Copy all top-level PNG icons into the app's data icons directory
  for f in "$ICON_SRC_DIR"/*.png; do
    [ -f "$f" ] || continue
    cp "$f" "$APPDIR/usr/share/paperboy/icons/"
  done
  # Copy any icons inside size directories as well
  for size in 128x128 256x256 512x512; do
    if [ -d "$ICON_SRC_DIR/$size" ]; then
      for f in "$ICON_SRC_DIR/$size"/*.png; do
        [ -f "$f" ] || continue
        cp "$f" "$APPDIR/usr/share/paperboy/icons/"
      done
    fi
  done
  # Copy symbolic directory recursively
  if [ -d "$ICON_SRC_DIR/symbolic" ]; then
    mkdir -p "$APPDIR/usr/share/paperboy/icons/symbolic"
    cp -r "$ICON_SRC_DIR/symbolic/"* "$APPDIR/usr/share/paperboy/icons/symbolic/" 2>/dev/null || true
  fi
  # Copy scalable SVG icons if present (e.g. data/icons/scalable)
  if [ -f "$ICON_SRC_DIR/scalable/paperboy.svg" ]; then
    mkdir -p "$APPDIR/usr/share/icons/hicolor/scalable/apps"
    cp "$ICON_SRC_DIR/scalable/paperboy.svg" "$APPDIR/usr/share/icons/hicolor/scalable/apps/paperboy.svg" 2>/dev/null || true
  fi
else
  echo "Warning: icons not found in $ICON_SRC_DIR"
fi

# Copy additional data files required at runtime
# Prefer the new `data/resources` location, fall back to the legacy `data` dir.
if [ -f "$ROOT_DIR/data/resources/style.css" ]; then
  cp "$ROOT_DIR/data/resources/style.css" "$APPDIR/usr/share/paperboy/style.css"
elif [ -f "$ROOT_DIR/data/style.css" ]; then
  cp "$ROOT_DIR/data/style.css" "$APPDIR/usr/share/paperboy/style.css"
else
  echo "Warning: style.css not found in $ROOT_DIR/data or $ROOT_DIR/data/resources"
fi

if [ -f "$ROOT_DIR/data/usZips.csv" ]; then
  cp "$ROOT_DIR/data/usZips.csv" "$APPDIR/usr/share/paperboy/usZips.csv"
else
  echo "Warning: usZips.csv not found in $ROOT_DIR/data"
fi

# Write AppRun
cat > "$APPDIR/AppRun" <<'APP_RUN'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(dirname "$(readlink -f "${0}")")"
# Ensure application can find its data files inside the AppDir
export XDG_DATA_DIRS="$HERE/usr/share:${XDG_DATA_DIRS:-}"
# Point GSettings to the bundled schema directory so preferences can be saved/loaded
export GSETTINGS_SCHEMA_DIR="$HERE/usr/share/glib-2.0/schemas:${GSETTINGS_SCHEMA_DIR:-}"
# Let the runtime know where internal helper binaries live inside the AppDir
export PAPERBOY_LIBEXECDIR="$HERE/usr/libexec"
# Prepend bundled fallback libs so libxml2.so.16 from the AppDir is preferred.
# Keep $HERE/usr/lib in the search path for other bundled libs if present.
# Use a safe expansion under `set -u` so referencing an unset LD_LIBRARY_PATH
# doesn't trigger an unbound variable error inside the AppImage runtime.
if [ -n "${LD_LIBRARY_PATH-}" ]; then
  export LD_LIBRARY_PATH="$HERE/opt/fallback-libs:$LD_LIBRARY_PATH:$HERE/usr/lib"
else
  export LD_LIBRARY_PATH="$HERE/opt/fallback-libs:$HERE/usr/lib"
fi
exec "$HERE/usr/bin/paperboy" "$@"
APP_RUN
chmod +x "$APPDIR/AppRun"

# Bundle libxml2.so.16 into AppDir/opt/fallback-libs.
# Prefer a .deb shipped under packaging/appimage/; if none exists, try to
# download the known upstream .deb from the official Ubuntu archive URL.
DEB_CANDIDATE="$(ls "$ROOT_DIR/packaging/appimage"/*.deb 2>/dev/null | head -n1 || true)"
if [ -z "$DEB_CANDIDATE" ]; then
  echo "No .deb found in packaging/appimage/; attempting to download libxml2 .deb from upstream archive..."
  TMPDIR="$(mktemp -d)"
  # Official upstream package (frozen to the version this project previously bundled)
  LIBXML_DEB_URL="https://archive.ubuntu.com/ubuntu/pool/main/libx/libxml2/libxml2-16_2.14.5+dfsg-0.2_amd64.deb"
  if curl -L -f -o "$TMPDIR/libxml2.deb" "$LIBXML_DEB_URL"; then
    DEB_CANDIDATE="$TMPDIR/libxml2.deb"
    echo "Downloaded $DEB_CANDIDATE"
  else
    echo "Warning: failed to download libxml2 .deb from $LIBXML_DEB_URL; not bundling libxml2." >&2
    rm -rf "$TMPDIR"
    DEB_CANDIDATE=""
  fi
fi

if [ -n "$DEB_CANDIDATE" ]; then
  echo "Found .deb for libxml2: $DEB_CANDIDATE — extracting libxml2.so.16 into AppDir..."
  # If TMPDIR wasn't set by the download branch, create one for extraction
  TMPDIR="${TMPDIR:-$(mktemp -d)}"
  if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb -x "$DEB_CANDIDATE" "$TMPDIR"
  else
    (cd "$TMPDIR" && ar x "$DEB_CANDIDATE")
    # extract data.tar.* if present
    for t in "$TMPDIR"/data.tar.*; do
      [ -f "$t" ] || continue
      case "$t" in
        *.gz) tar xzf "$t" -C "$TMPDIR" ;;
        *.xz) tar xJf "$t" -C "$TMPDIR" ;;
        *.zst) tar --use-compress-program=unzstd -xf "$t" -C "$TMPDIR" ;;
        *) tar xf "$t" -C "$TMPDIR" ;;
      esac
      break
    done
  fi
  # Find libxml2.so.16 in extracted tree
  LIBXML="$(find "$TMPDIR" -type f -name 'libxml2.so.16*' | head -n1 || true)"
  if [ -n "$LIBXML" ]; then
    mkdir -p "$APPDIR/opt/fallback-libs"
    cp -a "$LIBXML" "$APPDIR/opt/fallback-libs/"
    BASENAME="$(basename "$LIBXML")"
    (cd "$APPDIR/opt/fallback-libs" && ln -sf "$BASENAME" libxml2.so.16) || true
    echo "Bundled $BASENAME and created libxml2.so.16 symlink in AppDir/opt/fallback-libs"
  else
    echo "Warning: libxml2.so.16 not found inside $DEB_CANDIDATE; not bundling libxml2." >&2
  fi
  rm -rf "$TMPDIR"
fi

# Create optional .DirIcon and desktop file copy to top-level AppDir
if [ -f "$APPDIR/usr/share/icons/hicolor/256x256/apps/paperboy.png" ]; then
  cp "$APPDIR/usr/share/icons/hicolor/256x256/apps/paperboy.png" "$APPDIR/.DirIcon"
  # Also provide top-level icon files expected by appimagetool
  cp "$APPDIR/usr/share/icons/hicolor/256x256/apps/paperboy.png" "$APPDIR/paperboy.png" 2>/dev/null || true
fi
if [ -f "$APPDIR/usr/share/icons/hicolor/scalable/apps/paperboy.svg" ]; then
  cp "$APPDIR/usr/share/icons/hicolor/scalable/apps/paperboy.svg" "$APPDIR/paperboy.svg" 2>/dev/null || true
fi

# Build AppImage: robustly locate an appimagetool executable (accept names
# like 'appimagetool', 'appimagetool-ARCH' or 'appimagetool-ARCH.AppImage')
# and run it.
APPIMAGETOOL_BIN=""
if command -v appimagetool >/dev/null 2>&1; then
  APPIMAGETOOL_BIN="$(command -v appimagetool)"
else
  # Search PATH for any executable whose basename contains 'appimagetool'
  IFS=':' read -ra _pdirs <<< "$PATH"
  for _d in "${_pdirs[@]}"; do
    [ -d "$_d" ] || continue
    for _cand in "$_d"/*; do
      [ -x "$_cand" ] || continue
      _base="$(basename "$_cand")"
      case "$_base" in
        *appimagetool*) APPIMAGETOOL_BIN="$_cand"; break 2 ;;
      esac
    done
  done
  unset IFS
fi

if [ -n "$APPIMAGETOOL_BIN" ]; then
  echo "Running $APPIMAGETOOL_BIN to create $APP"
  "$APPIMAGETOOL_BIN" "$APPDIR" "$APP"
  # Ensure produced artifact has the normalized name. Some appimagetool
  # variants may produce filenames that include architecture or different
  # casing; find the most-recent matching artifact and rename it to $APP.
  if [ -f "$APP" ]; then
    echo "Created $APP"
  else
    CREATED="$(ls -t paperboy*.AppImage paperboy*.appimage 2>/dev/null | head -n1 || true)"
    if [ -n "$CREATED" ]; then
      if [ "$CREATED" != "$APP" ]; then
        mv -f "$CREATED" "$APP"
        echo "Renamed $CREATED -> $APP"
      else
        echo "Created $APP"
      fi
    else
      echo "Warning: appimagetool reported success but no AppImage found" >&2
    fi
  fi
else
  echo "appimagetool not found. To produce an AppImage, download appimagetool and run:" 
  echo "  appimagetool $APPDIR $APP"
  echo "See: https://github.com/AppImage/AppImageKit/releases"
fi

echo "Done"
