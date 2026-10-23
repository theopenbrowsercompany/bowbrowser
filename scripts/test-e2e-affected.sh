#!/bin/bash
# Tests scripts/e2e-affected.sh (the e2e selection make check runs) in a throwaway git repository with fake test
# files: each mapping rule on fake changed file lists, then the change listing itself (committed, staged, unstaged
# and untracked files, a rename, a deletion, a branch behind origin/main, a detached HEAD, no origin/main), then
# how scripts/check.sh treats a selection that fails or comes back empty, with a fake make.
# Takes about a second and launches no app.
set -u
cd "$(dirname "$0")/.." || exit 1

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
# Helpers other files call: Sidebar.swift declares SidebarWaits, which Zones.swift uses; Zones.swift declares
# ZonesSeed, which Fav.swift uses; Sidebar.swift's private Helper is its own, though Lone.swift names it.
cat > "$repo/E2E/Tests/Sidebar.swift" << 'EOF'
enum SidebarTests {
    struct RowsTest: E2ETest {
        let name = "sidebar.rows"
        func run() { open(E2EFixture.url("sidebar/a.html")) }
    }
}
enum SidebarWaits {
    static func rows() {}
}
private struct Helper {}
EOF
cat > "$repo/E2E/Tests/Zones.swift" << 'EOF'
enum ZonesTests {
    struct PinTest: E2ETest {
        let name = "zones.pin"
        func run() { SidebarWaits.rows() }
    }
}
enum ZonesSeed {}
EOF
cat > "$repo/E2E/Tests/Fav.swift" << 'EOF'
struct FavGridTest: E2ETest {
    let name = "fav.grid"
    func run() { _ = ZonesSeed.self }
}
EOF
cat > "$repo/E2E/Tests/Lone.swift" << 'EOF'
struct LoneTest: E2ETest {
    let name = "lone.a"
    struct Helper {}
}
EOF
cat > "$repo/E2E/Tests/Ext.swift" << 'EOF'
extension E2EApp {
    func waitForThing() {}
}
struct ExtTest: E2ETest {
    let name = "ext.a"
}
EOF
mkdir -p "$repo/E2E/Fixtures/sidebar"
echo x > "$repo/E2E/Fixtures/sidebar/a.html"
echo 'enum E2EAreas { static let all = [TabsTests.all, SidebarTests.all] }' > "$repo/E2E/Tests/E2EAreas.swift"
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
check "a helper file: also the areas of the files using it and their users, not of a private name" \
  "fav,sidebar,zones,smoke" "$(map E2E/Tests/Sidebar.swift)"
check "a file using a helper: its users, not the helper's file" "fav,zones,smoke" "$(map E2E/Tests/Zones.swift)"
check "a file whose declarations nobody else uses: only its own areas" "fav,smoke" "$(map E2E/Tests/Fav.swift)"
check "a test file with a top level extension: all" "all" "$(map E2E/Tests/Ext.swift)"
check "a fixture a helper file loads: the areas of that file's users too" "fav,sidebar,zones,smoke" \
  "$(map E2E/Fixtures/sidebar/a.html)"

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

# 3. scripts/check.sh with a fake e2e-affected.sh and a fake make that only logs what it is asked to run.
crepo=$tmp/check
mkdir -p "$crepo/scripts" "$tmp/bin"
cp scripts/check.sh "$crepo/scripts/"
cat > "$crepo/scripts/e2e-affected.sh" << 'EOF'
#!/bin/bash
if [ "${1:-}" = --changed ]; then
  [ -z "$FAKE_CHANGED" ] || echo "$FAKE_CHANGED"
  exit 0
fi
[ -z "$FAKE_SELECTION" ] || echo "$FAKE_SELECTION"
exit "$FAKE_STATUS"
EOF
cat > "$tmp/bin/make" << 'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_MAKE_LOG"
EOF
chmod +x "$crepo/scripts/e2e-affected.sh" "$tmp/bin/make"
# check_run <changed> <selection> <status>: prints check's last line, then the e2e-run it asked make for (or "no e2e").
check_run() {
  local log=$tmp/make.log
  : > "$log"
  local last
  last=$(FAKE_CHANGED=$1 FAKE_SELECTION=$2 FAKE_STATUS=$3 FAKE_MAKE_LOG=$log PATH="$tmp/bin:$PATH" \
    "$crepo/scripts/check.sh" 2> /dev/null | tail -1)
  echo "${last##*(}"
  grep -o 'e2e-run E2E=.*' "$log" || echo "no e2e"
}
two=$'App/UI/A.swift\nREADME.md'
check "check: a selection that fails runs everything" $'e2e: all)\ne2e-run E2E=all' "$(check_run "$two" "" 1)"
check "check: a selection that fails after printing runs everything" $'e2e: all)\ne2e-run E2E=all' \
  "$(check_run "$two" "tabs,smoke" 2)"
check "check: a selection that fails on docs only runs everything" $'e2e: all)\ne2e-run E2E=all' \
  "$(check_run README.md "" 1)"
check "check: an empty selection with a changed app file runs everything" $'e2e: all)\ne2e-run E2E=all' \
  "$(check_run "$two" "" 0)"
check "check: an empty selection on docs only runs no e2e" $'e2e: none)\nno e2e' \
  "$(check_run $'README.md\nspec/tabs.md' "" 0)"
check "check: a selection runs it" $'e2e: tabs,smoke)\ne2e-run E2E=tabs,smoke' "$(check_run "$two" "tabs,smoke" 0)"

if [ "$failed" = 0 ]; then echo "e2e-affected self test: ok"; else
  echo "e2e-affected self test: FAIL"
  exit 1
fi
