# bowbrowser

An Arc-inspired desktop browser for macOS, built by Arc fans and not affiliated with Arc, The Browser Company of New York, or Atlassian.
A native Swift app (AppKit) runs on Chromium, which comes in as a prebuilt engine (CEF, the Chromium Embedded Framework) behind a thin bridge.
This follows the pattern Arc and ChatGPT Atlas use: engineers and agents never compile Chromium, so app builds take minutes.
`spec/` has the behavior specs.
Plans, the issue board and architecture notes live in the maintainer's private repository at `../bowbrowser-private` when it is present (start with its `PLAN.md` and `WORKFLOW.md`, which says how issues are planned, reviewed and closed); keep them out of this repository.

## Layout

- `App/Engine/`: the Objective-C++ bridge to CEF and the app entry point. It is the only code that includes CEF or C++ headers; everything else talks to the engine through the Objective-C API in its headers.
- `App/UI/`: Swift and AppKit windows, menus and the views that host web pages.
- `App/Helper/`: the CEF helper process. The build packages it as the helper apps Chromium needs (GPU, renderer, plugin, alerts).
- `BowCore/`: a Swift package for browser logic that needs no UI or engine (today: address and search input). Its tests run in seconds.
- `Engine/cef.lock`: the pinned CEF version and checksum. `Vendor/` holds the download and is gitignored.
- `project.yml`: XcodeGen spec. `Bow.xcodeproj` is generated from it and not committed, so edit `project.yml`, never the project file.

## Commands

- `make bootstrap`: download CEF, build its wrapper library, generate the Xcode project. Run once, and again after `Engine/cef.lock` changes.
- `make hooks`: turn on the git hooks in `.githooks/`, which refuse pushes that add private paths or recordings (`make bootstrap` runs it).
- `make test`: BowCore unit tests.
- `make build`: build the app into `build/`.
- `make smoke`: build, open the app in a background window on a test page, print the result, quit. It puts a window on the maintainer's screen, so run it only when asked.
- `make verify`: lint, tests and build. A change is done when this passes.
- `make format`: format Swift sources.

## Working rules

- Put browser behavior in `BowCore` with tests whenever it does not need the engine or UI.
- Behavior specs live in `spec/` and follow `spec/_template.md`.
- The installed Arc app and `~/Library/Application Support/Arc` are the maintainer's real browser and profile: do not open, quit, script or read them.
- Commit locally on a branch or worktree. Pushing, tagging and releases happen only after the maintainer approves.
