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
#
# Each run writes build/e2e/<time>-<pid>/: the app's report.txt, chromium.log and final.png, plus results.json
# from this script. A retry runs in <run>/retry/: the failed, timed out and not run tests when RESULT lines name
# them, else the whole selection.
#
# The last line printed is always the summary:
#   E2E: PASS n/n               exit 0
#   E2E: FAIL passed/n          exit 1  a check failed (and failed again on the retry)
#   E2E: TIMEOUT <step>         exit 2  the app's main thread was stuck (and again on the retry)
#   E2E: FLAKY n/n retried ...  exit 3  failed or timed out, then passed on the retry: not a pass, report it
#   E2E: CRASH exit=<code> ...  exit 4  the app ended without a summary line (a crash, Chromium's own watchdog),
#                                       on the first run or on the retry
#   E2E: ERROR ...              exit 64 the app could not start the run (an unknown selection, no build)
set -u

app=${1:-}
# The selection comes as the second argument or in E2E (make exports it, so no shell quoting gets in the way).
selection=${2:-${E2E:-all}}
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
bundle=$(basename "$app")

# The real path: the runner hands Chromium the run folder's real path, and the sweep matches it.
mkdir -p "$root" && root=$(cd "$root" && pwd -P)
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
# process of the app bundle whose command line names the folder belongs to this run (a `tail -f` of its log does
# not). Ends them: TERM, then KILL after 2 seconds.
orphans_killed=0
sweep() {
  local pids pid i n=0
  # The folder followed by "/" (helpers) or by a space or the end of the line (the app's own --e2e-out=<folder>,
  # in case the app outlived its build lock), so a run never matches a sibling whose name starts with its own.
  pids=$(ps -axo pid=,command= | D="$1" B="$bundle/Contents/" awk -v me=$$ '
    { line = $0 " " }
    index(line, ENVIRON["B"]) && (index(line, ENVIRON["D"] "/") || index(line, "=" ENVIRON["D"] " ")) && $1 != me { print $1 }')
  [ -n "$pids" ] || return 0
  for pid in $pids; do kill -TERM "$pid" 2>/dev/null && n=$((n + 1)); done
  orphans_killed=$((orphans_killed + n))
  for i in 1 2 3 4 5 6 7 8 9 10; do
    pids=$(for pid in $pids; do kill -0 "$pid" 2>/dev/null && echo "$pid"; done)
    [ -n "$pids" ] || break
    sleep 0.2
  done
  for pid in $pids; do kill -KILL "$pid" 2>/dev/null; done
  say "ended $n helper processes the app left running"
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
  # A stuck main thread may print NOT RUN lines and more after its TIMEOUT line; the TIMEOUT line is the summary.
  if [ "$app_code" = 2 ] && grep -q '^E2E: TIMEOUT ' "$dir/report.txt" 2>/dev/null; then
    summary=$(grep '^E2E: TIMEOUT ' "$dir/report.txt" | tail -n 1)
  fi
  case "$app_code:$summary" in
    "0:E2E: PASS "*) status=pass ;;
    "1:E2E: FAIL "*) status=fail ;;
    "2:E2E: TIMEOUT "*) status=timeout ;;
    "64:"*) status=error summary="E2E: ERROR the app could not start the run (exit 64): an unknown selection or switch" ;;
    *)
      status=crash
      local why="E2E: CRASH exit=$app_code${signal:+ signal=$signal}"
      if [ -n "$summary" ]; then why="$why after its summary line ($summary)"; else why="$why without a summary line"; fi
      summary=$why
      echo "$summary" >> "$dir/report.txt"
      ;;
  esac
}

# What failed in folder $1, as "name<TAB>reason" lines: the tests whose RESULT line says fail or timeout and the
# test a stuck main thread stopped in; when no test is named that way, the failed checks (chromium.errors, or a
# runner without RESULT lines).
failures() {
  awk '
    /^RESULT [^ ]+ (fail|timeout)( |$)/ { r = $0; sub(/^RESULT [^ ]+ /, "", r); add($2, r) }
    /^E2E: TIMEOUT / { s = $0; sub(/^E2E: TIMEOUT /, "", s); n = s; sub(/:.*/, "", n); add(n, "TIMEOUT " s) }
    /^FAIL / { n = $2; sub(/:$/, "", n); r = $0; sub(/^FAIL [^ ]*:? ?/, "", r); checks = checks n "\t" r "\n" }
    function add(n, r) { if (!(n in seen)) { seen[n]; tests = tests n "\t" r "\n" } }
    END { printf "%s", (tests != "" ? tests : checks) }
  ' "$1/report.txt" 2>/dev/null
}

