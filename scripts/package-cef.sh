#!/bin/sh
# Xcode build phase: copy the CEF framework into Bow.app and create Chromium's helper apps.
# Chromium starts each helper by name ("Bow Helper (GPU)" and so on), so each needs its own bundle.
set -eu

app="$TARGET_BUILD_DIR/$WRAPPER_NAME"
frameworks="$app/Contents/Frameworks"
framework_src="$SRCROOT/Vendor/cef/Release/Chromium Embedded Framework.framework"
helper_src="$BUILT_PRODUCTS_DIR/Bow Helper.app"
helper_id="dev.bowbrowser.Bow.helper"

# CEF ships a flat framework; Xcode's validation and macOS signing expect the versioned layout
# (Versions/A plus symlinks), which is also how Chrome ships its framework.
framework="$frameworks/Chromium Embedded Framework.framework"
mkdir -p "$frameworks"
rm -rf "$framework"
mkdir -p "$framework/Versions/A"
for item in "Chromium Embedded Framework" Libraries Resources; do
  cp -R "$framework_src/$item" "$framework/Versions/A/"
done
ln -s A "$framework/Versions/Current"
for item in "Chromium Embedded Framework" Libraries Resources; do
  ln -s "Versions/Current/$item" "$framework/$item"
done
codesign --force --sign - "$framework"

for kind in "" GPU Renderer Plugin Alerts; do
  if [ -z "$kind" ]; then name="Bow Helper"; id="$helper_id"
  else name="Bow Helper ($kind)"; id="$helper_id.$(echo "$kind" | tr '[:upper:]' '[:lower:]')"; fi

  dst="$frameworks/$name.app"
  rm -rf "$dst"
  cp -R "$helper_src" "$dst"
  if [ "$name" != "Bow Helper" ]; then
    mv "$dst/Contents/MacOS/Bow Helper" "$dst/Contents/MacOS/$name"
  fi
  plist="$dst/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $name" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $name" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $id" "$plist"
  codesign --force --sign - "$dst"
done
