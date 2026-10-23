#!/bin/sh
# Builds Release and fails if the app carries any of the e2e harness: a symbol for something E2E/ declares
# (scripts/e2e-names.sh --symbols) or the Fixtures folder. A successful build also proves the Release side of
# every "E2E seam" (such as the AppDelegate #else branch) compiles.
set -eu

cd "$(dirname "$0")/.."

# Use the full Xcode even when the command line tools are the system default, as the Makefile does.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

derived=build/release
app="$derived/Build/Products/Release/Bow.app"
binary="$app/Contents/MacOS/Bow"

xcodebuild -project Bow.xcodeproj -scheme Bow -configuration Release -derivedDataPath "$derived" -quiet build

if [ ! -f "$binary" ]; then
  echo "Release build produced no $binary" >&2
  exit 1
fi
# Every binary in Contents/MacOS (a Debug-style build would put the code in Bow.debug.dylib); nm failing fails.
symbols=$(for file in "$app"/Contents/MacOS/*; do nm "$file"; done)

failed=no
if [ -e "$app/Contents/Resources/Fixtures" ]; then
  echo "Release app contains e2e fixtures: $app/Contents/Resources/Fixtures" >&2
  failed=yes
fi

# Match whole names only: Swift and C++ mangle a name as <length><name>, and Objective-C classes and C symbols
# end in _<name>. So WebViewPage would not match WebViewPageController.
pattern=$(./scripts/e2e-names.sh --symbols | while read -r name; do
  printf '%s|' "(^|[^0-9])${#name}${name}" "_${name}\$"
done)
found=$(echo "$symbols" | grep -E "${pattern%|}" || true)
if [ -n "$found" ]; then
  echo "Release app contains e2e harness symbols:" >&2
  echo "$found" >&2
  failed=yes
fi

[ "$failed" = no ] || exit 1
echo "release: no e2e harness in $app"
