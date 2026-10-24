#!/bin/bash
# Tests scripts/done.sh in a throwaway git repository with a fake make: the report block of a passing run, a failed
# fetch, a failing verify (which skips the e2e and the release build) and a failing e2e, a branch behind origin/main
# (a warning with no conflict, a refusal naming the files with one, a refusal with no origin/main), the repeat of
# changed e2e tests, and the release build (run beside the e2e for an App/, E2E/, BowCore/Sources/ or project.yml
# change, skipped otherwise, failing the run when it fails). Takes a few seconds and runs no build or app.
set -u
# The settings done.sh and e2e-affected.sh read come from each case alone, never from the caller's environment.
unset DONE_BASE DONE_FETCH CHECK_BASE
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; failed=1; fi
}
has() { # has <description> <text> <needle>
  case $2 in *"$3"*) echo "ok   $1" ;; *)
    echo "FAIL $1: no '$3' in:"
    echo "$2"
    failed=1
    ;;
  esac
}

repo=$tmp/repo
mkdir -p "$repo/scripts" "$repo/Vendor/cef" "$tmp/bin"
cp scripts/done.sh scripts/e2e-affected.sh "$repo/scripts/"
# A fake make: verify and e2e print the lines the real ones end with, e2e makes the run folder and final.png.
cat > "$tmp/bin/make" << 'EOF'
#!/bin/bash
case "$*" in
  *lint*)
    echo "ran: lint" >> "$FAKE_LOG"
    [ "${FAKE_LINT:-0}" = 0 ] || exit 2
    ;;
  *guards*)
    echo "ran: guards" >> "$FAKE_LOG"
    ;;
  *bootstrap*)
    echo "ran: bootstrap" >> "$FAKE_LOG"
    ;;
  *verify*)
    echo "verify: lint ok 1s"
    if [ "${FAKE_VERIFY:-0}" = 0 ]; then echo "verify: PASS 4 parts in 1s"; else
      echo "verify: FAIL lint (1s)"
      exit 2
    fi
    ;;
  *e2e-run*)
    # The repeat of the changed tests: the repeat summary lines, and latest moves to a folder without final.png.
    echo "ran: E2E_REPEAT=$E2E_REPEAT E2E_SHARDS=$E2E_SHARDS $*" >> "$FAKE_LOG"
    mkdir -p build/e2e/20260101-2
    ln -sfn 20260101-2 build/e2e/latest
    n=$E2E_REPEAT
    case "${FAKE_REPEAT:-0}" in
      0) echo "E2E: PASS $n/$n repeats" ;;
      1) # a changed test fails once
        echo "REPEAT x.one $((n - 1))/$n"
        echo "FAIL x.one.check: it failed"
        echo "E2E: FAIL $((n - 1))/$n repeats passed; failed: repeat 3"
        exit 1
        ;;
      2) # only a filler test fails (make exits 2 for any failure)
        echo "REPEAT smoke.a $((n - 1))/$n"
        echo "FAIL smoke.a.check: it failed"
        echo "E2E: FAIL $((n - 1))/$n repeats passed; failed: repeat 3"
        exit 2
        ;;
      3) # a crash
        echo "E2E: CRASH 0/$n repeats passed; failed: repeat 1 (E2E: CRASH exit=139)"
        exit 4
        ;;
      4) # a filler test fails and a check no test owns fails
        echo "REPEAT smoke.a $((n - 1))/$n"
        echo "FAIL smoke.a.check: it failed"
        echo "FAIL chromium.errors: errors"
        echo "E2E: FAIL $((n - 1))/$n repeats passed; failed: repeat 3"
        exit 2
        ;;
      5) # a filler test fails on a check that does not start with the test's name
        echo "REPEAT smoke.a $((n - 1))/$n"
        echo "FAIL smoke.a_sidebar: it failed"
        echo "RESULT smoke.a fail seconds=1 checks=0/1"
        echo "E2E: FAIL $((n - 1))/$n repeats passed; failed: repeat 3"
        exit 2
        ;;
      6) # a changed test fails on a check named like the filler test, and the filler fails too
        echo "REPEAT smoke.a $((n - 1))/$n"
        echo "FAIL smoke.a.shared: it failed"
        echo "RESULT x.one fail seconds=1 checks=0/1"
        echo "FAIL smoke.a.check: it failed"
        echo "RESULT smoke.a fail seconds=1 checks=0/1"
        echo "E2E: FAIL $((n - 1))/$n repeats passed; failed: repeat 3"
        exit 2
        ;;
      8) # a changed test's quit check fails after its RESULT line said pass, then a filler test fails
        echo "REPEAT smoke.a $((n - 1))/$n"
        echo "RESULT x.one pass seconds=1 checks=1/1 quit=pending"
        echo "FAIL x.one.quit: it failed"
        echo "RESULT smoke.a fail seconds=1 checks=0/1"
        echo "E2E: FAIL $((n - 1))/$n repeats passed; failed: repeat 3"
        exit 2
        ;;
      9) # a test a changed harness helper reaches fails once
        echo "REPEAT c.call $((n - 1))/$n"
        echo "FAIL c.call.check: it failed"
        echo "E2E: FAIL $((n - 1))/$n repeats passed; failed: repeat 3"
        exit 1
        ;;
      7) # a filler test fails but make's summary is not a FAIL naming repeats
        echo "REPEAT smoke.a $((n - 1))/$n"
        echo "FAIL smoke.a.check: it failed"
        echo "E2E: FAIL killed"
        exit 2
        ;;
    esac
    ;;
  *release*)
    # The Release build, run beside the e2e: logged apart from "ran:" so the e2e counts stay as they are.
    echo "release: $*" >> "$FAKE_LOG"
    : > "$FAKE_LOG.release-started"
    echo "release build output"
    if [ "${FAKE_RELEASE:-0}" = 0 ]; then echo "release: no e2e harness in Bow.app"; else
      echo "error: Swift optimizer crashed"
      exit 2
    fi
    ;;
  *e2e*)
    echo "ran: $*" >> "$FAKE_LOG"
    if [ "${FAKE_E2E:-0}" = flaky ]; then
      # A run that failed, then passed on the retry: the FLAKY lines FAKE_NAMES lists, then FAKE_SUMMARY, exit 2
      # (make exits 2 for any failure; e2e.sh itself exits 3).
      mkdir -p build/e2e/20260101-1
      ln -sfn 20260101-1 build/e2e/latest
      echo png > build/e2e/20260101-1/final.png
      for n in ${FAKE_NAMES:-}; do echo "FLAKY $n: failed then passed (it failed)"; done
      echo "${FAKE_SUMMARY:-E2E: FLAKY 3/3 after retrying $FAKE_NAMES}"
      echo "make: *** [e2e] Error 3"
      exit 2
    fi
    if [ "${FAKE_BESIDE:-0}" = 1 ]; then
      # Waits up to 5 s for the release build to start: it only can when done.sh runs it beside the e2e.
      for _ in $(seq 50); do [ -e "$FAKE_LOG.release-started" ] && break; sleep 0.1; done
      if [ -e "$FAKE_LOG.release-started" ]; then echo "e2e: release beside" >> "$FAKE_LOG"; fi
    fi
    mkdir -p build/e2e/20260101-1
    ln -sfn 20260101-1 build/e2e/latest
    echo png > build/e2e/20260101-1/final.png
    if [ "${FAKE_E2E:-0}" = 0 ]; then echo "E2E: PASS 3/3"; else
      echo "E2E: FAIL 2/3"
      echo "make: *** [e2e] Error 1"
      exit 2
    fi
    ;;
