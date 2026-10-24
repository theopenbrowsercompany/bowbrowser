#!/bin/bash
# make done: the final check of a branch, in one command, ending with one block to paste into the report.
#
#   scripts/done.sh
#
# 1. Fetches origin (git fetch -q origin); offline, it says so and checks against the base it has.
# 2. When the branch does not contain the base (scripts/base-ref.sh: origin/main, or origin/webkit for a webkit slice), merges the two in memory (git merge-tree --write-tree, which
#    touches no file or ref): no conflict prints "done: behind the base by N commits with no conflict; the landing
#    rebases and reruns the checks" and goes on; a conflict refuses, naming the files. No base ref also refuses.
# 3. Runs make bootstrap when Vendor/cef is missing (a fresh worktree).
# 4. Runs make verify, then the full make e2e (E2E=all) in DONE_E2E_SHARDS shards (default 3, as the landing runs it;
#    1 runs it in one app), as separate commands. A failed verify skips the e2e and the
#    release build. A full e2e that ends `E2E: FLAKY` (failed, then passed on the retry) does not fail the branch
#    when every `FLAKY <name>` line is a test it neither adds nor changes and that no changed E2E/Harness or
#    E2E/Engine symbol reaches (step 6 says how those are found): the block reports the lines under the e2e line and
#    the run goes on. A FLAKY test the branch adds, changes or reaches that way, a FLAKY check no test owns
#    (e2e.isolation, chromium.errors), a FLAKY summary with no FLAKY lines, a run where the changed files could not be
#    listed (exit 3 of e2e-affected.sh --changed) or a changed test file that names its tests in a form the list
#    cannot read (below), and every FAIL, CRASH, TIMEOUT or ERROR still fail. The landing is unchanged: there FLAKY is
#    not a pass unless quarantined.
# 5. Once verify passed, runs make release beside the full e2e when the branch (committed or not, against its merge
#    base) touches App/, E2E/, BowCore/Sources/ or project.yml (App/ holds the bridging header), as the landing
#    does. Release builds into its own derived data (build/release), and verify has already generated the project
#    and built Debug, so the two share nothing; its output is printed after the e2e's, so the two never interleave.
#    Any other branch skips it.
# 0. A branch that changes only *.md files and spec/ (at least one file, nothing else, committed or not) is docs
#    only, as the landing treats it: it runs make lint and make guards, skips bootstrap, verify, the e2e, the
#    release build and the repeat (each says "skip (docs only)" in the block), and the block says so. Anything
#    else, scripts and fixtures included, keeps the full run.
# 6. Reruns the e2e tests the branch adds or changes (the names in each changed E2E/Tests file, and the tests it
#    brings back by removing their entries from scripts/e2e-not-ported.txt), DONE_REPEAT times
#    (default 20) in DONE_REPEAT_SHARDS shards (default 3, so the repeats also run under load, which exposes waits on
#    time) with the retry off (E2E_REPEAT=<n> E2E_SHARDS=<k> make e2e-run), after the full e2e passed. A selection of
#    fewer tests than shards gets the smoke tests as load filler. The gate reads the changed tests' own
#    `REPEAT <test> <passes>/<n>` lines: a changed test below n/n, a crash, timeout or error, or a failing check that
#    no filler test owns (a check belongs to the test of the RESULT line after it, the name prefix only when no RESULT
#    line follows) fails it; a filler test that fails under make's `E2E: FAIL ... repeats` summary prints a `note:`
#    line and never fails make done. DONE_REPEAT must be 2 or more (1 would be a plain run with the retry on). No such
#    tests, no step. The block says the count and shards used ("changed tests, repeated").
#    Tests the full e2e left out as not ported yet (the "notPorted" list in its results.json, from
#    scripts/e2e-not-ported.txt) are taken out of this repeat, the callers' repeat and the smoke padding by name; the
#    block shows the e2e summary line, whose `; not ported N` ends it, and names the tests left out of the repeats.
# 7. Reruns, in a second and smaller run, the tests that reach a symbol the branch changes or adds in E2E/Harness/ or
#    E2E/Engine/ without being changed themselves (scripts/e2e-affected.sh --callers: a plain text search for the
#    changed functions, properties and types in E2E/Tests and one level up in the other harness files; a name found in
#    12 or more test files is too common to search, and then the smoke tests and every test in the areas that call
#    the changed file are added, and the note says which names). They have no change of their own, so they repeat
#    DONE_REPEAT_CALLERS times (default 6) in the same shards, and a caller over the DONE_REPEAT_CAP (default 8) is
#    sampled: each area's best caller, and the block says so. The same gate applies ("harness callers, repeated").
#    A test is named by `let name = "<literal>"` or by `<Type>Test(name: "<literal>"` (the popups tests); a name
#    computed in code (`var name: String { ... }`, a raw value) belongs to a `selectedByNameOnly` test, which the full
#    run and the repeats never run. A changed test file with an E2ETest type that has none of those forms fails the
#    FLAKY tolerance and the repeat instead of being missed (unreadable_test_files_of).
# 8. Reruns the package test suites the branch adds or changes: for each changed file under BowCore/Tests/ or
#    BowWebKit/Tests/, every top level suite it declares (a type with @Suite or @Test members, or an extension of one)
#    runs DONE_PKG_REPEAT times (default 10) with `swift test --skip-build --package-path <package> --filter
#    '\.<Suite>/'`, after the verify built both packages. A run that fails, or that runs no test (a filter that matches
#    nothing, a file whose suite cannot be read), fails make done and names the package, the suite and the run
#    ("package tests, repeated"). No such file, no step.
# 4a. Reuse (instead of the full e2e of step 4): when make check ran the full e2e (selection all) and it passed on this very tree (scripts/tree-key.sh,
#    uncommitted changes included; make check records it in build/check-e2e-pass and deletes the record at the start of
#    every run), the full e2e is not run again: the block says "make e2e: ok (reused make check's pass on tree <key>)",
#    and its summary line still ends `; not ported N` when that run left tests out (the count is read from its results.json).
#    A different key, a record of another selection or one whose run folder is gone, no record (a partial, failed,
#    FLAKY or interrupted check) all run the e2e as usual. DONE_REUSE=0 never reuses.
# Then it prints the block: each step's result line, the e2e summary line and run folder, the path to final.png,
# the diff stat against the merge base with the base (the base itself unless the branch is behind), the tree
# hash and whether the worktree is dirty (a dirty tree is not what was checked). It exits 1 when any step failed
# (a failed release build too), 2 when it refused.
#
# DONE_BASE=<ref> compares with another ref than the base and DONE_FETCH=0 skips the fetch (the self test,
# scripts/test-done.sh, uses both). The steps' own output streams as they run; the block is the last thing printed.
#
# The sizes, all whole numbers: DONE_REPEAT (2 or more, default 20) and DONE_REPEAT_SHARDS (1 or more, default 3) for
# the changed e2e tests; DONE_REPEAT_CALLERS (2 or more, default 6) and DONE_REPEAT_CAP (1 or more, default 8) for the
# tests only a changed harness symbol reaches; DONE_PKG_REPEAT (2 or more, default 10) for the package suites;
# DONE_REUSE=0 turns the reuse of make check's full e2e pass off; DONE_E2E_SHARDS (1 or more, default 3) sets the shards
# of the full e2e.
set -u
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd "$(dirname "$0")/.." || exit 1

