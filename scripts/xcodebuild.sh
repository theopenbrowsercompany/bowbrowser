#!/bin/sh
# xcodebuild under the shared build lock (scripts/build-lock.sh) with a capped number of parallel jobs.
# BOW_BUILD_JOBS sets the cap (default 8). Use this for every xcodebuild the Makefile and scripts run.
set -eu
exec "$(dirname "$0")/build-lock.sh" xcodebuild -jobs "${BOW_BUILD_JOBS:-8}" "$@"
