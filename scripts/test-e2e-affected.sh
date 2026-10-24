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
check "BowWebKit only: nothing (the app does not link it yet)" "" \
  "$(map BowWebKit/Package.swift BowWebKit/Sources/BowWebKit/WebKitSPI.swift BowWebKit/Tests/BowWebKitTests/Fixtures/host/index.html)"
check "BowWebKit and BowCore: smoke" "smoke" "$(map BowWebKit/Package.swift BowCore/Sources/A.swift)"
check "BowWebKit and a test file: that file's areas" "tabs,smoke" "$(map BowWebKit/Package.swift E2E/Tests/Tabs.swift)"
check "BowWebKit and an unmapped app file: all" "all" "$(map BowWebKit/Package.swift App/UI/AppDelegate.swift)"
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

# 2b. --callers: the tests that reach a symbol the branch changes under E2E/Harness/ or E2E/Engine/, in a fake
# repository that mimics the page driver change (an E2EPage extension with press(_:) and press(letter:)).
hrepo=$tmp/harness
mkdir -p "$hrepo/scripts" "$hrepo/E2E/Tests" "$hrepo/E2E/Harness" "$hrepo/E2E/Engine"
cp scripts/e2e-affected.sh "$hrepo/scripts/"
cat > "$hrepo/E2E/Harness/E2EInput.swift" << 'EOF'
extension E2EPage {
    func press(_ key: E2EKey) async throws {
        try await emulateFocus()
        print(key)
    }

    func press(letter: Character, macKeyCode: Int) async throws {
        print(letter)
    }

    /// Clicks a link.
    func clickLink(_ selector: String) {
        print(selector)
    }
}
EOF
cat > "$hrepo/E2E/Harness/Helpers.swift" << 'EOF'
enum FormHelpers {
    static func submitForm(_ page: any E2EPage) {
        page.clickLink("form")
    }

    static func openIt() {
        BowThing.openThing()
    }
}
EOF
printf '@implementation BowThing\n+ (void)openThing {\n  NSLog(@"open");\n}\n@end\n' > "$hrepo/E2E/Engine/BowThing.mm"
cat > "$hrepo/E2E/Tests/Page.swift" << 'EOF'
struct PageZoomTest: E2ETest {
    let name = "page.zoom"
    func run() { page.press(letter: "=", macKeyCode: 24) }
}
EOF
cat > "$hrepo/E2E/Tests/Tabs.swift" << 'EOF'
struct TabsEnterTest: E2ETest {
    let name = "tabs.enter"
    func run() { page.press(.enter) }
}
enum TabsHelper {
    static func again() { page.press(.tab) }
}
EOF
cat > "$hrepo/E2E/Tests/Forms.swift" << 'EOF'
struct FormsSubmitTest: E2ETest {
    let name = "forms.submit"
    func run() { FormHelpers.submitForm(page) }
}
struct FormsEngineTest: E2ETest {
    let name = "forms.engine"
    func run() { FormHelpers.openIt() }
}
EOF
cat > "$hrepo/E2E/Tests/Links.swift" << 'EOF'
struct LinksClickTest: E2ETest {
    let name = "links.click"
    func run() { page.clickLink("a") }
}
struct LinksOtherTest: E2ETest {
    let name = "links.other"
    func run() { page.open() }
}
EOF
cat > "$hrepo/E2E/Tests/Other.swift" << 'EOF'
struct OtherSmokeTest: E2ETest {
    let name = "other.smoke"
    let tags = ["smoke"]
}
EOF
h() { git -C "$hrepo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@" > /dev/null 2>&1; }
hb() { h commit -q -am "$1"; h update-ref refs/remotes/origin/main HEAD; }
hc() { (cd "$hrepo" && "$@" scripts/e2e-affected.sh --callers 2> "$tmp/callers.err"); }
h init -q -b main
h add -A
h commit -q -m base
h update-ref refs/remotes/origin/main HEAD
h checkout -q -b work
check "callers: no change, no callers" "" "$(hc env)"
sed -i '' 's/print(letter)/print(letter, 1)/' "$hrepo/E2E/Harness/E2EInput.swift"
check "callers: a changed function body reaches the tests that call it by its label" "direct 1 page.zoom" "$(hc env)"
check "callers: the note names the changed symbol" "callers: changed symbols: press(letter:" "$(cat "$tmp/callers.err")"
hb "press(letter:)"
sed -i '' 's/print(key)/print(key, 1)/' "$hrepo/E2E/Harness/E2EInput.swift"
check "callers: a bare function name finds every caller of that name" \
  "direct 2 page.zoom direct 1 tabs.enter" "$(hc env | paste -sd' ' -)"
