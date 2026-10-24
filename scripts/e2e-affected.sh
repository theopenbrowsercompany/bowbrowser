#!/bin/bash
# Prints the e2e selection (one E2E= value) for what a change touches: a comma list of areas ending in smoke, all,
# or an empty line when no e2e test needs to run. make check runs it; make verify and the full make e2e still run
# everything at the end.
#
#   scripts/e2e-affected.sh [--why] [--stdin | --changed | --callers]
#
# --callers prints the e2e tests that reach a symbol the branch changes or adds under E2E/Harness/ or E2E/Engine/,
# found with a plain text search, one per line as `direct <changed symbols that reach it> <test>` or, for a test only
# the fallback added, `fallback 0 <test>`; stderr says (lines starting `callers:`) which symbols were changed and which
# were too common to search. make done repeats them. The rules are above callers_main below.
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

why=0 stdin=0 list=0 callers=0
for arg in "$@"; do
  case $arg in
    --why) why=1 ;;
    --stdin) stdin=1 ;;
    --changed) list=1 ;;
    --callers) callers=1 ;;
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
  if [ "$list" = 1 ] || [ "$callers" = 1 ]; then
    echo "e2e-affected: $1" >&2
    exit 3
  fi
  all "$1"
}

# ---- --callers: the e2e tests that reach a changed harness symbol ----------------------------------------------------
#
# For every changed file under E2E/Harness/ and E2E/Engine/ (a deleted one adds nothing: what called it no longer
# builds), the symbols whose lines changed or that the branch adds: the function, property, type or enum case a
# changed line sits in (a Swift member of a type or of the file, found by indentation; an Objective-C method, or the
# class for a line outside one). A function is searched as `name(label:` for its first argument label, and as its bare
# name when that label is `_` or it takes none (a call may be a trailing closure). A comment, a blank line or a lone
# brace changes no symbol. With --stdin every line of the listed files counts as changed.
# The callers come from a plain text search, the same every run:
#   1. the tests in E2E/Tests/*.swift whose body (the struct holding `let name = "..."`) mentions the symbol; a
#      mention outside any test (a helper of the test file) counts for every test of that file;
#   2. one level up: the members of other E2E/Harness/*.swift files that mention the symbol are symbols too, and the
#      tests that mention those count. A symbol that is itself too common to search stops there.
# A symbol is too common when its text matches CALLERS_COMMON (default 12) or more test files. A too common symbol
# falls back to the named smoke set (every test tagged smoke) plus every test in the areas (the name before the first
# dot) of the test files that name a top level declaration of the changed file; the stderr note says which symbols.
# Output: the test names, one per line, sorted; notes on stderr, each starting `callers:`. Exit 3 when the changed
# files cannot be listed. Not covered: a symbol reached only through a rename, a protocol default, a closure stored
# elsewhere or a string key; a call whose label sits on the next line; a symbol deleted from a file.

