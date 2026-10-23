# Pages that open pages

## Summary

When a page opens another page (a link that opens in a new tab, a modified click on a link, or a script that opens a new window), the new page opens as a tab of the window, right after the tab that opened it, or in a popup panel (a small window attached to the browser window) when the page asks for a sized window or opens a sign in page.
A page a script opened stays connected to the page that opened it.
That connection is what sign in popups (for example Google or GitHub sign in) use to report back, so those flows keep working.

## Behavior

- A link meant to open in a new tab or window (for example `target="_blank"`) opens its page in a new tab of the window.
- A script that opens a window (`window.open`) after a click opens its page in a new tab of the window; with a size it opens a popup panel.
- A Cmd-click, Cmd-Shift-click, Shift-click or middle click on a link opens it in a new tab and leaves the clicked tab on its page.
- The new page can reach the page that opened it through `window.opener`, so a sign in popup can report back and close itself.
- The new page uses the same profile as the page that opened it.
- The engine asks the app where each new page goes: a new tab, a tab in the background, a popup panel, a window of its own, or nowhere (blocked).
  The window answers with the rules below, and new kinds of answer (Peek) come later.
- A link opened with a modified click has no `window.opener`, as in other browsers.
- A new page the app takes as a tab is still connected to the page that opened it through `window.opener`.
- The app owns such a tab before its first navigation, so the app's rules for where pages may go apply to that first page too.

## Where new tabs go

- A page that opens a new page without a click or key press from you is blocked: nothing opens, and the page gets no window back and keeps working.
- One click opens at most one new page: a page that calls `window.open` many times from one click gets one tab.
- A middle click opens in the background, like a Cmd-click.
- A script window with a size (a sign in popup) opens in a popup panel and keeps `window.opener` (see Popup panels).
- A plain click that opens an identity provider's sign in page (Google, Microsoft, Apple, GitHub sign in) opens it in a popup panel too, with or without a size; a modified click on it still opens a tab.
- A link meant for a new tab (`target="_blank"`) opens in the foreground, right after the tab that opened it, as in Chromium and Arc.
- A `window.open` after a click opens in the foreground, right after the tab that opened it.
- A Cmd-click opens in the background, right after the tab that opened it.
- A Cmd-Shift-click opens in the foreground, right after the tab that opened it.
- A Shift-click opens in the foreground for now; it becomes Peek later.
- A link opened from a pinned tab or a Favorite puts the new tab at the top of Today instead, because those tabs sit above Today.

## Popup panels

Arc shows sign in popups in a small window of their own, over the browser window, instead of as a tab; Bow does the same with a popup panel.

- The panel is a small window attached to the browser window: it sits centered over the window and moves with it.
- Its page area has the size `window.open` asked for, never smaller than 320 by 240 points and never larger than the window less a 20 point margin on each side; a side the page did not set is 500 wide or 640 high. The position the page asked for is ignored.
- Its title bar shows the page's title and the site it is on, so you can see where you are signing in.
- The panel's page keeps `window.opener`, so it can report back to the page that opened it.
- The panel closes when its page calls `window.close()` (a finished sign in), when you close it with its close button (the page is asked first), and when the tab that opened it or its window closes; quitting closes it with everything else. No panel outlives its window.
- A panel that moves on to another site (the site's own sign in callback, for example) stays a panel until it closes.
- Pages a panel's page opens open in popup windows of their own, as the pages popup windows open do.
- Each click opens its own panel; a second panel sits a little lower and to the right of the first.
- A panel opens with the keyboard in its page when the browser window has it, and never takes focus from another app.

## Edge cases

- Bow cannot tell a plain link to a new tab from a script's `window.open` after a click, so both open as a foreground tab.
- A new tab whose opener closes before the engine has created its page goes away with the opener; once created it stays open and loads on its own.
  A window that is closing opens its pages' new pages in popup windows of their own instead of taking tabs.
- A new tab to a page that cannot load opens and shows the engine's error page, like any tab.
- Closing a popup window leaves the window that opened it open, and quitting closes popups with everything else.
- A popup window has no Bow tab bar or address bar yet.

## Acceptance checks

1. Run `make e2e`: the `nav.popup` check opens a sized popup (a popup panel) and a plain `window.open` page (a foreground tab) from a fixture, both report back through `window.opener`, and it prints `PASS nav.popup: opener=kept`.
2. Open a page with a `target="_blank"` link and click it: the linked page opens as a foreground tab right after the current tab.
3. Sign in to a site with a "Sign in with Google" popup: the popup closes after signing in and the site shows you signed in.
4. Run `make e2e`: the `engine.popup` check has the app take a `window.open` page as a tab (the engine's disposition shown) and prints `PASS engine.popup: requests=1 target=opened.html disposition=foregroundTab opener=kept first-navigation=opened.html`.

5. Run `make e2e E2E=popups`: it prints `PASS popups.newtab: tabs=[A,B] shown=B`, `PASS popups.cmd_click: tabs=[A,B,C] shown=A`, `PASS popups.cmd_shift_click: tabs=[A,B,C] shown=B`, `PASS popups.middle_click: tabs=[A,B,C] shown=A`, `PASS popups.blocked: opened=null tabs=[A] after-click=[A,B]`, `PASS popups.opener: tabs=[A,B] postMessage=received` and `PASS popups.storm: opened=1 tabs=[A,B]`.
6. Run `make e2e E2E=popups`: it prints `PASS popups.oauth: panel=480x560 attached=yes postMessage=received closed=yes tabs=[A]`, `PASS popups.panel_close: without-click=blocked close-button=closed reopened=1 tabs=[A] opener-closed=closed` and `PASS popups.panel_window_close: panels=1 window-closed=panel-closed`.

## Out of scope

- Address bar, back and forward controls in a popup panel, moving a panel's page into a tab, and Peek.
- Choosing which popups a page may open without a click.
