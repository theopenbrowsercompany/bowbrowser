# Tabs

## Summary

A window holds several tabs, each one a live web page, and shows one of them at a time.
People keep many pages open and move between them all day, so switching must be instant and lossless, and closing a page must never throw away work without asking.
Each window shows an ordered list of tabs with one active tab, and everything the sidebar shows or does with tabs starts from that list.
The list comes from the saved sidebar (see `sidebar-store.md`): a window's tabs are the tabs of the Space on screen, its pinned tabs first and then its other tabs, so the same list carries pinned tabs, folders, Spaces and restoring tabs after a restart.

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
- Closing the last tab of the Space on screen keeps the window and the Space open: the page area shows a short "No tabs in this Space" line with a New Tab button.
  Switching to a Space that has no tabs shows the same empty state, never the page of the Space left behind.
  Closing the window itself (its close button, Close Window) still closes it.
- Closing a pinned tab with Close Tab unloads its page and keeps its row; the next tab becomes active.
  When it was the Space's only tab, it stays active with no page loaded, also after switching to another Space and back, and loads again only once its row or the page area's Load Tab button is chosen.
  Meanwhile the page area says the tab is not loaded, with that Load Tab button, rather than staying blank.
- Closing a window closes all of its tabs, each running its page's beforeunload handler.
  A page whose person chooses to stay keeps its tab and the window open, while the other tabs close; the window then shows the page the person stayed on, not a closed tab loading again, and one page staying never stops the window from following the others the next time it is closed.
  A window that is closing loads no other tab, even when a tab the person closed just before was followed by a saved one, and opens no new tab, so links go to another window.
  Quitting works the same way (see `quit.md`).

### Tab list

- A tab has a stable identity that never changes while it exists, an address, a title, an optional favicon, a loading flag, and whether it can go back and forward.
- A tab's address, title, favicon, loading flag and back and forward state always mirror what the page last reported.
  The tab's identity is its own and does not change when the page navigates.
- Opening a tab adds it to the Space on screen's tabs section (below the pinned tabs): right after the active tab when that tab is in the tabs section itself, otherwise at the end.
  When nothing is active, "after the active tab" means the end.
- Every tab is created in the profile of the Space that holds it, decided before its first request, so it never starts in another profile's cookies.
  This holds for every way a tab opens: the New Tab button and menu, a link from another app, and a saved tab loading after a relaunch.
  A tab whose Space names a profile Bow does not have does not open.
- A link from another app (for example one clicked in Mail) opens in a new tab of the most recently used window that is not closing, in the profile of its Space on screen, or in a new window when there is none.
  Rules that send links to a chosen Space come later.
- Opening, selecting, moving and closing tabs are saved to the sidebar as they happen.
  A tab in the tabs section remembers the page it shows, so a relaunch brings it back on that page; a pinned tab keeps the address it was pinned on.
  The page a tab shows is written to the sidebar file about a second after it last changed, so a page changing its title or address many times writes the file once; closing the window or quitting writes what is left.
- Relaunching shows the same tabs in the same order with the same active tab.
  Only the active tab loads its page right away; every other tab shows its saved title and loads when it is selected.
- A newly opened tab becomes the active tab, unless it is opened in the background, in which case the active tab stays as it was.
  The first tab opened in an empty window is always active.
- Selecting a tab makes it the active tab.
  A tab whose page cannot load (its Space names a profile Bow does not have) is not selected: the active tab stays as it was, and the sidebar's highlight and the page area always agree.
- Moving a tab puts it at the requested position in the resulting order.
  A position past either end puts it first or last.
  Moving never changes which tab is active.
- Closing a tab that is not active leaves the active tab alone.
- Closing the active tab makes the tab that was right after it active.
  When it was the last tab, the tab before it becomes active.
- Closing the only tab leaves an empty list with no active tab.
  Opening a tab afterwards works as in any empty window.
- Closing a tab (its close button, Close Tab) removes it from the sidebar; closing a pinned tab only unloads its page and keeps it.
  Tabs that close because their window closes or the app quits keep their place in the sidebar and come back on the next launch.
  A tab whose page closes itself (`window.close()`) leaves the sidebar the same way, and a pinned one unloads and stays.
  A tab whose page could not be opened at all keeps its row and saved page, so a saved tab never disappears without the person closing it.
- A loaded tab whose row leaves the sidebar any other way (its Space deleted, archived, a Favorite removed) has its page closed, so no page keeps running without a row.
  A page that asks before leaving asks once; when the person chooses to stay it keeps running unlisted until its window closes, and later sidebar changes do not ask again.
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

### Last active

- Bow remembers when each tab was last active: a tab counts as active when it becomes the tab a window shows, and again when its window becomes the front window.
  Opening or closing other tabs does not change it.
- The times survive quitting and relaunching, are kept apart from the sidebar, and are forgotten for tabs that no longer exist.
  If the saved times cannot be read, Bow starts with none and keeps the unreadable file aside.
- They are the record the command bar's open tabs list will use to put the most recent tab first, and auto-archive will use to tell how long a tab has sat idle.

## Edge cases

- A tab still opening when it is closed closes as soon as its page exists.
- The prompt for a shown tab is a sheet on its window.
  Known limit: the prompt for a tab that is not shown (for example when closing a window or quitting with several pages asking) is a free-floating alert that does not name the site, and several such alerts can stack.
