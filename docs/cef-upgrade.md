# Upgrading CEF

Bow runs on a prebuilt CEF (Chromium Embedded Framework) build pinned in `cef.lock`.
Chromium is never compiled here: an upgrade changes which prebuilt build Bow downloads, then adapts Bow's bridge (`App/Engine/`, `App/Helper/`, `E2E/Engine/`) to whatever changed in CEF's headers or Chromium's behavior.
This page is the runbook for that change, for a person or an agent; workers start from the `bow-cef-upgrade` skill in `.claude/skills/bow-cef-upgrade/SKILL.md`, which walks through it.

## Which builds Bow tracks

CEF publishes builds per Chromium milestone (156, 158 and so on) in its build index, https://cef-builds.spotifycdn.com/index.html, with the machine-readable list at https://cef-builds.spotifycdn.com/index.json.
Within a milestone, CEF ships new patch builds (for example 156.0.7, then 156.0.8) as Chromium releases security and stability fixes, and stops shipping them a few weeks after the next milestone reaches stable.

Current practice: Bow adopts the newest stable build of the pinned milestone within a week of its release, and moves to a new milestone as its own planned change.

Open maintainer decision: which channel Bow tracks in the long run (Stable, Extended or LTS) is not decided yet.
Stable means following each new milestone about every four weeks; Extended means staying on every other milestone for about eight weeks; LTS means a long-lived milestone with backported fixes.
On 2026-10-23 the CEF build index listed only `stable` and `beta` builds for `macosarm64`, so Extended or LTS would also mean deciding where those builds come from.
Until the maintainer decides, follow the current practice above and do not change channel.

## The pin

`cef.lock` has four lines that always change together:

- `CEF_VERSION`: the full CEF version, for example `156.0.8+g426920c+chromium-156.0.8078.48`.
- `CEF_PLATFORM`: `macosarm64`.
- `CEF_DIST`: `minimal` (the build without debug symbols or sample apps).
- `CEF_SHA1`: the SHA-1 of the archive, copied from the index and checked by `make bootstrap`.

`make bootstrap` downloads the archive into the shared cache (`~/Library/Caches/bowbrowser`), checks `CEF_SHA1`, builds CEF's small C++ wrapper library once, and links `Vendor/cef` to it.
Each CEF build gets its own folder in the cache, so other worktrees still pinned to the old build keep working; leave the old folder in place until every open branch has moved.

## Finding the target build

1. Download the index into a fresh folder: `mkdir -p /tmp/cef-index` and `curl -sS -o /tmp/cef-index/index.json https://cef-builds.spotifycdn.com/index.json`.
2. List the stable builds of a milestone with their minimal archive and checksum, newest first:
   `jq -r '.macosarm64.versions[] | select(.channel=="stable") | select(.cef_version|startswith("156.")) | .cef_version + " " + ([.files[]|select(.type=="minimal")|.sha1+" "+.name]|join(","))' /tmp/cef-index/index.json`
3. Take the first line: its version goes into `CEF_VERSION` and its SHA-1 into `CEF_SHA1`.
   Check the archive name ends in `_macosarm64_minimal.tar.bz2`, not `_beta_minimal`.

## Checklist A: a patch build inside the pinned milestone

Use this when only the last parts of the version change (156.0.7 to 156.0.8) and the Chromium milestone stays the same.
Expect few or no breaks: CEF keeps its API stable within a release branch.

1. Branch from a fresh `origin/main` (for example `cef-156-0-8`).
2. Find the target build as above and change all four `cef.lock` lines in one edit; keep the comment lines at the top.
3. Run `make bootstrap`; it must print `CEF <version> is ready at Vendor/cef`, and a checksum mismatch stops it.
4. Compare the headers of the old and new builds: `diff -rq <cache>/<old build>/include Vendor/cef/include`.
   For a patch build this usually shows only `cef_version.h`, dates in `cef_api_versions.h` and new IDs in `cef_command_ids.h` or `cef_pack_strings.h`.
   Read any other changed header and note what Bow uses from it.
5. Commit the `cef.lock` change on its own, naming the new CEF and Chromium versions.
6. Run `make build` until it succeeds.
   Fix each break in its own commit, as described in "Fixing a break" below.
7. Run `make check` while fixing, then rebase onto `origin/main` and run `make done` (verify, the full e2e and its repeats).
8. Run `make release`.
9. Hand the maintainer the manual checks below, with the branch and commit.

