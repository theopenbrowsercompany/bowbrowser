#!/bin/sh
# Xcode build phase: copies the license files into Bow.app/Contents/Resources, for Debug and Release.
#   CEF-LICENSE.txt       CEF's BSD license (Vendor/cef/LICENSE.txt)
#   Chromium-Credits.html Chromium's third party credits (Vendor/cef/CREDITS.html)
#   Bow-LICENSE.txt       Bow's own license (LICENSE)
#   OFL-NunitoSans.txt, OFL-Fredoka.txt  the bundled fonts' SIL Open Font Licenses (App/Fonts)
# Fails clearly when a source is missing. App/UI/Licenses.swift and scripts/check-release.sh name the same files.
set -eu

root="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
dest="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"

copy() {
  if [ ! -f "$1" ]; then
    echo "error: bundle-licenses: missing $1 (run make bootstrap)" >&2
    exit 1
  fi
  mkdir -p "$dest"
  cmp -s "$1" "$dest/$2" || cp -f "$1" "$dest/$2"
}

copy "$root/Vendor/cef/LICENSE.txt" CEF-LICENSE.txt
copy "$root/Vendor/cef/CREDITS.html" Chromium-Credits.html
copy "$root/LICENSE" Bow-LICENSE.txt
copy "$root/App/Fonts/OFL-NunitoSans.txt" OFL-NunitoSans.txt
copy "$root/App/Fonts/OFL-Fredoka.txt" OFL-Fredoka.txt
