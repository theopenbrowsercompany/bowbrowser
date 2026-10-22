# Quitting

## Summary

Quitting closes every page and ends the app quickly and cleanly, however it was started.
People rely on it every day, and every automated run relies on the app exiting on its own with a meaningful exit code.

## Behavior

- Choosing Bow > Quit Bow or pressing Cmd+Q closes every window and the app exits within 2 seconds with exit code 0.
- Closing the last window (its close button, Window > Close or Cmd+W) closes that page, then the app quits the same way.
- Closing a window that is not the last one closes only that window's page and leaves the app running.
- A page's own "leave this page?" prompt still appears when quitting or closing its window.
  Choosing to stay keeps the page and the app open, and quitting again asks again.
- Quitting twice in a row (for example pressing Cmd+Q again while windows are closing) does not slow quitting down or change the result.
- A smoke run (`Bow --smoke-test=<address>`) opens one window in the background without taking keyboard focus, loads the address, prints exactly one result line, then quits.
  - The result line is `smoke: status=<code> title="<title>" url=<url>` when the page loads, `smoke: error=<code> <text> url=<url>` when it fails, or `smoke: timed out` after 30 seconds.
  - The exit code is 0 when the page loaded with a 2xx or 3xx status, 1 when it failed or returned another status, and 2 when it timed out.
  - `--smoke-quit=terminate` (the default) quits directly, `--smoke-quit=menu` presses Cmd+Q through the menu bar, and `--smoke-quit=close-window` closes the window, so each way a person quits can be checked on its own.
  - After quitting, a smoke run prints `quit: seconds=<time>` to standard error, timed from the result line.
    If the app has not finished quitting 2 seconds after the result line, it prints `quit: timed out after 2.0 seconds` instead and exits with code 3.
- An unknown value for a switch the app reads (such as `--smoke-quit=later`) prints the problem to standard error and exits with code 64 without opening a window.

## Edge cases

- Quitting while a page is still loading, or before its window has finished opening, still exits within 2 seconds.
- Popup windows a page opened close along with everything else when quitting, and closing one leaves its opener's window open.
- A page that loads more than once during a smoke run (a redirect or a script navigation) still produces one result line and keeps the first result's exit code.
- A page that keeps its "leave this page?" prompt open blocks quitting until the person answers; a smoke run then fails with exit code 3 instead of hanging.

## Acceptance checks

1. Run `make smoke`: it prints one `smoke: status=200 title="Example Domain" url=https://example.com/` line, then `quit: seconds=` below 2, and `echo $?` prints 0.
2. Run the built app with `--smoke-test=https://example.com --smoke-quit=menu`: the same output and exit code 0.
3. Run it with `--smoke-test=https://example.com --smoke-quit=close-window`: the same output and exit code 0.
4. Open Bow normally, press Cmd+Q: the window closes and the process ends within 2 seconds with exit code 0.
5. Open Bow normally, click the window's close button: the window closes and the process ends within 2 seconds with exit code 0.
6. Run the built app with `--smoke-quit=later`: it prints an error, opens no window, and exits with code 64.
7. Run `make e2e`: the `app.quit` scenario loads a page in an off-screen window, quits, and prints `PASS app.quit: seconds<2` and `E2E: PASS 1/1`, exiting with code 0.

## Out of scope

- Restoring windows and pages after quitting and relaunching.
- Asking for confirmation before quitting with many tabs open.
- Quitting through signals such as Ctrl+C in a terminal.