esac
EOF
chmod +x "$tmp/bin/make"
g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }
git init -q "$repo"
printf "build/\n" > "$repo/.gitignore"
echo a > "$repo/a"
g add -A
g commit -qm one
g update-ref refs/remotes/origin/main HEAD
echo b > "$repo/b"
g add b
g commit -qm two

run() { # run <fake verify> <fake e2e> [fake repeat] [fake release]: the script's output and exit code
  : > "$tmp/log"
  rm -f "$tmp/log.release-started"
  (cd "$repo" && DONE_FETCH=${FETCH:-0} FAKE_RELEASE=${4:-0} FAKE_REPEAT=${3:-0} FAKE_VERIFY=$1 FAKE_E2E=$2 \
    FAKE_LOG=$tmp/log PATH="$tmp/bin:$PATH" ./scripts/done.sh 2>&1)
  echo "exit=$?"
}

out=$(run 0 0)
has "a branch holding origin/main passes" "$out" "done: PASS"
has "the block says verify's result line" "$out" "make verify: ok: verify: PASS 4 parts in 1s"
has "the block says the e2e result" "$out" "make e2e: ok"
has "the block says the e2e summary line" "$out" "e2e summary: E2E: PASS 3/3"
has "the block says the run folder" "$out" "e2e run folder: build/e2e/20260101-1"
has "the block says where final.png is" "$out" "/build/e2e/20260101-1/final.png"
has "the block has the tree hash" "$out" "tree: $(git -C "$repo" rev-parse 'HEAD^{tree}')"
has "the block has the diff stat" "$out" "b | 1 +"
has "the block names a clean worktree" "$out" "worktree: clean"
has "a passing run exits 0" "$out" "exit=0"
has "the full e2e ran" "$(cat "$tmp/log")" "E2E=all"
has "a branch touching no app source skips the release build" "$out" \
  "make release: skip (no change to App/, E2E/, BowCore/Sources/ or project.yml)"
check "a skipped release build runs no make release" "" "$(grep release: "$tmp/log")"
out=$(FETCH=1 run 0 0)
has "a failed fetch says so and goes on" "$out" "done: could not fetch origin (offline?)"
has "a failed fetch still passes" "$out" "done: PASS"

out=$(run 1 0)
has "a failing verify fails the run" "$out" "done: FAIL"
has "a failing verify is in the block" "$out" "make verify: FAIL (exit 2): verify: FAIL lint (1s)"
has "a failing verify skips the e2e" "$out" "make e2e: skip (verify failed)"
has "a failing run exits 1" "$out" "exit=1"

