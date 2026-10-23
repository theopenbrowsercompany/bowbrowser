#!/bin/bash
# Tests scripts/e2e-affected.sh (the e2e selection make check runs) in a throwaway git repository with fake test
# files: each mapping rule on fake changed file lists, then the change listing itself (committed, staged, unstaged
# and untracked files, a rename, a deletion, a branch behind origin/main, a detached HEAD, no origin/main).
# Takes about a second and launches no app.
set -u
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; failed=1; fi
}

# A fake repository: the script under test, two test files and fixtures.
repo=$tmp/repo
mkdir -p "$repo/scripts" "$repo/E2E/Tests" "$repo/E2E/Fixtures/tabs" "$repo/E2E/Fixtures/navigation" \
  "$repo/E2E/Fixtures/orphan" "$repo/BowCore/Sources" "$repo/App/UI/Downloads" "$repo/spec"
cp scripts/e2e-affected.sh "$repo/scripts/"
cat > "$repo/E2E/Tests/Tabs.swift" << 'EOF'
struct TabsSwitchTest: E2ETest {
    let name = "tabs.switch"
}
struct TabsEdgeTest: E2ETest {
    let name = "tabs.edge"
    func run() { open(E2EFixture.url("tabs/a.html")) }
}
EOF
cat > "$repo/E2E/Tests/Navigation.swift" << 'EOF'
struct NavTest: E2ETest {
    let name = "nav.back"
    func run() { open(E2EFixture.url("navigation/a.html")); open(E2EFixture.url("tabs/b.html")) }
}
struct LinkTest: E2ETest {
    let name = "link.open"
}
EOF
echo 'enum E2EAreas { static let all = [TabsTests.all] }' > "$repo/E2E/Tests/E2EAreas.swift"
for f in E2E/Fixtures/tabs/a.html E2E/Fixtures/navigation/a.html E2E/Fixtures/orphan/a.html \
  BowCore/Sources/A.swift App/UI/Downloads/D.swift App/UI/AppDelegate.swift spec/tabs.md README.md Makefile; do
  echo "$f" > "$repo/$f"
done
affected=$repo/scripts/e2e-affected.sh
map() { printf '%s\n' "$@" | "$affected" --stdin; }

# 1. The mapping on fake changed file lists.
check "one test file: its area plus smoke" "tabs,smoke" "$(map E2E/Tests/Tabs.swift)"
check "a test file with two areas: both" "link,nav,smoke" "$(map E2E/Tests/Navigation.swift)"
check "a test file naming no test: all" "all" "$(map E2E/Tests/E2EAreas.swift)"
check "a deleted test file: all" "all" "$(map E2E/Tests/Gone.swift)"
check "a fixture folder: the area of that name and the files that load it" "link,nav,tabs,smoke" \
  "$(map E2E/Fixtures/tabs/a.html)"
check "a fixture folder named apart from its area: the areas that load it" "link,nav,smoke" \
  "$(map E2E/Fixtures/navigation/a.html)"
check "a fixture folder no test uses: all" "all" "$(map E2E/Fixtures/orphan/a.html)"
check "docs only: nothing" "" "$(map README.md spec/tabs.md .claude/agents/bow-worker.md)"
check "BowCore only: smoke" "smoke" "$(map BowCore/Sources/A.swift)"
check "BowCore and docs: smoke" "smoke" "$(map BowCore/Sources/A.swift AGENTS.md)"
check "a mapped app folder: its table areas plus smoke" "downloads,sidebar,smoke" "$(map App/UI/Downloads/D.swift)"
check "a mapped app file: its table areas plus smoke" "find,sidebar,smoke" "$(map App/UI/FindBar.swift)"
check "a file next to a mapped one: all" "all" "$(map App/UI/FindBar2.swift)"
check "an unmapped app file: all" "all" "$(map App/UI/AppDelegate.swift)"
check "an unmapped file among mapped ones: all" "all" "$(map E2E/Tests/Tabs.swift App/UI/AppDelegate.swift)"
for f in E2E/Harness/E2ERun.swift E2E/Engine/E2EServer.mm project.yml scripts/e2e.sh Makefile cef.lock \
  E2E/Tests/Sub/X.swift; do
  check "$f: all" "all" "$(map "$f")"
done
check "areas and BowCore: sorted, smoke once at the end" "link,nav,tabs,smoke" \
  "$(map BowCore/A.swift E2E/Tests/Navigation.swift E2E/Tests/Tabs.swift E2E/Tests/Tabs.swift)"

# 2. The change listing in the fake repository.
g() { git -C "$repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@" > /dev/null 2>&1; }
run() { (cd "$repo" && scripts/e2e-affected.sh "$@" 2> /dev/null); }
g init -q -b main
check "no origin/main ref: all" "all" "$(run)"
check "no origin/main ref: --changed exits 3" "3" "$(run --changed > /dev/null; echo $?)"
g add -A
g commit -q -m base
g update-ref refs/remotes/origin/main HEAD
g checkout -q -b work
check "no change: nothing" "" "$(run)"
echo x >> "$repo/E2E/Tests/Tabs.swift"
check "an unstaged test file change" "tabs,smoke" "$(run)"
g add -A
check "a staged test file change" "tabs,smoke" "$(run)"
g commit -q -m tabs
check "a committed test file change" "tabs,smoke" "$(run)"
echo new > "$repo/spec/new.md"
check "an untracked doc adds nothing" "tabs,smoke" "$(run)"
echo new > "$repo/App/UI/New.swift"
check "an untracked app file: all" "all" "$(run)"
rm "$repo/App/UI/New.swift"
g mv E2E/Tests/Navigation.swift E2E/Tests/Nav.swift
check "a renamed test file: all (the old path is gone)" "all" "$(run)"
check "a renamed test file lists both paths" "E2E/Tests/Nav.swift E2E/Tests/Navigation.swift" \
  "$(run --changed | grep Nav | tr '\n' ' ' | sed 's/ $//')"
g reset -q --hard
# origin/main moves on with an app change the branch does not have: it must not count.
g checkout -q main
echo y >> "$repo/App/UI/AppDelegate.swift"
g commit -q -am main
g update-ref refs/remotes/origin/main HEAD
g checkout -q work
check "a branch behind origin/main: only its own changes" "tabs,smoke" "$(run)"
g checkout -q --detach work
check "a detached HEAD: its changes against the merge base" "tabs,smoke" "$(run)"
check "CHECK_BASE compares with another ref" "" "$(CHECK_BASE=work run)"
check "an unknown CHECK_BASE: all" "all" "$(CHECK_BASE=nope run)"
check "an unknown argument: exit 64" "64" "$(run --nope > /dev/null; echo $?)"

if [ "$failed" = 0 ]; then echo "e2e-affected self test: ok"; else
  echo "e2e-affected self test: FAIL"
  exit 1
fi
