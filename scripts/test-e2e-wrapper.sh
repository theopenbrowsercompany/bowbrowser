#!/bin/bash
# Tests scripts/e2e.sh with a fake Bow.app (a shell script) in throwaway folders: the summary line, exit codes,
# results.json, the retry and FLAKY, crash classification, the helper sweep, --only and build/e2e/latest, repeats
# (E2E_REPEAT), short output (E2E_QUIET, CLAUDECODE), the flake count (scripts/e2e-flakes.sh), the quarantine list
# and shards (E2E_SHARDS: planning, merging and every outcome against a single run's), signals, the build lock
# guards, the Makefile hand-off, package-cef.sh and the ledger. Launches no real app.
#
#   scripts/test-e2e-wrapper.sh [group ...]
#
# The checks are split into groups that run side by side, each in its own process with its own throwaway folder,
# fake app, run root, lock folder, ledger and quarantine list (and none of the E2E_* or FAKE_* settings of the
# caller's environment). Each group's output is printed whole, in the order below, when all have ended, then a
# "group <name> <seconds>s" line per group and the same final line as before ("e2e wrapper: all checks passed" or
# "e2e wrapper: some checks failed"). Name groups on the command line to run only those.
# The whole run takes 30 to 40 seconds (the slowest group, the shard plan, sets it; it took 150 to 165 seconds as one
# sequence). The checks are many runs of the wrapper, 1 to 2 seconds each, so the time is spread out, not one case.
set -u
self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
cd "$(dirname "$0")/.."

groups=(basic repeat quarantine shards shard-plan shard-outcomes shard-timeouts signals signals-shards signals-stuck locks make-package
  ledger ledger-stale threshold crash-reports)

if [ "${1:-}" != --group ]; then
  for g in "$@"; do
    case " ${groups[*]} " in *" $g "*) ;; *) echo "e2e wrapper: no group '$g' (groups: ${groups[*]})" >&2; exit 64 ;; esac
  done
  [ $# -gt 0 ] && groups=("$@")
  out=$(mktemp -d)
  # Job control gives each group its own process group, so stopping this script stops each group's whole tree.
  set -m
  pids=()
  cleanup() {
    local p
    for p in ${pids[@]+"${pids[@]}"}; do kill -TERM -- "-$p" 2> /dev/null; done
    wait 2> /dev/null
    rm -rf "$out"
  }
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  start=$SECONDS
  for g in "${groups[@]}"; do
    (
      s=$SECONDS
      "$self" --group "$g" > "$out/$g.log" 2>&1 < /dev/null
      echo $? > "$out/$g.status"
      echo $((SECONDS - s)) > "$out/$g.secs"
    ) &
    pids+=($!)
  done
  wait
  pids=()
  failed=0
  for g in "${groups[@]}"; do
    cat "$out/$g.log"
    status=$(cat "$out/$g.status" 2> /dev/null || echo "?")
    if [ "$status" != 0 ]; then
      failed=1
      # A group that ends early (a syntax error, an unset variable) shows here even when no FAIL line says so.
      grep -q '^FAIL ' "$out/$g.log" || echo "FAIL group $g ended with exit $status before its checks were done"
    fi
  done
  for g in "${groups[@]}"; do echo "e2e wrapper: group $g $(cat "$out/$g.secs" 2> /dev/null || echo "?")s"; done
  echo "e2e wrapper: all groups in $((SECONDS - start))s"
  [ "$failed" = 0 ] && echo "e2e wrapper: all checks passed" || echo "e2e wrapper: some checks failed"
  exit "$failed"
fi
group=${2:?group name}

# The real path, as scripts/e2e.sh sees it, so the orphan check can match this run's folder exactly.
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'chmod -R u+rwX "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
export BOW_E2E_ROOT="$tmp/runs" BOW_LOCK_DIR="$tmp/lock"
# A person's full output unless a check asks for short output (an agent's shell has CLAUDECODE=1).
export E2E_QUIET=0
unset E2E_REPEAT
# The checks' own quarantine list, empty until a check writes it, so the checked in one changes no outcome here.
quarantine="$tmp/quarantine.txt"
export E2E_QUARANTINE="$quarantine"
# The shared flake ledger, a temp file here so no check touches the real one.
export BOW_E2E_LEDGER="$tmp/ledger.tsv"
# Nothing of the caller's environment reaches a check: each setting the wrapper or the fake app reads is cleared, and
# the build lock's timings go to the throwaway folder, not the shared file.
unset E2E_RETRY E2E_KEEP E2E_SHARDS E2E_SHARD_DIR BOW_E2E_SLOTS BOW_BUILD_SLOTS BOW_BUILD_JOBS
for v in $(env | grep -o '^FAKE_[A-Z_]*'); do unset "$v"; done
export BOW_TIMINGS_DIR="$tmp/timings"
trap 'exit 143' TERM
trap 'exit 130' INT
app="$tmp/Bow.app"
mkdir -p "$app/Contents/MacOS"
# The fake app reads FAKE_MODE and writes report.txt into its --e2e-out folder like the real runner.
cat > "$app/Contents/MacOS/Bow" <<'EOF'
#!/bin/bash
out="" sel=""
for a in "$@"; do
  case $a in --e2e-out=*) out=${a#--e2e-out=} ;; --e2e=*) sel=${a#--e2e=} ;; esac
done
# The list selection prints one TEST line per test and starts nothing, like the real runner; FAKE_NOLIST=1 plays a
# runner without it (exit 64).
if [ "$sel" = list ]; then
  [ "${FAKE_NOLIST:-0}" = 1 ] && exit 64
  [ "$FAKE_MODE" = listhang ] && { echo "listing"; exec sleep 60; }
  echo "TEST a.one area=a tags=- checks=a.one"
  echo "TEST a.two area=a tags=smoke,slow${FAKE_LISTTAG:+,$FAKE_LISTTAG} checks=a.two"
  echo "TEST a.three area=a tags=- checks=a.three"
  # FAKE_BYNAME=1 adds a self test that only its exact name selects (the app never runs it here).
  [ "${FAKE_BYNAME:-0}" = 1 ] && echo "TEST a.self area=a tags=smoke checks=a.self by-name-only"
  exit 0
fi
# FAKE_MODE shard: runs the tests its selection names (all or a.* is every test) like the real runner, a.three last
# as the quit test, with one e2e.isolation and chromium.errors check per app. On the first attempt only:
# FAKE_FAIL fails a test, FAKE_TIMEOUT (a comma list) gets the main thread stuck in a test, FAKE_CRASH crashes in
# one, FAKE_USAGE makes the app refuse a selection holding it, FAKE_CHROMIUM fails chromium.errors in the app that
# runs it, FAKE_HANG=1 starts a helper and never ends, and FAKE_BARRIER=N waits until N apps run at once (writing
# yes or no to together).
shardrun() {
  local tests=() ordered=() t i b first=1 n=0 p=0 quit=0 bad=0 secs
  local r="$out/report.txt"
  # Names and globs of names, as the app reads them; FAKE_GREEDY=1 runs every test whatever the selection.
  local parts=() q
  IFS=, read -ra parts <<< "$sel"
  for t in a.one a.two a.three; do
    for q in "${parts[@]}"; do
      if [ "$q" = all ] || [ "${FAKE_GREEDY:-0}" = 1 ] || [[ $t == $q ]]; then tests+=("$t"); break; fi
    done
  done
  case $out in */retry) first=0 ;; esac
  for t in "${tests[@]}"; do [ "$t" = a.three ] || ordered+=("$t"); done
  for t in "${tests[@]}"; do [ "$t" != a.three ] || ordered+=("$t"); done
  line() { echo "$1" | tee -a "$r"; }
  # FAKE_DUMP=1: every app leaves a Crashpad report of its own name in its folder.
  [ "${FAKE_DUMP:-0}" != 1 ] || { mkdir -p "$out/profile/pending"; echo dump > "$out/profile/pending/s$$.dmp"; }
  if [ "$first" = 1 ]; then
    for t in "${ordered[@]}"; do [ "$t" != "${FAKE_USAGE:-}" ] || { echo "bow: --e2e=$sel is not a test" >&2; exit 64; }; done
    if [ -n "${FAKE_BARRIER:-}" ]; then
      b="$(dirname "$out")/barrier"
      mkdir -p "$b" && : > "$b/$$"
      for i in $(seq 100); do [ "$(ls "$b" | wc -l)" -ge "$FAKE_BARRIER" ] && break; sleep 0.05; done
      if [ "$(ls "$b" | wc -l)" -ge "$FAKE_BARRIER" ]; then echo yes > "$out/together"; else echo no > "$out/together"; fi
    fi
    if [ "${FAKE_HANG:-0}" = 1 ]; then
      "$(dirname "$0")/../Frameworks/Helper" "$out/helper" > /dev/null 2>&1 < /dev/null &
      line "PASS ${ordered[0]}: ok"; echo yes > "$out/hanging"
      while :; do sleep 0.1; done
    fi
  fi
  for i in "${!ordered[@]}"; do
    t=${ordered[i]}
    if [ "$first" = 1 ] && [[ ,${FAKE_TIMEOUT:-}, == *",$t,"* ]]; then
      line "E2E: TIMEOUT $t: open window (main thread stuck)"
      for t in "${ordered[@]:i+1}"; do line "NOT RUN $t"; done
      exit 2
    fi
    [ "$first" = 0 ] || [ "$t" != "${FAKE_CRASH:-}" ] || kill -SEGV $$
    # FAKE_SKIP: a test the app leaves out without a word.
    [ "$first" = 0 ] || [ "$t" != "${FAKE_SKIP:-}" ] || continue
    case $t in a.one) secs=0.5 ;; a.two) secs=0.2 ;; *) secs=0.3 ;; esac
    if [ "$t" = a.three ]; then
      line "RESULT a.three pass seconds=$secs checks=0/0 quit=pending"; quit=1
    elif [ "$first" = 1 ] && [ "$t" = "${FAKE_FAIL:-}" ]; then
      line "FAIL $t: broken"; line "RESULT $t fail seconds=$secs checks=0/1"; n=$((n + 1)) bad=1
    else
      line "PASS $t: ok"; line "RESULT $t pass seconds=$secs checks=1/1"; n=$((n + 1)) p=$((p + 1))
    fi
    [ "$first" = 0 ] || [ "$t" != "${FAKE_CHROMIUM:-}" ] || bad=2
  done
  line "PASS e2e.isolation: closed-tests=${#ordered[@]} left-over=0"; n=$((n + 1)) p=$((p + 1))
  [ "$quit" = 0 ] || { line "PASS a.three: closed=0.1 limit 5"; n=$((n + 1)) p=$((p + 1)); }
  n=$((n + 1))
  if [ "$bad" = 2 ]; then
    echo "[1023/101010.000001:ERROR:fake.cc(12)] something broke" >&2
    line "FAIL chromium.errors: 1 unexpected"
  else
    line "PASS chromium.errors: unexpected=0"; p=$((p + 1))
  fi
  if [ "$p" = "$n" ]; then line "E2E: PASS $p/$n"; exit 0; fi
  line "E2E: FAIL $p/$n"; exit 1
}
# Records the selection each attempt got.
[ -z "$out" ] || echo "e2e=$sel" > "$out/args"
[ "$FAKE_MODE" != shard ] || shardrun
r="$out/report.txt"
# The repeat modes count runs in the run root (a file, which pruning leaves alone) and print to stdout and stderr
# like the real runner: result lines on stdout, and a plain line and Chromium's ERROR lines echoed on stderr.
n=0
case $FAKE_MODE in loud* | repeat*)
  n=$(($(cat "$out/../count" 2>/dev/null || echo 0) + 1)); echo "$n" > "$out/../count" ;;