# The base is picked after the fetch, because the fetch can bring in origin/webkit (scripts/base-ref.sh).
fetch_failed=0
if [ "${DONE_FETCH:-1}" != 0 ] && ! git fetch -q origin; then fetch_failed=1; fi
base=${DONE_BASE:-$(scripts/base-ref.sh 2> /dev/null || echo origin/main)}
echo "done: base $base (scripts/base-ref.sh)"
[ "$fetch_failed" = 0 ] || echo "done: could not fetch origin (offline?); checking against the $base this checkout has"
# Every step compares with this base, not with its own default.
export CHECK_BASE=$base VERIFY_BASE=$base PRIVATE_PATHS_BASE=$base
if ! git rev-parse -q --verify "$base^{commit}" > /dev/null 2>&1; then
  echo "done: no $base ref. Run git fetch origin. Rebase onto $base first."
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
    echo "done: rebase onto $base first."
    exit 2
  elif [ "$merge_status" != 0 ]; then
    echo "done: this branch cannot be merged with $base: $merged"
    echo "done: rebase onto $base first."
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
e2e_shards=${DONE_E2E_SHARDS:-3}
case $e2e_shards in *[!0-9]* | "" | 0)
  echo "done: DONE_E2E_SHARDS must be a whole number of 1 or more"
  exit 2
  ;;
