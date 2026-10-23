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
- Modified link clicks: a Cmd-click, Cmd-Shift-click, Shift-click or middle click on a link asks the same question, with the modifiers its disposition names (a background tab is Command or a middle click, a foreground tab Command and Shift, a new window Shift).
  A tab answer opens the link in a new tab of the same profile, with no `window.opener`, handed to the window like any new page as a tab; a block opens nothing; with no answer the link opens in its own tab, as before.
- New page as a tab: a new page the app asked for as a tab arrives already created and still connected to its opener (`window.opener`), and the window can take it as a sidebar tab in its opener's Space, right after its opener when that is a today tab, or at the top of today; a new tab from a Space not on screen stays in that Space without changing what is shown.
  While a window is closing its pages' new pages open in the engine's own popup window.
  A new tab nobody takes is closed, so no page runs unseen.
- Keys: every key press reaches the app before the page; a key the app claims never reaches the page, neither its press nor its release, and the keys after it reach the page as usual.
  With no claim the page gets the key.
  The app shortcuts features claim (Cmd+T, Cmd+L, Cmd+Shift+C, Cmd+Shift+D, Cmd+plus, Cmd+minus, Cmd+0, Ctrl+Tab) are listed in one place with the feature that claims each, and no key may have two owners.
- New Tab: choosing New Tab asks the features first (the command bar takes it once it exists); with no taker a new tab opens on the new tab page.
- Page container: window chrome can inset the page area, round its corners and run the window's content under a transparent title bar without changing the window core; by default the page fills the window beside the sidebar with square corners.
- Zoom: zooming a page zooms every tab on the same site in that profile, now and later.
- Zoom keys and menu: Cmd+plus (also Cmd+=), Cmd+minus and Cmd+0 are taken before the page, and View > Zoom In, Zoom Out and Actual Size do the same.
  Zoom In and Out move to the next preset size (25, 33, 50, 67, 75, 80, 90, 100, 110, 125, 150, 175, 200, 250, 300, 400, 500 percent), Actual Size goes back to 100%, and another site keeps its own zoom.
  The items are disabled at the largest and smallest size, and Actual Size at 100%; the keys are still taken there, so the page never sees them.
- Crashed page: when a tab's page process ends (a crash, a kill or running out of memory), the page area shows "This page crashed" with a Reload button while that tab is shown.
  Reload reloads the tab and takes the message away, as does any navigation the tab starts; a tab that crashed in the background shows the message once it is shown.
- Copy Image: the context menu's Copy Image puts the image itself on the pasteboard, fetched through the tab's own profile; an image that cannot be fetched leaves the pasteboard alone.
- Unloading: the app can free a page's memory and keep its tab (see `unload.md`).
- Why a tab closed: once a tab has closed, the app can tell whether it closed it, the page closed itself (`window.close()`, or a page that could not be created at all), or quitting closed it, so a window drops a tab that closed itself from its sidebar.
- Sound: a tab never reports playing sound yet, because the engine version Bow uses gives no signal for it.
- Camera and microphone: a tab reports while its page uses a camera or a microphone (or captures the screen).
- Sign in and certificates: a site asking for a user name and password, or a page whose certificate fails to verify, asks the app.
  With no answer the sign in is cancelled, so the page shows the site's own 401 page, and a certificate error fails the page with the engine's error page.
  Chrome's own sign in prompt is turned off, so every sign in request reaches the app.
  Only a top level page's certificate error asks the app; the engine blocks a frame's or a subresource's on its own.
  A way past a certificate error may be offered only for errors that do not prove the certificate bad (an untrusted authority, a name or date mismatch and the like, never a revoked, invalid or pinned key error) and never for a site that requires HTTPS (HSTS); going past lasts for that host, error and certificate in the current session only and is never saved.
  The engine version Bow uses does not say whether a site requires HTTPS, so no way past is offered until something else can tell.
- Context menus: a right click (or Control-click) in a page asks the app what to show, with what is under the pointer: the link and its address, an image's address, the selected text, whether it is a field the person can type in and what that field can do now (undo, cut, copy, paste and so on), the frame's address, the position and the tab's profile.
  The app answers with its own items, the engine's own menu, or nothing; either menu shows as a native macOS menu at the pointer.
  With no feature answering, a window shows Bow's own menu, built the way Chromium based browsers and Arc build theirs: Open Link in New Tab and Copy Link Address on a link, Copy Image and Copy Image Address on an image, editing items in a field, Copy on a selection, Back, Forward and Reload on a bare page, and Inspect last.
  The chosen item goes to the app first and otherwise runs in the engine.
  Open Link in New Tab opens the link as a new today tab right after the tab, in the background, as a Cmd-click does.
