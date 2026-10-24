# Use the full Xcode even when the command line tools are the system default.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

BUILD_DIR := build
APP := $(BUILD_DIR)/Build/Products/Debug/Bow.app
SMOKE_URL ?= https://example.com
SWIFT_SOURCES := App/UI E2E BowCore BowWebKit
# The e2e tests `make e2e` runs: all, one name such as app.quit, or an area, glob or tag (see scripts/e2e.sh).
E2E ?= all
# Kept out of every recipe's environment (xcodebuild reads environment variables as build settings) and handed to
# scripts/e2e.sh alone, quoted for the shell.
unexport E2E

.PHONY: bootstrap hooks project build test test-lock test-e2e-wrapper test-prune test-affected test-scripts run smoke e2e e2e-run format lint guards release verify check done test-done test-refcount test-private-paths test-bootstrap-cef test-check-lists test-e2e-bisect test-verify-plan test-e2e-flakes test-webkit-imports test-base-ref clean

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
	./scripts/stamp-tree.sh $(dir $(APP)).bow-tree-key ./scripts/xcodebuild.sh -project Bow.xcodeproj -scheme Bow -configuration Debug -derivedDataPath $(BUILD_DIR) -quiet build

# BowCore's unit tests, then BowWebKit's tests, which run real WKWebViews in off screen windows of the test process.
# BowWebKit runs with --no-parallel: its suites send real input (keys, clicks, pointer moves) to key windows, and
# suites running side by side steal each other's events, which failed most full runs.
test:
	swift test --package-path BowCore --quiet
	swift test --package-path BowWebKit --quiet --no-parallel

# Tests the build lock with fake builds (about 65 seconds). Not part of verify.
test-lock:
	./scripts/test-build-lock.sh

# Tests scripts/e2e.sh with a fake app (30 to 45 seconds under load; its checks run in groups side by side, as one
# sequence they took 150 to 165 seconds; launches no real app).
test-e2e-wrapper:
	./scripts/test-e2e-wrapper.sh

# Tests scripts/prune-compile-cache.sh on small fake caches (a few seconds).
test-prune:
	./scripts/test-prune-compile-cache.sh

# Tests scripts/e2e-affected.sh, the e2e selection make check runs, on fake changes (about a second).
test-affected:
	./scripts/test-e2e-affected.sh

# Every script self test, one after another (about 70 seconds). make verify runs each one side by side, and only when a
# script it covers (the table in scripts/verify.sh) or the Makefile differs from origin/main.
test-scripts: test-e2e-wrapper test-prune test-affected test-done test-refcount test-private-paths test-bootstrap-cef test-check-lists test-e2e-bisect test-verify-plan test-e2e-flakes test-webkit-imports test-base-ref

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
# carry no CEF or C++ and no raw browser pointers, the union-merged lists keep one entry per line, no duplicates, and
# only BowWebKit/ imports WebKit, with its private names in WebKitSPI.swift.
guards:
	./scripts/check-e2e-seams.sh
	./scripts/check-swift-headers.sh
	./scripts/check-lists.sh
	./scripts/check-cef-refcount.sh
	./scripts/check-private-paths.sh
	./scripts/check-webkit-imports.sh

# Release builds must leave out the e2e harness and its fixtures.
release: project
	./scripts/check-release.sh

# lint, guards, test, build and the script self tests side by side, with seconds per part. Each self test runs only
# when a script it covers or the Makefile differs from origin/main; VERIFY_ALL=1 runs them all. scripts/verify.sh says how.
verify:
	@./scripts/verify.sh

# The quick check while building and fixing: lint on the changed Swift files, guards, BowCore tests when BowCore/
# changed, then build and e2e-run with only the tests the change touches (scripts/e2e-affected.sh). It never
# replaces verify and the full e2e at the end. scripts/check.sh says how.
check:
	@./scripts/check.sh

# The final check of a branch: warns when it is behind origin/main (refuses on a conflict), then make verify and the
# full make e2e with make release beside it when app sources changed, then one block for the report (result lines,
# e2e summary and run folder, final.png, diff stat, tree hash).
# A FLAKY test the branch does not add or change is reported and does not fail it.
# Run it after the last commit and a rebase onto origin/main. scripts/done.sh says how.
done:
	@./scripts/done.sh

# Tests scripts/done.sh, the behind and conflict handling, the release build and the report block, with a fake make
# (a few seconds).
test-done:
	./scripts/test-done.sh

# Tests scripts/check-cef-refcount.sh, the guard against Release, AddRef and HasOneRef declarations (under a second).
test-refcount:
	./scripts/test-check-cef-refcount.sh

# Tests scripts/check-private-paths.sh, the guard against private paths on the branch, on fake changes (about a second).
test-private-paths:
	./scripts/test-check-private-paths.sh

# Tests scripts/bootstrap-cef.sh --if-stale, the relink of Vendor/cef every build runs, on a fake cache (a few seconds).
test-bootstrap-cef:
	./scripts/test-bootstrap-cef.sh

# Tests scripts/check-lists.sh, the list checks (format, duplicates, entries no file declares), on fixture trees (under a second).
test-check-lists:
	./scripts/test-check-lists.sh

# Tests scripts/e2e-bisect.sh, which finds the commit that broke an e2e test, on a throwaway repository with a planted
# culprit (a few seconds; no build, no app).
test-e2e-bisect:
	./scripts/test-e2e-bisect.sh

# Tests which self tests scripts/verify.sh runs for a change (under a second; a throwaway repository).
test-verify-plan:
	./scripts/test-verify-plan.sh

# Tests scripts/e2e-flakes.sh, the flake ledger reader (a few seconds; throwaway ledgers).
test-e2e-flakes:
	./scripts/test-e2e-flakes.sh

# Tests scripts/check-webkit-imports.sh, the guard that keeps WebKit imports in BowWebKit/ and private WebKit names
# in WebKitSPI.swift, on fixture trees (under a second).
test-webkit-imports:
	./scripts/test-check-webkit-imports.sh

# Tests scripts/base-ref.sh, the base every check compares a branch with (main or webkit), on a throwaway repository
# (under a second).
test-base-ref:
	./scripts/test-base-ref.sh

clean:
	rm -rf $(BUILD_DIR) Bow.xcodeproj Generated
