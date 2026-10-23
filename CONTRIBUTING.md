# Contributing

Thanks for helping build Bow.
Small, focused changes are the easiest to review.

## Build and check

```sh
make bootstrap   # once per checkout: download the pinned Chromium Embedded Framework and generate the Xcode project
make verify      # lint, checks, tests and the Debug build
make e2e         # run the end-to-end tests in the real app
```

Run `make verify` before every pull request.
Also run `make e2e` (or `make e2e E2E=<area>` for one area) when you change behavior.
`AGENTS.md` describes the full repository layout and the working rules.

## Spec first

Behavior is specified in `spec/`, one file per feature area.
When a change alters what a user sees or does, update the matching spec in the same pull request.
If no spec covers the area, start one from `spec/_template.md`.
Write only what any user can observe in a browser.

## Never copy Arc

Bow follows Arc's behavior, not its code.
Do not copy Arc's code, assets, strings or screenshots, or anything from another browser.

## Pull requests

- Keep each pull request to one change.
- Say how you verified it: the `make verify` and `make e2e` results, plus anything you checked by hand.
- Note whether you updated a spec, or why none was needed.
