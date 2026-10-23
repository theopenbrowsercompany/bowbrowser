#!/bin/bash
# Runs the e2e tests in a built Bow.app and always finishes the story: a final summary line, results.json, distinct
# exit codes, no helper processes left behind, and build/e2e/latest pointing at the run.
#
#   scripts/e2e.sh <path to Bow.app> [selection]
#
# selection (or E2E): passed to the app as --e2e=<selection>: all (default), or a comma list of test names, areas,
#   globs and tags (tabs.switch, tabs, 'tabs.*', smoke). The app refuses an unknown one with exit 64.
#   After each test the runner prints `RESULT <test> pass|fail|timeout seconds=<s> checks=<passed>/<n>`, and a
#   `NOT RUN <test>` line for each test a stuck main thread kept from running; the retry and FLAKY lines use them.
# BOW_E2E_ROOT  where run folders go (default build/e2e).
# E2E_RETRY  1 (default) reruns a failed or timed out run once in a fresh app; 0 turns the retry off.
# E2E_KEEP   run folders to keep in build/e2e (default 20); older ones are deleted.
# E2E_REPEAT N (a whole number, 1 or more; default 1) runs the selection N times, each a whole run of this script in
#   its own run folder with the retry off, so a repeat check never hides a flake behind the retry: every repeat that
#   fails, times out or crashes counts as failed. It prints `REPEAT <test> <passes>/<N>` per test (from the RESULT
#   lines, where a later FAIL line of the test's check, such as the quit check, or a crash after quit=pending fails
#   the test) and ends with one summary line:
#     E2E: PASS N/N repeats                                                exit 0
#     E2E: <FAIL|TIMEOUT|CRASH> <passed>/N repeats passed; failed: repeat <i> (<its summary>), ...
#                                                exit code of the first failing repeat (1, 2 or 4)
#     E2E: ERROR repeat <i>/N could not run: ...  exit 64, and the repeats stop (a bad N exits 64 at once)
#     E2E: ERROR interrupted                      exit 130: a signal ends the repeat running and the rest
#   E2E_KEEP is raised to N inside the repeats, so none prunes another. list ignores E2E_REPEAT.
# E2E_QUIET  1 prints short output for agents, 0 the full output; unset, it is 1 when CLAUDECODE=1 (every agent
#   shell in Claude Code has it). Short output keeps only the FAIL, FLAKY, QUARANTINED, QUARANTINE EXPIRED, TIMEOUT
#   and NOT RUN lines, the RESULT lines of failing tests (a retry's prefixed `retry: `), the app's echoed Chromium
#   ERROR and FATAL lines when a check failed (a quarantined pass included), the app's own messages when it could not start the run (exit 64), one line naming the run folder
#   and the summary line. The files written are the same either way.
# E2E_QUARANTINE  the quarantine list to read (default scripts/e2e-quarantine.txt; a missing file is an empty list).
#   One entry per line, `<test name> <YYYY-MM-DD expiry> <reason>`, and # comments. An entry counts until its
#   expiry date and has expired on that date. When every test whose failure the retry passed is listed and
#   unexpired, the run passes (exit 0): it prints `QUARANTINED <test> (expires <date>): <reason>` per test after
#   the FLAKY lines and ends with `E2E: PASS n/n; quarantined flaky tests passed on the retry: <tests>`, and
#   results.json keeps the FLAKY names in "flaky" and the entries in "quarantined". Never quarantined: a failure
#   that is no test's (chromium.errors, e2e.isolation, a timeout between tests), a first attempt whose main thread
#   was stuck (an `E2E: TIMEOUT` line), a FAIL, TIMEOUT or crash on the retry, and the repeats (the retry is off
#   there). A failed quit check is named after its test (app.quit) and counts as that test's. Each expired entry
#   prints `QUARANTINE EXPIRED <test> (expired <date>): ...` on every run until it is removed or renewed, and a
#   malformed list (a bad name or date, no reason, a duplicate test, a run-wide check, a Plane ID) stops the run
#   before it starts with `E2E: ERROR bad quarantine list: ...` (exit 64).
# E2E_SHARDS N (a whole number, 1 or more; default 1) splits the selection across N apps run at once. 1 or unset is
#   the single run below, unchanged. The app's test list (`--e2e=list`) turns the selection into test names, which
#   are planned onto the shards longest first, each onto the least loaded shard, by each test's seconds in the
#   newest results.json under the run root that has it (a test with none counts as the average of those that do,
#   and with no history every test counts the same, which deals them out in test order). Each shard is a whole run
#   of this script with the retry off, in <run>/shard-<k>/ with its own report.txt, results.json, chromium.log and
#   profile, taking its own slot from the build lock's e2e pool; its --e2e= value is its comma list of test names.
#   The plan must put every selected test in exactly one shard, or the run stops with exit 64. The test with
#   quitsApp is in one shard, where the app runs it last. Fewer selected tests than N give one shard per test, and a
#   selection that names no known test, a single test or a list the app cannot give runs in one app as usual.
#   Once every shard ends, <run>/report.txt merges their lines (the shards that timed out last) and each run-wide
#   check (e2e.isolation, chromium.errors) becomes one line naming every shard's result, failing when any shard's
#   failed, so the total counts each check once, as a single run does. The run's outcome is the worst shard's
#   (ERROR, then CRASH, then TIMEOUT, then FAIL); a crash or error names its shard (`... in shard <k>/<N>`,
#   `E2E: ERROR shard <k>/<N>: ...`). The failed, timed out and not run tests of every shard go into one retry in
#   one app, chosen per shard as for a single run, except that a shard whose whole selection would be rerun (a
#   failed run-wide check, no RESULT line) has all of its own tests rerun; FLAKY, the quarantine list, short output, the
#   summary line, results.json and the exit codes then mean what they mean for a single run. results.json adds
#   "shards" (each shard's folder, tests, planned seconds, status and summary). A person sees each shard's output
#   once all have ended; short output is the same as a single run's. A signal stops every shard and its helpers.
#   E2E_REPEAT shards each repeat, and list ignores E2E_SHARDS.
#
# E2E_SHARD_DIR is set by this script for a shard's own run (its folder): it then neither prunes nor moves latest.
#
# Each run writes build/e2e/<time>-<pid>/: the app's report.txt, chromium.log and final.png, plus results.json
# from this script. A retry runs in <run>/retry/: the failed, timed out and not run tests when RESULT lines name
# them and every FAIL line belongs to one of those tests, else the whole selection (a failed chromium.errors,
# e2e.isolation or quit check, a runner without RESULT lines). FLAKY therefore never hides a check the retry did
# not run again. A retry that cannot start (exit 64) leaves the first attempt's outcome in place.
#
# The last line printed is always the summary:
#   E2E: PASS n/n               exit 0
#   E2E: FAIL passed/n          exit 1  a check failed (and failed again on the retry)
#   E2E: TIMEOUT <step>         exit 2  the app's main thread was stuck (and again on the retry)
#                                       When the retry fails the other way (a FAIL after a TIMEOUT, or the reverse),
#                                       the line names both, `<first summary> (retry: <its summary>)`, and the exit
#                                       code is the first attempt's, whose run covered the whole selection.
#   E2E: FLAKY n/n after ...    exit 3  failed or timed out, then passed on the retry: not a pass, report it.
#                                       n/n is the whole selection when the first attempt printed its total or the
#                                       retry reran everything. Otherwise (a timeout, then a retry of some tests)
#                                       the line says only the retried tests passed: `E2E: FLAKY retried tests
#                                       passed n/n after retrying <tests> (the first attempt printed no total)`.
#   E2E: CRASH exit=<code> ...  exit 4  the app ended without a summary line (a crash, Chromium's own watchdog),
#                                       on the first run or on the retry. Exit 2 with "Teardown watchdog expired"
#                                       in chromium.log says so: `E2E: CRASH exit=2 Chromium teardown watchdog
#                                       during quit`.
#   E2E: ERROR ...              exit 64 the app could not start the run (an unknown selection, no build), or the
#                                       build lock refused to run it (a bad BOW_E2E_SLOTS)
#   E2E: ERROR interrupted      exit 130 Ctrl-C, TERM or HUP: the app and its helpers are ended at once, and
#                                       results.json records only that the run was interrupted. A script started
#                                       in the background ignores INT (bash cannot trap it), so stop one with TERM.
set -u

app=${1:-}
# The selection comes as the second argument or in E2E (make sets it for this script alone, quoted for the shell).
selection=${2:-${E2E:-all}}
retry=${E2E_RETRY:-1}
keep=${E2E_KEEP:-20}

repo=$(cd "$(dirname "$0")/.." && pwd -P)
root=${BOW_E2E_ROOT:-$repo/build/e2e}
marker=.bow-e2e-run
binary="$app/Contents/MacOS/Bow"

