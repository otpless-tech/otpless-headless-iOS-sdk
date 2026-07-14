---
name: size-review
description: Source-size and optional-dependency review for OtplessBM. Use on every PR review touching Sources/OtplessBM/, when asked about SDK size or size regressions, or before adding a new dependency to Package.swift or OtplessBM.podspec.
---

# Size review protocol

## 1. What's actually measurable here — read before assuming an AAR-style number exists

Unlike the Android spokes, **there is no single binary artifact to measure.** SPM ships source directly to consumers (they compile it as part of their own app build); CocoaPods ships source too by default (`s.subspec 'Core'` points at `.swift` files, not a prebuilt framework). There is no XCFramework, no `.a`/`.framework` binary size number to diff — measure what actually exists:

```bash
find Sources -name '*.swift' | xargs wc -l | tail -1   # total lines
find Sources -name '*.swift' | wc -l                    # file count
```

At time of writing: 48 files, ~7,660 lines. Build the **base** and **head** commits and report the delta in files/lines — this is the honest proxy available today.

A `feat/xcframework` branch exists in this repo's history (unmerged) suggesting XCFramework distribution has been explored. If it ever lands, that would produce a real binary-size number — until then, don't invent one.

## 2. Optional-dependency correctness checklist (every PR) — this is this repo's equivalent of a shrinker/consumer-rules check

There's no R8/ProGuard-equivalent shrinker here, but there IS a real "does this feature ship its weight only when opted into" mechanism: the `#if canImport(...)` stub pattern (`FBSdkUseCase.swift`, `GIDSignInUseCase.swift`). Go through the diff and verify:

- **A new optional third-party integration** should follow this same pattern (a new podspec subspec + `#if canImport(...)` stub in the default/SPM path), not become a mandatory `Package.swift` dependency that every SPM consumer pays for whether or not they use it.
- **A new mandatory dependency** (added directly to `Package.swift`'s `dependencies:`) is paid by every consumer of every distribution channel — challenge it harder than an optional-subspec addition.
- **CocoaPods-only subspecs pull real transitive weight**: `FacebookSupport` → `FBSDKCoreKit`/`FBSDKLoginKit` (`~> 17.0.2`); `GoogleSupport` → `GoogleSignIn`/`GoogleSignInSwiftSupport` (`~> 9.0`, which itself pulls `GTMSessionFetcher`, `PromisesSwift`/`PromisesObjC`, `RecaptchaInterop` — visible in `pod lib lint`'s deployment-target warnings). None of this affects SPM consumers or the `Core`-only CocoaPods install. Don't conflate "GoogleSupport got heavier" with "OtplessBM got heavier" in a size discussion — be explicit about which subspec/distribution channel a size claim applies to.
- **New reflection or dynamic loading**: this repo doesn't currently use `NSClassFromString`/reflection-style optional loading (unlike the Android spokes' intelligence-SDK bridge) — the `#if canImport(...)` compile-time pattern is the whole story. If a PR introduces runtime reflection instead of a compile-time check, that's a design deviation worth flagging, not silently accepting.

## 3. Known size levers

| Lever | Notes |
|---|---|
| Challenge new mandatory dependencies (`Package.swift`) before adding them | Every SPM/Core-CocoaPods consumer pays for it; there's no shrinker to strip unused parts. |
| Prefer the optional-subspec + `#if canImport(...)` pattern for large integrations | Keeps the cost opt-in, matching the existing Facebook/Google precedent. |
| Delete dead source | Nothing strips it for you at any distribution's build time. |
| Gate debug-only logging | Check `Logger.swift`'s existing pattern before adding new unconditional log strings. |
| Land `feat/xcframework` (if ever prioritized) | Would give a real binary-size number to gate on, replacing the source-line-count proxy. Not something to build "as a side effect" of a size-review pass. |

## 4. Reporting

Report a short table (files/lines delta, base vs. head), a pass/fail per checklist item in §2, and specific (not generic) suggestions if the diff adds meaningful source or a new dependency. Keep it brief if the delta is small and nothing in §2 is flagged.
