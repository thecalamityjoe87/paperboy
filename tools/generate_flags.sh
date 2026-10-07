#!/bin/bash
# Regenerates the national-news flag icons in data/icons/symbolic/flags/
# from lipis/flag-icons (MIT), one per country with a Google News edition
# listed in src/utils/net/googleNewsUtils.vala.
#
# Needs valac (with gdk-pixbuf-2.0), python3 and Pillow, and network access.
#
# usage: tools/generate_flags.sh [OUT_DIR]
#   OUT_DIR defaults to data/icons/symbolic/flags. Downloads and
#   intermediate files go in a temp dir (or $WORK_DIR if set).
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1  # keep __pycache__ out of tools/

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
out=$(realpath -m "${1:-$root/data/icons/symbolic/flags}")
work=${WORK_DIR:-$(mktemp -d)}
mkdir -p "$out" "$work"

codes=$(grep -oE '"[A-Z]{2}:' "$root/src/utils/net/googleNewsUtils.vala" \
    | tr -d '":' | tr 'A-Z' 'a-z' | sort -u)

valac -q --pkg gdk-pixbuf-2.0 "$here/render_svg.vala" -o "$work/render_svg"

cd "$work"
python3 "$here/flag_levels.py" "$work/render_svg" $codes
python3 "$here/make_mono_flags.py" "$out" $codes > /dev/null
echo "wrote $(ls "$out"/flag-*.svg | wc -l) icons to $out"