repeat=${E2E_REPEAT:-1}
# Short output for agents (E2E_QUIET wins; unset, CLAUDECODE=1 turns it on).
quiet=0
if [ -n "${E2E_QUIET:-}" ]; then [ "$E2E_QUIET" = 1 ] && quiet=1
elif [ "${CLAUDECODE:-}" = 1 ]; then quiet=1; fi
# Short output: the file in an attempt's folder that keeps what its app and build lock printed, removed once read.
output=.output

tell() { echo "e2e: $*"; }
# Progress lines, left out of short output.
say() { [ "$quiet" = 1 ] || tell "$@"; }

if ! [[ $repeat =~ ^[1-9][0-9]*$ ]]; then
  tell "E2E_REPEAT must be a whole number of 1 or more, not '$repeat'"
  echo "E2E: ERROR bad E2E_REPEAT"
  exit 64
fi
if [ -z "$app" ] || [ ! -x "$binary" ]; then
  tell "no built app at ${app:-<none>}; run make e2e (or make build) first"
  echo "E2E: ERROR no build"
  exit 64
fi
# list prints one TEST line per test and starts no engine: nothing to run, report or retry. The app wants an
# output folder but exits before using it.
[ "$selection" != list ] || exec "$binary" --e2e=list --e2e-out="${TMPDIR:-/tmp}/bow-e2e-list"
case $keep in '' | *[!0-9]*) keep=20 ;; esac
shards=${E2E_SHARDS:-1}
if ! [[ $shards =~ ^[1-9][0-9]*$ ]]; then
  tell "E2E_SHARDS must be a whole number of 1 or more, not '$shards'"
  echo "E2E: ERROR bad E2E_SHARDS"
  exit 64
fi
shard_dir=${E2E_SHARD_DIR:-}

# Fields in the lines below are split by the unit separator, not a tab: bash's read merges runs of tabs (IFS
# whitespace), so an empty field would shift the ones after it.
us=$'\037'

# The quarantine list: quarantine and expired hold name<US>expiry<US>reason lines of its unexpired and expired
# entries. A malformed list stops the run before anything starts, so a bad entry is caught by the change adding it.
quarantine_file=${E2E_QUARANTINE:-$repo/scripts/e2e-quarantine.txt}
quarantine_name=$quarantine_file
[ -n "${E2E_QUARANTINE:-}" ] || quarantine_name=scripts/e2e-quarantine.txt
quarantine="" expired=""
if [ -e "$quarantine_file" ]; then
  if ! entries=$(perl -MTime::Local=timegm -e '
    my ($file, $today) = @ARGV;
    open(my $fh, "<", $file) or do { print "cannot be read: $!\n"; exit 1 };
    my (%seen, @out);
    while (my $line = <$fh>) {
      $line =~ s/\r?\n\z//;
      next if $line =~ /^\s*(#|\z)/;
      my $at = "line $.";
      my ($name, $date, $reason) = $line =~ /^\s*(\S+)\s+(\S+)\s+(.*\S)\s*\z/
        or do { print "$at: want <test name> <YYYY-MM-DD expiry> <reason>, got \"$line\"\n"; exit 1 };
      $name =~ /^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+\z/
        or do { print "$at: \"$name\" is not a test name (an area, a dot and the rest; no globs or commas)\n"; exit 1 };
      $name ne "chromium.errors" && $name ne "e2e.isolation"
        or do { print "$at: $name belongs to the runner, and a run-wide check is never quarantined\n"; exit 1 };
      my @ymd = $date =~ /^(\d{4})-(\d\d)-(\d\d)\z/;
      @ymd && eval { timegm(0, 0, 0, $ymd[2], $ymd[1] - 1, $ymd[0]); 1 }
        or do { print "$at: \"$date\" is not a date in YYYY-MM-DD form\n"; exit 1 };
      $reason !~ /\bBOW-\d+/i
        or do { print "$at: the reason names a Plane ID; say it in plain words\n"; exit 1 };
      !$seen{$name}++
        or do { print "$at: $name is listed twice\n"; exit 1 };
      $reason =~ s/[\x00-\x1f]/ /g;
      push @out, join("\037", $date gt $today ? "Q" : "E", $name, $date, $reason) . "\n";
    }
    # Printed only once the whole list is well formed, so an error is the only line printed.
    print @out;' "$quarantine_file" "$(date +%Y-%m-%d)"); then
    echo "E2E: ERROR bad quarantine list: $quarantine_name ${entries:-cannot be read}"
    exit 64
  fi
  quarantine=$(printf '%s\n' "$entries" | awk -F "$us" '$1 == "Q" { print $2 FS $3 FS $4 }')
  expired=$(printf '%s\n' "$entries" | awk -F "$us" '$1 == "E" { print $2 FS $3 FS $4 }')
fi
# expired_lines: one QUARANTINE EXPIRED line per expired entry.
expired_lines() {
  printf '%s\n' "$expired" | while IFS="$us" read -r name date reason; do
    [ -n "$name" ] && echo "QUARANTINE EXPIRED $name (expired $date): remove or renew its entry in $quarantine_name"
  done
}

# E2E_REPEAT: runs this script N times (each a whole run in its own folder, retry off), tallies each test's passes
# from the RESULT lines of each repeat's report.txt and prints one summary line. Short output keeps a passing
# repeat's lines to itself and shows a failing one's.
if [ "$repeat" != 1 ]; then
  mkdir -p "$root" && root=$(cd "$root" && pwd -P)
  repeat_child="" repeat_out=""
  on_repeat_signal() {
    trap '' INT TERM HUP
    # The repeat running ends its app and helpers and writes its interrupted results.json (a background job ignores
    # INT, so TERM).
    local rc=0
    if [ -n "$repeat_child" ] && kill -TERM "$repeat_child" 2>/dev/null; then wait "$repeat_child" 2>/dev/null; rc=$?; fi
    rm -f ${repeat_out:+"$repeat_out"}
    # A person's terminal already has the repeat's own summary line.
    [ "$quiet" = 0 ] && [ "$rc" = 130 ] || echo "E2E: ERROR interrupted"
    exit 130
  }
  trap on_repeat_signal INT TERM HUP
  # Each repeat keeps every run folder of the repeats before it.
  [ "$keep" -ge "$repeat" ] || keep=$repeat
  tally="" failed="" passed=0 first_code="" first_kind="" folders=""
  for i in $(seq "$repeat"); do
    say "repeat $i/$repeat"
    repeat_out=""
    [ "$quiet" = 0 ] || repeat_out=$(mktemp "$root/.repeat.XXXXXX")
    # The repeat runs in the background, keeping this script's stdin, so a signal's trap runs at once. Its output
    # goes to the terminal, or in short output to a file shown only when the repeat fails.
    if [ -n "$repeat_out" ]; then
      E2E_REPEAT=1 E2E_RETRY=0 E2E_KEEP=$keep E2E_QUIET=1 "$0" "$app" "$selection" <&0 > "$repeat_out" 2>&1 &
    else
      E2E_REPEAT=1 E2E_RETRY=0 E2E_KEEP=$keep E2E_QUIET=0 "$0" "$app" "$selection" <&0 &
    fi
    repeat_child=$!
    wait "$repeat_child"
    rc=$?
    pid=$repeat_child
    repeat_child=""
    # The repeat's run folder is named <time>-<its pid>.
    dir=$(cd "$root" && ls -1d -- *-"$pid" 2>/dev/null | head -n 1)
    line=""
    [ -z "$dir" ] || line=$(perl -MJSON::PP -e 'local $/; print decode_json(<STDIN>)->{summary} // ""' \
      < "$root/$dir/results.json" 2>/dev/null)
    [ -n "$line" ] || line=$( { [ -z "$repeat_out" ] || cat "$repeat_out"; } | grep '^E2E: ' | tail -n 1)
    [ -n "$line" ] || line="E2E: CRASH exit=$rc without a summary line"
    folders="$folders${folders:+ }${dir:-?}"
    if [ -n "$dir" ]; then
      # A test's RESULT line can say pass before its quit check fails, so a FAIL line named after a test (the
      # test, or the longest test name it continues with a dot) fails it, and so does a crash (this script's
      # `E2E: CRASH` line, the teardown watchdog included) after a RESULT line with quit=pending.
      tally=$tally$(awk '
        /^RESULT [^ ]+ [^ ]+/ { order[++n] = $2; st[$2] = $3; if ($0 ~ / quit=pending( |$)/) pending[$2] = 1 }
        /^NOT RUN [^ ]+/ { order[++n] = $3; st[$3] = "notrun" }
        /^FAIL [^ ]+/ { c = $2; sub(/:$/, "", c); failed[++f] = c }
        /^E2E: CRASH / { crash = 1 }
        END {
          for (i = 1; i <= f; i++) {
            c = failed[i]; owner = ""
            for (t in st) if ((c == t || index(c, t ".") == 1) && length(t) > length(owner)) owner = t
            if (owner != "" && st[owner] == "pass") st[owner] = "fail"
          }
          if (crash) for (t in pending) if (st[t] == "pass") st[t] = "fail"
          for (i = 1; i <= n; i++) print order[i], st[order[i]]
        }' "$root/$dir/report.txt" 2>/dev/null)$'\n'
    fi
    if [ "$rc" = 0 ]; then
      passed=$((passed + 1))
      rm -f ${repeat_out:+"$repeat_out"}
      say "repeat $i/$repeat: $line"
      continue
    fi
    # A failing repeat's short output goes to the terminal.
    [ -z "$repeat_out" ] || { cat "$repeat_out"; rm -f "$repeat_out"; }
    repeat_out=""
    tell "repeat $i/$repeat failed: $line"
    case $rc in
      130) echo "E2E: ERROR interrupted"; exit 130 ;;
      64)
        echo "E2E: ERROR repeat $i/$repeat could not run: ${line#E2E: ERROR }"
        exit 64 ;;
    esac
    failed="$failed${failed:+, }repeat $i (${line#E2E: })"
    if [ -z "$first_code" ]; then
      first_code=$rc
      case $rc in 1) first_kind=FAIL ;; 2) first_kind=TIMEOUT ;; 3) first_kind=FLAKY ;; *) first_kind=CRASH ;; esac
    fi
  done
  # Each test's passes out of N, in the order the tests first ran; short output lists only those below N.
  printf '%s' "$tally" | awk -v n="$repeat" -v quiet="$quiet" '
    NF == 2 { if (!($1 in seen)) { seen[$1]; order[++k] = $1 } if ($2 == "pass") ok[$1]++ }
    END { for (i = 1; i <= k; i++) { t = order[i]; if (quiet != 1 || ok[t] + 0 < n) printf "REPEAT %s %d/%d\n", t, ok[t], n } }'
  # Short output hides passing repeats, each of which names the expired entries; a person saw every repeat's.
  [ "$quiet" = 0 ] || expired_lines
  tell "repeat run folders in $root: $folders"
  if [ -z "$first_code" ]; then
    echo "E2E: PASS $repeat/$repeat repeats"
    exit 0
  fi
  echo "E2E: $first_kind $passed/$repeat repeats passed; failed: $failed"
  exit "$first_code"
