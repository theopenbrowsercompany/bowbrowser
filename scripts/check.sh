#!/bin/bash
# make check: the quick check while building and fixing, running only what the change touches. It never replaces
# make verify and the full make e2e, which run once at the end and again when the branch lands.
#
# The changed files are those scripts/e2e-affected.sh lists (against the merge base with origin/main, committed or
# not; CHECK_BASE=<ref> compares with another ref). The parts run one after another:
#   lint    swift format lint --strict on the changed Swift files under App/UI, E2E and BowCore (skip when none;
#           every file when the changes cannot be listed);
#   guards  make guards, always;
#   test    the BowCore unit tests, when BowCore/ changed (or the changes cannot be listed);
#   build   make build, when the e2e selection is not empty (the selection is all when scripts/e2e-affected.sh
#           fails, or prints nothing while a changed file is not docs);
#   e2e     make e2e-run with the selection scripts/e2e-affected.sh prints, when it is not empty and the build passed.
# Each part prints one "check: <part> ok|FAIL|skip ..." line with its seconds, and the last line is
# "check: PASS <parts> in <seconds>s (e2e: <selection>)" or "check: FAIL <parts> (<seconds>s)".
# Ctrl-C, TERM or HUP stops the running part (its whole process group) and ends with "check: FAIL interrupted".
set -u
cd "$(dirname "$0")/.." || exit 1

start=$SECONDS
ran=() failed=()
# Job control gives each part its own process group, so stopping check stops the part's whole tree (scripts/e2e.sh
# ends the app and its helpers on TERM).
set -m
pid=""
stop() {
  [ -z "$pid" ] || kill -TERM -- "-$pid" 2> /dev/null
  wait 2> /dev/null
  echo "check: FAIL interrupted ($((SECONDS - start))s)"
  exit "$1"
}
trap 'stop 130' INT
trap 'stop 143' TERM
trap 'stop 129' HUP

# part <name> <command...>: runs the command as one part and records its outcome.
part() {
  local name=$1 s=$SECONDS status
  shift
  echo "== $name"
  "$@" < /dev/null &
  pid=$!
  wait "$pid"
  status=$?
  pid=""
  ran+=("$name")
  if [ "$status" = 0 ]; then
    echo "check: $name ok $((SECONDS - s))s"
  else
    echo "check: $name FAIL $((SECONDS - s))s (exit $status)"
    failed+=("$name")
  fi
  return "$status"
}
skip() { echo "check: $1 skip ($2)"; }

if changed=$(scripts/e2e-affected.sh --changed); then
  listed=1
else
  listed=0
  echo "check: the changed files cannot be listed, so check runs everything"
fi
# A selection that cannot be computed runs everything, and so does an empty one unless every changed file is docs
# (*.md or spec/), the only changes e2e-affected.sh maps to nothing.
if ! selection=$(scripts/e2e-affected.sh --why); then
  echo "check: the e2e selection cannot be computed, so check runs everything"
  selection=all
elif [ -z "$selection" ] && echo "$changed" | grep -v '^$' | grep -qvE '(\.md$|^spec/)'; then
  echo "check: the e2e selection is empty but not every changed file is docs, so check runs everything"
  selection=all
fi
echo "check: $(echo "$changed" | grep -c .) changed files, e2e selection: ${selection:-none}"

if [ "$listed" = 0 ]; then
  part lint make --no-print-directory lint
else
  swift_files=()
  while IFS= read -r f; do
    case $f in App/UI/*.swift | E2E/*.swift | BowCore/*.swift) [ -f "$f" ] && swift_files+=("$f") ;; esac
  done <<< "$changed"
  if [ ${#swift_files[@]} -eq 0 ]; then
    skip lint "no changed Swift files"
  else
    part lint swift format lint --strict "${swift_files[@]}"
  fi
fi

part guards make --no-print-directory guards

if [ "$listed" = 0 ] || echo "$changed" | grep -q '^BowCore/'; then
  part test make --no-print-directory test
else
  skip test "BowCore/ unchanged"
fi

if [ -z "$selection" ]; then
  skip build "no e2e tests to run"
  skip e2e "no e2e tests to run"
elif part build make --no-print-directory build; then
  part e2e make --no-print-directory e2e-run E2E="$selection"
else
  skip e2e "the build failed"
fi

if [ ${#failed[@]} -eq 0 ]; then
  echo "check: PASS ${ran[*]} in $((SECONDS - start))s (e2e: ${selection:-none})"
else
  echo "check: FAIL ${failed[*]} ($((SECONDS - start))s)"
  exit 1
fi
