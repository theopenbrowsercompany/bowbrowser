# bowbrowser

An Arc-inspired browser for macOS, built in Swift on Chromium.
Built by Arc fans.

Website: https://www.bowbrowser.com

Status: early work in progress.

_Not affiliated with Arc, The Browser Company of New York, or Atlassian._

## Requirements

- macOS 14 or later on Apple Silicon
- Xcode 26
- Homebrew `cmake` and `xcodegen`

## Build

```sh
make bootstrap   # download the pinned Chromium Embedded Framework and generate the Xcode project
make run         # build and open the app
make verify      # lint, checks, tests and the Debug build
```

Chromium comes in as a prebuilt engine (CEF), so building the app never compiles Chromium.

## Contributing

`AGENTS.md` describes how the repository is laid out and how changes are made and checked.
`spec/` holds the behavior spec for each feature area.

## License

Bow is released under the [MIT License](LICENSE).
Chromium and CEF keep their own licenses.
