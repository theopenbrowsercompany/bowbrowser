#!/bin/bash
# Tests scripts/build-lock.sh with fake builds (sleep) in a throwaway lock folder: queue order, the slot limit,
# slot release after kill -9, SIGINT, SIGTERM and a failing command, and the priority file. Takes about 70 seconds.
set -u
cd "$(dirname "$0")/.."

export BOW_LOCK_DIR
BOW_LOCK_DIR=$(mktemp -d)
export BOW_BUILD_SLOTS=2
trap 'rm -rf "$BOW_LOCK_DIR"; kill $(jobs -p) 2>/dev/null' EXIT
lock=./scripts/build-lock.sh
failed=0
check() { # check <description> <condition command...>
  local what=$1
  shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; failed=1; fi
}
slot_count() { find "$BOW_LOCK_DIR/build/slots" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '; }
queue_count() { find "$BOW_LOCK_DIR/build/queue" -mindepth 1 -type f | wc -l | tr -d ' '; }
is() { [ "$1" = "$2" ]; }

# 1. Four builds, two slots: never more than two at once, served in arrival order.
out=$BOW_LOCK_DIR/out
for i in 1 2 3 4; do
  $lock sh -c "echo start $i >> $out; sleep 2; echo end $i >> $out" 2> "$BOW_LOCK_DIR/err$i" &
  sleep 0.3
done
sleep 0.3
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
  kid=$(pgrep -P $pid)
  check "slot held while running ($sig)" is "$(slot_count)" 1
  kill -$sig $pid
  wait $pid 2> /dev/null
  sleep 0.5
  check "slot freed after $sig" is "$(slot_count)" 0
  check "child stopped after $sig" test -z "$(ps -o pid= -p "$kid" 2>/dev/null)"
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
kid=$(pgrep -P $pid)
kill -9 $pid $kid
wait $pid 2> /dev/null
check "dead build left a stale slot" is "$(slot_count)" 1
start=$SECONDS
BOW_BUILD_SLOTS=1 $lock true 2> "$BOW_LOCK_DIR/err6"
check "stale slot reclaimed at once" test $((SECONDS - start)) -le 2
check "no waiting line for a stale slot" test ! -s "$BOW_LOCK_DIR/err6"

# 6b. A slot dir with no pids file (a build died between mkdir and writing it) is reclaimed once old enough.
mkdir "$BOW_LOCK_DIR/build/slots/1"
touch -t 202001010000 "$BOW_LOCK_DIR/build/slots/1"
BOW_BUILD_SLOTS=1 $lock true 2> "$BOW_LOCK_DIR/err6b"
check "pidless old slot reclaimed" test ! -s "$BOW_LOCK_DIR/err6b"
check "bad slot count rejected" test "$(BOW_BUILD_SLOTS=00 $lock true 2> /dev/null; echo $?)" = 64

# 7. The e2e pool is separate: a full build pool does not block an e2e run, and BOW_E2E_SLOTS limits it.
BOW_BUILD_SLOTS=1 $lock sleep 3 &
sleep 0.5
start=$SECONDS
$lock --pool e2e true 2> "$BOW_LOCK_DIR/err7"
check "e2e run not blocked by a full build pool" test $((SECONDS - start)) -le 1
BOW_E2E_SLOTS=1 $lock --pool e2e sleep 2 &
sleep 0.5
BOW_E2E_SLOTS=1 $lock --pool e2e true 2> "$BOW_LOCK_DIR/err8"
check "second e2e run waits for the single e2e slot" grep -q "waiting for a e2e slot" "$BOW_LOCK_DIR/err8"
wait

# 8. Priority. Each case holds the single slot with a gated build, queues waiters from directories on given
# branches, then opens the gate and records the order the waiters ran in. Waits poll for state, not time.
abslock=$PWD/scripts/build-lock.sh
prio=$BOW_LOCK_DIR/priority
repos=$BOW_LOCK_DIR/repos
plain=$BOW_LOCK_DIR/plain # not a git checkout
mkdir -p "$repos" "$plain"
until_true() { # until_true <condition command...>: poll for up to 10 seconds
  local i=0
  while ! "$@"; do
    i=$((i + 1))
    [ $i -lt 100 ] || return 1
    sleep 0.1
  done
}
repo() { # repo <branch>: print a checkout on that branch, creating it once
  local d=$repos/$1
  [ -d "$d" ] || git init -q -b "$1" "$d"
  echo "$d"
}
detached=$repos/detached
git init -q "$detached"
git -C "$detached" -c user.name=t -c user.email=t@t commit -q --allow-empty -m t
git -C "$detached" checkout -q --detach
gate=""
enqueue() { # enqueue <label> <directory>: queue a build that records its label when it runs
  local before
  before=$(queue_count)
  (cd "$2" && BOW_BUILD_SLOTS=1 "$abslock" sh -c "echo $1 >> $BOW_LOCK_DIR/order" 2> "$BOW_LOCK_DIR/err.$1") &
  until_true queued_more "$before"
}
queued_more() { [ "$(queue_count)" -gt "$1" ]; }
release_gate() {
  touch "$gate"
  wait
  order=$(tr '\n' ' ' < "$BOW_LOCK_DIR/order")
  order=${order% }
}
wait_line() { grep -q "$1" "$2" 2> /dev/null; } # wait_line <text> <file>
slot_is_one() { is "$(slot_count)" 1; }

hold_one() { # take the one slot until release_gate
  gate=$BOW_LOCK_DIR/gate.$RANDOM
  BOW_BUILD_SLOTS=1 $lock sh -c "while [ ! -e $gate ]; do sleep 0.1; done" &
  until_true slot_is_one
  : > "$BOW_LOCK_DIR/order"
}

# 8a. A listed branch jumps ahead of earlier unlisted tickets: a branch not in the file, a directory outside any
# checkout and a detached HEAD all count as unlisted and keep their arrival order.
printf 'hot\n' > "$prio"
hold_one
enqueue cold "$(repo cold)"
enqueue plain "$plain"
enqueue detached "$detached"
enqueue hot "$(repo hot)"
until_true wait_line "waiting" "$BOW_LOCK_DIR/err.hot"
release_gate
check "listed branch jumps ahead of earlier unlisted ones" is "$order" "hot cold plain detached"
check "waiting line says the priority rank" wait_line "0 waiting ahead of this one, priority 1 of 1)" "$BOW_LOCK_DIR/err.hot"
check "waiting line says unlisted" wait_line "waiting ahead of this one, unlisted)" "$BOW_LOCK_DIR/err.cold"
check "no checkout counts as unlisted" wait_line "unlisted)" "$BOW_LOCK_DIR/err.plain"
check "detached HEAD counts as unlisted" wait_line "unlisted)" "$BOW_LOCK_DIR/err.detached"

# 8b. Two listed branches follow file order; blank lines, comments and surrounding spaces are ignored.
printf '# lead order\n\n  first  \n\nsecond\n' > "$prio"
hold_one
enqueue second "$(repo second)"
enqueue first "$(repo first)"
release_gate
check "listed branches follow file order" is "$order" "first second"
check "rank counts only listed branches" wait_line "priority 2 of 2)" "$BOW_LOCK_DIR/err.second"

# 8c. The same rank stays first come, first served, ahead of an earlier unlisted build.
printf 'hot\n' > "$prio"
hold_one
enqueue cold "$(repo cold)"
enqueue hot1 "$(repo hot)"
enqueue hot2 "$(repo hot)"
enqueue hot3 "$(repo hot)"
release_gate
check "same rank stays first come, first served" is "$order" "hot1 hot2 hot3 cold"

# 8d. A missing or empty file means first come, first served.
for state in missing empty; do
  rm -f "$prio"
  [ $state = missing ] || : > "$prio"
  hold_one
  enqueue cold "$(repo cold)"
  enqueue hot "$(repo hot)"
  enqueue plain "$plain"
  release_gate
  check "$state priority file: first come, first served" is "$order" "cold hot plain"
done

# 8e. Reordering the file while builds wait takes effect.
printf 'early\nlate\n' > "$prio"
hold_one
enqueue late "$(repo late)"
enqueue early "$(repo early)"
until_true wait_line "priority 2 of 2)" "$BOW_LOCK_DIR/err.late"
printf 'late\nearly\n' > "$prio.new" && mv "$prio.new" "$prio"
until_true wait_line "priority 1 of 2)" "$BOW_LOCK_DIR/err.late"
check "waiting line updates after a reorder" wait_line "priority 1 of 2)" "$BOW_LOCK_DIR/err.late"
release_gate
check "reordered file takes effect while waiting" is "$order" "late early"

# 8f. A dead ticket, even one for the top branch, is dropped and does not block the queue.
printf 'hot\n' > "$prio"
sh -c 'exit 0' &
dead=$!
wait $dead
printf 'hot\n' > "$BOW_LOCK_DIR/build/queue/1000000000000000.$dead"
hold_one
enqueue cold "$(repo cold)"
release_gate
check "dead listed ticket does not block" is "$order" "cold"
check "dead ticket dropped" test ! -e "$BOW_LOCK_DIR/build/queue/1000000000000000.$dead"
check "queue empty after priority tests" is "$(slot_count)/$(queue_count)" 0/0

rm -rf "$BOW_LOCK_DIR"
[ $failed = 0 ] && echo "build-lock: all tests passed"
exit $failed