check "callers: a mention outside any test (a test file's helper) counts for that file's tests" "tabs.enter" \
  "$(hc env | awk '$3 == "tabs.enter" { print $3 }')"
check "callers: a name found in too many test files falls back to the smoke tests" "fallback 0 other.smoke" \
  "$(hc env CALLERS_COMMON=2 | paste -sd' ' -)"
check "callers: the fallback says which name was too common" "callers: too common to search by name: press (2 test files); added the smoke tests and every test in the areas that call the changed files:" \
  "$(grep '^callers: too common' "$tmp/callers.err" | sed 's/ *$//')"
hb "press(_:)"
sed -i '' 's/print(selector)/print(selector, 1)/' "$hrepo/E2E/Harness/E2EInput.swift"
check "callers: one level up, a harness member that mentions the symbol brings the tests that call that member" \
  "direct 1 forms.submit direct 1 links.click" "$(hc env | paste -sd' ' -)"
hb "clickLink"
sed -i '' 's/NSLog(@"open")/NSLog(@"open!")/' "$hrepo/E2E/Engine/BowThing.mm"
check "callers: a changed Objective-C method reaches the tests through the harness that mentions it" \
  "direct 1 forms.engine" "$(hc env | paste -sd' ' -)"
check "callers: the Objective-C method is the changed symbol" "callers: changed symbols: openThing" "$(cat "$tmp/callers.err")"
hb "openThing"
sed -i '' 's|/// Clicks a link.|/// Clicks a link, now with a longer comment.|' "$hrepo/E2E/Harness/E2EInput.swift"
check "callers: a comment alone changes no symbol" "" "$(hc env)"
hb "comment"
echo "" >> "$hrepo/E2E/Harness/E2EInput.swift"
check "callers: a blank line alone changes no symbol" "" "$(hc env)"
git -C "$hrepo" checkout -q -- E2E/Harness/E2EInput.swift
h rm -q E2E/Harness/Helpers.swift
check "callers: a deleted harness file changes no symbol" "" "$(hc env)"
h reset -q --hard
printf 'struct Fresh {\n    func brandNew() {}\n}\n' > "$hrepo/E2E/Harness/Fresh.swift"
printf 'struct FreshUseTest: E2ETest {\n    let name = "fresh.use"\n    func run() { Fresh().brandNew() }\n}\n' > "$hrepo/E2E/Tests/Fresh.swift"
check "callers: a new untracked harness file counts as all changed (the new type's name)" "direct 1 fresh.use" \
  "$(hc env | paste -sd' ' -)"
rm "$hrepo/E2E/Harness/Fresh.swift" "$hrepo/E2E/Tests/Fresh.swift"
check "callers: an app file changes no harness symbol" "" "$(echo App/UI/A.swift | (cd "$hrepo" && scripts/e2e-affected.sh --stdin --callers 2> /dev/null))"
check "callers: --stdin counts every line of a listed file as changed" \
  "direct 1 forms.submit direct 1 links.click direct 3 page.zoom direct 1 tabs.enter" \
  "$(echo E2E/Harness/E2EInput.swift | (cd "$hrepo" && scripts/e2e-affected.sh --stdin --callers 2> /dev/null) | paste -sd' ' -)"
