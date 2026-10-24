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
#    release build. A full e2e that ends `E2E: FLAKY` (failed, then passed on the retry) does not fail the branch
#    when every `FLAKY <name>` line is a test it neither adds nor changes: the block reports the lines under the e2e
#    line and the run goes on. A FLAKY test the branch adds or changes, a FLAKY check no test owns (e2e.isolation,
#    chromium.errors), a FLAKY summary with no FLAKY lines and every FAIL, CRASH, TIMEOUT or ERROR still fail. The
#    landing is unchanged: there FLAKY is not a pass unless quarantined.
# 5. Once verify passed, runs make release beside the full e2e when the branch (committed or not, against its merge
#    base) touches App/, E2E/, BowCore/Sources/ or project.yml (App/ holds the bridging header), as the landing
#    does. Release builds into its own derived data (build/release), and verify has already generated the project
#    and built Debug, so the two share nothing; its output is printed after the e2e's, so the two never interleave.
#    Any other branch skips it.
# 0. A branch that changes only *.md files and spec/ (at least one file, nothing else, committed or not) is docs
#    only, as the landing treats it: it runs make lint and make guards, skips bootstrap, verify, the e2e, the
#    release build and the repeat (each says "skip (docs only)" in the block), and the block says so. Anything
#    else, scripts and fixtures included, keeps the full run.
# 6. Reruns the e2e tests the branch adds or changes (the names in each changed E2E/Tests file) DONE_REPEAT times
#    (default 20) in DONE_REPEAT_SHARDS shards (default 3, so the repeats also run under load, which exposes waits on
#    time) with the retry off (E2E_REPEAT=<n> E2E_SHARDS=<k> make e2e-run), after the full e2e passed. A selection of
#    fewer tests than shards gets the smoke tests as load filler. The gate reads the changed tests' own
#    `REPEAT <test> <passes>/<n>` lines: a changed test below n/n, a crash, timeout or error, or a failing check that
#    no filler test owns (a check belongs to the test of the RESULT line after it, the name prefix only when no RESULT
#    line follows) fails it; a filler test that fails under make's `E2E: FAIL ... repeats` summary prints a `note:`
#    line and never fails make done. DONE_REPEAT must be 2 or more (1 would be a plain run with the retry on). No such
#    tests, no step. The block says the count and shards used.
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
    echo "$merged" | sed -n '2,/^$/p' | grep -v '^$' | sort -u | sed 's/^/  /'
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

# The repeat step's size: DONE_REPEAT repeats (default 20) in DONE_REPEAT_SHARDS shards (default 3) of the tests the
# branch adds or changes. Lower them to test or to check by hand: DONE_REPEAT is a whole number of 2 or more (a single
# repeat is a plain run, which turns e2e.sh's retry back on and prints no REPEAT lines, so the gate could not read it),
# DONE_REPEAT_SHARDS a whole number of 1 or more.
repeat_count=${DONE_REPEAT:-20}
repeat_shards=${DONE_REPEAT_SHARDS:-3}
case $repeat_count$repeat_shards in *[!0-9]* | "")
  echo "done: DONE_REPEAT must be a whole number of 2 or more and DONE_REPEAT_SHARDS a whole number of 1 or more"
  exit 2
  ;;
esac
if [ "$repeat_count" -lt 2 ] || [ "$repeat_shards" -lt 1 ]; then
  echo "done: DONE_REPEAT must be a whole number of 2 or more and DONE_REPEAT_SHARDS a whole number of 1 or more"
  exit 2
fi