fi
bundle=$(basename "$app")

# The real path: the runner hands Chromium the run folder's real path, and the sweep matches it.
mkdir -p "$root" && root=$(cd "$root" && pwd -P)
if [ -n "$shard_dir" ]; then
  # A shard of a sharded run: the folder its run made for it, which latest and pruning leave to that run.
  mkdir -p "$shard_dir" && run=$(cd "$shard_dir" && pwd -P)
  run_name=$(basename "$run")
else
  run_name="$(date +%Y%m%d-%H%M%S)-$$"
  run="$root/$run_name"
  mkdir -p "$run"
fi
echo "Made by a Bow e2e run." > "$run/$marker"
[ -n "$shard_dir" ] || ln -sfn "$run_name" "$root/latest"
say "$run"

# Keep the newest $keep run folders (only folders an e2e run made), so build/e2e does not grow without bound.
prune() {
  local n=0 entry
  while IFS= read -r entry; do
    [ -n "$entry" ] && [ "$entry" != latest ] && [ -f "$root/$entry/$marker" ] || continue
    n=$((n + 1))
    if [ "$n" -gt "$keep" ] && [ "$entry" != "$run_name" ]; then
      # A test that locks a folder and is killed before it unlocks it would otherwise keep the run forever.
      chmod -R u+rwX "${root:?}/$entry" 2>/dev/null
      rm -rf "${root:?}/$entry"
    fi
  done < <(cd "$root" && ls -1t)
}
[ -n "$shard_dir" ] || prune

# Every helper Chromium starts carries the run folder in its arguments (its user data and cache paths), so a
# process of the app bundle whose command line names the folder belongs to this run (a `tail -f` of its log does
# not). Ends them: TERM, then KILL after 2 seconds.
orphans_killed=0
# nap <seconds>: sleeps in the background and waits, so a signal's trap runs at once instead of after the sleep.
nap() { sleep "$1" 3>&- & wait $!; }
sweep() {
  local pids pid i n=0
  # The folder followed by "/" (helpers) or by a space or the end of the line (the app's own --e2e-out=<folder>,
  # in case the app outlived its build lock), so a run never matches a sibling whose name starts with its own.
  # The build lock still running (child, during an interrupt) is left to end by itself and give back its slot.
  # ps runs in the background and is waited for, so a signal during a slow ps stops the run at once too.
  rm -f "$snapshot" # left by a sweep an earlier signal interrupted (on_signal sweeps again)
  snapshot=$(mktemp "$run/.ps.XXXXXX" 2> /dev/null || mktemp -t bow-e2e-ps) || return 0
  ps -axo pid=,command= > "$snapshot" 2> /dev/null 3>&- &
  wait $!
  pids=$(D="$1" B="$bundle/Contents/" awk -v me=$$ -v child="${child:-0}" '
    { line = $0 " " }
    index(line, ENVIRON["B"]) && (index(line, ENVIRON["D"] "/") || index(line, "=" ENVIRON["D"] " ")) && $1 != me && $1 != child { print $1 }' "$snapshot")
  rm -f "$snapshot"
  snapshot=""
  [ -n "$pids" ] || return 0
  for pid in $pids; do kill -TERM "$pid" 2>/dev/null && n=$((n + 1)); done
  orphans_killed=$((orphans_killed + n))
  for i in 1 2 3 4 5 6 7 8 9 10; do
    pids=$(for pid in $pids; do kill -0 "$pid" 2>/dev/null && echo "$pid"; done)
    [ -n "$pids" ] || break
    nap 0.2
  done
  for pid in $pids; do kill -KILL "$pid" 2>/dev/null; done
  say "ended $n helper processes the app left running"
}

json() { printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037')"; }

# The commit and dirty fields of results.json.
commit_json() {
  local commit dirty=false
  commit=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null)
  [ -z "$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)" ] || dirty=true
  printf '"commit":%s,"dirty":%s' "$(json "$commit")" "$dirty"
}

# The build lock (and the app it runs) runs in the background while this script waits for it: bash runs a trap
# only between commands, so a foreground app would hold off Ctrl-C until it ended, but `wait` returns at once.
# child is that background job, current the folder it runs in.
current=""
child=""
# The snapshot file of a sweep in progress (in $run, or in $TMPDIR when that fails), removed by on_signal.
snapshot=""
# The shards' own runs of this script while they run (E2E_SHARDS), which a signal stops.
shard_pids=""
# The real stdout, kept apart: list_tests redirects stdout for a while, and the summary of an interrupt must reach
# the terminal whatever a signal interrupted. run_child closes it for the app, whose helpers may outlive the run and
# would otherwise hold open a pipe that captures this script's output.
exec 3>&1
# gone <pid> <tries>: waits up to <tries> times 0.2 seconds for the process to end; fails if it still runs.
gone() {
  local i
  for i in $(seq "$2"); do
    kill -0 "$1" 2>/dev/null || return 0
    nap 0.2
  done
  ! kill -0 "$1" 2>/dev/null
}
# is_build_lock <pid>: true while the process is the build lock this script started for the folder in $current: its
# command is `<shell> <repo>/scripts/build-lock.sh ...` and ends with the `--e2e-out=<folder>` argument, both
# compared exactly (not as a pattern), so a recycled PID is never mistaken for it.
is_build_lock() {
  ps -o command= -p "$1" 2> /dev/null | S="$repo/scripts/build-lock.sh" T="--e2e-out=$current" awk '
    { line = " " $0; ok = index(line, " " ENVIRON["S"] " ") && length($0) >= length(ENVIRON["T"]) \
        && substr($0, length($0) - length(ENVIRON["T"]) + 1) == ENVIRON["T"] }
    END { exit !ok }'
}
on_signal() {
  trap '' INT TERM HUP
  # The build lock passes TERM on to the app and gives back its slot (a background job ignores INT, so TERM). An
  # app that ignores TERM for 5 seconds is swept (KILL after 2 more), which lets the build lock end and give back
  # its slot; only a build lock still running 2 seconds after that is killed.
  if [ -n "$child" ] && kill -TERM "$child" 2>/dev/null; then
    gone "$child" 25 || { [ -z "$current" ] || sweep "$current"; gone "$child" 10; } || {
      # The PID was seen alive seconds ago: KILL it only while it is still this run's build lock.
      is_build_lock "$child" && kill -KILL "$child" 2>/dev/null
    }
    wait "$child" 2>/dev/null
  fi
  [ -z "$current" ] || sweep "$current"
  # Shards running: each ends its own app and helpers and gives back its slot; a sweep of the run folder then ends
  # whatever a shard could not.
  if [ -n "$shard_pids" ]; then
    local pid
    for pid in $shard_pids; do kill -TERM "$pid" 2>/dev/null; done
    for pid in $shard_pids; do wait "$pid" 2>/dev/null; done
    shard_pids=""
    sweep "$run"
  fi
  rm -f "$run"/.shard-*.out
  rm -f "$run"/.ps.* "$run/$output" "$run/retry/$output" ${snapshot:+"$snapshot"} # a snapshot left by a sweep this signal interrupted
  printf '{"status":"interrupted","exitCode":130,"signal":%s,"summary":"E2E: ERROR interrupted","selection":%s,"run":%s,%s}\n' \
    "$(json "$1")" "$(json "$selection")" "$(json "$run")" "$(commit_json)" > "$run/results.json"
  echo "E2E: ERROR interrupted" >&3
  echo "E2E: ERROR interrupted" >> "$run/report.txt"
  exit 130
}
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP

# Runs a command as the background child, keeping this script's stdin, waits for it and returns its exit code.
run_child() {
  local code
  "$@" <&0 3>&- &
  child=$!
  wait "$child"
  code=$?
  child=""
  return "$code"
}

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
load() { sysctl -n vm.loadavg | awk '{ print $2 }'; }

# Runs the app once into folder $1 with the remaining arguments. Sets: status (pass, fail, timeout, crash, error),
# summary (its E2E line), app_code, signal, seconds.
started=.app-started
attempt() {
  local dir=$1 start
  shift
  mkdir -p "$dir"
  [ -f "$dir/$marker" ] || echo "Made by a Bow e2e run." > "$dir/$marker"
  rm -f "$dir/$started"
  current=$dir
  start=$(now)
  # The stamp tells an exit 64 of the app (it refused the selection) from one of the build lock (it never ran the
  # app). exec keeps the app's pid, exit code and signal.
  # Short output keeps what the app and the build lock print in a file, read back at the end.
  if [ "$quiet" = 1 ]; then
    run_child "$repo/scripts/build-lock.sh" --pool e2e /bin/sh -c ': > "$0/'"$started"'"; exec "$@"' "$dir" "$binary" "$@" --e2e-out="$dir" \
      > "$dir/$output" 2>&1
  else
    run_child "$repo/scripts/build-lock.sh" --pool e2e /bin/sh -c ': > "$0/'"$started"'"; exec "$@"' "$dir" "$binary" "$@" --e2e-out="$dir"
  fi
  app_code=$?
  seconds=$(perl -e 'printf "%.2f", $ARGV[1] - $ARGV[0]' "$start" "$(now)")
  sweep "$dir"
  current=""
  # results.json in a run folder is this script's; keep one the app wrote under another name.
  [ ! -f "$dir/results.json" ] || mv "$dir/results.json" "$dir/app-results.json"
  signal=""
  [ "$app_code" -gt 128 ] && signal=$((app_code - 128))
  summary=$(grep '^E2E: ' "$dir/report.txt" 2>/dev/null | tail -n 1)
  # A stuck main thread may print NOT RUN lines and more after its TIMEOUT line; the TIMEOUT line is the summary.
  if [ "$app_code" = 2 ] && grep -q '^E2E: TIMEOUT ' "$dir/report.txt" 2>/dev/null; then
    summary=$(grep '^E2E: TIMEOUT ' "$dir/report.txt" | tail -n 1)
  fi
  case "$app_code:$summary" in
    "0:E2E: PASS "*) status=pass ;;
    "1:E2E: FAIL "*) status=fail ;;
    "2:E2E: TIMEOUT "*) status=timeout ;;
    "64:"*)
      status=error
      if [ -f "$dir/$started" ]; then
        summary="E2E: ERROR the app could not start the run (exit 64): an unknown selection or switch"
      else
        summary="E2E: ERROR the build lock refused to run the app (exit 64); see its message above"
      fi
      ;;
    *)
      status=crash
      local why="E2E: CRASH exit=$app_code${signal:+ signal=$signal}"
      # Chromium's own watchdog ends the app with exit 2 when shutdown hangs, usually after the summary line.
      local watchdog=""
      if [ "$app_code" = 2 ] && grep -q 'Teardown watchdog expired' "$dir/chromium.log" 2>/dev/null; then
        watchdog=1
        why="$why Chromium teardown watchdog during quit"
      fi
      if [ -n "$summary" ]; then why="$why after its summary line ($summary)"
      elif [ -z "$watchdog" ]; then why="$why without a summary line"; fi
      summary=$why
      echo "$summary" >> "$dir/report.txt"
      ;;
  esac
}

