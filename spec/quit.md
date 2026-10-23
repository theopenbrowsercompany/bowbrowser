# Quitting

## Summary

Quitting closes every page and ends the app quickly and cleanly, however it was started.
People rely on it every day, and every automated run relies on the app exiting on its own with a meaningful exit code.

## Behavior

- Choosing Bow > Quit Bow or pressing Cmd+Q closes every window and the app exits with exit code 0.
  Quitting has two parts, both timed from the moment it starts:
  - closing: the app closes every page, ends its message loop and takes every window off screen at once, with no fade; this finishes within 2 seconds (it takes a few hundredths of a second), unless a page's "leave this page?" prompt is waiting for an answer;
  - shutting down: Chromium then stops its threads and helper processes, and the process exits right after.
    No window is left on screen during this part; only the Dock icon stays until the process exits, as in other Chromium browsers.
    On a machine that is not busy the quit is done within 2 seconds, usually well under one.
    Chromium's part waits on other threads and processes, so it stretches when the machine is busy (for example many parallel builds), sometimes to a few seconds.
- Closing the last window (its close button, Window > Close or Cmd+W) closes every page (tab) in it, then the app quits the same way.
- Closing a window that is not the last one closes only that window's pages and leaves the app running.
- A page's own "leave this page?" prompt still appears when quitting or closing its window.
  Choosing to stay keeps that page open and cancels the quit, so the app keeps running; quitting again asks again.
  When a window has several pages, the pages that agree to close do close, and the window stays open with the page that asked to stay.
- Quitting twice in a row (for example pressing Cmd+Q again while windows are closing) does not slow quitting down or change the result.
- A smoke run (`Bow --smoke-test=<address>`) opens one window in the background without taking keyboard focus, loads the address, prints exactly one result line, then quits.
  - The result line is `smoke: status=<code> title="<title>" url=<url>` when the page loads, `smoke: error=<code> <text> url=<url>` when it fails, or `smoke: timed out` after 30 seconds.
  - The exit code is 0 when the page loaded with a 2xx or 3xx status, 1 when it failed or returned another status, and 2 when it timed out.
  - `--smoke-quit=terminate` (the default) quits directly, `--smoke-quit=menu` presses Cmd+Q through the menu bar, and `--smoke-quit=close-window` closes the window, so each way a person quits can be checked on its own.
  - After quitting, a smoke run prints `quit: seconds=<time>` to standard error, timed from the result line.
    If the app has not finished quitting 2 seconds after the result line, it prints `quit: timed out after 2.0 seconds` instead and exits with code 3.
    This limit covers Chromium's shutdown too, so on a very busy machine a smoke run can fail it although closing was quick.
- An unknown value for a switch the app reads (such as `--smoke-quit=later`) prints the problem to standard error and exits with code 64 without opening a window.

## Edge cases

- Quitting while a page is still loading, or before its window has finished opening, still closes every page within 2 seconds and exits.
- Popup windows a page opened close along with everything else when quitting, and closing one leaves its opener's window open.
- Quitting while a tab is being unloaded (its page freed to save memory) closes that page too: if the page wants to ask "leave this page?", it asks as usual instead of silently staying, so an unload never cancels a quit, and no tab is unloaded once quitting has begun.
- A page that loads more than once during a smoke run (a redirect or a script navigation) still produces one result line and keeps the first result's exit code.
- A page that keeps its "leave this page?" prompt open blocks quitting until the person answers; a smoke run then fails with exit code 3 instead of hanging.
- If Chromium's own shutdown has not finished 10 seconds after it began (only seen on a heavily loaded machine), Chromium ends the process itself with exit code 2 and logs `Teardown watchdog expired; recording dump and terminating.`; the app does not change this limit.

## Acceptance checks

1. Run `make smoke`: it prints one `smoke: status=200 title="Example Domain" url=https://example.com/` line, then `quit: seconds=` below 2, and `echo $?` prints 0.
2. Run the built app with `--smoke-test=https://example.com --smoke-quit=menu`: the same output and exit code 0.
3. Run it with `--smoke-test=https://example.com --smoke-quit=close-window`: the same output and exit code 0.
4. On a machine that is not busy, open Bow normally and press Cmd+Q: the window closes at once and the process ends within 2 seconds with exit code 0.
5. On a machine that is not busy, open Bow normally and click the window's close button: the window closes at once and the process ends within 2 seconds with exit code 0.
6. Run the built app with `--smoke-quit=later`: it prints an error, opens no window, and exits with code 64.
7. Run `make e2e`: the `app.quit` test loads a page in an off-screen window, quits, and prints `PASS app.quit: closed=<s> limit 2, windows=0, stopped=<s> (no limit)` after every other check and a final `E2E: PASS n/n`, exiting with code 0.
   `closed` is the closing part, `windows` the number of the app's windows the window server still has on screen after Chromium's shutdown, and `stopped` the time until Chromium's shutdown returned, just before the process exits, printed for information.

