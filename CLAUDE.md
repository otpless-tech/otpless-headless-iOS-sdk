# CLAUDE.md — otpless-headless-iOS-sdk

Instructions for Claude Code (and any AI agent) working in this repository. Human developers: the same rules apply to you.

## What this repo is

The **OTPLESS iOS headless SDK** — a single Swift library, product name `OtplessBM`, distributed two ways from the same source:

| Distribution | Manifest | Consumers |
|---|---|---|
| Swift Package Manager | `Package.swift` (`platforms: [.iOS(.v13)]`, one dependency: `OtplessEventIO` from `otpless-tech/otpless-event-io-ios`) | Apps that pin a git tag directly |
| CocoaPods | `OtplessBM.podspec` (`s.version`, currently `2.3.2`) — three subspecs: `Core` (required), `FacebookSupport` (adds `FBSDKCoreKit`/`FBSDKLoginKit`), `GoogleSupport` (adds `GoogleSignIn`/`GoogleSignInSwiftSupport`) | `pod 'OtplessBM/Core'` etc. |

There is **no sample app in this repo** (unlike the Android spokes) — nothing to gitignore or exclude as a testbed here; all code under `Sources/` is the shipped SDK. There is also, as of this PR, **no CI, no tests, and no `docs/SDK-GUIDE.md`** — this PR is the scaffolding half of bringing this repo to agentic readiness; the guide is landing in a parallel PR (`feat/sdk-guide`, see below).

**Real, load-bearing architecture fact:** `FacebookSupport`/`GoogleSupport` are CocoaPods-only. `Package.swift` never declares `FBSDKLoginKit`/`GoogleSignIn` as dependencies, so `Sources/OtplessBM/sdkLogin/FacebookSupport/FBSdkUseCase.swift` and `.../GoogleSupport/GIDSignInUseCase.swift` guard their real implementations behind `#if !canImport(FBSDKLoginKit)` / `#if !canImport(GoogleSignIn)` and compile an empty stub otherwise. SPM consumers therefore always get the stub (Google/Facebook sign-in silently no-ops for them); only CocoaPods consumers who add the optional subspec get the real integration. Keep this working if you touch either file — don't assume both distributions behave identically.

### Start here: `docs/SDK-GUIDE.md` (landing in a parallel PR)

The canonical, exhaustive description of this SDK's code — architecture, flows, response/error contract, networking, telemetry, quirks — belongs at `docs/SDK-GUIDE.md`, following the pattern established by the Android `otpless-headless-android-lite` exemplar. **As of this PR, that file does not exist on this branch** — it is being authored in a parallel PR (`feat/sdk-guide`). Once it merges:

1. **Locate via the guide first** — its layout tree and source-file → section map name the exact file/function for any requested behavior. Do not re-derive the architecture from scratch.
2. **Read only the target file(s)** the guide points at, plus immediate collaborators.
3. **Verify before editing** — the guide describes intent; the code is the source of truth.
4. Extend `scripts/docs-verify.sh` with guide-vs-source checks once the guide exists (see the TODO in that script) — it currently only checks the CHANGELOG heading and gate-line consistency, because there is no guide to fact-check against yet.

Until the guide lands, `Sources/OtplessBM/Otpless.swift` (the `Otpless` singleton — the entire public entry point) is the best starting map.

## Build & test

This repo's toolchain has one load-bearing quirk, discovered while wiring this gate: **plain `swift build` / `swift test` fail outright**, because `Package.swift` only declares `platforms: [.iOS(.v13)]` and the code imports UIKit — SwiftPM's bare CLI targets the *host* (macOS) by default, and macOS isn't a platform this package supports (`OtplessEventIO` additionally requires macOS 10.15+, which isn't declared either). This is a genuine platform mismatch, not a fixable misconfiguration, and `Package.swift`'s platform list is public-facing (changing it is a real product/compat decision, out of scope for scaffolding) — so every script here cross-compiles for the iOS Simulator explicitly instead:

```bash
bash scripts/build.sh        # swift build --sdk <iphonesimulator SDK> --triple arm64-apple-ios13.0-simulator
bash scripts/run-tests.sh    # swift test with the same flags, IF a Tests/ directory exists (it doesn't yet — see below)
```

The full verification gate — `make gate` in the root `Makefile` is the canonical definition (see the **verify** skill for what each rung actually checks):

```bash
bash scripts/build.sh
bash scripts/run-tests.sh
bash scripts/check-api-baseline.sh
pod lib lint OtplessBM.podspec --allow-warnings
bash scripts/docs-verify.sh
```