out=$(run 0 1)
has "a failing e2e is in the block" "$out" "make e2e: FAIL (exit 2)"
has "a failing e2e keeps its summary line, not make's" "$out" "e2e summary: E2E: FAIL 2/3"
has "a failing e2e exits 1" "$out" "exit=1"

rmdir "$repo/Vendor/cef"
rmdir "$repo/Vendor"
out=$(run 0 0)
has "a missing Vendor/cef runs make bootstrap" "$out" "== done: bootstrap"
mkdir -p "$repo/Vendor/cef"

# Behind origin/main: origin/main has a commit the branch lacks.
head_two=$(g rev-parse HEAD)
g checkout -q -b upstream HEAD~1
echo c > "$repo/c"
g add c
g commit -qm upstream
g update-ref refs/remotes/origin/main HEAD
g checkout -q "$head_two"
out=$(run 0 0)
warning="done: behind origin/main by 1 commit with no conflict; the landing rebases and reruns the checks"
has "a branch behind origin/main with no conflict warns" "$out" "$warning"
has "a branch behind origin/main with no conflict passes" "$out" "done: PASS"
has "a branch behind origin/main with no conflict exits 0" "$out" "exit=0"
has "a branch behind origin/main still runs the full e2e" "$(cat "$tmp/log")" "E2E=all"
check "the warning is the line before done: PASS" "$warning" "$(echo "$out" | grep -B1 '^done: PASS' | head -1)"
has "behind, the diff stat is against the merge base" "$out" \
  "git diff $(git -C "$repo" rev-parse --short HEAD~1) --stat (the merge base with origin/main):"
check "behind, the diff stat leaves out origin/main's own commits" "" "$(echo "$out" | grep ' c | ')"

# Behind with a conflict: origin/main and the branch both change b.
g checkout -q -b conflict "$head_two"
echo theirs > "$repo/b"
g commit -qam "main changes b"
g update-ref refs/remotes/origin/main HEAD
g checkout -q "$head_two"
echo ours > "$repo/b"
g commit -qam "the branch changes b"
out=$(run 0 0)
has "a branch that conflicts with origin/main is refused" "$out" "done: this branch conflicts with origin/main in:"
has "the refusal names the conflicted file" "$out" "  b"
has "a conflict refusal says to rebase" "$out" "rebase onto origin/main first."
has "a refusal exits 2" "$out" "exit=2"
check "a refusal runs nothing" "" "$(cat "$tmp/log")"
g checkout -q "$head_two"

g update-ref -d refs/remotes/origin/main
out=$(run 0 0)
has "no origin/main is refused" "$out" "Rebase onto origin/main first."

# Changed e2e tests: a branch that touches a test file reruns its tests 5 times after the full e2e.
g checkout -q -f "$head_two"
g update-ref refs/remotes/origin/main HEAD
out=$(run 0 0)
has "no changed e2e test, no repeat step" "$out" "changed tests, repeated: skip (no e2e test added or changed)"
check "no changed e2e test, no repeat run" "1" "$(grep -c ran: "$tmp/log")"
mkdir -p "$repo/E2E/Tests"
printf 'let name = "x.one"\nlet name = "x.two"\n' > "$repo/E2E/Tests/X.swift"
g add -A
g commit -qm "adds tests"
out=$(run 0 0)
has "a changed test file's tests are repeated, 20 times in 3 shards" "$out" \
  "changed tests, repeated: ok (20 repeats in 3 shards of x.one,x.two)"
has "the repeat ran 20 times in 3 shards via e2e-run, padded with smoke" "$(cat "$tmp/log")" \
  "E2E_REPEAT=20 E2E_SHARDS=3 --no-print-directory e2e-run E2E=x.one,x.two,smoke"
has "the block has the repeat summary" "$out" "E2E: PASS 20/20 repeats"
out=$(DONE_REPEAT=4 DONE_REPEAT_SHARDS=2 run 0 0)
has "DONE_REPEAT and DONE_REPEAT_SHARDS override the numbers" "$(cat "$tmp/log")" \
  "E2E_REPEAT=4 E2E_SHARDS=2 --no-print-directory e2e-run E2E=x.one,x.two"
