# Tabs

## Summary

A window holds several tabs, each one a live web page, and shows one of them at a time.
People keep many pages open and move between them all day, so switching must be instant and lossless, and closing a page must never throw away work without asking.
Each window keeps an ordered list of tabs with one active tab, and everything the sidebar shows or does with tabs starts from that list.
The list is the base for pinned tabs, folders, spaces and restoring tabs after a restart.

## Behavior

### Pages and closing

- Opening a tab adds it to its window and, unless it opens in the background, shows it.
- Switching to another tab shows that tab's page exactly as it was left: the same document, scroll position, typed text and running scripts.
  Switching never reloads either page.
- A tab that is not shown keeps running, but its page counts as hidden (`document.visibilityState` is `hidden`), so pages can pause animations and video while out of sight.
  The shown tab counts as visible and keeps painting.
- A tab opened in the background counts as hidden from the start, before it has ever been shown: its page sees `hidden` from its first script on and paints nothing until the tab is shown, when it becomes visible.
- Closing a tab runs its page's beforeunload handler first.
  - A page without a handler, or one that does not ask, closes at once.
  - A page that asks (for example one holding an unsaved draft) shows a "Leave this site?" prompt with Leave and Cancel.
    Choosing Leave closes the tab.
    Choosing Cancel keeps the tab and its page exactly as they were: the same document, nothing reloaded, typed text intact.
    Closing again asks again.
  - Chromium shows the prompt only for a page the person has interacted with (clicked, typed or pressed a key in); a page nobody touched closes without asking.
- When the shown tab closes, the window shows a neighboring tab (the one that took its place, or the last one).
- Closing the last tab of a window closes the window.
- Closing a window closes all of its tabs, each running its page's beforeunload handler.
  A page whose person chooses to stay keeps its tab and the window open, while the other tabs close.
  Quitting works the same way (see `quit.md`).

### Tab list

- A tab has a stable identity that never changes while it exists, an address, a title, an optional favicon, a loading flag, and whether it can go back and forward.
- A tab's address, title, favicon, loading flag and back and forward state always mirror what the page last reported.
  The tab's identity is its own and does not change when the page navigates.
- Opening a tab puts it right after the active tab by default, or at the end of the list when asked.
  When nothing is active, "after the active tab" means the end.
- A newly opened tab becomes the active tab, unless it is opened in the background, in which case the active tab stays as it was.
  The first tab opened in an empty window is always active.
- Selecting a tab makes it the active tab.
- Moving a tab puts it at the requested position in the resulting order.
  A position past either end puts it first or last.
  Moving never changes which tab is active.
- Closing a tab that is not active leaves the active tab alone.
- Closing the active tab makes the tab that was right after it active.
  When it was the last tab, the tab before it becomes active.
- Closing the only tab leaves an empty list with no active tab.
  Opening a tab afterwards works as in any empty window.
- Asking for a tab that does not exist (select, close, move or update with an unknown identity) changes nothing.
- Opening a tab whose identity is already in the list is refused and changes nothing.

### Sidebar

- Every window has a sidebar on its left, a fixed width, listing the window's tabs top to bottom in tab list order.
  The page fills the rest of the window, below any toolbar.
- Each row shows the tab's site icon and its title.
  A page without a title yet shows its address's host, and a tab with nothing loaded shows "New Tab".
  A page without a site icon, or whose icon cannot be loaded, shows a globe.
  While a navigation has not reported its icon yet, the row keeps the icon it had, so it does not flicker.
  Long titles are cut short with an ellipsis, and the full title shows on hover.
