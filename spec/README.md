# Behavior specs

Each spec describes what a user sees and does, in plain language: the actions, what happens, the edge cases and how to check it works.
Specs say nothing about implementation; the code and its tests own that.

- One file per feature area, named in kebab case: `sidebar-tabs.md`, `spaces.md`, `command-bar.md`.
- Start from `_template.md` and keep its sections in order.
- Write from public behavior only: what any user can observe in a browser.
  Never copy another browser's code, assets, strings or screenshots.
- Acceptance checks are concrete steps with an expected result, so a person or an agent can run them by hand.
- When behavior changes, update the spec in the same change.
