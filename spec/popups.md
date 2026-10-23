# Pages that open pages

## Summary

When a page opens another page (a link that opens in a new tab, or a script that opens a new window), the new page opens in a popup window of its own and stays connected to the page that opened it.
That connection is what sign in popups (for example Google or GitHub sign in) use to report back, so those flows keep working.

## Behavior

- A link meant to open in a new tab or window (for example `target="_blank"`) opens its page in a new popup window.
- A script that opens a window (`window.open`), with or without a size, opens its page in a new popup window.
- The new page can reach the page that opened it through `window.opener`, so a sign in popup can report back and close itself.
- The new page uses the same profile as the page that opened it.
- The engine asks the app where each new page goes: a new tab, a tab in the background, a window of its own, or nowhere (blocked). Until the app's link handling decides otherwise, every new page goes to a window of its own.
- A new page the app takes as a tab is still connected to the page that opened it through `window.opener`.
- The app owns such a tab before its first navigation, so the app's rules for where pages may go apply to that first page too.

## Where new tabs go

- A page that opens a new page without a click or key press from you is blocked.
- A script window with a size (a sign in popup) stays a window of its own and keeps `window.opener`.
- A link meant for a new tab (`target="_blank"`) or a Cmd-click opens in the background, right after the tab that opened it.
- A Cmd-Shift-click opens in the foreground, right after the tab that opened it.
- A Shift-click opens in the foreground for now; it becomes Peek later.
- A link opened from a pinned tab or a Favorite puts the new tab at the top of Today instead, because those tabs sit above Today.

## Edge cases

- Bow cannot tell a plain link to a new tab from a script's `window.open`, so neither opens as a tab of the window yet.
- Closing a popup window leaves the window that opened it open, and quitting closes popups with everything else.
- A popup window has no Bow tab bar or address bar yet.

## Acceptance checks

1. Run `make e2e`: the `nav.popup` check opens a sized popup and a plain `window.open` page from a fixture, both report back through `window.opener`, and it prints `PASS nav.popup: opener=kept`.
2. Open a page with a `target="_blank"` link and click it: the linked page opens in a new window.
3. Sign in to a site with a "Sign in with Google" popup: the popup closes after signing in and the site shows you signed in.
4. Run `make e2e`: the `engine.popup` check has the app take a `window.open` page as a background tab (the page itself asked for a foreground tab, the disposition shown) and prints `PASS engine.popup: requests=1 target=opened.html disposition=foregroundTab opener=kept first-navigation=opened.html`.

## Out of scope

- Opening new tab links as tabs of the window, and showing popups inside Bow's own window with its controls.
- Choosing which popups a page may open without a click.
