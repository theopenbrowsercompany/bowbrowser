#!/bin/bash
# Finds the commit that broke an e2e test: git bisect run over <good>..<bad> in a scratch worktree.
#
#   scripts/e2e-bisect.sh [--repeat N] <test> <good> <bad>
#
# <test> is an E2E selection as make e2e takes it (a test name, an area, a glob); <good> and <bad> are any
# commits, tags or branches (for example origin/main~20 and origin/main). --repeat N (default 1) runs the
# selection N times per step (E2E_REPEAT=N), each repeat failing the step on its first failure, so a flaky test
# does not point the bisect at the wrong commit; use 3 or more for a flaky test.
#
# What it does:
# - makes a detached scratch worktree under <repo>/.claude/worktrees/bisect-<unique> (gitignored), runs
#   `make bootstrap` there, runs the step once on <bad> (it must be bad) and once on <good> (it must be good),
#   since git assumes both ends, then `git bisect run` with one step per commit;
# - a step runs `make bootstrap` (a commit may pin another CEF), then `make e2e E2E=<test> E2E_RETRY=0
#   E2E_REPEAT=<N>` in the scratch worktree, so it builds there and takes its build and e2e slots from
#   scripts/build-lock.sh like any other build (a waiting step prints its rank; let it wait), maps the run's last
#   `E2E:` line to git's exit codes, and resets the worktree's tracked files afterwards:
#     E2E: PASS ...                        0    good
#     E2E: FAIL, TIMEOUT or FLAKY ...      1    bad
#     E2E: ERROR interrupted               130  stops the whole bisect
#     other E2E: ERROR, E2E: CRASH, or no E2E line   125  skip: the commit did not build, the run could not
#                                               start, or the app crashed (use --repeat to tell a crash from a fluke)
# - prints `culprit: <hash> <subject>` and exits 0 when the first bad commit is found; exits 1 when the bisect
#   ends without one (every remaining commit skipped, or <good> is not older than <bad>) and 64 for bad usage;
# - removes the scratch worktree however it ends (bisect reset first, also on Ctrl-C, TERM and HUP).
#
# Settings, for the self test (scripts/test-e2e-bisect.sh), which runs no build and no app:
#   BOW_BISECT_REPO       the repository to bisect (default: the one holding this script)
#   BOW_BISECT_BOOTSTRAP  a command replacing `make bootstrap`, run in the scratch worktree
#   BOW_BISECT_STEP       a command replacing the make e2e step, run in the scratch worktree for every commit
#                         with BOW_BISECT_TEST and BOW_BISECT_REPEAT set; its exit status goes to git as is
#
# Internal: `scripts/e2e-bisect.sh --step` is what git bisect run calls.
set -u

self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

if [ "${1:-}" = "--step" ]; then
  # One bisect step, in the scratch worktree git runs it from; never anywhere else, since it resets tracked files.
  [ -n "${BOW_BISECT_SCRATCH:-}" ] && [ "$(pwd -P)" = "$(cd "$BOW_BISECT_SCRATCH" && pwd -P)" ] || {
    echo "e2e-bisect: --step is internal and runs only in the scratch worktree" >&2
    exit 128
  }
  out=$(mktemp "${TMPDIR:-/tmp}/e2e-bisect-step.XXXXXX") || exit 128
  trap 'rm -f "$out"; git reset -q --hard' EXIT
  if [ -n "${BOW_BISECT_STEP:-}" ]; then
    bash -c "$BOW_BISECT_STEP"
    exit $?
  fi
  # Each commit may pin another CEF or project spec, so bootstrap again before building.
  make bootstrap > "$out" 2>&1 || { echo "bisect: skip (make bootstrap failed)"; exit 125; }
  make e2e E2E="$BOW_BISECT_TEST" E2E_RETRY=0 E2E_REPEAT="$BOW_BISECT_REPEAT" E2E_QUIET= E2E_SHARDS= > "$out" 2>&1
  cat "$out"
  line=$(grep '^E2E: ' "$out" | tail -n 1)
  case $line in
    "E2E: PASS "*) echo "bisect: good ($line)"; exit 0 ;;
    "E2E: FAIL "* | "E2E: TIMEOUT "* | "E2E: FLAKY "*) echo "bisect: bad ($line)"; exit 1 ;;
    "E2E: ERROR interrupted"*) echo "bisect: interrupted, stopping the bisect"; exit 130 ;;
    *) echo "bisect: skip (${line:-no E2E summary line, the build failed?}; an app crash lands here too)"; exit 125 ;;
  esac
