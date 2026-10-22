# bowbrowser

An Arc-style browser for macOS, built in Swift on Chromium.
Early work in progress.

## Build

Requirements: macOS 14 or later on Apple Silicon, Xcode 26, Homebrew `cmake` and `xcodegen`.

```sh
make bootstrap   # download the pinned Chromium Embedded Framework and generate the project
make run         # build and open the app
```

`make verify` runs lint, tests and the build.
