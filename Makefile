# Use the full Xcode even when the command line tools are the system default.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

BUILD_DIR := build
APP := $(BUILD_DIR)/Build/Products/Debug/Bow.app
SMOKE_URL ?= https://example.com
SWIFT_SOURCES := App/UI E2E BowCore
# The e2e test `make e2e` runs: all, or one name such as app.quit.
E2E ?= all

.PHONY: bootstrap hooks project build test test-lock run smoke e2e format lint guards release verify clean

bootstrap: hooks
	./scripts/bootstrap-cef.sh
	$(MAKE) project

# Use the hooks in .githooks/ (they block private paths from being pushed). Skipped outside a git checkout.
hooks:
	@if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then git config core.hooksPath .githooks; fi

# --use-cache skips generation (and leaves the project file untouched, so Xcode keeps its build plan) when
# project.yml and the source file list have not changed.
project:
	xcodegen generate --quiet --use-cache

build: project
	./scripts/xcodebuild.sh -project Bow.xcodeproj -scheme Bow -configuration Debug -derivedDataPath $(BUILD_DIR) -quiet build

test:
	swift test --package-path BowCore --quiet

# Tests the build lock with fake builds (about 50 seconds). Not part of verify.
test-lock:
	./scripts/test-build-lock.sh

run: build
	open $(APP)

smoke: build
	$(APP)/Contents/MacOS/Bow --smoke-test=$(SMOKE_URL)

# Runs the app off screen with a throwaway profile; each run writes to its own build/e2e/<time>-<pid> folder.
e2e: build
	@run="$(BUILD_DIR)/e2e/$$(date +%Y%m%d-%H%M%S)-$$$$"; \
	echo "e2e: $$run"; \
	./scripts/build-lock.sh --pool e2e $(APP)/Contents/MacOS/Bow --e2e=$(E2E) --e2e-out="$$run"; code=$$?; \
	if [ $$code -ne 0 ] && ! grep -q "^E2E: " "$$run/report.txt" 2>/dev/null && [ -f "$$run/chromium.log" ]; then \
		echo "e2e: the app ended with code $$code; the end of $$run/chromium.log:" >&2; \
		tail -n 40 "$$run/chromium.log" >&2; \
	fi; \
	exit $$code

format:
	swift format --in-place --recursive $(SWIFT_SOURCES)

lint:
	swift format lint --strict --recursive $(SWIFT_SOURCES)

# Boundary checks: app code reaches the e2e harness only through its marked seams, and the headers Swift sees
# carry no CEF or C++ and no raw browser pointers.
guards:
	./scripts/check-e2e-seams.sh
	./scripts/check-swift-headers.sh

# Release builds must leave out the e2e harness and its fixtures.
release: project
	./scripts/check-release.sh

verify: lint guards test build

clean:
	rm -rf $(BUILD_DIR) Bow.xcodeproj Generated
