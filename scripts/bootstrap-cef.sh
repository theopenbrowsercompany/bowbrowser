#!/bin/sh
# Download the pinned CEF build into Vendor/cef and build its C++ wrapper library.
set -eu
cd "$(dirname "$0")/.."
. ./cef.lock

name="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}_${CEF_DIST}"
archive="Vendor/downloads/${name}.tar.bz2"
stamp="Vendor/cef/.version"

if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$name" ] && [ -f Vendor/cef/build/libcef_dll_wrapper/libcef_dll_wrapper.a ]; then
  echo "CEF $CEF_VERSION is ready"
  exit 0
fi

mkdir -p Vendor/downloads
if [ ! -f "$archive" ]; then
  url="https://cef-builds.spotifycdn.com/$(printf '%s' "$name" | sed 's/+/%2B/g').tar.bz2"
  echo "Downloading $url"
  curl -fL --progress-bar -o "$archive.part" "$url"
  mv "$archive.part" "$archive"
fi

echo "$CEF_SHA1  $archive" | shasum -a 1 -c -

rm -rf Vendor/cef
mkdir -p Vendor/cef
tar -xjf "$archive" -C Vendor/cef --strip-components 1

cmake -S Vendor/cef -B Vendor/cef/build -DCMAKE_BUILD_TYPE=Release -DPROJECT_ARCH=arm64
cmake --build Vendor/cef/build --target libcef_dll_wrapper -j "$(sysctl -n hw.ncpu)"
echo "$name" > "$stamp"
echo "CEF $CEF_VERSION is ready"
