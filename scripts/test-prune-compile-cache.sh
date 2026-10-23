#!/bin/bash
# Tests scripts/prune-compile-cache.sh on small fake caches in a throwaway folder: garbage generations, the cap,
# a store in use by a build, two prunes at once, a stale prune lock, a missing cache, and (when Xcode's llvm-cas
# is found) that a real LLVM CAS store still reads after a prune. Takes a few seconds.
set -u
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
holders=()
trap 'for p in ${holders[@]+"${holders[@]}"}; do kill "$p" 2> /dev/null; done; rm -rf "$tmp"' EXIT
prune=$PWD/scripts/prune-compile-cache.sh
failed=0
check() { # check <description> <condition command...>
  local what=$1
  shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; failed=1; fi
}
is() { [ "$1" = "$2" ]; }

# fake <cache> <store> <generation>=<KB>...: a store with generations holding that many KB each.
fake() {
  local store=$1/$2 g
  shift 2
  mkdir -p "$store"
  : > "$store/lock"
  for g in "$@"; do
    mkdir -p "$store/${g%=*}"
    dd if=/dev/zero of="$store/${g%=*}/data" bs=1024 count="${g#*=}" 2> /dev/null
  done
}
gens() { (cd "$1" && ls -d v1.* corrupt.* 2> /dev/null | sort -t. -k2,2n | tr '\n' ' '); }
kb() { du -sk "$1" | cut -f1; }

# 1. A missing cache folder: nothing to do, no output, exit 0.
out=$(BOW_COMPILE_CACHE=$tmp/none "$prune" 2>&1)
check "missing cache: exit 0" is $? 0
check "missing cache: no output" is "$out" ""
check "missing cache: not created" test ! -e "$tmp/none"

# 2. Under the cap: only generations older than the newest two and corrupt folders go.
c=$tmp/c2
fake "$c" builtin v1.1=100 v1.2=100 v1.3=100 v1.4=100 corrupt.v1.9=100
fake "$c" generic v1.1=10
BOW_COMPILE_CACHE=$c BOW_COMPILE_CACHE_CAP=10M "$prune"
check "garbage generations deleted, newest two kept" is "$(gens "$c/builtin")" "v1.3 v1.4 "
check "a store with one generation is left alone" is "$(gens "$c/generic")" "v1.1 "
check "the prune lock is given back" test ! -e "$c.prune-lock"

# 3. Over the cap: a new generation starts, so the old upstream becomes garbage and the newest is kept.
c=$tmp/c3
fake "$c" builtin v1.3=2000 v1.4=600
BOW_COMPILE_CACHE=$c BOW_COMPILE_CACHE_CAP=1M "$prune"
check "over cap: one new generation, the oldest deleted" is "$(gens "$c/builtin")" "v1.4 v1.5 "
check "over cap: under the cap after" test "$(kb "$c")" -le 1024

# 4. The newest generation alone is over the cap: two new generations, both old ones deleted.
c=$tmp/c4
fake "$c" builtin v1.1=300 v1.2=1500
BOW_COMPILE_CACHE=$c BOW_COMPILE_CACHE_CAP=1M "$prune"
check "newest over cap: two new generations, both old ones deleted" is "$(gens "$c/builtin")" "v1.3 v1.4 "

# 5. A store a build has open (a shared flock on its lock file, as LLVM takes): nothing in use is touched.
c=$tmp/c5
fake "$c" builtin v1.1=100 v1.2=1500 v1.3=600
perl -MFcntl=:flock -e 'open(my $f, "<", $ARGV[0]) or die; flock($f, LOCK_SH) or die; print "held\n"; $| = 1; sleep 30' \
  "$c/builtin/lock" > "$tmp/held5" &
