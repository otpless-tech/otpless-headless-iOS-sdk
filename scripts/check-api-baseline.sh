#!/usr/bin/env bash
# Public-API breakage check for OtplessBM — the Swift/SPM analog of a
# binary-compatibility-validator ".api" dump-and-diff. There is no
# `swift package diagnose-api-breaking-changes` available here: that command
# always builds for the *host* platform, and OtplessBM only declares
# `platforms: [.iOS(.v13)]` in Package.swift — since the code imports UIKit,
# building it for macOS fails outright (see CLAUDE.md's known-deviations
# section). This script uses `swift-api-digester` directly instead, scoped to
# just the OtplessBM module (not the whole platform SDK), cross-compiled for
# the iOS Simulator via explicit --sdk/--triple flags — no Xcode project or
# scheme required.
#
# Usage:
#   bash scripts/check-api-baseline.sh            # diagnose current source against the committed baseline
#   bash scripts/check-api-baseline.sh --update    # regenerate the committed baseline (review the diff before committing)
#
# Used by `make gate` (see the root Makefile) and .github/workflows/build-test.yml.
#
# Known limitation (documented, not silently assumed away): swift-api-digester
# dumps are sensitive to the Xcode/SDK version that generated them — comparing
# a baseline generated on one Xcode version against a dump generated on a
# different one can produce noise unrelated to actual source changes. CI pins
# whatever Xcode version the macos runner defaults to (see build-test.yml); if
# that ever drifts from the version used to (re)generate the committed
# baseline, expect to need `--update` even without a real API change. This is
# a tracked follow-up (pin an explicit Xcode version once one is chosen), not
# a bug in this script.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MODULE_NAME="OtplessBM"
# Must match Package.swift's `platforms: [.iOS(.v13)]` deployment target.
# If that changes, update this triple too.
TARGET_TRIPLE="arm64-apple-ios13.0-simulator"
MODULES_DIR=".build/arm64-apple-ios-simulator/debug/Modules"
BASELINE_DIR="api-baseline"
BASELINE_FILE="$BASELINE_DIR/OtplessBM.json"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "FAIL: xcrun not found — this script requires a macOS host with Xcode command line tools." >&2
  exit 1
fi

SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"

echo "Building $MODULE_NAME for $TARGET_TRIPLE (sdk: $SDK_PATH) ..."
swift build --sdk "$SDK_PATH" --triple "$TARGET_TRIPLE"

if [ ! -d "$MODULES_DIR" ]; then
  echo "FAIL: expected build output at $MODULES_DIR but it does not exist." >&2
  exit 1
fi

if [ "${1:-}" = "--update" ]; then
  mkdir -p "$BASELINE_DIR"
  echo "Regenerating API baseline at $BASELINE_FILE ..."
  xcrun swift-api-digester -dump-sdk \
    -module "$MODULE_NAME" \
    -sdk "$SDK_PATH" \
    -target "$TARGET_TRIPLE" \
    -I "$MODULES_DIR" \
    -o "$BASELINE_FILE"
  echo "Baseline written. Review 'git diff $BASELINE_FILE' before committing."
  exit 0
fi

if [ ! -f "$BASELINE_FILE" ]; then
  echo "FAIL: no baseline at $BASELINE_FILE. Generate one with: bash scripts/check-api-baseline.sh --update" >&2
  exit 1
fi

echo "Diagnosing $MODULE_NAME's current public API against $BASELINE_FILE ..."
DIAG_OUTPUT="$(xcrun swift-api-digester -diagnose-sdk \
  -baseline-path "$BASELINE_FILE" \
  -module "$MODULE_NAME" \
  -sdk "$SDK_PATH" \
  -target "$TARGET_TRIPLE" \
  -I "$MODULES_DIR" 2>&1)"

echo "$DIAG_OUTPUT"

# Clean output is exclusively blank lines and "/* Section Header */" lines;
# any other non-empty line is a real reported change.
if echo "$DIAG_OUTPUT" | grep -vE '^\s*(/\*.*\*/)?\s*$' | grep -q .; then
  echo
  echo "FAIL: API change detected against $BASELINE_FILE."
  echo "If intentional and semver-appropriate (CLAUDE.md constitution article 1 — breaking changes need a"
  echo "**BREAKING:** CHANGELOG.md entry and a wrapper-SDK migration check), regenerate the baseline:"
  echo "  bash scripts/check-api-baseline.sh --update"
  echo "then review and commit the updated $BASELINE_FILE in the same PR."
  exit 1
fi

echo "PASS: no API change detected against $BASELINE_FILE."
