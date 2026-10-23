# Default browser

## Summary

The Bow menu offers to make Bow the system's default browser, so links from other apps open in Bow.

## Behavior

- The Bow menu has an item right after About Bow: "Set as Default Browser…" (the wording of Chrome's item; the research has no Arc wording).
- Choosing it asks macOS to make Bow the handler of http links, then https links. macOS shows its own confirmation, so the request waits for the person's answer and the app stays usable meanwhile.
- When macOS already opens http links with Bow, the item reads "Bow Is Your Default Browser" and is disabled.
- While a request waits for macOS, the item is disabled, so a second choice cannot start a second request.
- If the person declines macOS's confirmation, nothing more is asked (https is skipped) and no alert shows.
- Any other failure shows an alert sheet on the window: "Bow could not be set as your default browser", naming the scheme and macOS's reason, with an OK button.
- The decisions (the schemes, whether Bow is the default, the titles, what counts as a refusal) are BowCore's `DefaultBrowser`.

## Edge cases

- The item's state is read each time the menu opens, so it follows changes made in System Settings.
- With no window open, the alert is an app modal alert.
- Debug builds with the e2e harness contain no real registrar: the NSWorkspace calls live in a type that is not compiled into them, and a blocked registrar that refuses and counts its calls takes its place until a test installs a recorder.

## Acceptance checks

1. `make e2e E2E=defaultbrowser`: `PASS defaultbrowser` (http then https for Bow's bundle, the real setter never reached), `PASS defaultbrowser.twice`, `PASS defaultbrowser.cancel`.
2. `make e2e E2E=defaultbrowser.already`: the item shows the "is your default" title, disabled, and registers nothing.
3. `make e2e E2E=defaultbrowser.failure`: the alert sheet comes up, is answered through its OK button, and https is not tried.

## Out of scope

- Prompting to become the default at first launch, and Little Arc's window for links from other apps (see link-routing).