esac
loudpass() {
  { echo "PASS a.one: ok"; echo "RESULT a.one pass seconds=0.1 checks=1/1"; echo "E2E: PASS 1/1"; } | tee "$r"
  echo "quit: seconds=0.5" >&2
  exit 0
}
loudfail() {
  { echo "FAIL a.one: broken"; echo "RESULT a.one fail seconds=0.1 checks=0/1"; echo "E2E: FAIL 0/1"; } | tee "$r"
  echo "quit: seconds=0.5" >&2
  echo "[1023/101010.000001:ERROR:fake.cc(12)] something broke" >&2
  exit 1
}
case $FAKE_MODE in
  loudpass) loudpass ;;
  loudfail) loudfail ;;
  # The second run of a repeat fails, or times out.
  repeatfail) [ "$n" = 2 ] && loudfail; loudpass ;;
  repeattimeout)
    [ "$n" = 2 ] && { echo "E2E: TIMEOUT a.one: open window" | tee "$r"; exit 2; }
    loudpass ;;
  repeatcrash) [ "$n" = 1 ] && kill -SEGV $$; loudpass ;;
  # The second run's quit test passes its RESULT line (quit=pending), then its quit check fails, as the real runner
  # reports the quit after the engine stops.
  repeatquit)
    [ "$n" = 2 ] || loudpass
    { echo "RESULT a.one pass seconds=0.1 checks=0/0 quit=pending"; echo "FAIL a.one: closing took too long"
      echo "PASS chromium.errors: unexpected=0"; echo "E2E: FAIL 1/2"; } | tee "$r"
    exit 1 ;;
  # The second run's quit test passes its RESULT line (quit=pending), then Chromium's teardown watchdog ends the app.
  repeatquitcrash)
    [ "$n" = 2 ] || loudpass
    echo "RESULT a.one pass seconds=0.1 checks=0/0 quit=pending" | tee "$r"
    echo "[1:2:ERROR:foo] Teardown watchdog expired; ending the process" > "$out/chromium.log"
    exit 2 ;;
  # The second run starts a helper and never ends.
  repeathang)
    [ "$n" = 2 ] || loudpass
    "$(dirname "$0")/../Frameworks/Helper" "$out/helper" > /dev/null 2>&1 < /dev/null &
    echo "PASS a.one: ok" > "$r"; echo yes > "$out/../hanging"
    while :; do sleep 0.1; done ;;
  pass) echo "PASS a.one: ok" > "$r"; echo "E2E: PASS 1/1" >> "$r"; exit 0 ;;
  # Crashpad keeps a report (pending, then the same name in completed) and a second one in another state, and
  # another sits already in crash-reports; a retry's own crash lands in its folder.
  crashdump)
    mkdir -p "$out/profile/pending" "$out/profile/completed" "$out/crash-reports"
    echo dump1 > "$out/profile/pending/aaa.dmp"; echo dump1 > "$out/profile/completed/aaa.dmp"
    echo dump2 > "$out/profile/completed/bbb.dmp"; echo dump3 > "$out/crash-reports/ccc.dmp"
    echo "not a report" > "$out/profile/pending/note.txt"; echo meta1 > "$out/profile/pending/aaa.meta"
    case $out in
      */retry) { echo "PASS a.one: ok"; echo "E2E: PASS 1/1"; } > "$r"; exit 0 ;;
      *) { echo "FAIL a.one: slow"; echo "E2E: FAIL 0/1"; } > "$r"; exit 1 ;;
    esac ;;
  fail) echo "FAIL a.one: broken" > "$r"; echo "E2E: FAIL 0/1" >> "$r"; exit 1 ;;
  timeout) echo "E2E: TIMEOUT a.one: open window" > "$r"; exit 2 ;;
  usage) echo "bow: --e2e=nope is not a test" >&2; exit 64 ;;
  crash) echo "PASS a.one: ok" > "$r"; kill -SEGV $$ ;;
  watchdog) echo "PASS a.one: ok" > "$r"; exit 2 ;;
  teardown)
    echo "PASS a.one: ok" > "$r"
    echo "[1:2:ERROR:foo] Teardown watchdog expired; ending the process" > "$out/chromium.log"
    exit 2 ;;
  teardownsummary)
    { echo "PASS a.one: ok"; echo "E2E: PASS 1/1"; } > "$r"
    echo "[1:2:ERROR:foo] Teardown watchdog expired; ending the process" > "$out/chromium.log"
    exit 2 ;;
  listhang) echo "E2E: TIMEOUT unknown.test: open window" > "$r"; exit 2 ;;
  flaky)
    case $out in
      */retry) echo "PASS a.one: ok" > "$r"; echo "E2E: PASS 1/1" >> "$r"; exit 0 ;;
      *) echo "FAIL a.one: slow" > "$r"; echo "E2E: FAIL 0/1" >> "$r"; exit 1 ;;
    esac ;;
  orphan)
    "$(dirname "$0")/../Frameworks/Helper" "$out/helper" > /dev/null 2>&1 < /dev/null &
    tail -f /dev/null "$out/report.txt" > /dev/null 2>&1 < /dev/null & echo $! > "$out/../tail.pid"
    echo "PASS a.one: ok" > "$r"; echo "E2E: PASS 1/1" >> "$r"; exit 0 ;;
  retrycrash)
    case $out in
      */retry) kill -SEGV $$ ;;
      *) echo "FAIL a.one: broken" > "$r"; echo "E2E: FAIL 0/1" >> "$r"; exit 1 ;;
    esac ;;
  chromium)
    case $out in
      */retry) { echo "RESULT a.one pass seconds=0.1 checks=1/1"; echo "PASS chromium.errors: ok"; echo "E2E: PASS 2/2"; } > "$r"; exit 0 ;;
      *) { echo "RESULT a.one pass seconds=0.1 checks=1/1"; echo "FAIL chromium.errors: 1 unexpected"; echo "E2E: FAIL 1/2"; } > "$r"; exit 1 ;;
    esac ;;
  stuck)
    case $out in
      */retry) { echo "RESULT a.two pass seconds=0.2 checks=1/1"; echo "RESULT a.three pass seconds=0.2 checks=1/1"; echo "E2E: PASS 2/2"; } > "$r"; exit 0 ;;
      *) { echo "RESULT a.one pass seconds=0.1 checks=1/1"; echo "E2E: TIMEOUT a.two: open window (main thread stuck)"
        echo "NOT RUN a.three"; echo "E2E: FAIL 1/3"; } > "$r"; exit 2 ;;
    esac ;;
  between)
    # The main thread stuck between tests: a TIMEOUT line with no test name. The retry cannot start.
    case $out in
      */retry) echo "bow: --e2e=$sel is not a test" >&2; exit 64 ;;
      *) { echo "RESULT a.one pass seconds=0.1 checks=1/1"; echo "E2E: TIMEOUT between tests (closing windows)"
        echo "NOT RUN a.two"; } > "$r"; exit 2 ;;
    esac ;;
  mixed)
    # A test fails and so does a check that is no test's; only a rerun of the whole selection passes it all.
    case $out in
      */retry)
        if [ "$sel" = "a.two" ]; then
          { echo "PASS a.two: ok"; echo "RESULT a.two pass seconds=0.1 checks=1/1"; echo "E2E: PASS 1/1"; } > "$r"
        else
          { echo "PASS a.one: ok"; echo "RESULT a.one pass seconds=0.1 checks=1/1"; echo "PASS a.two: ok"
            echo "RESULT a.two pass seconds=0.1 checks=1/1"; echo "PASS chromium.errors: ok"; echo "E2E: PASS 3/3"; } > "$r"
        fi
        exit 0 ;;
      *) { echo "PASS a.one: ok"; echo "RESULT a.one pass checks=1/1"; echo "FAIL a.two: broken"
        echo "RESULT a.two fail seconds=0.2 checks=0/1"; echo "FAIL chromium.errors: 1 unexpected"; echo "E2E: FAIL 1/3"; } > "$r"
        exit 1 ;;
    esac ;;
  hang)
    # Starts a helper, then never ends, like a stuck app that ignores its watchdog.
    "$(dirname "$0")/../Frameworks/Helper" "$out/helper" > /dev/null 2>&1 < /dev/null &
    echo "PASS a.one: ok" > "$r"
    while :; do sleep 0.1; done ;;
  stucklate)
    # The stuck test fails its step after the TIMEOUT line, before the app exits.
    case $out in
      */retry) { echo "RESULT a.two pass seconds=0.2 checks=1/1"; echo "RESULT a.three pass seconds=0.2 checks=1/1"; echo "E2E: PASS 2/2"; } > "$r"; exit 0 ;;
      *) { echo "RESULT a.one pass seconds=0.1 checks=1/1"; echo "E2E: TIMEOUT a.two: open window (main thread stuck)"
        echo "NOT RUN a.three"; echo "FAIL a.two: TIMEOUT: the step ran past 10 s"; } > "$r"; exit 2 ;;
    esac ;;
  hangterm)
    # Never ends and ignores TERM, like an app stuck in shutdown.
    trap '' TERM
    echo "PASS a.one: ok" > "$r"
    while :; do sleep 0.1; done ;;
  stuckchromium)
    # A runner-owned check fails after the TIMEOUT line: no rerun of tests covers it.
    case $out in
      */retry) { echo "RESULT a.one pass seconds=0.1 checks=1/1"; echo "RESULT a.two pass seconds=0.2 checks=1/1"
        echo "RESULT a.three pass seconds=0.2 checks=1/1"; echo "PASS chromium.errors: ok"; echo "E2E: PASS 4/4"; } > "$r"; exit 0 ;;
      *) { echo "RESULT a.one pass seconds=0.1 checks=1/1"; echo "E2E: TIMEOUT a.two: open window (main thread stuck)"
        echo "NOT RUN a.three"; echo "FAIL chromium.errors: 1 unexpected"; } > "$r"; exit 2 ;;
    esac ;;
  stucknototal)
    # A timeout that prints no total, then a retry of the stuck and not run tests that passes.
    case $out in
      */retry) { echo "RESULT a.two pass seconds=0.2 checks=1/1"; echo "RESULT a.three pass seconds=0.2 checks=1/1"; echo "E2E: PASS 2/2"; } > "$r"; exit 0 ;;
      *) { echo "RESULT a.one pass seconds=0.1 checks=1/1"; echo "E2E: TIMEOUT a.two: open window (main thread stuck)"
        echo "NOT RUN a.three"; } > "$r"; exit 2 ;;
    esac ;;
  timeoutfail)
    # Times out, then fails on the retry: the two attempts fail differently.
    case $out in
      */retry) echo "FAIL a.one: broken" > "$r"; echo "E2E: FAIL 0/1" >> "$r"; exit 1 ;;
      *) echo "E2E: TIMEOUT a.one: open window" > "$r"; exit 2 ;;
    esac ;;
  flakyresult)
    # Like flaky, with the RESULT lines the real runner prints after each test.
    case $out in
      */retry) { echo "PASS a.one: ok"; echo "RESULT a.one pass seconds=0.1 checks=1/1"; echo "E2E: PASS 1/1"; } > "$r"; exit 0 ;;
      *) { echo "FAIL a.one: slow"; echo "RESULT a.one fail seconds=0.1 checks=0/1"; echo "E2E: FAIL 0/1"; } > "$r"; exit 1 ;;
    esac ;;
  twoflaky)
    # Two tests fail, then both pass on the retry.
    case $out in
      */retry) { echo "PASS a.one: ok"; echo "RESULT a.one pass seconds=0.1 checks=1/1"; echo "PASS a.two: ok"
        echo "RESULT a.two pass seconds=0.1 checks=1/1"; echo "E2E: PASS 2/2"; } > "$r"; exit 0 ;;
      *) { echo "FAIL a.one: slow"; echo "RESULT a.one fail seconds=0.1 checks=0/1"; echo "FAIL a.two: slow"
        echo "RESULT a.two fail seconds=0.1 checks=0/1"; echo "E2E: FAIL 0/2"; } > "$r"; exit 1 ;;
    esac ;;
  quitflaky)
    # The quit check (named after its test) fails after a passing RESULT line, then the whole selection passes.
    case $out in
      */retry) { echo "RESULT a.one pass seconds=0.1 checks=0/0 quit=pending"; echo "PASS a.one: closed in 1 s"
        echo "PASS chromium.errors: unexpected=0"; echo "E2E: PASS 2/2"; } > "$r"; exit 0 ;;
      *) { echo "RESULT a.one pass seconds=0.1 checks=0/0 quit=pending"; echo "FAIL a.one: stopping took 6 s"
        echo "PASS chromium.errors: unexpected=0"; echo "E2E: FAIL 1/2"; } > "$r"; exit 1 ;;
    esac ;;
  failtimeout)
    # Fails, then times out on the retry.
    case $out in
      */retry) echo "E2E: TIMEOUT a.one: open window" > "$r"; exit 2 ;;
      *) { echo "FAIL a.one: slow"; echo "RESULT a.one fail seconds=0.1 checks=0/1"; echo "E2E: FAIL 0/1"; } > "$r"; exit 1 ;;
    esac ;;
  badjson)
    # The app writes a results.json of its own that is not JSON.
    echo "{not json" > "$out/results.json"
    echo "PASS a.one: ok" > "$r"; echo "E2E: PASS 1/1" >> "$r"; exit 0 ;;
  results)
    if [ "$sel" = "a.two" ]; then
      { echo "PASS a.two: ok"; echo "RESULT a.two pass seconds=0.3 checks=1/1"; echo "E2E: PASS 1/1"; } > "$r"; exit 0
    fi
    { echo "PASS a.one: ok"; echo "RESULT a.one pass seconds=0.1 checks=1/1"; echo "FAIL a.two: \"quoted\" reason"
      echo "RESULT a.two fail seconds=1.5 checks=0/1"; echo "E2E: FAIL 1/2"; } > "$r"; exit 1 ;;
