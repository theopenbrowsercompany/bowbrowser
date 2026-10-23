# Ctrl+Tab by recency

## Summary

Ctrl+Tab takes a person back to the tab they used last, not to the next tab in the strip.
Each window remembers the order its tabs were used in, and the switcher shows that order.

## Behavior

- Each window keeps a list of its tabs in the order they were last used, most recent first.
- Activating a tab (clicking it, opening it, or switching to it with any shortcut) moves it to the front of that window's list.
- Closing a tab removes it from the list, and the remaining tabs keep their order.
- On restart, tabs that no longer exist are dropped from the restored list, and the rest keep their order.
- Holding Ctrl and pressing Tab opens a switcher overlay that lists the window's tabs in recency order.
  The first Tab press highlights the previous tab, so a quick Ctrl+Tab goes back to where the person just was.
- Each further Tab press moves the highlight one tab forward, and Shift+Tab moves it one tab back.
  Both wrap around at the ends of the list.
- Releasing Ctrl selects the highlighted tab and closes the overlay.
- Pressing Escape while the overlay is open closes it and keeps the current tab.
- Selecting a tab with the switcher makes it the most recent tab in that window, so the next Ctrl+Tab goes back to the tab before it.
- Ctrl+Tab is handled before the page or Chromium sees the key, so a page cannot take it over.

## Edge cases

- A window with one tab: Ctrl+Tab does nothing visible and the tab stays selected.
- A tab that closes while the overlay is open is removed from the overlay, and releasing Ctrl never selects a closed tab.
- A window with many tabs: the list keeps every open tab, so the switcher never hides one.
  Any cap on the list length is off by default, so a cap would have to be set on purpose and would be written into this spec.
- Each window has its own list, so Ctrl+Tab in one window never selects a tab from another window.
- After a restart, the saved list is restored with its order.
  A saved list that lists a tab twice keeps only its most recent position.

## Acceptance checks

1. Open tabs A, B and C in that order, then activate A, then C, so the recency order is C, A, B.
   Hold Ctrl and press Tab once, release Ctrl: the window shows A and A becomes the active tab.
2. From the same state, hold Ctrl, press Tab twice, release Ctrl: the window selects B.
3. Hold Ctrl, press Tab, then Shift+Tab, release Ctrl: the window stays on the current tab.
4. Hold Ctrl and press Escape: the overlay closes and the current tab stays selected.
5. Close the active tab while the overlay is open, then release Ctrl: the window selects a tab that is still open.
6. Run `make e2e`: `mru` prints its PASS lines for the checks above (`mru`, `mru.third`, `mru.shift`, `mru.escape`, `mru.space`, `mru.closes`, `mru.engine-key`).
   This check needs the app and is not part of BowCore unit tests.

## Out of scope

- The switcher overlay, its drawing and the keyboard handling in `OnPreKeyEvent` are not covered by this spec's unit tests and are checked by the app and the e2e run.
- The tab strip order used by the sidebar and by Cmd+1 through Cmd+9 is not changed by this spec.

## Switcher details

- The overlay floats over the page card and lists each tab with its site icon, title and Space (emoji and name, no Space for a Favorite).
  Tabs the window has never shown, such as another Space's tabs that have not loaded, follow the used ones, so every tab can be reached.
- Choosing a tab in another Space brings that Space on screen, as choosing it in the command bar does.
- Ctrl+Shift+Tab starts from the least recent end, since the first step goes back.
- With fewer than two tabs the keys do nothing and no overlay shows.
- The overlay also closes, keeping the shown tab, when its window stops being the key window.
- The overlay watches the Ctrl release with an event monitor that exists only while the overlay shows.
