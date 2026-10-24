#!/bin/sh
# Prints, one per line, the names the e2e harness in E2E/ declares and app code must not use outside its seams:
#   Swift: top-level types, protocols, funcs, lets and vars, and members of extensions on types that are not
#     the harness's own (members of extensions on harness types are only reachable through those types);
#   Objective-C and C headers: classes, protocols, functions and extern constants;
#   the seam header App/Engine/BowE2EHooks.h: the hooks it declares, and its own name.
# Private and fileprivate declarations, typedefs and all-caps macro names never count.
# With --symbols, prints only types, classes, protocols, C functions and extern constants: top-level Swift funcs,
# lets and vars and extension members are too generic to look for in a binary.
set -eu

cd "$(dirname "$0")/.."

symbols_only=no
[ "${1:-}" = "--symbols" ] && symbols_only=yes

swift_files=$(find E2E -name '*.swift' | sort)
hooks=App/Engine/BowE2EHooks.h
headers=$(find E2E -name '*.h' | sort)
# The seam header goes away with the CEF bridge: without it there are no hooks to list, and the note names it.
if [ -f "$hooks" ]; then
  headers="$headers $hooks"
else
  echo "e2e-names: no seam header $hooks, listing nothing for it" >&2
fi

# Strips attributes and modifiers, then prints "<keyword> <name>" for a declaration line, or nothing.
declaration='
function declared(line,    parts) {
  sub(/^[[:space:]]+/, "", line)
  # Private and fileprivate names cannot leak out of their file, so they never count.
  if (line ~ /^(@[^ ]+[[:space:]]+)*([a-z]+[[:space:]]+)*(private|fileprivate)[[:space:]]/) return ""
  while (line ~ /^@[A-Za-z_]+(\([^)]*\))?[[:space:]]+/) sub(/^@[A-Za-z_]+(\([^)]*\))?[[:space:]]+/, "", line)
  while (line ~ /^(public|internal|private|fileprivate|final|nonisolated|static|class|override|mutating|convenience|required)[[:space:]]+(class|struct|enum|protocol|actor|func|let|var|typealias|extension|static|final|private|fileprivate|internal|public|nonisolated|override|mutating|convenience|required)[[:space:]]/)
    sub(/^[a-z]+[[:space:]]+/, "", line)
  if (line !~ /^(class|struct|enum|protocol|actor|func|let|var|typealias|extension)[[:space:]]/) return ""
  split(line, parts, /[^A-Za-z0-9_]+/)
  return parts[1] " " parts[2]
}
function braces(line,    opens, closes) {
  opens = gsub(/\{/, "{", line); closes = gsub(/\}/, "}", line)
  return opens - closes
}
'

types=$(awk "$declaration"'
  FNR == 1 { depth = 0 }
  { d = declared($0); if (depth == 0 && d != "" && d !~ /^(func|let|var|extension) /) { split(d, p, " "); print p[2] } }
  { depth += braces($0) }
' $swift_files | sort -u)

{
  echo "$types"
  awk -v types=" $(echo $types) " -v symbols_only="$symbols_only" "$declaration"'
    FNR == 1 { depth = 0; extension_depth = -1 }
    {
      d = declared($0)
      if (d != "") {
        split(d, p, " ")
        if (depth == 0 && p[1] ~ /^(func|let|var)$/ && symbols_only == "no") print p[2]
        if (depth == 0 && p[1] == "extension" && index(types, " " p[2] " ") == 0) extension_depth = 1
        if (depth == extension_depth && p[1] ~ /^(func|let|var)$/ && symbols_only == "no") print p[2]
      }
      depth += braces($0)
      if (depth < extension_depth) extension_depth = -1
    }
  ' $swift_files
  # Headers: classes and protocols, then C functions and extern constants outside @interface blocks.
  # Comment lines are skipped so names mentioned in documentation do not count.
  # No header at all: awk would wait on stdin.
  [ -z "$headers" ] || awk '
    /^[[:space:]]*\/\// { next }
    /^@(interface|protocol)[[:space:]]/ { split($0, p, /[^A-Za-z0-9_@]+/); print p[2]; inside = ($0 !~ /;[[:space:]]*$/); next }
    /^@end/ { inside = 0; next }
    inside || /^[[:space:]]*[#@+-]/ { next }
    /^extern[[:space:]].*;/ { line = $0; sub(/[[:space:]]*;.*/, "", line); n = split(line, p, /[^A-Za-z0-9_]+/); print p[n] }
    /^typedef[[:space:]]/ { next }
    /^[A-Za-z_].*[[:space:]*&]+[A-Za-z_][A-Za-z0-9_]*\(/ {
      line = $0; sub(/\(.*/, "", line); n = split(line, p, /[^A-Za-z0-9_]+/); print p[n]
    }
  ' $headers
  [ ! -f "$hooks" ] || echo BowE2EHooks
} | grep -v '^$' | grep -vE '^[A-Z0-9_]+$' | sort -u