esac
EOF
chmod +x "$app/Contents/MacOS/Bow"
# A stand-in for a Chromium helper: lives in the bundle and runs until killed.
mkdir -p "$app/Contents/Frameworks"
printf '#!/bin/bash\nwhile :; do sleep 0.2; done\n' > "$app/Contents/Frameworks/Helper"
chmod +x "$app/Contents/Frameworks/Helper"

failed=0
check() { # check <description> <condition command...>
  local what=$1
  shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; failed=1; fi
}
is() { [ "$1" = "$2" ]; }
not() { ! "$@"; }
has() { grep -q -- "$2" "$1"; }
valid_json() { perl -MJSON::PP -e 'local $/; decode_json(<STDIN>)' < "$1"; }
field() { plutil -extract "$2" raw -o - "$1" 2>/dev/null; }

# run <mode> [selection] [env...]: runs the wrapper; sets code, last (its last line) and res (results.json).
run() {
  local mode=$1 selection=${2:-all}
  out=$(FAKE_MODE=$mode ./scripts/e2e.sh "$app" "$selection" 2>&1)
  code=$?
  last=$(echo "$out" | tail -n 1)
  res="$BOW_E2E_ROOT/latest/results.json"
}

# Helpers the groups share.
rroot() { export BOW_E2E_ROOT="$tmp/repeat-$1"; }
says() { printf '%s\n' "$out" | grep -qx -- "$1"; }
says_some() { printf '%s\n' "$out" | grep -q -- "$1"; }
runs_in() { find "$BOW_E2E_ROOT" -mindepth 2 -maxdepth 2 -name results.json | wc -l | tr -d ' '; }
list() { printf '%s\n' "$@" > "$quarantine"; }
today=$(date +%Y-%m-%d)
latest() { echo "$BOW_E2E_ROOT/latest/$1"; }
shard_args() { cat "$(latest "shard-$1/args")" 2>/dev/null; }
shard_dirs() { find "$BOW_E2E_ROOT/latest/" -mindepth 1 -maxdepth 1 -name 'shard-*' | wc -l | tr -d ' '; }
retry_args() { cat "$(latest retry/args)" 2>/dev/null; }
# interrupt <signal> [mode] [tenths]: runs the wrapper on an app that never ends (FAKE_MODE hang), sends the signal
# once the app runs, and sets stopped (yes when the wrapper ended within tenths of a second, default 100), code, last,
# res and iroot.
interrupt() {
  local sig=$1 mode=${2:-hang} limit=${3:-100} ready=${4:-latest/report.txt} i wpid
  iroot="$tmp/int-$sig-$mode"
  # perl gives the wrapper a default INT, as a terminal does: a background job of a script starts with INT ignored.
  BOW_E2E_ROOT=$iroot FAKE_MODE=$mode PATH="${ipath:-$PATH}" perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' ./scripts/e2e.sh "$app" \
    > "$tmp/int-$sig.out" 2>&1 &
  wpid=$!
  for i in $(seq 300); do [ -s "$iroot/$ready" ] && break; sleep 0.1; done
  kill -"$sig" "$wpid"
  stopped=no
  for i in $(seq "$limit"); do kill -0 "$wpid" 2>/dev/null || { stopped=yes; break; }; sleep 0.1; done
  if [ "$stopped" = no ]; then
    kill -KILL "$wpid" 2>/dev/null
    pkill -KILL -f "$app/Contents/" 2>/dev/null
  fi
  wait "$wpid" 2>/dev/null
  code=$?
  last=$(tail -n 1 "$tmp/int-$sig.out")
  res="$iroot/latest/results.json"
}
nomake() { env -u MAKEFLAGS -u MAKELEVEL -u MFLAGS "$@"; }
fakewt() {
  local d="$tmp/wt-$1"
  mkdir -p "$d"
  cp -R scripts "$d/scripts"
  git -C "$d" init -q
  git -C "$d" checkout -q -b "$1"
  echo "$1" > "$d/marker"
  git -C "$d" add -A
  git -C "$d" -c user.name=t -c user.email=t@t commit -q -m t
}
# wtrun <worktree> <fake mode>: a run (after stamping a build of that tree) of that worktree's wrapper, its run folders outside the worktree.
wtrun() { (cd "$tmp/wt-$1" && ./scripts/stamp-tree.sh "$tmp/.bow-tree-key" true && FAKE_MODE=$2 BOW_E2E_ROOT="$tmp/wt-$1-runs" ./scripts/e2e.sh "$app" a.one > "$tmp/wt-$1.out" 2>&1; echo $?); }

group_basic() {
run pass
check "pass: exit 0" is "$code" 0
check "pass: ends with the app's summary" is "$last" "E2E: PASS 1/1"
check "pass: results.json is valid JSON" valid_json "$res"
check "pass: results.json status" is "$(field "$res" status)" pass
check "pass: latest points at the run" is "$(readlink "$BOW_E2E_ROOT/latest")" "$(basename "$(dirname "$(field "$res" run)/x")")"

run fail
check "fail: exit 1 after a failed retry" is "$code" 1
check "fail: summary" is "$last" "E2E: FAIL 0/1"
check "fail: two attempts" is "$(field "$res" attempts.1.status)" fail

E2E_RETRY=0 run fail
check "retry off: one attempt" is "$(plutil -extract attempts.1 raw -o - "$res" 2>/dev/null)" ""

run timeout
check "timeout: exit 2" is "$code" 2
check "timeout: summary" is "$last" "E2E: TIMEOUT a.one: open window"

run flaky
check "flaky: exit 3" is "$code" 3
check "flaky: summary" is "$last" "E2E: FLAKY 1/1 after retrying a.one"
check "flaky: FLAKY line" has "$BOW_E2E_ROOT/latest/report.txt" "^FLAKY a.one: failed then passed (slow)"
check "flaky: results.json lists it" is "$(field "$res" flaky.0)" a.one

run crash
check "crash: exit 4" is "$code" 4
check "crash: summary names the signal" is "$last" "E2E: CRASH exit=139 signal=11 without a summary line"
check "crash: report.txt gets the line" has "$BOW_E2E_ROOT/latest/report.txt" "^E2E: CRASH exit=139"
check "crash: results.json is valid JSON" valid_json "$res"

run watchdog
check "exit 2 with no summary is a crash, not a timeout" is "$code" 4

run teardown
check "teardown watchdog: exit 4" is "$code" 4
check "teardown watchdog: named in the summary" is "$last" "E2E: CRASH exit=2 Chromium teardown watchdog during quit"
run teardownsummary
check "teardown watchdog after a summary line: named, with the summary" is "$last" "E2E: CRASH exit=2 Chromium teardown watchdog during quit after its summary line (E2E: PASS 1/1)"

run usage nope.test
check "usage: exit 64" is "$code" 64
check "usage: summary" is "$last" "E2E: ERROR the app could not start the run (exit 64): an unknown selection or switch"

run orphan
check "orphan: exit 0" is "$code" 0
# Only this test's helpers, whose arguments name its own run folders, so parallel runs elsewhere do not count.
check "orphan: helper ended" is "$(ps -axo command= | grep -F -- "Frameworks/Helper $BOW_E2E_ROOT/" | grep -vc grep)" 0
check "orphan: counted" is "$(field "$res" orphansKilled)" 1
tail_pid=$(cat "$BOW_E2E_ROOT/tail.pid")
check "orphan: a process outside the app bundle is left alone" kill -0 "$tail_pid"
kill "$tail_pid" 2>/dev/null

run retrycrash
check "a crash on the retry: exit 4" is "$code" 4
check "a crash on the retry: summary" is "$last" "E2E: CRASH exit=139 signal=11 without a summary line"

run chromium 'tabs, nav'
check "the selection reaches the app as one --e2e value" is "$(cat "$BOW_E2E_ROOT/latest/args")" "e2e=tabs, nav"
check "a failed check outside any test: whole selection retried" is "$(cat "$BOW_E2E_ROOT/latest/retry/args")" "e2e=tabs, nav"
check "a failed check outside any test: FLAKY names it" is "$last" "E2E: FLAKY 2/2 after retrying chromium.errors"

run stuck 'a.*'
check "stuck: a pass on retry is flaky" is "$code" 3
check "stuck: the stuck test is named, the count covers the whole selection" is "$last" "E2E: FLAKY 3/3 after retrying a.two"
check "stuck: retries the stuck and not run tests" is "$(cat "$BOW_E2E_ROOT/latest/retry/args")" "e2e=a.two,a.three"
check "stuck: NOT RUN in results.json" is "$(field "$res" attempts.0.tests.1.status)" "not run"

FAKE_NOLIST=1 run stuck 'a.*'
check "stuck: a TIMEOUT test no RESULT, NOT RUN or TEST line names: whole selection retried" \
  is "$(cat "$BOW_E2E_ROOT/latest/retry/args")" "e2e=a.*"

run between 'a.*'
check "between tests: the TIMEOUT text is not taken as a test" is "$(cat "$BOW_E2E_ROOT/latest/retry/args")" "e2e=a.*"
check "between tests: a retry that cannot start keeps the first attempt's timeout" is "$code" 2
check "between tests: the first TIMEOUT line is the summary" is "$last" "E2E: TIMEOUT between tests (closing windows)"
check "between tests: results.json status" is "$(field "$res" status)" timeout

run mixed 'a.*'
check "mixed: a failed check outside any test retries the whole selection" is "$(cat "$BOW_E2E_ROOT/latest/retry/args")" "e2e=a.*"
check "mixed: FLAKY names the test and the run-wide check" is "$last" "E2E: FLAKY 3/3 after retrying a.two,chromium.errors"
check "mixed: FLAKY line for the run-wide check" has "$BOW_E2E_ROOT/latest/report.txt" "^FLAKY chromium.errors: failed then passed (1 unexpected)"
check "mixed: an empty field stays empty in results.json" is "$(field "$res" attempts.0.tests.0.checks)" 1/1
check "mixed: results.json is valid JSON" valid_json "$res"

BOW_E2E_SLOTS=none run pass
check "a refusal of the build lock: exit 64" is "$code" 64
check "a refusal of the build lock is not called a bad selection" is "$last" "E2E: ERROR the build lock refused to run the app (exit 64); see its message above"

E2E_RETRY=0 run stuck 'a.*'
check "stuck: exit 2 with RESULT and NOT RUN lines is a timeout" is "$code" 2
check "stuck: the TIMEOUT line is the summary" is "$last" "E2E: TIMEOUT a.two: open window (main thread stuck)"

run results 'a.*'
check "results: retries only the failed test" is "$(cat "$BOW_E2E_ROOT/latest/retry/args")" "e2e=a.two"
check "results: flaky exit 3" is "$code" 3
check "results: FLAKY line" has "$BOW_E2E_ROOT/latest/report.txt" "^FLAKY a.two: failed then passed (fail seconds=1.5 checks=0/1)"
check "results: seconds in results.json" is "$(field "$res" attempts.0.tests.1.seconds)" 1.500000
check "results: checks in results.json" is "$(field "$res" attempts.0.tests.1.checks)" 0/1
check "results: failed check detail in results.json" is "$(field "$res" attempts.0.checks.1.detail)" '"quoted" reason'
check "results: results.json is valid JSON" valid_json "$res"

run stucklate 'a.*'
check "a FAIL line after the TIMEOUT line is the stuck test's: only it and the not run tests rerun" \
  is "$(cat "$BOW_E2E_ROOT/latest/retry/args")" "e2e=a.two,a.three"

run stuckchromium 'a.*'
check "a chromium.errors FAIL after the TIMEOUT line: whole selection retried" is "$(cat "$BOW_E2E_ROOT/latest/retry/args")" "e2e=a.*"

run stucknototal 'a.*'
check "no total after a timeout: FLAKY says only the retried tests passed" \
  is "$last" "E2E: FLAKY retried tests passed 2/2 after retrying a.two,a.three (the first attempt printed no total)"

run timeoutfail
check "a timeout, then a FAIL on the retry: the first attempt's exit code" is "$code" 2
check "a timeout, then a FAIL on the retry: the summary names both" is "$last" "E2E: TIMEOUT a.one: open window (retry: FAIL 0/1)"

run badjson
check "an app results.json that is not JSON: results.json stays valid" valid_json "$res"
check "an app results.json is kept aside" has "$BOW_E2E_ROOT/latest/app-results.json" "not json"
}

