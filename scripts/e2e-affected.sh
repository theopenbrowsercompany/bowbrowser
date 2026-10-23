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
#   E2E/Tests/<File>.swift                          the areas of the tests the file names (`let name = "<area>.x"`);
#                                                   all when the file is gone or names no test (E2EAreas.swift)
#   E2E/Fixtures/<folder>/                          the area named <folder>, and the areas of every test file that
#                                                   loads "<folder>/..." fixtures; all when there is none
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
    E2E/Tests/*/*) all "$f" ;;
    E2E/Tests/*.swift)
      found=$(areas_in "$f")
      [ -n "$found" ] || all "$f (no test names)"
      say "$f: $(echo "$found" | paste -sd, -)"
      add "$found"
      continue
      ;;
    E2E/Fixtures/*/*)
      folder=${f#E2E/Fixtures/}
      folder=${folder%%/*}
      found=""
      for t in E2E/Tests/*.swift; do
        if areas_in "$t" | grep -qx "$folder" || grep -q "\"$folder/" "$t"; then
          found=$(printf '%s\n%s' "$found" "$(areas_in "$t")")
        fi
      done
      found=$(echo "$found" | grep -v '^$' | sort -u)
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

# Empty when only docs changed; otherwise the areas (sorted, without smoke) followed by smoke.
areas=$(echo "$areas" | grep -v '^$' | sort -u)
if [ -z "$areas" ]; then
  echo ""
else
  echo "$areas" | grep -vx smoke | sed 's/$/,/' | tr -d '\n'
  echo smoke
fi
