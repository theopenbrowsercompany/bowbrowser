#!/bin/bash
# make verify: runs the independent checks side by side and fails when any of them fails.
#
#   scripts/verify.sh [--plan]
#
# --plan prints which parts would run and why, and runs nothing.
#
# The parts are make targets: lint, guards, test, build and the script self tests (make test-e2e-wrapper and the
# other test-* targets that make test-scripts runs). They share no output folder (lint and guards only read, test
# builds BowCore/.build and BowWebKit/.build, the self tests use throwaway folders, build uses build/), so they run at
# once. Each part's
# output is kept in a file and printed whole, under a "== <part>" header, when the part ends, so the parts never
# interleave. Every part prints one "verify: <part> ok|FAIL <seconds>s" line, and the last line is
# "verify: PASS <n> parts in <seconds>s" or "verify: FAIL <parts> (<seconds>s)".
#
# Each self test runs only when a script it covers (the table below, plain data) differs from origin/main, committed
# or not, and the whole set runs when the Makefile differs. A change to a script no self test covers (verify.sh
# itself, check-release.sh, check-e2e-seams.sh and the like) runs none, and so does a docs or app only change.
# Measured at a load average of 10 to 17 (other worktrees building): test-e2e-wrapper 30 to 45 s with its groups side
# by side (150 to 165 s as one sequence), test-done 8 s, test-affected 5 s, test-private-paths and test-e2e-bisect
# 4 s, the rest 2 s or less. The self tests run beside lint, guards, test and build, so the longest part sets the
# time: a change to scripts/e2e.sh, which only the wrapper test covers, ends with it.
# Without an origin/main ref every self test runs. VERIFY_ALL=1 runs every part regardless, for a full backstop run.
# VERIFY_BASE=<ref> compares with another ref. make test-scripts runs every self test one after another.
set -u
cd "$(dirname "$0")/.."

# Self test (its make target) and the files it covers: the script it tests, what that script runs, and the test.
self_tests=(
  "test-e2e-wrapper scripts/e2e.sh scripts/e2e-flakes.sh scripts/stamp-tree.sh scripts/tree-key.sh scripts/package-cef.sh scripts/build-lock.sh scripts/e2e-quarantine.txt scripts/test-e2e-wrapper.sh"
  "test-prune scripts/prune-compile-cache.sh scripts/test-prune-compile-cache.sh"
  "test-affected scripts/e2e-affected.sh scripts/check.sh scripts/test-e2e-affected.sh"
  "test-done scripts/done.sh scripts/e2e-affected.sh scripts/test-done.sh"
  "test-refcount scripts/check-cef-refcount.sh scripts/test-check-cef-refcount.sh"
  "test-private-paths scripts/check-private-paths.sh .githooks/pre-push scripts/test-check-private-paths.sh"
  "test-bootstrap-cef scripts/bootstrap-cef.sh scripts/xcodebuild.sh scripts/test-bootstrap-cef.sh"
  "test-check-lists scripts/check-lists.sh scripts/test-check-lists.sh"
  "test-e2e-bisect scripts/e2e-bisect.sh scripts/test-e2e-bisect.sh"
  "test-verify-plan scripts/verify.sh scripts/test-verify-plan.sh"
  "test-e2e-flakes scripts/e2e-flakes.sh scripts/test-e2e-flakes.sh"
  "test-webkit-imports scripts/check-webkit-imports.sh scripts/test-check-webkit-imports.sh"
)
script_inputs=(scripts Makefile .githooks)
base=${VERIFY_BASE:-origin/main}

parts=(lint guards test build)
if [ "${VERIFY_ALL:-0}" = 1 ]; then
  for t in "${self_tests[@]}"; do parts+=("${t%% *}"); done
  echo "verify: VERIFY_ALL=1, running every part"
elif ! git rev-parse -q --verify "$base^{commit}" > /dev/null 2>&1; then
  for t in "${self_tests[@]}"; do parts+=("${t%% *}"); done
  echo "verify: no $base ref, running every self test"
else
  changed=$( { git diff --name-only "$base" -- "${script_inputs[@]}" 2> /dev/null
    git ls-files --others --exclude-standard -- "${script_inputs[@]}"; } | sort -u)
  if [ -z "$changed" ]; then
    echo "verify: skip the self tests (scripts/ and the Makefile match $base; VERIFY_ALL=1 runs them)"
  elif printf '%s\n' "$changed" | grep -qx Makefile; then
    for t in "${self_tests[@]}"; do parts+=("${t%% *}"); done
    echo "verify: the Makefile differs from $base, running every self test"
  else
    for t in "${self_tests[@]}"; do
      for f in ${t#* }; do
        if printf '%s\n' "$changed" | grep -qxF -- "$f"; then
          parts+=("${t%% *}")
          echo "verify: $f differs from $base, running ${t%% *}"
          break
        fi
      done
    done
    [ ${#parts[@]} -gt 4 ] || echo "verify: skip the self tests (no changed script is covered by one; VERIFY_ALL=1 runs them)"
  fi
fi
if [ "${1:-}" = --plan ]; then
  echo "verify: parts ${parts[*]}"
  exit 0
fi

out=$(mktemp -d)
mkfifo "$out/ended"
exec 3<> "$out/ended"
# Job control gives each part its own process group, so a part keeps SIGINT (a background job of a script would
# ignore it) and stopping verify stops each part's whole tree.
set -m
pids=()
cleanup() {
  local p
  for p in ${pids[@]+"${pids[@]}"}; do kill -TERM -- "-$p" 2> /dev/null; done
  wait 2> /dev/null
  rm -rf "$out"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

start=$SECONDS
for p in "${parts[@]}"; do
  (
    s=$SECONDS
    make --no-print-directory "$p" > "$out/$p.log" 2>&1 < /dev/null
    echo "$p $? $((SECONDS - s))" >&3
  ) &
  pids+=($!)
done

# Print each part whole as it ends, in the order they end: each part writes one line to the fifo when it ends.
failed=()
left=${#parts[@]}
while [ "$left" -gt 0 ] && read -r p status secs <&3; do
  left=$((left - 1))
  if [ -s "$out/$p.log" ]; then
    echo "== $p"
    cat "$out/$p.log"
  fi
  if [ "$status" = 0 ]; then
    echo "verify: $p ok ${secs}s"
  else
    echo "verify: $p FAIL ${secs}s (exit $status)"
    failed+=("$p")
  fi
done
wait
pids=()

if [ ${#failed[@]} -eq 0 ]; then
  echo "verify: PASS ${#parts[@]} parts in $((SECONDS - start))s"
else
  echo "verify: FAIL ${failed[*]} ($((SECONDS - start))s)"
  exit 1
fi
