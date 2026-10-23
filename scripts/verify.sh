#!/bin/bash
# make verify: runs the independent checks side by side and fails when any of them fails.
#
#   scripts/verify.sh [--plan]
#
# --plan prints which parts would run and why, and runs nothing.
#
# The parts are make targets: lint, guards, test, test-scripts and build. They share no output folder (lint and
# guards only read, test builds BowCore/.build, the script tests use throwaway folders, build uses build/), so they
# run at once. Each part's output is kept in a file and printed whole, under a "== <part>" header, when the part
# ends, so the parts never interleave. Every part prints one "verify: <part> ok|FAIL <seconds>s" line, and the last
# line is "verify: PASS <n> parts in <seconds>s" or "verify: FAIL <parts> (<seconds>s)".
#
# test-scripts (the self tests of the e2e wrapper, the compile cache prune and make check's e2e selection, about
# 35 seconds) runs only when
# something they test differs from origin/main, committed or not: scripts/ or the Makefile. A docs or app only
# change skips it, and so does a branch whose scripts match origin/main. Without an origin/main ref it runs.
# VERIFY_ALL=1 runs every part regardless, for a full backstop run. VERIFY_BASE=<ref> compares with another ref.
set -u
cd "$(dirname "$0")/.."

script_inputs=(scripts Makefile)
base=${VERIFY_BASE:-origin/main}

parts=(lint guards test build)
if [ "${VERIFY_ALL:-0}" = 1 ]; then
  parts+=(test-scripts)
  echo "verify: VERIFY_ALL=1, running every part"
elif ! git rev-parse -q --verify "$base^{commit}" > /dev/null 2>&1; then
  parts+=(test-scripts)
  echo "verify: no $base ref, running the script tests"
elif ! git diff --quiet "$base" -- "${script_inputs[@]}" 2> /dev/null ||
  [ -n "$(git ls-files --others --exclude-standard -- "${script_inputs[@]}")" ]; then
  parts+=(test-scripts)
  echo "verify: scripts/ or the Makefile differ from $base, running the script tests"
else
  echo "verify: skip test-scripts (scripts/ and the Makefile match $base; VERIFY_ALL=1 runs it)"
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
