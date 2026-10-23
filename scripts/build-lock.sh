#!/bin/bash
# Runs a command (an xcodebuild) while holding one of N build slots shared by every worktree and checkout, so
# parallel agents take turns instead of all compiling at once.
#
#   scripts/build-lock.sh <command> [args...]
#
# BOW_BUILD_SLOTS   number of builds that may run at once (default 2)
# BOW_LOCK_DIR      lock state folder (default ~/Library/Caches/bowbrowser/build-lock)
#
# How it works, with only bash, mkdir, perl (for a microsecond clock) and kill -0:
# - A build first takes a ticket, a file named <microsecond time>.<pid> in queue/. Tickets are served in name
#   order, so first come, first served. Only the oldest live ticket may claim a slot.
# - A slot is a directory slots/N. mkdir is atomic, so two builds never share one. The slot records the pid of
#   this script and of the command. It counts as held while either process lives, so a build whose script was
#   killed with kill -9 keeps its slot until the orphaned xcodebuild ends, then it is reclaimed.
# - The slot and ticket are released when the command ends, fails, or this script gets INT, TERM or HUP.
set -u

slots=${BOW_BUILD_SLOTS:-2}
dir=${BOW_LOCK_DIR:-$HOME/Library/Caches/bowbrowser/build-lock}

case $slots in '' | *[!0-9]* | 0)
  echo "build-lock: BOW_BUILD_SLOTS must be a positive number, got '$slots'" >&2
  exit 2
  ;;
esac
[ $# -gt 0 ] || { echo "usage: build-lock.sh <command> [args...]" >&2; exit 2; }

mkdir -p "$dir/queue" "$dir/slots"

ticket=""
slot=""
child=""

alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

release() {
  [ -z "$ticket" ] || rm -f "$ticket"
  [ -z "$slot" ] || rm -rf "$slot"
  ticket="" slot=""
}

# A slot is stale when neither recorded pid lives. A slot without a pid file is one another build created a
# moment ago and has not filled in yet; only treat it as stale after 12 seconds.
slot_stale() {
  local pid
  if [ ! -f "$1/pids" ]; then
    [ -n "$(find "$1" -maxdepth 0 -mmin +0.2 2>/dev/null)" ]
    return
  fi
  for pid in $(cat "$1/pids" 2>/dev/null); do
    alive "$pid" && return 1
  done
  return 0
}

running_count() {
  local n=0 s
  for s in "$dir"/slots/*; do
    [ -d "$s" ] && n=$((n + 1))
  done
  echo "$n"
}

# Drop tickets whose build is gone, then print the live ones oldest first.
live_tickets() {
  local t
  for t in "$dir"/queue/*; do
    [ -e "$t" ] || continue
    if alive "${t##*.}"; then echo "$t"; else rm -f "$t"; fi
  done | sort
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

now=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000000')
ticket="$dir/queue/$now.$$"
: > "$ticket"

told=no
start=$SECONDS
while :; do
  oldest=$(live_tickets | head -n 1)
  if [ "$oldest" = "$ticket" ] && try_claim; then break; fi
  if [ "$told" = no ]; then
    ahead=$(live_tickets | grep -n -F "$ticket" | cut -d: -f1)
    echo "build-lock: waiting for a build slot ($(running_count) of $slots running, $((${ahead:-1} - 1)) waiting ahead of this build)" >&2
    told=yes
  fi
  sleep 1
done
rm -f "$ticket"
ticket=""
[ "$told" = no ] || echo "build-lock: got a build slot after $((SECONDS - start))s" >&2

"$@" &
child=$!
echo "$$ $child" > "$slot/pids"
wait "$child"
exit $?
