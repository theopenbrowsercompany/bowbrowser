#!/bin/bash
# make done: the final check of a branch, in one command, ending with one block to paste into the report.
#
#   scripts/done.sh
#
# 1. Refuses ("rebase onto origin/main first") unless the branch contains origin/main.
# 2. Runs make bootstrap when Vendor/cef is missing (a fresh worktree).
# 3. Runs make verify, then the full make e2e (E2E=all), as separate commands. A failed verify skips the e2e.
# Then it prints the block: each step's result line, the e2e summary line and run folder, the path to final.png,
# git diff origin/main --stat, the tree hash and whether the worktree is dirty (a dirty tree is not what was
# checked). It exits 1 when any step failed, 2 when it refused.
#
# DONE_BASE=<ref> compares with another ref than origin/main (the self test, scripts/test-done.sh, uses it).
# The steps' own output streams as they run; the block is the last thing printed.
set -u
cd "$(dirname "$0")/.." || exit 1

base=${DONE_BASE:-origin/main}
if ! git rev-parse -q --verify "$base^{commit}" > /dev/null 2>&1; then
  echo "done: no $base ref. Run git fetch origin. Rebase onto origin/main first."
  exit 2
fi
if ! git merge-base --is-ancestor "$base" HEAD; then
  echo "done: this branch does not contain $base. Rebase onto origin/main first."
  exit 2
fi

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
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

verify="skip (bootstrap failed)"
e2e="skip (not run)"
if [ "$failed" = 0 ]; then
  step verify make --no-print-directory verify
  verify_line=$(grep '^verify: \(PASS\|FAIL\)' "$out/verify.log" | tail -1)
  if [ "$step_status" = 0 ]; then verify="ok: ${verify_line:-no summary line}"; else
    verify="FAIL (exit $step_status): ${verify_line:-no summary line}"
    failed=1
  fi
  if [ "$failed" = 0 ]; then
    step e2e make --no-print-directory e2e E2E=all
    e2e_line=$(grep '^E2E: ' "$out/e2e.log" | tail -1)
    if [ "$step_status" = 0 ]; then e2e="ok"; else
      e2e="FAIL (exit $step_status)"
      failed=1
    fi
  else
    e2e="skip (verify failed)"
  fi
fi

echo
echo "===== done: report block ====="
echo "bootstrap: $bootstrap"
echo "make verify: $verify"
echo "make e2e: $e2e"
echo "e2e summary: ${e2e_line:-none}"
run=$(readlink build/e2e/latest 2> /dev/null || true)
if [ -n "$run" ]; then echo "e2e run folder: build/e2e/$run"; else echo "e2e run folder: none"; fi
if [ -n "$run" ] && [ -f "build/e2e/latest/final.png" ]; then
  echo "final.png: $PWD/build/e2e/latest/final.png"
else
  echo "final.png: none"
fi
echo "head: $(git rev-parse HEAD)"
echo "tree: $(git rev-parse 'HEAD^{tree}')"
if [ -n "$(git status --porcelain)" ]; then echo "worktree: DIRTY (commit first, this is not what was checked)"; else echo "worktree: clean"; fi
echo "git diff $base --stat:"
git diff "$base" --stat
if [ "$failed" = 0 ]; then echo "done: PASS"; else
  echo "done: FAIL"
  exit 1
fi