# The test names the app knows, from the TEST lines of `--e2e=list` (which starts no engine). Asked only to check
# the test a TIMEOUT line names; an app without the list selection prints none, so that name is not trusted.
list_tests() {
  current=$1
  run_child "$repo/scripts/build-lock.sh" --pool e2e perl -e 'alarm 30; exec @ARGV' "$binary" --e2e=list --e2e-out="$1" \
    > "$1.txt" 2> /dev/null
  sweep "$1" > /dev/null
  current=""
  awk '/^TEST [^ ]+/ { print $2 }' "$1.txt"
}

# What failed in folder $1 (its report.txt; $2 is a file of known test names, one per line, maybe empty), one line
# each, fields split by $us:
#   T test reason   a failed or timed out test, from its RESULT line, or the test a stuck main thread stopped in
#                   (named by `E2E: TIMEOUT <test>: <step>`, trusted only when a RESULT, NOT RUN or TEST line names
#                   that test); the FAIL lines printed after the TIMEOUT line are the stuck test's too (its step
#                   may end and fail before the app exits), except chromium.errors and e2e.isolation (C lines)
#   C check reason  a failure that is no test's: a FAIL line not followed by a failed test's RESULT line
#                   (chromium.errors, e2e.isolation after a passing test, the quit check), or a TIMEOUT line naming
#                   no known test (`E2E: TIMEOUT between tests (...)`) and the FAIL lines around it
#   R test          a test the retry reruns: the failed, timed out and not run ones
#   W               the retry reruns the whole selection: there is a C line, or there are no RESULT lines at all
# The runner prints a test's FAIL lines before its RESULT line, and run-wide checks after the last RESULT line.
analyze() {
  awk -v us="$us" -v known_file="$2" '
    BEGIN { if (known_file != "") while ((getline k < known_file) > 0) if (k != "") known[k] }
    function test(n, r) { if (!(n in tseen)) { tseen[n]; out = out "T" us n us r "\n"; retry(n) } }
    function retry(n) { if (!(n in rseen)) { rseen[n]; rlist = rlist "R" us n "\n" } }
    function check(n, r) { checks = checks "C" us n us r "\n" }
    function flush_pending(  i) { for (i = 1; i <= np; i++) check(pn[i], pr[i]); np = 0 }
    /^FAIL / {
      n = $2; sub(/:$/, "", n); r = $0; sub(/^FAIL [^ ]*:? ?/, "", r)
      # After the TIMEOUT line a FAIL line belongs to the stuck test, like those since the last RESULT line, except
      # the checks the runner owns, which no test rerun covers.
      if (timed && (n == "chromium.errors" || n == "e2e.isolation")) check(n, r)
      else if (timed) { ntp++; tn[ntp] = n; tr[ntp] = r }
      else { np++; pn[np] = n; pr[np] = r }
      next
    }
    /^RESULT [^ ]+ [^ ]+/ {
      results = 1; known[$2]
      if ($3 == "fail" || $3 == "timeout") { r = $0; sub(/^RESULT [^ ]+ /, "", r); test($2, r); np = 0 }
      else flush_pending()
      next
    }
    /^NOT RUN [^ ]+/ { known[$3]; notrun[++nn] = $3; next }
    /^E2E: TIMEOUT / && !timed {
      timed = 1; tline = $0; sub(/^E2E: TIMEOUT /, "", tline)
      if (match(tline, /^[^ :]+:/)) tname = substr(tline, 1, RLENGTH - 1)
      # FAIL lines printed since the last RESULT line belong to the stuck test, if it is one.
      for (i = 1; i <= np; i++) { tn[i] = pn[i]; tr[i] = pr[i] }
      ntp = np; np = 0
      next
    }
    END {
      if (timed) {
        if (tname != "" && (tname in known)) test(tname, "TIMEOUT " tline)
        else { for (i = 1; i <= ntp; i++) check(tn[i], tr[i]); check("TIMEOUT", tline) }
      }
      flush_pending()
      for (i = 1; i <= nn; i++) retry(notrun[i])
      printf "%s%s%s", out, checks, rlist
      if (checks != "" || !results) print "W"
    }
  ' "$1/report.txt" 2>/dev/null
}

