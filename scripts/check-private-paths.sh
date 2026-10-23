#!/bin/bash
# make guards part: fails when the branch adds a private path or a disallowed file, the same check the pre-push hook
# makes, so a worker finds out before the push instead of at it.
#
#   scripts/check-private-paths.sh
#
# The patterns and the excluded paths are read from .githooks/pre-push (content_pattern, file_pattern and its
# ':(exclude)' pathspecs), never copied here. The lines checked are those the branch adds against where it left
# origin/main (the merge base): committed, staged, unstaged and untracked changes. With no origin/main ref (or no
# merge base) it checks the working tree changes against HEAD only. PRIVATE_PATHS_BASE=<ref> compares with another
# ref than origin/main (the self test, scripts/test-check-private-paths.sh, uses it).
# It also checks each commit in <merge base>..HEAD on its own, as the hook does, and names the commit (short hash and
# subject), the file and the line. Prints "<file>:<line>: <line text>" per offending line, then the hook's message; exits 1 on any, 2 when it cannot
# read the hook.
set -u
cd "$(dirname "$0")/.." || exit 1

hook=.githooks/pre-push
content_pattern=$(sed -n "s/^content_pattern='\(.*\)'\$/\1/p" "$hook" 2> /dev/null)
file_pattern=$(sed -n "s/^file_pattern='\(.*\)'\$/\1/p" "$hook" 2> /dev/null)
if [ -z "$content_pattern" ] || [ -z "$file_pattern" ]; then
  echo "check-private-paths: cannot read the patterns from $hook" >&2
  exit 2
fi
# The hook's excluded paths, as pathspecs, one per line.
excludes=()
while IFS= read -r spec; do
  [ -n "$spec" ] && excludes+=("$spec")
done < <(grep -o "':(exclude)[^']*'" "$hook" | tr -d "'")

base=${PRIVATE_PATHS_BASE:-origin/main}
from=HEAD
if git rev-parse -q --verify "$base^{commit}" > /dev/null 2>&1; then
  from=$(git merge-base "$base" HEAD 2> /dev/null) || from=HEAD
fi

failed=0

# Added files of a disallowed type: committed or staged ones (against the merge base), and untracked ones.
added_files=$( { git diff --name-only --diff-filter=A --no-renames "$from" -- . "${excludes[@]}"; git ls-files --others --exclude-standard; } | grep -iE "$file_pattern")
if [ -n "$added_files" ]; then
  echo "check-private-paths: the branch adds a disallowed file type:" >&2
  echo "$added_files" | sed 's/^/    /' >&2
  failed=1
fi

# Added lines: "<file>:<line>: <text>".
scan() { # scan: reads a unified diff on stdin
  awk -v pat="$content_pattern" '
    /^\+\+\+ / { file = substr($0, 7); if ($0 == "+++ /dev/null") file = ""; next }
    /^--- / { next }
    /^@@ / { split($3, p, ","); line = substr(p[1], 2) + 0; next }
    /^\+/ { if (file != "" && substr($0, 2) ~ pat) printf "%s:%d: %s\n", file, line, substr($0, 2); line++ }
  '
}
hits=$(git diff -U0 --no-color --no-ext-diff --no-renames "$from" -- . "${excludes[@]}" | scan)
# Untracked files are all added lines.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  excluded=0
  for spec in "${excludes[@]}"; do
    [ "${spec#:(exclude)}" = "$f" ] && excluded=1
  done
  [ "$excluded" = 1 ] && continue
  more=$(git diff -U0 --no-color --no-ext-diff --no-index -- /dev/null "$f" | scan)
  [ -n "$more" ] && hits=$(printf '%s\n%s' "$hits" "$more")
done < <(git ls-files --others --exclude-standard)
hits=$(echo "$hits" | grep -v '^$')
if [ -n "$hits" ]; then
  echo "check-private-paths: the branch adds a home directory, Arc profile or private repository path:" >&2
  echo "$hits" | sed 's/^/    /' >&2
  failed=1
fi

# The hook checks the added lines and files of every commit, so a line added in one commit and removed in a later one
# passes the net checks above and is still refused at the push. Check each commit in <merge base>..HEAD the same way.
commit_failed=0
bad_commit=
if [ "$from" != HEAD ]; then
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    label="$(git rev-parse --short "$commit") $(git log -1 --format=%s "$commit")"    cfiles=$(git diff-tree --root --no-commit-id --name-only -r --diff-filter=A "$commit" | grep -iE "$file_pattern")
    if [ -n "$cfiles" ]; then
      echo "check-private-paths: commit $label adds a disallowed file type:" >&2
      echo "$cfiles" | sed 's/^/    /' >&2
      commit_failed=1
      [ -n "$bad_commit" ] || bad_commit=$commit
    fi
    clines=$(git diff-tree --root --no-commit-id -r -p -U0 --no-color --no-ext-diff "$commit" -- . "${excludes[@]}" | scan)
    if [ -n "$clines" ]; then
      echo "check-private-paths: commit $label adds a home directory, Arc profile or private repository path:" >&2
      echo "$clines" | sed 's/^/    /' >&2
      commit_failed=1
      [ -n "$bad_commit" ] || bad_commit=$commit
    fi
  done < <(git rev-list --reverse "$from..HEAD")
fi
if [ "$commit_failed" -ne 0 ]; then
  # A fixup commit cannot do this: when a later commit removed the line, the tip is clean and there is nothing to commit.
  # Steps for the first commit named above (rerun after it for the next one); no editor needed.
  bad=$(git rev-parse --short "$bad_commit")
  {
    echo "check-private-paths: fix the commit named above in place, not the branch tip, and never squash the whole branch. Steps for $bad:"
    echo "    old=\$(git rev-parse HEAD)"
    echo "    GIT_SEQUENCE_EDITOR=\"sed -i '' 's/^pick $bad/edit $bad/'\" git rebase -i $bad~1"
    echo "    (remove the offending line or file from that commit's change, then git add it)"
    echo "    git commit --amend --no-edit"
    echo "    git rebase --continue"
    echo "    (on a conflict in a later commit, take that later commit's version, git checkout --theirs <file>, git add <file>, then git rebase --continue again, so the final tree stays the same)"
    echo "    git diff \$old HEAD    (must print nothing)"
  } >&2
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  echo "check-private-paths: the pre-push hook would refuse this. Remove the lines or files above from the commit that adds them (use /tmp or relative paths in tests)." >&2
  exit 1
fi
echo "check-private-paths: ok"
