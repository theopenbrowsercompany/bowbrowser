# Navigation controls

## Summary

Back, forward, reload and stop act on the window's active tab.
They are the most used commands in any browser, so they sit in the window's toolbar and have the usual keyboard shortcuts.

## Behavior

- The toolbar shows three buttons at its leading edge, right after the window buttons: Back, Forward and Reload.
  The page title stays the window's title (the Window menu shows it) but is not drawn in the toolbar.
- Back (toolbar button, History > Back, Cmd+[) goes to the previous page in the active tab's history.
- Forward (toolbar button, History > Forward, Cmd+]) goes to the next page after going back.
- Reload (toolbar button, View > Reload Page, Cmd+R) loads the active tab's page again as a new document.
  Cmd+R also works while the page is still loading.
- While the active tab loads, the Reload button turns into a Stop button; this is how the window shows that the page is loading.
  Stop (that button, View > Stop, Cmd+.) ends the load and the button turns back into Reload.
- Back is disabled when the active tab has nothing to go back to, and Forward when it has nothing ahead; their menu items are disabled the same way.
  View > Stop is disabled when nothing is loading.
- The controls follow the active tab: switching tabs shows that tab's back, forward and loading state at once.

## Edge cases

- A tab that has just opened has no history: Back and Forward are both disabled and Reload is enabled.
- Stopping a load before the new page appears leaves the previous page showing; Reload then reloads that previous page.
- Stopping after the new page appears keeps what has loaded so far; Reload loads it again.
- A window whose tabs have all closed offers no controls.
- Back and forward history is lost when the app restarts (restoring it is planned for later).

## Acceptance checks

1. Run `make e2e`: `PASS nav.history: back=A forward=B` shows a tab with pages A then B going back to A and forward to B with the toolbar buttons, with Back and Forward disabled on a fresh tab, Back alone enabled on B, and Forward alone enabled after going back.
2. Run `make e2e`: `PASS nav.shortcuts: back=A forward=B disabled-forward=refused` shows Cmd+[ and Cmd+] doing the same through the menu, and History > Forward disabled with nothing ahead.
3. Run `make e2e`: `PASS nav.reload: toolbar=reloaded shortcut=reloaded` shows the Reload button and Cmd+R each loading a new document.
4. Run `make e2e`: `PASS nav.stop` shows a page that never finishes loading with Stop in place of Reload, stopped by the button, reloaded by the button (showing Stop again), stopped by Cmd+., and View > Stop disabled once idle.
5. By hand: open a page, follow a link, and check that Back is enabled and Forward disabled; press Cmd+[ and check that Forward is now enabled.

## Out of scope

- Long press or right click menus listing the history entries.
- Swipe gestures for back and forward.
- Restoring history after a restart or after a tab is unloaded.
- An address bar and a progress bar.
