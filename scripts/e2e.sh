#!/bin/bash
# Runs the e2e tests in a built Bow.app and always finishes the story: a final summary line, results.json, distinct
# exit codes, no helper processes left behind, and build/e2e/latest pointing at the run.
#
#   scripts/e2e.sh <path to Bow.app> [selection]
#
# selection: all (default), one test name (tabs.switch), or an area, glob, comma list or tag (tabs, 'tabs.*',
#   smoke). Names go to the app as --e2e=<name>; anything else as --e2e=all --only=<selection>, which needs runner
#   support (the run ends with exit 64 when the app ignores it).
# E2E_RETRY  1 (default) reruns a failed or timed out run once in a fresh app; 0 turns the retry off.
# E2E_KEEP   run folders to keep in build/e2e (default 20); older ones are deleted.
#
# Each run writes build/e2e/<time>-<pid>/: the app's report.txt, chromium.log and final.png, plus results.json
# from this script. A retry runs in <run>/retry/.
#
# The last line printed is always the summary:
#   E2E: PASS n/n               exit 0
#   E2E: FAIL passed/n          exit 1  a check failed (and failed again on the retry)
#   E2E: TIMEOUT <step>         exit 2  a step timed out (and again on the retry)
#   E2E: FLAKY n/n retried ...  exit 3  failed or timed out, then passed on the retry: not a pass, report it
#   E2E: CRASH exit=<code> ...  exit 4  the app ended without a summary line (a crash, Chromium's own watchdog)
#   E2E: ERROR ...              exit 64 the app could not start the run (an unknown test, no build)
set -u

app=${1:-}
selection=${2:-all}
retry=${E2E_RETRY:-1}
keep=${E2E_KEEP:-20}

repo=$(cd "$(dirname "$0")/.." && pwd -P)
root=${BOW_E2E_ROOT:-$repo/build/e2e}
marker=.bow-e2e-run
binary="$app/Contents/MacOS/Bow"

say() { echo "e2e: $*"; }

if [ -z "$app" ] || [ ! -x "$binary" ]; then
  say "no built app at ${app:-<none>}; run make e2e (or make build) first"
  echo "E2E: ERROR no build"
  exit 64
fi
case $keep in '' | *[!0-9]*) keep=20 ;; esac

run_name="$(date +%Y%m%d-%H%M%S)-$$"
run="$root/$run_name"
mkdir -p "$run"
echo "Made by a Bow e2e run." > "$run/$marker"
ln -sfn "$run_name" "$root/latest"
say "$run"

# Keep the newest $keep run folders (only folders an e2e run made), so build/e2e does not grow without bound.
prune() {
  local n=0 entry
  for entry in $(cd "$root" && ls -1t); do
    [ "$entry" != latest ] && [ -f "$root/$entry/$marker" ] || continue
    n=$((n + 1))
    if [ "$n" -gt "$keep" ] && [ "$entry" != "$run_name" ]; then rm -rf "${root:?}/$entry"; fi
  done
}
prune