group_repeat() {
rroot pass
E2E_REPEAT=3 run loudpass a.one
check "repeat: exit 0" is "$code" 0
check "repeat: summary" is "$last" "E2E: PASS 3/3 repeats"
check "repeat: passes out of N per test" says "REPEAT a.one 3/3"
check "repeat: one run folder per repeat" is "$(runs_in)" 3
check "repeat: each repeat gets the selection" is "$(cat "$BOW_E2E_ROOT"/*/args | sort -u)" "e2e=a.one"
check "repeat: a person sees each repeat's output" is "$(printf '%s\n' "$out" | grep -c '^PASS a.one: ok')" 3
rroot fail
E2E_REPEAT=3 run repeatfail
check "a failing repeat: exit 1" is "$code" 1
check "a failing repeat: the summary names it" is "$last" "E2E: FAIL 2/3 repeats passed; failed: repeat 2 (FAIL 0/1)"
check "a failing repeat: passes out of N" says "REPEAT a.one 2/3"
check "a failing repeat: the retry is off inside repeats" is "$(find "$BOW_E2E_ROOT" -name retry | wc -l | tr -d ' ')" 0
check "a failing repeat: the repeats go on" is "$(runs_in)" 3
rroot timeout
E2E_REPEAT=3 run repeattimeout
check "a repeat that times out: exit 2" is "$code" 2
check "a repeat that times out: the summary names it" is "$last" "E2E: TIMEOUT 2/3 repeats passed; failed: repeat 2 (TIMEOUT a.one: open window)"
rroot crash
E2E_REPEAT=2 run repeatcrash
check "a repeat that crashes: exit 4" is "$code" 4
check "a repeat that crashes: the summary names it" is "$last" "E2E: CRASH 1/2 repeats passed; failed: repeat 1 (CRASH exit=139 signal=11 without a summary line)"
rroot quit
E2E_REPEAT=3 run repeatquit
check "a repeat whose quit check fails after a passing RESULT: the summary" is "$last" "E2E: FAIL 2/3 repeats passed; failed: repeat 2 (FAIL 1/2)"
check "a repeat whose quit check fails after a passing RESULT: the test's passes" says "REPEAT a.one 2/3"
rroot quitcrash
E2E_REPEAT=3 run repeatquitcrash
check "a repeat that crashes after quit=pending: exit 4" is "$code" 4
check "a repeat that crashes after quit=pending: the test's passes" says "REPEAT a.one 2/3"
rroot usage
E2E_REPEAT=3 run usage nope.test
check "a repeat that cannot start: exit 64" is "$code" 64
check "a repeat that cannot start: the repeats stop" is "$(runs_in)" 1
check "a repeat that cannot start: summary" is "$last" "E2E: ERROR repeat 1/3 could not run: the app could not start the run (exit 64): an unknown selection or switch"
for bad in 0 x 1.5 -2; do
  E2E_REPEAT=$bad run pass
  check "E2E_REPEAT=$bad: exit 64" is "$code" 64
  check "E2E_REPEAT=$bad: summary" is "$last" "E2E: ERROR bad E2E_REPEAT"
done
check "list ignores E2E_REPEAT" is "$(E2E_REPEAT=3 FAKE_MODE=pass ./scripts/e2e.sh "$app" list | wc -l | tr -d ' ')" 3
E2E_REPEAT=1 run pass
check "E2E_REPEAT=1 is a plain run" is "$last" "E2E: PASS 1/1"

# Short output (E2E_QUIET=1, or CLAUDECODE=1 when E2E_QUIET is unset): the failing lines, the folder and the summary.
rroot quiet
E2E_QUIET=1 run loudpass
check "short output on a pass: two lines" is "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 2
check "short output on a pass: names the run folder" says "e2e: everything is in $(cd "$BOW_E2E_ROOT/latest" && pwd -P) (report.txt, results.json, chromium.log)"
check "short output on a pass: ends with the summary" is "$last" "E2E: PASS 1/1"
check "short output leaves no file of its own behind" not test -e "$BOW_E2E_ROOT/latest/.output"
quiet_files=$(cd "$BOW_E2E_ROOT/latest" && ls -A)
quiet_report=$(cat "$BOW_E2E_ROOT/latest/report.txt")
run loudpass
check "a person's output keeps everything" says "PASS a.one: ok"
check "a person's output keeps the app's echoed lines" says "quit: seconds=0.5"
check "a person's output keeps the progress lines" says_some "^e2e: .*results in results.json"
check "short output writes the same files" is "$(cd "$BOW_E2E_ROOT/latest" && ls -A)" "$quiet_files"
check "short output writes the same report.txt" is "$(cat "$BOW_E2E_ROOT/latest/report.txt")" "$quiet_report"
(unset E2E_QUIET; CLAUDECODE=1 FAKE_MODE=loudpass ./scripts/e2e.sh "$app" > "$tmp/claude.out" 2>&1)
check "CLAUDECODE=1 turns short output on" is "$(wc -l < "$tmp/claude.out" | tr -d ' ')" 2
(CLAUDECODE=1 E2E_QUIET=0 FAKE_MODE=loudpass ./scripts/e2e.sh "$app" > "$tmp/claude.out" 2>&1)
check "E2E_QUIET=0 turns it off" has "$tmp/claude.out" "^PASS a.one: ok"
E2E_QUIET=1 run loudfail
check "short output on a failure: exit 1" is "$code" 1
check "short output on a failure: the FAIL line" says "FAIL a.one: broken"
check "short output on a failure: the failing test's RESULT line" says "RESULT a.one fail seconds=0.1 checks=0/1"
check "short output on a failure: the retry's lines" says "retry: FAIL a.one: broken"
check "short output on a failure: the echoed ERROR line" says "\[1023/101010.000001:ERROR:fake.cc(12)\] something broke"
check "short output on a failure: not the app's other lines" not says_some "quit: seconds"
check "short output on a failure: no progress lines" not says_some "retrying once"
check "short output on a failure: ends with the summary" is "$last" "E2E: FAIL 0/1"
check "short output on a failure: nothing more" is "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 8
E2E_QUIET=1 run flaky
check "short output on a flake: the FLAKY line" says "FLAKY a.one: failed then passed (slow)"
check "short output on a flake: ends with the summary" is "$last" "E2E: FLAKY 1/1 after retrying a.one"
E2E_QUIET=1 run usage nope.test
check "short output when the run cannot start: exit 64" is "$code" 64
check "short output when the run cannot start: says why" says "bow: --e2e=nope is not a test"
E2E_QUIET=1 BOW_E2E_SLOTS=none run pass
check "short output when the build lock refuses: says why" says_some "^build-lock: BOW_E2E_SLOTS must be a positive number"
rroot quietpass
E2E_QUIET=1 E2E_REPEAT=3 run loudpass
check "short output of passing repeats: two lines" is "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 2
check "short output of passing repeats: summary" is "$last" "E2E: PASS 3/3 repeats"
rroot quietfail
E2E_QUIET=1 E2E_REPEAT=3 run repeatfail
check "short output of a failing repeat: its FAIL line" says "FAIL a.one: broken"
check "short output of a failing repeat: names the repeat" says_some "^e2e: repeat 2/3 failed: E2E: FAIL 0/1"
check "short output of a failing repeat: the test below N" says "REPEAT a.one 2/3"
check "short output of a failing repeat: not the passing repeats' lines" not says_some "^E2E: PASS"
check "short output of a failing repeat: no file of its own left" is "$(find "$BOW_E2E_ROOT" -name '.repeat.*' -o -name .output | wc -l | tr -d ' ')" 0

# The flake count: per test runs, passes, FLAKY, FAIL and TIMEOUT from the results.json files of a run root.
rroot flakes
E2E_REPEAT=3 run repeatfail
run results 'a.*'
E2E_RETRY=0 run stucknototal 'a.*'
newest=$(readlink "$BOW_E2E_ROOT/latest")
# A run that could not start counts for nothing.
run usage nope.test
flakes=$(./scripts/e2e-flakes.sh "$BOW_E2E_ROOT")
flakes_code=$?
row() { printf '%s\n' "$flakes" | awk -v t="$1" '$1 == t { print $2, $3, $4, $5, $6 }'; }
check "flakes: exit 0" is "$flakes_code" 0
check "flakes: counts every run" is "$(printf '%s\n' "$flakes" | tail -n 1)" "e2e-flakes: 5 runs"
check "flakes: a.one runs passes FLAKY FAIL TIMEOUT" is "$(row a.one)" "5 4 0 1 0"
check "flakes: a.two flaked once and timed out once" is "$(row a.two)" "2 0 1 0 1"
check "flakes: most failures first" is "$(printf '%s\n' "$flakes" | sed -n 2p | awk '{ print $1 }')" a.two
check "flakes: a test that never ran is not counted" is "$(row a.three)" ""
check "flakes: the newest failure is named" is "$(printf '%s\n' "$flakes" | awk '$1 == "a.two" { print $7 }')" "$newest"
check "flakes: also takes a run folder" is "$(./scripts/e2e-flakes.sh "$BOW_E2E_ROOT/$newest" | tail -n 1)" "e2e-flakes: 1 runs"
check "flakes: an empty root exits 1" not ./scripts/e2e-flakes.sh "$tmp/none" 2> /dev/null
quit_row() { ./scripts/e2e-flakes.sh "$tmp/repeat-$1" | awk '$1 == "a.one" { print $2, $3, $4, $5, $6 }'; }
check "flakes: a quit check failing after a passing RESULT fails the test" is "$(quit_row quit)" "3 2 0 1 0"
check "flakes: a crash after quit=pending fails the test" is "$(quit_row quitcrash)" "3 2 0 1 0"
}

