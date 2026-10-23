#!/bin/sh
# Checks the registration lists that git merges by union (see .gitattributes). A union merge keeps every line both
# sides added, so these lists stay one entry per line, and this check fails on what a merge can get wrong:
#   - the Swift lists (WindowFeatures, AppFeatures, E2EAreas, and the sidebar's section, menu, drop rule and accessory
#     lists): a `static let all` line that does not open a list on its own (`    static let all: [...] = [`, with
#     the entries on the lines below and `    ]` alone on a later line), a list left open, a line inside a list
#     that is not exactly one `Name.self,` or `Name.all,` entry, or the same entry twice in one list (a file may
#     hold more than one list, and two lists may share an entry), or an entry whose type no Swift file under App/ or
#     E2E/ declares (a renamed entry a union merge kept beside the new one); a type a macro declares carries a
#     `// lists: declared by <macro>` comment on its entry line;
#   - the bridging header: an #import line that is not one `#import "File.h"` (with an optional // comment), or
#     the same header imported twice;
#   - the e2e tests: two tests with the same `let name = "..."` in E2E/Tests (the form every test uses; the runner's
#     E2ETests.checkUnique catches any other duplicate when a run starts).
set -eu

cd "$(dirname "$0")/.."
# The self test (scripts/test-check-lists.sh) runs this on a fixture tree.
[ -z "${LISTS_ROOT:-}" ] || cd "$LISTS_ROOT"

swift_lists="App/UI/Window/WindowFeatures.swift App/UI/App/AppFeatures.swift E2E/Tests/E2EAreas.swift
  App/UI/Sidebar/SidebarSectionList.swift App/UI/Sidebar/SidebarMenuList.swift App/UI/Sidebar/SidebarDropRuleList.swift
  App/UI/Sidebar/SidebarAccessoryList.swift"
header=App/Engine/Bow-Bridging-Header.h
failed=0

fail() {
  echo "lists: $1" >&2
  failed=1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
declared=$tmp/declared
# The names of the types, extensions and typealiases declared in App/ and E2E/ (a type a macro declares is
# allowed with a `// lists: declared by <macro>` comment on its entry line).
find App E2E -name '*.swift' -exec grep -hoE '\b(class|struct|enum|actor|extension|typealias)[[:space:]]+[A-Z][A-Za-z0-9_]*' {} + 2> /dev/null |
  awk '{ print $2 }' | sort -u > "$declared" || true

for file in $swift_lists; do
  [ -f "$file" ] || { fail "$file is missing"; continue; }
  # Each entry is printed as "<list number> <entry>", so duplicates are found per list.
  entries=$(awk -v file="$file" '
    /^ *static let all[:= ]/ {
      if (inside) { printf "%s:%d: a list opens before the one above it closes\n", file, NR > "/dev/stderr"; bad = 1 }
      inside = 0
      if ($0 !~ /^    static let all: .* = \[$/) {
        printf "%s:%d: not a `static let all: [...] = [` line opening a one-entry-per-line list: %s\n", file, NR, $0 > "/dev/stderr"
        bad = 1
        next
      }
      inside = 1; lists++; next
    }
    inside && /^    \]$/ { inside = 0; next }
    inside {
      if ($0 !~ /^        [A-Z][A-Za-z0-9_]*\.(self|all),( +\/\/ lists: declared by .+)?$/) {
        printf "%s:%d: not one entry with a trailing comma: %s\n", file, NR, $0 > "/dev/stderr"
        bad = 1
      }
      entry = $0; skip = ($0 ~ /\/\/ lists: declared by /) ? "macro" : "-"
      sub(/^ */, "", entry); sub(/,.*$/, "", entry)
      print lists, entry, NR, skip
    }
    END {
      if (inside) { printf "%s: a `static let all` list is not closed by a `    ]` line\n", file > "/dev/stderr"; bad = 1 }
      if (!lists) { printf "%s: no one-entry-per-line `static let all ... = [` list\n", file > "/dev/stderr"; bad = 1 }
      exit bad
    }
  ' "$file") || failed=1
  duplicates=$(printf '%s\n' "$entries" | awk 'NF { print $1, $2 }' | sort | uniq -d | sed 's/^[0-9]* //')
  for entry in $duplicates; do fail "$file lists $entry twice in one list"; done
  # Every entry names a type some Swift file declares (a union merge can keep a renamed entry beside its new name).
  printf '%s\n' "$entries" | while read -r _ entry line skip; do
    [ -n "${entry:-}" ] && [ "$skip" != macro ] || continue
    name=${entry%.*}
    grep -qx "$name" "$declared" || echo "lists: $file:$line: $name is declared nowhere (a stale entry after a rebase?)" >&2
  done 2> "$tmp/undeclared"
  if [ -s "$tmp/undeclared" ]; then cat "$tmp/undeclared" >&2; failed=1; fi
done

bad_imports=$(grep -n '#import' "$header" | grep -Ev '^[0-9]+:#import "[A-Za-z0-9_+]+\.h"( +//.*)?$' || true)
[ -z "$bad_imports" ] || fail "$header: not one #import per line: $bad_imports"
duplicates=$(sed -n 's/^#import "\([^"]*\)".*/\1/p' "$header" | sort | uniq -d)
for entry in $duplicates; do fail "$header imports $entry twice"; done

duplicates=$(grep -ho 'let name = "[^"]*"' E2E/Tests/*.swift | sort | uniq -d | sed 's/let name = //')
for entry in $duplicates; do fail "two e2e tests are named $entry"; done

[ "$failed" -eq 0 ] || exit 1
echo "lists: ok ($(echo "$swift_lists" | wc -w | tr -d ' ') Swift lists, the bridging header, e2e test names)"
