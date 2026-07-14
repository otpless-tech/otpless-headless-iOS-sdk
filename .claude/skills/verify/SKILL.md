---
name: verify
description: Verification ladder for changes to the otpless-headless-iOS-sdk (OtplessBM). Use before claiming any SDK change works, after modifying Sources/OtplessBM/ source, or when asked to verify/prove a change.
---

# Verification ladder

Claims of "this works" are only as good as what was actually run. Climb the ladder below to the rung the change requires, run the commands, and report actual output — not intent.

## Rung 1 — headless build

```bash
bash scripts/build.sh   # or: make build
```

Cross-compiles `OtplessBM` for the iOS Simulator via `swift build --sdk <iphonesimulator SDK> --triple arm64-apple-ios13.0-simulator`. Plain `swift build` (no flags) fails outright on this repo — confirmed by running it — because `Package.swift` only declares `platforms: [.iOS(.v13)]` and the code imports UIKit, so SwiftPM's default host-platform (macOS) build target is fundamentally the wrong destination, not a fixable misconfiguration. Always use this script (or `make build`), never bare `swift build`.

## Rung 2 — tests (currently a no-op — read before assuming otherwise)

```bash
bash scripts/run-tests.sh   # or: make test
```

**There is no `Tests/` directory in this repo as of this writing.** `swift test` on a package with no test target fails with "no tests found; create a target in the 'Tests' directory" — this script detects that and prints a message instead of failing, so the gate stays honest rather than red for a condition nobody can fix by rerunning it. The moment a real test target exists (see the **add-tests** skill), this script starts running it with the same `--sdk`/`--triple` flags automatically.

## Rung 3 — API-surface and packaging verification

```bash
bash scripts/check-api-baseline.sh          # public-API breakage check (see below)
pod lib lint OtplessBM.podspec --allow-warnings   # full lint, all 3 subspecs — ~3.5 min, disk-intensive (see CLAUDE.md)
bash scripts/docs-verify.sh                 # CHANGELOG/gate mechanical fact-check
```

Or all of rungs 1–3 together: `make gate`.

- `scripts/check-api-baseline.sh` diagnoses `OtplessBM`'s current public Swift API against the committed `api-baseline/OtplessBM.json` using `swift-api-digester -diagnose-sdk`, scoped to just this module (not the whole platform SDK). This is the Swift/SPM analog of a binary-compatibility-validator `.api` diff — `swift package diagnose-api-breaking-changes` doesn't work here (same host-platform-build problem as rung 1). Sanity-tested while building this gate: making a public method `internal` produces `Func Otpless.<name>() has been removed` and exit 1. If the diagnose step reports **any** non-header, non-blank line, that's a real detected change — regenerate deliberately with `bash scripts/check-api-baseline.sh --update` only after confirming the change is intentional and semver-appropriate (see constitution article 1), then review the JSON diff before committing.
- `pod lib lint --allow-warnings` (no `--quick`) builds and compiles all three subspecs (`Core`, `FacebookSupport`, `GoogleSupport`) against their real dependency trees — this is what catches "the podspec is structurally valid but a subspec doesn't actually compile" bugs that a bare `swift build` (SPM-only, no Facebook/Google code paths) cannot see. It is disk-intensive (multiple GB of DerivedData per run); a `lipo: ... No space left on device` failure is an environment problem, not a lint failure — don't debug it as one. `--quick` (podspec validity + dependency resolution only, ~1s) is a lighter local-iteration fallback but does not replace the full lint in the actual gate.
- `scripts/docs-verify.sh` is a pure grep/sed mechanical check (no build) — CHANGELOG heading vs. podspec version, and CLAUDE.md/Makefile gate-line consistency.

## Rung 4 — manual/device verification (human-only for several flows)

This repo has no sample app. For a behavioral change, the minimum bar is a passing `bash scripts/build.sh` plus a description in the PR of what was manually exercised (e.g., in a scratch Xcode project pointing at this checkout via a local SPM package reference, or a local Podfile pointing at `:path`). The following flows need a **physical device or a properly provisioned simulator** and cannot be verified by an agent — flag them as human-only in the PR rather than claiming they were run:

- SNA (carrier/cellular network binding)
- Deep-link handling (`isOtplessDeeplink`/`handleDeeplink`)
- Passkey/WebAuthn (`authorizeViaPasskey`)
- Apple/Google/Facebook sign-in (`registerFBApp`, Google/Facebook subspecs)

## Which rungs are mandatory

| Change type | Mandatory rungs |
|---|---|
| Any change to `Sources/OtplessBM/**` | 1 + 3 |
| A new `Tests/` target, or a change to an existing test | 1 + 2 |
| Public API, `Package.swift`, or `OtplessBM.podspec` change | 3 — non-negotiable, even if rung 1 passes cleanly |
| Behavioral change to an auth flow (init/start/response, SNA, deep link, passkey, SSO) | 1 + 3, plus note rung 4 for a human to run — do not claim rung 4 was done if you can't run it |
| Docs-only change | None of the above apply |

Report which rungs you actually ran and their real output. If a rung couldn't be run in the current environment (e.g. disk space, no CocoaPods installed, no physical device), say so explicitly instead of skipping it silently.
