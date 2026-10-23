# Command bar

## Summary

One bar for opening, finding and changing pages by typing: a web address, a search, a tab that is already open, or a page visited before.
Everyone who browses uses it, mostly through Cmd+T and Cmd+L.

## Behavior

- The bar is a panel floating over the page, centered on it near its top, with the text field above one list of results.
- Cmd+T (File > New Tab) opens the bar empty.
  Pressing Enter on a result opens it in a new tab in the today section of the Space on screen, right after the shown tab when that is a today tab.
- Cmd+L (View > Open Location) opens the bar filled with the current page's address, all selected, so typing replaces it.
  Pressing Enter on a result loads it in the current tab.
- A click on the sidebar's URL field opens the bar exactly as Cmd+L does; in an empty Space, with no page to show the address of, it opens the bar as Cmd+T does.
- Escape, a click anywhere outside the panel, or View > Close Command Bar closes the bar and changes nothing: no tab is opened, no page is loaded.
- The shortcuts work even when the page has keyboard focus, and the page never sees them; Escape is taken from the page only while the bar is open.
- Escape has no shortcut in the menu: a menu item takes its key even while it is disabled, which would take Escape from the find bar and from pages.
- Cmd+Shift+C (Edit > Copy Current URL) copies the shown page's address to the pasteboard, as a link and as plain text, and shows a small rounded "Copied URL" label near the bottom of the page that fades after about a second and a half.
  Like Cmd+T and Cmd+L it is taken before the page, so a page that handles the key itself never sees it.
  A blank tab, an internal page or an empty Space has no address to copy: nothing is copied, no label shows and the menu item is disabled.
  A second press restarts the one label; the label goes with the window.
  The address is copied as it is (Arc's Supercopy also strips tracking parameters; Bow does not yet).
  `make e2e E2E=chrome` checks it (`PASS chrome.copy`, `chrome.copy.twice`, `chrome.copy.fade`, `chrome.copy.page-key`, `chrome.copy.blank`, `chrome.copy.window-close`).
- Each window has its own bar; opening, typing in or closing one leaves the bars of other windows as they are.
- Up and Down move the highlighted row, and Enter or a click chooses it.
  Typed text highlights the best row, also when a slower source's answer puts a better row first; a row picked with an arrow key stays picked while the list updates.
- Pressing Enter before the typed text's first results show waits for them, so Enter never chooses a row left from older text.
- The open tabs are this window's tabs in every Space and in Favorites, also those whose page has not loaded yet.
- Visited pages come from the history of the shown tab's profile.
- The sidebar's New Tab button still opens a new tab directly; only File > New Tab and Cmd+T open the bar.
- Typing shows one list that merges every source, best match first, and updates on each keystroke.
  Up to 8 rows show.
  Each row has a title and an address, and an open tab is marked as one.
- Choosing a row that is an open tab switches to that tab instead of opening a new one.
- Every open tab row shows the Space the tab lives in (its icon and name), so two tabs on similar pages in different Spaces can be told apart and the person sees which profile, and so which logins, the tab uses.
  The Ctrl+Tab tab switcher shows the same Space beside each tab.
  A Favorite belongs to no one Space, so its row shows none.
  Rows for visited pages, typed addresses and searches show no Space.
- Choosing an open tab that lives in another Space first shows that Space, then selects the tab.
  Choosing one in the Space already on screen only selects it.
  Choosing a Favorite never changes the Space on screen.
- With the bar empty, the list shows the open tabs, most recently used first.
- What gets typed is read the same way as in the address field:
  - A full address (`https://example.com/a`) loads as typed.
  - A host name (`example.com`, `localhost:3000`, `192.168.1.1`) loads over https.
  - Anything else, including numbers such as `3.14`, is a web search.
  - Characters such as `&`, `=`, `+` and `#` in search text are searched for, not treated as part of the address.
- When the typed text is an address, the first row loads it, and a second row below the matches searches for it instead.
  When it is not an address, a search row sits below the rows where a word of the title or address starts with the text and above rows that match only inside a word.
- Ranking, in order of strength:
  1. A tab or page whose address equals the typed address.
  2. The typed address itself.
  3. A tab or page whose address starts with the text, then one whose title starts with it, then one with a title or address word starting with every typed word, then one containing every typed word anywhere.
  4. An open tab ranks above a visited page with the same kind of match.
  5. Ties go to what was used most recently.
- Matching ignores capitals and accents.
  Every typed word must match; a tab or page matching none is not shown.
- An address shows once: an open tab hides the visited page and the typed address for the same address, and a visited page hides the typed address.
  Scheme, a leading `www.`, a trailing slash and a `#` fragment do not make addresses different.
  When a page was visited more than once, only the latest visit shows.

## Edge cases

- Blank or spaces only: nothing is searched or loaded, no row is highlighted, and Enter does nothing until an arrow key picks a row.
- A source that is slow or fails never holds up the others: rows from the faster sources appear first, and a source that has not answered within half a second is left out of that list.
- Opening the bar again clears the previous text and selection.
- The bar opened with Cmd+L closes when its tab closes or another tab is shown, since Enter would have nowhere to load.
- Any bar closes when another Space comes on screen and when the window's last tab closes.
- While the bar is open and a tab opens, closes or is renamed, the list updates to match.
- Two tabs on the same address both show, and each switches to its own tab.
- When the history source is not available yet, the bar still works with the typed address, search and open tabs.

## Acceptance checks

The ranking and address rules above are covered by unit tests; the checks below run in the app with `make e2e E2E=cmdbar`.

1. Start with tabs "Alpha" and "Beta" open and Alpha selected.
   Press Cmd+T, then Escape.
   The bar closes and still only two tabs exist.
2. Press Cmd+T, type `beta`, press Enter on the Beta row.
   Beta becomes the selected tab and no third tab opens.
3. Press Cmd+T, type `example.com`, press Enter.
   A third tab opens on `https://example.com`.
4. Select Alpha, press Cmd+L.
   The bar shows Alpha's address, selected; typing replaces it.
   Type `rust book`, press Enter.
   Alpha loads a search for "rust book" and no tab is added.
5. With focus inside a web page that handles Cmd+T or Cmd+L itself, press either shortcut.
   The bar opens and the page does not react.
6. Press Cmd+T with nothing typed.
   The list shows the open tabs, most recently used first.
7. Type `a&b=c`.
   The search row loads a search for exactly `a&b=c`.
8. With tabs A and B open, press Cmd+T and type `a`.
   `make e2e` prints `PASS cmdbar: query=a first=tab:A`, and the checks `cmdbar.escape`, `cmdbar.new-tab`, `cmdbar.current-tab`, `cmdbar.blank`, `cmdbar.arrows` and `cmdbar.click-outside` cover checks 1, 3, 4 and 6 and the edge cases above.
9. With Spaces "work" (tab A) and "personal" (tab Beta) and "work" on screen, press Cmd+T, type `beta`, press Enter on the Beta row.
   The Beta row shows "personal".
   "personal" comes on screen with Beta selected and no tab is added (`PASS cmdbar.space`).
10. Visit a page, then leave it in the same tab.
   Press Cmd+T and type part of its name: its row is a visited page, and Enter opens it in a new tab (`PASS cmdbar.history`).
11. Focus a field in a page that records every key, and send it Cmd+T, Escape and Cmd+L.
   The bar opens, closes and opens again on the page's address, and the page records none of the three keys (`PASS cmdbar.keys`).
12. Open the bar in two windows, type in the second, press Escape in it.
   The first bar still shows its own text (`PASS cmdbar.windows`).

## Out of scope

- Commands and actions in the bar, and suggestions from the search engine.
- Ctrl+Tab switching by recency.
- Sidebar and tab behavior: see the tab specs.
- A Space icon: Spaces have no icon yet (see the Spaces spec), so rows show the name until they do.
- Finding tabs by typing a Space's name.
