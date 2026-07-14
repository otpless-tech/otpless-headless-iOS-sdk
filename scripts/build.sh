#!/usr/bin/env bash
# Headless build of OtplessBM for the iOS Simulator, via SwiftPM's CLI
# directly — no Xcode project, scheme, or simulator device required.
#
# Package.swift only declares `platforms: [.iOS(.v13)]`, so plain `swift
# build` (which targets the host machine, i.e. macOS) fails outright: the
# code imports UIKit and the OtplessEventIO dependency requires macOS 10.15+
# while OtplessBM's implicit macOS minimum floor is lower. Passing an
# explicit --sdk/--triple cross-compiles for iOS instead, which is the
# correct destination for this SDK.
#
# Used by `make build` (see the root Makefile) and .github/workflows/build-test.yml.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
# Must match Package.swift's `platforms: [.iOS(.v13)]` deployment target.
TARGET_TRIPLE="arm64-apple-ios13.0-simulator"

swift build --sdk "$SDK_PATH" --triple "$TARGET_TRIPLE"
