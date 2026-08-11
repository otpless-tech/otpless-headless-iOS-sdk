---
name: bump-dependency
description: Review and land any dependency version bump for OtplessBM — the OtplessEventIO SPM dependency, or the CocoaPods-only FBSDKCoreKit/FBSDKLoginKit/GoogleSignIn/GoogleSignInSwiftSupport version constraints in OtplessBM.podspec. Use before approving or merging any PR touching Package.swift's dependencies, Package.resolved, or the podspec's dependency versions.
---

# Dependency bump protocol

A version bump is a code change: constitution article 5 (CLAUDE.md) applies, and a green build alone is NOT a pass — a bump can change runtime behavior invisible to compilation. Never rubber-stamp.

## 1. Classify the dependency

This repo has exactly one **mandatory, compile-time** dependency and several **optional, CocoaPods-only** ones.

### A. `OtplessEventIO` (`otpless-tech/otpless-event-io-ios`, `Package.swift`)

- Pinned `from: "1.0.0"`; resolved at `1.0.0` per `Package.resolved`. This is a mandatory dependency of every distribution channel (SPM and both CocoaPods subspec combinations) — it's not optional anywhere.
- Check the sibling's release notes/tags for API surface changes at its call sites in this repo (grep `OtplessEventIO` usage across `Sources/OtplessBM/`) — a rename or signature change there is a compile-time break, but a *behavior* change (e.g. what an event payload contains) is invisible to the build and needs the sibling's own changelog read.
- Update `Package.resolved` by actually running a resolve (`swift package update` or `swift package resolve` after editing the `from:` constraint in `Package.swift`) — don't hand-edit the pinned revision/version in `Package.resolved`.

### B. CocoaPods-only optional integrations (`OtplessBM.podspec`)

- `FBSDKCoreKit`/`FBSDKLoginKit` (`~> 17.0.2`) — only affects the `FacebookSupport` subspec and `FBSdkUseCase.swift`'s real (non-stub) implementation path (`#if canImport(FBSDKLoginKit)`). SPM consumers and `Core`-only CocoaPods consumers are entirely unaffected by this bump.
- `GoogleSignIn`/`GoogleSignInSwiftSupport` (`~> 9.0`) — same shape, affects only `GoogleSupport` and `GIDSignInUseCase.swift`'s real implementation path. Note `pod lib lint`'s deployment-target warnings for this subspec's transitives (`GTMSessionFetcher`, `PromisesSwift`/`PromisesObjC`, `RecaptchaInterop`) — those come from Google's own dependency tree, not from a version choice made in this podspec; don't try to "fix" them here.
- A major-version bump on either changes real, user-visible sign-in behavior — read the SDK's own migration guide, don't assume compilation success means behavioral compatibility.

## 2. Verification gate (mandatory for both A and B)

```bash
bash scripts/build.sh                              # SPM path — always run, regardless of which dependency changed
pod lib lint OtplessBM.podspec --allow-warnings    # CocoaPods path — mandatory if a podspec dependency version changed
bash scripts/check-api-baseline.sh                 # confirm the bump didn't change OtplessBM's own public surface
bash scripts/docs-verify.sh
```

`pod lib lint` is disk-intensive (see CLAUDE.md's known findings) — make sure there's headroom before running it, and don't mistake a disk-pressure failure (`lipo: ... No space left on device`) for a real lint regression.

## 3. Behavior check — compilation does not cover this

- **`OtplessEventIO`:** does the event payload shape or delivery timing change? This repo's telemetry wrapper (`utils/Events/OtplessBMEvents.swift`) calls into it — verify call sites still behave as documented (cross-check against this repo's Atlas pages under `repos/otpless-headless-iOS-sdk/` — documentation lives only in `otpless-tech/atlas`, never in a `docs/` directory here — and describe what you verified in the PR).
- **Facebook/Google SDKs:** manually exercise (or state plainly that you couldn't, and why) the real sign-in flow — a major SDK version bump changing a delegate callback's timing or a deprecated API's removal is exactly the kind of thing that compiles fine and breaks at runtime.

## 4. Docs

- `CHANGELOG.md` `## Unreleased`: one bullet, `<dependency> old → new (#NN — title)` plus what changed at runtime if anything. Prefix internal-only bumps "Repo & tooling."
- If the bump changes anything a dependency-table or architecture page in Atlas states, open a companion PR against `otpless-tech/atlas` (`repos/otpless-headless-iOS-sdk/`) in the same cycle and link it here — see the **docs-sync** skill §5. Do not add a `docs/` directory to this repo to hold it.
- Run `bash scripts/docs-verify.sh` before finishing — check whether it reports any new `WARN` that wasn't there before (e.g. if this bump somehow touched a version-string location).

## 5. Merge rules

- Merge only when: the verification gate (§2) is green, the behavior check (§3) is done or explicitly stated as not-run-and-why, and docs (§4) are updated in the same PR.
- Never merge on green build alone — it proves compilation, not runtime behavior, especially for the Facebook/Google optional paths which an SPM-only build never even compiles.
- A major bump on either optional dependency without an explicit behavior-check note in the PR: request changes.
