---
name: bow-cef-upgrade
description: Move Bow to a newer prebuilt CEF build, either a patch build inside the pinned Chromium milestone (156.0.7 to 156.0.8) or a milestone move (156 to 158). Use when a work item asks to bump cef.lock, adopt a newer CEF or Chromium, or pick up a CEF security release.
---

# Upgrading Bow's CEF

The runbook is `docs/cef-upgrade.md` in this repository.
Read it whole before starting, then follow it step by step; this skill only says how to move through it.

## When to use

- A work item names a new CEF or Chromium version, or asks for the newest stable build of the pinned milestone.
- Not for changing which channel Bow tracks (Stable, Extended or LTS): that is the maintainer's open decision, so leave it and say so in the report.

## Phase 1: pin and bootstrap

1. Decide which checklist applies: A when only the patch build changes inside the same milestone, B when the milestone changes.
2. Find the target build in CEF's `index.json` as the runbook shows, and check its SHA-1 against the index yourself, even when a brief already gives one.
3. Change all four `cef.lock` lines in one edit, run `make bootstrap`, and diff the old and new `include/` folders.
4. Commit the `cef.lock` change on its own.

Phase 1 is done when `make bootstrap` prints `CEF <version> is ready at Vendor/cef` for the target build and the pin is committed.

## Phase 2: build, fix, verify

1. Run `make build`; on a failure, fix one break, commit it with a message naming the CEF or Chromium change it adapts to, and build again.
2. Never patch CEF, never comment out a feature, and never drop a check to get a green build; stop and report a break that cannot be adapted.
3. Run `make check` while fixing; when it builds, rebase onto `origin/main` and run `make done`, then `make release`.
4. Copy the runbook's manual checks into the report for the maintainer; never run them yourself (no `make smoke`, no `make run`, no window on the maintainer's screen).

## Exit criteria

Do not report done until every exit criterion in the runbook holds except the maintainer's manual checks, which the report hands over:

- `cef.lock` pins the target build with a verified checksum.
- `make done` passes (no FAIL and no FLAKY) and `make release` passes.
- Each bridge fix is its own commit naming the change it adapts to.

The report pastes the `make done` block, the `make release` result, the checksum check, and the list of bridge fixes (or "none").
