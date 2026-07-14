#!/usr/bin/env bash
# Runs the Swift unit test suite for OtplessBM, if one exists.
#
# As of this writing, this repo has NO Tests/ directory and NO test target in
# Package.swift — `swift test` fails with "no tests found; create a target in
# the 'Tests' directory" (confirmed by running it, not assumed). This script
# makes that an honest, non-fatal no-op rather than a red gate: once a real
# test target is added (see the add-tests skill), this script starts running
# it automatically with no changes needed.
#
# Used by `make test` (see the root Makefile) and .github/workflows/build-test.yml.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [ -d Tests ]; then
  SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
  TARGET_TRIPLE="arm64-apple-ios13.0-simulator"
  swift test --sdk "$SDK_PATH" --triple "$TARGET_TRIPLE"
else
  echo "No Tests/ directory in this repo yet — nothing to run. See CLAUDE.md's known-deviations section and the add-tests skill before adding the first test target."
fi