# Every helper Chromium starts carries the run folder in its arguments (its user data and cache paths), so a
# process whose command line names the folder belongs to this run. Ends them: TERM, then KILL after 2 seconds.
orphans_killed=0
sweep() {
  local pids pid i
  # The folder followed by "/" (helpers) or by a space or the end of the line (the app's own --e2e-out=<folder>,
  # in case the app outlived its build lock), so a run never matches a sibling whose name starts with its own.
  pids=$(ps -axo pid=,command= | D="$1" awk -v me=$$ '
    { line = $0 " " }
    (index(line, ENVIRON["D"] "/") || index(line, "=" ENVIRON["D"] " ")) && $1 != me { print $1 }')
  [ -n "$pids" ] || return 0
  for pid in $pids; do kill -TERM "$pid" 2>/dev/null && orphans_killed=$((orphans_killed + 1)); done
  for i in 1 2 3 4 5 6 7 8 9 10; do
    pids=$(for pid in $pids; do kill -0 "$pid" 2>/dev/null && echo "$pid"; done)
    [ -n "$pids" ] || break
    sleep 0.2
  done
  for pid in $pids; do kill -KILL "$pid" 2>/dev/null; done
  say "ended $orphans_killed helper processes the app left running"
}

current=""
on_signal() {
  trap '' INT TERM HUP
  [ -z "$current" ] || sweep "$current"
  echo "E2E: ERROR interrupted"
  exit 130
}
trap on_signal INT TERM HUP

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
load() { sysctl -n vm.loadavg | awk '{ print $2 }'; }

# Runs the app once into folder $1 with the remaining arguments. Sets: status (pass, fail, timeout, crash, error),
# summary (its E2E line), app_code, signal, seconds.
attempt() {
  local dir=$1 start
  shift
  mkdir -p "$dir"
  [ -f "$dir/$marker" ] || echo "Made by a Bow e2e run." > "$dir/$marker"
  current=$dir
  start=$(now)
  "$repo/scripts/build-lock.sh" --pool e2e "$binary" "$@" --e2e-out="$dir"
  app_code=$?
  seconds=$(perl -e 'printf "%.2f", $ARGV[1] - $ARGV[0]' "$start" "$(now)")
  sweep "$dir"
  current=""
  # results.json in a run folder is this script's; keep one the app wrote under another name.
  [ ! -f "$dir/results.json" ] || mv "$dir/results.json" "$dir/app-results.json"
  signal=""
  [ "$app_code" -gt 128 ] && signal=$((app_code - 128))
  summary=$(grep '^E2E: ' "$dir/report.txt" 2>/dev/null | tail -n 1)
  case "$app_code:$summary" in
    "0:E2E: PASS "*) status=pass ;;
    "1:E2E: FAIL "*) status=fail ;;
    "2:E2E: TIMEOUT "*) status=timeout ;;
    "64:") status=error summary="E2E: ERROR the app could not start the run (exit 64)" ;;
    *)
      status=crash
      local why="E2E: CRASH exit=$app_code${signal:+ signal=$signal}"
      if [ -n "$summary" ]; then why="$why after its summary line ($summary)"; else why="$why without a summary line"; fi
      summary=$why
      echo "$summary" >> "$dir/report.txt"
      ;;
  esac
  # --only needs runner support: a run that ignored it ran everything and printed no per-test lines.
  if [ "$status" != error ] && [ "$status" != crash ] && [ "$only" = yes ] && ! grep -q '^TEST ' "$dir/report.txt"; then
    status=error summary="E2E: ERROR this build's runner does not support --only=$selection yet; use all or one test name"
  fi
}

# Tests that failed in folder $1: from per-test lines (TEST FAIL <name>: ...) when the runner prints them, else the
# names of failed checks. Prints "name<TAB>reason" lines.
failures() {
  if grep -q '^TEST ' "$1/report.txt" 2>/dev/null; then
    awk '/^TEST FAIL / { name = $3; sub(/:$/, "", name); reason = $0; sub(/^TEST FAIL [^ ]*:? ?/, "", reason); print name "\t" reason }' "$1/report.txt"
  else
    awk '/^FAIL / { name = $2; sub(/:$/, "", name); reason = $0; sub(/^FAIL [^ ]*:? ?/, "", reason); print name "\t" reason }
      /^E2E: TIMEOUT / { step = $0; sub(/^E2E: TIMEOUT /, "", step); name = step; sub(/:.*/, "", name); print name "\tTIMEOUT " step }' "$1/report.txt" 2>/dev/null
  fi
}

# Selection: names the runner already takes as --e2e=<name>; anything else through --only.
only=no
if [ "$selection" = all ]; then
  args=("--e2e=all")
elif [[ $selection =~ ^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+$ ]]; then
  args=("--e2e=$selection")
else
  only=yes
  args=("--e2e=all" "--only=$selection")
fi

load_start=$(load)
attempt "$run" "${args[@]}"
first_status=$status first_summary=$summary
attempts=("$run|$status|$app_code|$signal|$seconds|$summary")
flaky=""

