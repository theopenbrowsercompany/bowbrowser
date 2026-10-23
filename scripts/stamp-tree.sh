#!/bin/sh
# Stamps the tree key of the source a build was made from in <stamp file>, around that build's command:
#   stamp-tree.sh <stamp file> <command...>
# The key is taken before the command (before it waits for a build slot) and again after it; the stamp holds the
# key only when both agree, and "unknown" when the tree changed meanwhile (an edit made while the build waited or
# ran may or may not be in the binary). The old stamp goes first, and a failed build leaves none, so a binary whose
# source is not known is never given a tree. The command's exit status is this script's.
here=$(dirname "$0")
stamp=$1
shift
rm -f "$stamp"
before=$("$here/tree-key.sh")
status=0
"$@" || status=$?
[ "$status" -eq 0 ] || exit "$status"
after=$("$here/tree-key.sh")
key=unknown
[ "$before" != "$after" ] || key=$before
printf '%s\n' "$key" > "$stamp" || true
exit 0