# members_of <swift file>: one row per member (tab separated: start line, end line, kind, display, grep pattern). The
# kind is M for a func, var, let, init or enum case that is a member of a type or of the file (not a local), and T for
# the declaration line of a type or typealias. A declaration inside a function body is a local and gets no row.
members_of() {
  awk '
  function ident(s) { if (match(s, /^[A-Za-z_][A-Za-z0-9_]*/)) return substr(s, 1, RLENGTH); return "" }
  function word(n) { return "(^|[^A-Za-z0-9_])" n "([^A-Za-z0-9_]|$)" }
  function emit(s, e, kind, disp, re, par) { printf "%d\t%d\t%s\t%s\t%s\t%d\n", s, e, kind, disp, re, par }
  {
    copy = $0
    tq = gsub(/"""/, "", copy)
    if (inq) { if (tq % 2 == 1) inq = 0; next }
    if (tq % 2 == 1) inq = 1
    line = $0
    if (line ~ /^[ \t]*$/) next
    ind = match(line, /[^ \t]/) - 1
    st = substr(line, ind + 1)
    if (st ~ /^\/\// || st ~ /^#/) next
    cont = (st ~ /^[])]/)
    closing = (st ~ /^}/)
    while (nopen > 0 && (oind[nopen] > ind || (oind[nopen] == ind && !cont))) {
      emit(ostart[nopen], (closing && oind[nopen] == ind) ? NR : NR - 1, "M", odisp[nopen], ore[nopen], opar[nopen])
      nopen--
    }
    while (sp > 0 && (sind[sp] > ind || (sind[sp] == ind && !cont))) sp--
    s = st
    while (match(s, /^(@[A-Za-z]+(\([^)]*\))?|(public|internal|private|fileprivate|open|final|static|override|mutating|nonisolated|indirect|lazy|weak|convenience|required|dynamic|optional|prefix|postfix|unowned)(\([a-z]+\))?) +/)) s = substr(s, RLENGTH + 1)
    if (s ~ /^class (func|var|let) /) s = substr(s, 7)
    if (!match(s, /^(func|var|let|struct|class|enum|protocol|actor|typealias|case|init|subscript|extension)([^A-Za-z0-9_]|$)/)) next
    kind = s
    sub(/[^a-z].*$/, "", kind)
    rest = substr(s, length(kind) + 1)
    sub(/^ +/, "", rest)
    top = (sp > 0) ? skind[sp] : ""
    member = (sp == 0 || top ~ /^(struct|class|enum|protocol|actor|extension)$/)
    par = (top ~ /^(struct|class|enum|actor|protocol)$/) ? sline[sp] : 0
    name = (kind == "init") ? "init" : ident(rest)
    if (name == "" || name == "let" || name == "var") next
    if (kind == "case" && top != "enum") next
    if (kind ~ /^(struct|class|enum|protocol|actor|extension)$/) {
      sp++; sind[sp] = ind; skind[sp] = kind; sname[sp] = name; sline[sp] = NR
      if (member && kind != "extension") emit(NR, NR, "T", name, word(name), par)
      next
    }
    if (kind == "typealias") { if (member) emit(NR, NR, "T", name, word(name), par); next }
    if (kind == "case") { if (member) emit(NR, NR, "M", name, word(name), par); next }
    # func, var, let, init
    disp = name; re = word(name)
    if (kind == "init") { disp = (sp > 0 ? sname[sp] : "init"); re = word(disp) }
    if (kind == "func") {
      p = substr(rest, length(name) + 1)
      if (p ~ /^</ && match(p, />[ ]*\(/)) p = substr(p, RSTART + RLENGTH - 1)
      label = ""
      if (p ~ /^\(/) {
        q = substr(p, 2); a = ident(q); after = substr(q, length(a) + 1)
        if (a != "" && a != "_" && (after ~ /^:/ || after ~ /^ +[A-Za-z_]/)) label = a
      }
      if (label != "") { disp = name "(" label ":"; re = "(^|[^A-Za-z0-9_])" name "\\(" label ":" }
    }
    sp++; sind[sp] = ind; skind[sp] = kind; sname[sp] = name; sline[sp] = NR
    if (member) { nopen++; ostart[nopen] = NR; oind[nopen] = ind; odisp[nopen] = disp; ore[nopen] = re; opar[nopen] = par }
  }
  END { while (nopen > 0) { emit(ostart[nopen], NR, "M", odisp[nopen], ore[nopen], opar[nopen]); nopen-- } }
  ' "$1"
}


# test_blocks <test file>: one row per test (tab separated: file, start, end, name, smoke 0 or 1): the struct (or
# class, enum, actor) conforming to E2ETest, from its declaration to its closing brace. Its names are its stored
# `let name = "..."` literals, or, for a type with none, the names it is constructed with in the file
# (`<Type>(name: "...")`, one row per name over the same lines, as the popups tests are).
test_blocks() {
  awk -v FILE="$1" '
  {
    lines[NR] = $0
    ind[NR] = ($0 ~ /[^ \t]/) ? match($0, /[^ \t]/) - 1 : -1
  }
  END {
    for (i = 1; i <= NR; i++) {
      if (lines[i] !~ /^[ \t]*((final|private|fileprivate|public|internal) +)*(struct|class|enum|actor) +[A-Za-z0-9_]+ *:[^{]*(^|[^A-Za-z0-9_])E2ETest([^A-Za-z0-9_]|$)/) continue
      type = lines[i]
      sub(/^[ \t]*((final|private|fileprivate|public|internal) +)*(struct|class|enum|actor) +/, "", type)
      sub(/[^A-Za-z0-9_].*$/, "", type)
      e = NR
      for (j = i + 1; j <= NR; j++) if (ind[j] >= 0 && ind[j] <= ind[i]) { e = j; break }
      delete names
      nn = 0; smoke = 0
      for (j = i; j <= e; j++) {
        if (match(lines[j], /let name = "[^"]*"/)) names[++nn] = substr(lines[j], RSTART + 12, RLENGTH - 13)
        if (lines[j] ~ /tags *= *\[[^]]*"smoke"/) smoke = 1
      }
      if (nn == 0) {
        key = type "(name: \""
        for (j = 1; j <= NR; j++) {
          t = lines[j]
          while ((p = index(t, key)) > 0) {
            t = substr(t, p + length(key))
            q = index(t, "\"")
            names[++nn] = substr(t, 1, q - 1)
            t = substr(t, q + 1)
          }
        }
      }
      for (k = 1; k <= nn; k++) printf "%s\t%d\t%d\t%s\t%d\n", FILE, i, e, names[k], smoke
    }
  }' "$1"
}

# changed_lines_of <file>: the line numbers of the file the branch changes (committed, staged or not), one per line;
# every line for a file the base does not have, and with --stdin. A hunk that only deletes lines gives the two lines
# around the gap with a trailing `!`, which meaningful_lines keeps whatever they hold: removing a wait or a guard
# from a helper changes it.
changed_lines_of() {
  if [ "$stdin" = 1 ] || ! git cat-file -e "$fork:$1" 2> /dev/null; then
    awk '{ print NR }' "$1"
  else
    git diff -U0 --no-renames "$fork" -- "$1" | awk '/^@@/ {
      s = substr($3, 2); n = split(s, p, ","); c = (n > 1) ? p[2] : 1
      if (c == 0) { if (p[1] > 0) print p[1] "!"; print (p[1] + 1) "!" }
      for (i = 0; i < c; i++) print p[1] + i
    }'
  fi
}

# meaningful_lines <file> <line numbers, one per line>: those that are code, not a comment, a blank or a lone brace
# (a number with a trailing `!` is kept as it is).
meaningful_lines() {
  awk -v ls="$(echo "$2" | paste -sd, -)" '
    BEGIN {
      n = split(ls, a, ",")
      for (i = 1; i <= n; i++) {
        if (a[i] ~ /!$/) { sub(/!$/, "", a[i]); force[a[i]] = 1 }
        ch[a[i]] = 1
      }
    }
    (FNR in ch) && ((FNR in force) || $0 !~ /^[ \t]*(\/\/.*|[]{}(),;]*)$/) { print FNR }' "$1"
}

# swift_symbols <file> <meaningful changed lines>: "display<TAB>pattern" for each symbol those lines sit in.
swift_symbols() {
  members_of "$1" | awk -F'\t' -v ls="$(echo "$2" | paste -sd, -)" '
    # A member of a type whose own declaration line changed (a new type) is covered by the type name.
    BEGIN { n = split(ls, a, ","); for (i = 1; i <= n; i++) ch[a[i]] = 1 }
    $3 == "M" && $6 != 0 && ($6 in ch) { next }
    { for (i = 1; i <= n; i++) if (($3 == "M" && a[i] >= $1 && a[i] <= $2) || ($3 == "T" && a[i] == $1)) { print $4 "\t" $5; break } }'
}

# objc_symbols <file> <meaningful changed lines>: "display<TAB>pattern" for the Objective-C method each line sits in
# (its first selector part), or the class (@interface, @implementation, @protocol) for a line outside any method.
objc_symbols() {
  awk -v ls="$(echo "$2" | paste -sd, -)" '
  function word(n) { return "(^|[^A-Za-z0-9_])" n "([^A-Za-z0-9_]|$)" }
  function sel(s,   d, i, c) {
    d = 0
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c == "(") d++
      else if (c == ")") { d--; if (d == 0) break }
    }
    s = substr(s, i + 1)
    sub(/^ +/, "", s)
    if (match(s, /^[A-Za-z_][A-Za-z0-9_]*/)) return substr(s, 1, RLENGTH)
    return ""
  }
  { lines[NR] = $0 }
  END {
    n = split(ls, a, ",")
    for (i = 1; i <= n; i++) {
      name = ""
      for (j = a[i]; j >= 1; j--) {
        l = lines[j]
        if (l ~ /^[-+] *\(/) { name = sel(substr(l, 2)); break }
        if (l ~ /^@(interface|implementation|protocol) /) {
          sub(/^@[a-z]+ +/, "", l)
          if (match(l, /^[A-Za-z_][A-Za-z0-9_]*/)) name = substr(l, 1, RLENGTH)
          break
        }
      }
      if (name != "" && !(name in seen)) { seen[name] = 1; print name "\t" word(name) }
    }
  }' "$1"
}

callers_main() {
  local f lines disp re hf hl qdisp qre mf common_limit
  common_limit=${CALLERS_COMMON:-12}
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  local harness_files
  harness_files=$(echo "$changed" | grep -E '^E2E/(Harness|Engine)/.+\.(swift|h|mm)$')
  [ -n "$harness_files" ] || return 0

  : > "$tmp/blocks"
  for f in E2E/Tests/*.swift; do test_blocks "$f" >> "$tmp/blocks"; done

  # The changed symbols.
  : > "$tmp/primary"
  : > "$tmp/declared"
  : > "$tmp/common"
  local syms
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    lines=$(meaningful_lines "$f" "$(changed_lines_of "$f")")
    [ -n "$lines" ] || continue
    case $f in
      *.swift)
        syms=$(swift_symbols "$f" "$lines")
        declared_in "$f" >> "$tmp/declared"
        ;;
      *) syms=$(objc_symbols "$f" "$lines") ;;
    esac
    # Code changed but no symbol could be read from the lines (a construct the parser does not follow): the
    # fallback applies, so the change is never reported as reaching nothing.
    if [ -n "$syms" ]; then echo "$syms" >> "$tmp/primary"; else echo "$f (changed lines in no symbol it can read)" >> "$tmp/common"; fi
  done <<< "$harness_files"
  sort -u "$tmp/primary" -o "$tmp/primary"
  [ -s "$tmp/primary" ] || [ -s "$tmp/common" ] || return 0

  : > "$tmp/found"
  : > "$tmp/symbols"
  # resolve <pattern> <display>: adds the tests that mention it to found; returns 1 when it is too common.
  resolve() {
    grep -nHE -- "$1" E2E/Tests/*.swift 2> /dev/null | awk -F: '{
      t = substr($0, length($1) + length($2) + 3)
      if (t !~ /^[ \t]*\/\//) printf "%s\t%s\n", $1, $2
    }' > "$tmp/hits"
    local nfiles
    nfiles=$(cut -f1 "$tmp/hits" | sort -u | grep -c .)
    if [ "$nfiles" -ge "$common_limit" ]; then
      echo "$2 ($nfiles test files)" >> "$tmp/common"
      return 1
    fi
    awk -F'\t' 'FNR == NR { n++; bf[n] = $1; bs[n] = $2; be[n] = $3; bn[n] = $4; next }
      { found = 0
        for (b = 1; b <= n; b++) if (bf[b] == $1 && $2 >= bs[b] && $2 <= be[b]) { print bn[b]; found = 1 }
        if (!found) for (b = 1; b <= n; b++) if (bf[b] == $1) print bn[b] }' "$tmp/blocks" "$tmp/hits" | sort -u >> "$tmp/found"
  }

  while IFS=$'\t' read -r disp re; do
    echo "$disp" >> "$tmp/symbols"
    resolve "$re" "$disp" || continue
    # One level up: the members of harness files that mention the symbol.
    grep -nHE -- "$re" E2E/Harness/*.swift 2> /dev/null | awk -F: '{
      t = substr($0, length($1) + length($2) + 3)
      if (t !~ /^[ \t]*\/\//) printf "%s\t%s\n", $1, $2
    }' | sort -u > "$tmp/hh"
    while IFS=$'\t' read -r hf hl; do
      mf=$tmp/members.$(echo "$hf" | tr '/' '_')
      [ -f "$mf" ] || members_of "$hf" > "$mf"
      awk -F'\t' -v l="$hl" '$3 == "M" && l >= $1 && l <= $2 { print $4 "\t" $5 }' "$mf"
    done < "$tmp/hh" | sort -u > "$tmp/secondary"
    while IFS=$'\t' read -r qdisp qre; do
      [ "$qdisp" != "$disp" ] || continue
      resolve "$qre" "$qdisp" || true
    done < "$tmp/secondary"
  done < "$tmp/primary"

  # Each test with the number of changed symbols that reached it (resolve adds a test once per symbol).
  grep -v '^$' "$tmp/found" | sort | uniq -c | awk '{ print $2 "\t" $1 }' > "$tmp/direct_counts"
  cut -f1 "$tmp/direct_counts" > "$tmp/direct"
  : > "$tmp/fallback"
  if [ -s "$tmp/common" ]; then
    # The named fallback: the smoke tests, and every test in the areas of the test files that name a top level
    # declaration of a changed file.
    awk -F'\t' '$5 == 1 { print $4 }' "$tmp/blocks" >> "$tmp/fallback"
    local names areas
    names=$(sort -u "$tmp/declared" | grep -v '^$' | paste -sd'|' -)
    : > "$tmp/area_files"
    [ -z "$names" ] || grep -lwE -- "$names" E2E/Tests/*.swift 2> /dev/null > "$tmp/area_files" || true
    areas=$(awk -F'\t' 'FNR == NR { f[$1] = 1; next } ($1 in f) { sub(/\..*$/, "", $4); print $4 }' "$tmp/area_files" "$tmp/blocks" | sort -u)
    for f in $areas; do awk -F'\t' -v a="$f" '{ n = $4; sub(/\..*$/, "", n); if (n == a) print $4 }' "$tmp/blocks" >> "$tmp/fallback"; done
    echo "callers: too common to search by name: $(sort -u "$tmp/common" | paste -sd, - | sed 's/,/, /g'); added the smoke tests and every test in the areas that call the changed files: $(echo "$areas" | paste -sd, - | sed 's/,/, /g')" >&2
  fi
  echo "callers: changed symbols: $(sort -u "$tmp/symbols" | paste -sd, - | sed 's/,/, /g')" >&2
  # `direct <symbols reached> <test>` for a test found by a symbol's name, `fallback 0 <test>` for one the fallback added.
  awk -F'\t' '{ print "direct " $2 " " $1 }' "$tmp/direct_counts"
  sort -u "$tmp/fallback" | grep -v '^$' | grep -vxFf "$tmp/direct" | sed 's/^/fallback 0 /'
}

if [ "$stdin" = 1 ]; then
  fork=""
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
if [ "$callers" = 1 ]; then
  callers_main
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