# A test type built once per name (the popups tests), a deleted line, and code the parser cannot place.
h checkout -q -f work
printf 'extension E2EPage {\n    func zoomIt() {\n        print("z")\n        print("zz")\n    }\n}\n' > "$hrepo/E2E/Harness/Zoom.swift"
printf 'print("a")\n' > "$hrepo/E2E/Harness/Weird.swift"
cat > "$hrepo/E2E/Tests/Popups.swift" << 'EOF'
struct PopupsLinkTest: E2ETest {
    let name: String
    func run() { page.zoomIt() }
}
let all = [PopupsLinkTest(name: "popups.a"), PopupsLinkTest(name: "popups.b")]
struct PopupsOtherTest: E2ETest {
    let name = "popups.other"
}
EOF
h add -A
hb "zoomIt"
sed -i '' '/print("zz")/d' "$hrepo/E2E/Harness/Zoom.swift"
check "callers: a test type constructed once per name reaches every name" "direct 1 popups.a direct 1 popups.b" \
  "$(hc env | paste -sd' ' -)"
hb "delete a line"
sed -i '' '/print(selector, 1)/d' "$hrepo/E2E/Harness/E2EInput.swift"
check "callers: a deleted line changes the member that held it" "direct 1 forms.submit direct 1 links.click" \
  "$(hc env | paste -sd' ' -)"
hb "delete clickLink body"
sed -i '' 's/print("a")/print("b")/' "$hrepo/E2E/Harness/Weird.swift"
check "callers: code that sits in no symbol falls back to the smoke tests and says so" "fallback 0 other.smoke" \
  "$(hc env | paste -sd' ' -)"
check "callers: the fallback names the file it could not read" "callers: too common to search by name: E2E/Harness/Weird.swift (changed lines in no symbol it can read); added the smoke tests and every test in the areas that call the changed files:" \
  "$(grep '^callers: too common' "$tmp/callers.err" | sed 's/ *$//')"
hb "weird"
# Scenario A: the only harness caller of the changed function is private and no test names it; the test calls the
# public member two levels up. Scenario B: the only harness caller is a member no test calls: the named fallback.
cat > "$hrepo/E2E/Harness/Chain.swift" << 'EOF'
extension E2EPage {
    func dispatchDeep() {
        print("d")
    }

    private func sendDeep() {
        dispatchDeep()
    }

    func pressDeep() {
        sendDeep()
    }
}
EOF
printf 'struct DeepPressTest: E2ETest {\n    let name = "deep.press"\n    func run() { page.pressDeep() }\n}\n' > "$hrepo/E2E/Tests/Deep.swift"
cat > "$hrepo/E2E/Engine/Session.mm" << 'EOF'
@implementation Session
- (void)callThing:(id)x {
  NSLog(@"c");
}
@end
EOF
printf 'enum Probe {\n    static func devThing() {\n        Session.callThing(1)\n    }\n}\n' > "$hrepo/E2E/Harness/Probe.swift"
cat > "$hrepo/E2E/Engine/Observer.mm" << 'EOF'
@interface Obs
- (void)detached;
@end

namespace {
class ResultObserver {
 public:
  void run() {
    int x = 1;
  }
};
}

@implementation Obs
- (void)detached {
  NSLog(@"d");
}
@end
EOF
printf 'struct ObsDetachedTest: E2ETest {\n    let name = "obs.detached"\n    func run() { obs.detached() }\n}\n' > "$hrepo/E2E/Tests/Obs.swift"
h add -A
hb "chains"
sed -i '' 's/print("d")/print("dd")/' "$hrepo/E2E/Harness/Chain.swift"
check "callers: a changed function whose callers are private reaches the tests two levels up" "direct 1 deep.press" \
  "$(hc env | paste -sd' ' -)"
hb "dispatchDeep"
sed -i '' 's/NSLog(@"c")/NSLog(@"cc")/' "$hrepo/E2E/Engine/Session.mm"
check "callers: a changed symbol that reaches no test within the climb takes the smoke fallback" "fallback 0 other.smoke" \
  "$(hc env | paste -sd' ' -)"
