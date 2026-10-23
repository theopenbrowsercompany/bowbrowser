#!/bin/bash
# Tests scripts/check-private-paths.sh in a throwaway git repository with fake changes: a clean branch, a committed,
# a staged, an unstaged and an untracked home directory path, a disallowed file, an excluded file, a private
# repository path, and a repository with no origin/main. Takes about a second. The home directory prefix is built at
# run time so this file holds no such path itself.
set -u
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0
has() { # has <description> <text> <needle>
  case $2 in *"$3"*) echo "ok   $1" ;; *)
    echo "FAIL $1: no '$3' in:"
    echo "$2"
    failed=1
    ;;
  esac
}
lacks() { # lacks <description> <text> <needle>
  case $2 in *"$3"*)
    echo "FAIL $1: found '$3' in:"
    echo "$2"
    failed=1
    ;;
  *) echo "ok   $1" ;;
  esac
}

home="/$(echo Users)/someone/code"
repo=$tmp/repo
mkdir -p "$repo/scripts" "$repo/.githooks" "$repo/E2E/Tests"
cp scripts/check-private-paths.sh "$repo/scripts/"
cp .githooks/pre-push "$repo/.githooks/"
g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }
git init -q "$repo"
printf 'let a = 1\n' > "$repo/E2E/Tests/A.swift"
printf 'doc\n' > "$repo/AGENTS.md"
g add -A
g commit -qm base
g update-ref refs/remotes/origin/main HEAD

run() { (cd "$repo" && ./scripts/check-private-paths.sh 2>&1; echo "exit=$?"); }

out=$(run)
has "a clean branch passes" "$out" "check-private-paths: ok"
has "a clean branch exits 0" "$out" "exit=0"

printf 'let a = 1\nlet b = "%s/x"\n' "$home" > "$repo/E2E/Tests/A.swift"
g commit -qam "adds a path"
out=$(run)
has "a committed home path fails" "$out" "exit=1"
has "it names the file and line" "$out" "E2E/Tests/A.swift:2:"
has "it says the hook's message" "$out" "adds a home directory, Arc profile or private repository path"

g reset -q --hard HEAD~1
printf 'let c = "%s"\n' "$home" > "$repo/E2E/Tests/B.swift"
g add E2E/Tests/B.swift
out=$(run)
has "a staged home path fails" "$out" "E2E/Tests/B.swift:1:"
g reset -q --hard HEAD

printf 'let a = 1\nlet z = "%s"\n' "$home" > "$repo/E2E/Tests/A.swift"
out=$(run)
has "an unstaged home path fails" "$out" "E2E/Tests/A.swift:2:"
g checkout -q -- .

printf 'let u = "%s"\n' "$home" > "$repo/E2E/Tests/U.swift"
out=$(run)
has "an untracked home path fails" "$out" "E2E/Tests/U.swift:1:"
rm "$repo/E2E/Tests/U.swift"

printf 'doc %s\n' "$home" > "$repo/AGENTS.md"
out=$(run)
has "the hook's excluded file passes" "$out" "exit=0"
g checkout -q -- .

printf 'x\n' > "$repo/recording.mov"
out=$(run)
has "a disallowed file type fails" "$out" "recording.mov"
has "a disallowed file type exits 1" "$out" "exit=1"
rm "$repo/recording.mov"

printf 'see %s/PLAN.md\n' "bowbrowser-$(echo private)" > "$repo/E2E/Tests/P.swift"
out=$(run)
has "a private repository path fails" "$out" "E2E/Tests/P.swift:1:"
rm "$repo/E2E/Tests/P.swift"

# An old line with a path that the branch did not add does not count.
printf 'let old = "%s"\n' "$home" > "$repo/E2E/Tests/Old.swift"
g add -A
g commit -qm "old path on main"
g update-ref refs/remotes/origin/main HEAD
out=$(run)
has "a path already on origin/main passes" "$out" "exit=0"

# A path added in one commit and removed in the next passes the net diff but the hook refuses the first commit.
printf 'let t = "%s"\n' "$home" > "$repo/E2E/Tests/T.swift"
g add -A
g commit -qm "spells a path"
first=$(g rev-parse --short HEAD)
printf 'let t = 1\n' > "$repo/E2E/Tests/T.swift"
g commit -qam "replaces the path"
out=$(run)
has "a path added then removed fails" "$out" "exit=1"
has "it names the first commit" "$out" "commit $first spells a path"
has "it names the commit's file and line" "$out" "E2E/Tests/T.swift:1:"
lacks "it does not name the fixing commit" "$out" "commit $(g rev-parse --short HEAD) "
has "it tells how to fix it" "$out" "Never squash the whole branch"
# A clean history of several commits passes.
g reset -q --hard "$first"~1
printf 'let t = 1\n' > "$repo/E2E/Tests/T.swift"
g add -A
g commit -qm "clean one"
printf 'let t = 2\n' > "$repo/E2E/Tests/T.swift"
g commit -qam "clean two"
out=$(run)
has "a clean history passes" "$out" "exit=0"
g update-ref refs/remotes/origin/main HEAD

# No origin/main: the working tree changes against HEAD only.
g update-ref -d refs/remotes/origin/main
out=$(run)
has "no origin/main, a clean tree passes" "$out" "exit=0"
printf 'let n = "%s"\n' "$home" > "$repo/E2E/Tests/N.swift"
out=$(run)
has "no origin/main, a new path fails" "$out" "E2E/Tests/N.swift:1:"
lacks "no origin/main, committed lines are not checked" "$out" "Old.swift"

if [ "$failed" = 0 ]; then echo "check-private-paths self test: ok"; else
  echo "check-private-paths self test: FAIL"
  exit 1
fi
