#!/bin/sh
# Fails when app code (App/, BowCore/) reaches into the e2e harness outside its declared seams.
#
# Harness names are the E2E/ folder, every type and Objective-C class declared under E2E/, any E2E-prefixed
# name, the seam header BowE2EHooks.h and the hooks it declares. App code may use one only on a line inside
# an `#if BOW_E2E` block where that line, or the block's `#if` line, is marked "E2E seam". BowE2EHooks.h itself
# is exempt. A use anywhere else would break Release builds, which leave the harness out.
set -eu

cd "$(dirname "$0")/.."

hooks=App/Engine/BowE2EHooks.h

# Names declared by the harness and by the seam header.
names=$(
  {
    sed -nE 's/^[[:space:]]*((public|internal|private|fileprivate|final|@MainActor)[[:space:]]+)*(class|struct|enum|protocol|actor)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*/\4/p' \
      $(find E2E -name '*.swift')
    sed -nE 's/^@interface[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*/\1/p' $(find E2E -name '*.h')
    cat $(find E2E -name '*.h') "$hooks" | grep -vE '^[[:space:]]*//' | grep -oE 'Bow[A-Za-z0-9_]+' | grep -vE '^Bow(Engine|WebView)$|^BowEngineConfiguration$'
    echo BowE2EHooks
  } | sort -u | paste -sd '|' -
)
pattern="(^|[^A-Za-z0-9_])(E2E/|E2E[A-Z][A-Za-z0-9_]*|$names)([^A-Za-z0-9_]|\$)"

violations=$(
  find App BowCore -path BowCore/.build -prune -o \
    \( -name '*.swift' -o -name '*.h' -o -name '*.m' -o -name '*.mm' \) -type f -print |
    grep -v "^$hooks\$" |
    while read -r file; do
      awk -v pattern="$pattern" -v file="$file" '
        # Each open #if: 0 not about BOW_E2E, 1 inside #if BOW_E2E, 2 inside a marked #if BOW_E2E, 3 its #else.
        /^[[:space:]]*#if/ {
          kind = 0
          if ($0 ~ /BOW_E2E/ && $0 !~ /!/) kind = ($0 ~ /E2E seam/) ? 2 : 1
          stack[++depth] = kind
        }
        /^[[:space:]]*#(else|elseif|elif)/ { if (stack[depth] > 0) stack[depth] = 3 }
        /^[[:space:]]*#endif/ { depth--; next }
        $0 ~ pattern && $0 !~ /^[[:space:]]*#(if|else|elseif|elif|endif)/ {
          inside = 0; marked = ($0 ~ /E2E seam/)
          for (i = 1; i <= depth; i++) {
            if (stack[i] == 1 || stack[i] == 2) inside = 1
            if (stack[i] == 2) marked = 1
          }
          if (!inside) print file ":" FNR ": outside #if BOW_E2E: " $0
          else if (!marked) print file ":" FNR ": not marked \"E2E seam\": " $0
        }
      ' "$file"
    done
)

if [ -n "$violations" ]; then
  echo "App code reaches into the e2e harness outside its seams:" >&2
  echo "$violations" >&2
  exit 1
fi
echo "e2e seams: ok"