- A window with no tabs is a valid state in the tab list.
- Saved tab lists are plain data.
  A saved list that is inconsistent (repeated identities, an active tab that is not in the list, an active tab in an empty list, or no active tab in a non-empty list) is rejected as a whole instead of being repaired silently.
- Tab identities are separate from the engine's page identities, which do not survive a restart.
- A page that closes itself only counts as closed by the person once it has shown a page; a tab that closes before it ever showed one, or for no known cause, keeps its place in the sidebar, unloaded, as it does for quitting.
- A saved tab that has not loaded yet closes at once from its close button or Close Tab, since it has no page to ask.
- Moving a tab to a position in the window's tab order puts it in the place of the tab it lands on, in that tab's section or folder (pinning or unpinning it when that is the other zone); past the last tab it goes to the end of today.
  How dragging across the divider pins and unpins is in `sidebar.md`.
- If the sidebar file can be neither read nor moved aside, Bow still opens with an empty sidebar for that launch, saved nowhere, and leaves the file alone.
- A window opened for a smoke run or an e2e test runs on a sidebar of its own, so it never adds tabs to the person's sidebar.

## Acceptance checks

1. Run `make e2e`: `PASS tabs.switch: reloads=0` shows two tabs switched three times each with no reload, and `PASS tabs.hidden` shows the tab not shown counted as hidden in every switch.
2. Run `make e2e`: `PASS tabs.beforeunload: stay=kept leave=closed` shows a tab with a typed draft and a beforeunload handler asked once on close, kept with the same document and draft after Cancel, and closed after a second close and Leave.
3. Run `make e2e`: `PASS tabs.close: neighbor=shown closed=true prompts=0` shows the neighbor tab shown after the draft tab closed, and a page without a handler closed at once without a prompt.
4. Run `make e2e`: `PASS tabs.close-window` shows a window with three tabs, one shown and two hidden, closing all three and then itself while the app keeps running.
5. By hand: open a page with a form in a window, type into it, press Command-W; the prompt appears as a sheet; choose Cancel and the tab and text are still there; press Command-W again and choose Leave and the tab is gone (leaving the empty state, when it was the last tab).
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
17. Run `make e2e`: `PASS tabs.last_closed: windows=1 empty_state=shown page=none` shows closing a window's only tab keeping the window on the empty state, and `PASS tabs.empty_space` shows switching to an empty Space hiding the previous Space's page.
18. Run `make e2e`: `PASS tabs.pinned_close: rows=1 loaded=0 window=open active=pinned load_button=shown` shows Command-W on a lone pinned tab unloading it without loading it again, with the Load Tab button shown, and `PASS tabs.pinned_space_switch` shows it still unloaded after a switch to another Space and back, then loaded by Load Tab.
19. Run `make e2e`: `PASS tabs.close_while_closing: window=closed loaded_next=0` shows a window closed right after one of its tabs closing without loading the saved tab that followed.
20. Run `make e2e`: `PASS tabs.select_failed: active=unchanged page=none` shows selecting a tab that cannot load leaving the selection and the page area as they were.
21. Run `make e2e`: `PASS tabs.orphan_closed: orphan=closed kept=running` shows deleting a Space closing the page loaded in it.
22. Run `make e2e`: `PASS tabs.record_debounced: writes=1` shows five title changes written to the sidebar file once, no sooner than the save delay after the first change.
23. Run `make e2e`: `PASS tabs.orphan_asked_once: prompts=1` shows a page with a draft whose Space was deleted asked once, answered stay, and not asked again by later sidebar changes.
24. Run `make e2e`: `PASS tabs.window_close_stay` shows a window close answered stay keeping the window open on the draft the person stayed on, and `PASS tabs.window_close_again` shows a second close answered leave closing it.
25. Run `make e2e`: `PASS tabs.link_while_closing: link=other window` shows a link arriving while the last used window closes opening in the other window.
26. BowCore tests (`make test`): `SelfClosedPagesTests` show a page that committed and then closed itself told apart from one the engine never created.
27. Run `make e2e`: `PASS store.roundtrip: items=12 after_relaunch=12` shows twelve tabs saved, their window closed and the sidebar read back from its file into a new window, which lists all twelve with the same active tab and loads only that one.
28. Run `make e2e`: `PASS link.profile: opened_in=work cookie=1` shows a link from another app opening in the most recent window, created in its Space's profile (work), and seeing the cookie that profile set.
29. By hand: open a few tabs, select one, quit and relaunch; the same tabs come back in order with the selected one loaded and the others loading only when clicked.
30. Run `make e2e`: `PASS activity: last=B` shows two tabs A and B with A selected and then B, B recorded as the more recently active.

## Out of scope

- Keyboard shortcuts for switching tabs, reopening closed tabs, and moving tabs between windows.
- How the sidebar looks beyond the rows above (collapsing, resizing, themes, a hidden title bar).
- The sidebar's sections (Favorites, pinned, today) and its folders, covered in `sidebar.md`; archiving of old tabs and sleeping tabs to save memory.
- Switching Spaces, choosing a Space's profile, and tabs mirrored across windows.
- Creating or closing the underlying pages in the engine (the tab list only records what the engine reports).
- Prompts when a page reloads or navigates away (reloading asks "Reload this site?" the same way), which this spec does not check.
