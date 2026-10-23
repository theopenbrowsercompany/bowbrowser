#!/bin/bash
# make done: the final check of a branch, in one command, ending with one block to paste into the report.
#
#   scripts/done.sh
#
# 1. Fetches origin (git fetch -q origin); offline, it says so and checks against the origin/main it has.
# 2. When the branch does not contain origin/main, merges the two in memory (git merge-tree --write-tree, which
#    touches no file or ref): no conflict prints "done: behind origin/main by N commits with no conflict; the landing
#    rebases and reruns the checks" and goes on; a conflict refuses, naming the files. No origin/main also refuses.
# 3. Runs make bootstrap when Vendor/cef is missing (a fresh worktree).
# 4. Runs make verify, then the full make e2e (E2E=all), as separate commands. A failed verify skips the e2e and the
#    release build.
# 5. Once verify passed, runs make release beside the full e2e when the branch (committed or not, against its merge
#    base) touches App/, E2E/, BowCore/Sources/ or project.yml (App/ holds the bridging header), as the landing
#    does. Release builds into its own derived data (build/release), and verify has already generated the project
#    and built Debug, so the two share nothing; its output is printed after the e2e's, so the two never interleave.
#    Any other branch skips it.
# 6. Reruns the e2e tests the branch adds or changes (the names in each changed E2E/Tests file) 5 times with the retry
#    off (E2E_REPEAT=5 make e2e-run), after the full e2e passed; any failed repeat fails it. No such tests, no step.
# Then it prints the block: each step's result line, the e2e summary line and run folder, the path to final.png,
# the diff stat against the merge base with origin/main (origin/main itself unless the branch is behind), the tree
# hash and whether the worktree is dirty (a dirty tree is not what was checked). It exits 1 when any step failed
# (a failed release build too), 2 when it refused.
#
# DONE_BASE=<ref> compares with another ref than origin/main and DONE_FETCH=0 skips the fetch (the self test,
# scripts/test-done.sh, uses both). The steps' own output streams as they run; the block is the last thing printed.
set -u
cd "$(dirname "$0")/.." || exit 1

base=${DONE_BASE:-origin/main}
if [ "${DONE_FETCH:-1}" != 0 ] && ! git fetch -q origin; then
  echo "done: could not fetch origin (offline?); checking against the $base this checkout has"
fi
if ! git rev-parse -q --verify "$base^{commit}" > /dev/null 2>&1; then
  echo "done: no $base ref. Run git fetch origin. Rebase onto origin/main first."
  exit 2
fi
behind_line=""
if ! git merge-base --is-ancestor "$base" HEAD; then
  # Exit 0 is a clean merge, 1 a conflict (the conflicted paths follow the tree hash, up to a blank line), anything
  # else an error such as no merge base.
  merged=$(git merge-tree --write-tree --name-only --no-messages "$base" HEAD 2>&1)
  merge_status=$?
  if [ "$merge_status" = 1 ]; then
    echo "done: this branch conflicts with $base in:"
    echo "$merged" | sed -n '2,/^$/p' | grep -v '^$' | sed 's/^/  /'
    echo "done: rebase onto origin/main first."
    exit 2
  elif [ "$merge_status" != 0 ]; then
    echo "done: this branch cannot be merged with $base: $merged"
    echo "done: rebase onto origin/main first."
    exit 2
  fi
  behind=$(git rev-list --count "HEAD..$base")
  commits=commits
  [ "$behind" != 1 ] || commits=commit
  behind_line="done: behind $base by $behind $commits with no conflict; the landing rebases and reruns the checks"
  echo "$behind_line"
fi
fork=$(git merge-base "$base" HEAD)