if [ "$retry" = 1 ] && { [ "$status" = fail ] || [ "$status" = timeout ]; }; then
  failed=$(failures "$run")
  retry_args=("${args[@]}")
  # With per-test lines, rerun only the tests that failed (a timeout reruns the whole selection, since the tests
  # after the stuck one never ran).
  if [ "$status" = fail ] && grep -q '^TEST ' "$run/report.txt"; then
    only=yes
    retry_args=("--e2e=all" "--only=$(echo "$failed" | cut -f1 | paste -sd, -)")
  fi
  say "$first_summary; retrying once in a fresh app"
  attempt "$run/retry" "${retry_args[@]}"
  attempts+=("$run/retry|$status|$app_code|$signal|$seconds|$summary")
  if [ "$status" = pass ]; then
    flaky=$failed
    echo "$failed" | while IFS="	" read -r name reason; do
      [ -n "$name" ] && echo "FLAKY $name: failed then passed ($reason)"
    done | tee -a "$run/report.txt"
    status=flaky
    summary="E2E: FLAKY ${summary#E2E: PASS } after retrying $(echo "$failed" | cut -f1 | paste -sd, -)"
  else
    status=$first_status summary=$first_summary
  fi
fi
load_end=$(load)

case $status in
  pass) code=0 ;; fail) code=1 ;; timeout) code=2 ;; flaky) code=3 ;; crash) code=4 ;; *) code=64 ;;
esac

# results.json: the outcome, each attempt's checks and per-test lines, and what the run ran on. A results.json the
# app itself wrote is kept as app-results.json and embedded under "app".
json() { printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037')"; }
attempt_json() {
  local dir=$1 status=$2 code=$3 sig=$4 secs=$5 line=$6 app_json=null
  [ -s "$dir/app-results.json" ] && app_json=$(cat "$dir/app-results.json")
  printf '{"folder":%s,"status":%s,"appExitCode":%s,"signal":%s,"seconds":%s,"summary":%s,' \
    "$(json "$dir")" "$(json "$status")" "$code" "${sig:-null}" "$secs" "$(json "$line")"
  printf '"checks":['
  awk '/^(PASS|FAIL) / { n = $2; sub(/:$/, "", n); d = $0; sub(/^[A-Z]+ [^ ]*:? ?/, "", d); print tolower($1) "\t" n "\t" d }' \
    "$dir/report.txt" 2>/dev/null | { sep=""; while IFS="	" read -r s n d; do
      printf '%s{"name":%s,"status":%s,"detail":%s}' "$sep" "$(json "$n")" "$(json "$s")" "$(json "$d")"; sep=,; done; }
  printf '],"tests":['
  awk '/^TEST (PASS|FAIL) / { n = $3; sub(/:$/, "", n); d = $0; sub(/^TEST [A-Z]+ [^ ]*:? ?/, "", d); print tolower($2) "\t" n "\t" d }' \
    "$dir/report.txt" 2>/dev/null | { sep=""; while IFS="	" read -r s n d; do
      printf '%s{"name":%s,"status":%s,"detail":%s}' "$sep" "$(json "$n")" "$(json "$s")" "$(json "$d")"; sep=,; done; }
  printf '],"app":%s}' "$app_json"
}
{
  commit=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null)
  dirty=false
  [ -z "$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)" ] || dirty=true
  printf '{"status":%s,"exitCode":%s,"summary":%s,"selection":%s,"run":%s,"commit":%s,"dirty":%s,' \
    "$(json "$status")" "$code" "$(json "$summary")" "$(json "$selection")" "$(json "$run")" "$(json "$commit")" "$dirty"
  printf '"load":{"start":%s,"end":%s,"cpus":%s},"orphansKilled":%s,"flaky":[' \
    "$load_start" "$load_end" "$(sysctl -n hw.ncpu)" "$orphans_killed"
  echo "$flaky" | cut -f1 | { sep=""; while read -r n; do [ -n "$n" ] && printf '%s%s' "$sep" "$(json "$n")" && sep=,; done; }
  printf '],"attempts":['
  sep=""
  for a in "${attempts[@]}"; do
    IFS="|" read -r dir s c sig secs line <<< "$a"
    printf '%s' "$sep"; attempt_json "$dir" "$s" "$c" "$sig" "$secs" "$line"; sep=,
  done
  printf ']}\n'
} > "$run/results.json"

if [ "$code" -ne 0 ] && [ "$status" != fail ] && [ -f "$run/chromium.log" ]; then
  say "the end of $run/chromium.log:"
  tail -n 40 "$run/chromium.log"
fi
say "$run (build/e2e/latest), results in results.json"
echo "$summary"
exit "$code"
