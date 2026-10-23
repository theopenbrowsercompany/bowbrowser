# Peek

## Summary

Peek previews a link in a card over the current page, so you can read something and go back to what you were doing without opening a tab.
It is how pinned tabs and Favorites keep their own site: a link that leaves the site opens in a Peek instead of taking the tab away.

## Behavior

- A Shift-click on a link opens its page in a Peek over the window.
- A plain click on a link in a pinned tab or a Favorite that goes to another site opens that page in a Peek, and the tab stays on its own page.
  Another site means another host name, ignoring a leading `www.` and letter case, so another subdomain of the same site counts as another site.
  A link to the same site navigates the tab as usual.
- Links in Today tabs, typed addresses, reloads, back and forward, form posts and navigations a script starts without a click are never peeked.
- The Peek is a centered card with rounded corners and a soft shadow, the page around it dimmed, with two round buttons above the card's trailing edge: Open as Tab and Close.
- The Peek's page is a page of its own in the same profile as the tab it was opened from, so it shares that tab's logins.
- Escape closes the Peek, wherever the keyboard is in the window (the Peek's page, the page under it or the sidebar).
- The Close button and a click on the dimmed page around the card close it too.
- Open as Tab moves the Peek's page into a tab right after the tab it was opened from (at the top of Today when that is a pinned tab or a Favorite), shown at once.
  The page moves as it is: it does not reload, and anything typed into it stays.
- While a Peek is open, the page under it is not clickable, and the page under it stays the window's shown tab.
- The Peek's page shows its alerts, confirms and prompts as sheets on the window, as a tab's page does.
- A sign in popup the Peek's page opens opens in a popup panel; any other new page it opens becomes a tab of the window.
- App shortcuts keep working while the keyboard is in the Peek's page (Cmd+T, Ctrl+Tab and the others).

## Settings

Two settings, both on by default, as Arc ships them.

- "Open a Peek window when clicking on links with Shift held": with it off, a Shift-click opens the link in a new tab in the foreground, right after the tab it was clicked in.
- "Open a Peek window when clicking on links to other sites": with it off, a link from a pinned tab or a Favorite that leaves the site opens in a new tab at the top of Today, shown at once, and the pinned tab or Favorite still stays on its own page.

There is no settings window yet; the settings are stored in the app's preferences.

## Edge cases

- A window shows one Peek at a time: a second Shift-click before the first Peek shows opens nothing more, and an off-site link from a pinned tab while a Peek is open opens a new tab.
- The Peek belongs to the tab it was opened from: closing, unloading or archiving that tab closes the Peek.
- Showing another tab, or switching to another Space, closes the Peek.
- Closing the window or quitting closes the Peek; nothing of it is left running.
- When the Peek's page asks "Leave this site?" as you close it with Escape, Close or a click on the dimmed page, choosing to stay keeps the Peek open on the same page.
- When the Peek closes because its tab closed or went out of sight and its page asks "Leave this site?", choosing to stay keeps the page as a tab in the background, right after its source tab, so nothing runs out of sight.
- A Peek's page that closes itself (`window.close()`) closes the Peek.

## Acceptance checks

1. Open a page with a link, Shift-click the link: the linked page shows in a card over the dimmed page, and the sidebar still marks the first tab as shown. Press Escape: the card goes and the first page shows.
2. Shift-click a link, then press Open as Tab: the page becomes a new tab right after the first one, shown, without reloading.
3. Pin a tab, click a link in it to another site: a Peek opens and the pinned tab stays on its page. Turn the off-site setting off and click the link again: a new tab opens at the top of Today instead.
4. Shift-click a link, then close the tab it was clicked in: the Peek closes too.
5. Shift-click a link, then select another tab: the Peek closes.
6. Shift-click a link to a page with a form, type into it, press Close and choose to stay: the Peek stays open with the text kept; click the dimmed page and choose to leave: the Peek closes.
7. Run `make e2e E2E=peek`: `PASS peek: overlay=B under=A after_esc=A`, and `PASS` for `peek.promote`, `peek.pinned`, `peek.source_close`, `peek.switch`, `peek.stay` and `peek.backdrop`.

## Out of scope

- Hover previews of links, Peek's Split View button, Cmd+O and Cmd+W while a Peek is open, email peeking for mail Favorites, opening animations, and a settings window for the two settings.
- Popups and popup panels are in spec/popups.md; split view is in spec/split-view.md.