# E2E_SHARDS. resolve_selection <TEST lines file>: prints the selected test names in test order, matching each
# comma separated part as the app does (a name, an area, a tag or a glob of names, and only the exact name for a
# test whose line ends in by-name-only); fails when a part matches no test or nothing is selected, so the app
# itself refuses the selection.
resolve_selection() {
  local kw name area tags rest i part matched parts
  local names=() areas=() tagsets=() byname=() chosen=()
  while read -r kw name area tags rest; do
    [ "$kw" = TEST ] && [ -n "$name" ] || continue
    names+=("$name")
    areas+=("${area#area=}")
    tags=${tags#tags=}
    [ "$tags" != - ] || tags=""
    tagsets+=(",$tags,")
    case " $rest " in *" by-name-only "*) byname+=(1) ;; *) byname+=(0) ;; esac
    chosen+=(0)
  done < "$1"
  [ "${#names[@]}" -gt 0 ] || return 1
  if [ "$selection" = all ]; then
    for i in "${!names[@]}"; do [ "${byname[i]}" = 1 ] || echo "${names[i]}"; done
    return 0
  fi
  IFS=, read -ra parts <<< "$selection"
  [ "${#parts[@]}" -gt 0 ] || return 1
  for part in "${parts[@]}"; do
    part="${part#"${part%%[![:blank:]]*}"}"
    part="${part%"${part##*[![:blank:]]}"}"
    [ -n "$part" ] || continue
    matched=0
    for i in "${!names[@]}"; do
      # The last test is fnmatch with no flags, as the app's: an unquoted pattern.
      if [ "${names[i]}" = "$part" ] || { [ "${byname[i]}" = 0 ] && { [ "${areas[i]}" = "$part" ] \
        || [[ ${tagsets[i]} == *",$part,"* ]] || [[ ${names[i]} == $part ]]; }; }; then
        chosen[i]=1 matched=1
      fi
    done
    [ "$matched" = 1 ] || return 1
  done
  matched=0
  for i in "${!names[@]}"; do [ "${chosen[i]}" = 0 ] || { echo "${names[i]}"; matched=1; }; done
  [ "$matched" = 1 ]
}