## Checklist B: a milestone move

Use this when the Chromium milestone changes (156 to 158 or 160).
Plan for real breaks: CEF changes its C++ API between milestones, and Chromium changes behavior Bow relies on.

1. Branch from a fresh `origin/main` (for example `cef-158`).
2. Read what changed before touching the pin:
   - CEF's release notes and the commits on the new release branch at https://github.com/chromiumembedded/cef, especially changes under `include/`.
   - Chromium's release notes for each milestone skipped, for removed command line switches, sandbox changes and macOS requirements.
3. Find the target build (the newest stable build of the new milestone) and change all four `cef.lock` lines in one edit.
4. Run `make bootstrap`.
5. Diff the old and new `include/` folders as in checklist A step 4, and list every changed header Bow includes (`git grep -n '#include "include/' App E2E`).
   Pay attention to:
   - `cef_api_versions.h` and `cef_version.h`: whether the API version Bow builds against changed.
   - Handler interfaces Bow implements (life span, load, display, request, permission, dialog, download, context menu, keyboard, find, DevTools, render process handler in the helper): a renamed or re-signatured virtual method silently stops being called unless it is marked `override`.
   - `cef_command_ids.h`, if Bow filters or adds context menu commands.
   - Command line switches Bow passes, which a new milestone can rename or drop.
6. Check the packaging: `scripts/package-cef.sh` copies the framework and builds the helper apps Chromium expects (GPU, renderer, plugin, alerts); a new milestone can add or rename a helper or a framework resource.
7. Commit the `cef.lock` change on its own.
8. Run `make build` until it succeeds, fixing each break in its own commit (below).
9. Run the full `make e2e`; a behavior change shows up as a failing area, not a build error.
   Fix each in its own commit naming the Chromium or CEF change, and update the spec in `spec/` for any behavior that changed on purpose.
10. Rebase onto `origin/main`, run `make done` and `make release`.
11. Hand the maintainer the manual checks below.

## Fixing a break

- One break, one commit: its message names the CEF or Chromium change it adapts to (the CEF commit or issue, the Chromium change or the header and method that changed), so a later reader can see why the bridge changed.
- Adapt Bow to the new CEF; never patch CEF or Chromium, and never comment out or delete a feature to get a green build.
- Keep C++ in `+Internal.h` headers and `.mm` files; the headers Swift sees stay plain Objective-C (`make verify` checks this).
- When a fix needs a new decision (which item, what order, what default), put the decision in `BowCore` with unit tests, as for any other change.
- If a break cannot be adapted without losing behavior, stop and report it with the CEF change behind it, rather than working around it.

## Exit criteria

The upgrade is done only when all of these hold:

1. `cef.lock` pins the target build, with all four lines changed together and `CEF_SHA1` matching the index.
2. `make done` passes on the rebased branch: `make verify`, the full `make e2e` with `E2E: PASS n/n`, and the repeats.
   A FLAKY result is not a pass.
3. `make release` passes.
4. Each bridge fix is its own commit naming the change it adapts to.
5. The maintainer has done the manual checks below and reported no regression.

## Manual checks for the maintainer

The e2e suite runs off screen with no sound output and cannot judge how media looks or sounds, so the maintainer checks these by hand once per upgrade.
Agents never run these: they never run `make smoke` or `make run` and never put a window on the maintainer's screen; they hand this list over instead.

1. Build and open the branch with `make run`.
2. Sound: play a video with sound (for example on YouTube) and confirm the audio plays, pauses and resumes.
3. Video: confirm the video plays smoothly at full resolution, seeks, and enters and leaves full screen.
4. GPU: open `chrome://gpu` and confirm the Graphics Feature Status shows hardware acceleration for compositing, rasterization, video decode and WebGL; open a WebGL page and confirm it renders.
5. Sandbox: with Bow open, run `ps -axo command | grep '[B]ow Helper (Renderer)'`; every renderer command line contains `--seatbelt-client=` and none contains `--no-sandbox`.
6. DevTools: right click a page, choose Inspect, and confirm DevTools opens and shows the page (the e2e suite never opens DevTools).
7. Quit Bow and confirm it quits promptly and leaves no `Bow Helper` processes behind (`ps -axo command | grep '[B]ow Helper'` prints nothing).