## Why the automated check has two limits

Timestamps taken through quitting during full `make e2e` runs, while other worktrees built at once (load average 8 to 30 on 16 cores), showed where the time goes:

- From the start of the quit to the last page's close callback: 2 to 25 milliseconds.
- To the end of the message loop (closing done): 17 to 45 milliseconds in every run.
- Chromium's shutdown after that: 0.04 seconds with only the quit test run, and 0.06 to 0.5 seconds after a full run, varying from run to run with the load.
  A stack sample during it showed the main thread mostly waiting on other threads, not working.
  Pausing 0.3 seconds before it cut it to under 0.1 seconds, so much of it is waiting for work still finishing elsewhere, which a busy machine slows down.
- Twenty full runs in a row with the two part check, load average 18 to 27: closing took 0.023 to 0.037 seconds, and the quit up to the end of Chromium's shutdown 0.085 to 0.61 seconds (median 0.11).

So a single 2 second limit on the whole quit measured mostly how busy the machine was: one full run under heavy load took 2.72 seconds and failed, while closing never took more than 0.05 seconds in any measured run.
The check then held closing, the part the app controls and a person waits for, to 2 seconds, and gave the whole quit a separate limit of 5 seconds.

That second limit flaked too: one full run with other worktrees building took 5.4 seconds with closing at 0.03 seconds.
Runs of the quit test alone with the retry off showed the same spread at any load: at load average 15 on 16 cores, 0.049 to 0.064 seconds; at load average 5 to 8, 0.052 to 0.069 seconds in eight runs and 2.47 seconds in one; and 3.28 seconds in one more run while building the change.
All of that time is inside Chromium's shutdown, after every page has closed and the message loop has ended; no Bow code runs there.
Until then, though, the window stayed on screen through it, since quitting closes pages and not windows, so a slow shutdown was a window left up for seconds.
Now the app takes every window off screen the moment the loop ends, and the check judges what a person sees:

- closing (every page closed and the message loop ended, so the app takes no more input) within 2 seconds;
- no window of the app on screen, asked of the window server after Chromium's shutdown;
- the whole quit (`stopped`) printed for information, with no limit, so a drift still shows in the reports.

A quit that hangs in Chromium's shutdown still fails: the runner's hang watchdog ends the run with `E2E: TIMEOUT app.quit` 6 seconds after the quit started.

## Chromium's teardown watchdog

Chromium bounds its own shutdown: when it has not finished 10 seconds after its teardown began (inside `CefShutdown`, after the message loop ended), it ends the process with exit code 2, so nothing the app would print after shutdown appears.
Under heavy load (load average 24 to 44 on 16 cores) full `make e2e` runs on two branches hit it after every test had passed, and each ended as a crash without a summary line.
Holding one shutdown-blocking task for 20 seconds reproduces it every time.
The runner's hang watchdog for quitting used to wait 15 seconds, so Chromium's always fired first.
It now fires 6 seconds after the quit starts, before Chromium's can: a quit that slow ends with `E2E: TIMEOUT app.quit` at once, then a stack sample in `hang.txt` showing where Chromium's shutdown waits, unless Chromium ends the process during the sample.

Each test's in-memory profile stays alive until quitting, which was a suspect for the slow shutdowns.
Quitting after the quit test alone took 0.047 to 0.088 seconds and after a full run (17 more profiles) 0.096 to 0.137 seconds, at load average 7 to 11.
Releasing each test's profiles when the test ended (their contexts were destroyed then) made no measurable difference in five alternating pairs of full runs (0.079 to 0.138 seconds kept, 0.080 to 0.192 released), so the runner keeps them.
None of the app's or the runner's code posts tasks that block Chromium's shutdown.

## Out of scope

- Restoring windows and pages after quitting and relaunching.
- Asking for confirmation before quitting with many tabs open.
- Quitting through signals such as Ctrl+C in a terminal.