# plan_shards <shards> <names file>: deals the tests in the names file onto the shards, longest first, each onto the
# least loaded shard (the lowest numbered on a tie), by each test's seconds in the newest results.json under the run
# root that has it. A test with none counts as the average of those that do, or as 1 with no history at all; tests
# of the same length keep test order. Prints shard<US>test<US>seconds lines, then H<US><runs read with a time>.
plan_shards() {
  local files=() f
  while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done < <(ls -1t "$root"/*/results.json 2>/dev/null | head -n 50)
  perl -MJSON::PP -e '
    my ($n, $names, @files) = @ARGV;
    open(my $fh, "<", $names) or exit 1;
    my @tests = grep { length } map { s/\s+\z//r } <$fh>;
    my %want = map { $_ => 1 } @tests;
    my (%seconds, $used);
    for my $file (@files) {
      my $doc = eval { open(my $j, "<", $file) or die; local $/; decode_json(<$j>) };
      next unless ref $doc eq "HASH" && ref $doc->{attempts} eq "ARRAY" && ref $doc->{attempts}[0] eq "HASH";
      my $any = 0;
      for my $t (@{ref $doc->{attempts}[0]{tests} eq "ARRAY" ? $doc->{attempts}[0]{tests} : []}) {
        next unless ref $t eq "HASH" && defined $t->{name} && !ref $t->{name} && $want{$t->{name}};
        next if exists $seconds{$t->{name}};
        my $s = $t->{seconds};
        next unless defined $s && !ref $s && $s =~ /^[0-9]+(\.[0-9]+)?\z/;
        $seconds{$t->{name}} = $s + 0;
        $any = 1;
      }
      $used++ if $any;
    }
    my @known = values %seconds;
    my $average = 1;
    if (@known) { $average = 0; $average += $_ for @known; $average /= @known }
    my %order;
    @order{@tests} = 0 .. $#tests;
    my %w = map { $_ => exists $seconds{$_} ? $seconds{$_} : $average } @tests;
    my @load = (0) x $n;
    for my $t (sort { $w{$b} <=> $w{$a} || $order{$a} <=> $order{$b} } @tests) {
      my $k = 0;
      for my $i (1 .. $n - 1) { $k = $i if $load[$i] < $load[$k] }
      $load[$k] += $w{$t};
      printf "%d\037%s\037%.2f\n", $k + 1, $t, $w{$t};
    }
    printf "H\037%d\n", $used // 0;
  ' "$1" "$2" ${files[@]+"${files[@]}"}
}

# check_plan <names file> <shards> <plan>: true when every selected test is in exactly one shard, the plan names no
# other test, and every shard has a test. A plan that fails this stops the run: a test must never go unrun silently.
check_plan() {
  printf '%s\n' "$3" | awk -F "$us" -v names="$1" -v n="$2" '
    BEGIN { while ((getline l < names) > 0) if (l != "") { want[l]; count++ } }
    $1 == "H" || $0 == "" { next }
    { if (NF != 3 || !($2 in want) || ($2 in seen) || $1 !~ /^[0-9]+$/ || $1 < 1 || $1 > n) bad = 1; seen[$2]; used[$1] }
    END {
      for (t in want) if (!(t in seen)) bad = 1
      for (k = 1; k <= n; k++) if (!(k in used)) bad = 1
      exit bad || count == 0
    }'
}

# The shards: shard_count of them, shard_tests_<k> each one's comma list of tests, shard_plan the plan lines.
shard_count=0 shard_plan=""
# plan_run: lists the app's tests and plans the shards. Fails, saying why, when the run should be a single one.
plan_run() {
  local names="$run/selected-tests" count k history tests
  list_tests "$run/tests" > "$run/known-tests"
  if ! resolve_selection "$run/tests.txt" > "$names"; then
    say "E2E_SHARDS=$shards: the app's test list did not resolve the selection; running it in one app"
    return 1
  fi
  count=$(grep -c . "$names")
  if [ "$count" -lt 2 ]; then
    say "E2E_SHARDS=$shards: one test selected; running it in one app"
    return 1
  fi
  shard_count=$shards
  [ "$count" -ge "$shard_count" ] || shard_count=$count
  shard_plan=$(plan_shards "$shard_count" "$names")
  if ! check_plan "$names" "$shard_count" "$shard_plan"; then
    tell "the shard plan does not put every selected test in exactly one shard:"
    printf '%s\n' "$shard_plan" | tr "$us" ' '
    status=error summary="E2E: ERROR the shard plan lost or repeated a test"
    return 2
  fi
  history=$(printf '%s\n' "$shard_plan" | awk -F "$us" '$1 == "H" { print $2 }')
  if [ "${history:-0}" = 0 ]; then say "$count tests in $shard_count shards, split in test order (no earlier run timed them)"
  else say "$count tests in $shard_count shards, planned from the test times of $history earlier runs"; fi
  # Each shard's tests in test order (the app runs them in that order whatever the list says), and its selection:
  # the same names, except that a name that is also an area or a tag (the test downloads in the area downloads)
  # goes as a glob matching just that name (download[s]), since the app would take it as the whole area or tag.
  while IFS="$us" read -r k tests sel; do
    [[ $k =~ ^[0-9]+$ ]] && eval "shard_tests_$k=\$tests shard_selection_$k=\$sel"
  done < <(printf '%s\n' "$shard_plan" | awk -F "$us" -v names="$names" -v list="$run/tests.txt" '
    BEGIN {
      while ((getline l < list) > 0) {
        if (split(l, f, " ") < 4 || f[1] != "TEST") continue
        sub(/^area=/, "", f[3]); taken[f[3]]
        sub(/^tags=/, "", f[4]); n = split(f[4], tags, ","); for (i = 1; i <= n; i++) taken[tags[i]]
      }
    }
    $1 != "H" && NF == 3 { shard[$2] = $1 }
    END {
      while ((getline t < names) > 0) {
        if (!(t in shard)) continue
        k = shard[t]
        s = (t in taken) ? substr(t, 1, length(t) - 1) "[" substr(t, length(t)) "]" : t
        tl[k] = tl[k] (tl[k] == "" ? "" : ",") t
        sl[k] = sl[k] (sl[k] == "" ? "" : ",") s
      }
      for (k in tl) print k FS tl[k] FS sl[k]
    }')
}

# run_shards: runs every shard at once, each as this script in <run>/shard-<k> with the retry off, waits for all
# and merges them into the run folder. Sets what attempt sets for the first attempt, plus log_dir.
run_shards() {
  local k pid code start sel codes=""
  start=$(now)
  for k in $(seq "$shard_count"); do
    eval "sel=\$shard_selection_$k"
    say "shard $k/$shard_count: $sel"
    mkdir -p "$run/shard-$k"
    # A shard's output goes to a file, shown once every shard has ended (a person) or read for its failing lines.
    E2E_SHARD_DIR="$run/shard-$k" E2E_SHARDS=1 E2E_RETRY=0 E2E_REPEAT=1 E2E_QUIET=$quiet \
      "$0" "$app" "$sel" <&0 3>&- > "$run/.shard-$k.out" 2>&1 &
    shard_pids="$shard_pids $!"
  done
  for pid in $shard_pids; do
    wait "$pid"
    codes="$codes $?"
  done
  shard_pids=""
  seconds=$(perl -e 'printf "%.2f", $ARGV[1] - $ARGV[0]' "$start" "$(now)")
  # Nothing should be left: each shard swept its own folder.
  sweep "$run"
  if [ "$quiet" = 0 ]; then
    for k in $(seq "$shard_count"); do
      tell "shard $k/$shard_count output:"
      cat "$run/.shard-$k.out"
    done
  fi
  merge_shards $codes
}

# merge_shards <exit code of each shard>: writes the run's report.txt from the shards' and sets status, summary,
# app_code, signal, log_dir, shard_orphans and shards_json.
merge_shards() {
  local kind value merged
  merged=$(SHARD_PLAN="$shard_plan" perl -MJSON::PP -e '
    my ($run, @codes) = @ARGV;
    my $n = @codes;
    my %planned;
    for (split /\n/, $ENV{SHARD_PLAN}) {
      my ($k, $t, $s) = split /\037/;
      next unless defined $s;
      push @{$planned{$k}{tests}}, $t;
      $planned{$k}{seconds} += $s;
    }
    my @runner = ("e2e.isolation", "chromium.errors");
    my %is_runner = map { $_ => 1 } @runner;
    my $rank = { error => 5, crash => 4, timeout => 3, fail => 2, pass => 1 };
    my (@shards, %runner_lines, $all_totals, $sum_p, $sum_n, $all_pass, $orphans);
    ($all_totals, $all_pass, $sum_p, $sum_n, $orphans) = (1, 1, 0, 0, 0);
    for my $k (1 .. $n) {
      my $dir = "$run/shard-$k";
      my $code = $codes[$k - 1];
      my $doc = eval { open(my $j, "<", "$dir/results.json") or die; local $/; decode_json(<$j>) };
      $doc = {} unless ref $doc eq "HASH";
      my $first = ref $doc->{attempts} eq "ARRAY" && ref $doc->{attempts}[0] eq "HASH" ? $doc->{attempts}[0] : {};
      my $status = $doc->{status} // "";
      my $summary = $doc->{summary} // "";
      if ($code == 130 || $status eq "interrupted") {
        ($status, $summary) = ("crash", "E2E: CRASH exit=$code the shard was interrupted");
      } elsif ($status !~ /^(pass|fail|timeout|crash|error)\z/) {
        ($status, $summary) = ("crash", "E2E: CRASH exit=$code the shard wrote no results.json");
      }
      $orphans += $doc->{orphansKilled} // 0;
      my (@lines, %runner_here, $total);
      if (open(my $r, "<", "$dir/report.txt")) {
        while (my $l = <$r>) {
          chomp $l;
          if ($l =~ /^(PASS|FAIL) ([^ ]+?):? (.*)\z/ && $is_runner{$2}) { $runner_here{$2} = [$1, $3]; next }
          if ($l =~ /^E2E: (PASS|FAIL) ([0-9]+)\/([0-9]+)/) { $total = [$1, $2, $3]; next }
          next if $l =~ /^E2E: (CRASH|ERROR) /;
          push @lines, $l;
        }
      }
      # The plan puts each test in one shard, so a shard that ran another test (the app read a name as an area,
      # say) would count it twice: never silently.
      my %mine = map { $_ => 1 } @{$planned{$k}{tests} || []};
      my @extra = grep { !$mine{$_} } map { /^(?:RESULT|NOT RUN) ([^ ]+)/ ? $1 : () } @lines;
      # A shard that ran to its total ran every test of its plan (one that timed out or crashed says so itself).
      my %result = map { /^RESULT ([^ ]+)/ ? ($1 => 1) : () } @lines;
      my @missing = $status =~ /^(pass|fail)\z/ ? grep { !$result{$_} } @{$planned{$k}{tests} || []} : ();
      if (@extra) {
        ($status, $summary) = ("error", "E2E: ERROR it ran tests outside its plan: " . join(", ", @extra));
      } elsif (@missing) {
        ($status, $summary) = ("error", "E2E: ERROR it did not run tests of its plan: " . join(", ", @missing));
      }
      if ($total) {
        my ($rn, $rp) = (0, 0);
        for (values %runner_here) { $rn++; $rp++ if $_->[0] eq "PASS" }
        $sum_n += $total->[2] - $rn;
        $sum_p += $total->[1] - $rp;
        $all_pass = 0 if $total->[0] ne "PASS";
      } else {
        $all_totals = 0;
      }
      for my $c (keys %runner_here) { push @{$runner_lines{$c}}, [$k, @{$runner_here{$c}}] }
      push @shards, { k => $k, dir => $dir, code => $code, status => $status, summary => $summary,
        app => $first->{appExitCode}, signal => $first->{signal}, seconds => $first->{seconds}, lines => \@lines,
        quit => scalar grep { /^RESULT [^ ]+ [^ ]+ .*quit=pending( |\z)/ } @lines };
    }
    # The shards that timed out go last, so the lines after a TIMEOUT line are the stuck shard'"'"'s own.
    my @ordered = ((grep { $_->{status} ne "timeout" } @shards), (grep { $_->{status} eq "timeout" } @shards));
    my @report = map { @{$_->{lines}} } @ordered;
    my ($rn, $rp) = (0, 0);
    for my $c (@runner) {
      my $results = $runner_lines{$c} or next;
      my $failed = grep { $_->[1] eq "FAIL" } @$results;
      push @report, ($failed ? "FAIL" : "PASS") . " $c: " . join("; ", map { "shard $_->[0]/$n: $_->[2]" } @$results);
      $rn++;
      $rp++ unless $failed;
    }
    my ($worst) = sort { $rank->{$b->{status}} <=> $rank->{$a->{status}} || $a->{k} <=> $b->{k} } @shards;
    my $status = $worst->{status};
    my $line = "";
    if ($all_totals) {
      $line = sprintf "E2E: %s %d/%d", ($all_pass ? "PASS" : "FAIL"), $sum_p + $rp, $sum_n + $rn;
      push @report, $line;
    }
    my $summary;
    if ($status eq "pass" || $status eq "fail") { $summary = $line || $worst->{summary} }
    elsif ($status eq "timeout") { $summary = $worst->{summary} }
    elsif ($status eq "crash") { $summary = "$worst->{summary} in shard $worst->{k}/$n"; push @report, $summary }
    else { (my $why = $worst->{summary}) =~ s/^E2E: ERROR //; $summary = "E2E: ERROR shard $worst->{k}/$n: $why" }
    open(my $out, ">", "$run/report.txt") or die "cannot write $run/report.txt: $!\n";
    print $out map { "$_\n" } @report;
    close $out;
    my ($quit) = (grep({ $_->{quit} } @shards), $shards[0]);
    my $json = JSON::PP->new->canonical;
    my @info = map { {
      folder => $_->{dir}, tests => $planned{$_->{k}}{tests} || [],
      plannedSeconds => 0 + sprintf("%.2f", $planned{$_->{k}}{seconds} // 0), status => $_->{status},
      exitCode => 0 + $_->{code}, seconds => $_->{seconds}, summary => $_->{summary} } } @shards;
    my $sig = $status eq "pass" ? "" : ($worst->{signal} // "");
    print join("\037", "status", $status), "\n";
    print join("\037", "summary", $summary =~ s/[\x00-\x1f]/ /gr), "\n";
    print join("\037", "app", $status eq "pass" ? 0 : ($worst->{app} // $worst->{code})), "\n";
    print join("\037", "signal", $sig), "\n";
    print join("\037", "log", $status eq "pass" || $status eq "fail" ? $run : $worst->{dir}), "\n";
    print join("\037", "final", $quit->{dir}), "\n";
    print join("\037", "orphans", $orphans), "\n";
    print join("\037", "json", $json->encode(\@info)), "\n";
  ' "$run" "$@")
  status=crash summary="E2E: CRASH the shards could not be merged" app_code=4 signal="" log_dir=$run
  shard_orphans=0 shards_json="[]"
  while IFS="$us" read -r kind value; do
    case $kind in
      status) status=$value ;; summary) summary=$value ;; app) app_code=$value ;; signal) signal=$value ;;
      log) log_dir=$value ;; orphans) shard_orphans=$value ;; json) shards_json=$value ;;
      final) [ ! -f "$value/final.png" ] || cp -p "$value/final.png" "$run/final.png" ;;
    esac
  done <<< "$merged"
}

# shard_analysis: what failed in each shard (analyze on its own report), as one analysis: the tests, then the
# failures that are no test's (one per check), then the tests to rerun. A shard that would rerun its whole selection
# (W: a run-wide check failed, or it printed no RESULT line) reruns every test it ran, so the retry's run-wide
# checks cover them all again, as a single run's rerun of its whole selection does.
shard_analysis() {
  local k one tests
  for k in $(seq "$shard_count"); do
    one=$(analyze "$run/shard-$k" "$run/known-tests")
    printf '%s\n' "$one" | grep -vx W
    if printf '%s\n' "$one" | grep -qx W; then
      eval "tests=\$shard_tests_$k"
      printf '%s\n' "$tests" | tr , '\n' | awk -v us="$us" 'NF { print "R" us $0 }'
    fi
  done | awk -F "$us" '
    $1 == "T" && !seen["T" $2]++ { t = t $0 "\n" }
    $1 == "C" && !seen["C" $2]++ { c = c $0 "\n" }
    $1 == "R" && !seen["R" $2]++ { r = r $0 "\n" }
    END { printf "%s%s%s", t, c, r }'
}

args=("--e2e=$selection")
load_start=$(load)
sharded=0 shard_orphans=0 shards_json=""
plan_code=1
[ "$shards" = 1 ] || { plan_run; plan_code=$?; }
if [ "$plan_code" = 0 ]; then
  sharded=1
  run_shards
elif [ "$plan_code" = 2 ]; then
  app_code=64 signal="" seconds=0
  echo "$summary" >> "$run/report.txt"
else
  attempt "$run" "${args[@]}"
fi
first_status=$status first_summary=$summary
attempts=("$run|$status|$app_code|$signal|$seconds|$summary")
flaky=""
# The quarantine entries (name<US>expiry<US>reason) that turned a FLAKY run into a pass.
quarantined=""
# A sharded run's merge named the shard whose chromium.log says most.
[ "$sharded" = 1 ] || log_dir=$run

if [ "$retry" = 1 ] && { [ "$status" = fail ] || [ "$status" = timeout ]; } && [ "$sharded" = 1 ]; then
  # Each shard is analyzed as a single run is, against the test list its plan came from.
  analysis=$(shard_analysis)
elif [ "$retry" = 1 ] && { [ "$status" = fail ] || [ "$status" = timeout ]; }; then
  known="$run/known-tests"
  : > "$known"
  # A TIMEOUT naming a test that no RESULT or NOT RUN line names: ask the app for its test list to check the name.
  tname=$(sed -n 's/^E2E: TIMEOUT \([^ :]*\):.*/\1/p' "$run/report.txt" 2>/dev/null | head -n 1)
  if [ -n "$tname" ] && ! awk -v t="$tname" '($1 == "RESULT" && $2 == t) || ($1 " " $2 == "NOT RUN" && $3 == t) { f = 1 } END { exit !f }' "$run/report.txt"; then
    list_tests "$run/list" > "$known"
  fi
  analysis=$(analyze "$run" "$known")
fi
if [ "$retry" = 1 ] && { [ "$status" = fail ] || [ "$status" = timeout ]; }; then
  # What failed, as name<US>reason lines: the tests, then the failures that are no test's.
  failed=$(printf '%s\n' "$analysis" | awk -F "$us" '$1 == "T" || $1 == "C" { print $2 FS $3 }')
  names=$(printf '%s\n' "$failed" | awk -F "$us" '$1 != "" { print $1 }' | paste -sd, -)
  retry_args=("${args[@]}")
  subset=$(printf '%s\n' "$analysis" | awk -F "$us" '$1 == "R" { print $2 }' | paste -sd, -)
  if [ -n "$subset" ] && ! printf '%s\n' "$analysis" | grep -qx W; then retry_args=("--e2e=$subset"); fi
  # The FLAKY count covers the whole selection: the first attempt's total, every check of which has now passed,
  # or the retry's own when it reran the whole selection. A timeout may print no total.
  total=$(grep -E '^E2E: (PASS|FAIL) [0-9]+/[0-9]+' "$run/report.txt" 2>/dev/null | tail -n 1 | sed -E 's|^E2E: [A-Z]+ [0-9]+/([0-9]+).*|\1|')
  say "$first_summary; retrying once in a fresh app"
  attempt "$run/retry" "${retry_args[@]}"
  attempts+=("$run/retry|$status|$app_code|$signal|$seconds|$summary")
  if [ "$status" = pass ]; then
    flaky=$failed
    printf '%s\n' "$failed" | while IFS="$us" read -r name reason; do
      [ -n "$name" ] && echo "FLAKY $name: failed then passed ($reason)"
    done | if [ "$quiet" = 1 ]; then cat >> "$run/report.txt"; else tee -a "$run/report.txt"; fi
    status=flaky
    count=${summary#E2E: PASS }
    if [ -n "$total" ]; then
      summary="E2E: FLAKY $total/$total after retrying ${names:-the run}"
    elif [ "${retry_args[*]}" = "${args[*]}" ]; then
      summary="E2E: FLAKY $count after retrying ${names:-the run}"
    else
      summary="E2E: FLAKY retried tests passed $count after retrying $subset (the first attempt printed no total)"
    fi
    # Quarantine: the run passes when the first attempt's main thread never got stuck, its total is known, and
    # every failure belongs to a test with an unexpired entry. A failure that is no test's (a C line) belongs to the
    # test it is named after (the test, or the longest test name it continues with a dot), like the quit check;
    # the runner's own checks and a timeout between tests belong to none (printed with a leading "!").
    if [ -n "$quarantine" ] && [ -n "$total" ] && ! grep -q '^E2E: TIMEOUT ' "$run/report.txt" 2>/dev/null; then
      owners=$(printf '%s\n' "$analysis" | R="$run/report.txt" awk -F "$us" '
        BEGIN { report = ENVIRON["R"]; while ((getline l < report) > 0) if (split(l, f, " ") >= 3 && f[1] == "RESULT") tests[f[2]] }
        $1 == "T" { print $2; next }
        $1 == "C" {
          c = $2; owner = ""
          if (c != "chromium.errors" && c != "e2e.isolation" && c != "TIMEOUT")
            for (t in tests) if ((c == t || index(c, t ".") == 1) && length(t) > length(owner)) owner = t
          print (owner == "" ? "!" c : owner)
        }' | awk '!seen[$0]++')
      held=$(printf '%s\n' "$owners" | Q="$quarantine" awk -F "$us" '
        BEGIN { n = split(ENVIRON["Q"], lines, "\n"); for (i = 1; i <= n; i++) { split(lines[i], e, FS); entry[e[1]] = lines[i] } }
        $0 == "" { next }
        !($0 in entry) { bad = 1; exit }
        { out = out entry[$0] "\n" }
        END { if (!bad && out != "") printf "%s", out; exit bad }') || held=""
      if [ -n "$held" ]; then
        quarantined=$held
        printf '%s\n' "$held" | while IFS="$us" read -r name date reason; do
          echo "QUARANTINED $name (expires $date): $reason"
        done | if [ "$quiet" = 1 ]; then cat >> "$run/report.txt"; else tee -a "$run/report.txt"; fi
        status=pass
        summary="E2E: PASS $total/$total; quarantined flaky tests passed on the retry: $(printf '%s\n' "$held" | awk -F "$us" '{ print $1 }' | paste -sd, - | sed 's/,/, /g')"
      fi
    fi
  elif [ "$status" = fail ] || [ "$status" = timeout ]; then
    # Failed again: report the first attempt, whose run covered the whole selection, and name the retry's outcome
    # when it failed the other way.
    [ "$status" = "$first_status" ] || first_summary="$first_summary (retry: ${summary#E2E: })"
    status=$first_status summary=$first_summary
  elif [ "$status" = error ]; then
    # The retry could not start: that says nothing about the tests, so the first attempt's outcome stands.
    say "the retry could not start (${summary#E2E: ERROR }); reporting the first attempt"
    status=$first_status summary=$first_summary
  else
    # The retry crashed: report that, with its log.
    log_dir="$run/retry"
  fi
fi
load_end=$(load)
# Every run names the expired entries, so they get removed or renewed.
if [ -n "$expired" ] && [ -z "$shard_dir" ]; then
  expired_lines | if [ "$quiet" = 1 ]; then cat >> "$run/report.txt"; else tee -a "$run/report.txt"; fi
fi

case $status in
  pass) code=0 ;; fail) code=1 ;; timeout) code=2 ;; flaky) code=3 ;; crash) code=4 ;; *) code=64 ;;
