#!/bin/bash
# Prints the e2e selection (one E2E= value) for what a change touches: a comma list of areas ending in smoke, all,
# or an empty line when no e2e test needs to run. make check runs it; make verify and the full make e2e still run
# everything at the end.
#
#   scripts/e2e-affected.sh [--why] [--stdin | --changed]
#
# The changed files are those that differ from where the branch left origin/main (its merge base), committed,
# staged, unstaged or untracked, so a branch behind origin/main does not count main's newer commits. Renames count
# as the old path deleted and the new one added. --stdin reads the changed paths from stdin instead, one per line
# (the self test uses it). --changed prints the changed paths, one per line, and maps nothing; it exits 3 when they
# cannot be listed. --why prints each path's mapping to stderr. CHECK_BASE=<ref> compares with another ref.
# Without the ref or a merge base, the selection is all.
#
# The mapping, kept simple: when unsure, all.
#   docs (*.md anywhere, spec/)                     nothing
#   BowCore/                                        smoke (make check also runs the BowCore unit tests)
#   BowWebKit/                                      nothing: the app does not link it yet, and make check runs its
#                                                   package tests (until the app runs on it, then smoke or more)
#   E2E/Tests/<File>.swift                          the areas of the tests the file names (`let name = "<area>.x"`),
#                                                   and those of every test file using a top level name it declares
#                                                   (a helper such as SidebarWaits), followed through their users;
#                                                   all when the file is gone or names no test (E2EAreas.swift), or
#                                                   one of them declares a top level extension
#   E2E/Fixtures/<folder>/                          the area named <folder>, and the areas of every test file that
#                                                   loads "<folder>/..." fixtures and of their users as above; all
#                                                   when there is none
#   a file or folder in the table below             its areas
#   anything else (App/, E2E/Harness/, E2E/Engine/, project.yml, scripts/, the Makefile, cef.lock, ...)   all
# smoke is added to every selection that is neither all nor empty.
set -u
cd "$(dirname "$0")/.." || exit 1

# Files and folders whose e2e tests are known, as "<path prefix> <areas, comma separated>". sidebar is in every
# entry because its menu shortcut test (sidebar.menu-shortcuts) looks up every feature's menu items; unload is in
# the permission entry because an unload test answers a permission prompt.
table='
App/UI/FindBar.swift find,sidebar
App/UI/Window/FindFeature.swift find,sidebar
App/UI/Downloads/ downloads,sidebar
App/UI/Window/DownloadsFeature.swift downloads,sidebar
App/UI/App/DownloadsCenter.swift downloads,sidebar
App/UI/Engine/CEFDownloads.swift downloads,sidebar
App/UI/PermissionPrompts.swift permissions,unload,sidebar
App/UI/Window/PermissionsFeature.swift permissions,unload,sidebar
App/UI/App/SitePermissionStores.swift permissions,unload,sidebar
'

why=0 stdin=0 list=0
for arg in "$@"; do
  case $arg in
    --why) why=1 ;;
    --stdin) stdin=1 ;;
    --changed) list=1 ;;
    *) echo "e2e-affected: unknown argument $arg" >&2; exit 64 ;;
  esac
done
say() { [ "$why" = 1 ] && echo "e2e-affected: $*" >&2; return 0; }

# The areas of the tests a Swift file names, one per line.
areas_in() { [ -f "$1" ] && sed -n 's/.*let name = "\([^".]*\).*/\1/p' "$1" | sort -u; }

# The names a Swift file declares at the top level (column 0, not private or fileprivate), one per line: the types,
# functions and constants other test files can call, such as SidebarWaits or TabEdgesTests.until.
declared_in() {
  sed -nE 's/^((public|internal|final|nonisolated|@[A-Za-z]+) +)*(struct|enum|class|actor|protocol|typealias|func|let|var) +([A-Za-z_][A-Za-z0-9_]*).*/\4/p' "$1" | sort -u
}

