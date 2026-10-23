# Engine hooks

## Summary

The engine tells the app about each page and asks it before acting, so window features (link handling, shortcuts, the sidebar, memory saving) can decide what happens.
This spec covers what those hooks promise; the features that use them have their own specs.

## Behavior

- Who answers: a window answers each hook for its own tabs by asking its features in order; the first feature that answers decides, and with no answer the window keeps the default each hook below names, so a window with no answering feature behaves as before.
  A hook from a tab the window does not own gets the default at once.
- New pages: when a page opens another, the app decides where the new page goes (see `popups.md`).
  With no answer it opens in the engine's own popup window.
  The request says whether Command and Shift were held at the click, as far as the engine can tell: a background tab means Command, a new window means Shift, and a foreground tab (a plain `target="_blank"` link and Cmd-Shift-click arrive alike) reads the keys still held as the request arrives.
- New page as a tab: a new page the app asked for as a tab arrives already created and still connected to its opener (`window.opener`), and the window can take it as a sidebar tab in its opener's Space, right after its opener when that is a today tab, or at the top of today; a new tab from a Space not on screen stays in that Space without changing what is shown.
  While a window is closing its pages' new pages open in the engine's own popup window.
  A new tab nobody takes is closed, so no page runs unseen.
- Keys: every key press reaches the app before the page; a key the app claims never reaches the page, neither its press nor its release, and the keys after it reach the page as usual.
  With no claim the page gets the key.
  The app shortcuts features claim (Cmd+T, Cmd+L, Cmd+Shift+C, Cmd+plus, Cmd+minus, Cmd+0, Ctrl+Tab) are listed in one place with the feature that claims each, and no key may have two owners.
- New Tab: choosing New Tab asks the features first (the command bar takes it once it exists); with no taker a new tab opens on the new tab page.
- Page container: window chrome can inset the page area, round its corners and run the window's content under a transparent title bar without changing the window core; by default the page fills the window beside the sidebar with square corners.
- Zoom: zooming a page zooms every tab on the same site in that profile, now and later.
- Unloading: the app can free a page's memory and keep its tab (see `unload.md`).
- Why a tab closed: once a tab has closed, the app can tell whether it closed it, the page closed itself (`window.close()`, or a page that could not be created at all), or quitting closed it, so a window drops a tab that closed itself from its sidebar.
- Sound: a tab never reports playing sound yet, because the engine version Bow uses gives no signal for it.
- Camera and microphone: a tab reports while its page uses a camera or a microphone (or captures the screen).
- Sign in and certificates: a site asking for a user name and password, or a page whose certificate fails to verify, asks the app; with no answer the sign in is cancelled and the page fails with the engine's error page.

## Edge cases

- A page that closes itself while the app is closing it counts as closed by the app.
- A tab that closed while quitting counts as closed by quitting, even when another page then asks to stay and the quit is cancelled.
- A page opened as a tab whose opener closes before the new page exists is closed, never left without an owner.
- Pressing another key before releasing a claimed one still keeps the claimed key's release from the page.
- A modified click on a link (Cmd-click, also on a `target="_blank"` link) is not a new page request yet: the engine version Bow uses reports it on a different path the app does not handle, so it reaches no feature.
- A `target="_blank"` link keeps `window.opener` only when it asks for it (`rel="opener"`); otherwise the new page is not connected to its opener, as in every current browser.
- A window that starts closing between a new page's decision and its arrival takes no new tab; the new tab is closed.

## Acceptance checks

1. Run `make e2e E2E=engine`: it prints `PASS engine.popup`, `PASS engine.key`, `PASS engine.zoom`, `PASS engine.unload` and `PASS engine.close-reason: reason=page unload-after-close=false`.
2. `engine.key` prints the keys the page saw: `page-down` and `page-up` hold only `j`, never `k`.
3. Run `make e2e E2E=window`: a `target="_blank"` link clicked in tab A becomes the sidebar tab after A, shown and still connected to A, printing `PASS window.adopt: tabs=[A,B] opener=kept`.
4. `make test` checks that no app shortcut is claimed by two features.

## Out of scope

- Sign in, certificate errors and camera or microphone state have no `make e2e` check yet: the test server serves neither a password protected page nor a bad certificate, and no fixture captures media.
- Click modifiers have no `make e2e` check: test clicks come through DevTools, which holds no real keys, and modified link clicks do not reach the popup hook yet.
- Quitting while an unload is pending has no `make e2e` check: quitting ends the run, and the window in which an unload's answer can race the quit is a fraction of a second that a test cannot hold open.
