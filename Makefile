# Use the full Xcode even when the command line tools are the system default.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

BUILD_DIR := build
APP := $(BUILD_DIR)/Build/Products/Debug/Bow.app
SMOKE_URL ?= https://example.com
SWIFT_SOURCES := App/UI E2E BowCore
# The e2e tests `make e2e` runs: all, one name such as app.quit, or an area, glob or tag (see scripts/e2e.sh).
E2E ?= all
# Kept out of every recipe's environment (xcodebuild reads environment variables as build settings) and handed to
# scripts/e2e.sh alone, quoted for the shell.
unexport E2E

.PHONY: bootstrap hooks project build test test-lock test-e2e-wrapper test-prune test-affected test-scripts run smoke e2e e2e-run format lint guards release verify check done test-done clean

bootstrap: hooks
	./scripts/bootstrap-cef.sh
	$(MAKE) project

# Use the hooks in .githooks/ (they block private paths from being pushed). Skipped outside a git checkout.
hooks:
	@if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then git config core.hooksPath .githooks; fi

# --use-cache skips generation (and leaves the project file untouched, so Xcode keeps its build plan) when
# project.yml and the source file list have not changed. It still generates when Bow.xcodeproj is missing (XcodeGen
# 2.46 checks), so make clean needs no cache reset.
project:
	xcodegen generate --quiet --use-cache

# The empty .metadata_never_index keeps Spotlight from indexing the build folder (derived data and e2e runs).
build: project
	@mkdir -p $(BUILD_DIR) && : > $(BUILD_DIR)/.metadata_never_index
	./scripts/xcodebuild.sh -project Bow.xcodeproj -scheme Bow -configuration Debug -derivedDataPath $(BUILD_DIR) -quiet build

test:
	swift test --package-path BowCore --quiet

# Tests the build lock with fake builds (about 50 seconds). Not part of verify.
test-lock:
	./scripts/test-build-lock.sh

# Tests scripts/e2e.sh with a fake app (about 35 seconds; launches no real app).
test-e2e-wrapper:
	./scripts/test-e2e-wrapper.sh

# Tests scripts/prune-compile-cache.sh on small fake caches (a few seconds).
test-prune:
	./scripts/test-prune-compile-cache.sh

# Tests scripts/e2e-affected.sh, the e2e selection make check runs, on fake changes (about a second).
test-affected:
	./scripts/test-e2e-affected.sh

# The script self tests verify runs when scripts/ or the Makefile differ from origin/main.
test-scripts: test-e2e-wrapper test-prune test-affected test-done

run: build
	open $(APP)

smoke: build
	$(APP)/Contents/MacOS/Bow --smoke-test=$(SMOKE_URL)

# Runs the app off screen with a throwaway profile; each run writes to its own build/e2e/<time>-<pid> folder.
# scripts/e2e.sh documents the selection, the retry, results.json and the exit codes.
# e2e-run does the same without building: it reruns the last build.
e2e: build
e2e e2e-run:
	@E2E=$(call shq,$(E2E)) BOW_E2E_ROOT=$(call shq,$(BUILD_DIR)/e2e) ./scripts/e2e.sh $(call shq,$(APP))

# $(call shq,<text>): the text in single quotes for the shell.
shq = '$(subst ','\'',$(1))'

format:
	swift format --in-place --recursive $(SWIFT_SOURCES)

lint:
	swift format lint --strict --recursive $(SWIFT_SOURCES)

# Boundary checks: app code reaches the e2e harness only through its marked seams, and the headers Swift sees
# carry no CEF or C++ and no raw browser pointers, and the union-merged lists keep one entry per line, no duplicates.
guards:
	./scripts/check-e2e-seams.sh
	./scripts/check-swift-headers.sh
	./scripts/check-lists.sh

# Release builds must leave out the e2e harness and its fixtures.
release: project
	./scripts/check-release.sh

# lint, guards, test, build and test-scripts side by side, with seconds per part. test-scripts runs only when
# scripts/ or the Makefile differ from origin/main; VERIFY_ALL=1 runs it always. scripts/verify.sh says how.
verify:
	@./scripts/verify.sh

# The quick check while building and fixing: lint on the changed Swift files, guards, BowCore tests when BowCore/
# changed, then build and e2e-run with only the tests the change touches (scripts/e2e-affected.sh). It never
# replaces verify and the full e2e at the end. scripts/check.sh says how.
check:
	@./scripts/check.sh

# The final check of a branch: refuses unless it contains origin/main, then make verify and the full make e2e, then
# one block for the report (result lines, e2e summary and run folder, final.png, diff stat, tree hash).
# Run it after the last commit and a rebase onto origin/main. scripts/done.sh says how.
done:
	@./scripts/done.sh

# Tests scripts/done.sh, the refusal and the report block, with a fake make (about a second).
test-done:
	./scripts/test-done.sh

clean:
	rm -rf $(BUILD_DIR) Bow.xcodeproj Generated