check "two changed tests in 2 shards need no filler" "" "$(grep 'e2e-run.*smoke' "$tmp/log")"
has "the block says the overridden count" "$out" "ok (4 repeats in 2 shards of x.one,x.two)"
out=$(DONE_REPEAT=0 run 0 0)
has "a bad DONE_REPEAT is refused" "$out" "DONE_REPEAT must be a whole number of 2 or more"
has "a bad DONE_REPEAT exits 2" "$out" "exit=2"
out=$(DONE_REPEAT=1 run 0 0)
has "DONE_REPEAT=1 is refused (it would turn the retry back on)" "$out" "exit=2"
out=$(DONE_REPEAT_SHARDS=x run 0 0)
has "a bad DONE_REPEAT_SHARDS is refused" "$out" "exit=2"
out=$(run 0 0)
has "the block keeps the full run's folder" "$out" "e2e run folder: build/e2e/20260101-1"
has "the block keeps the full run's final.png" "$out" "/build/e2e/20260101-1/final.png"
has "a passing repeat passes" "$out" "done: PASS"
out=$(run 0 0 1)
has "a failing repeat of a changed test fails the run" "$out" "changed tests, repeated: FAIL (changed test x.one passed 19/20 repeats)"
has "a failing repeat shows its tally" "$out" "REPEAT x.one 19/20"
has "a failing repeat exits 1" "$out" "exit=1"
out=$(run 0 0 2)
has "a failing filler test does not fail the run" "$out" "changed tests, repeated: ok (20 repeats in 3 shards of x.one,x.two)"
has "a failing filler test prints a note naming it" "$out" "note: filler test failed (not part of the gate): smoke.a 19/20"
has "a failing filler test leaves done passing" "$out" "done: PASS"
has "a failing filler test exits 0" "$out" "exit=0"
out=$(run 0 0 3)
has "a crash in the repeats fails the run" "$out" "changed tests, repeated: FAIL (CRASH 0/20 repeats passed"
has "a crash exits 1" "$out" "exit=1"
out=$(run 0 0 4)
has "a failing check no test owns fails the run even with a filler failure" "$out" \
  "FAIL (check chromium.errors is a changed test's or no test's)"
out=$(run 0 0 5)
has "a filler test's check not named after it still belongs to it" "$out" "changed tests, repeated: ok (20 repeats in 3 shards of x.one,x.two)"
has "a filler test's other-named check leaves done passing" "$out" "done: PASS"
out=$(run 0 0 6)
has "a check printed before a changed test's RESULT line is the changed test's" "$out" \
  "FAIL (check smoke.a.shared is a changed test's or no test's)"
has "a changed test's other-named check exits 1" "$out" "exit=1"
out=$(run 0 0 8)
has "a changed test's check printed after its passing RESULT line is not excused by a later filler" "$out" \
  "FAIL (check x.one.quit is a changed test's or no test's)"
out=$(run 0 0 7)
has "a filler failure with a summary that does not name repeats fails the run" "$out" "changed tests, repeated: FAIL (FAIL killed)"
# Three changed tests fill the 3 shards: no smoke padding.
printf 'let name = "x.one"\nlet name = "x.two"\nlet name = "x.three"\n' > "$repo/E2E/Tests/X.swift"
g commit -qam "a third test"
out=$(run 0 0)
has "as many changed tests as shards need no filler" "$(cat "$tmp/log")" \
  "E2E_REPEAT=20 E2E_SHARDS=3 --no-print-directory e2e-run E2E=x.one,x.three,x.two"
out=$(run 0 1)
has "a failing e2e skips the repeat" "$out" "changed tests, repeated: skip (the e2e did not pass)"

# A FLAKY full e2e (failed, then passed on the retry): gone past only when every flaky test is outside the branch.
g checkout -q -f "$head_two"
g update-ref refs/remotes/origin/main HEAD
mkdir -p "$repo/E2E/Tests"
printf 'let name = "y.other"\nlet name = "y.other.deep"\n' > "$repo/E2E/Tests/Y.swift"
g add -A
g commit -qm "an untouched test file"
g update-ref refs/remotes/origin/main HEAD
printf 'let name = "x.one"\nlet name = "x.two"\n' > "$repo/E2E/Tests/X.swift"
g add -A
g commit -qm "adds tests"
out=$(FAKE_NAMES="y.other" run 0 flaky)
has "a FLAKY test the branch does not change passes" "$out" "done: PASS"
has "a FLAKY test outside the branch is named in the e2e line" "$out" \
  "make e2e: ok (FLAKY outside this branch, reported: y.other)"
has "a FLAKY test outside the branch keeps its FLAKY line in the block" "$out" \
  "  FLAKY y.other: failed then passed (it failed)"
has "a FLAKY test outside the branch keeps the summary line" "$out" "e2e summary: E2E: FLAKY 3/3 after retrying y.other"
has "a FLAKY test outside the branch still runs the repeat" "$out" \
  "changed tests, repeated: ok (20 repeats in 3 shards of x.one,x.two)"