esac
callers_count=${DONE_REPEAT_CALLERS:-6}
callers_cap=${DONE_REPEAT_CAP:-8}
pkg_count=${DONE_PKG_REPEAT:-10}
case $repeat_count$repeat_shards in *[!0-9]* | "")
  echo "done: DONE_REPEAT must be a whole number of 2 or more and DONE_REPEAT_SHARDS a whole number of 1 or more"
  exit 2
  ;;
esac
if [ "$repeat_count" -lt 2 ] || [ "$repeat_shards" -lt 1 ]; then
  echo "done: DONE_REPEAT must be a whole number of 2 or more and DONE_REPEAT_SHARDS a whole number of 1 or more"
  exit 2
fi
case $callers_count$callers_cap$pkg_count in *[!0-9]* | "")
  echo "done: DONE_REPEAT_CALLERS and DONE_PKG_REPEAT must be whole numbers of 2 or more and DONE_REPEAT_CAP a whole number of 1 or more"
  exit 2
  ;;
esac
if [ "$callers_count" -lt 2 ] || [ "$pkg_count" -lt 2 ] || [ "$callers_cap" -lt 1 ]; then
  echo "done: DONE_REPEAT_CALLERS and DONE_PKG_REPEAT must be whole numbers of 2 or more and DONE_REPEAT_CAP a whole number of 1 or more"
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


