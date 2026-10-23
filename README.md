# bowbrowser

An Arc-inspired browser for macOS, built in Swift on Chromium.
Built by Arc fans.

Website: https://www.bowbrowser.com

Status: early work in progress.

_Not affiliated with Arc, The Browser Company of New York, or Atlassian._

## What works today

Bow is an early preview that adds the core Arc features people love, a few at a time.

- A vertical sidebar with pinned and Today tabs
- Drag a tab across the divider to pin or unpin it
- Your tabs and sidebar come back after you quit and relaunch
- Back, forward, reload and find in page
- Downloads you can pause, resume and cancel
- Permission prompts kept separately for each profile
- Background tabs stop drawing until you open them
- A clear empty state when a Space has no tabs

## Coming next

- Spaces you switch with Ctrl+1 to 9 or a swipe, each with its own profile
- Nested folders and a Favorites grid
- The Cmd+T command bar
- Auto-archive of Today tabs
- Peek, Little Arc, split view and Air Traffic Control
- Minimal chrome with Cmd+L and Cmd+Shift+C
- Importing your Arc sidebar

Extensions come later.
Missing something you love? Please [open an issue](https://github.com/theopenbrowsercompany/bowbrowser/issues) with your request.

## Requirements

- macOS 14 or later on Apple Silicon (the app targets macOS 14 and builds for arm64 only)
- Xcode 26 (tested with Xcode 26.6)
- Homebrew `cmake` and `xcodegen`

## Build

```sh
make bootstrap   # download the pinned Chromium Embedded Framework and generate the Xcode project
make run         # build and open the app
make verify      # lint, checks, tests and the Debug build
```

Chromium comes in as a prebuilt engine (CEF), so building the app never compiles Chromium.

## Contributing

Read `CONTRIBUTING.md` first; `AGENTS.md` describes how the repository is laid out and how changes are made and checked.
`spec/` holds the behavior spec for each feature area.

## License

Bow is released under the [MIT License](LICENSE).
Chromium and CEF keep their own licenses.
