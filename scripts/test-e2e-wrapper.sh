#!/bin/bash
# Tests scripts/e2e.sh with a fake Bow.app (a shell script) in a throwaway folder: the summary line, exit codes,
# results.json, the retry and FLAKY, crash classification, the helper sweep, --only and build/e2e/latest, repeats
# (E2E_REPEAT), short output (E2E_QUIET, CLAUDECODE) and the flake count (scripts/e2e-flakes.sh).
# Takes a few seconds and launches no real app.
set -u
cd "$(dirname "$0")/.."

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
  for t in a.one a.two a.three; do echo "TEST $t area=a tags=- checks=$t"; done
  exit 0
fi
# Records the selection each attempt got.
[ -z "$out" ] || echo "e2e=$sel" > "$out/args"
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

# E2E_REPEAT: whole runs in their own folders with the retry off, each test's passes out of N, one summary line.
# Each group of checks uses its own run root, so the fake app's run count starts at 1.
rroot() { export BOW_E2E_ROOT="$tmp/repeat-$1"; }
says() { printf '%s\n' "$out" | grep -qx -- "$1"; }
says_some() { printf '%s\n' "$out" | grep -q -- "$1"; }
runs_in() { find "$BOW_E2E_ROOT" -mindepth 2 -maxdepth 2 -name results.json | wc -l | tr -d ' '; }
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

# The quarantine list (E2E_QUARANTINE): a FLAKY run whose every failure is a listed, unexpired test passes with a
# note; anything else fails as before, an expired entry is named on every run, and a malformed list stops the run.
rroot qmain
list() { printf '%s\n' "$@" > "$quarantine"; }
today=$(date +%Y-%m-%d)
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
oldest=$(cd "$BOW_E2E_ROOT" && ls -1t | grep -v '^latest$' | tail -n 1)
mkdir -p "$BOW_E2E_ROOT/$oldest/profile/locked" && touch "$BOW_E2E_ROOT/$oldest/profile/locked/file"
chmod 000 "$BOW_E2E_ROOT/$oldest/profile/locked"
touch -t 200001010000 "$BOW_E2E_ROOT/$oldest"  # still the oldest run, as making the folder changed its time
E2E_KEEP=3 run pass
check "prunes a run with a locked folder" not test -e "$BOW_E2E_ROOT/$oldest"
check "keeps the newest E2E_KEEP runs" is "$(find "$BOW_E2E_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" 3

check "list: passes the TEST lines through" is "$(FAKE_MODE=pass ./scripts/e2e.sh "$app" list | head -n 1)" "TEST a.one area=a tags=- checks=a.one"

check "no build: exit 64" is "$(./scripts/e2e.sh "$tmp/none.app" >/dev/null 2>&1; echo $?)" 64

[ "$failed" = 0 ] && echo "e2e wrapper: all checks passed" || echo "e2e wrapper: some checks failed"
exit "$failed"