# The given test files (one per line) and every test file that uses a name one of them declares, followed through
# the files that use those, one per line; or "all" when one of them declares a top level extension, whose members
# cannot be traced by name.
users_of() {
  local set=$1 todo=$1 f n u
  while [ -n "$todo" ]; do
    f=$(echo "$todo" | head -1)
    todo=$(echo "$todo" | sed 1d)
    [ -n "$f" ] || continue
    if grep -qE '^((public|internal|nonisolated|@[A-Za-z]+) +)*extension ' "$f"; then
      echo all
      return
    fi
    for n in $(declared_in "$f"); do
      for u in E2E/Tests/*.swift; do
        echo "$set" | grep -qxF "$u" && continue
        grep -qw -- "$n" "$u" || continue
        set=$(printf '%s\n%s' "$set" "$u")
        todo=$(printf '%s\n%s' "$todo" "$u")
      done
    done
  done
  echo "$set"
}

# The areas of the tests in the given test files and in every test file that uses their declarations, one per line;
# or "all" when that cannot be traced.
areas_with_users() {
  local files
  files=$(users_of "$1")
  if [ "$files" = all ]; then
    echo all
    return
  fi
  for u in $files; do areas_in "$u"; done | sort -u
}

all() {
  say "$1: all"
  echo all
  exit 0
}
# The changed files cannot be listed: all, or for --changed no output and exit 3.
unknown() {
  [ "$list" = 1 ] && {
    echo "e2e-affected: $1" >&2
    exit 3
  }
  all "$1"
}

if [ "$stdin" = 1 ]; then
  changed=$(cat)
else
  base=${CHECK_BASE:-origin/main}
  git rev-parse -q --verify "$base^{commit}" > /dev/null 2>&1 || unknown "no $base ref"
  fork=$(git merge-base "$base" HEAD 2> /dev/null) || unknown "no merge base with $base"
  committed=$(git diff --name-only --no-renames "$fork" --) || unknown "git diff failed"
  untracked=$(git ls-files --others --exclude-standard) || unknown "git ls-files failed"
  changed=$(printf '%s\n%s\n' "$committed" "$untracked" | grep -v '^$' | sort -u)
fi
if [ "$list" = 1 ]; then
  [ -z "$changed" ] || echo "$changed"
  exit 0
fi

areas=""
add() { areas=$(printf '%s\n%s' "$areas" "$(echo "$1" | tr ',' '\n')"); }

while IFS= read -r f; do
  [ -n "$f" ] || continue
  case $f in
    *.md | spec/*)
      say "$f: nothing (docs)"
      continue
      ;;
    BowCore/*)
      say "$f: smoke (BowCore)"
      add smoke
      continue
      ;;
    BowWebKit/*)
      say "$f: nothing (BowWebKit, not linked into the app yet; make check runs its tests)"
      continue
      ;;
    E2E/Tests/*/*) all "$f" ;;
    E2E/Tests/*.swift)
      [ -n "$(areas_in "$f")" ] || all "$f (no test names)"
      found=$(areas_with_users "$f")
      [ "$found" != all ] || all "$f (a top level extension it or a file using it declares)"
      say "$f: $(echo "$found" | paste -sd, -)"
      add "$found"
      continue
      ;;
    E2E/Fixtures/*/*)
      folder=${f#E2E/Fixtures/}
      folder=${folder%%/*}
      loaders=""
      for t in E2E/Tests/*.swift; do
        if areas_in "$t" | grep -qx "$folder" || grep -q "\"$folder/" "$t"; then
          loaders=$(printf '%s\n%s' "$loaders" "$t")
        fi
      done
      loaders=$(echo "$loaders" | grep -v '^$')
      [ -n "$loaders" ] || all "$f (no tests use $folder/)"
      found=$(areas_with_users "$loaders")
      [ "$found" != all ] || all "$f (a top level extension in a test file using $folder/)"
      [ -n "$found" ] || all "$f (no tests use $folder/)"
      say "$f: $(echo "$found" | paste -sd, -)"
      add "$found"
      continue
      ;;
  esac
  mapped=""
  # A path ending in / maps every file under it; any other path maps only itself.
  while read -r path to; do
    case $path in
      "") continue ;;
      */) case $f in "$path"*) mapped=$to ;; esac ;;
      *) [ "$f" = "$path" ] && mapped=$to ;;
    esac
    [ -z "$mapped" ] || break
  done <<< "$table"
  [ -n "$mapped" ] || all "$f (unmapped)"
  say "$f: $mapped (table)"
  add "$mapped"
done <<< "$changed"

# Empty when only docs and BowWebKit/ changed; otherwise the areas (sorted, without smoke) followed by smoke.
areas=$(echo "$areas" | grep -v '^$' | sort -u)
if [ -z "$areas" ]; then
  echo ""
else
  echo "$areas" | grep -vx smoke | sed 's/$/,/' | tr -d '\n'
  echo smoke
fi