group_quarantine() {
rroot qmain
list "# known flakes" "" "a.one 2999-01-01 slow under load"
rroot quarantineflakes
run flakyresult
check "quarantine: the flake count still counts a quarantined test as FLAKY" \
  is "$(./scripts/e2e-flakes.sh "$BOW_E2E_ROOT" | awk '$1 == "a.one" { print $2, $3, $4, $5, $6 }')" "1 0 1 0 0"
rroot qmain
run flakyresult
check "quarantine: a listed FLAKY test passes" is "$code" 0
check "quarantine: the summary is a pass naming it" is "$last" "E2E: PASS 1/1; quarantined flaky tests passed on the retry: a.one"
check "quarantine: the FLAKY line stays" says "FLAKY a.one: failed then passed (fail seconds=0.1 checks=0/1)"
check "quarantine: a QUARANTINED line" says "QUARANTINED a.one (expires 2999-01-01): slow under load"
check "quarantine: report.txt keeps both lines" has "$BOW_E2E_ROOT/latest/report.txt" "^QUARANTINED a.one (expires 2999-01-01)"
check "quarantine: results.json status pass" is "$(field "$res" status)" pass
check "quarantine: results.json exit code 0" is "$(field "$res" exitCode)" 0
check "quarantine: results.json still lists it as flaky" is "$(field "$res" flaky.0)" a.one
check "quarantine: results.json names the entry" is "$(field "$res" quarantined.0.name)/$(field "$res" quarantined.0.expires)/$(field "$res" quarantined.0.reason)" "a.one/2999-01-01/slow under load"
check "quarantine: results.json is valid JSON" valid_json "$res"
E2E_QUIET=1 run flakyresult
check "quarantine, short output: exit 0" is "$code" 0
check "quarantine, short output: the FLAKY line" says "FLAKY a.one: failed then passed (fail seconds=0.1 checks=0/1)"
check "quarantine, short output: the QUARANTINED line" says "QUARANTINED a.one (expires 2999-01-01): slow under load"
check "quarantine, short output: ends with the note" is "$last" "E2E: PASS 1/1; quarantined flaky tests passed on the retry: a.one"
run quitflaky 'a.*'
check "quarantine: a failed quit check counts as its test's" is "$code" 0
check "quarantine: the quit check's run reran the whole selection" is "$(cat "$BOW_E2E_ROOT/latest/retry/args")" "e2e=a.*"
check "quarantine: the quit check's note" is "$last" "E2E: PASS 2/2; quarantined flaky tests passed on the retry: a.one"
run twoflaky 'a.*'
check "quarantine: one listed and one unlisted FLAKY test: exit 3" is "$code" 3
check "quarantine: one listed and one unlisted: the FLAKY summary" is "$last" "E2E: FLAKY 2/2 after retrying a.one,a.two"
check "quarantine: one listed and one unlisted: no QUARANTINED line" not says_some "^QUARANTINED"
check "quarantine: one listed and one unlisted: results.json has none" is "$(field "$res" quarantined.0.name)" ""
run fail
check "quarantine: a listed test that fails on the retry: exit 1" is "$code" 1
check "quarantine: a listed test that fails on the retry: summary" is "$last" "E2E: FAIL 0/1"
run failtimeout
check "quarantine: a listed test that times out on the retry: exit 1" is "$code" 1
check "quarantine: a listed test that times out on the retry: summary" is "$last" "E2E: FAIL 0/1 (retry: TIMEOUT a.one: open window)"
run retrycrash
check "quarantine: a listed test whose retry crashes: exit 4" is "$code" 4
run chromium
check "quarantine: a run-wide check is never quarantined" is "$code" 3
list "a.two 2999-01-01 slow"
run mixed 'a.*'
check "quarantine: a listed test beside a run-wide failure: exit 3" is "$code" 3
run stuck 'a.*'
check "quarantine: a first attempt whose main thread was stuck is never quarantined" is "$code" 3
check "quarantine: after a stuck main thread: the FLAKY summary" is "$last" "E2E: FLAKY 3/3 after retrying a.two"
list "a.two 2999-01-01 slow"
run results 'a.*'
check "quarantine: a listed failed test retried alone passes" is "$last" "E2E: PASS 2/2; quarantined flaky tests passed on the retry: a.two"
list "a.one 2999-01-01 slow" "a.two 2999-01-01 slow"
run twoflaky 'a.*'
check "quarantine: two listed tests: the note names both" is "$last" "E2E: PASS 2/2; quarantined flaky tests passed on the retry: a.one, a.two"
list "a.two 2999-01-01 slow"
run flakyresult
check "quarantine: an unlisted FLAKY test: exit 3" is "$code" 3
check "quarantine: an unlisted FLAKY test: the FLAKY summary" is "$last" "E2E: FLAKY 1/1 after retrying a.one"
list "a.one 2000-01-01 slow" "a.two $today due today"
run flakyresult
check "quarantine: an expired entry: exit 3" is "$code" 3
check "quarantine: an expired entry is named" says "QUARANTINE EXPIRED a.one (expired 2000-01-01): remove or renew its entry in $quarantine"
check "quarantine: an entry has expired on its date" says_some "^QUARANTINE EXPIRED a.two (expired $today)"
check "quarantine: results.json names the expired entries" is "$(field "$res" quarantineExpired.0)/$(field "$res" quarantineExpired.1)" "a.one/a.two"
run pass
check "quarantine: a passing run still names the expired entries" says_some "^QUARANTINE EXPIRED a.one "
check "quarantine: a passing run with an expired entry still passes" is "$last" "E2E: PASS 1/1"
E2E_QUIET=1 run pass
check "quarantine, short output: the expired entries are named on a pass" says_some "^QUARANTINE EXPIRED a.one "
check "quarantine, short output: only they are added" is "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 4
list "a.one 2999-01-01 slow"
rroot quarantine
E2E_REPEAT=3 run repeatfail
check "quarantine: a listed test failing in a repeat still fails" is "$code" 1
for bad in "a.one 2999-13-01 slow|is not a date in YYYY-MM-DD form" "a.one 2999-02-30 slow|is not a date" \
  "a.one 30-10-2026 slow|is not a date" "a.one 2999-01-01|want <test name> <YYYY-MM-DD expiry> <reason>" \
  "a.* 2999-01-01 slow|is not a test name" "aone 2999-01-01 slow|is not a test name" \
  "chromium.errors 2999-01-01 slow|belongs to the runner" "a.one 2999-01-01 see BOW-12|names a Plane ID"; do
  list "# a comment" "${bad%%|*}"
  run pass
  check "quarantine: '${bad%%|*}' stops the run: exit 64" is "$code" 64
  check "quarantine: '${bad%%|*}' says why" says_some "^E2E: ERROR bad quarantine list: $quarantine line 2: .*${bad#*|}"
done
list "a.one 2999-01-01 slow" "a.one 2000-01-01 again"
run pass
check "quarantine: a duplicate entry stops the run" is "$last" "E2E: ERROR bad quarantine list: $quarantine line 2: a.one is listed twice"
E2E_REPEAT=3 run pass
check "quarantine: a malformed list stops the repeats before they start" is "$code/$(runs_in)" "64/3"
check "quarantine: list ignores a malformed list" is "$(FAKE_MODE=pass ./scripts/e2e.sh "$app" list | wc -l | tr -d ' ')" 3
rroot qmain
: > "$quarantine"
run flakyresult
check "quarantine: an empty list quarantines nothing" is "$code" 3
rm -f "$quarantine"
run flakyresult
check "quarantine: a missing list quarantines nothing" is "$code" 3
check "quarantine: the checked in list is well formed" is "$(E2E_QUARANTINE="" FAKE_MODE=pass ./scripts/e2e.sh "$app" 2>&1 | tail -n 1)" "E2E: PASS 1/1"
}

group_shards() {
rroot shard1
run shard
check "shards unset: the fake runner's single run" is "$last" "E2E: PASS 5/5"
single_report=$(cat "$(latest report.txt)")
E2E_SHARDS=1 run shard
check "E2E_SHARDS=1: a single run" is "$last/$(shard_dirs)/$(cat "$(latest args)")" "E2E: PASS 5/5/0/e2e=all"
check "E2E_SHARDS=1: the same report" is "$(cat "$(latest report.txt)")" "$single_report"
check "E2E_SHARDS=1: no test list asked for" not test -e "$(latest tests.txt)"
check "E2E_SHARDS=1: results.json has no shards" not has "$res" '"shards"'
for n in 2 3; do
  rroot "shards$n"
  E2E_SHARDS=$n FAKE_BARRIER=$n run shard
  check "E2E_SHARDS=$n: exit 0" is "$code" 0
  check "E2E_SHARDS=$n: the same total as a single run" is "$last" "E2E: PASS 5/5"
  check "E2E_SHARDS=$n: one folder per shard" is "$(shard_dirs)" "$n"
  check "E2E_SHARDS=$n: the apps ran at once" is "$(cat "$BOW_E2E_ROOT"/latest/shard-*/together | sort -u)" yes
  check "E2E_SHARDS=$n: every test ran once" is "$(grep '^RESULT ' "$(latest report.txt)" | awk '{ print $2 }' | sort | paste -sd, -)" "a.one,a.three,a.two"
  check "E2E_SHARDS=$n: each run-wide check is one line" is "$(grep -c -e '^PASS chromium.errors: ' -e '^PASS e2e.isolation: ' "$(latest report.txt)")" 2
  check "E2E_SHARDS=$n: the run-wide line names each shard's result" \
    has "$(latest report.txt)" "^PASS chromium.errors: shard 1/$n: unexpected=0; shard 2/$n: unexpected=0"
  check "E2E_SHARDS=$n: the quit test is in exactly one app" is "$(grep -l a.three "$BOW_E2E_ROOT"/latest/shard-*/args | wc -l | tr -d ' ')" 1
  quit_shard=$(dirname "$(grep -l a.three "$BOW_E2E_ROOT"/latest/shard-*/args | head -n 1)")
  check "E2E_SHARDS=$n: the quit test is its app's last" is "$(grep '^RESULT ' "$quit_shard/report.txt" | tail -n 1 | awk '{ print $2 }')" a.three
  check "E2E_SHARDS=$n: results.json is valid JSON" valid_json "$res"
  check "E2E_SHARDS=$n: results.json status and exit code" is "$(field "$res" status)/$(field "$res" exitCode)" pass/0
  check "E2E_SHARDS=$n: results.json lists each shard" is "$(field "$res" shards.$((n - 1)).status)/$(field "$res" shards.$n.status)" pass/
  check "E2E_SHARDS=$n: results.json has every test" is "$(field "$res" attempts.0.tests.2.status)" pass
  check "E2E_SHARDS=$n: latest is the run, not a shard" is "$(field "$res" run)" "$(cd "$BOW_E2E_ROOT/latest" && pwd -P)"
  check "E2E_SHARDS=$n: no output file left" is "$(find "$BOW_E2E_ROOT" -name '.shard-*' | wc -l | tr -d ' ')" 0
done
check "E2E_SHARDS=3: each shard is a run of its own" is "$(field "$(latest shard-2/results.json)" status)" pass
check "a person sees each shard's output" says "e2e: shard 2/3 output:"
}

group_shard_plan() {
# Planning: test order with no history, then the newest time of each test, longest first onto the least loaded.
rroot plan
E2E_SHARDS=2 run shard
check "plan: no history deals the tests out in test order" is "$(shard_args 1) $(shard_args 2)" "e2e=a.one,a.three e2e=a.two"
check "plan: says it had no history" says_some "split in test order"
E2E_SHARDS=2 run shard
check "plan: from the last run's times (0.5, 0.3, 0.2)" is "$(shard_args 1) $(shard_args 2)" "e2e=a.one e2e=a.two,a.three"
check "plan: results.json keeps the planned seconds" is "$(field "$res" shards.1.plannedSeconds)" 0.500000
mkdir -p "$BOW_E2E_ROOT/old"
echo '{"attempts":[{"tests":[{"name":"z.gone","seconds":99},{"name":"a.two","seconds":9},{"name":"a.one","seconds":"x"}]}]}' \
  > "$BOW_E2E_ROOT/old/results.json"
E2E_SHARDS=2 run shard
check "plan: the newest time of each test, ignoring tests that are gone and bad times" \
  is "$(shard_args 1) $(shard_args 2)" "e2e=a.two e2e=a.one,a.three"
rm -rf "$BOW_E2E_ROOT/old"
E2E_SHARDS=5 run shard 'a.one,a.two'
check "plan: fewer tests than shards: one shard per test" is "$(shard_dirs)/$last" "2/E2E: PASS 4/4"
E2E_SHARDS=2 run shard 'smoke, a.th*'
check "plan: a tag and a glob resolve as the app resolves them" is "$(shard_args 1) $(shard_args 2)" "e2e=a.three e2e=a.two"
E2E_SHARDS=2 run shard a
check "plan: an area resolves to its tests" is "$(shard_dirs)/$last" "2/E2E: PASS 5/5"
FAKE_LISTTAG=a.one E2E_SHARDS=2 run shard
check "plan: a test named like a tag or area goes as a glob of just its name" \
  is "$(cat "$BOW_E2E_ROOT"/latest/shard-*/args | grep -c 'a\.on\[e\]')/$last" "1/E2E: PASS 5/5"
check "plan: that test runs once" is "$(grep -c '^RESULT a.one ' "$(latest report.txt)")" 1
for sel in all a 'a.*' smoke,a.one; do
  FAKE_BYNAME=1 E2E_SHARDS=2 run shard "$sel"
  check "plan: $sel leaves out a test selected by name only" \
    is "$(cat "$BOW_E2E_ROOT"/latest/shard-*/args | grep -c 'a\.self')/$(shard_dirs)" "0/2"
done
FAKE_BYNAME=1 E2E_SHARDS=2 run shard 'a.one,a.self'
check "plan: the exact name selects a test selected by name only" \
  is "$(cat "$BOW_E2E_ROOT"/latest/shard-*/args | grep -c 'a\.self')/$(shard_dirs)" "1/2"
FAKE_GREEDY=1 E2E_SHARDS=2 run shard
check "a shard that runs tests outside its plan stops the run" \
  is "$code/$last" "64/E2E: ERROR shard 1/2: it ran tests outside its plan: a.two, a.three"
FAKE_SKIP=a.two E2E_SHARDS=2 run shard
check "a shard that leaves a test of its plan unrun stops the run" \
  is "$code/$last" "64/E2E: ERROR shard 2/2: it did not run tests of its plan: a.two"
E2E_SHARDS=3 run shard a.one
check "plan: one test runs in one app" is "$(shard_dirs)/$last/$(cat "$(latest args)")" "0/E2E: PASS 3/3/e2e=a.one"
E2E_SHARDS=2 run usage nope.test
check "plan: an unknown selection is the app's to refuse, in one app" \
  is "$code/$last" "64/E2E: ERROR the app could not start the run (exit 64): an unknown selection or switch"
E2E_SHARDS=2 BOW_E2E_SLOTS=none run shard
check "plan: no test list (the build lock refused) runs in one app, which says why" \
  is "$code/$last" "64/E2E: ERROR the build lock refused to run the app (exit 64); see its message above"
for bad in 0 x -1; do
  E2E_SHARDS=$bad run shard
  check "E2E_SHARDS=$bad: exit 64" is "$code/$last" "64/E2E: ERROR bad E2E_SHARDS"
done
check "list ignores E2E_SHARDS" is "$(E2E_SHARDS=x FAKE_MODE=shard ./scripts/e2e.sh "$app" list | wc -l | tr -d ' ')" 3
eval "$(sed -n '/^check_plan() {/,/^}/p' scripts/e2e.sh)"
us=$'\037'
printf 'a.one\na.two\na.three\n' > "$tmp/names"
plan() { printf '%s\n' "$@" | tr '|' "$us"; }
check "check_plan: accepts a plan with every test once" check_plan "$tmp/names" 2 "$(plan '1|a.one|1' '2|a.two|1' '1|a.three|1' 'H|0')"
check "check_plan: refuses a test in no shard" not check_plan "$tmp/names" 2 "$(plan '1|a.one|1' '2|a.two|1')"
check "check_plan: refuses a test in two shards" not check_plan "$tmp/names" 2 "$(plan '1|a.one|1' '2|a.two|1' '1|a.three|1' '2|a.three|1')"
check "check_plan: refuses a test not selected" not check_plan "$tmp/names" 2 "$(plan '1|a.one|1' '2|a.two|1' '1|a.three|1' '2|z.gone|1')"
check "check_plan: refuses an empty shard" not check_plan "$tmp/names" 3 "$(plan '1|a.one|1' '2|a.two|1' '1|a.three|1')"

}