has "a FLAKY test outside the branch exits 0" "$out" "exit=0"
check "done: PASS is the last line" "done: PASS|exit=0" "$(echo "$out" | tail -n 2 | paste -sd'|' -)"
out=$(FAKE_NAMES="y.other.deep y.other.quit" run 0 flaky)
has "FLAKY checks of an untouched test pass" "$out" "reported: y.other.deep, y.other.quit"
has "FLAKY checks of an untouched test exit 0" "$out" "exit=0"
out=$(FAKE_NAMES="y.other" FAKE_SUMMARY="E2E: FLAKY retried tests passed 1/1 after retrying y.other (the first attempt printed no total)" run 0 flaky)
has "the FLAKY summary of a retried subset passes too" "$out" "done: PASS"
out=$(FAKE_NAMES="y.other" FAKE_SUMMARY="E2E: FLAKY 3 after retrying y.other" run 0 flaky)
has "the FLAKY summary with no total passes too" "$out" "done: PASS"
out=$(FAKE_NAMES="x.one" run 0 flaky)
has "a FLAKY test the branch changes fails" "$out" "make e2e: FAIL (exit 2): FLAKY test this branch changes: x.one"
has "a FLAKY changed test skips the repeat" "$out" "changed tests, repeated: skip (the e2e did not pass)"
has "a FLAKY changed test exits 1" "$out" "exit=1"
out=$(FAKE_NAMES="x.one.quit" run 0 flaky)
has "a FLAKY check a changed test owns fails" "$out" "FLAKY test this branch changes: x.one.quit"
out=$(FAKE_NAMES="y.other x.two" run 0 flaky)
has "one changed test among FLAKY ones fails" "$out" "FLAKY test this branch changes: x.two"
out=$(FAKE_NAMES="e2e.isolation" run 0 flaky)
has "a FLAKY run wide check fails" "$out" "make e2e: FAIL (exit 2): FLAKY check no test owns: e2e.isolation"
out=$(FAKE_NAMES="chromium.errors" run 0 flaky)
has "a FLAKY chromium.errors fails" "$out" "FLAKY check no test owns: chromium.errors"
out=$(FAKE_NAMES="z.unknown" run 0 flaky)
has "a FLAKY check no test owns fails" "$out" "FLAKY check no test owns: z.unknown"
out=$(FAKE_NAMES="" FAKE_SUMMARY="E2E: FLAKY the run" run 0 flaky)
has "a FLAKY summary with no FLAKY lines fails" "$out" "make e2e: FAIL (exit 2): FLAKY with no FLAKY lines"
has "a FLAKY summary with no FLAKY lines exits 1" "$out" "exit=1"
out=$(run 0 1)
has "a real E2E: FAIL still fails" "$out" "make e2e: FAIL (exit 2)"
has "a real E2E: FAIL is not excused" "$out" "done: FAIL"
out=$(FAKE_NAMES="y.other" FAKE_SUMMARY="E2E: FAIL 2/3" run 0 flaky)
has "FLAKY lines under a FAIL summary still fail" "$out" "make e2e: FAIL (exit 2)"
out=$(FAKE_NAMES="y.other" FAKE_SUMMARY="E2E: CRASH exit=139" run 0 flaky)
has "FLAKY lines under a CRASH summary still fail" "$out" "make e2e: FAIL (exit 2)"

# A changed test that extends an unchanged one: tabs.close is untouched, tabs.close.all is changed, and the FLAKY tests
# are judged by the longest test name they continue. e2e.isolation and chromium.errors are run wide checks even when a
# test file declares those names.
g checkout -q -f "$head_two"
g update-ref refs/remotes/origin/main HEAD
mkdir -p "$repo/E2E/Tests"
printf 'struct CloseTest: E2ETest {\n    let name = "tabs.close"\n}\nstruct IsoTest: E2ETest {\n    let name = "e2e.isolation"\n}\nstruct ErrTest: E2ETest {\n    let name = "chromium.errors"\n}\n' > "$repo/E2E/Tests/Close.swift"
g add -A
g commit -qm "an untouched tabs.close"
g update-ref refs/remotes/origin/main HEAD
printf 'struct CloseAllTest: E2ETest {\n    let name = "tabs.close.all"\n}\n' > "$repo/E2E/Tests/CloseAll.swift"
g add -A
g commit -qm "adds tabs.close.all"
out=$(FAKE_NAMES="tabs.close.all.quit" run 0 flaky)
has "a FLAKY check of a changed test that extends an unchanged one fails" "$out" \
  "FLAKY test this branch changes: tabs.close.all.quit"
out=$(FAKE_NAMES="tabs.close.all" run 0 flaky)
has "a FLAKY changed test that extends an unchanged one fails" "$out" "FLAKY test this branch changes: tabs.close.all"
out=$(FAKE_NAMES="tabs.close.quit" run 0 flaky)
has "a FLAKY check of the unchanged test it extends passes" "$out" "reported: tabs.close.quit"
has "a FLAKY check of the unchanged test it extends exits 0" "$out" "exit=0"
out=$(FAKE_NAMES="tabs.close" run 0 flaky)
has "the unchanged test itself passes too" "$out" "done: PASS"
out=$(FAKE_NAMES="e2e.isolation" run 0 flaky)
has "e2e.isolation fails even when a test file declares that name" "$out" "FLAKY check no test owns: e2e.isolation"
out=$(FAKE_NAMES="chromium.errors" run 0 flaky)
has "chromium.errors fails even when a test file declares that name" "$out" "FLAKY check no test owns: chromium.errors"

# A changed test file that names a test any other way than `let name = "<literal>"` (a constructor, `var name`) fails
# closed: the FLAKY tolerance and the repeat cannot tell its tests, so a plain pass fails on the repeat and a FLAKY run
# fails.
g checkout -q -f "$head_two"
g update-ref refs/remotes/origin/main HEAD
mkdir -p "$repo/E2E/Tests"
printf 'struct NamedTest: E2ETest {\n    let name: String\n    init() { name = "n.one" }\n}\nstruct OkTest: E2ETest {\n    let name = "ok.one"\n}\n' > "$repo/E2E/Tests/Named.swift"
g add -A
g commit -qm "a test named through an initializer"
out=$(FAKE_NAMES="y.other" run 0 flaky)
has "a FLAKY run with a test named through an initializer fails" "$out" \
  "make e2e: FAIL (exit 2): FLAKY run with a changed test file whose tests the list cannot read: E2E/Tests/Named.swift"