check "callers: the fallback says the symbol reaches no test" "callers: too common to search by name: callThing (no test reaches it within 4 levels of callers);" \
  "$(grep '^callers: too common' "$tmp/callers.err" | sed 's/ added the smoke.*//')"
hb "callThing"
sed -i '' 's/int x = 1;/int x = 2;/' "$hrepo/E2E/Engine/Observer.mm"
check "callers: a change in C++ code after an @end is not credited to the method before it" "fallback 0 other.smoke" \
  "$(hc env | paste -sd' ' -)"
sed -i '' 's/NSLog(@"d")/NSLog(@"dd")/' "$hrepo/E2E/Engine/Observer.mm"
check "callers: one unreadable changed line takes the fallback beside the readable one in the same file" \
  "direct 1 obs.detached fallback 0 other.smoke" "$(hc env | paste -sd' ' -)"
h reset -q --hard
check "callers: no origin/main ref exits 3" "3" "$(cd "$hrepo" && CHECK_BASE=nope scripts/e2e-affected.sh --callers > /dev/null 2>&1; echo $?)"

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
# A fake tree-key.sh: the key is the file FAKE_KEYFILE holds (or "k0").
cat > "$crepo/scripts/tree-key.sh" << 'EOF'
#!/bin/sh
cat "${FAKE_KEYFILE:-/nonexistent}" 2> /dev/null || echo k0
EOF
# A fake make that logs what it is asked to run; an e2e-run with FAKE_RUN_SUMMARY set also writes a run folder whose
# report.txt ends with that summary line, changes the tree key when FAKE_TOUCH is set, and exits FAKE_E2E_EXIT.
cat > "$tmp/bin/make" << 'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_MAKE_LOG"
case "$*" in
  *e2e-run*)
    if [ -n "${FAKE_RUN_SUMMARY:-}" ]; then
      mkdir -p build/e2e/r1
      echo "$FAKE_RUN_SUMMARY" > build/e2e/r1/report.txt
      ln -sfn r1 build/e2e/latest
      [ -z "${FAKE_TOUCH:-}" ] || echo touched > "$FAKE_KEYFILE"
      exit "${FAKE_E2E_EXIT:-0}"
    fi
    ;;
esac
EOF
chmod +x "$crepo/scripts/e2e-affected.sh" "$crepo/scripts/tree-key.sh" "$tmp/bin/make"
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
check "check: an empty selection on BowWebKit and docs runs no e2e" $'e2e: none)\nno e2e' \
  "$(check_run $'BowWebKit/Package.swift\nREADME.md' "" 0)"
check "check: BowWebKit runs the package tests" "yes" \
  "$(check_run BowWebKit/Package.swift "" 0 > /dev/null; grep -qx -- '--no-print-directory test' "$tmp/make.log" && echo yes)"
check "check: an app change alone runs no package tests" "no" \
  "$(check_run App/UI/A.swift "tabs,smoke" 0 > /dev/null
    grep -qx -- '--no-print-directory test' "$tmp/make.log" && echo yes || echo no)"
check "check: a selection runs it" $'e2e: tabs,smoke)\ne2e-run E2E=tabs,smoke' "$(check_run "$two" "tabs,smoke" 0)"

# check records a full e2e pass for make done to reuse (build/check-e2e-pass: key, selection, summary, run folder), only
# for a selection of all that passed on a tree that did not change while it ran; every run deletes the old record.
# stamp_run <selection> <summary> <e2e exit> <touch the tree during the e2e> <old record: yes|no>
stamp_run() {
  rm -rf "$crepo/build"
  mkdir -p "$crepo/build"
  echo key1 > "$tmp/key"
  [ "$5" = no ] || echo old > "$crepo/build/check-e2e-pass"
  FAKE_CHANGED=App/UI/Z.swift FAKE_SELECTION=$1 FAKE_STATUS=0 FAKE_MAKE_LOG=$tmp/make.log FAKE_RUN_SUMMARY=$2 \
    FAKE_E2E_EXIT=$3 FAKE_TOUCH=$4 FAKE_KEYFILE=$tmp/key PATH="$tmp/bin:$PATH" "$crepo/scripts/check.sh" > /dev/null 2>&1
  if [ -f "$crepo/build/check-e2e-pass" ]; then paste -sd'|' - < "$crepo/build/check-e2e-pass"; else echo none; fi
}
check "check: a passing full e2e is recorded with its tree key and run folder" "key1|all|E2E: PASS 128/128|r1" \
  "$(stamp_run all "E2E: PASS 128/128" 0 "" no)"
