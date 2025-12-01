#!/usr/bin/env bash
set -euo pipefail

# Build an AppImage that prefers the system libxml2.so.16 and falls back
# to a bundled libxml2.so.2 only when the system library is missing.
#
# Usage:
#   ./build-appimage-fallback.sh [--fallback /path/to/libxml2.so.2] [--build-dir build] [--appimagetool /path/to/appimagetool]
#
# Default behavior expects:
# - You build (or let this script build) the project with Meson/Ninja into `build/`.
# - A fallback lib at `packaging/appimage/fallback-libs/libxml2.so.2` (or pass `--fallback`).
# - `packaging/appimage/AppDirTemplate` contains the AppDir layout (this repo already has it).

SCRIPT_DIR="$(dirname "$(readlink -f "${0}")")"
REPO_ROOT="$(readlink -f "$SCRIPT_DIR/../..")"

BUILD_DIR="build"
APPIMAGETOOL="appimagetool"
FALLBACK_SRC="$REPO_ROOT/packaging/appimage/fallback-libs/libxml2.so.2"
OUT_DIR="$REPO_ROOT/build/appimage"
APPDIR_DEST="$OUT_DIR/Paperboy.AppDir"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fallback) FALLBACK_SRC="$2"; shift 2 ;;
    --build-dir) BUILD_DIR="$2"; shift 2 ;;
    --appimagetool) APPIMAGETOOL="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --help) sed -n '1,120p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

mkdir -p "$OUT_DIR"
rm -rf "$APPDIR_DEST"
cp -a "$REPO_ROOT/packaging/appimage/AppDirTemplate" "$APPDIR_DEST"

# Build the project (meson + ninja) if the build dir doesn't exist or is empty
if [ ! -d "$BUILD_DIR" ] || [ -z "$(ls -A "$BUILD_DIR" 2>/dev/null || true)" ]; then
  echo "Running meson and ninja to build the project into '$BUILD_DIR'..."
  meson setup "$BUILD_DIR" || meson configure "$BUILD_DIR"
  ninja -C "$BUILD_DIR"
else
  echo "Using existing build directory '$BUILD_DIR' (run 'ninja -C $BUILD_DIR' to rebuild)."
fi

# Find the built 'paperboy' and 'rssFinder' executables
find_exe() {
  name="$1"
  find "$BUILD_DIR" -type f -name "$name" -perm /u+x,g+x,o+x -print -quit 2>/dev/null || true
}

PAPERBOY_EXE="$(find_exe paperboy)"
RSSFINDER_EXE="$(find_exe rssFinder)"

if [ -z "$PAPERBOY_EXE" ]; then
  echo "Could not find built 'paperboy' executable in '$BUILD_DIR'. Build failed or binary has a different name."
  exit 1
fi

mkdir -p "$APPDIR_DEST/usr/bin"
cp -a "$PAPERBOY_EXE" "$APPDIR_DEST/usr/bin/paperboy"
chmod +x "$APPDIR_DEST/usr/bin/paperboy"

if [ -n "$RSSFINDER_EXE" ]; then
  cp -a "$RSSFINDER_EXE" "$APPDIR_DEST/usr/bin/rssFinder"
  chmod +x "$APPDIR_DEST/usr/bin/rssFinder"
  echo "Included rssFinder in AppDir/usr/bin"
else
  echo "Warning: 'rssFinder' not found in build dir; skipping inclusion." >&2
fi

## Place the fallback lib into $APPDIR/opt/fallback-libs/libxml2.so.2
copy_fallback() {
  mkdir -p "$APPDIR_DEST/opt/fallback-libs"
  cp -a "$1" "$APPDIR_DEST/opt/fallback-libs/"
  echo "Copied fallback lib to $APPDIR_DEST/opt/fallback-libs/"
}

if [ -f "$FALLBACK_SRC" ]; then
  copy_fallback "$FALLBACK_SRC"
else
  # Try to find a .deb in packaging/appimage/ and extract libxml2.so.2 from it
  FOUND_DEB="$(ls "$REPO_ROOT/packaging/appimage"/*.deb 2>/dev/null | head -n1 || true)"
  if [ -n "$FOUND_DEB" ]; then
    echo "Found .deb in packaging/appimage: $FOUND_DEB — attempting to extract libxml2.so.2..."
    TMPDIR="$(mktemp -d)"
    if command -v dpkg-deb >/dev/null 2>&1; then
      dpkg-deb -x "$FOUND_DEB" "$TMPDIR"
    else
      # Try ar + tar fallback (deb is ar archive with data.tar.* inside)
      pushd "$TMPDIR" >/dev/null
      ar x "$FOUND_DEB"
      # Extract data.tar.* (could be gz, xz, or zst)
      for f in data.tar.*; do
        if [ -f "$f" ]; then
          case "$f" in
            *.gz) tar xzf "$f" ;;
            *.xz) tar xJf "$f" ;;
            *.zst) tar --use-compress-program=unzstd -xf "$f" ;;
            *) tar xf "$f" ;;
          esac
          break
        fi
      done
      popd >/dev/null
    fi

    # Look for libxml2*.so files inside the extracted tree
    CANDIDATE="$(find "$TMPDIR" -type f -name 'libxml2.so*' | grep '/libxml2.so\.2\>' || true)"
    if [ -n "$CANDIDATE" ]; then
      copy_fallback "$CANDIDATE"
    else
      # If exact soname not found, try any libxml2.so.* and pick the oldest (libxml2.so.2 likely)
      ANY="$(find "$TMPDIR" -type f -name 'libxml2.so.*' | head -n1 || true)"
      if [ -n "$ANY" ]; then
        copy_fallback "$ANY"
      else
        echo "Warning: could not find libxml2.so.2 inside $FOUND_DEB" >&2
      fi
    fi
    rm -rf "$TMPDIR"
  else
    echo "Warning: fallback lib not found at '$FALLBACK_SRC' and no .deb present in packaging/appimage/. The AppImage will still prefer system libxml2; older distros may fail without the fallback." >&2
  fi
fi

# Ensure AppRun is executable
chmod +x "$APPDIR_DEST/AppRun"

# Build the AppImage
if ! command -v "$APPIMAGETOOL" >/dev/null 2>&1; then
  echo "Error: appimagetool not found at '$APPIMAGETOOL'. Install appimagetool or pass --appimagetool /path/to/appimagetool" >&2
  exit 1
fi

echo "Creating AppImage from AppDir at '$APPDIR_DEST'..."
pushd "$OUT_DIR" >/dev/null
"$APPIMAGETOOL" "$APPDIR_DEST" || { popd >/dev/null; echo "appimagetool failed"; exit 1; }
popd >/dev/null

echo "AppImage build complete. Look in $OUT_DIR for the .AppImage file."
