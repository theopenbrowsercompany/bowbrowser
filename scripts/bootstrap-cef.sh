#!/bin/sh
# Make the pinned CEF build available at Vendor/cef.
# CEF lives once in a shared cache outside the repository, so every checkout and worktree links to the
# same download and wrapper build instead of fetching 378 MB again. Override the cache with BOW_CEF_CACHE.
set -eu
cd "$(dirname "$0")/.."
. ./cef.lock

name="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}_${CEF_DIST}"
cache="${BOW_CEF_CACHE:-$HOME/Library/Caches/bowbrowser}"
dir="$cache/$name"
archive="$cache/downloads/$name.tar.bz2"

if [ ! -f "$dir/.ready" ]; then
  mkdir -p "$cache/downloads"

  # Reuse a download left in this checkout by the earlier per-checkout layout.
  if [ ! -f "$archive" ] && [ -f "Vendor/downloads/$name.tar.bz2" ]; then
    mv "Vendor/downloads/$name.tar.bz2" "$archive"
  fi
  if [ ! -f "$archive" ]; then
    url="https://cef-builds.spotifycdn.com/$(printf '%s' "$name" | sed 's/+/%2B/g').tar.bz2"
    echo "Downloading $url"
    curl -fL --progress-bar -o "$archive.part" "$url"
    mv "$archive.part" "$archive"
  fi
  echo "$CEF_SHA1  $archive" | shasum -a 1 -c -

  rm -rf "$dir"
  mkdir -p "$dir"
  tar -xjf "$archive" -C "$dir" --strip-components 1
  cmake -S "$dir" -B "$dir/build" -DCMAKE_BUILD_TYPE=Release -DPROJECT_ARCH=arm64
  cmake --build "$dir/build" --target libcef_dll_wrapper -j "$(sysctl -n hw.ncpu)"
  touch "$dir/.ready"
fi

mkdir -p Vendor
if [ -d Vendor/cef ] && [ ! -L Vendor/cef ]; then
  rm -rf Vendor/cef
fi
ln -sfn "$dir" Vendor/cef
rmdir Vendor/downloads 2>/dev/null || true
echo "CEF $CEF_VERSION is ready at Vendor/cef"