check "check: a quarantined pass is recorded too" "key1|all|E2E: PASS 128/128; quarantined flaky tests passed on the retry: a.b|r1" \
  "$(stamp_run all "E2E: PASS 128/128; quarantined flaky tests passed on the retry: a.b" 0 "" no)"
check "check: a partial selection records nothing" "none" "$(stamp_run "tabs,smoke" "E2E: PASS 12/12" 0 "" no)"
check "check: a FLAKY full run records nothing" "none" "$(stamp_run all "E2E: FLAKY 128/128 after retrying a.b" 2 "" no)"
check "check: a failed full run records nothing" "none" "$(stamp_run all "E2E: FAIL 100/128" 2 "" no)"
check "check: a full run on a tree that changed while it ran records nothing" "none" "$(stamp_run all "E2E: PASS 128/128" 0 yes no)"
check "check: a failed run deletes the record of an earlier one" "none" "$(stamp_run all "E2E: FAIL 100/128" 2 "" yes)"
check "check: a run whose e2e leaves no pass summary deletes the record of an earlier one" "none" "$(stamp_run "" "" 0 "" yes)"

# 4. check formats exactly the changed Swift files before linting them, with a fake swift that rewrites BAD to GOOD
# on `format --in-place` and logs every call.
mkdir -p "$crepo/App/UI"
echo BAD > "$crepo/App/UI/A.swift"
echo GOOD > "$crepo/App/UI/B.swift"
echo BAD > "$crepo/App/UI/C.swift"
cat > "$tmp/bin/swift" << 'EOF'
#!/bin/bash
[ "$1" = format ] || exit 0
echo "$*" >> "$FAKE_SWIFT_LOG"
if [ "$2" = --in-place ]; then
  shift 2
  for f in "$@"; do echo GOOD > "$f"; done
fi
EOF
chmod +x "$tmp/bin/swift"
: > "$tmp/swift.log"
fmt_out=$(FAKE_CHANGED=$'App/UI/A.swift\nApp/UI/B.swift' FAKE_SELECTION="" FAKE_STATUS=0 FAKE_MAKE_LOG=$tmp/make.log \
  FAKE_SWIFT_LOG=$tmp/swift.log PATH="$tmp/bin:$PATH" "$crepo/scripts/check.sh" 2> /dev/null | grep '^check: format')
check "check: says which changed files it formatted" "check: format: formatted App/UI/A.swift (commit the change)" "$fmt_out"
check "check: formats then lints exactly the changed files" \
  $'format --in-place App/UI/A.swift App/UI/B.swift\nformat lint --strict App/UI/A.swift App/UI/B.swift' \
  "$(cat "$tmp/swift.log")"
check "check: leaves an unchanged file alone" "BAD" "$(cat "$crepo/App/UI/C.swift")"
fmt_out=$(FAKE_CHANGED=$'App/UI/B.swift' FAKE_SELECTION="" FAKE_STATUS=0 FAKE_MAKE_LOG=$tmp/make.log \
  FAKE_SWIFT_LOG=$tmp/swift.log PATH="$tmp/bin:$PATH" "$crepo/scripts/check.sh" 2> /dev/null | grep '^check: format')
check "check: says when nothing needed formatting" "check: format: 1 changed Swift files, none needed formatting" "$fmt_out"

if [ "$failed" = 0 ]; then echo "e2e-affected self test: ok"; else
  echo "e2e-affected self test: FAIL"
  exit 1
fi
