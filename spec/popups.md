# Pages that open pages

## Summary

When a page opens another page (a link that opens in a new tab, a modified click on a link, or a script that opens a new window), the new page opens as a tab of the window, right after the tab that opened it, or in a popup window of its own when the page asks for a sized window.
A page a script opened stays connected to the page that opened it.
That connection is what sign in popups (for example Google or GitHub sign in) use to report back, so those flows keep working.

## Behavior

- A link meant to open in a new tab or window (for example `target="_blank"`) opens its page in a new tab of the window.
- A script that opens a window (`window.open`) after a click opens its page in a new tab of the window; with a size it opens a popup window of its own.
- A Cmd-click, Cmd-Shift-click, Shift-click or middle click on a link opens it in a new tab and leaves the clicked tab on its page.
- The new page can reach the page that opened it through `window.opener`, so a sign in popup can report back and close itself.
- The new page uses the same profile as the page that opened it.
- The engine asks the app where each new page goes: a new tab, a tab in the background, a window of its own, or nowhere (blocked).
  The window answers with the rules below, and new kinds of answer (a popup panel for sign in windows, Peek) come later.
- A link opened with a modified click has no `window.opener`, as in other browsers.
- A new page the app takes as a tab is still connected to the page that opened it through `window.opener`.
- The app owns such a tab before its first navigation, so the app's rules for where pages may go apply to that first page too.

## Where new tabs go

- A page that opens a new page without a click or key press from you is blocked: nothing opens, and the page gets no window back and keeps working.
- One click opens at most one new page: a page that calls `window.open` many times from one click gets one tab.
- A middle click opens in the background, like a Cmd-click.
- A script window with a size (a sign in popup) stays a window of its own and keeps `window.opener`.
- A link meant for a new tab (`target="_blank"`) or a Cmd-click opens in the background, right after the tab that opened it.
- A Cmd-Shift-click opens in the foreground, right after the tab that opened it.
- A Shift-click opens in the foreground for now; it becomes Peek later.
- A link opened from a pinned tab or a Favorite puts the new tab at the top of Today instead, because those tabs sit above Today.

## Edge cases

- Bow cannot tell a plain link to a new tab from a script's `window.open` after a click, so both open as a background tab.
- A new tab whose opener closes before the engine has created its page goes away with the opener; once created it stays open and loads on its own.
  A window that is closing opens its pages' new pages in popup windows of their own instead of taking tabs.
- A new tab to a page that cannot load opens and shows the engine's error page, like any tab.
- Closing a popup window leaves the window that opened it open, and quitting closes popups with everything else.
- A popup window has no Bow tab bar or address bar yet.

## Acceptance checks

1. Run `make e2e`: the `nav.popup` check opens a sized popup (a window of its own) and a plain `window.open` page (a background tab) from a fixture, both report back through `window.opener`, and it prints `PASS nav.popup: opener=kept`.
2. Open a page with a `target="_blank"` link and click it: the linked page opens as a background tab right after the current tab.
3. Sign in to a site with a "Sign in with Google" popup: the popup closes after signing in and the site shows you signed in.
4. Run `make e2e`: the `engine.popup` check has the app take a `window.open` page as a background tab (the page itself asked for a foreground tab, the disposition shown) and prints `PASS engine.popup: requests=1 target=opened.html disposition=foregroundTab opener=kept first-navigation=opened.html`.

5. Run `make e2e E2E=popups`: it prints `PASS popups.newtab: tabs=[A,B]`, `PASS popups.cmd_click: tabs=[A,B,C] shown=A`, `PASS popups.cmd_shift_click: tabs=[A,B,C] shown=B`, `PASS popups.middle_click: tabs=[A,B,C] shown=A`, `PASS popups.blocked: opened=null tabs=[A] after-click=[A,B]`, `PASS popups.opener: tabs=[A,B] postMessage=received` and `PASS popups.storm: opened=1 tabs=[A,B]`.

## Out of scope

- Showing sized popups inside Bow's own window with its controls (a popup panel), and Peek.
- Choosing which popups a page may open without a click.