Or simply: `make gate`.

- **No `Tests/` directory exists in this repo today** — `scripts/run-tests.sh` detects this and no-ops with a message rather than failing the gate; `swift test` on a package with no test target errors with "no tests found", which would otherwise make every gate run red. The moment a real test target is added (see the **add-tests** skill), this script starts running it automatically — no changes needed.
- `scripts/check-api-baseline.sh` is this repo's API-breakage check — the Swift/SPM analog of the Android SDKs' binary-compatibility-validator `.api` dump. `swift package diagnose-api-breaking-changes` does **not** work here (same host-platform-build problem as above — confirmed by running it, not assumed), so this script drives `swift-api-digester` directly, scoped to just the `OtplessBM` module, against a committed baseline at `api-baseline/OtplessBM.json`. Sanity-tested: making a public method `internal` and rerunning the script produces `Func Otpless.<name>() has been removed` and a non-zero exit. Regenerate with `bash scripts/check-api-baseline.sh --update` after a deliberate, semver-appropriate API change, and review the JSON diff before committing.
- `pod lib lint OtplessBM.podspec --allow-warnings` (no `--quick`) builds all three subspecs (`Core`, `FacebookSupport`, `GoogleSupport`) — takes ~3.5 minutes locally, passes today with warnings only (see "Known findings" below), no errors. `--allow-warnings` is necessary because Google/Facebook's own transitive pods emit deployment-target warnings this repo doesn't control. **This step is disk-intensive** — each full run leaves several GB of `~/Library/Developer/Xcode/DerivedData/App-*` behind (the `GoogleSupport` subspec alone pulls in ~22 transitive targets), and it was observed to fail with a `lipo: ... No space left on device` error on a disk under pressure — that failure mode is an environment/disk-space problem, not a real lint failure; don't debug it as one. If disk space is tight, `pod lib lint OtplessBM.podspec --allow-warnings --quick` (podspec-validity + dependency-resolution only, ~1 second, no compilation) is the lighter fallback for local iteration — but it does not catch what the full lint catches (e.g. a subspec that doesn't actually compile against its declared dependencies), so don't substitute it into the CI gate without a deliberate decision.
- `scripts/docs-verify.sh` mechanically checks that `OtplessBM.podspec`'s `s.version` has a matching `CHANGELOG.md` heading (or an `## Unreleased` section exists), and that CLAUDE.md's documented gate commands match the Makefile's `gate` target prerequisites.
- **CI does not pin an explicit Xcode version** (see "Known findings/follow-ups" below) — it uses whichever Xcode the `macos` GitHub-hosted runner defaults to. `swift-api-digester` dumps are sensitive to SDK/Xcode version skew; if CI's default Xcode ever drifts from whatever generated the committed baseline, expect `scripts/check-api-baseline.sh` to need a `--update` even without a real API change. Pinning a specific Xcode version (via an action like `maxim-lobanov/setup-xcode`, SHA-pinned) is a tracked follow-up, not done in this PR because I could not verify which Xcode versions are actually available on GitHub's hosted `macos` runners from this environment.

### Local dev setup

No `local.properties`-equivalent is needed to build or test `OtplessBM` itself — there's no sample app and no credentials gate any of the commands above. `pod lib lint` needs CocoaPods installed (`gem install cocoapods`, or already present on GitHub's `macos` runners).

### Publishing

This repo's git history (`git log --oneline | grep -i version`) shows every past release as a plain "version bump" commit — `OtplessBM.podspec`'s `s.version` edited, then a matching git tag (`1.0.0` through the current `2.3.2` all exist as tags). There is no in-repo publish script or CI publish job:

- **SPM** needs nothing beyond the git tag — consumers pin `from: "<version>"` and SPM resolves it directly from the repo's tags. No build/upload step.
- **CocoaPods** additionally needs `pod trunk push OtplessBM.podspec` (or `--allow-warnings` to match the lint invocation above) from a machine with a registered CocoaPods Trunk session for this pod. I could not verify Trunk ownership/session state from this environment — the **release** skill documents the standard mechanic but does not assume you can run it without checking `pod trunk me` first.

### Known findings / follow-ups (read before assuming otherwise)

