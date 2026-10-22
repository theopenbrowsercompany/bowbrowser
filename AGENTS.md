# bowbrowser

An Arc-inspired desktop browser for macOS, built by Arc fans and not affiliated with Arc, The Browser Company of New York, or Atlassian.
A native Swift app (AppKit) runs on Chromium, which comes in as a prebuilt engine (CEF, the Chromium Embedded Framework) behind a thin bridge.
This follows the pattern Arc and ChatGPT Atlas use: engineers and agents never compile Chromium, so app builds take minutes.

The maintainer's plan, issue board, research and architecture notes live in a private repository checked out at `../bowbrowser-private`; keep their content out of this repository.
The maintainer's `.claude/settings.local.json` adds that folder to every session here; elsewhere, start with `claude --add-dir ../bowbrowser-private`.

## Layout

- `App/Engine/`: the Objective-C++ bridge to CEF and the app entry point. It is the only code that includes CEF or C++ headers; everything else talks to the engine through the Objective-C API in its headers.
- `App/UI/`: Swift and AppKit windows, menus and the views that host web pages.
- `App/Helper/`: the CEF helper process. The build packages it as the helper apps Chromium needs (GPU, renderer, plugin, alerts).
- `BowCore/`: a Swift package for browser logic that needs no UI or engine (today: address and search input). Its tests run in seconds.
- `cef.lock`: the pinned CEF version and checksum. `Vendor/` holds the download and is gitignored.
- `project.yml`: XcodeGen spec. `Bow.xcodeproj` is generated from it and not committed, so edit `project.yml`, never the project file.
- `spec/`: behavior specs, one per feature area, following `spec/_template.md`.

## Commands

- `make bootstrap`: download CEF, build its wrapper library, generate the Xcode project. Run once, and again after `cef.lock` changes.
- `make hooks`: turn on the git hooks in `.githooks/`, which refuse pushes that add private paths or recordings (`make bootstrap` runs it).
- `make test`: BowCore unit tests.
- `make build`: build the app into `build/`.
- `make smoke`: build, open the app in a background window on a test page, print the result, quit. It puts a window on the maintainer's screen, so run it only when asked.
- `make verify`: lint, tests and build. A change is done when this passes.
- `make format`: format Swift sources.

## Working rules

- Put browser behavior in `BowCore` with tests whenever it does not need the engine or UI.
- When behavior changes, update its spec in the same change.
- The installed Arc app and `~/Library/Application Support/Arc` are the maintainer's real browser and profile: do not open, quit, script or read them.
- Commit locally on a branch or worktree. Pushing, tagging and releases happen only after the maintainer approves.

## Workflow

Every change follows this loop; steps 1 to 3 happen before any code changes.

1. **Pick.** Read `../bowbrowser-private/PLAN.md` and list the board with `grep -H '^status:' ../bowbrowser-private/issues/*.md`.
   Take the issue the maintainer names, or propose the lowest-numbered `todo` issue in the current phase and say why it is next.
2. **Plan.** Read the issue, its spec and the code it touches.
   If the feature has no spec, draft one from `spec/_template.md`, grounded in the private `research/` (start with `research/02-arc-feature-triage.md`).
   Write a short plan: the approach, the files that change, the tests, and how each "Done when" bullet will be checked.
   Ask about anything the issue leaves open instead of guessing.
3. **Review gate.** Present the plan and wait for the maintainer's yes before changing code.
   Small, clearly specified fixes may skip the gate; say so when skipping.
   Record the approved plan in the issue's Notes.
4. **Build.** Set the issue's `status` to `doing`, work in a worktree or branch named after it (for example `0003-tab-model`), and follow the working rules.
5. **Review.** Check every "Done when" bullet and say how it was verified, run `/code-review` on the diff and fix what it finds, then report what changed and what is still open.
6. **Close.** Commit with a message that describes the change, without private issue numbers or plans.
   Set the issue's `status` to `done` with the commit hash in its Notes, and open new issues for follow-ups instead of widening this one.
   Change `PLAN.md` only when a phase starts or ends or a decision changes.
