# Use the full Xcode even when the command line tools are the system default.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

BUILD_DIR := build
APP := $(BUILD_DIR)/Build/Products/Debug/Bow.app
SMOKE_URL ?= https://example.com
SWIFT_SOURCES := App/UI E2E BowCore
# The e2e tests `make e2e` runs: all, one name such as app.quit, or an area, glob or tag (see scripts/e2e.sh).
E2E ?= all

.PHONY: bootstrap hooks project build test test-lock test-e2e-wrapper run smoke e2e e2e-run format lint guards release verify clean

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

# Tests scripts/e2e.sh with a fake app (a few seconds; launches no real app).
test-e2e-wrapper:
	./scripts/test-e2e-wrapper.sh

run: build
	open $(APP)

smoke: build
	$(APP)/Contents/MacOS/Bow --smoke-test=$(SMOKE_URL)

# Runs the app off screen with a throwaway profile; each run writes to its own build/e2e/<time>-<pid> folder.
# scripts/e2e.sh documents the selection, the retry, results.json and the exit codes.
e2e: build
	@./scripts/e2e.sh $(APP) '$(E2E)'

# The same without building: reruns the last build.
e2e-run:
	@./scripts/e2e.sh $(APP) '$(E2E)'

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

verify: lint guards test test-e2e-wrapper build

clean:
	rm -rf $(BUILD_DIR) Bow.xcodeproj Generated