- DevTools: Inspect opens DevTools for the tab and inspects the element under the pointer.
  It opens in a window of its own, since the engine version Bow uses supports DevTools only as a Chrome style window, which cannot be docked into Bow's window.
  DevTools closes with its tab, and quitting closes it.

## Edge cases

- A page that closes itself while the app is closing it counts as closed by the app.
- A tab that closed while quitting counts as closed by quitting, even when another page then asks to stay and the quit is cancelled.
- A page opened as a tab whose opener closes before the new page exists is closed, never left without an owner.
- Pressing another key before releasing a claimed one still keeps the claimed key's release from the page.
- A modified click on a link (Cmd-click, also on a `target="_blank"` link) is not a new page request yet: the engine version Bow uses reports it on a different path the app does not handle, so it reaches no feature.
- A `target="_blank"` link keeps `window.opener` only when it asks for it (`rel="opener"`); otherwise the new page is not connected to its opener, as in every current browser.
- A window that starts closing between a new page's decision and its arrival takes no new tab; the new tab is closed.
- A choice made after the page moved to another address, or closed, while its menu was open is dropped.
- A context menu from a tab the window does not own gets the engine's own menu.
- Inspect on a tab with no page (closed or unloaded) does nothing.
- The link text is not part of a context menu request yet: the engine version Bow uses does not report it.

## Acceptance checks

1. Run `make e2e E2E=engine`: it prints `PASS engine.popup`, `PASS engine.key`, `PASS engine.zoom`, `PASS engine.unload` and `PASS engine.close-reason: reason=page unload-after-close=false`.
2. `engine.key` prints the keys the page saw: `page-down` and `page-up` hold only `j`, never `k`.
3. Run `make e2e E2E=window`: a `target="_blank"` link clicked in tab A becomes the sidebar tab after A, shown and still connected to A, printing `PASS window.adopt: tabs=[A,B] opener=kept`.
4. `make test` checks that no app shortcut is claimed by two features.
5. Run `make e2e E2E=window`: right clicking a link reaches the app with its address, and choosing Open Link in New Tab opens it as the next tab, printing `PASS window.context-menu: link=opened.html tabs=[A,B]` followed by the items shown; choosing Inspect asks the tab's DevTools to inspect the element under the pointer with nothing shown on screen, printing `PASS window.inspect: requests=1 at-element=true`.
6. `make test` checks Bow's menu for links, images, fields, selections and bare pages.
7. Run `make e2e E2E=page`: `PASS page.zoom.keys`, `PASS page.zoom.menu` and `PASS page.zoom.site` for zoom by key and menu with another site keeping its own level; `PASS page.crash.overlay` and `PASS page.crash.reload` for a crashed page and its Reload button; `PASS page.copy-image` for the copied image's data.
8. Run `make e2e E2E=engine.challenges`: a page answering 401 with a Basic challenge asks the window, which cancels, printing a line starting `PASS engine.auth_hook: questions=[basic auth.bow.test:80 realm=bow answer=cancel] ended=finish http://auth.bow.test/ 401`; a page with a self-signed certificate asks the window, which cancels, printing a line starting `PASS engine.cert_hook: questions=[https://badcert.bow.test/ -202 answer=cancel] ended=fail https://badcert.bow.test/ -202`.
9. `make test` checks when a way past a certificate error may be offered and remembered (`CertificateAllowancesTests`).

## Out of scope

- Camera or microphone state has no `make e2e` check yet: no fixture captures media.
- The sign in sheet and the certificate error page themselves are later work; until then the window answers both questions with cancel.
- The keys still held when a script opens a page from a click (`window.open` in a click handler) have no `make e2e` check: test clicks come through DevTools, which holds no real keys; modified link clicks are checked in `popups.md`.
- DevTools opening and closing with its tab has no `make e2e` check: e2e runs record the request instead, because the DevTools window would show on screen and take focus.
- Docking DevTools inside the window is later work.
- Quitting while an unload is pending has no `make e2e` check: quitting ends the run, and the window in which an unload's answer can race the quit is a fraction of a second that a test cannot hold open.
