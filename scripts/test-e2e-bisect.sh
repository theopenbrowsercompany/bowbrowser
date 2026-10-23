#!/bin/bash
# Tests scripts/e2e-bisect.sh in a throwaway git repository with a planted culprit commit: it finds the culprit,
# passes the test name and --repeat to every step, skips a commit whose step cannot run (125) and still finds the
# culprit, reports no culprit when every candidate is skipped, refuses bad usage (64), removes its scratch worktree
# and bisect state however it ends (a found culprit, a failed bootstrap, no culprit), and maps the last `E2E:` line
# of a fake `make e2e` to git's exit codes (pass 0, FAIL, TIMEOUT or CRASH 1, ERROR or no line 125). The step
# command and the bootstrap are replaced through environment variables: no build and no app run, a few seconds.
set -u
cd "$(dirname "$0")/.." || exit 1
script=$PWD/scripts/e2e-bisect.sh
unset BOW_BISECT_REPO BOW_BISECT_BOOTSTRAP BOW_BISECT_STEP BOW_BISECT_TEST BOW_BISECT_REPEAT

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

# The repository: c1 c2 c3 c4 c5 c6, each a commit changing a file; c4 plants "broken" in state.
repo=$tmp/repo
mkdir -p "$repo"
g() { git -C "$repo" -c user.name=t -c user.email=t@example.com "$@"; }
g init -q
for i in 1 2 3 4 5 6; do
  echo "$i" > "$repo/n"
  if [ "$i" -ge 4 ]; then echo broken > "$repo/state"; else echo ok > "$repo/state"; fi
  g add -A
  g commit -q -m "c$i"
done
good=$(g rev-parse HEAD~5)
bad=$(g rev-parse HEAD)
culprit=$(g rev-parse HEAD~2)

# run <args...>: the script on the repository, output in $tmp/out, echoes the exit status.
run() {
  BOW_BISECT_REPO=$repo BOW_BISECT_BOOTSTRAP=${BOOT-true} BOW_BISECT_STEP=$STEP "$script" "$@" > "$tmp/out" 2>&1
  echo $?
}
leftovers() { # leftovers: scratch worktrees or bisect state left in the repository
  local n
  n=$(g worktree list | wc -l | tr -d ' ')
  local dirs
  dirs=$(ls "$repo/.claude/worktrees" 2> /dev/null | wc -l | tr -d ' ')
  echo "worktrees=$n dirs=$dirs bisect=$([ -e "$repo/.git/BISECT_LOG" ] && echo yes || echo no)"
}
clean="worktrees=1 dirs=0 bisect=no"

# 1 Finds the planted culprit and says so.
STEP='grep -qx ok state'
check "finds the culprit: exit 0" 0 "$(run t.test "$good" "$bad")"
has "finds the culprit: names it" "$(cat "$tmp/out")" "culprit: $(g log -1 --format='%h %s' "$culprit")"
check "finds the culprit: no worktree or bisect state left" "$clean" "$(leftovers)"

# 2 The test name and --repeat reach every step; the default repeat is 1.
STEP='echo "$BOW_BISECT_TEST $BOW_BISECT_REPEAT" >> '$tmp'/seen; grep -qx ok state'
rm -f "$tmp/seen"
check "--repeat: exit 0" 0 "$(run --repeat 3 'tabs.*' "$good" "$bad")"
check "--repeat: every step got the test and 3" "tabs.* 3" "$(sort -u "$tmp/seen")"
rm -f "$tmp/seen"
run 'a.b' "$good" "$bad" > /dev/null
check "default repeat is 1" "a.b 1" "$(sort -u "$tmp/seen")"

# 3 A commit that cannot be tested (125) is skipped and the culprit is still found.
STEP='[ "$(cat n)" = 2 ] && exit 125; grep -qx ok state'
check "skipped commit: exit 0" 0 "$(run t.test "$good" "$bad")"
has "skipped commit: culprit named" "$(cat "$tmp/out")" "culprit: $(g log -1 --format='%h %s' "$culprit")"
check "skipped commit: nothing left" "$clean" "$(leftovers)"

# 4 Every candidate skipped: no culprit, exit 1, the worktree is still removed.
STEP='case $(cat n) in 1) exit 0 ;; 6) exit 1 ;; *) exit 125 ;; esac'
check "no culprit: exit 1" 1 "$(run t.test "$good" "$bad")"
has "no culprit: says so" "$(cat "$tmp/out")" "no culprit found"
check "no culprit: nothing left" "$clean" "$(leftovers)"

