# bowbrowser

An Arc-inspired browser for macOS (RIP Arc), built in Swift on Chromium.
Inspired by Arc, built by Arc fans.
Early work in progress.

_Not affiliated with Arc, The Browser Company of New York, or Atlassian._

## Build

Requirements: macOS 14 or later on Apple Silicon, Xcode 26, Homebrew `cmake` and `xcodegen`.

```sh
make bootstrap   # download the pinned Chromium Embedded Framework and generate the project
make run         # build and open the app
```

`make verify` runs lint, tests and the build.
