#!/bin/bash
# The base ref a branch is checked against: prints one ref and nothing else.
#
#   scripts/base-ref.sh
#
# Slices of the WebKit switch branch from and land on origin/webkit, every other branch on origin/main, and each check
# (make done, make check, make verify, make guards, scripts/e2e-affected.sh, scripts/e2e-flakes.sh) compares a branch
# with its own base. The rules, first match wins:
#   1. $BOW_BASE, when set (any ref, taken as it is);
#   2. origin/webkit, when that ref exists and the merge base of HEAD and origin/webkit is not an ancestor of
#      origin/main (the branch carries webkit commits that main does not have yet);
#   3. origin/main.
# It never fetches and never fails: a missing origin/webkit, a missing origin/main or a HEAD with no merge base print
# origin/main. It reads the current directory's repository. Each check's own override (DONE_BASE, CHECK_BASE,
# VERIFY_BASE, PRIVATE_PATHS_BASE) still wins over this. The self test is scripts/test-base-ref.sh.
set -u

if [ -n "${BOW_BASE:-}" ]; then
  echo "$BOW_BASE"
  exit 0
fi
if git rev-parse -q --verify "origin/webkit^{commit}" > /dev/null 2>&1; then
  fork=$(git merge-base HEAD origin/webkit 2> /dev/null)
  if [ -n "$fork" ] && ! git merge-base --is-ancestor "$fork" origin/main; then
    echo origin/webkit
    exit 0
  fi
fi
echo origin/main
