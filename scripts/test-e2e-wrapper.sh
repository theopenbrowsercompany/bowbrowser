#!/bin/bash
# Tests scripts/e2e.sh with a fake Bow.app (a shell script) in a throwaway folder: the summary line, exit codes,
# results.json, the retry and FLAKY, crash classification, the helper sweep, --only and build/e2e/latest.
# Takes a few seconds and launches no real app.
set -u
cd "$(dirname "$0")/.."

# The real path, as scripts/e2e.sh sees it, so the orphan check can match this run's folder exactly.
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
export BOW_E2E_ROOT="$tmp/runs" BOW_LOCK_DIR="$tmp/lock"
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
  for t in a.one a.two a.three; do echo "TEST $t area=a tags=- checks=$t"; done
  exit 0
fi
# Records the selection each attempt got.
[ -z "$out" ] || echo "e2e=$sel" > "$out/args"
r="$out/report.txt"
case $FAKE_MODE in
  pass) echo "PASS a.one: ok" > "$r"; echo "E2E: PASS 1/1" >> "$r"; exit 0 ;;
  fail) echo "FAIL a.one: broken" > "$r"; echo "E2E: FAIL 0/1" >> "$r"; exit 1 ;;
  timeout) echo "E2E: TIMEOUT a.one: open window" > "$r"; exit 2 ;;
  usage) echo "bow: --e2e=nope is not a test" >&2; exit 64 ;;
  crash) echo "PASS a.one: ok" > "$r"; kill -SEGV $$ ;;
  watchdog) echo "PASS a.one: ok" > "$r"; exit 2 ;;
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

# interrupt <signal> [mode] [tenths]: runs the wrapper on an app that never ends (FAKE_MODE hang), sends the signal
# once the app runs, and sets stopped (yes when the wrapper ended within tenths of a second, default 40), code, last,
# res and iroot.
interrupt() {
  local sig=$1 mode=${2:-hang} limit=${3:-40} i wpid
  iroot="$tmp/int-$sig-$mode"
  # perl gives the wrapper a default INT, as a terminal does: a background job of a script starts with INT ignored.
  BOW_E2E_ROOT=$iroot FAKE_MODE=$mode perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' ./scripts/e2e.sh "$app" \
    > "$tmp/int-$sig.out" 2>&1 &
  wpid=$!
  for i in $(seq 100); do [ -s "$iroot/latest/report.txt" ] && break; sleep 0.1; done
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
  check "$sig: results.json says interrupted" is "$(field "$res" status)" interrupted
  check "$sig: the app and its helper are ended" is "$(ps -axo command= | grep -F -- "$iroot/" | grep -vc grep)" 0
  check "$sig: the build lock slot is given back" is "$(ls "$BOW_LOCK_DIR/e2e/slots" | wc -l | tr -d ' ')" 0
done
# An app that ignores TERM is swept after 5 seconds, so the build lock still ends and gives back its slot.
interrupt TERM hangterm 120
check "an app that ignores TERM: the wrapper stops" is "$stopped" yes
check "an app that ignores TERM: exit 130" is "$code" 130
check "an app that ignores TERM: the app is ended" is "$(ps -axo command= | grep -F -- "$iroot/" | grep -vc grep)" 0
check "an app that ignores TERM: the build lock slot is given back" is "$(ls "$BOW_LOCK_DIR/e2e/slots" | wc -l | tr -d ' ')" 0
check "an app that ignores TERM: no build lock ticket is left" is "$(ls "$BOW_LOCK_DIR/e2e/queue" | wc -l | tr -d ' ')" 0

# The Makefile keeps E2E out of every recipe's environment (xcodebuild takes environment variables as build
# settings), and e2e and e2e-run hand it to the wrapper whole.
nomake() { env -u MAKEFLAGS -u MAKELEVEL -u MFLAGS "$@"; }
printf 'print-e2e-env:\n\t@echo "E2E=$${E2E-unset}"\n' > "$tmp/env.mk"
check "make: E2E stays out of other recipes' environment" \
  is "$(E2E=env nomake make -s -f Makefile -f "$tmp/env.mk" print-e2e-env E2E=cli)" "E2E=unset"
FAKE_MODE=pass nomake make -s e2e-run APP="$app" BUILD_DIR="$tmp/mk" E2E="it's, a" > /dev/null 2>&1
check "make e2e-run hands the selection to the wrapper whole" is "$(cat "$tmp/mk/e2e/latest/args" 2>/dev/null)" "e2e=it's, a"

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
not() { ! "$@"; }
package > "$tmp/package.out"
check "package-cef: packages a fake CEF build" is "$(cat "$pc/products/Bow.app/Contents/Frameworks/Chromium Embedded Framework.framework/Resources/en.lproj/locale.pak" 2>/dev/null)" pak
check "package-cef: an unchanged build skips the copy" skips
echo more >> "$fw/Resources/en.lproj/locale.pak"
check "package-cef: a changed Resources file is copied again" not skips
echo more >> "$fw/Libraries/libEGL.dylib"
check "package-cef: a changed Libraries file is copied again" not skips

E2E_KEEP=3 run pass
check "keeps the newest E2E_KEEP runs" is "$(find "$BOW_E2E_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" 3

check "list: passes the TEST lines through" is "$(FAKE_MODE=pass ./scripts/e2e.sh "$app" list | head -n 1)" "TEST a.one area=a tags=- checks=a.one"

check "no build: exit 64" is "$(./scripts/e2e.sh "$tmp/none.app" >/dev/null 2>&1; echo $?)" 64

[ "$failed" = 0 ] && echo "e2e wrapper: all checks passed" || echo "e2e wrapper: some checks failed"
exit "$failed"
