#!/bin/sh
# xcodebuild under the shared build lock (scripts/build-lock.sh) with a capped number of parallel jobs, then a
# prune of the shared compilation cache (scripts/prune-compile-cache.sh) once the build slot is given back.
# Use this for every xcodebuild the Makefile and scripts run.
#
# Jobs: the machine's cores divided by the build slots (BOW_BUILD_SLOTS, default 6), at least 2, so that every
# slot compiling at once fills the cores without overcommitting them (16 cores and 6 slots give 2 jobs each).
# BOW_BUILD_JOBS overrides it.
set -eu
here=$(dirname "$0")
cores=$(sysctl -n hw.ncpu 2> /dev/null || echo 8)
slots=${BOW_BUILD_SLOTS:-6}
case $slots in '' | *[!0-9]* | 0) slots=6 ;; esac
jobs=$((cores / slots))
[ "$jobs" -ge 2 ] || jobs=2
# The build runs in the foreground, so Ctrl-C reaches build-lock.sh and xcodebuild as before (a background job of
# a script would ignore SIGINT), and Ctrl-C stops this script too. A failed build still prunes.
status=0
"$here/build-lock.sh" xcodebuild -jobs "${BOW_BUILD_JOBS:-$jobs}" "$@" || status=$?
"$here/prune-compile-cache.sh" || true
exit "$status"