esac

# results.json: the outcome, each attempt's checks and per-test lines, and what the run ran on. A results.json the
# app itself wrote stays in app-results.json, unread: nothing checks that it is JSON, so it is not embedded.
attempt_json() {
  local dir=$1 status=$2 code=$3 sig=$4 secs=$5 line=$6
  printf '{"folder":%s,"status":%s,"appExitCode":%s,"signal":%s,"seconds":%s,"summary":%s,' \
    "$(json "$dir")" "$(json "$status")" "$code" "${sig:-null}" "$secs" "$(json "$line")"
  printf '"checks":['
  awk -v us="$us" '/^(PASS|FAIL) / { n = $2; sub(/:$/, "", n); d = $0; sub(/^[A-Z]+ [^ ]*:? ?/, "", d); print tolower($1) us n us d }' \
    "$dir/report.txt" 2>/dev/null | { sep=""; while IFS="$us" read -r s n d; do
      printf '%s{"name":%s,"status":%s,"detail":%s}' "$sep" "$(json "$n")" "$(json "$s")" "$(json "$d")"; sep=,; done; }
  printf '],"tests":['
  # RESULT <test> <status> seconds=<s> checks=<p>/<n> [quit=pending], and NOT RUN <test>.
  awk -v us="$us" '/^RESULT / { s = ""; c = ""; for (i = 4; i <= NF; i++) { if ($i ~ /^seconds=/) s = substr($i, 9); if ($i ~ /^checks=/) c = substr($i, 8) }
      d = $0; sub(/^RESULT [^ ]+ [^ ]+ ?/, "", d); print $2 us $3 us s us c us d }
    /^NOT RUN / { print $3 us "not run" us us us }' \
    "$dir/report.txt" 2>/dev/null | { sep=""; while IFS="$us" read -r n s secs c d; do
      printf '%s{"name":%s,"status":%s,"seconds":%s,"checks":%s,"detail":%s}' "$sep" "$(json "$n")" "$(json "$s")" \
        "$([[ $secs =~ ^[0-9]+(\.[0-9]+)?$ ]] && echo "$secs" || echo null)" "$(json "$c")" "$(json "$d")"; sep=,; done; }
  printf ']}'
}
{
  printf '{"status":%s,"exitCode":%s,"summary":%s,"selection":%s,"run":%s,%s,' \
    "$(json "$status")" "$code" "$(json "$summary")" "$(json "$selection")" "$(json "$run")" "$(commit_json)"
  printf '"load":{"start":%s,"end":%s,"cpus":%s},"orphansKilled":%s,"flaky":[' \
    "$load_start" "$load_end" "$(sysctl -n hw.ncpu)" "$((orphans_killed + shard_orphans))"
  printf '%s\n' "$flaky" | awk -F "$us" '{ print $1 }' | { sep=""; while IFS= read -r n; do [ -n "$n" ] && printf '%s%s' "$sep" "$(json "$n")" && sep=,; done; }
  printf '],"quarantined":['
  printf '%s\n' "$quarantined" | { sep=""; while IFS="$us" read -r n d r; do
    [ -n "$n" ] && printf '%s{"name":%s,"expires":%s,"reason":%s}' "$sep" "$(json "$n")" "$(json "$d")" "$(json "$r")" && sep=,; done; }
  printf '],"quarantineExpired":['
  printf '%s\n' "$expired" | awk -F "$us" '{ print $1 }' | { sep=""; while IFS= read -r n; do [ -n "$n" ] && printf '%s%s' "$sep" "$(json "$n")" && sep=,; done; }
  printf '],"attempts":['
  sep=""
  for a in "${attempts[@]}"; do
    IFS="|" read -r dir s c sig secs line <<< "$a"
    printf '%s' "$sep"; attempt_json "$dir" "$s" "$c" "$sig" "$secs" "$line"; sep=,
  done
  printf ']'
  # A sharded run: each shard's folder, tests, planned seconds, status, exit code, seconds and summary.
  [ -z "$shards_json" ] || printf ',"shards":%s' "$shards_json"
  printf '}\n'
} > "$run/results.json"

