#!/bin/bash
# Tests scripts/build-lock.sh with fake builds (sleep) in a throwaway lock folder: queue order, the slot limit,
# and slot release after kill -9, SIGINT, SIGTERM and a failing command. Takes about 30 seconds.
set -u
cd "$(dirname "$0")/.."

export BOW_LOCK_DIR
BOW_LOCK_DIR=$(mktemp -d)
export BOW_BUILD_SLOTS=2
lock=./scripts/build-lock.sh
failed=0
check() { # check <description> <condition command...>
  local what=$1
  shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; failed=1; fi
}
slot_count() { find "$BOW_LOCK_DIR/slots" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '; }
queue_count() { find "$BOW_LOCK_DIR/queue" -mindepth 1 -type f | wc -l | tr -d ' '; }
is() { [ "$1" = "$2" ]; }

# 1. Four builds, two slots: never more than two at once, served in arrival order.
out=$BOW_LOCK_DIR/out
for i in 1 2 3 4; do
  $lock sh -c "echo start $i >> $out; sleep 2; echo end $i >> $out" 2> "$BOW_LOCK_DIR/err$i" &
  sleep 0.3
done
sleep 1
check "two slots busy while four builds run" is "$(slot_count)" 2
wait
order=$(grep start "$out" | tr -d '\n')
check "first come, first served" is "$order" "start 1start 2start 3start 4"
running=0 max=0
while read -r line; do
  case $line in start*) running=$((running + 1)) ;; *) running=$((running - 1)) ;; esac
  [ $running -le $max ] || max=$running
done < "$out"
check "never more than two at once" is "$max" 2
check "waiting build prints waiting line" grep -q "waiting for a build slot (2 of 2 running, 0 waiting ahead" "$BOW_LOCK_DIR/err3"
check "waiting build prints got slot line" grep -q "got a build slot" "$BOW_LOCK_DIR/err3"
check "unqueued builds print nothing" test ! -s "$BOW_LOCK_DIR/err1"
check "slots and queue empty after" is "$(slot_count)/$(queue_count)" 0/0

# 2. A failing command passes its status on and frees the slot.
$lock sh -c "exit 7"
check "exit status passes through" is $? 7
check "slot freed after failure" is "$(slot_count)" 0

# 3. Signals to the wrapper: the build stops and the slot is freed.
for sig in INT TERM; do
  $lock sleep 30 &
  pid=$!
  sleep 1
  check "slot held while running ($sig)" is "$(slot_count)" 1
  kill -$sig $pid
  wait $pid 2> /dev/null
  sleep 0.5
  check "slot freed after $sig" is "$(slot_count)" 0
  check "child stopped after $sig" test -z "$(pgrep -f 'sleep 30' || true)"
done

# 4. A waiting build killed while queued leaves its ticket behind for nobody.
BOW_BUILD_SLOTS=1 $lock sleep 4 &
holder=$!
sleep 0.5
BOW_BUILD_SLOTS=1 $lock sleep 1 2> /dev/null &
waiter=$!
sleep 1.5
kill -TERM $waiter
wait $waiter 2> /dev/null
check "queued build's ticket removed on SIGTERM" is "$(queue_count)" 0
wait $holder

# 5. kill -9 of the wrapper: the orphaned command keeps the slot until it ends, then the slot is reclaimed.
$lock sleep 5 &
pid=$!
sleep 1
kill -9 $pid
wait $pid 2> /dev/null
check "orphaned build still holds its slot" is "$(slot_count)" 1
# Both slots in use would block a third build; with one slot left it must still start at once.
start=$SECONDS
$lock true
check "other slot usable meanwhile" test $((SECONDS - start)) -le 2
sleep 5
BOW_BUILD_SLOTS=1 $lock true 2> "$BOW_LOCK_DIR/err5"
check "stale slot reclaimed after holder died" test ! -s "$BOW_LOCK_DIR/err5"

# 6. kill -9 of wrapper and command together: the next build takes the slot without waiting.
BOW_BUILD_SLOTS=1 $lock sleep 30 &
pid=$!
sleep 1
pkill -9 -P $pid
kill -9 $pid
wait $pid 2> /dev/null
check "dead build left a stale slot" is "$(slot_count)" 1
start=$SECONDS
BOW_BUILD_SLOTS=1 $lock true 2> "$BOW_LOCK_DIR/err6"
check "stale slot reclaimed at once" test $((SECONDS - start)) -le 2
check "no waiting line for a stale slot" test ! -s "$BOW_LOCK_DIR/err6"

rm -rf "$BOW_LOCK_DIR"
[ $failed = 0 ] && echo "build-lock: all tests passed"
exit $failed