out=$(mktemp -d)
release_pid=""
# kill_tree <pid>: stops a process and everything under it (the background release build: make, then
# build-lock.sh and xcodebuild, which as background jobs of a script ignore Ctrl-C).
kill_tree() {
  local child
  for child in $(pgrep -P "$1"); do kill_tree "$child"; done
  kill "$1" 2> /dev/null
}
cleanup() {
  [ -z "$release_pid" ] || kill_tree "$release_pid"
  rm -rf "$out"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
failed=0

# step <name> <command...>: runs the command with its output streaming and kept, records its status.
step() {
  local name=$1
  shift
  echo "== done: $name"
  "$@" 2>&1 | tee "$out/$name.log"
  step_status=${PIPESTATUS[0]}
}
step_status=0

if [ -e Vendor/cef ]; then
  bootstrap="skip (Vendor/cef is there)"
else
  step bootstrap make --no-print-directory bootstrap
  if [ "$step_status" = 0 ]; then bootstrap=ok; else
    bootstrap="FAIL (exit $step_status)"
    failed=1
  fi
fi

# Whether the branch needs a Release build: it touches what the Release app is built from. When the changed files
# cannot be listed, it builds, to be safe.
release_reason=""
if changed=$(CHECK_BASE=$base ./scripts/e2e-affected.sh --changed 2> /dev/null); then
  release_reason=$(echo "$changed" | grep -m1 '^\(App/\|E2E/\|BowCore/Sources/\|project\.yml$\)')
else
  release_reason="the changed files could not be listed"
fi

verify="skip (bootstrap failed)"
e2e="skip (not run)"
release="skip (verify did not pass)"
if [ "$failed" = 0 ]; then
  step verify make --no-print-directory verify
  verify_line=$(grep '^verify: \(PASS\|FAIL\)' "$out/verify.log" | tail -1)
  if [ "$step_status" = 0 ]; then verify="ok: ${verify_line:-no summary line}"; else
    verify="FAIL (exit $step_status): ${verify_line:-no summary line}"
    failed=1
  fi
  if [ "$failed" = 0 ]; then
    if [ -n "$release_reason" ]; then
      echo "== done: release, beside the e2e (its output follows the e2e's)"
      make --no-print-directory release > "$out/release.log" 2>&1 &
      release_pid=$!
    else
      release="skip (no change to App/, E2E/, BowCore/Sources/ or project.yml)"
    fi
    step e2e make --no-print-directory e2e E2E=all
    e2e_line=$(grep '^E2E: ' "$out/e2e.log" | tail -1)
    if [ "$step_status" = 0 ]; then e2e="ok"; else
      e2e="FAIL (exit $step_status)"
      failed=1
    fi
    if [ -n "$release_pid" ]; then
      release_status=0
      wait "$release_pid" || release_status=$?
      release_pid=""
      echo "== done: release"
      cat "$out/release.log"
      if [ "$release_status" = 0 ]; then release="ok ($release_reason)"; else
        release="FAIL (exit $release_status) ($release_reason)"
        failed=1
      fi
    fi
  else
    e2e="skip (verify failed)"
  fi
fi

full_run=$(readlink build/e2e/latest 2> /dev/null || true) # the full run, before the repeats move latest
# The tests the branch adds or changes (the names in each changed E2E/Tests file, found with
# scripts/e2e-affected.sh --changed), rerun 5 times with the retry off: a new test that flakes shows here.
repeat="skip (the e2e did not pass)"
repeat_lines=""
if [ "$failed" = 0 ]; then
  changed_tests=""
  changed_files=${changed:-}
  while IFS= read -r f; do
    case $f in E2E/Tests/*.swift) [ -f "$f" ] && changed_tests="$changed_tests"$'\n'"$(sed -n 's/.*let name = "\([^"]*\)".*/\1/p' "$f")" ;; esac
  done <<< "$changed_files"
  changed_tests=$(echo "$changed_tests" | grep -v '^$' | sort -u | paste -sd, -)
  if [ -z "$changed_tests" ]; then
    repeat="skip (no e2e test added or changed)"
  else
    step repeat env E2E_REPEAT=5 make --no-print-directory e2e-run "E2E=$changed_tests"
    repeat_lines=$(grep '^\(REPEAT \|E2E: \)' "$out/repeat.log")
    if [ "$step_status" = 0 ]; then repeat="ok (5 repeats of $changed_tests)"; else
      repeat="FAIL (exit $step_status) (5 repeats of $changed_tests)"
      failed=1
    fi
  fi
fi

echo
echo "===== done: report block ====="
echo "bootstrap: $bootstrap"
echo "make verify: $verify"
echo "make e2e: $e2e"
echo "e2e summary: ${e2e_line:-none}"
echo "make release: $release"
echo "changed tests, repeated: $repeat"
[ -z "$repeat_lines" ] || echo "$repeat_lines" | sed 's/^/  /'
run=$full_run
if [ -n "$run" ]; then echo "e2e run folder: build/e2e/$run"; else echo "e2e run folder: none"; fi
if [ -n "$run" ] && [ -f "build/e2e/$run/final.png" ]; then
  echo "final.png: $PWD/build/e2e/$run/final.png"
else
  echo "final.png: none"
fi
echo "head: $(git rev-parse HEAD)"
echo "tree: $(git rev-parse 'HEAD^{tree}')"
if [ -n "$(git status --porcelain)" ]; then echo "worktree: DIRTY (commit first, this is not what was checked)"; else echo "worktree: clean"; fi
if [ "$fork" = "$(git rev-parse "$base")" ]; then
  echo "git diff $base --stat:"
else
  echo "git diff $(git rev-parse --short "$fork") --stat (the merge base with $base):"
fi
git diff "$fork" --stat
[ -z "$behind_line" ] || echo "$behind_line"
if [ "$failed" = 0 ]; then echo "done: PASS"; else
  echo "done: FAIL"
  exit 1
fi