group_shard_outcomes() {
# The outcomes: the same summary lines and exit codes as a single run.
rroot shardfail
for n in 1 2; do
  E2E_SHARDS=$n E2E_RETRY=0 FAKE_FAIL=a.two run shard
  check "a failed test, E2E_SHARDS=$n: exit 1, one total" is "$code/$last" "1/E2E: FAIL 4/5"
  FAKE_FAIL=a.two E2E_SHARDS=$n run shard
  check "a flaky test, E2E_SHARDS=$n: FLAKY over the whole selection" is "$code/$last" "3/E2E: FLAKY 5/5 after retrying a.two"
  check "a flaky test, E2E_SHARDS=$n: one retry of just the test" is "$(retry_args)" "e2e=a.two"
  check "a flaky test, E2E_SHARDS=$n: the FLAKY line" has "$(latest report.txt)" "^FLAKY a.two: failed then passed (fail seconds=0.2 checks=0/1)"
  check "a flaky test, E2E_SHARDS=$n: results.json" is "$(field "$res" flaky.0)/$(field "$res" attempts.1.status)" a.two/pass
  E2E_RETRY=0 FAKE_CHROMIUM=a.two E2E_SHARDS=$n run shard
  check "a failed chromium.errors, E2E_SHARDS=$n: one check" is "$code/$last" "1/E2E: FAIL 4/5"
  FAKE_CHROMIUM=a.two E2E_SHARDS=$n run shard
  check "a failed chromium.errors, E2E_SHARDS=$n: FLAKY over the whole selection" is "$last" "E2E: FLAKY 5/5 after retrying chromium.errors"
  if [ "$n" = 1 ]; then
    check "a failed chromium.errors in a single run: the whole selection retried" is "$(retry_args)" "e2e=all"
  else
    check "a failed chromium.errors in a shard: every test of that app retried" \
      is "$(retry_args)" "$(cat "$(grep -l a.two "$BOW_E2E_ROOT"/latest/shard-*/args)")"
  fi
done
check "a failed chromium.errors in one shard: the line fails and names each shard" \
  has "$(latest report.txt)" "^FAIL chromium.errors: shard 1/2: unexpected=0; shard 2/2: 1 unexpected"
# No history from here on, so the shards are a.one,a.three and a.two.
}

group_shard_timeouts() {
rroot shardtimeout
E2E_RETRY=0 FAKE_TIMEOUT=a.one E2E_SHARDS=2 run shard
check "a timeout in one shard: exit 2 with its TIMEOUT line" is "$code/$last" "2/E2E: TIMEOUT a.one: open window (main thread stuck)"
check "a timeout in one shard: its NOT RUN line" has "$(latest report.txt)" "^NOT RUN a.three"
check "a timeout in one shard: the other shard's results" has "$(latest report.txt)" "^RESULT a.two pass"
check "a timeout in one shard: results.json status" is "$(field "$res" status)" timeout
FAKE_TIMEOUT=a.one E2E_SHARDS=2 run shard
check "a timeout in one shard: the retry reruns its stuck and not run tests" is "$(retry_args)" "e2e=a.one,a.three"
check "a timeout in one shard: FLAKY says only the retried tests passed" \
  is "$code/$last" "3/E2E: FLAKY retried tests passed 4/4 after retrying a.one,a.three (the first attempt printed no total)"
FAKE_TIMEOUT=a.one,a.two E2E_SHARDS=2 run shard
check "a timeout in two shards: the retry reruns both stuck tests" is "$(retry_args)" "e2e=a.one,a.three,a.two"
E2E_RETRY=0 FAKE_CRASH=a.two E2E_SHARDS=2 run shard
check "a crash in one shard: exit 4, naming the shard" is "$code/$last" "4/E2E: CRASH exit=139 signal=11 without a summary line in shard 2/2"
check "a crash in one shard: the other shard's results stay" has "$(latest report.txt)" "^RESULT a.one pass"
FAKE_CRASH=a.two E2E_SHARDS=2 run shard
check "a crash in one shard: no retry" is "$code/$(find "$BOW_E2E_ROOT/latest/" -maxdepth 1 -name retry | wc -l | tr -d ' ')" 4/0
FAKE_USAGE=a.two E2E_SHARDS=2 run shard
check "a shard that cannot start: exit 64, naming it" \
  is "$code/$last" "64/E2E: ERROR shard 2/2: the app could not start the run (exit 64): an unknown selection or switch"
E2E_QUIET=1 FAKE_USAGE=a.two E2E_SHARDS=2 run shard
check "a shard that cannot start, short output: says why" says_some "^bow: --e2e=[a-z.,]*a\.two[a-z.,]* is not a test$"
list "a.two 2999-01-01 slow"
FAKE_FAIL=a.two E2E_SHARDS=2 run shard
check "a quarantined test flaky in a shard: a pass with the note" is "$code/$last" "0/E2E: PASS 5/5; quarantined flaky tests passed on the retry: a.two"
rm -f "$quarantine"

# Short output and repeats.
rroot shardquiet
E2E_QUIET=1 E2E_SHARDS=2 run shard
check "shards, short output on a pass: two lines" is "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 2
check "shards, short output on a pass: the summary" is "$last" "E2E: PASS 5/5"
E2E_QUIET=1 E2E_RETRY=0 FAKE_CHROMIUM=a.two E2E_SHARDS=2 run shard
check "shards, short output on a failure: the FAIL line" says_some "^FAIL chromium.errors: shard 1/2"
check "shards, short output on a failure: the echoed ERROR line once" is "$(printf '%s\n' "$out" | grep -c 'ERROR:fake.cc')" 1
check "shards, short output on a failure: nothing else" is "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 4
check "shards, short output leaves no file of its own" is "$(find "$BOW_E2E_ROOT" -name '.shard-*' -o -name .output | wc -l | tr -d ' ')" 0
rroot shardrepeat
E2E_REPEAT=2 E2E_SHARDS=2 run shard
check "shards with repeats: every repeat passes" is "$code/$last" "0/E2E: PASS 2/2 repeats"
check "shards with repeats: each test's passes" says "REPEAT a.three 2/2"
check "shards with repeats: one run per repeat" is "$(runs_in)" 2
check "shards: the flake count counts a sharded run once" \
  is "$(./scripts/e2e-flakes.sh "$BOW_E2E_ROOT" | awk '$1 == "a.two" { print $2, $3 }')" "2 2"
}

group_signals() {
for sig in TERM INT; do
  interrupt "$sig"
  check "$sig: the wrapper stops at once" is "$stopped" yes
  check "$sig: exit 130" is "$code" 130
  check "$sig: summary" is "$last" "E2E: ERROR interrupted"
  check "$sig: results.json is valid JSON" valid_json "$res"
  check "$sig: report.txt gets the line" has "$iroot/latest/report.txt" "^E2E: ERROR interrupted"
  check "$sig: results.json says interrupted" is "$(field "$res" status)" interrupted
  check "$sig: the app and its helper are ended" is "$(ps -axo command= | grep -F -- "$iroot/" | grep -vc grep)" 0
  check "$sig: the build lock slot is given back" is "$(ls "$BOW_LOCK_DIR/e2e/slots" | wc -l | tr -d ' ')" 0
done
# A signal during a repeat ends that repeat's app and helpers and stops the repeats after it.
for quiet in 0 1; do
  E2E_QUIET=$quiet E2E_REPEAT=3 interrupt TERM repeathang 100 hanging
  check "TERM during a repeat (quiet=$quiet): the wrapper stops at once" is "$stopped" yes
  check "TERM during a repeat (quiet=$quiet): exit 130" is "$code" 130
  check "TERM during a repeat (quiet=$quiet): summary" is "$last" "E2E: ERROR interrupted"
  check "TERM during a repeat (quiet=$quiet): the repeat's results.json says interrupted" is "$(field "$res" status)" interrupted
  check "TERM during a repeat (quiet=$quiet): no later repeat runs" is "$(find "$iroot" -mindepth 2 -maxdepth 2 -name report.txt | wc -l | tr -d ' ')" 2
  check "TERM during a repeat (quiet=$quiet): the app and its helper are ended" is "$(ps -axo command= | grep -F -- "$iroot/" | grep -vc grep)" 0
  check "TERM during a repeat (quiet=$quiet): the build lock slot is given back" is "$(ls "$BOW_LOCK_DIR/e2e/slots" | wc -l | tr -d ' ')" 0
  check "TERM during a repeat (quiet=$quiet): no file of its own left" is "$(find "$iroot" -name '.repeat.*' -o -name .output | wc -l | tr -d ' ')" 0
  rm -rf "$iroot"
done
}