- While a tab's page loads, its row shows a small spinner in place of the icon.
- A row changes as soon as its page reports a new title, icon or loading state.
- The active tab's row is highlighted.
- Clicking a row makes that tab active and shows its page, as it was left.
- The active row, and any row under the pointer, shows a close button; clicking it closes that tab the same way as any other close (the page's beforeunload handler runs first).
- A New Tab button above the list opens a new tab right after the active tab and shows it.
- Dragging a row to another position moves that tab there; the active tab stays the same, even when the dragged row was not active.
- File > New Tab (Command-T) opens a new tab, File > Close Tab (Command-W) closes the active tab, and File > Close Window (Shift-Command-W) closes the window with all its tabs.
  In a window without tabs (a page's popup), Command-W closes that window.

## Edge cases

- A tab still opening when it is closed closes as soon as its page exists.
- The prompt for a shown tab is a sheet on its window.
  Known limit: the prompt for a tab that is not shown (for example when closing a window or quitting with several pages asking) is a free-floating alert that does not name the site, and several such alerts can stack.
- A window with no tabs is a valid state in the tab list.
- Saved tab lists are plain data.
  A saved list that is inconsistent (repeated identities, an active tab that is not in the list, an active tab in an empty list, or no active tab in a non-empty list) is rejected as a whole instead of being repaired silently.
- Tab identities are separate from the engine's page identities, which do not survive a restart.

## Acceptance checks

1. Run `make e2e`: `PASS tabs.switch: reloads=0` shows two tabs switched three times each with no reload, and `PASS tabs.hidden` shows the tab not shown counted as hidden in every switch.
2. Run `make e2e`: `PASS tabs.beforeunload: stay=kept leave=closed` shows a tab with a typed draft and a beforeunload handler asked once on close, kept with the same document and draft after Cancel, and closed after a second close and Leave.
3. Run `make e2e`: `PASS tabs.close: neighbor=shown closed=true prompts=0` shows the neighbor tab shown after the draft tab closed, and a page without a handler closed at once without a prompt.
4. Run `make e2e`: `PASS tabs.close-window` shows a window with three tabs, one shown and two hidden, closing all three and then itself while the app keeps running.
5. By hand: open a page with a form in a window, type into it, press Command-W; the prompt appears as a sheet; choose Cancel and the tab and text are still there; press Command-W again and choose Leave and the tab is gone (with the window, when it was the last tab).
6. Tab list, starting with tabs A, B, C and A active: open a tab X after the active tab. Expected order A, X, B, C with X active.
7. Tab list, starting with tabs A, B, C and B active: close B. Expected order A, C with C active.
8. Tab list, starting with tabs A, B, C and C active: close C. Expected order A, B with B active.
9. Tab list, starting with tabs A, B, C and A active: close C. Expected order A, B with A still active.
10. Tab list, starting with one tab: close it. Expected an empty list with no active tab.
11. Tab list, starting with tabs A, B, C and B active: move B to the first position. Expected order B, A, C with B still active.
12. Tab list, starting with tabs A, B: open X in the background. Expected order A, B, X with the active tab unchanged.
13. Run `make e2e`: `PASS tabs.model: open,close,select,move` shows the app's window following the tab list: New Tab opens after the active tab, Command-W on the active tab activates the one after it, a sidebar click selects, and a moved tab stays active, with the sidebar's order and highlight matching after each step.
14. Run `make e2e`: `PASS sidebar.tabs: tabs=[A,B] active=B` shows a window with tab A and tab B (opened with the New Tab button) listed with their icons and titles and B highlighted, B's row showing a spinner while it loaded and then its title, a title change reaching the row, and clicking each row showing its page without reloading it.
15. Run `make e2e`: `PASS sidebar.close: button=closed cmd-w=closed` shows one tab closed with its row's close button and another with Command-W, each leaving A and B with B active.
16. By hand: drag a row to another position in the sidebar; the tab moves there and the highlighted tab stays the same.

## Out of scope

- Keyboard shortcuts for switching tabs, reopening closed tabs, and moving tabs between windows.
- How the sidebar looks beyond the rows above (collapsing, resizing, themes, a hidden title bar).
- Pinned tabs, favorites, folders, archiving of old tabs and sleeping tabs to save memory.
- Several spaces, and tabs mirrored across windows.
- Saving the tab list to disk and restoring it on launch.
- Creating or closing the underlying pages in the engine (the tab list only records what the engine reports).
- Prompts when a page reloads or navigates away (reloading asks "Reload this site?" the same way), which this spec does not check.