# repeat_gate <changed tests, comma list> <repeats> <e2e summary line> <repeat log>: prints the verdict on one line:
#   pass                     every repeat passed;
#   filler <note>            only filler tests (the smoke padding) failed, which never fails make done;
#   fail <reason>            anything else, including a crash, timeout or error, a changed test below N/N, and a
#                            failing check no test owns (chromium.errors, e2e.isolation): when in doubt, fail.
# It reads the log's `REPEAT <test> <passes>/<N>` lines (short output prints only the tests below N) and its
# `FAIL <check>: ...` lines. The runner prints a test's FAIL lines before its `RESULT <test> ...` line, so a check
# belongs to the test of the next RESULT line (many checks do not start with their test's name: design.fonts_sidebar
# is design.fonts'); a FAIL line no RESULT line follows before the next `E2E: ` summary (a run-wide check, or a short
# output that left out a passing test's RESULT line) falls back to the longest test name it equals or continues with a
# dot. A failing filler test only counts when make's summary is a FAIL naming repeats (not a crash or kill).
repeat_gate() {
  local changed=$1 n=$2 summary=$3 log=$4
  case $summary in
    "") echo "fail no summary line"; return ;;
    "E2E: PASS"*) echo pass; return ;;
    "E2E: CRASH"* | "E2E: TIMEOUT"* | "E2E: ERROR"* | "E2E: FLAKY"* | *"(CRASH"* | *"(TIMEOUT"* | *"(ERROR"* | *"(FLAKY"*) echo "fail ${summary#E2E: }"; return ;;
    "E2E: FAIL "*" repeats"*) ;;
    *) echo "fail ${summary#E2E: }"; return ;;
  esac
  awk -v changed="$changed" -v n="$n" '
    function flush(t,   j) {
      for (j = 1; j <= np; j++) { checks[++nc] = pend[j]; owned[nc] = t }
      np = 0
    }
    BEGIN { k = split(changed, c, ","); for (i = 1; i <= k; i++) mine[c[i]] = 1 }
    /^REPEAT [^ ]+ [0-9]+\/[0-9]+$/ { split($3, p, "/"); if (p[1] + 0 < n) low[$2] = $3 }
    /^FAIL [^ ]+/ { chk = $2; sub(/:$/, "", chk); pend[++np] = chk }
    /^RESULT [^ ]+ [^ ]+/ { seen[$2] = 1; flush($2) }
    /^E2E: / { flush("") }
    END {
      flush("")
      for (t in low) if (t in mine) { print "fail changed test " t " passed " low[t] " repeats"; exit }
      if (nc == 0) { print "fail repeats failed with no FAIL line to attribute"; exit }
      for (i = 1; i <= nc; i++) {
        owner = owned[i]
        # When in doubt, fail: a check named after a changed test is its own whatever RESULT line follows it (a quit
        # check prints its FAIL after its test passed, and short output leaves out a passing test'"'"'s RESULT line).
        for (t in mine) if (checks[i] == t || index(checks[i], t ".") == 1) { print "fail check " checks[i] " is a changed test'"'"'s or no test'"'"'s"; exit }
        if (owner == "") {
          for (t in low) if ((checks[i] == t || index(checks[i], t ".") == 1) && length(t) > length(owner)) owner = t
          for (t in seen) if ((checks[i] == t || index(checks[i], t ".") == 1) && length(t) > length(owner)) owner = t
          for (t in mine) if ((checks[i] == t || index(checks[i], t ".") == 1) && length(t) >= length(owner)) owner = t
        }
        if (owner == "" || owner in mine) { print "fail check " checks[i] " is a changed test'"'"'s or no test'"'"'s"; exit }
      }
      list = ""
      for (t in low) list = list (list == "" ? "" : ", ") t " " low[t]
      print "filler filler test failed (not part of the gate): " list
    }' "$log"
}

# changed_tests_of <changed files, one per line>: the e2e tests the branch adds or changes (the names in each changed
# E2E/Tests file), as a comma list. The repeat step and the FLAKY tolerance both use it, so they never disagree.
changed_tests_of() {
  local f names=""
  while IFS= read -r f; do
    case $f in E2E/Tests/*.swift) [ -f "$f" ] && names="$names"$'\n'"$(sed -n 's/.*let name = "\([^"]*\)".*/\1/p' "$f")" ;; esac
  done <<< "$1"
  echo "$names" | grep -v '^$' | sort -u | paste -sd, -
}