group_signals_shards() {
# A signal while shards run stops every shard, its app and its helper, in both output modes.
for case in TERM:0 TERM:1 INT:0; do
  sig=${case%:*} quiet=${case#*:}
  E2E_QUIET=$quiet E2E_SHARDS=2 FAKE_HANG=1 interrupt "$sig" shard 150 latest/shard-2/hanging
  check "$sig during shards (quiet=$quiet): the wrapper stops at once" is "$stopped" yes
  check "$sig during shards (quiet=$quiet): exit 130 and the summary" is "$code/$last" "130/E2E: ERROR interrupted"
  check "$sig during shards (quiet=$quiet): results.json says interrupted" is "$(field "$res" status)" interrupted
  check "$sig during shards (quiet=$quiet): each shard's results.json says interrupted" \
    is "$(field "$iroot/latest/shard-1/results.json" status)/$(field "$iroot/latest/shard-2/results.json" status)" interrupted/interrupted
  check "$sig during shards (quiet=$quiet): every app and helper is ended" is "$(ps -axo command= | grep -F -- "$iroot/" | grep -vc grep)" 0
  check "$sig during shards (quiet=$quiet): every build lock slot is given back" is "$(ls "$BOW_LOCK_DIR/e2e/slots" | wc -l | tr -d ' ')" 0
  check "$sig during shards (quiet=$quiet): no file of its own left" is "$(find "$iroot" -name '.shard-*' -o -name .output | wc -l | tr -d ' ')" 0
  rm -rf "$iroot"
done
}

group_signals_stuck() {
# An app that ignores TERM is swept after 5 seconds, so the build lock still ends and gives back its slot.
interrupt TERM hangterm 200
check "an app that ignores TERM: the wrapper stops" is "$stopped" yes
check "an app that ignores TERM: exit 130" is "$code" 130
check "an app that ignores TERM: the app is ended" is "$(ps -axo command= | grep -F -- "$iroot/" | grep -vc grep)" 0
check "an app that ignores TERM: the build lock slot is given back" is "$(ls "$BOW_LOCK_DIR/e2e/slots" | wc -l | tr -d ' ')" 0
check "an app that ignores TERM: no build lock ticket is left" is "$(ls "$BOW_LOCK_DIR/e2e/queue" | wc -l | tr -d ' ')" 0

# A signal while the wrapper lists tests (the app's list hangs) or sweeps processes (the first ps takes 5 seconds)
# stops it at once, not after that command ends, and the summary is still the last line on the terminal, not in the
# file the list's output goes to. (A regression guard: the stop alone passed before the summary moved to the real
# stdout; the `last` checks are what tell old from new.)
interrupt TERM listhang 30 latest/list.txt
check "a signal while listing tests: the wrapper stops at once" is "$stopped" yes
check "a signal while listing tests: exit 130" is "$code" 130
check "a signal while listing tests: the summary is the last terminal line" is "$last" "E2E: ERROR interrupted"
check "a signal while listing tests: the summary is not in the list file" not has "$iroot/latest/list.txt" "E2E: ERROR interrupted"
mkdir -p "$tmp/slowps"
printf '#!/bin/sh\n[ "$1" = -axo ] && [ ! -e "%s/ps-mark" ] && { echo x > "%s/ps-mark"; sleep 5; }\nexec /bin/ps "$@"\n' "$tmp" "$tmp" > "$tmp/slowps/ps"
chmod +x "$tmp/slowps/ps"
ipath="$tmp/slowps:$PATH" interrupt TERM pass 30 ../ps-mark
check "a signal while sweeping: the wrapper stops at once" is "$stopped" yes
check "a signal while sweeping: exit 130" is "$code" 130
check "a signal while sweeping: the summary is the last terminal line" is "$last" "E2E: ERROR interrupted"
}

group_locks() {
# is_build_lock refuses a process that is not exactly this run's build lock: one for the same repo whose run folder
# differs only by a suffix ($run against $run/retry), and one from another repo path. The function is taken from the
# wrapper as written.
ibl="$tmp/ibl"
mkdir -p "$ibl/repo/scripts" "$ibl/other/scripts"
for d in repo other; do
  printf '#!/bin/bash\nsleep 30 &\nwait\n' > "$ibl/$d/scripts/build-lock.sh"
  chmod +x "$ibl/$d/scripts/build-lock.sh"
done
"$ibl/repo/scripts/build-lock.sh" --pool e2e x "--e2e-out=$ibl/run" & ibl_run=$!
"$ibl/repo/scripts/build-lock.sh" --pool e2e x "--e2e-out=$ibl/run/retry" & ibl_retry=$!
"$ibl/other/scripts/build-lock.sh" --pool e2e x "--e2e-out=$ibl/run" & ibl_other=$!
sleep 0.5
eval "$(sed -n '/^is_build_lock() {/,/^}/p' scripts/e2e.sh)"
repo="$ibl/repo"
current="$ibl/run"
check "is_build_lock: accepts this run's build lock" is_build_lock "$ibl_run"
check "is_build_lock: refuses the same command for a run folder that differs by a suffix" not is_build_lock "$ibl_retry"
current="$ibl/run/retry"
check "is_build_lock: refuses a shorter run folder when the current one is longer" not is_build_lock "$ibl_run"
check "is_build_lock: accepts the retry's own build lock" is_build_lock "$ibl_retry"
current="$ibl/run"
check "is_build_lock: refuses a build lock of another repo path" not is_build_lock "$ibl_other"
kill "$ibl_run" "$ibl_retry" "$ibl_other" 2>/dev/null
wait "$ibl_run" "$ibl_retry" "$ibl_other" 2>/dev/null

# The final KILL guard: a build lock that ignores TERM is killed only when it is this run's, matched exactly. A copy
# of the wrapper beside a stand-in build lock does it.
kl="$tmp/kl"
mkdir -p "$kl/scripts"
cp scripts/e2e.sh "$kl/scripts/e2e.sh"
printf '#!/bin/bash\ntrap "" TERM\nshift 2\n"$@"\nwhile :; do sleep 1; done\n' > "$kl/scripts/build-lock.sh"
chmod +x "$kl/scripts/build-lock.sh"
iroot="$tmp/int-kill"
BOW_E2E_ROOT=$iroot FAKE_MODE=hangterm perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' "$kl/scripts/e2e.sh" "$app" > "$tmp/int-kill.out" 2>&1 &
kpid=$!
for i in $(seq 300); do [ -s "$iroot/latest/report.txt" ] && break; sleep 0.1; done
kill -TERM "$kpid"
stopped=no
for i in $(seq 200); do kill -0 "$kpid" 2>/dev/null || { stopped=yes; break; }; sleep 0.1; done
[ "$stopped" = yes ] || { kill -KILL "$kpid" 2>/dev/null; pkill -KILL -f "$kl/scripts/build-lock.sh" 2>/dev/null; }
wait "$kpid" 2>/dev/null
check "a build lock that ignores TERM: the wrapper stops" is "$stopped" yes
check "a build lock that ignores TERM: it is killed" is "$(ps -axo command= | grep -F -- "$kl/scripts/build-lock.sh" | grep -vc grep)" 0
}

group_make_package() {
# The Makefile keeps E2E out of every recipe's environment (xcodebuild takes environment variables as build
# settings), and e2e and e2e-run hand it to the wrapper whole.
nomake() { env -u MAKEFLAGS -u MAKELEVEL -u MFLAGS "$@"; }
printf 'print-e2e-env:\n\t@echo "E2E=$${E2E-unset}"\n' > "$tmp/env.mk"
check "make: E2E stays out of other recipes' environment" \
  is "$(E2E=env nomake make -s -f Makefile -f "$tmp/env.mk" print-e2e-env E2E=cli)" "E2E=unset"
FAKE_MODE=pass nomake make -s e2e-run APP="$app" BUILD_DIR="$tmp/mk" E2E="it's, a" > /dev/null 2>&1
check "make e2e-run hands the selection to the wrapper whole" is "$(cat "$tmp/mk/e2e/latest/args" 2>/dev/null)" "e2e=it's, a"
check "make e2e-run passes E2E_REPEAT on" \
  is "$(FAKE_MODE=loudpass nomake make -s e2e-run APP="$app" BUILD_DIR="$tmp/mkr" E2E_REPEAT=2 2>&1 | tail -n 1)" "E2E: PASS 2/2 repeats"
FAKE_MODE=shard nomake make -s e2e-run APP="$app" BUILD_DIR="$tmp/mks" E2E_SHARDS=2 > /dev/null 2>&1
check "make e2e-run passes E2E_SHARDS on" is "$(find "$tmp/mks/e2e/latest/" -mindepth 1 -maxdepth 1 -name 'shard-*' | wc -l | tr -d ' ')" 2

# package-cef.sh on a fake CEF build and helper: an unchanged build skips the work, and a change to the
# framework's Libraries or Resources does not.
pc="$tmp/pc"
fw="$pc/src/Vendor/cef/Release/Chromium Embedded Framework.framework"
helper="$pc/products/Bow Helper.app/Contents"
mkdir -p "$fw/Libraries" "$fw/Resources/en.lproj" "$helper/MacOS" "$pc/temp"
cp /usr/bin/true "$fw/Chromium Embedded Framework"
cp /usr/bin/true "$helper/MacOS/Bow Helper"
echo lib > "$fw/Libraries/libEGL.dylib"
echo pak > "$fw/Resources/en.lproj/locale.pak"
plist() { # plist <file> <executable> <identifier> <package type>
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>%s</string><key>CFBundleIdentifier</key><string>%s</string><key>CFBundleName</key><string>%s</string><key>CFBundlePackageType</key><string>%s</string></dict></plist>\n' "$2" "$3" "$2" "$4" > "$1"
}
plist "$fw/Resources/Info.plist" "Chromium Embedded Framework" org.example.cef FMWK
plist "$helper/Info.plist" "Bow Helper" org.example.helper APPL
package() {
  TARGET_BUILD_DIR="$pc/products" WRAPPER_NAME=Bow.app SRCROOT="$pc/src" BUILT_PRODUCTS_DIR="$pc/products" \
    TARGET_TEMP_DIR="$pc/temp" ./scripts/package-cef.sh 2>&1
}
skips() { package | grep -q "unchanged; skipping"; }
package > "$tmp/package.out"
check "package-cef: packages a fake CEF build" is "$(cat "$pc/products/Bow.app/Contents/Frameworks/Chromium Embedded Framework.framework/Resources/en.lproj/locale.pak" 2>/dev/null)" pak
check "package-cef: an unchanged build skips the copy" skips
echo more >> "$fw/Resources/en.lproj/locale.pak"
check "package-cef: a changed Resources file is copied again" not skips
echo more >> "$fw/Libraries/libEGL.dylib"
check "package-cef: a changed Libraries file is copied again" not skips
package > /dev/null
mkdir -p "$pc/real"
echo one > "$pc/real/target.dylib"
ln -s "$pc/real/target.dylib" "$fw/Libraries/libLink.dylib"
package > /dev/null
check "package-cef: a symlinked file is part of the stamp" skips
sleep 1
echo two >> "$pc/real/target.dylib"
check "package-cef: a changed symlink target is copied again" not skips

# A test killed while a folder of its run was locked: pruning unlocks it rather than keep the run forever.
rroot prune
run pass
run pass
run pass
oldest=$(cd "$BOW_E2E_ROOT" && ls -1t | grep -v '^latest$' | tail -n 1)
mkdir -p "$BOW_E2E_ROOT/$oldest/profile/locked" && touch "$BOW_E2E_ROOT/$oldest/profile/locked/file"
chmod 000 "$BOW_E2E_ROOT/$oldest/profile/locked"
touch -t 200001010000 "$BOW_E2E_ROOT/$oldest"  # still the oldest run, as making the folder changed its time
E2E_KEEP=3 run pass
check "prunes a run with a locked folder" not test -e "$BOW_E2E_ROOT/$oldest"
check "keeps the newest E2E_KEEP runs" is "$(find "$BOW_E2E_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" 3

check "list: passes the TEST lines through" is "$(FAKE_MODE=pass ./scripts/e2e.sh "$app" list | head -n 1)" "TEST a.one area=a tags=- checks=a.one"

check "no build: exit 64" is "$(./scripts/e2e.sh "$tmp/none.app" >/dev/null 2>&1; echo $?)" 64
}

group_ledger() {
# The ledger (BOW_E2E_LEDGER): every run appends one line per test, from any worktree. Two throwaway git repositories
# with their own copy of the scripts, branch and tree stand in for two worktrees.
: > "$quarantine"
fakewt one
fakewt two
rm -f "$BOW_E2E_LEDGER"
check "ledger: a flaky run in the first worktree exits 3" is "$(wtrun one flakyresult)" 3
check "ledger: a flaky run in the second worktree exits 3" is "$(wtrun two flakyresult)" 3
check "ledger: the header comes once, on a new file" \
  is "$(head -n 1 "$BOW_E2E_LEDGER")|$(grep -c '^date' "$BOW_E2E_LEDGER")" "date	test	outcome	branch	tree	load	shard	run|1"
check "ledger: a line per test per run with its 8 fields" \
  is "$(awk -F '\t' 'NR > 1 && NF == 8 && $2 == "a.one" && $3 == "FLAKY" { n++ } END { print n + 0 "/" NR - 1 }' "$BOW_E2E_LEDGER")" "2/2"
check "ledger: each line names its worktree's branch" is "$(awk -F '\t' 'NR > 1 { print $4 }' "$BOW_E2E_LEDGER" | paste -sd, -)" "one,two"
check "ledger: each line names its worktree's tree" \
  is "$(awk -F '\t' 'NR > 1 { print $5 }' "$BOW_E2E_LEDGER" | paste -sd, -)" \
  "$(git -C "$tmp/wt-one" rev-parse 'HEAD^{tree}'),$(git -C "$tmp/wt-two" rev-parse 'HEAD^{tree}')"
check "ledger: the date is UTC ISO 8601" \
  is "$(awk -F '\t' 'NR == 2 { print ($1 ~ /^[0-9]{4}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/) ? "ok" : $1 }' "$BOW_E2E_LEDGER")" ok
check "ledger: an unsharded run has no shard" is "$(awk -F '\t' 'NR == 2 { print $7 }' "$BOW_E2E_LEDGER")" "-"
# The first worktree is deleted: its runs stay in the flake count.
rm -rf "$tmp/wt-one" "$tmp/wt-one-runs"
flakes=$(./scripts/e2e-flakes.sh)
check "ledger: the flake count still has the deleted worktree's run" \
  is "$(printf '%s\n' "$flakes" | awk '$1 == "a.one" { print $2, $3, $4, $5, $6, $7, $8 }')" "2 0 2 0 0 2 FILE"
check "ledger: the flake count names the runs and branches" \
  is "$(printf '%s\n' "$flakes" | tail -n 1)" "e2e-flakes: 2 runs on 2 branches in the last 7 days; 1 to file"
check "ledger: a flake run's own results.json still counts through --local" \
  is "$(./scripts/e2e-flakes.sh --local "$tmp/wt-two-runs" | awk '$1 == "a.one" { print $2, $4 }')" "1 1"
# A quarantined flake keeps its own name.
printf '%s\n' "a.one 2999-01-01 slow under load" > "$quarantine"
check "ledger: a quarantined flake exits 0" is "$(wtrun two flakyresult)" 0
check "ledger: a quarantined flake is QUARANTINED-FLAKY" is "$(tail -n 1 "$BOW_E2E_LEDGER" | cut -f 2,3)" "a.one	QUARANTINED-FLAKY"
: > "$quarantine"
check "ledger: a failing run is FAIL" is "$(wtrun two loudfail)" 1
check "ledger: a failing run's line" is "$(tail -n 1 "$BOW_E2E_LEDGER" | cut -f 2,3)" "a.one	FAIL"
check "ledger: a passing run is PASS" is "$(wtrun two loudpass)" 0
check "ledger: a passing run's line" is "$(tail -n 1 "$BOW_E2E_LEDGER" | cut -f 2,3)" "a.one	PASS"
check "ledger: the FAIL then PASS on the same tree counts as an event" \
  is "$(./scripts/e2e-flakes.sh | awk '$1 == "a.one" { print $2, $3, $4, $5, $7, $8 }')" "5 1 3 1 4 FILE"
# Parallel writers never interleave a line.
rm -f "$BOW_E2E_LEDGER"
fakewt three
for i in 1 2 3 4 5 6; do wtrun three twoflaky > /dev/null & done
wait
check "ledger: parallel runs write whole lines" \
  is "$(awk -F '\t' 'NR > 1 && NF != 8 { bad++ } END { print bad + 0 "/" NR - 1 "/" (NR - 1) / 2 }' "$BOW_E2E_LEDGER")" "0/12/6"
check "ledger: parallel runs write one header" is "$(grep -c '^date' "$BOW_E2E_LEDGER")" 1
}

group_ledger_stale() {
: > "$quarantine"
fakewt three
rm -f "$BOW_E2E_LEDGER"
# The tree key is the one stamped when the app was built, not the tree checked out when the run happens (make
# e2e-run reruns an older build). Stamped on tree A, then the tree changes to B: a run without a build logs A.
fakewt stale
rm -f "$BOW_E2E_LEDGER" "$tmp/.bow-tree-key"
treea=$(git -C "$tmp/wt-stale" rev-parse 'HEAD^{tree}')
(cd "$tmp/wt-stale" && ./scripts/stamp-tree.sh "$tmp/.bow-tree-key" true)
check "ledger: a build stamps the tree key beside the app" is "$(cat "$tmp/.bow-tree-key")" "$treea"
echo changed > "$tmp/wt-stale/marker"
(cd "$tmp/wt-stale" && FAKE_MODE=loudfail BOW_E2E_ROOT="$tmp/wt-stale-runs" ./scripts/e2e.sh "$app" a.one > /dev/null 2>&1)
check "ledger: a run without a build logs the stamped tree, not the one checked out now" \
  is "$(tail -n 1 "$BOW_E2E_LEDGER" | cut -f 3,5)" "FAIL	$treea"
# The fix is built (stamped on the dirty tree B) and passes: B differs from A, so A's FAIL is no flake event.
(cd "$tmp/wt-stale" && ./scripts/stamp-tree.sh "$tmp/.bow-tree-key" true)
(cd "$tmp/wt-stale" && FAKE_MODE=loudpass BOW_E2E_ROOT="$tmp/wt-stale-runs" ./scripts/e2e.sh "$app" a.one > /dev/null 2>&1)
check "ledger: a pass on the rebuilt tree is no later pass of the stale binary's fail" \
  is "$(./scripts/e2e-flakes.sh | awk '$1 == "a.one" { print $2, $3, $4, $5, $7 }')" "2 1 0 1 0"
# No stamp (an old build), a build whose tree changed while it ran and a failed build: the key is unknown, and an
# unknown FAIL never counts as passed later on the same unknown tree.
rm -f "$tmp/.bow-tree-key"
(cd "$tmp/wt-stale" && FAKE_MODE=loudfail BOW_E2E_ROOT="$tmp/wt-stale-runs" ./scripts/e2e.sh "$app" a.one > /dev/null 2>&1)
(cd "$tmp/wt-stale" && FAKE_MODE=loudpass BOW_E2E_ROOT="$tmp/wt-stale-runs" ./scripts/e2e.sh "$app" a.one > /dev/null 2>&1)
check "ledger: a run with no stamp logs the tree as unknown" is "$(tail -n 2 "$BOW_E2E_LEDGER" | cut -f 3,5 | paste -sd, -)" "FAIL	unknown,PASS	unknown"
check "ledger: an unknown tree is never a later pass" \
  is "$(./scripts/e2e-flakes.sh | awk '$1 == "a.one" { print $2, $3, $4, $5, $7 }')" "4 2 0 2 0"
(cd "$tmp/wt-stale" && ./scripts/stamp-tree.sh "$tmp/.bow-tree-key" sh -c 'echo moved > marker')
check "ledger: a tree that changed while the build ran is stamped unknown" is "$(cat "$tmp/.bow-tree-key")" unknown
(cd "$tmp/wt-stale" && ./scripts/stamp-tree.sh "$tmp/.bow-tree-key" false)
check "ledger: a failed build leaves no stamp" is "$([ -e "$tmp/.bow-tree-key" ] && echo stamp || echo none)" none
# A ledger that cannot be written warns on stderr and changes nothing about the run.
touch "$tmp/notafolder"
res=$(cd "$tmp/wt-three" && FAKE_MODE=flakyresult BOW_E2E_LEDGER="$tmp/notafolder/ledger.tsv" BOW_E2E_ROOT="$tmp/wt-three-runs" \
  ./scripts/e2e.sh "$app" a.one 2> "$tmp/ledger-stderr" | tail -n 1; echo "${PIPESTATUS[0]}")
check "ledger: an unwritable ledger leaves the summary alone" is "$(printf '%s\n' "$res" | head -n 1)" "E2E: FLAKY 1/1 after retrying a.one"
check "ledger: an unwritable ledger leaves the exit code alone" is "$(printf '%s\n' "$res" | tail -n 1)" 3
check "ledger: an unwritable ledger warns on stderr" has "$tmp/ledger-stderr" "^e2e: warning: could not write the e2e ledger"
}

group_threshold() {
: > "$quarantine"
# The threshold: a FLAKY, or a FAIL or TIMEOUT on a tree that the same test later passed, twice or more in 7 days.
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
old=$(date -u -v-10d +%Y-%m-%dT%H:%M:%SZ)
before=$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)
fake="$tmp/fake-ledger.tsv"
{
  printf 'date\ttest\toutcome\tbranch\ttree\tload\tshard\trun\n'
  row() { printf '%s\t%s\t%s\tb\t%s\t1.00\t-\tr\n' "$1" "$2" "$3" "$4"; }
  row "$before" t.fixed FAIL aaa; row "$now" t.fixed PASS aaa; row "$before" t.fixed TIMEOUT bbb; row "$now" t.fixed PASS bbb
  row "$before" t.broken FAIL aaa; row "$before" t.broken FAIL bbb; row "$now" t.broken PASS ccc
  row "$old" t.old FLAKY aaa; row "$old" t.old FLAKY bbb
  row "$now" t.once FLAKY aaa; row "$now" t.once PASS bbb
  row "$before" t.twice FLAKY aaa; row "$now" t.twice QUARANTINED-FLAKY bbb
  printf 'garbage line\n'
} > "$fake"
tr_row() { ./scripts/e2e-flakes.sh --ledger "$fake" "${@:2}" | awk -v t="$1" '$1 == t { print $2, $7, $8 }'; }
check "threshold: a FAIL and a TIMEOUT that later passed on their trees are 2 events: FILE" is "$(tr_row t.fixed)" "4 2 FILE"
check "threshold: FAILs a later tree fixed are no events" is "$(tr_row t.broken)" "3 0 -"
check "threshold: a flake older than the window is not counted" is "$(tr_row t.old)" ""
check "threshold: --days widens the window" is "$(tr_row t.old --days 30)" "2 2 FILE"
check "threshold: one FLAKY is not enough" is "$(tr_row t.once)" "2 1 -"
check "threshold: a FLAKY and a QUARANTINED-FLAKY are 2 events: FILE" is "$(tr_row t.twice)" "2 2 FILE"
check "threshold: no ledger exits 1" not ./scripts/e2e-flakes.sh --ledger "$tmp/missing.tsv" 2> /dev/null
printf 'date\ttest\toutcome\tbranch\ttree\tload\tshard\trun\n%s\tt.old\tFLAKY\tb\taaa\t1.00\t-\tr\n' "$old" > "$tmp/oldonly.tsv"
check "threshold: a window with no line exits 1" not ./scripts/e2e-flakes.sh --ledger "$tmp/oldonly.tsv" 2> /dev/null
check "threshold: --days 00 exits 64" is "$(./scripts/e2e-flakes.sh --days 00 > /dev/null 2>&1; echo $?)" 64
check "threshold: --days with --local exits 64" is "$(./scripts/e2e-flakes.sh --days 3 --local > /dev/null 2>&1; echo $?)" 64
# An untracked file gives the tree its own key, so a fail fixed by adding one is not a flake.
fakewt four
wtrun four loudpass > /dev/null
touch "$tmp/wt-four/newfile"
wtrun four loudpass > /dev/null
check "ledger: an untracked file changes the tree key" \
  is "$(tail -n 2 "$BOW_E2E_LEDGER" | cut -f 5 | sort -u | wc -l | tr -d ' ')" 2
check "threshold: a bad --days exits 64" is "$(./scripts/e2e-flakes.sh --days x > /dev/null 2>&1; echo $?)" 64
}

