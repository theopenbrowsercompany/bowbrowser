# Find in page

## Summary

Find in page searches the text of the shown page and steps through every match.
It is basic browser behavior that people reach for by reflex, so it must open instantly with Cmd+F and stay out of the page's way.

## Behavior

- Edit > Find > Find… (Cmd+F) shows the find bar, floating over the top right corner of the page, with the keyboard in its search field.
  If the bar kept text from an earlier search, that text is selected, so typing replaces it, and the page is searched again at once.
- Typing searches as you type, ignoring case: every match is highlighted, the first match becomes the active match and scrolls into view, and the bar shows "n of m" (the active match and the number of matches).
  A search with no matches shows "0 of 0".
  Emptying the field clears the highlights and the count.
- Enter, the down arrow button, and Edit > Find > Find Next (Cmd+G) make the next match active; after the last match comes the first.
- Shift+Enter, the up arrow button, and Edit > Find > Find Previous (Shift+Cmd+G) make the previous match active; before the first match comes the last.
  Cmd+G and Shift+Cmd+G open the bar first when it is closed.
- Escape, or the close button, hides the bar and clears the highlights.
  The active match stays selected in the page, as in other browsers, and the keyboard goes back to the page.
  The bar keeps its text for the next Cmd+F.

## Edge cases

- Showing another tab closes the find bar and stops its search; closing the tab being searched does too.
- On a long page the count can rise for a moment while the engine is still counting; the count shown settles on the final number.
- Navigating while the bar is open keeps the bar and its text; the count shows the last search until the next keystroke or step.

## Acceptance checks

1. Run `make e2e`: `PASS find: matches=3 active=1` shows Cmd+F (through the menu item) opening the bar with the keyboard in its field, and typing a word the fixture holds three times finding three matches with the first active, shown as "1 of 3".
2. Run `make e2e`: `PASS find.step: enter=2,3,1 shift-enter=3` shows Enter stepping forward and wrapping to the first match, and Shift+Enter stepping back and wrapping to the last.
3. Run `make e2e`: `PASS find.close: hidden selection=m3` shows Escape hiding the bar, clearing its count and leaving the active match selected in the page.
4. Run `make e2e`: `PASS find.reopen: text=arrow count=1 of 3` shows Cmd+F again bringing back the kept text and searching again; `final.png` shows the bar over the page with the matches highlighted.
5. By hand: open any article, press Cmd+F, type a common word, press Enter a few times and watch the active match move and the page scroll, then press Escape and see the highlights go.

## Out of scope

- Match case and whole word options (the engine supports match case; the bar has no toggle yet).
- Finding inside PDFs, and finding across all tabs.
- A separate find bar per tab that remembers its state when switching back.
