#!/bin/bash
# Tests scripts/e2e.sh with a fake Bow.app (a shell script) in a throwaway folder: the summary line, exit codes,
# results.json, the retry and FLAKY, crash classification, the helper sweep, --only and build/e2e/latest.
# Takes a few seconds and launches no real app.
set -u
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export BOW_E2E_ROOT="$tmp/runs" BOW_LOCK_DIR="$tmp/lock"
app="$tmp/Bow.app"
mkdir -p "$app/Contents/MacOS"
# The fake app reads FAKE_MODE and writes report.txt into its --e2e-out folder like the real runner.
cat > "$app/Contents/MacOS/Bow" <<'EOF'
#!/bin/bash
out="" only=""
for a in "$@"; do
  case $a in --e2e-out=*) out=${a#--e2e-out=} ;; --only=*) only=${a#--only=} ;; esac
done
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
    perl -e 'sleep 60' -- "$out/helper" &
    echo "PASS a.one: ok" > "$r"; echo "E2E: PASS 1/1" >> "$r"; exit 0 ;;
  only)
    echo "only=$only" >> "$out/args"
    if [ "$only" = "a.two" ]; then
      { echo "PASS a.two: ok"; echo "TEST PASS a.two"; echo "E2E: PASS 1/1"; } > "$r"; exit 0
    fi
    { echo "PASS a.one: ok"; echo "TEST PASS a.one"; echo "FAIL a.two: \"quoted\" reason"; echo "TEST FAIL a.two: \"quoted\" reason"
      echo "E2E: FAIL 1/2"; } > "$r"; exit 1 ;;
esac
EOF
chmod +x "$app/Contents/MacOS/Bow"

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
check "usage: summary" is "$last" "E2E: ERROR the app could not start the run (exit 64)"

run orphan
check "orphan: exit 0" is "$code" 0
check "orphan: helper ended" is "$(pgrep -f -- "$BOW_E2E_ROOT/.*/helper" | wc -l | tr -d ' ')" 0
check "orphan: counted" is "$(field "$res" orphansKilled)" 1

run only 'a.*'
check "only: retries only the failed test" is "$(cat "$BOW_E2E_ROOT/latest/retry/args")" "only=a.two"
check "only: first run got the selection" is "$(cat "$BOW_E2E_ROOT/latest/args")" "only=a.*"
check "only: flaky exit 3" is "$code" 3
check "only: per-test lines in results.json" is "$(field "$res" attempts.0.tests.1.detail)" '"quoted" reason'
check "only: results.json is valid JSON" valid_json "$res"

run pass smoke
check "only: a runner without per-test lines is refused" is "$code" 64

E2E_KEEP=3 run pass
check "keeps the newest E2E_KEEP runs" is "$(find "$BOW_E2E_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" 3

check "no build: exit 64" is "$(./scripts/e2e.sh "$tmp/none.app" >/dev/null 2>&1; echo $?)" 64

[ "$failed" = 0 ] && echo "e2e wrapper: all checks passed" || echo "e2e wrapper: some checks failed"
exit "$failed"
