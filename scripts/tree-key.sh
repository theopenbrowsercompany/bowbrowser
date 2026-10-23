#!/bin/sh
# Prints the tree key of a checkout: the HEAD tree hash, plus 8 hex digits of the diff when a tracked file is
# modified or an untracked (not ignored) file exists, so a fix in the working tree is a different tree.
# Usage: tree-key.sh [repo] (default: the checkout this script lives in).
# `make build` stamps it beside the built app (scripts/stamp-tree.sh) and scripts/e2e.sh writes that stamp to the
# ledger, so a run says which source its binary was built from, not which tree is checked out when it runs.
repo=${1:-$(dirname "$0")/..}
tree=$(git -C "$repo" rev-parse 'HEAD^{tree}' 2> /dev/null)
if [ -n "$(git -C "$repo" status --porcelain 2> /dev/null)" ]; then
  diff=$({
    git -C "$repo" diff HEAD
    git -C "$repo" ls-files --others --exclude-standard | while IFS= read -r f; do
      echo "$f"
      shasum < "$repo/$f"
    done
  } 2> /dev/null | shasum | cut -c1-8)
  tree="${tree:-unknown}-$diff"
fi
printf '%s\n' "${tree:-unknown}"
