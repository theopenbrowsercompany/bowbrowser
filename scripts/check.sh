#!/bin/bash
# make check: the quick check while building and fixing, running only what the change touches. It never replaces
# make verify and the full make e2e, which run once at the end and again when the branch lands.
#
# The changed files are those scripts/e2e-affected.sh lists (against the merge base with the base, committed or
# not: origin/main, or origin/webkit for a webkit slice, see scripts/base-ref.sh; CHECK_BASE=<ref> compares with another
# ref). The first line names the base. The parts run one after another:
#   lint    swift format --in-place on exactly the changed Swift files under App/UI, E2E, BowCore and BowWebKit (a
#           line says which it rewrote), then swift format lint --strict on them (skip when none; lint only, on
#           every file, when the changes cannot be listed: nothing is formatted then);
#   guards  make guards, always;
#   test    make test (the BowCore and BowWebKit tests), when BowCore/ or BowWebKit/ changed (or the changes cannot
#           be listed);
#   build   make build, when the e2e selection is not empty (the selection is all when scripts/e2e-affected.sh
#           fails, or prints nothing while a changed file is neither docs nor under BowWebKit/, which the app does
#           not link yet);
#   e2e     make e2e-run with the selection scripts/e2e-affected.sh prints, when it is not empty and the build passed.
# When the e2e selection is all and that run passes (not FLAKY) on a tree that did not change since the build (the key
# of scripts/tree-key.sh, uncommitted changes included), check records it in build/check-e2e-pass and prints a line
# saying so; scripts/done.sh reuses it instead of running the full e2e again. Every run deletes the old record first.
# Each part prints one "check: <part> ok|FAIL|skip ..." line with its seconds, and the last line is
# "check: PASS <parts> in <seconds>s (e2e: <selection>)" or "check: FAIL <parts> (<seconds>s)".
# Ctrl-C, TERM or HUP stops the running part (its whole process group) and ends with "check: FAIL interrupted".
set -u
cd "$(dirname "$0")/.." || exit 1

start=$SECONDS
# The base this branch is checked against (scripts/base-ref.sh): the first line, and the same base for every part
# (e2e-affected.sh, guards and the rest read these variables, each already overridable).
base=${CHECK_BASE:-$(scripts/base-ref.sh 2> /dev/null || echo origin/main)}
echo "check: base $base (scripts/base-ref.sh)"
export CHECK_BASE=$base VERIFY_BASE=${VERIFY_BASE:-$base} PRIVATE_PATHS_BASE=${PRIVATE_PATHS_BASE:-$base}
ran=() failed=()
# The record of a full e2e pass (4 lines: tree key, selection, summary line, run folder) for scripts/done.sh to reuse.
# Every check run drops the previous one first, so a partial, failed, flaky or interrupted run leaves none.
pass_stamp=build/check-e2e-pass
rm -f "$pass_stamp"
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
# (*.md or spec/) or under BowWebKit/, the only changes e2e-affected.sh maps to nothing.
if ! selection=$(scripts/e2e-affected.sh --why); then
  echo "check: the e2e selection cannot be computed, so check runs everything"
  selection=all
elif [ -z "$selection" ] && echo "$changed" | grep -v '^$' | grep -qvE '(\.md$|^spec/|^BowWebKit/)'; then
  echo "check: the e2e selection is empty but not every changed file is docs or BowWebKit, so check runs everything"
  selection=all
fi
echo "check: $(echo "$changed" | grep -c .) changed files, e2e selection: ${selection:-none}"

if [ "$listed" = 0 ]; then
  part lint make --no-print-directory lint
else
  swift_files=()
  while IFS= read -r f; do
    case $f in App/UI/*.swift | E2E/*.swift | BowCore/*.swift | BowWebKit/*.swift) [ -f "$f" ] && swift_files+=("$f") ;; esac
  done <<< "$changed"
  if [ ${#swift_files[@]} -eq 0 ]; then
    skip lint "no changed Swift files"
  else
    # Format exactly the changed files first (never an unchanged one), so lint does not fail on layout the formatter
    # fixes in a second, and say which files it rewrote.
    before=$(cksum "${swift_files[@]}")
    swift format --in-place "${swift_files[@]}" < /dev/null
    after=$(cksum "${swift_files[@]}")
    formatted=()
    for i in "${!swift_files[@]}"; do
      [ "$(echo "$before" | sed -n "$((i + 1))p")" = "$(echo "$after" | sed -n "$((i + 1))p")" ] ||
        formatted+=("${swift_files[$i]}")
    done
    if [ ${#formatted[@]} -eq 0 ]; then
      echo "check: format: ${#swift_files[@]} changed Swift files, none needed formatting"
    else
      echo "check: format: formatted ${formatted[*]} (commit the change)"
    fi
    part lint swift format lint --strict "${swift_files[@]}"
  fi
fi

part guards make --no-print-directory guards

if [ "$listed" = 0 ] || echo "$changed" | grep -qE '^(BowCore|BowWebKit)/'; then
  part test make --no-print-directory test
else
  skip test "BowCore/ and BowWebKit/ unchanged"
fi

if [ -z "$selection" ]; then
  skip build "no e2e tests to run"
  skip e2e "no e2e tests to run"
else
  # The tree the build and the e2e run see: lint's formatting is done, so this is the source they are built from.
  key_before=$(scripts/tree-key.sh)
  if part build make --no-print-directory build; then
    if part e2e make --no-print-directory e2e-run E2E="$selection"; then
      # A passing full e2e on a tree that did not change while it ran: leave the pass for make done to reuse.
      key_after=$(scripts/tree-key.sh)
      latest=$(readlink build/e2e/latest 2> /dev/null || true)
      summary=""
      [ -z "$latest" ] || summary=$(grep '^E2E: ' "build/e2e/$latest/report.txt" 2> /dev/null | tail -n 1)
      case $summary in "E2E: PASS"*)
        if [ "$selection" = all ] && [ "$key_before" = "$key_after" ] && [ ${#failed[@]} -eq 0 ]; then
          printf '%s\n%s\n%s\n%s\n' "$key_after" "$selection" "$summary" "$latest" > "$pass_stamp"
          echo "check: full e2e pass recorded for tree $key_after (make done reuses it while the tree is unchanged)"
        fi
        ;;
      esac
    fi
  else
    skip e2e "the build failed"
  fi
fi

if [ ${#failed[@]} -eq 0 ]; then
  echo "check: PASS ${ran[*]} in $((SECONDS - start))s (e2e: ${selection:-none})"
else
  echo "check: FAIL ${failed[*]} ($((SECONDS - start))s)"
  exit 1
fi