# flaky_verdict <changed tests, comma list> <e2e log>: whether a FLAKY full e2e may be gone past, on one line:
#   ok <names>      every `FLAKY <name>: failed then passed (...)` line names a test the branch neither adds nor
#                   changes (or a check one owns: the test name, or the longest test name and a dot before it);
#   fail <reason>   a FLAKY test the branch changes, a check no test owns (e2e.isolation, chromium.errors), or no
#                   FLAKY line to attribute: when in doubt, fail.
flaky_verdict() {
  local changed=$1 log=$2 all_tests
  all_tests=$(cat E2E/Tests/*.swift 2> /dev/null | sed -n 's/.*let name = "\([^"]*\)".*/\1/p' | paste -sd, -)
  awk -v changed="$changed" -v all="$all_tests" '
    BEGIN {
      k = split(changed, c, ","); for (i = 1; i <= k; i++) mine[c[i]] = 1
      k = split(all, a, ","); for (i = 1; i <= k; i++) if (a[i] != "") known[a[i]] = 1
    }
    /^FLAKY [^ ]+:/ { n = $2; sub(/:$/, "", n); names[++nn] = n }
    END {
      if (nn == 0) { print "fail FLAKY with no FLAKY lines"; exit }
      for (i = 1; i <= nn; i++) {
        owner = ""
        for (t in known) if ((names[i] == t || index(names[i], t ".") == 1) && length(t) > length(owner)) owner = t
        for (t in mine) if ((names[i] == t || index(names[i], t ".") == 1) && length(t) > length(owner)) owner = t
        if (names[i] == "e2e.isolation" || names[i] == "chromium.errors") owner = ""
        if (owner == "") { print "fail FLAKY check no test owns: " names[i]; exit }
        if (owner in mine) { print "fail FLAKY test this branch changes: " names[i]; exit }
      }
      list = ""
      for (i = 1; i <= nn; i++) list = list (list == "" ? "" : ", ") names[i]
      print "ok " list
    }' "$log"
}

# Whether the branch needs a Release build: it touches what the Release app is built from. When the changed files
# cannot be listed, it builds, to be safe.
release_reason=""
docs_only=0
if changed=$(CHECK_BASE=$base ./scripts/e2e-affected.sh --changed 2> /dev/null); then
  release_reason=$(echo "$changed" | grep -m1 '^\(App/\|E2E/\|BowCore/Sources/\|project\.yml$\)')
  # Docs only: at least one changed file, and every one is a *.md file or under spec/ (the landing's policy, and
  # e2e-affected.sh's "docs" mapping). Anything else, or no change at all, keeps the full run.
  if [ -n "$changed" ] && [ -z "$(echo "$changed" | grep -v '\.md$' | grep -v '^spec/')" ]; then docs_only=1; fi
else
  release_reason="the changed files could not be listed"
fi

if [ "$docs_only" = 1 ]; then
  bootstrap="skip (docs only)"
elif [ -e Vendor/cef ]; then
  bootstrap="skip (Vendor/cef is there)"
else
  step bootstrap make --no-print-directory bootstrap
  if [ "$step_status" = 0 ]; then bootstrap=ok; else
    bootstrap="FAIL (exit $step_status)"
    failed=1
  fi
fi

verify="skip (bootstrap failed)"
e2e="skip (not run)"
release="skip (verify did not pass)"
lint_line=""
guards_line=""
if [ "$docs_only" = 1 ]; then
  # Only *.md and spec/ changed: lint and guards, no build, e2e or release.
  verify="skip (docs only)"
  e2e="skip (docs only)"
  release="skip (docs only)"
  step lint make --no-print-directory lint
  if [ "$step_status" = 0 ]; then lint_line=ok; else
    lint_line="FAIL (exit $step_status)"
    failed=1
  fi
  step guards make --no-print-directory guards
  if [ "$step_status" = 0 ]; then guards_line=ok; else
    guards_line="FAIL (exit $step_status)"
    failed=1
  fi
elif [ "$failed" = 0 ]; then
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
    changed_tests=$(changed_tests_of "${changed:-}")
    flaky_lines=""
    if [ "$step_status" = 0 ]; then e2e="ok"; else
      e2e="FAIL (exit $step_status)"
      failed=1
      # A FLAKY run (failed, then passed on the retry) goes on when every flaky test is outside this branch.
      case $e2e_line in "E2E: FLAKY"*)
        flaky=$(flaky_verdict "$changed_tests" "$out/e2e.log")
        case $flaky in
          "ok "*)
            e2e="ok (FLAKY outside this branch, reported: ${flaky#ok })"
            flaky_lines=$(grep '^FLAKY ' "$out/e2e.log")
            failed=0
            ;;
          *) e2e="FAIL (exit $step_status): ${flaky#fail }" ;;
        esac
        ;;
      esac
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
# scripts/e2e-affected.sh --changed), rerun DONE_REPEAT times in shards with the retry off: a new test that flakes shows here.
repeat="skip (the e2e did not pass)"
repeat_lines=""
if [ "$docs_only" = 1 ]; then
  repeat="skip (docs only)"
elif [ "$failed" = 0 ]; then
  if [ -z "$changed_tests" ]; then
    repeat="skip (no e2e test added or changed)"
  else
    # Fewer changed tests than shards would run as one shard per test, so a lone test would get no load: the smoke
    # tests pad the selection as filler (e2e.sh drops a name listed twice).
    selection=$changed_tests
    n_changed=$(echo "$changed_tests" | tr ',' '\n' | grep -c .)
    [ "$n_changed" -ge "$repeat_shards" ] || selection="$changed_tests,smoke"
    desc="$repeat_count repeats in $repeat_shards shards of $changed_tests"
    step repeat env E2E_REPEAT="$repeat_count" E2E_SHARDS="$repeat_shards" make --no-print-directory e2e-run "E2E=$selection"
    repeat_lines=$(grep '^\(REPEAT \|E2E: \|note: \)' "$out/repeat.log")
    # make exits 2 for any failure, so the summary line decides: PASS is the only pass, and a failure counts only
    # when every failing check belongs to a filler test (see repeat_gate).
    summary=$(grep '^E2E: ' "$out/repeat.log" | tail -1)
    verdict=$(repeat_gate "$changed_tests" "$repeat_count" "$summary" "$out/repeat.log")
    case $verdict in
      pass)
        if [ "$step_status" = 0 ]; then repeat="ok ($desc)"; else
          repeat="FAIL (exit $step_status) ($desc)"
          failed=1
        fi
        ;;
      "filler "*)
        repeat="ok ($desc)"
        repeat_lines="$repeat_lines"$'\n'"note: ${verdict#filler }"
        ;;
      *)
        repeat="FAIL (${verdict#fail }) ($desc)"
        failed=1
        ;;
    esac
  fi
fi

echo
echo "===== done: report block ====="
echo "bootstrap: $bootstrap"
if [ "$docs_only" = 1 ]; then
  echo "docs only: the branch changes only *.md files and spec/, so it ran lint and guards and no build, e2e or release, as the landing does"
  echo "make lint: $lint_line"
  echo "make guards: $guards_line"
fi
echo "make verify: $verify"
echo "make e2e: $e2e"
[ -z "${flaky_lines:-}" ] || echo "$flaky_lines" | sed 's/^/  /'
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
