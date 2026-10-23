#!/bin/sh
# Fails when app code (App/, BowCore/) reaches into the e2e harness outside its declared seams.
#
# Harness names are the E2E/ folder, any E2E-prefixed name and everything scripts/e2e-names.sh lists.
# App code may use one only on a line inside a harness block, which opens with exactly `#if BOW_E2E` or
# `#ifdef BOW_E2E` (any other conditional that mentions BOW_E2E, such as `#ifndef BOW_E2E`, does not count),
# where the line or the block's opening line is marked "E2E seam". App/Engine/BowE2EHooks.h itself is exempt.
# A use anywhere else would break Release builds, which leave the harness out.
set -eu

cd "$(dirname "$0")/.."

hooks=App/Engine/BowE2EHooks.h
names=$(./scripts/e2e-names.sh | paste -sd '|' -)
pattern="(^|[^A-Za-z0-9_])(E2E/|E2E[A-Z][A-Za-z0-9_]*|$names)([^A-Za-z0-9_]|\$)"

violations=$(
  find App BowCore -path BowCore/.build -prune -o -type f \( -name '*.swift' -o -name '*.h' -o -name '*.m' \
    -o -name '*.mm' -o -name '*.c' -o -name '*.cc' -o -name '*.cpp' \) -print |
    grep -v "^$hooks\$" |
    while read -r file; do
      awk -v pattern="$pattern" -v file="$file" '
        # Each open conditional: 0 not a harness block, 1 a harness block, 2 a marked harness block,
        # 3 the #else part of a harness block.
        /^[[:space:]]*#[[:space:]]*if/ {
          kind = 0
          if ($0 ~ /^[[:space:]]*#[[:space:]]*(if|ifdef)[[:space:]]+BOW_E2E[[:space:]]*($|\/\/)/) {
            kind = ($0 ~ /E2E seam/) ? 2 : 1
          }
          stack[++depth] = kind
          next
        }
        /^[[:space:]]*#[[:space:]]*(else|elseif|elif)/ { if (stack[depth] > 0) stack[depth] = 3; next }
        /^[[:space:]]*#[[:space:]]*endif/ { depth--; next }
        $0 ~ pattern {
          inside = 0; marked = ($0 ~ /E2E seam/)
          for (i = 1; i <= depth; i++) {
            if (stack[i] == 1 || stack[i] == 2) inside = 1
            if (stack[i] == 2) marked = 1
          }
          if (!inside) print file ":" FNR ": outside an #if BOW_E2E block: " $0
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
