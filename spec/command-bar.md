# Command bar

## Summary

One bar for opening, finding and changing pages by typing: a web address, a search, a tab that is already open, or a page visited before.
Everyone who browses uses it, mostly through Cmd+T and Cmd+L.

## Behavior

- Cmd+T opens the bar empty.
  Pressing Enter on a result opens it in a new tab.
- Cmd+L opens the bar filled with the current page's address, all selected.
  Pressing Enter on a result loads it in the current tab.
- Escape closes the bar and changes nothing: no tab is opened, no page is loaded.
- The shortcuts work even when the page has keyboard focus, and the page never sees them.
- Typing shows one list that merges every source, best match first, and updates on each keystroke.
  Up to 8 rows show.
  Each row has a title and an address, and an open tab is marked as one.
- Choosing a row that is an open tab switches to that tab instead of opening a new one.
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

- Blank or spaces only: nothing is searched or loaded, and Enter does nothing.
- A source that is slow or fails never holds up the others: rows from the faster sources appear first, and a source that has not answered within half a second is left out of that list.
- Opening the bar again clears the previous text and selection.
- Two tabs on the same address both show, and each switches to its own tab.
- When the history source is not available yet, the bar still works with the typed address, search and open tabs.

## Acceptance checks

Checks 1 to 8 need the command bar UI and shortcuts, which are built separately from the ranking logic; the ranking and address rules above are covered by unit tests.

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
8. (Pending the app work, not part of the ranking logic.) `make e2e` prints `PASS cmdbar: query=a first=tab:A`.

## Out of scope

- The history store that feeds visited pages: not yet built, see its own spec when added.
- Commands and actions in the bar, and suggestions from the search engine.
- Ctrl+Tab switching by recency.
- Sidebar and tab behavior: see the tab specs.
