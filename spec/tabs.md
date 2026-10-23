# Tabs

## Summary

A window holds several tabs, each one a live web page, and shows one of them at a time.
People keep many pages open and move between them all day, so switching must be instant and lossless, and closing a page must never throw away work without asking.

## Behavior

- Opening a tab adds it to its window and, unless it opens in the background, shows it.
- Switching to another tab shows that tab's page exactly as it was left: the same document, scroll position, typed text and running scripts.
  Switching never reloads either page.
- A tab that is not shown keeps running, but its page counts as hidden (`document.visibilityState` is `hidden`), so pages can pause animations and video while out of sight.
  The shown tab counts as visible and keeps painting.
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

## Edge cases

- A tab still opening when it is closed closes as soon as its page exists.
- The prompt for a shown tab is a sheet on its window.
  Known limit: the prompt for a tab that is not shown (for example when closing a window or quitting with several pages asking) is a free-floating alert that does not name the site, and several such alerts can stack.

## Acceptance checks

1. Run `make e2e`: `PASS tabs.switch: reloads=0` shows two tabs switched three times each with no reload, and `PASS tabs.hidden` shows the tab not shown counted as hidden in every switch.
2. Run `make e2e`: `PASS tabs.beforeunload: stay=kept leave=closed` shows a tab with a typed draft and a beforeunload handler asked once on close, kept with the same document and draft after Cancel, and closed after a second close and Leave.
3. Run `make e2e`: `PASS tabs.close: neighbor=shown closed=true prompts=0` shows the neighbor tab shown after the draft tab closed, and a page without a handler closed at once without a prompt.
4. Run `make e2e`: `PASS tabs.close-window` shows a window with three tabs, one shown and two hidden, closing all three and then itself while the app keeps running.
5. By hand: open a page with a form, type into it, close its tab; the prompt appears; choose Cancel and the text is still there; close again and choose Leave and the tab is gone.

## Out of scope

- A tab strip or sidebar, keyboard shortcuts for switching and closing tabs, and reopening closed tabs.
- Pinned tabs, archiving and sleeping tabs to save memory.
- Prompts when a page reloads or navigates away (reloading asks "Reload this site?" the same way), which this spec does not check.
