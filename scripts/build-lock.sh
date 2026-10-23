#!/bin/bash
# Runs a command (an xcodebuild) while holding one of N build slots shared by every worktree and checkout, so
# parallel agents take turns instead of all compiling at once.
#
#   scripts/build-lock.sh [--pool build|e2e] <command> [args...]
#
# Two separate pools of slots: "build" (default, for xcodebuild) and "e2e" (for launching the built app).
# BOW_BUILD_SLOTS   builds that may run at once (default 6)
# BOW_E2E_SLOTS     e2e runs that may run at once (default 6)
# BOW_LOCK_DIR      lock state folder (default ~/Library/Caches/bowbrowser/build-lock); one subfolder per pool
#
# Priority: the lead may keep a plain text file, <lock dir>/priority, shared by both pools. It lists git branch
# names, highest priority first, one per line; blank lines and lines starting with # are ignored. A waiting
# build whose branch is listed is served before every build whose branch is further down or not listed. A
# missing or empty file means plain first come, first served. A running build is never interrupted.
#
# How it works, with only bash, mkdir, perl (for a microsecond clock) and kill -0:
# - A build first takes a ticket, a file named <microsecond time>.<pid> in queue/ holding the git branch of the
#   directory it runs from (empty for a detached HEAD or outside a checkout). The branch is looked up once, so
#   ranking only reads files. Tickets are served by priority rank, then in name order (first come, first
#   served). The priority file is read again on every pass, so reordering it reorders the waiting builds.
#   Only the first live ticket in that order may claim a slot.
# - A slot is a directory slots/N. mkdir is atomic, so two builds never share one. The slot records the pid of
#   this script and of the command. It counts as held while either process lives, so a build whose script was
#   killed with kill -9 keeps its slot until the orphaned xcodebuild ends, then it is reclaimed.
# - The slot and ticket are released when the command ends, fails, or this script gets INT, TERM or HUP.
set -u

pool=build
if [ "${1:-}" = "--pool" ]; then
  pool=${2:-}
  shift 2 2>/dev/null || shift $#
fi
case $pool in
  build) slots_var=BOW_BUILD_SLOTS default_slots=6 ;;
  e2e) slots_var=BOW_E2E_SLOTS default_slots=6 ;;
  *) echo "build-lock: unknown pool '$pool' (use build or e2e)" >&2; exit 64 ;;
esac
slots=${!slots_var:-$default_slots}
root=${BOW_LOCK_DIR:-$HOME/Library/Caches/bowbrowser/build-lock}
dir=$root/$pool
priority_file=$root/priority

case $slots in '' | *[!0-9]* | 0 | 0[0-9]*)
  echo "build-lock: $slots_var must be a positive number, got '$slots'" >&2
  exit 64
  ;;
esac
[ $# -gt 0 ] || { echo "usage: build-lock.sh [--pool build|e2e] <command> [args...]" >&2; exit 64; }

mkdir -p "$dir/queue" "$dir/slots"

ticket=""
slot=""
child=""

alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

release() {
  [ -z "$ticket" ] || rm -f "$ticket"
  [ -z "$slot" ] || rm -rf "$slot"
  rm -f "$dir/queue/.new.$$"
  ticket="" slot=""
}

# A slot is stale when neither recorded pid lives. A slot without a pid file is one another build created a
# moment ago and has not filled in yet; only treat it as stale after 12 seconds.
slot_stale() {
  local pid
  if [ ! -s "$1/pids" ]; then
    [ $(($(date +%s) - $(stat -f %m "$1" 2>/dev/null || echo 0))) -gt 12 ]
    return
  fi
  for pid in $(cat "$1/pids" 2>/dev/null); do
    alive "$pid" && return 1
  done
  return 0
}

running_count() {
  local n=0 i
  for i in $(seq 1 "$slots"); do
    [ -d "$dir/slots/$i" ] && n=$((n + 1))
  done
  echo "$n"
}

# Read the priority file into prio (highest first, trimmed, without blanks or comments) and its length into
# listed. Called once per pass, so each pass ranks every ticket against one reading of the file.
prio=()
listed=0
load_priority() {
  local line
  prio=()
  listed=0
  [ -r "$priority_file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case $line in '' | '#'*) continue ;; esac
    prio[listed]=$line
    listed=$((listed + 1))
  done < "$priority_file" 2>/dev/null
}

# Drop tickets whose build is gone, then print the live ones in serving order as "<rank> <ticket>": listed
# branches by their place in prio (rank 1 first), then unlisted ones (rank listed + 1), each group in arrival
# order.
live_tickets() {
  local t b r i
  for t in "$dir"/queue/*; do
    [ -e "$t" ] || continue
    if ! alive "${t##*.}"; then
      rm -f "$t"
      continue
    fi
    # A ticket whose build claimed a slot since the glob is gone; an empty one has no branch.
    b=""
    { read -r b < "$t"; } 2>/dev/null || [ -e "$t" ] || continue
    r=$((listed + 1))
    if [ -n "$b" ]; then
      i=0
      while [ "$i" -lt "$listed" ]; do
        if [ "${prio[i]}" = "$b" ]; then r=$((i + 1)); break; fi
        i=$((i + 1))
      done
    fi
    echo "$r $t"
  done | sort -k1,1n -k2
}

try_claim() {
  local i=1 s
  while [ "$i" -le "$slots" ]; do
    s="$dir/slots/$i"
    if [ -d "$s" ] && slot_stale "$s"; then
      mv "$s" "$dir/slots/stale.$$.$i" 2>/dev/null && rm -rf "$dir/slots/stale.$$.$i"
    fi
    if mkdir "$s" 2>/dev/null; then
      echo "$$" > "$s/pids"
      slot=$s
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

on_signal() {
  trap '' INT TERM HUP
  if alive "$child"; then
    kill -TERM "$child" 2>/dev/null
    wait "$child" 2>/dev/null
  fi
  release
  exit "$1"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP
trap release EXIT

# The ticket holds the branch of the directory the command runs from. It is written under a dot name (which
# queue/* does not match) and moved into place whole, so no reader sees a ticket without its branch.
branch=$(git symbolic-ref --short -q HEAD 2>/dev/null)
now=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000000')
printf '%s\n' "$branch" > "$dir/queue/.new.$$"
ticket="$dir/queue/$now.$$"
mv "$dir/queue/.new.$$" "$ticket"

told=""
start=$SECONDS
while :; do
  load_priority
  order=$(live_tickets)
  first=$(echo "$order" | head -n 1)
  if [ "${first#* }" = "$ticket" ] && try_claim; then break; fi
  # Say so once, and again whenever an edit to the priority file gives this build another rank.
  mine=$(echo "$order" | grep -n -F " $ticket" | head -n 1)
  ahead=${mine%%:*}
  rank=${mine#*:}
  rank=${rank%% *}
  if [ -z "$rank" ] || [ "$rank" -gt "$listed" ]; then
    where=unlisted
  else
    where="priority $rank of $listed"
  fi
  if [ "$told" != "$where" ]; then
    echo "build-lock: waiting for a $pool slot ($(running_count) of $slots running, $((${ahead:-1} - 1)) waiting ahead of this one, $where)" >&2
    told=$where
  fi
  sleep 1
done
rm -f "$ticket"
ticket=""
[ -z "$told" ] || echo "build-lock: got a $pool slot after $((SECONDS - start))s" >&2

# Keep the command's stdin (a background job would get /dev/null).
"$@" <&0 &
child=$!
echo "$$ $child" > "$slot/pids.new" && mv "$slot/pids.new" "$slot/pids"
wait "$child"
exit $?
