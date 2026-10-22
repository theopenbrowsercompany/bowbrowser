# Use the full Xcode even when the command line tools are the system default.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

BUILD_DIR := build
APP := $(BUILD_DIR)/Build/Products/Debug/Bow.app
SMOKE_URL ?= https://example.com
SWIFT_SOURCES := App/UI BowCore

.PHONY: bootstrap hooks project build test run smoke format lint verify clean

bootstrap: hooks
	./scripts/bootstrap-cef.sh
	$(MAKE) project

# Use the hooks in .githooks/ (they block private paths from being pushed). Skipped outside a git checkout.
hooks:
	@if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then git config core.hooksPath .githooks; fi

project:
	xcodegen generate --quiet

build: project
	xcodebuild -project Bow.xcodeproj -scheme Bow -configuration Debug -derivedDataPath $(BUILD_DIR) -quiet build

test:
	swift test --package-path BowCore --quiet

run: build
	open $(APP)

smoke: build
	$(APP)/Contents/MacOS/Bow --smoke-test=$(SMOKE_URL)

format:
	swift format --in-place --recursive $(SWIFT_SOURCES)

lint:
	swift format lint --strict --recursive $(SWIFT_SOURCES)

verify: lint test build

clean:
	rm -rf $(BUILD_DIR) Bow.xcodeproj Generated