# The tests a retry of folder $1 reruns, as a comma list: those that failed, timed out or never ran, when RESULT
# lines name them; empty (rerun the whole selection) when the failure is not a test's (a failed chromium.errors or
# app.quit check, whose RESULT line said pass) or the runner prints no RESULT lines.
retry_tests() {
  awk '
    /^RESULT [^ ]+ (fail|timeout)( |$)/ { add($2) }
    /^E2E: TIMEOUT / { n = $0; sub(/^E2E: TIMEOUT /, "", n); sub(/:.*/, "", n); add(n) }
    /^NOT RUN / { add($3) }
    /^RESULT / { results = 1 }
    function add(n) { if (!(n in seen)) { seen[n]; list = list (list == "" ? "" : ",") n } }
    END { if (results) print list }
  ' "$1/report.txt" 2>/dev/null
}

args=("--e2e=$selection")
load_start=$(load)
attempt "$run" "${args[@]}"
first_status=$status first_summary=$summary
attempts=("$run|$status|$app_code|$signal|$seconds|$summary")
flaky=""
log_dir=$run

if [ "$retry" = 1 ] && { [ "$status" = fail ] || [ "$status" = timeout ]; }; then
  failed=$(failures "$run")
  names=$(echo "$failed" | cut -f1 | grep -v '^$' | paste -sd, -)
  retry_args=("${args[@]}")
  subset=$(retry_tests "$run")
  [ -z "$subset" ] || retry_args=("--e2e=$subset")
  say "$first_summary; retrying once in a fresh app"
  attempt "$run/retry" "${retry_args[@]}"
  attempts+=("$run/retry|$status|$app_code|$signal|$seconds|$summary")
  if [ "$status" = pass ]; then
    flaky=$failed
    echo "$failed" | while IFS="	" read -r name reason; do
      [ -n "$name" ] && echo "FLAKY $name: failed then passed ($reason)"
    done | tee -a "$run/report.txt"
    status=flaky
    summary="E2E: FLAKY ${summary#E2E: PASS } after retrying ${names:-the run}"
  elif [ "$status" = fail ] || [ "$status" = timeout ]; then
    # Failed again: report the first attempt, whose run covered the whole selection.
    status=$first_status summary=$first_summary
  else
    # The retry crashed or could not start: report that, with its log.
    log_dir="$run/retry"
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
  # RESULT <test> <status> seconds=<s> checks=<p>/<n> [quit=pending], and NOT RUN <test>.
  awk '/^RESULT / { s = ""; c = ""; for (i = 4; i <= NF; i++) { if ($i ~ /^seconds=/) s = substr($i, 9); if ($i ~ /^checks=/) c = substr($i, 8) }
      d = $0; sub(/^RESULT [^ ]+ [^ ]+ ?/, "", d); print $2 "\t" $3 "\t" s "\t" c "\t" d }
    /^NOT RUN / { print $3 "\tnot run\t\t\t" }' \
    "$dir/report.txt" 2>/dev/null | { sep=""; while IFS="	" read -r n s secs c d; do
      printf '%s{"name":%s,"status":%s,"seconds":%s,"checks":%s,"detail":%s}' "$sep" "$(json "$n")" "$(json "$s")" \
        "$([[ $secs =~ ^[0-9]+(\.[0-9]+)?$ ]] && echo "$secs" || echo null)" "$(json "$c")" "$(json "$d")"; sep=,; done; }
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

if { [ "$status" = timeout ] || [ "$status" = crash ] || [ "$status" = error ]; } && [ -f "$log_dir/chromium.log" ]; then
  say "the end of $log_dir/chromium.log:"
  tail -n 40 "$log_dir/chromium.log"
fi
say "$run (build/e2e/latest), results in results.json"
echo "$summary"
exit "$code"