out=$(run 0 0)
has "a pass with a test named through an initializer fails the repeat" "$out" \
  "changed tests, repeated: FAIL (a changed test file names its tests in a form the list cannot read: E2E/Tests/Named.swift)"
has "a test named through an initializer exits 1" "$out" "exit=1"

# The forms real tests use: one type constructed once per name (the popups tests) is read, and a name computed in code
# belongs to a selectedByNameOnly test that the full run never runs, so neither fails closed.
g checkout -q -f "$head_two"
g update-ref refs/remotes/origin/main HEAD
mkdir -p "$repo/E2E/Tests"
printf 'struct CtorTest: E2ETest {\n    let name: String\n    init(name: String) { self.name = name }\n}\nstruct SlowTest: E2ETest {\n    var name: String { "slow." + "one" }\n    var selectedByNameOnly: Bool { true }\n}\nlet ctors = [CtorTest(name: "ctor.one"), CtorTest(name: "ctor.two")]\n' > "$repo/E2E/Tests/Ctor.swift"
g add -A
g commit -qm "tests named through a constructor and by name only"
out=$(run 0 0)
has "tests named through a constructor are repeated" "$(cat "$tmp/log")" "E2E=ctor.one,ctor.two,smoke"
has "a by-name-only test with a computed name does not fail the run" "$out" "done: PASS"
out=$(FAKE_NAMES="ctor.one" run 0 flaky)
has "a FLAKY test named through a constructor fails" "$out" "FLAKY test this branch changes: ctor.one"

# A construction of a type that does not end in Test is not read by the list, so it counts as unreadable.
g checkout -q -f "$head_two"
g update-ref refs/remotes/origin/main HEAD
mkdir -p "$repo/E2E/Tests"
printf 'struct OddCase: E2ETest {\n    let name: String\n    init(name: String) { self.name = name }\n}\nlet odd = [OddCase(name: "odd.one")]\n' > "$repo/E2E/Tests/Odd.swift"
g add -A
g commit -qm "a test type constructed by a name the list does not read"
out=$(run 0 0)
has "a construction of a type not ending in Test fails the repeat" "$out" \
  "a changed test file names its tests in a form the list cannot read: E2E/Tests/Odd.swift"

# The changed files cannot be listed (scripts/e2e-affected.sh --changed exits 3): no FLAKY test is known to be outside
# the branch, and the repeat cannot tell its tests.
g checkout -q -f "$head_two"
g update-ref refs/remotes/origin/main HEAD
printf '#!/bin/bash\necho "e2e-affected: git diff failed" >&2\nexit 3\n' > "$repo/scripts/e2e-affected.sh"
out=$(FAKE_NAMES="y.other" run 0 flaky)
has "a FLAKY run fails when the changed files cannot be listed" "$out" \
  "make e2e: FAIL (exit 2): FLAKY run with the changed files could not be listed"
has "a FLAKY run with no file list exits 1" "$out" "exit=1"
out=$(run 0 0)
has "a pass fails the repeat when the changed files cannot be listed" "$out" \
  "changed tests, repeated: FAIL (the changed files could not be listed"
cp scripts/e2e-affected.sh "$repo/scripts/e2e-affected.sh"
g checkout -q -f "$head_two"