- **CHANGELOG.md was missing a `2.3.2` entry.** `OtplessBM.podspec`'s `s.version` was bumped `2.3.1` → `2.3.2` in the same commit as "SNA failure error code and description added. (#40)" (tag `2.3.2` exists), but no `## 2.3.2` heading was ever added to `CHANGELOG.md` — a pre-existing gap, not introduced by this PR. This PR adds an `## Unreleased` section (required by scaffolding item 8) but deliberately does **not** backfill the missing `2.3.2` entry — that's a docs-sync/guide-adjacent judgment call outside a scaffolding PR's scope. Flagged here so it isn't lost.
- **`.swiftpm/xcode/**/xcuserdata/` files were tracked in git** (two contributors' personal Xcode UI state: breakpoints, scheme management, workspace UI state) despite `.gitignore` already having an `xcuserdata/` rule — gitignore doesn't retroactively untrack. This PR runs `git rm --cached` on them; the `.gitignore` rule now actually does its job going forward.
- **`.gitignore` blanket-ignored `docs/` and `CLAUDE.md`** under a "Claude Code / agent session artifacts" comment — which would have fought this very PR (and forced the parallel guide PR, `feat/sdk-guide`/#41, to `git add -f` its own files, which is what surfaced this). Neither line was hiding a real local-only artifact (there is no `docs/` directory or per-agent scratch content in this repo today) — this PR removes both lines outright rather than narrowing them to a specific subpath, since there's nothing to preserve.
- **`Constants.swift`'s `SDK_VERSION` doesn't match `OtplessBM.podspec`.** `Sources/OtplessBM/utils/Constants.swift:20` hardcodes `SDK_VERSION = "2.3.1"` while the podspec (and the latest git tag) are `2.3.2` — meaning every telemetry event sent via `DeviceInfoUtils.swift:90`'s `params["sdkVersion"] = Constants.SDK_VERSION` currently under-reports the SDK version by one release. This PR does **not** silently bump the constant — that's a behavior change (it changes what ships in every telemetry payload) for the release owner to decide, not a scaffolding-PR side effect. Instead, `scripts/docs-verify.sh` now has a `WARN`-level check (not `FAIL` — see the script's own comment) that surfaces this drift on every run until a maintainer fixes it and the check is promoted to `fail()`. The **release** skill's version-bump step explicitly lists `Constants.SDK_VERSION` as a place version lives, so this doesn't recur.
- **`pod lib lint --allow-warnings` passes with pre-existing warnings**, not introduced by this PR: several `TransactionStatusResponse.swift` warnings about implicit `Any` coercion, and one real concurrency warning at `Otpless.swift:376` ("sending 'handler' risks causing data races... main actor-isolated 'handler' to nonisolated instance method"). Constitution article 2 (never harm the host app) treats data-race warnings as a real finding — this PR does not fix it (scaffolding shouldn't bundle unrelated source changes), but it's a legitimate first target for whoever picks up Swift 6 strict-concurrency cleanup.
- **No Xcode version is pinned in CI** — see the CI explanation above. Follow-up once a specific `macos` runner image / Xcode version combination is confirmed available.
- **Not all public API is `@objc`.** `Otpless` (the singleton, `final public class Otpless: NSObject`) mixes `@objc public func` members (Objective-C-bridgeable: `initialise`, `start`, `cleanup`, `isSdkReady`, `setMfaEnabled`, …) with plain `public func` members that are Swift-only (`startAuth`, `commitOtplessResponse`, `setResponseDelegate`, `userAuthEvent`, `setEnvironment`, `setLoggerDelegate`, `clearAll`). This looks deliberate (newer async/Swift-concurrency-shaped APIs aren't marked `@objc`, which wouldn't support `async` anyway), but it means new public API needs a conscious decision about Objective-C bridging, not just adding `public`. See constitution article 1.
- **No repo-level size-budget artifact exists.** SPM ships source, not a binary artifact, for this kind of package — there's no AAR-equivalent to measure directly. This PR's **size-review** skill measures source line/file counts (`find Sources -name '*.swift' | xargs wc -l`: 48 files, ~7,660 lines at time of writing) as the honest, currently-available proxy; a `feat/xcframework` branch exists in this repo's history suggesting XCFramework distribution has been explored, which would give a real binary-size number if it ever lands — noted as a follow-up, not adopted here.

## Repo protocols — invoke the skill, don't improvise

Detailed procedures live as skills in `.claude/skills/`. These are MANDATORY when their trigger applies:

| Skill | When it applies |
|---|---|
| **verify** | Before claiming any SDK change works, after modifying `Sources/OtplessBM/` source, or when asked to verify/prove a change. |
| **add-tests** | Adding the first (or any subsequent) Swift test in this repo — there is no existing test culture to follow yet; this skill is honest about that. |
| **pr-review** | Reviewing any PR or diff that touches `Sources/OtplessBM/` against the six constitution articles below, in order, before merge. |
| **release** | Cutting a release: podspec version bump → tag → (optionally) `pod trunk push`. |
| **size-review** | Every PR touching `Sources/OtplessBM/`: source-size delta (the only artifact currently measurable — see above), plus a reflection/consumer-rules-equivalent checklist for the `#if canImport(...)` optional-dependency pattern. |
| **bump-dependency** | Reviewing a bump to `OtplessEventIO` (SPM dependency), or the CocoaPods-only `FBSDKCoreKit`/`FBSDKLoginKit`/`GoogleSignIn`/`GoogleSignInSwiftSupport` version constraints in the podspec. |
| **docs-sync** | Once `docs/SDK-GUIDE.md` lands: syncing it and `CHANGELOG.md` with SDK code changes. Not yet actionable — see the skill's own note. |

## SDK development constitution (MANDATORY for every code change)

This SDK runs inside enterprise clients' apps. We are a guest in their process: their crash rate, startup time, security audit, and app size all include us. Every change is held to these rules — they outrank convenience, and exceptions require an explicit decision recorded in the PR and the changelog.

### 1. Public API is a contract

- **Semver discipline.** Breaking anything a merchant can observe — method signatures, response payload keys, response ordering, error codes, default behavior — requires a major-version decision, a `**BREAKING:**` changelog entry, and a wrapper-SDK migration check against **both** `otpless-rn-lite` and `otpless-rn-full` (the hub CLAUDE.md's topology table: both React Native wrappers pin this exact iOS SDK). When in doubt, it's breaking.
- **Deprecate, then remove — never remove cold.** Mark `@available(*, deprecated, message: "...")` (or the Objective-C-visible equivalent if the symbol is `@objc`) pointing at the replacement → keep it working for at least 2 minor releases → remove.
- **Additive evolution only.** Extend via new optional parameters with defaults, new setters, or new response fields — never by changing the meaning of existing ones.
- **Swift/Objective-C binary-compat traps:** parameter *names* are API for Swift call sites (labeled arguments); *selector* shape is API for the `@objc` surface — renaming an `@objc` method's Swift name or its parameters changes its Objective-C selector too. Decide deliberately whether a new public member needs `@objc` (Objective-C/legacy-bridging consumers) or can stay Swift-only (e.g. anything `async`, which `@objc` cannot express) — see the "Known findings" note above; don't add `@objc` reflexively, and don't omit it from something that legacy consumers need to call.
- **Smallest possible surface.** Prefer `internal` unless a merchant or wrapper demonstrably needs a symbol public. There is no `explicitApi()`-equivalent compiler enforcement in Swift for this — it's a review-discipline requirement, not a mechanical one; `scripts/check-api-baseline.sh` only catches an *unintended* API change once it's already public, not an unnecessarily-public new symbol.
- **Never leak third-party types** (the raw `OtplessEventIO` module, `FBSDKLoginKit`/`GoogleSignIn` types) in public signatures reachable by SPM consumers, who never get those pods. Public payloads use Foundation/Swift standard types (`String`, `[String: Any]`, `Data`) — never force a dependency version choice onto a merchant.
- **The committed `api-baseline/OtplessBM.json` is the mechanical contract** — any public-surface change requires a reviewed `bash scripts/check-api-baseline.sh --update` in the same PR (CI enforces this by running the check unmodified and failing on drift).

### 2. Never harm the host app

- **Never crash the merchant.** No exception/fatal error may escape an SDK entry point or a callback into merchant code. Swift doesn't have Kotlin-style checked exceptions here — this means defensive `guard`/`try?`/`Result` handling at every boundary a merchant can reach, not `try!` or force-unwraps on merchant-influenced input (network responses, deep-link URLs, merchant-supplied config).
- **Never block the main thread.** Merchant-facing callbacks are delivered via `@MainActor`-annotated code paths (`Otpless.swift`, `PasskeyUseCase.swift`, `DeviceInfoUtils.swift`, `Utils.swift`, `Logger.swift` all already use `@MainActor` or `DispatchQueue.main` deliberately — keep this pattern for new UI-adjacent or delegate-callback code). Network/parsing work stays off the main thread.
- **Concurrency correctness is a real, current gap, not a hypothetical.** The pre-existing `Otpless.swift:376` warning ("sending 'handler' risks causing data races... main actor-isolated 'handler' to nonisolated instance method") is exactly the class of bug this article exists to prevent — a data race reachable from merchant-supplied callbacks. Don't introduce more of these; treat any new Swift 6 concurrency warning in `pod lib lint` output as a real finding, not lint noise.
- **Undo every process-global side effect.** `Otpless.shared.cleanup()` and `.clearAll()` are the documented release points — verify any new state you add (URLSession tasks, `NotificationCenter` observers, timers, background work) is actually torn down by one of these, not just by process exit. There is currently no `deinit` anywhere in `Sources/OtplessBM/` (confirmed by search) — cleanup here is 100% explicit/manual, unlike a class that self-releases resources in `deinit`. Assume the host app lives for days and never calls `deinit` on this singleton.
- **No surprises for the merchant's app.** New required `Info.plist` keys, URL schemes, or `LSApplicationQueriesSchemes` entries (see `README.md`'s integration steps) require product sign-off — enterprise security teams audit exactly this.
- **Fail safe, not loud.** If an optional capability is unavailable (Facebook/Google SDK absent under SPM, passkey APIs below the required iOS version, permission missing), the flow continues without it. The `#if !canImport(...)` stub pattern for Facebook/Google support is the reference example — extend it the same way for any new optional integration, don't reflection-hack it.

### 3. Privacy & auditability

- **Every collected data point is documented or it doesn't ship.** `Sources/PrivacyInfo.xcprivacy` currently declares collection of `NSPrivacyCollectedDataTypePhoneNumber` and `NSPrivacyCollectedDataTypeEmailAddress` (both linked to identity, both `NSPrivacyCollectedDataTypeTracking: false`, purpose `AppFunctionality`), plus `NSPrivacyAccessedAPICategoryUserDefaults` (reason `CA92.1`). Any new collected field or accessed API category needs a same-PR update to this file and (once it exists) a `docs/SDK-GUIDE.md` update — product sign-off required either way.
- **No App Tracking Transparency / IDFA usage exists today** (confirmed by grep — no `ASIdentifierManager`, no `AppTrackingTransparency` import). If a future change needs either, that's an `NSPrivacyTracking: true` flip and an ATT prompt decision — a product decision, not something to add incidentally.
- **No PII in release logs.** Phone numbers, OTPs, tokens, and user identities never reach unconditional log output — check `Logger.swift` for the existing debug-gating pattern before adding new log statements.
- **Respect platform privacy signals** by omitting data, not working around it (this SDK collects no ad-tracking identifiers today — keep it that way unless a product decision says otherwise).

### 4. Naming conventions

- **Public API speaks merchant language.** `OtplessBM`/`OtplessEventIO` module names and `Otpless`-prefixed public types are already the convention — no internal codenames appear in public symbols today; keep it that way.
- **Swift API Design Guidelines** everywhere: `UpperCamelCase` types, `lowerCamelCase` members/parameters, clear argument labels (Swift's own style, distinct from Kotlin's but the same spirit as the Android spokes' naming article).
- **JSON payload keys** must match the backend contract exactly (`lowerCamelCase`, per the response contract shared with the Android spokes — see the hub's parity rule 4). Never invent a synonym for a concept the backend already names.

### 5. Dependencies & size

- **Default answer to a new dependency is no.** The one real compile-time dependency today is `OtplessEventIO` (`otpless-tech/otpless-event-io-ios`, pinned `from: "1.0.0"`, resolved at `1.0.0` in `Package.resolved`). CocoaPods-only, optional dependencies (`FBSDKCoreKit`/`FBSDKLoginKit` `~> 17.0.2`, `GoogleSignIn`/`GoogleSignInSwiftSupport` `~> 9.0`) are opt-in per subspec — SPM consumers never pull them in at all. If a new dependency is genuinely unavoidable: stable release only (never alpha/beta/RC), and — if it's meant for all consumers — added to `Package.swift`; if it's a large optional integration, follow the existing subspec + `#if canImport(...)` stub pattern instead of making it mandatory.
- **Source size is the only currently-measurable size lever** (see "Known findings" above — no XCFramework/binary artifact exists yet). Challenge new dependencies and new source before assuming a build artifact will absorb the cost; nothing here strips dead code the way an Android R8 shrink does.
- **Two subspecs (`FacebookSupport`, `GoogleSupport`) pull in their own dependency trees** (Facebook/Google SDKs and their transitives) — `pod lib lint`'s deployment-target warnings for `RecaptchaInterop`, `PromisesSwift`, `PromisesObjC`, `GTMSessionFetcher` come from these, not from this repo's own code. Don't "fix" those warnings here; they're upstream.

### 6. Verification before merge

- **Run the full gate, not a subset.** `make gate` (see "Build & test" above).
- **Both distributions matter.** A change that only gets verified via `swift build`/SPM but breaks the podspec (or vice versa) ships broken to half of this SDK's consumers — `pod lib lint` and the SPM build are both mandatory, not redundant.
- **Exercise the changed flow end-to-end** where feasible; this repo has no sample app, so "exercise" for a behavioral change means, at minimum, a passing `bash scripts/build.sh` plus a description in the PR of what was manually checked (e.g. in a scratch Xcode project). SNA (carrier network binding), deep-link handling, passkey/WebAuthn, and Apple/Google/Facebook sign-in all need a **physical device or a properly provisioned simulator** and are effectively human-only — state plainly if a flow needs a human and wasn't run.
- **minSdk-equivalent honesty:** `platforms: [.iOS(.v13)]` is the floor — every `@available(iOS X, *)`-gated call (there are several, e.g. `@available(iOS 15.0, *)` in `Otpless.swift`) needs a defined fallback for iOS 13/14, not just an availability annotation with no `else` path.
- **Wrapper check:** if the response contract or public API moved, confirm `otpless-rn-lite` and `otpless-rn-full` (both pin this iOS SDK per the hub topology) either tolerate it or have a coordinated update filed.

## General working rules

- **Worktree-driven development (MANDATORY for parallel/independent work).** The primary checkout belongs to whoever has it open — never switch its branch out from under them. Every independent agent task gets its own git worktree:
  ```bash
  git worktree add /tmp/<repo>-<task> -b <branch> origin/main   # work + commit + push from there
  git worktree remove /tmp/<repo>-<task>                        # always clean up when done
  ```
  This is the same rule the workspace hub (`android-sdk/CLAUDE.md`) states for all spokes. **Caveat discovered while writing this file:** on macOS, `/tmp` is itself a symlink to `/private/tmp`; a shell's `pwd` shows the unresolved `/tmp/...` form while Python's `os.getcwd()` (and most non-shell tooling) returns the resolved `/private/tmp/...` form. Any hook or script here that compares an absolute `file_path` against a `cwd`-derived root must resolve both sides with `os.path.realpath()` (or equivalent) first, or the comparison silently fails for exactly the worktree layout this rule mandates. The hooks in `.claude/settings.json` already do this — don't regress it if you edit them.
- **Git workflow:** work on a feature branch, open a PR, fill the PR template's constitution checklist (including the parity-statement line — the hub's Android ↔ iOS parity rule: "Android typically leads"; a phone-auth-related change here that has an Android counterpart change needs a parity statement). CI on every PR: `build-test` (the gate above + actionlint). Never push directly to `main`.
- **`docs-sync`, `docs-audit`, and a device-smoke CI workflow are deliberately NOT added in this PR** — they depend on `docs/SDK-GUIDE.md` existing (parallel PR) and/or a provisioned device/simulator matrix this PR didn't set up. Tracked in "Follow-ups" below, mirroring how `otpless-headless-android-sdk`'s equivalent scaffolding PR handled the same guide-not-merged-yet situation.
- Match the file you're editing: this is a single Swift codebase (no dual JSON-stack split like the Android spokes) — Foundation's `JSONSerialization`/`Codable` usage varies file to file; check the existing pattern in a file before introducing a third one.
- All merchant-visible output flows through `Otpless.shared`'s response-delegate mechanism (`OtplessResponseDelegate`/`setOtplessObjcResponseDelegate`) — never invoke a merchant callback directly from inside a use case.

## Follow-ups (tracked here so they aren't lost)

- Pin an explicit Xcode version in CI once a specific `macos` runner image / Xcode combination is confirmed available (reduces `swift-api-digester` baseline noise across Xcode upgrades).
- Add `docs-sync`/`docs-audit`/device-smoke CI workflows once `docs/SDK-GUIDE.md` merges (`feat/sdk-guide`).
- Backfill (or explicitly decide not to backfill) the missing `CHANGELOG.md` `## 2.3.2` entry.
- Add a real `Tests/` target — see the **add-tests** skill for the honest starting state (there is none today).
- Investigate whether `feat/xcframework` (an existing, unmerged branch in this repo's history) should land, to get a real binary-size artifact for the **size-review** skill to measure instead of source line counts.
- Fix the `Otpless.swift:376` data-race warning surfaced by `pod lib lint` (constitution article 2).
