# The e2e harness

How `make e2e` runs, reports and fails.
AGENTS.md carries the short version: how to select tests, the exit codes that matter and where the run folder is.
Everything else is here.

The harness is compiled into Debug builds only, and this folder's README is a document, not a source: it is not part of the app bundle.

## Selecting and running tests

`make e2e`: build Debug and run the e2e tests in the real app (`make e2e E2E=app.quit` runs one).
`E2E` takes `all`, or a comma separated list of test names, areas (`tabs`, the part of a name before the first dot), globs (`'tabs.*'`) and tags (`smoke` marks one fast test per area, so `E2E=smoke` is a quick cross section); `E2E=list` prints one `TEST <name> area=<area> tags=<tags> checks=<checks>` line per test and runs nothing.
Agents use it, not `make smoke`, for "Done when" checks: the window stays off screen, the app never takes focus or shows in the Dock, the profile and settings are throwaway, the network is blocked, and it runs from any worktree, beside a normal Bow and while other worktrees build.
`make e2e-run` does the same without building, to rerun the last build (for example a test that looked like load).
`E2E=` goes to the app as one `--e2e=` value, and the app refuses a selection it does not know with exit 64.
A harness self test that ends its run on purpose (`selectedByNameOnly` in `E2ETest`, for example `engine.watchdog-tracking-loop`) runs only when the selection names it exactly: `all`, areas, globs and tags skip it, and `E2E=list` leaves it out.

## Run folder, report and results.json

Both run the app through `scripts/e2e.sh`, which writes `build/e2e/<run>/`, points `build/e2e/latest` at it and keeps the newest 20 runs (`E2E_KEEP`).
It prints one `PASS <check>` or `FAIL <check>: <reason>` line per check, one `RESULT <test> pass|fail|timeout seconds=<s> checks=<passed>/<n>` line per test, and a final `E2E: PASS n/n` (or `E2E: FAIL passed/n`) line, also saved in `build/e2e/<run>/report.txt`, and always ends with one summary line, also written with every check and test to `build/e2e/<run>/results.json` (with the commit, a dirty flag and the load average).
A `results.json` the app itself wrote stays beside it as `app-results.json`, and the wrapper's `results.json` does not embed it.

## Tests and checks