# A changed harness helper: the tests that reach a changed symbol are repeated, and a FLAKY one among them fails.
mkdir -p "$repo/E2E/Harness" "$repo/E2E/Tests"
printf 'enum Hlp {\n    static func tap(selector: String) {\n        print(selector)\n    }\n    static func other() {\n        print("o")\n    }\n}\n' > "$repo/E2E/Harness/Hlp.swift"
printf 'struct CallsTapTest: E2ETest {\n    let name = "c.call"\n    func run() { Hlp.tap(selector: "a") }\n}\nstruct CallsTapAgainTest: E2ETest {\n    let name = "c.zzz"\n    func run() { Hlp.tap(selector: "b") }\n}\nstruct CallsOtherTest: E2ETest {\n    let name = "d.other"\n    let tags = ["smoke"]\n    func run() { Hlp.other() }\n}\nstruct NoCallTest: E2ETest {\n    let name = "e.none"\n}\n' > "$repo/E2E/Tests/Calls.swift"
g add -A
g commit -qm "a harness helper and its callers"
g update-ref refs/remotes/origin/main HEAD
sed -i '' 's/print(selector)/print(selector, 1)/' "$repo/E2E/Harness/Hlp.swift"
g commit -qam "changes tap's body"
out=$(run 0 0)
has "a changed harness function repeats the tests that call it" "$(cat "$tmp/log")" "E2E=c.call,c.zzz,smoke"
has "a changed harness function is reported with its callers" "$out" "callers: changed symbols: tap(selector:"
has "the block says how many callers there are" "$out" "reached through changed harness symbols: 2 found"
check "a changed harness function leaves out the tests that do not call it" "" "$(grep "e2e-run.*\(d.other\|e.none\)" "$tmp/log")"
has "the repeat of a harness caller passes" "$out" "done: PASS"
out=$(FAKE_NAMES="c.call.quit" run 0 flaky)
has "a FLAKY test a changed harness function reaches fails" "$out" "FLAKY test this branch changes: c.call.quit"
out=$(FAKE_NAMES="d.other" run 0 flaky)
has "a FLAKY test no changed harness function reaches passes" "$out" "reported: d.other"
out=$(run 0 0 9)
has "a failing harness caller fails the run" "$out" "changed tests, repeated: FAIL (changed test c.call passed 19/20 repeats)"
# A name searched in too many test files falls back to the smoke tests and the areas that call the changed file.
out=$(CALLERS_COMMON=1 run 0 0)
has "a too common name says so and names the fallback" "$out" "callers: too common to search by name: tap(selector: (1 test files)"
has "a too common name adds the smoke tests" "$(cat "$tmp/log")" "d.other"
has "a too common name adds the areas calling the changed file" "$(cat "$tmp/log")" "c.call"
# More callers than the cap are sampled, and the block says so.
out=$(DONE_REPEAT_CAP=1 run 0 0)
has "callers over the cap are sampled and the block says so" "$out" "sampled: the best caller of each of 1 areas (of 2 tests"
check "a sample repeats the best caller of an area, not its other callers" "ran: E2E_REPEAT=20 E2E_SHARDS=3 --no-print-directory e2e-run E2E=c.call,smoke" "$(grep e2e-run "$tmp/log")"
sed -i '' 's/print("o")/print("o", 1)/' "$repo/E2E/Harness/Hlp.swift"
g commit -qam "changes other too"
out=$(run 0 0)
has "two changed harness functions repeat both callers" "$(cat "$tmp/log")" "E2E=c.call,c.zzz,d.other"
g update-ref refs/remotes/origin/main HEAD
echo "// only a comment" >> "$repo/E2E/Harness/Hlp.swift"
g commit -qam "a comment in the helper"
out=$(run 0 0)
has "a comment only change in the harness reaches no test" "$out" "changed tests, repeated: skip (no e2e test added or changed)"

# A changed harness symbol whose search finds no test never gives an empty repeat. Scenario A: the only harness caller
# is private and no test names it, the test calls the public member two levels up. Scenario B: the only caller is a
# member no test calls, so the smoke tests are the fallback. The ResultObserver case: a change in C++ code after an
# @end is not credited to the Objective-C method before it.
mkdir -p "$repo/E2E/Engine"
printf 'extension Hlp {\n    static func dispatchDeep() {\n        print("d")\n    }\n    private static func sendDeep() {\n        dispatchDeep()\n    }\n    static func pressDeep() {\n        sendDeep()\n    }\n}\n' > "$repo/E2E/Harness/Chain.swift"
printf 'struct DeepTest: E2ETest {\n    let name = "f.deep"\n    func run() { Hlp.pressDeep() }\n}\n' > "$repo/E2E/Tests/Deep.swift"
printf '@implementation Session\n- (void)callThing:(id)x {\n  NSLog(@"c");\n}\n@end\n' > "$repo/E2E/Engine/Session.mm"
printf 'enum Probe {\n    static func devThing() {\n        Session.callThing(1)\n    }\n}\n' > "$repo/E2E/Harness/Probe.swift"
printf '@interface Obs\n- (void)detached;\n@end\n\nnamespace {\nclass ResultObserver {\n public:\n  void run() {\n    int x = 1;\n  }\n};\n}\n\n@implementation Obs\n- (void)detached {\n  NSLog(@"d");\n}\n@end\n' > "$repo/E2E/Engine/Observer.mm"
printf 'struct ObsTest: E2ETest {\n    let name = "g.obs"\n    func run() { obs.detached() }\n}\n' > "$repo/E2E/Tests/Obs.swift"
g add -A
g commit -qm "private chains and an Objective-C++ file"
g update-ref refs/remotes/origin/main HEAD
sed -i '' 's/print("d")/print("dd")/' "$repo/E2E/Harness/Chain.swift"
g commit -qam "changes dispatchDeep's body"
out=$(run 0 0)
has "a change whose callers are private repeats the test two levels up" "$(cat "$tmp/log")" "E2E=f.deep,smoke"
has "the block counts the test two levels up" "$out" "reached through changed harness symbols: 1 found"
g update-ref refs/remotes/origin/main HEAD
sed -i '' 's/NSLog(@"c")/NSLog(@"cc")/' "$repo/E2E/Engine/Session.mm"
g commit -qam "changes callThing"
out=$(run 0 0)
has "a changed symbol no test reaches repeats the smoke tests, not nothing" "$(cat "$tmp/log")" "E2E=d.other,smoke"
has "the block says the symbol reaches no test" "$out" "callThing (no test reaches it within 4 levels of callers)"
g update-ref refs/remotes/origin/main HEAD
sed -i '' 's/int x = 1;/int x = 2;/' "$repo/E2E/Engine/Observer.mm"
g commit -qam "changes C++ code after an @end"
out=$(run 0 0)
check "a change in C++ code is not credited to the method before it" "" "$(grep "e2e-run.*g.obs" "$tmp/log")"
has "a change in C++ code takes the fallback" "$out" "changed lines outside any Objective-C method body"