fi

usage() { sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p;}' "$self"; }

repeat=1
while [ $# -gt 0 ]; do
  case $1 in
    --repeat)
      repeat=${2:-}
      shift 2 2>/dev/null || { echo "e2e-bisect: --repeat needs a number" >&2; exit 64; }
      ;;
    -h | --help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "e2e-bisect: unknown option $1" >&2; exit 64 ;;
    *) break ;;
  esac
done
case $repeat in '' | *[!0-9]* | 0) echo "e2e-bisect: --repeat must be a whole number of 1 or more, not '$repeat'" >&2; exit 64 ;; esac
if [ $# -ne 3 ]; then
  echo "usage: scripts/e2e-bisect.sh [--repeat N] <test> <good> <bad>" >&2
  exit 64
fi
test_name=$1 good=$2 bad=$3

repo=${BOW_BISECT_REPO:-$(cd "$(dirname "$self")/.." && pwd)}
git_repo() { git -C "$repo" "$@"; }
good_rev=$(git_repo rev-parse --verify --quiet "$good^{commit}") || { echo "e2e-bisect: unknown commit '$good'" >&2; exit 64; }
bad_rev=$(git_repo rev-parse --verify --quiet "$bad^{commit}") || { echo "e2e-bisect: unknown commit '$bad'" >&2; exit 64; }
if [ "$good_rev" = "$bad_rev" ] || ! git_repo merge-base --is-ancestor "$good_rev" "$bad_rev"; then
  echo "e2e-bisect: <good> must be an ancestor of <bad> and a different commit" >&2
  exit 64
fi

mkdir -p "$repo/.claude/worktrees" || exit 1
wt=$(mktemp -d "$repo/.claude/worktrees/bisect-XXXXXX") || exit 1
added=0
cleanup() {
  trap '' INT TERM HUP
  if [ "$added" = 1 ]; then
    git -C "$wt" bisect reset > /dev/null 2>&1
    git_repo worktree remove --force "$wt" > /dev/null 2>&1
  fi
  rm -rf "$wt"
  git_repo worktree prune > /dev/null 2>&1
}
trap cleanup EXIT
trap 'echo "e2e-bisect: interrupted" >&2; exit 130' INT TERM HUP

git_repo worktree add --detach "$wt" "$bad_rev" > /dev/null || { echo "e2e-bisect: could not make the scratch worktree" >&2; exit 1; }
added=1
echo "e2e-bisect: scratch worktree $wt, $test_name from $good_rev (good) to $bad_rev (bad), repeat $repeat"

cd "$wt" || exit 1
if [ -n "${BOW_BISECT_BOOTSTRAP:-}" ]; then
  bash -c "$BOW_BISECT_BOOTSTRAP" || { echo "e2e-bisect: bootstrap failed" >&2; exit 1; }
else
  make bootstrap || { echo "e2e-bisect: make bootstrap failed" >&2; exit 1; }
fi

export BOW_BISECT_SCRATCH=$wt BOW_BISECT_TEST=$test_name BOW_BISECT_REPEAT=$repeat
# The endpoints must behave as claimed: git assumes them, so a test that passes on <bad> would blame <bad> itself.
"$self" --step > /dev/null 2>&1
rc=$?
[ "$rc" = 1 ] || { echo "e2e-bisect: the test does not fail on <bad> $bad (step status $rc); nothing to bisect" >&2; exit 1; }
git checkout -q --detach "$good_rev" || exit 1
"$self" --step > /dev/null 2>&1
rc=$?
[ "$rc" = 0 ] || { echo "e2e-bisect: the test does not pass on <good> $good (step status $rc)" >&2; exit 1; }
git checkout -q --detach "$bad_rev" || exit 1

git bisect start "$bad_rev" "$good_rev" > /dev/null || { echo "e2e-bisect: git bisect start failed" >&2; exit 1; }
log=$(mktemp "${TMPDIR:-/tmp}/e2e-bisect-log.XXXXXX") || exit 1
trap 'rm -f "$log"; cleanup' EXIT
git bisect run "$self" --step 2>&1 | tee "$log"

culprit=$(sed -n 's/^\([0-9a-f]\{40\}\) is the first bad commit$/\1/p' "$log" | head -n 1)
if [ -z "$culprit" ]; then
  echo "e2e-bisect: no culprit found (every remaining commit was skipped, or the bisect failed); see the output above" >&2
  exit 1
fi
echo "culprit: $(git_repo log -1 --format='%h %s' "$culprit")"
exit 0