# test_names_in <E2E/Tests file>: the test names it declares, one per line: `let name = "<literal>"` (a stored name)
# and `<Type>Test(name: "<literal>"` (one test type constructed once per name, as the popups tests do).
test_names_in() {
  awk '{
    s = $0
    if (match(s, /let name = "[^"]*"/)) print substr(s, RSTART + 12, RLENGTH - 13)
    while (match(s, /Test\(name: "[^"]*"/)) { print substr(s, RSTART + 12, RLENGTH - 13); s = substr(s, RSTART + RLENGTH) }
  }' "$1"
}

# changed_tests_of <changed files, one per line>: the e2e tests the branch adds or changes (the names in each changed
# E2E/Tests file, see test_names_in), as a comma list. The repeat step and the FLAKY tolerance both use it, so they
# never disagree. A name computed in code (`var name: String { ... }`, a raw value) is not read; such a test is
# `selectedByNameOnly` (the full run and the repeat never run it), and unreadable_test_files_of names a changed file
# whose test types could be missed.
changed_tests_of() {
  local f names=""
  while IFS= read -r f; do
    case $f in E2E/Tests/*.swift) [ -f "$f" ] && names="$names"$'\n'"$(test_names_in "$f")" ;; esac
  done <<< "$1"
  echo "$names" | grep -v '^$' | sort -u | paste -sd, -
}

# ported_tests_of: the tests the branch brings back by removing their entries from scripts/e2e-not-ported.txt (against
# the merge base with the base, committed or not), as a comma list. An entry is a test name, an area (the name up to its
# first dot) or a glob of names, as E2E= takes them; each removed entry that the list does not still hold is matched
# against every test name the E2E/Tests files declare. A porting branch repeats what it brings back like a changed test.
ported_tests_of() {
  local list=scripts/e2e-not-ported.txt sel name f names=""
  local removed kept
  removed=$(git diff "$fork" -- "$list" 2> /dev/null | sed -n 's/^-\([^-#[:space:]][^[:space:]]*\)[[:space:]].*$/\1/p')
  [ -n "$removed" ] || return 0
  kept=""
  [ ! -f "$list" ] || kept=$(sed -n 's/^[[:space:]]*\([^#[:space:]][^[:space:]]*\)[[:space:]].*$/\1/p' "$list")
  for f in E2E/Tests/*.swift; do [ -f "$f" ] && names="$names"$'\n'"$(test_names_in "$f")"; done
  while IFS= read -r sel; do
    [ -n "$sel" ] || continue
    printf '%s\n' "$kept" | grep -qxF -- "$sel" && continue
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      # shellcheck disable=SC2254
      if [ "$name" = "$sel" ] || [ "${name%%.*}" = "$sel" ]; then echo "$name"; else
        case $name in $sel) echo "$name" ;; esac
      fi
    done <<< "$names"
  done <<< "$removed" | sort -u | paste -sd, -
}

# unreadable_test_files_of <changed files, one per line>: the changed E2E/Tests files with a test type (a struct,
# class, enum or actor conforming to E2ETest) that changed_tests_of cannot name and that the full run would still run:
# none of a stored `let name = "<literal>"`, a `<Type>(name: "<literal>"` construction anywhere in the file, and
# `var selectedByNameOnly: Bool { true }` (a test the full run leaves out, so no FLAKY or repeat involves it). One file
# per line. The FLAKY tolerance and the repeat fail closed on such a file instead of missing its tests.
unreadable_test_files_of() {
  local f
  while IFS= read -r f; do
    case $f in E2E/Tests/*.swift)
      [ -f "$f" ] || continue
      awk -v FILE="$f" '
        { L[NR] = $0; ind[NR] = ($0 ~ /[^ \t]/) ? match($0, /[^ \t]/) - 1 : -1 }
        END {
          for (i = 1; i <= NR; i++) {
            if (L[i] !~ /^[ \t]*((final|private|fileprivate|public|internal) +)*(struct|class|enum|actor) +[A-Za-z0-9_]+ *:[^{]*(^|[^A-Za-z0-9_])E2ETest([^A-Za-z0-9_]|$)/) continue
            type = L[i]
            sub(/^[ \t]*((final|private|fileprivate|public|internal) +)*(struct|class|enum|actor) +/, "", type)
            sub(/[^A-Za-z0-9_].*$/, "", type)
            e = NR
            for (j = i + 1; j <= NR; j++) if (ind[j] >= 0 && ind[j] <= ind[i]) { e = j; break }
            ok = 0
            for (j = i; j <= e; j++) if (L[j] ~ /let name = "/ || L[j] ~ /selectedByNameOnly: Bool \{ true \}/) ok = 1
            # test_names_in reads a construction only for a type whose name ends in Test.
            for (j = 1; !ok && type ~ /Test$/ && j <= NR; j++) if (index(L[j], type "(name: \"")) ok = 1
            if (!ok) { print FILE; exit }
          }
        }' "$f"
      ;;
    esac
  done <<< "$1"
}

# union_of <comma list> <comma list>: both lists' names once each, sorted, as a comma list.
union_of() {
  printf '%s\n%s\n' "$(echo "$1" | tr ',' '\n')" "$(echo "$2" | tr ',' '\n')" | grep -v '^$' | sort -u | paste -sd, -
}

# callers_sample <changed tests, comma list> <cap>, rows `direct|fallback <symbols reached> <test>` on stdin (the output
# of scripts/e2e-affected.sh --callers): prints a note line (empty unless it sampled), then the comma list of tests to
# repeat. At most <cap> callers: all of them plus the changed tests. More: a stated sample, the changed tests (the
# tests the branch's own files declare) and each area's best caller (the one reached by the most changed symbols, a
# name-found one before a fallback one, ties by name; an area is the name before its first dot).
callers_sample() {
  local res
  res=$(awk -v changed="$1" -v cap="$2" '
    NF == 3 { n++; cls[n] = $1; cnt[n] = $2; nm[n] = $3 }
    END {
      k = split(changed, c, ",")
      for (i = 1; i <= k; i++) if (c[i] != "") sel[c[i]] = 1
      if (n <= cap) { for (i = 1; i <= n; i++) sel[nm[i]] = 1; print "" }
      else {
        for (i = 1; i <= n; i++) {
          area = nm[i]; sub(/\..*$/, "", area)
          rank = (cls[i] == "direct" ? 100000 : 0) + cnt[i]
          if (!(area in best) || rank > brank[area] || (rank == brank[area] && nm[i] < best[area])) { best[area] = nm[i]; brank[area] = rank }
        }
        na = 0
        for (a in best) { sel[best[a]] = 1; na++ }
        print "sampled: the best caller of each of " na " areas (of " n " tests that reach a changed harness symbol, over the cap of " cap ")"
      }
      for (t in sel) print t
    }')
  echo "$res" | sed -n 1p
  echo "$res" | sed 1d | sort -u | paste -sd, -
}

# flaky_verdict <changed tests, comma list> <e2e log>: whether a FLAKY full e2e may be gone past, on one line:
#   ok <names>      every `FLAKY <name>: failed then passed (...)` line names a test the branch neither adds nor
#                   changes (or a check one owns: the test name, or the longest test name and a dot before it);
#   fail <reason>   a FLAKY test the branch changes, a check no test owns (e2e.isolation, chromium.errors), or no
#                   FLAKY line to attribute: when in doubt, fail.
flaky_verdict() {
  local changed=$1 log=$2 all_tests
  all_tests=$(for f in E2E/Tests/*.swift; do [ -f "$f" ] && test_names_in "$f"; done | paste -sd, -)
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

# minus_of <comma list> <comma list>: the names of the first list that the second does not hold, sorted, as a comma list.
minus_of() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    n = split(b, bb, ","); for (i = 1; i <= n; i++) skip[bb[i]] = 1
    n = split(a, aa, ","); for (i = 1; i <= n; i++) if (aa[i] != "" && !(aa[i] in skip)) print aa[i]
  }' | sort -u | paste -sd, -
}

# package_suites_of <changed files, one per line>: one row `<package> <suite>` for every top level suite of each changed
# file under BowCore/Tests/ or BowWebKit/Tests/ that holds a test: a type or an extension declared at the left margin
# whose body (up to the next such declaration) has an @Test, or a type marked @Suite. A changed file with an @Test and no
# suite it can read prints `<package> ?<file>`, which the repeat fails on instead of missing it. Files with no @Test
# (support code, fixtures) and deleted files print nothing.
package_suites_of() {
  local f pkg
  while IFS= read -r f; do
    case $f in BowCore/Tests/*.swift) pkg=BowCore ;; BowWebKit/Tests/*.swift) pkg=BowWebKit ;; *) continue ;; esac
    [ -f "$f" ] || continue
    awk -v pkg="$pkg" -v file="$f" '
      function flush() { if (name != "" && (suite || test)) { if (!(name in seen)) { seen[name] = 1; print pkg " " name } found = 1 } name = ""; suite = 0; test = 0 }
      /^(@[A-Za-z]+(\([^)]*\))? +)*((public|internal|final|private|fileprivate|open) +)*(struct|class|actor|enum|extension) +[A-Za-z0-9_]+/ {
        flush()
        line = $0
        suite = (line ~ /@Suite/)
        sub(/^(@[A-Za-z]+(\([^)]*\))? +)*((public|internal|final|private|fileprivate|open) +)*(struct|class|actor|enum|extension) +/, "", line)
        sub(/[^A-Za-z0-9_].*$/, "", line)
        name = line
        next
      }
      /@Test/ { any = 1; if (name != "") test = 1 }
      END { flush(); if (any && !found) print pkg " ?" file }' "$f"
  done <<< "$1"
}

# Whether the branch needs a Release build: it touches what the Release app is built from. When the changed files
# cannot be listed, it builds, to be safe.
release_reason=""
docs_only=0
list_failed=""
if changed=$(CHECK_BASE=$base ./scripts/e2e-affected.sh --changed 2> /dev/null); then
  release_reason=$(echo "$changed" | grep -m1 '^\(App/\|E2E/\|BowCore/Sources/\|project\.yml$\)')
  # Docs only: at least one changed file, and every one is a *.md file or under spec/ (the landing's policy, and
  # e2e-affected.sh's "docs" mapping). Anything else, or no change at all, keeps the full run.
  if [ -n "$changed" ] && [ -z "$(echo "$changed" | grep -v '\.md$' | grep -v '^spec/')" ]; then docs_only=1; fi
else
  release_reason="the changed files could not be listed"
  list_failed="the changed files could not be listed (scripts/e2e-affected.sh --changed failed)"
  changed=""
fi

# The tests the branch adds or changes, the tests that reach a changed harness symbol, and the repeat set. Computed
# before the e2e, because a FLAKY full run is judged against the same list the repeat step uses.
changed_tests=""
callers_rows=""
callers_notes=""
unreadable=""
flaky_set=""
repeat_set=""
callers_set=""
repeat_note=""
package_rows=""
if [ "$docs_only" != 1 ] && [ -z "$list_failed" ]; then
  changed_tests=$(union_of "$(changed_tests_of "$changed")" "$(ported_tests_of)")
  unreadable=$(unreadable_test_files_of "$changed")
  if echo "$changed" | grep -q '^E2E/\(Harness\|Engine\)/'; then
    if callers_rows=$(CHECK_BASE=$base ./scripts/e2e-affected.sh --callers 2> "$out/callers.err"); then
      callers_notes=$(cat "$out/callers.err")
    else
      callers_rows=""
      list_failed="the tests reaching the changed harness symbols could not be found (scripts/e2e-affected.sh --callers failed)"
    fi
  fi
  callers_all=$(echo "$callers_rows" | awk 'NF == 3 { print $3 }' | paste -sd, -)
  flaky_set=$(union_of "$changed_tests" "$callers_all")
  # The changed tests repeat on their own (the full count); the callers are the rest, sampled over the cap, and repeat
  # fewer times because the branch did not touch them.
  sampled=$(echo "$callers_rows" | callers_sample "" "$callers_cap")
  repeat_set=$changed_tests
  callers_set=$(minus_of "$(echo "$sampled" | sed -n '2p')" "$changed_tests")
  repeat_note=$(echo "$sampled" | sed -n '1p')
  package_rows=$(package_suites_of "$changed")
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

# The tree this run checks (scripts/tree-key.sh: the HEAD tree, plus a digest of any uncommitted change), taken before
# verify so make check's record is compared with the source and not with what a build left behind.
tree_key=$(scripts/tree-key.sh 2> /dev/null || echo unknown)
reused_run=""

# reusable_check_pass <tree key>: when make check recorded a passing full e2e (selection all) on this tree key and its
# run folder is still there, prints the run's summary line and its folder (2 lines); prints nothing otherwise. The
# record is build/check-e2e-pass: tree key, selection, summary line, run folder. When in doubt, it prints nothing.
reusable_check_pass() {
  local stamp=build/check-e2e-pass key sel summary run
  [ -f "$stamp" ] && [ "$1" != unknown ] || return 0
  { read -r key; read -r sel; read -r summary; read -r run; } < "$stamp"
  [ "$key" = "$1" ] && [ "$sel" = all ] || return 0
  case $summary in *quarantined*) return 0 ;; "E2E: PASS"*) ;; *) return 0 ;; esac
  [ -n "$run" ] && [ -d "build/e2e/$run" ] || return 0
  printf '%s\n%s\n' "$summary" "$run"
}

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
    # make check's pass of the full e2e on this very tree stands in for the run (see reusable_check_pass).
    reused=""
    [ "${DONE_REUSE:-1}" = 0 ] || reused=$(reusable_check_pass "$tree_key")
    if [ -n "$reused" ]; then
      echo "== done: e2e (reused make check's pass on tree $tree_key, not run again)"
      e2e_line=$(echo "$reused" | sed -n 1p)
      reused_run=$(echo "$reused" | sed -n 2p)
      # check's record holds the app's summary line, which has no "; not ported N" (the wrapper adds that to the line
      # it prints and to results.json); the count comes from that run's results.json, as the block of a fresh run shows.
      case $e2e_line in *"; not ported "*) ;; *)
        reused_np=$(perl -MJSON::PP -e 'local $/; my $d = eval { decode_json(<STDIN>) }; my $n = ref $d eq "HASH" && ref $d->{notPorted} eq "ARRAY" ? scalar @{$d->{notPorted}} : 0; print $n' \
          < "build/e2e/$reused_run/results.json" 2> /dev/null)
        case $e2e_line in "E2E: PASS "*) [ "${reused_np:-0}" = 0 ] || e2e_line="$e2e_line; not ported $reused_np" ;; esac
        ;;
      esac
      step_status=0
    else
      echo "done: the full e2e runs in $e2e_shards shard(s) (DONE_E2E_SHARDS)"
      # In DONE_E2E_SHARDS shards (default 3), as the landing runs it; 1 runs it in one app.
      step e2e env E2E_SHARDS="$e2e_shards" make --no-print-directory e2e E2E=all
      e2e_line=$(grep '^E2E: ' "$out/e2e.log" | tail -1)
    fi
    flaky_lines=""
    if [ "$step_status" = 0 ]; then
      if [ -n "$reused" ]; then e2e="ok (reused make check's pass on tree $tree_key)"; else e2e=ok; fi
    else
      e2e="FAIL (exit $step_status)"
      failed=1
      # A FLAKY run (failed, then passed on the retry) goes on when every flaky test is outside this branch: not one
      # it adds or changes, and not one that reaches a changed harness symbol. When the branch's tests cannot be
      # told (the changed files cannot be listed, a changed test file names its tests in a form the list cannot
      # read), no flaky test is outside it, so the run fails.
      case $e2e_line in "E2E: FLAKY"*)
        if [ -n "$list_failed" ]; then flaky="fail FLAKY run with $list_failed"
        elif [ -n "$unreadable" ]; then flaky="fail FLAKY run with a changed test file whose tests the list cannot read: $(echo "$unreadable" | paste -sd, -)"
        else flaky=$(flaky_verdict "$flaky_set" "$out/e2e.log"); fi
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
[ -z "$reused_run" ] || full_run=$reused_run

# The tests the e2e left out as not ported yet (scripts/e2e-not-ported.txt, none on main) are in the full run's
# results.json. The repeats skip them by name, and their smoke padding counts only the tests left.
not_ported_set=""
not_ported_skipped=""
repeat_all_skipped=0
callers_all_skipped=0
if [ -n "$full_run" ] && [ -f "build/e2e/$full_run/results.json" ]; then
  not_ported_set=$(perl -MJSON::PP -e 'local $/; my $d = eval { decode_json(<STDIN>) }; print join(",", sort @{ref $d eq "HASH" && ref $d->{notPorted} eq "ARRAY" ? $d->{notPorted} : []})' \
    < "build/e2e/$full_run/results.json" 2> /dev/null)
fi
if [ -n "$not_ported_set" ]; then
  not_ported_skipped=$(minus_of "$(union_of "$repeat_set" "$callers_set")" "$(minus_of "$(union_of "$repeat_set" "$callers_set")" "$not_ported_set")")
  [ -z "$repeat_set" ] || [ -n "$(minus_of "$repeat_set" "$not_ported_set")" ] || repeat_all_skipped=1
  [ -z "$callers_set" ] || [ -n "$(minus_of "$callers_set" "$not_ported_set")" ] || callers_all_skipped=1
  repeat_set=$(minus_of "$repeat_set" "$not_ported_set")
  callers_set=$(minus_of "$callers_set" "$not_ported_set")
fi

# repeat_run <log name> <tests, comma list> <repeats> <description>: reruns the tests <repeats> times in
# DONE_REPEAT_SHARDS shards with the retry off, and sets run_result (the block's line) and run_lines (the REPEAT, E2E
# and note lines under it); a failure also sets failed. Fewer tests than shards would run as one shard per test, so a
# lone test would get no load: the smoke tests pad the selection as filler (e2e.sh drops a name listed twice).
run_result=""
run_lines=""
repeat_run() {
  local name=$1 tests=$2 n=$3 what=$4 selection n_tests desc summary verdict
  selection=$tests
  n_tests=$(echo "$tests" | tr ',' '\n' | grep -c .)
  [ "$n_tests" -ge "$repeat_shards" ] || selection="$tests,smoke"
  desc="$n repeats in $repeat_shards shards of $what"
  step "$name" env E2E_REPEAT="$n" E2E_SHARDS="$repeat_shards" make --no-print-directory e2e-run "E2E=$selection"
  run_lines=$(grep '^\(REPEAT \|E2E: \|note: \)' "$out/$name.log")
  # make exits 2 for any failure, so the summary line decides: PASS is the only pass, and a failure counts only when
  # every failing check belongs to a filler test (see repeat_gate).
  summary=$(grep '^E2E: ' "$out/$name.log" | tail -1)
  verdict=$(repeat_gate "$tests" "$n" "$summary" "$out/$name.log")
  case $verdict in
    pass)
      if [ "$step_status" = 0 ]; then run_result="ok ($desc)"; else
        run_result="FAIL (exit $step_status) ($desc)"
        failed=1
      fi
      ;;
    "filler "*)
      run_result="ok ($desc)"
      run_lines="$run_lines"$'\n'"note: ${verdict#filler }"
      ;;
    *)
      run_result="FAIL (${verdict#fail }) ($desc)"
      failed=1
      ;;
  esac
}

# package_repeat <rows `<package> <suite>`>: runs every suite DONE_PKG_REPEAT times, the build skipped (verify built the
# packages), and sets package_result. A run that fails, or that runs no test (a filter that matches nothing; the
# Swift Testing line `Test run with <n> tests` must say 1 or more), or a suite that cannot be read, fails and names
# the package, the suite and the run.
package_result=""
package_repeat() {
  local pkg suite run st ran_n what=""
  while read -r pkg suite; do
    [ -n "$pkg" ] || continue
    case $suite in \?*)
      package_result="FAIL ($pkg: cannot read the suites of ${suite#?}: an @Test outside a top level type or extension)"
      failed=1
      return
      ;;
    esac
    what="$what${what:+; }$pkg $suite"
    for run in $(seq 1 "$pkg_count"); do
      st=0
      swift test --skip-build --package-path "$pkg" --filter "\\.$suite/" < /dev/null > "$out/package.log" 2>&1 || st=$?
      ran_n=$(sed -n 's/.*Test run with \([0-9][0-9]*\) tests\{0,1\}.*/\1/p' "$out/package.log" | tail -1)
      if [ "$st" != 0 ] || [ "${ran_n:-0}" = 0 ]; then
        echo "== done: package tests, $pkg $suite run $run"
        tail -n 40 "$out/package.log"
        if [ "$st" != 0 ]; then package_result="FAIL ($pkg suite $suite failed on run $run of $pkg_count (exit $st))"; else
          package_result="FAIL ($pkg suite $suite ran no test on run $run of $pkg_count)"
        fi
        failed=1
        return
      fi
    done
  done <<< "$1"
  package_result="ok ($pkg_count runs of each: $what)"
}

# The tests the branch adds or changes (the names in each changed E2E/Tests file, found with
# scripts/e2e-affected.sh --changed) rerun DONE_REPEAT times in shards with the retry off: a new test that flakes shows
# here. The tests only a changed harness symbol reaches rerun DONE_REPEAT_CALLERS times, and the package suites the
# branch adds or changes DONE_PKG_REPEAT times each.
repeat="skip (the e2e did not pass)"
repeat_lines=""
callers_result="skip (the e2e did not pass)"
callers_lines=""
package="skip (the e2e did not pass)"
if [ "$docs_only" = 1 ]; then
  repeat="skip (docs only)"
  callers_result="skip (docs only)"
  package="skip (docs only)"
elif [ "$failed" = 0 ]; then
  if [ -n "$list_failed" ]; then
    repeat="FAIL ($list_failed)"
    callers_result="skip (the changed files could not be listed)"
    package="skip (the changed files could not be listed)"
    failed=1
  elif [ -n "$unreadable" ]; then
    repeat="FAIL (a changed test file names its tests in a form the list cannot read: $(echo "$unreadable" | paste -sd, -))"
    callers_result="skip (a changed test file could not be read)"
    package="skip (a changed test file could not be read)"
    failed=1
  else
    if [ -z "$package_rows" ]; then package="skip (no package test added or changed)"; else
      echo "== done: package tests"
      package_repeat "$package_rows"
      package=$package_result
    fi
    if [ "$failed" != 0 ]; then
      repeat="skip (the package test repeat failed)"
      callers_result="skip (the package test repeat failed)"
    elif [ -z "$repeat_set" ]; then
      if [ "$repeat_all_skipped" = 1 ]; then repeat="skip (every changed test is not ported yet)"; else
        repeat="skip (no e2e test added or changed)"
      fi
    else
      repeat_run repeat "$repeat_set" "$repeat_count" "$repeat_set"
      repeat=$run_result
      repeat_lines=$run_lines
    fi
    if [ "$failed" != 0 ]; then
      [ "$callers_result" != "skip (the e2e did not pass)" ] || callers_result="skip (a repeat failed)"
    elif [ -z "$callers_set" ]; then
      if [ "$callers_all_skipped" = 1 ]; then callers_result="skip (every test a changed harness symbol reaches is not ported yet)"; else
        callers_result="skip (no changed harness symbol reaches a test the branch does not change itself)"
      fi
    else
      n_callers=$(echo "$callers_rows" | awk 'NF == 3' | grep -c .)
      repeat_run callers "$callers_set" "$callers_count" "$(echo "$callers_set" | tr ',' '\n' | grep -c .) tests (reached through changed harness symbols: $n_callers found${repeat_note:+; $repeat_note}): $callers_set"
      callers_result=$run_result
      callers_lines=$run_lines
      [ -z "$callers_notes" ] || callers_lines="$callers_notes"$'\n'"$callers_lines"
    fi
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
[ -z "$not_ported_skipped" ] || echo "not ported yet, left out of the repeats: $not_ported_skipped"
echo "make release: $release"
echo "package tests, repeated: $package"
echo "changed tests, repeated: $repeat"
[ -z "$repeat_lines" ] || echo "$repeat_lines" | sed 's/^/  /'
echo "harness callers, repeated: $callers_result"
[ -z "$callers_lines" ] || echo "$callers_lines" | sed 's/^/  /'
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
