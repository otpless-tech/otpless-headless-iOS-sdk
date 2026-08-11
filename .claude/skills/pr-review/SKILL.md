---
name: pr-review
description: Review any PR or diff that touches Sources/OtplessBM/, Package.swift, or OtplessBM.podspec against the SDK development constitution in CLAUDE.md. Use when asked to review a pull request, review a diff, or check a change against the constitution before merge.
---

# Constitution-based PR review

This SDK runs inside enterprise clients' apps — the constitution in `CLAUDE.md` exists because their crash rate, security audit, and app size all include us. Review every diff against the six articles below, in order. Skip an article only if the diff genuinely has nothing relevant to it (say so, don't stay silent).

## Article 1 — Public API is a contract

- Diff any changed method signature, parameter label, parameter order, or default value on a public type against the previous version — Swift call sites use argument labels; a rename or reorder is breaking even if types line up.
- For `@objc` members specifically: a rename changes the Objective-C selector too — check both the Swift and (if applicable) Objective-C call-site impact.
- Diff response payload keys/types (`OtplessResponse`, `network/model/response/*`) — new keys are safe, renamed/retyped/reordered existing keys are breaking.
- Confirm `bash scripts/check-api-baseline.sh --update` was run and `api-baseline/OtplessBM.json` was regenerated if the diff touches public surface — the CI gate would otherwise fail; check whether the PR ran it and committed the diff.
- Scan public signatures for leaked third-party types (`OtplessEventIO` internals, `FBSDKLoginKit`/`GoogleSignIn` types) reachable by SPM consumers, who never get the Facebook/Google pods.
- **No compiler-enforced visibility restriction exists** (no Swift equivalent of Kotlin's `explicitApi()` is turned on here) — manually check whether a new type/member actually needs to be `public`, or should default to `internal`.
- Any breaking change needs a `**BREAKING:**` changelog entry and a stated wrapper-SDK check against **both** `react-native-headless-lite` and `react-native-headless-sdk` (the hub topology: both pin this iOS SDK) — flag if missing.
- A removed public member must go through a deprecation cycle first (`@available(*, deprecated, ...)`), not be deleted cold.

## Article 2 — Never harm the host app

- Every new SDK entry point / callback boundary: is there defensive handling (`guard`, `try?`, `Result`) instead of `try!`/force-unwraps on network-response or merchant-supplied input? No exception/fatal error should be able to propagate out of an SDK call merchant code makes.
- Main-thread discipline: merchant-facing callbacks and UI work should go through `@MainActor` or `DispatchQueue.main`, matching the existing pattern (`Otpless.swift`, `PasskeyUseCase.swift`, `Logger.swift`, `Utils.swift`, `DeviceInfoUtils.swift` all already do this). Flag any new UI-adjacent code that doesn't.
- **Swift 6 concurrency warnings are real findings, not noise.** `pod lib lint`'s output surfaces `Sendable`/data-race warnings (see the pre-existing one at `Otpless.swift:376`, tracked as a follow-up, not yet fixed) — any *new* one introduced by this diff is a blocking finding.
- New process-global state (URLSession tasks, `NotificationCenter` observers, timers) — is it torn down by `Otpless.shared.cleanup()`/`.clearAll()`? There is no `deinit` anywhere in this codebase (confirmed) — cleanup here is 100% manual; a new resource with no corresponding cleanup-path change is a leak.
- New `Info.plist` requirements, URL schemes, or `LSApplicationQueriesSchemes` entries (README's integration steps) — flag as needing product sign-off if the PR doesn't state it.
- New optional-capability code (a new `#if canImport(...)`-style integration) must degrade to a working stub, never throw — check the Facebook/Google pattern is followed, not a reflection hack.

## Article 3 — Privacy & auditability

- Any new field collected (network payload, device info) or new API category accessed: is `Sources/PrivacyInfo.xcprivacy` updated in the same PR? Missing update = blocking finding, not a nit.
- Grep new/changed logging for phone numbers, OTPs, tokens, or user identifiers reaching unconditional log output — check against `Logger.swift`'s existing debug-gating pattern.
- Any new ATT/IDFA-adjacent code (`ASIdentifierManager`, `AppTrackingTransparency`) is a blocking finding unless the PR states the product decision and the corresponding `NSPrivacyTracking` flip in the privacy manifest — none exists today; this should stay a deliberate, rare addition.
- Any field sent in telemetry (`utils/Events/OtplessBMEvents.swift`, `DeviceInfoUtils.swift`'s params dictionary) should actually report what it claims — the pre-existing `Constants.SDK_VERSION` vs. `OtplessBM.podspec` drift (see CLAUDE.md's Known findings) is exactly the class of bug this bullet exists to catch; a diff touching either file should double-check they still agree.

## Article 4 — Naming conventions

- No internal codenames in public symbols — `Otpless`/`OtplessBM`/`OtplessEventIO` naming stays consistent.
- Swift API Design Guidelines: `UpperCamelCase` types, `lowerCamelCase` members/parameters, clear argument labels.
- New JSON payload keys: `lowerCamelCase` matching the backend contract exactly — flag any key that's a synonym for an existing concept (shared response contract with the Android spokes per the hub's parity rule 4).

## Article 5 — Dependencies & size

- Any new dependency in the diff: challenged in the PR description? Stable release only (no alpha/beta/RC)? Added to `Package.swift` if it's meant for all consumers, or added as a new optional subspec (with the `#if canImport(...)` stub pattern) if it's a large optional integration? Recorded in `CHANGELOG.md`?
- Confirm `OtplessEventIO` and any podspec-declared version constraint (`FBSDKCoreKit`/`FBSDKLoginKit` `~> 17.0.2`, `GoogleSignIn`/`GoogleSignInSwiftSupport` `~> 9.0`) bumps are stable releases, not majors bumped without justification.
- Source-size delta (the only currently-measurable size lever — see the **size-review** skill): does the diff add source disproportionate to the feature? There's no shrinker here to absorb dead code.

## Article 6 — Verification before merge

- Was `make gate` (or the equivalent `scripts/*.sh` + `pod lib lint` invocations) run, and does the PR state the actual result — not just "should pass"?
- Any public-API/`Package.swift`/`OtplessBM.podspec` change: was `bash scripts/check-api-baseline.sh` (and `--update` if intentional) run? No evidence in the PR = blocking finding.
- Behavioral changes: does the PR state what was manually exercised, given there's no sample app? SNA/deep-link/passkey/SSO flows need an explicit "human-only, not run" statement if not actually run on a device.
- Any new `@available(iOS X, *)`-gated call: confirm a defined fallback exists for iOS 13/14 (the package's declared floor), not just the availability annotation with no `else`.
- If the response contract or public API moved: does the PR note a wrapper-SDK check against **both** `react-native-headless-lite` and `react-native-headless-sdk`? Absence is a blocking finding for any breaking change.
- Does `bash scripts/docs-verify.sh` still report the same `WARN`s as before (or fewer) — a new, previously-unseen `WARN` (e.g. a fresh version mismatch) deserves a comment even though it won't fail CI.

## Report format

Report findings as a flat list ordered by severity (**Blocking** → **Should-fix** → **Nit**), each with a `file:line` reference and a one-line fix suggestion:

```
### Blocking
- Sources/OtplessBM/Otpless.swift:120 — new public method `foo()` has no api-baseline update; the CI gate will fail.

### Should-fix
- Sources/OtplessBM/dto/Bar.swift:12 — new field looks internal-only but is public; no compiler enforcement here — mark it `internal`.

### Nit
- CHANGELOG.md — Unreleased entry missing for this PR.
```

If an article has no relevant diff content, state "Article N — not applicable (no matching changes)" rather than omitting it silently.
