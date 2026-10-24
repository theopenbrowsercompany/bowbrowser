#!/bin/bash
# Tests scripts/base-ref.sh in a throwaway git repository whose origin/main and origin/webkit are plain refs (no remote,
# no fetch): no origin/webkit, a main branch, the webkit branch itself, a branch off webkit, a branch off webkit after
# webkit merged into main, a main that moved on, and BOW_BASE. Touches no real ref. Takes under a second.
set -u
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
repo=$tmp/repo
mkdir -p "$repo/scripts"
cp scripts/base-ref.sh "$repo/scripts/"
g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }
commit() { echo "$1" > "$repo/$1.txt"; g add -A; g commit -q -m "$1"; }
base_ref() { (cd "$repo" && env -u BOW_BASE "$@" scripts/base-ref.sh 2>&1); }

failed=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: wanted '$2', got '$3'"; failed=1; fi
}

g init -q -b work
commit one
g update-ref refs/remotes/origin/main HEAD

# 1. No origin/webkit: main.
check "no origin/webkit, on main" "origin/main" "$(base_ref)"
g checkout -q -b feature
commit feature
check "no origin/webkit, a branch off main" "origin/main" "$(base_ref)"

# 2. origin/webkit forked from main with two commits of its own; the checkout is main or a branch off main.
g checkout -q -b webkit-side origin/main
commit w1
commit w2
g update-ref refs/remotes/origin/webkit HEAD
g checkout -q work
check "origin/webkit exists, on main" "origin/main" "$(base_ref)"
g checkout -q feature
check "origin/webkit exists, a branch off main" "origin/main" "$(base_ref)"

# 3. A main that moved on after webkit forked, and a branch off the new main.
g checkout -q work
commit two
g update-ref refs/remotes/origin/main HEAD
g checkout -q -b feature2
commit feature2
check "main moved on, a branch off the new main" "origin/main" "$(base_ref)"

# 4. The webkit branch itself, and a branch off it.
g checkout -q webkit-side
check "the webkit branch itself" "origin/webkit" "$(base_ref)"
g checkout -q -b slice
commit slice
check "a branch off webkit" "origin/webkit" "$(base_ref)"
g checkout -q -b slice-behind webkit-side~1
commit sliceb
check "a branch off an older webkit commit" "origin/webkit" "$(base_ref)"

# 5. Webkit merged into main: a branch off webkit's old tip is based on main now.
g checkout -q work
g merge -q --no-ff -m "merge webkit" webkit-side
g update-ref refs/remotes/origin/main HEAD
g checkout -q slice
check "a branch off webkit after webkit merged into main" "origin/main" "$(base_ref)"
g checkout -q webkit-side
check "the webkit branch itself after it merged into main" "origin/main" "$(base_ref)"

# 6. BOW_BASE wins over everything, even with a webkit branch checked out.
g checkout -q slice
check "BOW_BASE set" "origin/custom" "$(base_ref BOW_BASE=origin/custom)"
check "BOW_BASE empty is ignored" "origin/main" "$(base_ref BOW_BASE=)"

# 7. A fresh webkit slice again after the merge: webkit moves on, a new branch off it is based on webkit.
g checkout -q webkit-side
commit w3
g update-ref refs/remotes/origin/webkit HEAD
g checkout -q -b slice2
commit slice2
check "a branch off webkit's new commit after an earlier merge" "origin/webkit" "$(base_ref)"

# 8. An unrelated HEAD (no merge base) and a missing origin/main: never fails.
g checkout -q --orphan unrelated
commit unrelated
check "no merge base with origin/webkit: main" "origin/main" "$(base_ref)"

if [ "$failed" = 0 ]; then echo "test-base-ref: PASS"; else
  echo "test-base-ref: FAIL"
  exit 1
fi
