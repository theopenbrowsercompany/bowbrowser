#!/bin/bash
# Tests which self tests scripts/verify.sh --plan picks, in a throwaway git repository with a copy of verify.sh: a change
# to a covered script runs only its self tests, one no self test covers runs none, the Makefile or VERIFY_ALL runs
# every one, an untracked or deleted covered file counts, and no base ref runs every one. Takes a second.
set -u
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
repo=$tmp/repo
mkdir -p "$repo/scripts" "$repo/.githooks"
cp scripts/verify.sh "$repo/scripts/"
for f in e2e.sh check.sh done.sh e2e-affected.sh check-release.sh check-e2e-seams.sh; do echo "# $f" > "$repo/scripts/$f"; done
echo "# hook" > "$repo/.githooks/pre-push"
echo "all:" > "$repo/Makefile"
echo docs > "$repo/README.md"
git -C "$repo" init -q
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m base

failed=0
# plan [env...]: the "parts" line of verify.sh --plan with the four fixed parts (lint guards test build) removed.
plan() {
  (cd "$repo" && env -u VERIFY_ALL VERIFY_BASE=HEAD "$@" ./scripts/verify.sh --plan 2>&1 | sed -n 's/^verify: parts lint guards test build *//p')
}
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: wanted '$2', got '$3'"; failed=1; fi
}

check "no change: no self test" "" "$(plan)"
echo more >> "$repo/README.md"
check "a docs change: no self test" "" "$(plan)"
git -C "$repo" checkout -q -- README.md

echo more >> "$repo/scripts/e2e.sh"
check "scripts/e2e.sh: only the wrapper test" "test-e2e-wrapper" "$(plan)"
git -C "$repo" checkout -q -- scripts/e2e.sh

echo more >> "$repo/scripts/e2e-affected.sh"
check "scripts/e2e-affected.sh: the two self tests that cover it" "test-affected test-done" "$(plan)"
git -C "$repo" checkout -q -- scripts/e2e-affected.sh

echo more >> "$repo/scripts/check-release.sh"
check "scripts/check-release.sh, which no self test covers: none" "" "$(plan)"
git -C "$repo" checkout -q -- scripts/check-release.sh

echo more >> "$repo/scripts/verify.sh"
check "scripts/verify.sh itself: its own self test" "test-verify-plan" "$(plan)"
git -C "$repo" checkout -q -- scripts/verify.sh

echo more >> "$repo/.githooks/pre-push"
check ".githooks/pre-push: the private paths self test" "test-private-paths" "$(plan)"
git -C "$repo" checkout -q -- .githooks/pre-push

echo more >> "$repo/Makefile"
check "the Makefile: every self test" "10" "$(plan | wc -w | tr -d ' ')"
git -C "$repo" checkout -q -- Makefile

check "VERIFY_ALL=1 with no change: every self test" "10" "$(plan VERIFY_ALL=1 | wc -w | tr -d ' ')"

echo new > "$repo/scripts/done.sh.new"
echo new > "$repo/scripts/check.sh.new"
check "an untracked file that is no covered script: none" "" "$(plan)"
rm "$repo/scripts/done.sh.new" "$repo/scripts/check.sh.new"
git -C "$repo" rm -q scripts/check.sh
check "a deleted covered script counts" "test-affected" "$(plan)"
git -C "$repo" reset -q --hard

(cd "$repo" && env -u VERIFY_ALL VERIFY_BASE=nope ./scripts/verify.sh --plan > "$tmp/noref.out" 2>&1)
check "no base ref: every self test" "10" "$(sed -n 's/^verify: parts lint guards test build *//p' "$tmp/noref.out" | wc -w | tr -d ' ')"

[ "$failed" = 0 ] && echo "verify plan self test: ok" || echo "verify plan self test: FAIL"
exit "$failed"
