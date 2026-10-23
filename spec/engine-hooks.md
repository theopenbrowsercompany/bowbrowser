# Engine hooks

## Summary

The engine tells the app about each page and asks it before acting, so window features (link handling, shortcuts, the sidebar, memory saving) can decide what happens.
This spec covers what those hooks promise; the features that use them have their own specs.

## Behavior

- New pages: when a page opens another, the app decides where the new page goes (see `popups.md`).
- Keys: every key press reaches the app before the page; a key the app claims never reaches the page, neither its press nor its release, and the keys after it reach the page as usual.
- Zoom: zooming a page zooms every tab on the same site in that profile, now and later.
- Unloading: the app can free a page's memory and keep its tab (see `unload.md`).
- Why a tab closed: once a tab has closed, the app can tell whether it closed it, the page closed itself (`window.close()`, or a page that could not be created at all), or quitting closed it, so a window drops a tab that closed itself from its sidebar.
- Sound: a tab never reports playing sound yet, because the engine version Bow uses gives no signal for it.
- Camera and microphone: a tab reports while its page uses a camera or a microphone (or captures the screen).
- Sign in and certificates: a site asking for a user name and password, or a page whose certificate fails to verify, asks the app; with no answer the sign in is cancelled and the page fails with the engine's error page.

## Edge cases

- A page that closes itself while the app is closing it counts as closed by the app.
- A page opened as a tab whose opener closes before the new page exists is closed, never left without an owner.
- Pressing another key before releasing a claimed one still keeps the claimed key's release from the page.

## Acceptance checks

1. Run `make e2e E2E=engine`: it prints `PASS engine.popup`, `PASS engine.key`, `PASS engine.zoom`, `PASS engine.unload` and `PASS engine.close-reason: reason=page unload-after-close=false`.
2. `engine.key` prints the keys the page saw: `page-down` and `page-up` hold only `j`, never `k`.

## Out of scope

- Sign in, certificate errors and camera or microphone state have no `make e2e` check yet: the test server serves neither a password protected page nor a bad certificate, and no fixture captures media.
- Quitting while an unload is pending has no `make e2e` check: quitting ends the run, and the window in which an unload's answer can race the quit is a fraction of a second that a test cannot hold open.