# The Release build: a branch touching App/ (or E2E/, BowCore/Sources/, project.yml) builds Release beside the e2e.
g checkout -q -f "$head_two"
g update-ref refs/remotes/origin/main HEAD
mkdir -p "$repo/App/UI"
echo x > "$repo/App/UI/View.swift"
g add -A
g commit -qm "changes the app"
out=$(FAKE_BESIDE=1 run 0 0)
has "an App/ change runs make release" "$(cat "$tmp/log")" "release: --no-print-directory release"
has "the release build runs while the e2e runs" "$(cat "$tmp/log")" "e2e: release beside"
has "the block says the release result" "$out" "make release: ok (App/UI/View.swift)"
check "the release output follows the e2e's" "E2E: PASS 3/3|release build output" \
  "$(echo "$out" | grep '^\(E2E: PASS 3/3\|release build output\)$' | paste -sd'|' -)"
has "a passing release build passes" "$out" "done: PASS"
out=$(run 0 0 0 1)
has "a failing release build is in the block" "$out" "make release: FAIL (exit 2) (App/UI/View.swift)"
has "a failing release build shows its output" "$out" "error: Swift optimizer crashed"
has "a failing release build fails the run" "$out" "done: FAIL"
has "a failing release build exits 1" "$out" "exit=1"
has "a failing release build leaves the e2e result" "$out" "make e2e: ok"
out=$(run 1 0)
has "a failing verify skips the release build" "$out" "make release: skip (verify did not pass)"
check "a failing verify runs no make release" "" "$(grep release: "$tmp/log")"
for path in E2E/Harness/H.swift BowCore/Sources/BowCore/C.swift project.yml; do
  g checkout -q -f "$head_two"
  mkdir -p "$repo/$(dirname "$path")"
  echo x > "$repo/$path"
  out=$(run 0 0)
  has "an uncommitted $path change runs make release" "$out" "make release: ok ($path)"
  rm "$repo/$path"
done
g checkout -q -f "$head_two"
mkdir -p "$repo/BowCore/Tests"
echo x > "$repo/BowCore/Tests/T.swift"
out=$(run 0 0)
has "a BowCore test change alone skips the release build" "$out" "make release: skip"
rm -rf "$repo/BowCore"

# Docs only: a branch that changes only *.md files and spec/ runs lint and guards, and no bootstrap, verify, e2e,
# release build or repeat; anything else keeps the full run.
g checkout -q -f "$head_two"
g update-ref refs/remotes/origin/main HEAD
mkdir -p "$repo/spec/area" "$repo/docs"
echo x > "$repo/spec/area/spec.txt"
echo x > "$repo/docs/note.md"
g add -A
g commit -qm "docs"
rmdir "$repo/Vendor/cef"
rmdir "$repo/Vendor"
out=$(run 0 0)
log=$(cat "$tmp/log")
has "docs only: the block says so" "$out" "docs only: the branch changes only *.md files and spec/"
has "docs only: lint ran" "$out" "make lint: ok"
has "docs only: guards ran" "$out" "make guards: ok"
check "docs only: only lint and guards ran" "ran: lint|ran: guards" "$(echo "$log" | paste -sd'|' -)"
has "docs only: bootstrap says skip" "$out" "bootstrap: skip (docs only)"
has "docs only: verify says skip" "$out" "make verify: skip (docs only)"
has "docs only: e2e says skip" "$out" "make e2e: skip (docs only)"
has "docs only: release says skip" "$out" "make release: skip (docs only)"
has "docs only: repeat says skip" "$out" "changed tests, repeated: skip (docs only)"
has "docs only: passes" "$out" "done: PASS"
has "docs only: exits 0" "$out" "exit=0"
out=$(FAKE_LINT=1 run 0 0)
has "docs only: a failing lint fails the run" "$out" "make lint: FAIL (exit 2)"
has "docs only: a failing lint exits 1" "$out" "exit=1"
has "docs only: a failing lint still runs guards" "$(cat "$tmp/log")" "ran: guards"
mkdir -p "$repo/Vendor/cef"
echo x > "$repo/README.md"
out=$(run 0 0)
has "docs only: an uncommitted *.md file is docs too" "$out" "make e2e: skip (docs only)"
echo x > "$repo/scripts/tool.sh" 2> /dev/null
out=$(run 0 0)
has "an uncommitted script change keeps the full run" "$out" "make e2e: ok"
has "an uncommitted script change runs verify" "$out" "make verify: ok"
check "an uncommitted script change is not docs only" "" "$(echo "$out" | grep '^docs only:')"
rm -f "$repo/scripts/tool.sh" "$repo/README.md"
mkdir -p "$repo/E2E/Fixtures/app"
echo x > "$repo/E2E/Fixtures/app/page.html"
out=$(run 0 0)
has "a fixture change next to docs keeps the full run" "$out" "make e2e: ok"
rm -rf "$repo/E2E"

if [ "$failed" = 0 ]; then echo "done self test: ok"; else
  echo "done self test: FAIL"
  exit 1
fi
