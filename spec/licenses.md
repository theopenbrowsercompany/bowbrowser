# Licenses and credits

## Summary

The app ships the licenses its parts require, and the person can read them from the app menu.

## Behavior

- Bow.app/Contents/Resources holds CEF-LICENSE.txt (CEF's BSD license), Chromium-Credits.html (Chromium's third party credits) and Bow-LICENSE.txt (Bow's MIT license), in Debug and Release.
- The Bow menu starts with About Bow, which opens the standard About panel with one link per file; each link opens in the system's default app for it.

## Edge cases

- The build fails with a message naming the missing source file when CEF's files (through Vendor/cef) or the repository LICENSE are absent.
- `make release` fails when any of the three files is missing or empty in the Release app.

## Acceptance checks

1. Run `make e2e E2E=app.licenses`: it prints `PASS app.licenses: cef=yes chromium=yes bow=yes menu=yes`.
2. Run `make release`: it succeeds; remove one file from the built Release app and the check script fails naming it.

## Out of scope

- A dedicated acknowledgements window, and credits for packages added later.