holders+=($!)
until grep -q held "$tmp/held5" 2> /dev/null; do sleep 0.1; done
out=$(BOW_COMPILE_CACHE=$c BOW_COMPILE_CACHE_CAP=1M "$prune" 2>&1)
check "store in use: exit 0" is $? 0
check "store in use: garbage deleted, the two in use kept" is "$(gens "$c/builtin")" "v1.2 v1.3 "
check "store in use: says it is over the cap and busy" grep -q "over the 1M cap, and in use by another build (builtin)" <<< "$out"
kill ${holders[@]+"${holders[@]}"} 2> /dev/null
wait 2> /dev/null
holders=()
BOW_COMPILE_CACHE=$c BOW_COMPILE_CACHE_CAP=1M "$prune"
check "store free again: the next prune gets under the cap" is "$(gens "$c/builtin")" "v1.3 v1.4 "

# 6. Two prunes at once on a store over the cap: exactly one new generation, never two from a race.
for round in 1 2 3; do
  c=$tmp/c6.$round
  fake "$c" builtin v1.1=1500 v1.2=600
  BOW_COMPILE_CACHE=$c BOW_COMPILE_CACHE_CAP=1M "$prune" &
  a=$!
  BOW_COMPILE_CACHE=$c BOW_COMPILE_CACHE_CAP=1M "$prune" &
  b=$!
  wait $a $b
  check "two prunes at once (round $round): one new generation" is "$(gens "$c/builtin")" "v1.2 v1.3 "
  check "two prunes at once (round $round): lock given back" test ! -e "$c.prune-lock"
done

# 7. The prune lock held by a live prune: a second prune skips. Held by a dead one: it is taken over.
c=$tmp/c7
fake "$c" builtin v1.1=100 v1.2=100 v1.3=100
mkdir "$c.prune-lock"
sleep 30 &
holders+=($!)
echo $! > "$c.prune-lock/pid"
BOW_COMPILE_CACHE=$c BOW_COMPILE_CACHE_CAP=10M "$prune"
check "live prune lock: the second prune skips" is "$(gens "$c/builtin")" "v1.1 v1.2 v1.3 "
kill ${holders[@]+"${holders[@]}"} 2> /dev/null
wait 2> /dev/null
holders=()
BOW_COMPILE_CACHE=$c BOW_COMPILE_CACHE_CAP=10M "$prune"
check "stale prune lock: taken over" is "$(gens "$c/builtin")" "v1.2 v1.3 "
check "stale prune lock: given back" test ! -e "$c.prune-lock"

# 8. A bad cap is refused with a message, and the prune still exits 0 so the build does not fail.
out=$(BOW_COMPILE_CACHE=$c BOW_COMPILE_CACHE_CAP=7 "$prune" 2>&1)
check "bad cap: exit 0" is $? 0
check "bad cap: says so" grep -q "must be a whole number with K, M or G" <<< "$out"

# 9. A real LLVM CAS store with two generations, an object in each: the prune starts one new generation, the
# object in the newest old generation still reads (from the generation now read from) and the oldest is deleted,
# so the prune follows the store's own format. LLVM starts a generation the same way, with an empty folder.
cas_tool=$(xcrun --find llvm-cas 2> /dev/null)
if [ -n "$cas_tool" ]; then
  c=$tmp/c9
  mkdir -p "$c"
  head -c 2000000 /dev/urandom > "$tmp/blob1"
  head -c 2000000 /dev/urandom > "$tmp/blob2"
  "$cas_tool" --cas="$c/builtin" --make-blob --data="$tmp/blob1" > /dev/null
  mkdir "$c/builtin/v1.2"
  id=$("$cas_tool" --cas="$c/builtin" --make-blob --data="$tmp/blob2")
  BOW_COMPILE_CACHE=$c BOW_COMPILE_CACHE_CAP=3M "$prune"
  check "real CAS: one new generation, the oldest deleted" is "$(gens "$c/builtin")" "v1.2 v1.3 "
  "$cas_tool" --cas="$c/builtin" --cat-blob "$id" > "$tmp/back" 2> "$tmp/cas-err"
  check "real CAS: an object written before the prune still reads" cmp -s "$tmp/blob2" "$tmp/back"
else
  echo "skip real CAS: llvm-cas not found"
fi

[ $failed = 0 ] && echo "prune-compile-cache tests passed" || echo "prune-compile-cache tests FAILED"
exit $failed
