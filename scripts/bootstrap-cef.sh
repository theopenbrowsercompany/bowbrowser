#!/bin/sh
# Make the pinned CEF build available at Vendor/cef.
# CEF lives once in a shared cache outside the repository, so every checkout and worktree links to the
# same download and wrapper build instead of fetching 378 MB again. Override the cache with BOW_CEF_CACHE.
#
#   scripts/bootstrap-cef.sh [--if-stale]
#
# --if-stale: scripts/xcodebuild.sh runs this before every build, so a checkout bootstrapped before a cef.lock
# change never builds against the old CEF. It does nothing, silently, when Vendor/cef already links to the ready
# build cef.lock names; otherwise it bootstraps as usual and ends with one line naming the old and new link.
#
# Filling the cache (download, checksum, unpack, wrapper build) holds an flock on <cache>/<build>.lock, so builds
# in several worktrees that all find a new cef.lock at once fill it once; the kernel drops the lock if this dies.
set -eu
cd "$(dirname "$0")/.."
. ./cef.lock

mode=${1:-}
case $mode in '' | --if-stale) ;; *) echo "usage: bootstrap-cef.sh [--if-stale]" >&2; exit 64 ;; esac

name="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}_${CEF_DIST}"
cache="${BOW_CEF_CACHE:-$HOME/Library/Caches/bowbrowser}"
dir="$cache/$name"
archive="$cache/downloads/$name.tar.bz2"

if [ -L Vendor/cef ]; then
  old=$(readlink Vendor/cef)
elif [ -e Vendor/cef ]; then
  old="a folder"
else
  old="missing"
fi
if [ "$mode" = --if-stale ] && [ "$old" = "$dir" ] && [ -f "$dir/.ready" ]; then
  exit 0
fi

if [ ! -f "$dir/.ready" ] && [ -z "${BOW_CEF_LOCKED:-}" ]; then
  # Run this script again holding the cache lock; it checks .ready again, since another may have filled it.
  # $^F = 255 keeps the lock's descriptor open across exec (Perl closes descriptors above 2 on exec by default).
  mkdir -p "$cache"
  BOW_CEF_LOCKED=1 exec perl -MFcntl=:flock -e \
    '$^F = 255; open(my $fh, ">>", shift) or die "bootstrap-cef: $!\n"; flock($fh, LOCK_EX) or die "bootstrap-cef: $!\n";
     exec(@ARGV) or die "bootstrap-cef: $!\n";' "$cache/$name.lock" "$0" "$@"
fi

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
if [ "$mode" = --if-stale ]; then
  echo "cef: Vendor/cef was ${old##*/}, relinked to $name per cef.lock"
else
  echo "CEF $CEF_VERSION is ready at Vendor/cef"
fi
