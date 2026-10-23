#!/bin/sh
# Xcode build phase: copy the CEF framework into Bow.app and create Chromium's helper apps.
# Chromium starts each helper by name ("Bow Helper (GPU)" and so on), so each needs its own bundle.
#
# Copying the 327 MB framework and signing it and five helpers takes about two seconds, so the phase skips all of
# it when nothing changed: a stamp in the target's temporary folder records the CEF build (its binary, Libraries and
# Resources), every file of the built helper, this script and the copies it made, and the work runs again when any
# of them differs.
set -eu

app="$TARGET_BUILD_DIR/$WRAPPER_NAME"
frameworks="$app/Contents/Frameworks"
framework_src="$SRCROOT/Vendor/cef/Release/Chromium Embedded Framework.framework"
helper_src="$BUILT_PRODUCTS_DIR/Bow Helper.app"
helper_id="dev.bowbrowser.Bow.helper"
framework="$frameworks/Chromium Embedded Framework.framework"
stamp_file="$TARGET_TEMP_DIR/package-cef.stamp"

helper_name() { if [ -z "$1" ]; then echo "Bow Helper"; else echo "Bow Helper ($1)"; fi; }

# What the copies are made from (the CEF build's real folder and binary, the built helper, this script), then the
# copies themselves, so a deleted or rebuilt app bundle is packaged again.
stamp() {
  (cd "$framework_src" && pwd -P)
  stat -f '%N %m %c %z %i' "$framework_src/Chromium Embedded Framework"
  # The framework's Libraries and Resources (about 230 files), by metadata, so a stat each is cheap.
  # find -L and stat -L follow symlinks, so a link whose target changes still changes the stamp.
  find -L "$framework_src/Libraries" "$framework_src/Resources" -type f -print0 | sort -z | xargs -0 stat -L -f '%N %m %c %z %i'
  find "$helper_src" -type f -print0 | sort -z | xargs -0 shasum
  shasum "$0"
  stat -f '%N %m %c %z %i' "$framework/Versions/A/Chromium Embedded Framework"
  find -L "$framework/Versions/A/Libraries" "$framework/Versions/A/Resources" -type f -print0 | sort -z |
    xargs -0 stat -L -f '%N %m %c %z %i'
  for kind in "" GPU Renderer Plugin Alerts; do
    name=$(helper_name "$kind")
    stat -f '%N %m %c %z %i' "$frameworks/$name.app/Contents/MacOS/$name" \
      "$frameworks/$name.app/Contents/_CodeSignature/CodeResources"
  done
}

if [ -f "$stamp_file" ] && current=$(stamp 2>/dev/null) && [ "$current" = "$(cat "$stamp_file")" ]; then
  echo "package-cef: the CEF framework and helpers are unchanged; skipping the copy and signing"
  exit 0
fi
rm -f "$stamp_file"

# Copies $1 to the path $2 with APFS clones when the volume allows it, which is near instant; a plain copy otherwise
# (after removing whatever a failed clone left there).
copy() { cp -cR "$1" "$2" 2>/dev/null || { rm -rf "$2" && cp -R "$1" "$2"; }; }

# CEF ships a flat framework; Xcode's validation and macOS signing expect the versioned layout
# (Versions/A plus symlinks), which is also how Chrome ships its framework.
mkdir -p "$frameworks"
rm -rf "$framework"
mkdir -p "$framework/Versions/A"
for item in "Chromium Embedded Framework" Libraries Resources; do
  copy "$framework_src/$item" "$framework/Versions/A/$item"
done
ln -s A "$framework/Versions/Current"
for item in "Chromium Embedded Framework" Libraries Resources; do
  ln -s "Versions/Current/$item" "$framework/$item"
done
codesign --force --sign - "$framework"

for kind in "" GPU Renderer Plugin Alerts; do
  name=$(helper_name "$kind")
  if [ -z "$kind" ]; then id="$helper_id"
  else id="$helper_id.$(echo "$kind" | tr '[:upper:]' '[:lower:]')"; fi

  dst="$frameworks/$name.app"
  rm -rf "$dst"
  copy "$helper_src" "$dst"
  if [ "$name" != "Bow Helper" ]; then
    mv "$dst/Contents/MacOS/Bow Helper" "$dst/Contents/MacOS/$name"
  fi
  plist="$dst/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $name" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $name" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $id" "$plist"
  codesign --force --sign - "$dst"
done

mkdir -p "$TARGET_TEMP_DIR"
stamp > "$stamp_file"