group_crash_reports() {
# Crash reports: copied into the run folder, named before the summary, in results.json, outcome unchanged.
run crashdump
runf="$BOW_E2E_ROOT/latest"
check "crash reports: the run's outcome stays FLAKY" is "$code" 3
check "crash reports: the summary stays the last line" is "$last" "E2E: FLAKY 1/1 after retrying a.one"
check "crash reports: Crashpad's reports are copied into crash-reports" is "$(ls "$runf/crash-reports" | tr '\n' ' ')" "aaa.dmp aaa.meta bbb.dmp ccc.dmp "
check "crash reports: the copy has the report's content" is "$(cat "$runf/crash-reports/bbb.dmp")" dump2
check "crash reports: the .meta file comes with its report" is "$(cat "$runf/crash-reports/aaa.meta")" meta1
check "crash reports: a non report file is left" not test -e "$runf/crash-reports/note.txt"
check "crash reports: one line per report, the same name once" is "$(grep -c '^CRASH REPORT ' "$runf/report.txt")" 6
check "crash reports: the line names the path" has "$runf/report.txt" "^CRASH REPORT $(field "$res" run)/crash-reports/aaa.dmp\$"
check "crash reports: the retry's report is named too" has "$runf/report.txt" "^CRASH REPORT $(field "$res" run)/retry/crash-reports/bbb.dmp\$"
check "crash reports: printed before the summary" is "$(echo "$out" | grep -c '^CRASH REPORT ')" 6
check "crash reports: results.json is valid JSON" valid_json "$res"
check "crash reports: results.json lists them" is "$(field "$res" crashReports.0)" "$(field "$res" run)/crash-reports/aaa.dmp"
check "crash reports: results.json lists the retry's" is "$(field "$res" crashReports.5)" "$(field "$res" run)/retry/crash-reports/ccc.dmp"
E2E_QUIET=1 run crashdump
check "crash reports: short output keeps the lines" is "$(echo "$out" | grep -c '^CRASH REPORT ')" 6
run pass
check "crash reports: none, no line" not has "$BOW_E2E_ROOT/latest/report.txt" "^CRASH REPORT"
check "crash reports: none, an empty list" is "$(plutil -extract crashReports raw -o - "$res" 2>/dev/null)" 0
E2E_SHARDS=2 FAKE_DUMP=1 run shard
check "crash reports: sharded, each shard's report is named once" is "$(grep -c '^CRASH REPORT ' "$BOW_E2E_ROOT/latest/report.txt")" 2
check "crash reports: sharded, copied into the shard's folder" is "$(ls "$BOW_E2E_ROOT"/latest/shard-*/crash-reports/*.dmp | wc -l | tr -d ' ')" 2
check "crash reports: sharded, results.json lists both" is "$(plutil -extract crashReports raw -o - "$res")" 2
}

"group_${group//-/_}"
exit "$failed"
