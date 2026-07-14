---
name: add-tests
description: Recipe for adding the first (or any subsequent) Swift test in the otpless-headless-iOS-sdk (OtplessBM). Use when adding/updating tests, after changing dto/usecase/network parsing logic, or when asked to write a test for this SDK — covers the current (nonexistent) test infrastructure and how to bootstrap it.
---

# Adding tests to this repo

## 0. Honest starting point

**There is no `Tests/` directory and no test target in `Package.swift` as of this writing.** `swift test` fails with "no tests found; create a target in the 'Tests' directory" — confirmed by running it, not assumed. `scripts/run-tests.sh` (used by `make test` and rung 2 of the **verify** skill) detects this and no-ops rather than failing the gate. There is no existing test-double toolkit, no seam on the `Otpless` singleton for resetting state between tests, and no golden contract-fixture directory (unlike the Android `otpless-headless-android-lite` exemplar's `LongClaw/src/test/resources/contract/`). Building all of this out is real, first-time work — treat what follows as a starting recipe, not an established pattern to copy from elsewhere in this repo.

## 1. Add the test target

`Package.swift` needs a `.testTarget` added to both `targets` and (if you want `swift test` to build it standalone) referenced correctly:

```swift
.testTarget(
    name: "OtplessBMTests",
    dependencies: ["OtplessBM"]
),
```

Test files go under `Tests/OtplessBMTests/`, mirroring `Sources/OtplessBM/`'s subdirectory structure as the suite grows (`dto/`, `usecase/`, `utils/`, etc.) — there's no existing convention to match yet, so pick this mirrored-structure approach and stay consistent.

## 2. Run tests the same way the build works

```bash
bash scripts/run-tests.sh   # or: make test
```

This runs `swift test --sdk <iphonesimulator SDK> --triple arm64-apple-ios13.0-simulator` once a `Tests/` directory exists — the same cross-compilation flags `scripts/build.sh` uses, for the same reason (plain `swift test` fails on this repo's platform declaration; see CLAUDE.md). Don't invoke bare `swift test` directly.

## 3. `Otpless` is a singleton with no reset seam

`Otpless.shared` (`Sources/OtplessBM/Otpless.swift`) holds process-global state with no `@testable`-visible reset function today. Prefer testing the smallest unit that doesn't require touching singleton state at all — e.g. a `dto/` type's own parsing/encoding logic (`OtplessRequest`, `OtplessResponse`, `ResponseTypes`), or a `network/model/` response type's `Codable`/`JSONSerialization` decoding directly from a hand-built JSON fixture. If a test genuinely needs to exercise singleton-dependent code, add a minimal internal (not `@objc`, not exported) reset seam to `Otpless.swift` — excluded from `api-baseline/OtplessBM.json` the same way lite's Android seams are excluded from its `.api` dump — and reset it in both setup and teardown, since it's a process-global singleton and state will leak across tests otherwise.

## 4. The `#if canImport(...)` optional-dependency pattern needs its own test strategy

`FBSdkUseCase.swift` and `GIDSignInUseCase.swift` compile a real implementation only when `FBSDKLoginKit`/`GoogleSignIn` are available, and an empty stub otherwise (see CLAUDE.md's "what this repo is" section). A plain SPM `.testTarget` will only ever exercise the **stub** path, since the test target doesn't declare those pods either. To test the real Facebook/Google integration path you would need a CocoaPods-based test setup (a `Podfile` with the `FacebookSupport`/`GoogleSupport` subspecs) — no such setup exists in this repo yet. Until it does, be explicit in the PR about which path (`stub` vs. `real`) a given test actually covers; don't imply Facebook/Google coverage from an SPM-only test run.

## 5. Faking / test doubles — nothing preinstalled

No mocking library, no HTTP-stubbing library is declared anywhere in this repo. `URLSession`-based network calls (see `network/api/ApiManager.swift`, `repository/ApiRepository.swift`, `repository/CoreHttpClient.swift`) would need either a `URLProtocol` stub (Foundation-native, no new dependency) or a real new test-only dependency — if the latter, constitution article 5 applies in full: justify it in the PR, pin a stable release, record it in `CHANGELOG.md`. Prefer the `URLProtocol` stub approach first; it's free.

## 6. Response-contract fixtures — none exist yet

The Android exemplar mirrors backend response payloads as golden JSON fixtures shared across test files. No such fixture directory exists in this repo. If you're testing `network/model/response/*.swift` decoding, hand-build the JSON literal in the test file itself for now; if a fixture directory becomes worth creating (multiple tests decoding the same payload shape), that's a deliberate follow-up, not something to invent as a side effect of one test.
