#!/usr/bin/env bash
set -euo pipefail

# Usage: ./packaging/appimage/build-appimage.sh [AppImageName]
APP=image.Paperboy.AppImage
if [ "$#" -gt 0 ]; then
  APP="$1"
fi

# When run from packaging/appimage, repository root is two levels up
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APPDIR="$ROOT_DIR/AppDir"

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

# Copy helper binaries (rssFinder)
if [ -x "$BUILD_DIR/rssFinder" ]; then
  cp "$BUILD_DIR/rssFinder" "$APPDIR/usr/bin/rssFinder"
  chmod +x "$APPDIR/usr/bin/rssFinder"
else
  echo "Warning: rssFinder binary not found at $BUILD_DIR/rssFinder"
fi

# Copy desktop file (use reverse-domain application id filename)
cp "$ROOT_DIR/data/io.github.thecalamityjoe87.Paperboy.desktop" "$APPDIR/usr/share/applications/io.github.thecalamityjoe87.Paperboy.desktop"
# Also copy the desktop file to the AppDir root (required by appimagetool)
cp "$ROOT_DIR/data/io.github.thecalamityjoe87.Paperboy.desktop" "$APPDIR/io.github.thecalamityjoe87.Paperboy.desktop"

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
if [ -f "$ROOT_DIR/data/style.css" ]; then
  cp "$ROOT_DIR/data/style.css" "$APPDIR/usr/share/paperboy/style.css"
else
  echo "Warning: style.css not found in $ROOT_DIR/data"
fi

if [ -f "$ROOT_DIR/data/usZips.csv" ]; then
  cp "$ROOT_DIR/data/usZips.csv" "$APPDIR/usr/share/paperboy/usZips.csv"
else
  echo "Warning: usZips.csv not found in $ROOT_DIR/data"
fi

# Write AppRun
cat > "$APPDIR/AppRun" <<'APP_RUN'
#!/usr/bin/env bash
HERE="$(dirname "$(readlink -f "${0}")")"
# Ensure application can find its data files inside the AppDir
export XDG_DATA_DIRS="$HERE/usr/share:${XDG_DATA_DIRS:-}"
# Ensure bundled libraries are preferred
export LD_LIBRARY_PATH="$HERE/usr/lib:${LD_LIBRARY_PATH:-}"
exec "$HERE/usr/bin/paperboy" "$@"
APP_RUN
chmod +x "$APPDIR/AppRun"

# Create optional .DirIcon and desktop file copy to top-level AppDir
if [ -f "$APPDIR/usr/share/icons/hicolor/256x256/apps/paperboy.png" ]; then
  cp "$APPDIR/usr/share/icons/hicolor/256x256/apps/paperboy.png" "$APPDIR/.DirIcon"
  # Also provide top-level icon files expected by appimagetool
  cp "$APPDIR/usr/share/icons/hicolor/256x256/apps/paperboy.png" "$APPDIR/paperboy.png" 2>/dev/null || true
fi
if [ -f "$APPDIR/usr/share/icons/hicolor/scalable/apps/paperboy.svg" ]; then
  cp "$APPDIR/usr/share/icons/hicolor/scalable/apps/paperboy.svg" "$APPDIR/paperboy.svg" 2>/dev/null || true
fi

# Build AppImage if appimagetool is available
if command -v appimagetool >/dev/null 2>&1; then
  echo "Running appimagetool to create $APP"
  appimagetool "$APPDIR" "$APP"
  echo "Created $APP"
else
  echo "appimagetool not found. To produce an AppImage, download appimagetool and run:" 
  echo "  appimagetool $APPDIR $APP"
  echo "See: https://github.com/AppImage/AppImageKit/releases"
fi

echo "Done"
