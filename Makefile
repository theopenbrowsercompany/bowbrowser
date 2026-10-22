# Use the full Xcode even when the command line tools are the system default.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

BUILD_DIR := build
APP := $(BUILD_DIR)/Build/Products/Debug/Bow.app
SMOKE_URL ?= https://example.com
SWIFT_SOURCES := App/UI E2E BowCore
# The e2e test `make e2e` runs: all, or one name such as app.quit.
E2E ?= all

.PHONY: bootstrap hooks project build test run smoke e2e format lint seams verify clean

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

# Runs the app off screen with a throwaway profile; each run writes to its own build/e2e/<time>-<pid> folder.
e2e: build
	@run="$(BUILD_DIR)/e2e/$$(date +%Y%m%d-%H%M%S)-$$$$"; \
	echo "e2e: $$run"; \
	$(APP)/Contents/MacOS/Bow --e2e=$(E2E) --e2e-out="$$run"

format:
	swift format --in-place --recursive $(SWIFT_SOURCES)

lint:
	swift format lint --strict --recursive $(SWIFT_SOURCES)

# App code may reach the e2e harness only through its marked seams.
seams:
	./scripts/check-e2e-seams.sh

verify: lint seams test build

clean:
	rm -rf $(BUILD_DIR) Bow.xcodeproj Generated
