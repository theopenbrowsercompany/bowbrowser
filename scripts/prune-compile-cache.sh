#!/bin/bash
# Keeps Xcode's shared compilation cache (COMPILATION_CACHE_CAS_PATH in project.yml) under a size cap.
# scripts/xcodebuild.sh runs it after each build, once the build slot is given back.
#
#   scripts/prune-compile-cache.sh
#
# BOW_COMPILE_CACHE      the cache folder (default ~/Library/Caches/bowbrowser/compile-cache)
# BOW_COMPILE_CACHE_CAP  the cap: a whole number with a unit, K, M or G (default 7G)
#
# The cache holds LLVM on-disk CAS stores (builtin/, generic/), each a folder with a "lock" file and numbered
# generations v1.1, v1.2, ... Compilers read and write only the two newest generations of a store (the newest is
# where new entries go, the one before it is read from and copied forward), and any older generation may be
# deleted at any time by anyone. LLVM starts a new generation only while it holds the store's lock exclusively
# (flock), which it can only get when no compiler or build has the store open. Single entries are never deleted:
# the store's index refers to them, and removing one under it would corrupt the store.
#
# So pruning works by generation, oldest first, and uses the store's own protocol:
# 1. Delete every generation older than the newest two (LLVM's own garbage collection rule).
# 2. If the cache is still over the cap, try the store's lock exclusively without waiting. Holding it, start a
#    new empty generation, so the old newest one becomes the one read from and the one before it becomes garbage;
#    if that old newest one alone is over the cap, start two, so both old ones become garbage. Then do step 1
#    again, outside the lock. If a build has the store open, the lock is busy: leave the store as it is and say so,
#    and the next prune tries again.
#
# Two prunes never race: a prune holds <cache>.prune-lock (a directory with its pid) and a second prune that finds
# it held by a live process skips. A prune killed midway leaves a stale lock that the next prune takes over, at
# worst a half deleted garbage generation that the next prune finishes, or an empty new generation, which is valid.
# A missing cache folder is not an error. The prune never fails the build: it always exits 0.
set -u

cache=${BOW_COMPILE_CACHE:-$HOME/Library/Caches/bowbrowser/compile-cache}
cap=${BOW_COMPILE_CACHE_CAP:-7G}
case $cap in
  [1-9]*K | [1-9]*M | [1-9]*G) ;;
  *) cap=bad ;;
esac
case ${cap%?} in *[!0-9]*) cap=bad ;; esac
if [ "$cap" = bad ]; then
  echo "prune-compile-cache: BOW_COMPILE_CACHE_CAP must be a whole number with K, M or G, like 7G; got '${BOW_COMPILE_CACHE_CAP:-}'" >&2
  exit 0
fi
case $cap in
  *K) cap_kb=${cap%K} ;;
  *M) cap_kb=$((${cap%M} * 1024)) ;;
  *G) cap_kb=$((${cap%G} * 1024 * 1024)) ;;
esac

[ -d "$cache" ] || exit 0

lock=$cache.prune-lock
if ! mkdir "$lock" 2> /dev/null; then
  holder=$(cat "$lock/pid" 2> /dev/null)
  if [ -n "$holder" ] && kill -0 "$holder" 2> /dev/null; then
    exit 0 # another prune is at work
  fi
  # A lock without a pid file is one another prune created a moment ago; only take it over once it is old.
  if [ -z "$holder" ] && [ $(($(date +%s) - $(stat -f %m "$lock" 2> /dev/null || echo 0))) -le 12 ]; then
    exit 0
  fi
  mv "$lock" "$lock.stale.$$" 2> /dev/null && rm -rf "$lock.stale.$$"
  mkdir "$lock" 2> /dev/null || exit 0
fi
echo "$$" > "$lock/pid"
trap 'rm -rf "$lock"' EXIT
trap 'exit 0' INT TERM HUP

size_kb() { du -sk "$1" 2> /dev/null | cut -f1; }

# The generations of store $1, oldest first, one name per line.
generations() {
  local d
  for d in "$1"/v1.*; do
    [ -d "$d" ] || continue
    d=${d##*/}
    case ${d#v1.} in '' | *[!0-9]*) continue ;; esac
    echo "${d#v1.} $d"
  done | sort -n | cut -d' ' -f2
}

# Step 1: delete the generations of store $1 older than the newest two, and folders LLVM marked corrupt.
collect_garbage() {
  local g n
  n=$(generations "$1" | wc -l | tr -d ' ')
  if [ "$n" -gt 2 ]; then
    for g in $(generations "$1" | head -n $((n - 2))); do
      rm -rf "${1:?}/$g"
    done
  fi
  for g in "$1"/corrupt.*; do
    [ -e "$g" ] && rm -rf "$g"
  done
}

# Step 2: start <count> new empty generations in store $1 while holding its lock exclusively, if it is free.
start_generations() {
  perl -MFcntl=:flock -e '
    my ($store, $count) = @ARGV;
    open(my $fh, "<", "$store/lock") or exit 2;
    flock($fh, LOCK_EX | LOCK_NB) or exit 1;
    my @n = sort { $a <=> $b } map { /\/v1\.(\d+)$/ ? $1 : () } grep { -d } glob("$store/v1.*");
    my $next = (@n ? $n[-1] : 0) + 1;
    for my $i (0 .. $count - 1) { mkdir("$store/v1." . ($next + $i)) or exit 2; }
    exit 0;
  ' "$1" "$2"
}

stores=()
for s in "$cache"/*/; do
  s=${s%/}
  [ -f "$s/lock" ] && stores+=("$s")
done

for s in "${stores[@]}"; do collect_garbage "$s"; done
total=$(size_kb "$cache")
[ "$total" -gt "$cap_kb" ] || exit 0

busy=""
# Largest store first: it is the one that has to give way.
while read -r _ s; do
  newest=$(generations "$s" | tail -n 1)
  [ -n "$newest" ] || continue
  if [ "$(size_kb "$s/$newest")" -gt "$cap_kb" ]; then count=2; else count=1; fi
  if start_generations "$s" "$count"; then
    collect_garbage "$s"
  else
    busy="$busy ${s##*/}"
  fi
  total=$(size_kb "$cache")
  [ "$total" -gt "$cap_kb" ] || break
done < <(for s in "${stores[@]}"; do echo "$(size_kb "$s") $s"; done | sort -rn)

if [ "$total" -gt "$cap_kb" ]; then
  echo "prune-compile-cache: $((total / 1024)) MB is over the $cap cap${busy:+, and in use by another build (${busy# }); the next prune tries again}" >&2
fi
exit 0