# The ledger: one line per test and run-wide check of this run, appended under a lock in one write, so worktrees
# running at once never interleave a line, with a header line when the file is new. Nothing here may change the
# run's outcome: a failure warns on stderr and goes on.
ledger_write() {
  local file=${BOW_E2E_LEDGER:-$HOME/Library/Caches/bowbrowser/e2e-ledger.tsv}
  # A shard's own run is written by the run that planned it, from the merged results.json.
  [ -z "$shard_dir" ] || return 0
  local outcomes branch tree diff when shard_map
  outcomes=$("$repo/scripts/e2e-flakes.sh" --emit "$run/results.json") || return 1
  [ -n "$outcomes" ] || return 0
  branch=$(git -C "$repo" branch --show-current 2>/dev/null)
  tree=$(git -C "$repo" rev-parse 'HEAD^{tree}' 2>/dev/null)
  diff=$(git -C "$repo" diff HEAD 2>/dev/null | shasum | cut -c1-8)
  [ -z "$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)" ] || tree="${tree:-unknown}-$diff"
  when=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # The shard of each planned test (a run-wide check names every shard's result, so it has none).
  shard_map=$(printf '%s\n' "$shard_plan" | awk -F "$us" '$1 ~ /^[0-9]+$/ && NF == 3 { print $2 "\t" $1 }')
  mkdir -p "$(dirname "$file")" || return 1
  printf '%s\n' "$outcomes" | WHEN=$when BRANCH=${branch:-detached} TREE=${tree:-unknown} LOAD=$load_start RUN=$run_name \
    SHARDS=$shard_map LEDGER=$file perl -e '
      use Fcntl qw(:flock SEEK_END);
      my %shard = map { split /\t/ } grep { length } split /\n/, $ENV{SHARDS};
      my $out = "";
      while (my $l = <STDIN>) {
        chomp $l;
        my ($test, $outcome) = split /\t/, $l;
        $out .= join("\t", $ENV{WHEN}, $test, $outcome, @ENV{qw(BRANCH TREE LOAD)},$shard{$test} // "-", $ENV{RUN}) . "\n";
      }
      open(my $fh, ">>", $ENV{LEDGER}) or die "cannot open $ENV{LEDGER}: $!\n";
      flock($fh, LOCK_EX) or die "cannot lock $ENV{LEDGER}: $!\n";
      seek($fh, 0, SEEK_END);
      $out = join("\t", qw(date test outcome branch tree load shard run)) . "\n" . $out unless tell($fh);
      syswrite($fh, $out) == length $out or die "short write to $ENV{LEDGER}\n";
      close($fh) or die "cannot write $ENV{LEDGER}: $!\n";
    '
}
ledger_write >&2 || echo "e2e: warning: could not write the e2e ledger (${BOW_E2E_LEDGER:-~/Library/Caches/bowbrowser/e2e-ledger.tsv}); the result stands" >&2

# A shard's own output, shown above, already ended with the end of its chromium.log; a retry's did not.
if [ "$quiet" = 0 ] && { [ "$status" = timeout ] || [ "$status" = crash ] || [ "$status" = error ]; } && [ -f "$log_dir/chromium.log" ] \
  && { [ "$sharded" = 0 ] || [ "$log_dir" = "$run/retry" ]; }; then
  say "the end of $log_dir/chromium.log:"
  tail -n 40 "$log_dir/chromium.log"
fi
if [ "$quiet" = 1 ]; then
  # failing_lines <folder> <prefix>: the FAIL, FLAKY, QUARANTINED, QUARANTINE EXPIRED, TIMEOUT and NOT RUN lines and
  # the RESULT lines of failing tests in the folder's report.txt.
  failing_lines() {
    awk -v p="$2" '/^(FAIL|FLAKY|QUARANTINED) |^QUARANTINE EXPIRED |^E2E: TIMEOUT |^NOT RUN |^RESULT [^ ]+ (fail|timeout)( |$)/ { print p $0 }' \
      "$1/report.txt" 2>/dev/null
  }
  failing_lines "$run" ""
  if [ -d "$run/retry" ] && ! grep -q '^E2E: PASS ' "$run/retry/report.txt" 2>/dev/null; then failing_lines "$run/retry" "retry: "; fi
  # The app echoes Chromium's unexpected ERROR and FATAL lines to stderr; they matter only when a check failed.
  if [ "$status" != pass ] || [ -n "$quarantined" ]; then
    cat "$run/$output" "$run"/.shard-*.out "$run/retry/$output" 2>/dev/null | grep -E '(\[|:)(ERROR|FATAL):[^] ]+\] '
  fi
  # A run that could not start says why: what the app or the build lock printed (a shard's, without its own
  # folder and summary lines).
  [ "$status" != error ] || grep -v '^[[:space:]]*$' "$run/$output" 2>/dev/null
  [ "$status" != error ] || [ "$sharded" = 0 ] \
    || cat "$run"/.shard-*.out 2>/dev/null | grep -v -e '^[[:space:]]*$' -e '^E2E: ' -e '^e2e: everything is in '
  rm -f "$run/$output" "$run/retry/$output" "$run"/.shard-*.out
  if [ "$sharded" = 1 ]; then tell "everything is in $run (report.txt, results.json; each shard's chromium.log in shard-<k>)"
  else tell "everything is in $run (report.txt, results.json, chromium.log)"; fi
else
  rm -f "$run"/.shard-*.out
  if [ -n "$shard_dir" ]; then say "$run, results in results.json"
  else say "$run (build/e2e/latest), results in results.json"; fi
fi
echo "$summary"
exit "$code"
