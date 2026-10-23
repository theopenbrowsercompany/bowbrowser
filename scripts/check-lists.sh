#!/bin/sh
# Checks the registration lists that git merges by union (see .gitattributes). A union merge keeps every line both
# sides added, so these lists stay one entry per line, and this check fails on what a merge can get wrong:
#   - the Swift lists (WindowFeatures, AppFeatures, E2EAreas, and the sidebar's section, menu and drop rule lists): a
#     line inside the `static let all ... = [` literal that is not exactly one `Name.self,` or `Name.all,` entry, or
#     the same entry twice;
#   - the bridging header: an #import line that is not one `#import "File.h"` (with an optional // comment), or
#     the same header imported twice;
#   - the e2e tests: two tests with the same `let name = "..."` in E2E/Tests (the form every test uses; the runner's
#     E2ETests.checkUnique catches any other duplicate when a run starts).
set -eu

cd "$(dirname "$0")/.."

swift_lists="App/UI/Window/WindowFeatures.swift App/UI/App/AppFeatures.swift E2E/Tests/E2EAreas.swift
  App/UI/Sidebar/SidebarSectionList.swift App/UI/Sidebar/SidebarMenuList.swift App/UI/Sidebar/SidebarDropRuleList.swift"
header=App/Engine/Bow-Bridging-Header.h
failed=0

fail() {
  echo "lists: $1" >&2
  failed=1
}

for file in $swift_lists; do
  [ -f "$file" ] || { fail "$file is missing"; continue; }
  entries=$(awk -v file="$file" '
    /static let all: .* = \[$/ { inside = 1; found = 1; next }
    inside && /^    \]$/ { inside = 0; closed = 1; next }
    inside {
      if ($0 !~ /^        [A-Z][A-Za-z0-9_]*\.(self|all),$/) {
        printf "%s:%d: not one entry with a trailing comma: %s\n", file, NR, $0 > "/dev/stderr"
        bad = 1
      }
      print $0
    }
    END {
      if (!found || !closed) { printf "%s: no one-entry-per-line `static let all ... = [` list\n", file > "/dev/stderr"; bad = 1 }
      exit bad
    }
  ' "$file") || failed=1
  duplicates=$(printf '%s\n' "$entries" | sed 's/^ *//; s/,$//' | sort | uniq -d)
  for entry in $duplicates; do fail "$file lists $entry twice"; done
done

bad_imports=$(grep -n '#import' "$header" | grep -Ev '^[0-9]+:#import "[A-Za-z0-9_+]+\.h"( +//.*)?$' || true)
[ -z "$bad_imports" ] || fail "$header: not one #import per line: $bad_imports"
duplicates=$(sed -n 's/^#import "\([^"]*\)".*/\1/p' "$header" | sort | uniq -d)
for entry in $duplicates; do fail "$header imports $entry twice"; done

duplicates=$(grep -ho 'let name = "[^"]*"' E2E/Tests/*.swift | sort | uniq -d | sed 's/let name = //')
for entry in $duplicates; do fail "two e2e tests are named $entry"; done

[ "$failed" -eq 0 ] || exit 1
echo "lists: ok ($(echo "$swift_lists" | wc -w | tr -d ' ') Swift lists, the bridging header, e2e test names)"
