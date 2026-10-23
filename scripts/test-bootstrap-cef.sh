#!/bin/bash
# Tests scripts/bootstrap-cef.sh --if-stale, which scripts/xcodebuild.sh runs before every build, in a throwaway
# checkout with a fake cef.lock and a fake CEF cache: a matching link is left alone, a stale link is relinked, a
# missing link is created, and two builds that find an unfilled cache at once fill it once. Downloads nothing; the
# fill uses a small local archive and a stub CMake project. Takes a few seconds.
set -u
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0
check() { # check <description> <condition command...>
  local what=$1
  shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; failed=1; fi
}
is() { [ "$1" = "$2" ]; }
contains() { case $1 in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# The xcodebuild wrapper must run the check before building.
check "xcodebuild.sh runs bootstrap-cef.sh --if-stale" grep -q '"$here/bootstrap-cef.sh" --if-stale' scripts/xcodebuild.sh

repo=$tmp/repo
cache=$tmp/cache
mkdir -p "$repo/scripts" "$cache"
cp scripts/bootstrap-cef.sh "$repo/scripts/"
lock() { # lock <version> [sha1]: write the fake checkout's cef.lock
  printf 'CEF_VERSION=%s\nCEF_PLATFORM=macosarm64\nCEF_DIST=minimal\nCEF_SHA1=%s\n' "$1" "${2:-0}" > "$repo/cef.lock"
}
ready() { # ready <version>: a filled cache folder for that version
  mkdir -p "$cache/cef_binary_$1_macosarm64_minimal"
  : > "$cache/cef_binary_$1_macosarm64_minimal/.ready"
}
run() { BOW_CEF_CACHE=$cache "$repo/scripts/bootstrap-cef.sh" "$@" 2>&1; }
old=$cache/cef_binary_1.0.0_macosarm64_minimal
new=$cache/cef_binary_2.0.0_macosarm64_minimal
ready 1.0.0
ready 2.0.0
lock 2.0.0

# 1. A missing link is created and named.
out=$(run --if-stale)
check "missing link: exit 0" is $? 0
check "missing link: linked to cef.lock's build" is "$(readlink "$repo/Vendor/cef")" "$new"
check "missing link: one line" is "$out" "cef: Vendor/cef was missing, relinked to cef_binary_2.0.0_macosarm64_minimal per cef.lock"

# 2. A matching link is left alone, silently.
before=$(stat -f '%i %m' "$repo/Vendor/cef")
out=$(run --if-stale)
check "matching link: exit 0" is $? 0
check "matching link: no output" is "$out" ""
check "matching link: link untouched" is "$(stat -f '%i %m' "$repo/Vendor/cef")" "$before"

# 3. A stale link (bootstrapped before a cef.lock change) is relinked and the line names both builds.
ln -sfn "$old" "$repo/Vendor/cef"
out=$(run --if-stale)
check "stale link: exit 0" is $? 0
check "stale link: relinked to cef.lock's build" is "$(readlink "$repo/Vendor/cef")" "$new"
check "stale link: one line" is "$out" "cef: Vendor/cef was cef_binary_1.0.0_macosarm64_minimal, relinked to cef_binary_2.0.0_macosarm64_minimal per cef.lock"

# 4. A folder left by the old per-checkout layout is replaced by the link.
rm "$repo/Vendor/cef"
mkdir -p "$repo/Vendor/cef"
out=$(run --if-stale)
check "folder: relinked" is "$(readlink "$repo/Vendor/cef")" "$new"
check "folder: named" contains "$out" "was a folder, relinked"

# 5. Without --if-stale (make bootstrap) it always says the build is ready; an unknown argument is refused.
out=$(run)
check "plain: ready line" is "$out" "CEF 2.0.0 is ready at Vendor/cef"
run --nope > /dev/null
check "unknown argument: exit 64" is $? 64

# 6. Two builds find a new cef.lock whose build is not in the cache yet: both end linked, and the cache is filled
# once (the stub CMake project counts its configure runs).
src=$tmp/src/cef_binary_3.0.0_macosarm64_minimal
mkdir -p "$src" "$cache/downloads"
cat > "$src/CMakeLists.txt" << 'EOF'
cmake_minimum_required(VERSION 3.10)
project(stub NONE)
file(APPEND "${CMAKE_CURRENT_LIST_DIR}/../configured" "x\n")
add_custom_target(libcef_dll_wrapper)
EOF
archive=$cache/downloads/cef_binary_3.0.0_macosarm64_minimal.tar.bz2
tar -cjf "$archive" -C "$tmp/src" cef_binary_3.0.0_macosarm64_minimal
lock 3.0.0 "$(shasum -a 1 "$archive" | cut -d' ' -f1)"
ln -sfn "$new" "$repo/Vendor/cef"
run --if-stale > "$tmp/a.out" &
a=$!
run --if-stale > "$tmp/b.out" &
b=$!
wait "$a"
sa=$?
wait "$b"
sb=$?
check "fill: both exit 0" is "$sa $sb" "0 0"
check "fill: linked to the new build" is "$(readlink "$repo/Vendor/cef")" "$cache/cef_binary_3.0.0_macosarm64_minimal"
check "fill: ready" test -f "$cache/cef_binary_3.0.0_macosarm64_minimal/.ready"
check "fill: configured once" is "$(wc -l < "$cache/configured" | tr -d ' ')" 1
[ "$failed" = 0 ] || cat "$tmp/a.out" "$tmp/b.out"

# 7. A wrong checksum fails and leaves the link as it was.
ln -sfn "$new" "$repo/Vendor/cef"
lock 4.0.0 0000000000000000000000000000000000000000
cp "$archive" "$cache/downloads/cef_binary_4.0.0_macosarm64_minimal.tar.bz2"
run --if-stale > /dev/null
check "bad checksum: fails" test $? -ne 0
check "bad checksum: link unchanged" is "$(readlink "$repo/Vendor/cef")" "$new"

if [ "$failed" = 0 ]; then echo "test-bootstrap-cef: PASS"; else echo "test-bootstrap-cef: FAIL"; fi
exit "$failed"
