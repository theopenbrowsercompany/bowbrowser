#!/bin/bash
# Tests scripts/check-lists.sh on fixture trees (LISTS_ROOT): a clean list passes, an entry no file declares fails
# with the message naming file and line (a stale entry, a renamed entry kept beside the new one), a macro comment
# allows an undeclared name, extensions and typealiases count as declarations. Takes under a second, launches nothing.
set -u
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; failed=1; fi
}

# fixture <areas entries> <extra Swift text>: a tree with every list the check reads, E2EAreas holding the entries.
fixture() {
  rm -rf "$tmp/t"
  local root=$tmp/t
  mkdir -p "$root/App/UI/Window" "$root/App/UI/App" "$root/App/UI/Sidebar" "$root/App/Engine" "$root/E2E/Tests"
  local list
  for list in App/UI/Window/WindowFeatures.swift App/UI/App/AppFeatures.swift App/UI/Sidebar/SidebarSectionList.swift \
    App/UI/Sidebar/SidebarMenuList.swift App/UI/Sidebar/SidebarDropRuleList.swift App/UI/Sidebar/SidebarAccessoryList.swift; do
    printf 'enum L {\n    static let all: [Int.Type] = [\n        Real.self,\n    ]\n}\n' > "$root/$list"
  done
  printf 'struct Real {}\nstruct SpacesAreaTests {}\nenum FavoritesTests {}\nextension Extended {}\ntypealias Aliased = Int\n%s\n' "$2" \
    > "$root/App/Real.swift"
  printf 'enum E2EAreas {\n    static let all: [Int.Type] = [\n%s    ]\n}\n' "$1" > "$root/E2E/Tests/E2EAreas.swift"
  printf '#import "A.h"\n' > "$root/App/Engine/Bow-Bridging-Header.h"
}
# run: the check's exit status on the fixture, output in $tmp/out.
run() {
  LISTS_ROOT=$tmp/t ./scripts/check-lists.sh > "$tmp/out" 2>&1
  echo $?
}

fixture '        SpacesAreaTests.self,
        FavoritesTests.all,
        Extended.self,
        Aliased.self,
' ''
check "a clean list passes" 0 "$(run)"
check "the clean list says ok" "yes" "$(grep -q '^lists: ok' "$tmp/out" && echo yes)"

fixture '        SpacesAreaTests.self,
        GoneTests.self,
' ''
check "a stale entry fails" 1 "$(run)"
check "the message names file, line and entry" "yes" \
  "$(grep -qF 'lists: E2E/Tests/E2EAreas.swift:4: GoneTests is declared nowhere (a stale entry after a rebase?)' "$tmp/out" && echo yes)"

fixture '        SpacesTests.self,
        SpacesAreaTests.self,
' ''
check "a renamed entry kept beside the new one fails" 1 "$(run)"
check "only the old name is reported" "1" "$(grep -c 'declared nowhere' "$tmp/out")"
check "the old name is the one reported" "yes" "$(grep -q 'SpacesTests is declared nowhere' "$tmp/out" && echo yes)"

fixture '        MacroMade.self, // lists: declared by @Registered
' ''
check "an entry with a macro comment passes" 0 "$(run)"

fixture '        MacroMade.self,
' 'struct Other {}'
check "the same entry without the comment fails" 1 "$(run)"

fixture '        GoneTests.self,
' '// the old struct GoneTests was renamed
let text = "enum GoneTests"'
check "a name only in a comment or a string is not a declaration" 1 "$(run)"

fixture '        Real.all,
        Real.all,
' ''
check "a duplicate entry still fails" 1 "$(run)"
check "the duplicate message stays" "yes" "$(grep -q 'lists Real.all twice' "$tmp/out" && echo yes)"

fixture '        Rea.self,
' ''
check "a name that is only a prefix of a declared type fails" 1 "$(run)"

fixture '        SpacesAreaTests.self,
' ''
check "the ok line names the bridging header when it exists" "yes" "$(run > /dev/null; grep -qF 'Swift lists, the bridging header, e2e' "$tmp/out" && echo yes)"
printf '#import "A.h"\n#import "A.h"\n' > "$tmp/t/App/Engine/Bow-Bridging-Header.h"
check "a duplicate import in an existing bridging header still fails" 1 "$(run)"
printf '#import <A.h>\n' > "$tmp/t/App/Engine/Bow-Bridging-Header.h"
check "a malformed import in an existing bridging header still fails" 1 "$(run)"

fixture '        SpacesAreaTests.self,
' ''
rm "$tmp/t/App/Engine/Bow-Bridging-Header.h"
check "a missing bridging header passes" 0 "$(run)"
check "the ok line names the missing bridging header" "yes" \
  "$(grep -qF 'lists: ok (7 Swift lists, no bridging header App/Engine/Bow-Bridging-Header.h, e2e test names)' "$tmp/out" && echo yes)"

[ "$failed" -eq 0 ] && echo "test-check-lists: ok" || { echo "test-check-lists: FAIL"; exit 1; }
