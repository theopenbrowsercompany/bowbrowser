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