# 4b The endpoints are tested: a test passing on <bad>, or failing on <good>, is refused instead of blaming <bad>.
STEP='true'
check "test passes on bad: exit 1" 1 "$(run t.test "$good" "$bad")"
has "test passes on bad: says so" "$(cat "$tmp/out")" "does not fail on <bad>"
STEP='false'
check "test fails on good: exit 1" 1 "$(run t.test "$good" "$bad")"
has "test fails on good: says so" "$(cat "$tmp/out")" "does not pass on <good>"
check "endpoint checks: nothing left" "$clean" "$(leftovers)"

# 5 A failing bootstrap ends the run with exit 1 and removes the worktree.
STEP='true'
BOOT=false
check "bootstrap failure: exit 1" 1 "$(run t.test "$good" "$bad")"
has "bootstrap failure: says so" "$(cat "$tmp/out")" "bootstrap failed"
check "bootstrap failure: nothing left" "$clean" "$(leftovers)"
BOOT=true

# 6 Bad usage exits 64 and makes no worktree.
check "good not older than bad: exit 64" 64 "$(run t.test "$bad" "$good")"
check "same commit: exit 64" 64 "$(run t.test "$bad" "$bad")"
check "unknown commit: exit 64" 64 "$(run t.test nope "$bad")"
check "missing argument: exit 64" 64 "$(run t.test "$good")"
check "bad --repeat: exit 64" 64 "$(run --repeat 0 t.test "$good" "$bad")"
check "unknown option: exit 64" 64 "$(run --nope t.test "$good" "$bad")"
check "usage errors: nothing left" "$clean" "$(leftovers)"

# 7 The real step maps the last E2E line of make e2e to git's exit codes (a fake make; no build, no app).
fake=$tmp/bin
mkdir -p "$fake"
cat > "$fake/make" << 'EOF'
#!/bin/bash
echo "make $*" >> "$FAKE_MAKE_LOG"
[ "$1" != bootstrap ] || exit "${FAKE_BOOTSTRAP_EXIT:-0}"
echo "PASS earlier.check"
[ -z "${FAKE_E2E_LINE:-}" ] || echo "$FAKE_E2E_LINE"
exit "${FAKE_MAKE_EXIT:-0}"
EOF
chmod +x "$fake/make"
step() { # step <line> <make exit>: the exit status of --step with that fake make
  (
    cd "$repo" || exit 99
    FAKE_E2E_LINE=$1 FAKE_MAKE_EXIT=$2 FAKE_MAKE_LOG=$tmp/make.log PATH=$fake:$PATH BOW_BISECT_SCRATCH=$repo \
      BOW_BISECT_TEST=tabs.open BOW_BISECT_REPEAT=2 "$script" --step > "$tmp/step.out" 2>&1
    echo $?
  )
}
rm -f "$tmp/make.log"
check "step: PASS is good" 0 "$(step 'E2E: PASS 4/4' 0)"
check "step: FAIL is bad" 1 "$(step 'E2E: FAIL 3/4' 2)"
check "step: TIMEOUT is bad" 1 "$(step 'E2E: TIMEOUT tabs.open' 2)"
check "step: CRASH is skipped" 125 "$(step 'E2E: CRASH exit=11 without a summary line' 4)"
check "step: FLAKY is bad" 1 "$(step 'E2E: FLAKY 4/4 after the retry' 3)"
check "step: quarantined PASS is good" 0 "$(step 'E2E: PASS 4/4; quarantined flaky tests passed on the retry: a.b' 0)"
check "step: interrupted stops the bisect" 130 "$(step 'E2E: ERROR interrupted' 130)"
check "step: failed bootstrap is skipped" 125 "$(FAKE_BOOTSTRAP_EXIT=1 step 'E2E: PASS 4/4' 0)"
check "step: outside the scratch worktree is refused" 128 "$(cd "$tmp" && BOW_BISECT_SCRATCH=$repo "$script" --step > /dev/null 2>&1; echo $?)"
check "step: repeated FAIL is bad" 1 "$(step 'E2E: FAIL 1/2 repeats passed; failed: repeat 2 (FAIL 0/1)' 1)"
check "step: ERROR is skipped" 125 "$(step 'E2E: ERROR no build' 64)"
check "step: no E2E line (build failed) is skipped" 125 "$(step '' 2)"
has "step: runs make e2e with the test, no retry and the repeat" "$(grep 'make e2e' "$tmp/make.log" | head -n 1)" "make e2e E2E=tabs.open E2E_RETRY=0 E2E_REPEAT=2"
has "step: bootstraps first" "$(head -n 1 "$tmp/make.log")" "make bootstrap"

if [ "$failed" = 0 ]; then echo "e2e-bisect tests: ok"; else echo "e2e-bisect tests: FAIL"; fi
exit "$failed"