Each test declares its checks (`checks` in `E2ETest`, default its name), and a test that stops early still prints `FAIL <check>: not run` for the rest, so the total never depends on how far tests got; a check a test does not declare fails.
Record each check once per test: a check recorded again fails once, printing a FAIL line that overrides its PASS without changing the total, and so does the last recorded check when the test throws after recording every check (the RESULT line then carries `error="<step>: <reason>"`).
`e2e.isolation` and `chromium.errors` belong to the runner, and a test may not declare them.
A FAIL line names the step that failed, also for a test's own failed check.
Once a test ends, its app and pages refuse every action with an error, so work a timed-out step left running cannot drive the app; never swallow `CancellationError` or an `E2EError` with reason `.testEnded` in a test (rethrow both before a bare `catch`).
A step that runs past its limit fails its test with `TIMEOUT` in the reason, and the run goes on; waits (`E2EWaits`) give up shortly before the step's limit with what they saw last, and also work in hidden tabs.
Each test gets a fresh in-memory profile (`openWindow(at:)`; `profile: .appDefault` asks for the shared default profile), and afterwards the runner closes its windows and the `e2e.isolation` check fails if any browser, popups included, is left open.
`app.quit` (the test with `quitsApp`) always runs last and keeps its window, so quitting is timed with only that window open.
A failing test leaves `build/e2e/<run>/<test>/log.txt` (each step's duration and limit) and `fail.png`; the last test leaves `build/e2e/<run>/final.png`: its window, AppKit chrome and web content together, as evidence to look at, not to compare pixels.

## Timeouts, the retry and exit codes

When the main thread stops answering for 10 seconds (or engine start or quit hangs), the run prints `E2E: TIMEOUT <test>: <step> (...)` and `NOT RUN <test>` for each test left, writes a stack sample to `build/e2e/<run>/hang.txt`, and exits.
A failed or timed out run is retried once in a fresh app, in `build/e2e/<run>/retry/`: just the tests whose `RESULT` line failed or timed out and those left `NOT RUN`, or the whole selection when a failure is no test's (a failed `chromium.errors`, `e2e.isolation` or quit check, a timeout between tests), so FLAKY never hides a check that was not run again; a retry that cannot start leaves the first outcome (`E2E_RETRY=0` turns the retry off).
Exit codes of `scripts/e2e.sh` and their last lines (make itself exits 2 for any failure, so read the last line or `exitCode` in `results.json`):
0 `E2E: PASS n/n`; 1 `E2E: FAIL passed/n`, a check failed again on the retry; 2 `E2E: TIMEOUT <test>: <step>`, the main thread was stuck again; 3 `E2E: FLAKY ...`, failed then passed on the retry, which is not a pass: report it with the `FLAKY <test>` lines; 4 `E2E: CRASH exit=<code> ...`, the app ended without a summary line (a crash or Chromium's own watchdog); 64 `E2E: ERROR ...`, the run could not start (an unknown selection, no build, or the build lock refused it); 130 `E2E: ERROR interrupted`, Ctrl-C, TERM or HUP stopped the run at once, ending the app and its helpers, and `results.json` says only that (a run started in the background ignores Ctrl-C, so stop it with TERM).
When the retry fails the other way (a FAIL after a TIMEOUT, or the reverse), the last line names both, `<first> (retry: <second>)`, and the exit code is the first attempt's.
`FLAKY n/n` counts the whole selection; after a timeout that printed no total and a retry of some tests, it reads `E2E: FLAKY retried tests passed n/n ...`, since only those tests passed.

## Quarantine

`scripts/e2e-quarantine.txt` lists known flaky tests, one per line as `<test name> <YYYY-MM-DD expiry> <reason in plain words>` with `#` comments and no Plane IDs; an entry counts until its expiry date and has expired on that date.
When every test the retry passed is listed and unexpired, the run passes with exit 0: it prints a `QUARANTINED <test> (expires <date>): <reason>` line per test after the `FLAKY` lines, ends with `E2E: PASS n/n; quarantined flaky tests passed on the retry: <tests>`, and `results.json` keeps the tests in `flaky` (so `scripts/e2e-flakes.sh` still counts them FLAKY) and the entries in `quarantined`.
A failure that is no test's (`chromium.errors`, `e2e.isolation`, a timeout between tests), a stuck main thread on the first attempt, an unlisted or expired test, and a FAIL, TIMEOUT or crash on the retry still fail as above; a failed quit check counts as `app.quit`'s, and `E2E_REPEAT` runs with the retry off, so a listed test failing in a repeat still fails.
Every run names each expired entry with a `QUARANTINE EXPIRED <test>` line until it is removed or renewed, and a malformed list (a bad name or date, no reason, a duplicate, a run-wide check, a Plane ID) stops the run before it starts with `E2E: ERROR bad quarantine list: <file> line <n>: <why>` (exit 64).
Keep entries few and short lived, each with a filed flake item: fix the test, then remove its entry.

## Run folders left behind and cleanup

A failed run keeps its profile in the run folder.
After each run the wrapper ends any process left running with the run folder in its arguments (Chromium's helpers carry it), and says how many it ended.

## Repeats

`E2E_REPEAT=N` (`make e2e E2E=app.quit E2E_REPEAT=3`) runs the selection N times, each a whole run in its own folder with the retry off so no flake hides behind it, prints `REPEAT <test> <passes>/<N>` per test and ends with `E2E: PASS N/N repeats` (exit 0) or `E2E: FAIL <passed>/N repeats passed; failed: repeat <i> (<its summary>)` with the first failing repeat's kind and exit code; use it on a new test before landing it, with a small selection.

## Shards

`E2E_SHARDS=N` (`make e2e-run E2E_SHARDS=2`) splits the selection across N apps run at once, each a whole run of the wrapper with the retry off in `build/e2e/<run>/shard-<k>/` (its own report, `results.json`, `chromium.log`, profile and e2e slot), planned longest first onto the least loaded shard from each test's seconds in the newest `results.json` that has it (no history deals the tests out in test order); unset or 1 is the single run, `E2E=list` ignores it, and a single test or a selection the app's test list cannot resolve runs in one app.
The run folder gets one merged `report.txt` and `results.json` (with a `shards` list), where each run-wide check (`e2e.isolation`, `chromium.errors`) is one line naming every shard's result and failing if any failed, so totals, FAIL, FLAKY, NOT RUN, the quarantine list, short output, `E2E_REPEAT`, the summary line and the exit codes mean what they mean for a single run; the worst shard sets the outcome, a crash or error names its shard, and every shard's failed, timed out and not run tests go into one retry in one app (all of a shard's tests when it would rerun its whole selection).
A plan or a shard that would run a test twice or not at all stops the run with exit 64, and a signal stops every shard and its helpers.

## Flake history

`scripts/e2e-flakes.sh [run roots or run folders]` reads every `results.json` under `build/e2e/` (or the roots given) and prints per test its runs, passes, FLAKY, FAIL and TIMEOUT counts and its newest failed run, most failures first.

## Short output

In an agent's shell (`CLAUDECODE=1`, or `E2E_QUIET=1`; `E2E_QUIET=0` turns it off) the output is short: the FAIL, FLAKY, QUARANTINED, QUARANTINE EXPIRED, TIMEOUT and NOT RUN lines, the RESULT lines of failing tests, the echoed Chromium ERROR and FATAL lines only when a check failed, why a run could not start, one line naming the run folder and the summary line.
A person's output and the files written stay the same, so read `report.txt`, `results.json` and `chromium.log` in the named folder for the rest.

## Testing the wrapper

`make test-e2e-wrapper` tests the wrapper with a fake app.

## chromium.log

Everything the app and Chromium write to stderr goes to `build/e2e/<run>/chromium.log`, also after a timeout; it carries `E2E MARK` lines at each test's start, teardown and result, and a failed `chromium.errors` check writes `chromium-errors.txt` in the run folder.
After quitting (or timing out), the run echoes the lines that are not Chromium log lines and every Chromium ERROR or FATAL line; `chromium.errors` fails on any not listed as harmless in `E2E/Harness/E2EChromiumLog.swift`, whose header says what may be added.
When a run ends any other way than PASS or FAIL (a timeout, a crash, a failed engine start), `make e2e` prints the end of `chromium.log`.
