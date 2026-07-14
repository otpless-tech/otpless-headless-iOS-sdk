# OTPLESS Headless iOS SDK — Code Guide

> **Audience:** Any developer (human or AI) who needs to learn, navigate, modify, or extend the SDK code.
> **Scope:** The `OtplessBM` Swift package (`Sources/OtplessBM/`) — the entire published surface for both distribution channels (SPM and CocoaPods). There is no separate sample/test app module in this repository to exclude.
> **Source of truth:** This document describes the code as of SDK version **2.3.2** (`OtplessBM.podspec` → `s.version`), at commit `591d76a356afdecc487ebda781fe4b03780a4aaa` on `main`. Note a verified drift: the runtime-reported version string (`Constants.SDK_VERSION`, sent in every `appInfo.sdkVersion` field and in the device telemetry event) is still `"2.3.1"` — the last release commit bumped the podspec but not this constant (§24 quirk #1). When code and doc disagree, the code wins — please update this doc.

---

## Table of Contents

1. [What This SDK Is](#1-what-this-sdk-is)
2. [Repository & Source Layout](#2-repository--source-layout)
3. [Build, Toolchain & Distribution](#3-build-toolchain--distribution)
4. [Glossary of Domain Terms & Identifiers](#4-glossary-of-domain-terms--identifiers)
5. [Architecture Overview](#5-architecture-overview)
6. [Public API Surface](#6-public-api-surface)
7. [Global SDK State (`Otpless` singleton fields)](#7-global-sdk-state-otpless-singleton-fields)
8. [End-to-End Flows](#8-end-to-end-flows)
9. [Response Semantics & Error Codes](#9-response-semantics--error-codes)
10. [Networking Layer](#10-networking-layer)
11. [Network Data Models](#11-network-data-models)
12. [Silent Network Auth (SNA) Deep Dive](#12-silent-network-auth-sna-deep-dive)
13. [Device Intelligence / Fingerprinting](#13-device-intelligence--fingerprinting)
14. [OneTap Bottom-Sheet UI](#14-onetap-bottom-sheet-ui)
15. [Device, App & Data Collection Inventory](#15-device-app--data-collection-inventory)
16. [Telemetry / Event Pipeline (`OtplessBMEvents`)](#16-telemetry--event-pipeline-otplessbmevents)
17. [Persistence](#17-persistence)
18. [Concurrency Model](#18-concurrency-model)
19. [Public API Stability & Objective-C Interop Surface](#19-public-api-stability--objective-c-interop-surface)
20. [Info.plist / Entitlements Requirements](#20-infoplist--entitlements-requirements)
21. [External Dependencies](#21-external-dependencies)
22. [Testing](#22-testing)
23. [How-To: Common Modifications](#23-how-to-common-modifications)
24. [Known Quirks & Gotchas](#24-known-quirks--gotchas)
25. [Removed & Deprecated API History](#25-removed--deprecated-api-history)

---

## 1. What This SDK Is

This is the **OTPLESS headless iOS SDK**, product name **`OtplessBM`**. "Headless" means the merchant app builds its own login UI and drives authentication through the `Otpless` singleton, receiving results through a delegate/callback — with one notable exception: the SDK optionally presents a small **native "OneTap" bottom sheet** for picking among previously-used identities (§14), so this SDK is not as strictly headless as the Android lite SDK it otherwise parallels.

Unlike the Android **lite** SDK (phone-number-auth only), this iOS SDK supports a broad set of authentication channels in one artifact: phone number (OTP/OTP-link/magic-link style, SNA), email, native social sign-in (Google and Facebook via optional CocoaPods subspecs, Apple via the system AuthenticationServices framework), generic OAuth/backend-redirect channels (WhatsApp, Twitter, GitHub, LinkedIn, …), WebAuthn/Passkey (`DEVICE` channel), an SSO deep-link code-verify flow, and MFA (multi-factor) chaining. It is closer in scope to `otpless-headless-android-sdk` ("full") than to `otpless-headless-android-lite`.

- **Distribution:** Swift Package Manager (`Package.swift`, product `OtplessBM`) and CocoaPods (`OtplessBM.podspec`, pod `OtplessBM`, subspecs `Core`, `FacebookSupport`, `GoogleSupport`).
- **Product/module name:** `OtplessBM`. Top-level Swift type: `Otpless` (singleton `Otpless.shared`).
- **Backend:** `https://user-auth.otpless.app` (production) / `https://user-auth.otpless.tech` (DEBUG-only staging toggle), plus the server-selected SNA partner URL for silent auth, plus `https://api.otpless.com/` for the separate session-persistence feature (§6.5), and OTPLESS's telemetry backend via `OtplessEventIO` (transport implementation lives in the sibling `otpless-event-io-ios` package, not in this repo).
- **Consumers:** merchant iOS apps directly, and the two OTPLESS React Native wrappers (`otpless-rn-lite`, `otpless-rn-full`), which both pin this SDK for their iOS side.

The high-level contract with a merchant app:

```swift
// 1. Initialize once (e.g. in viewDidLoad)
Otpless.shared.initialise(withAppId: "MY_APP_ID", vc: self)
Otpless.shared.setResponseDelegate(self)   // conform to OtplessResponseDelegate

// 2. Start an authentication (async)
let request = OtplessRequest()
request.set(phoneNumber: "99xxxxxx99", withCountryCode: "+91")
await Otpless.shared.start(withRequest: request)

// 3. (If OTP flow) verify the OTP the user typed
let verify = OtplessRequest()
verify.set(phoneNumber: "99xxxxxx99", withCountryCode: "+91")
verify.set(otp: "123456")
await Otpless.shared.start(withRequest: verify)

// 4. Every result arrives as OtplessResponse via OtplessResponseDelegate.onResponse,
//    always hopped onto the main queue. Terminal success is responseType == .ONETAP.
```

---

## 2. Repository & Source Layout

```text
ios-headless/                              (GitHub: otpless-headless-iOS-sdk)
├── Package.swift                # SPM manifest: product "OtplessBM", iOS 13+, depends on otpless-event-io-ios
├── Package.resolved             # pinned otpless-event-io-ios revision (1.0.0)
├── OtplessBM.podspec            # CocoaPods spec: version 2.3.2, subspecs Core/FacebookSupport/GoogleSupport
├── CHANGELOG.md                 # per-release notes (no artifact-size table — see §3)
├── README.md                    # merchant integration guide (Info.plist, deep link, quick start)
├── LICENSE
└── Sources/
    ├── PrivacyInfo.xcprivacy    # Apple privacy manifest (§20)
    └── OtplessBM/               # ★ THE ENTIRE SDK — no separate app/sample module in this repo ★
        ├── Otpless.swift                # PUBLIC singleton facade + orchestrator (init, start, response dispatch)
        ├── dto/
        │   ├── OtplessRequest.swift          # merchant-built request (+ DeviceFingerprintMode, OtplessAuthCofig)
        │   ├── OtplessResponse.swift         # response envelope + internal factory helpers
        │   ├── ResponseTypes.swift           # enum of all response types
        │   ├── OtplessChannelType.swift       # OAuth/social channel enum (+ ObjC string-constant mirror)
        │   ├── OtplessEnvironment.swift       # PRODUCTION / (DEBUG-only) STAGING base-URL switch
        │   ├── OtplessConstant.swift          # terminal error codes, snaError JSON key
        │   ├── AuthEvent.swift                # merchant-reported CLE event enum
        │   ├── ProviderType.swift             # CLE provider enum (CLIENT/OTPLESS)
        │   ├── SdkAuthParams.swift            # internal carrier for native-SDK (Google/FB/Apple) auth params
        │   ├── SdkState.swift                 # READY / NOT_READY
        │   └── TokenAsIdUIdAndTimerSettings.swift  # internal 4-tuple: token/asId/uid/timerSettings
        ├── extensions/
        │   ├── OtplessExtensions.swift        # invokeResponse (the response funnel, §9.3) + SDK-auth glue
        │   └── StringExtensions.swift         # trimSSOAndSDKFromStringIfExists (channel-name cleanup)
        ├── network/
        │   ├── api/
        │   │   └── ApiManager.swift           # URLSession-based request builder + all path constants + enrichment
        │   ├── cellular/
        │   │   └── CellularConnectionManager.swift  # raw NWConnection SNA client (forces cellular transport)
        │   └── model/
        │       ├── request/
        │       │   └── PostIntentRequestBody.swift   # Codable POST body for the intent endpoint
        │       └── response/
        │           ├── StateResponse.swift            # { state }
        │           ├── MerchantConfigResponse.swift   # channel/UI config, MFA flag, device-intelligence type
        │           ├── IntentResponse.swift            # { quantumLeap, oneTap? }
        │           └── TransactionStatusResponse.swift # { authDetail, oneTap?, quantumLeap?, ... } + all nested DTOs
        ├── repository/
        │   ├── ApiRepository.swift            # one call per endpoint; owns the CellularConnectionManager for SNA
        │   └── CoreHttpClient.swift            # generic URLSession wrapper used ONLY by OtplessSessionManager (§6.5)
        ├── usecase/
        │   ├── GetStateUseCase.swift           # state fetch + 2-attempt retry
        │   ├── GetMerchantConfigUseCase.swift  # merchant/channel config fetch + 2-attempt retry
        │   ├── PostIntentUseCase.swift         # start-auth API + response branching (the heart of start())
        │   ├── VerifyOTPUseCase.swift          # OTP verification
        │   ├── VerifyCodeUseCase.swift         # SSO-code / WebAuthn-data verification
        │   ├── TransactionStatusUseCase.swift  # generic status polling loop
        │   ├── SNAUseCase.swift                # SNA race: partner call vs status polling
        │   ├── IntelligenceUseCase.swift       # reflection bridge to optional intelligence SDK
        │   ├── AppleSignInUseCase.swift        # native Sign in with Apple
        │   └── PasskeyUseCase.swift            # WebAuthn / Passkey (ASAuthorization) registration + assertion
        ├── sdkLogin/
        │   ├── GoogleSupport/GIDSignInUseCase.swift    # compiled only if GoogleSignIn is linked (subspec)
        │   └── FacebookSupport/FBSdkUseCase.swift      # compiled only if FBSDKLoginKit is linked (subspec)
        ├── session/
        │   ├── OtplessSessionManager.swift    # separate PUBLIC actor: JWT session persistence/refresh (§6.5)
        │   └── models.swift                    # session DTOs + OtplessSessionState
        ├── views/
        │   └── OneTapView.swift                # OneTap bottom-sheet UI: OneTapView, OneTapCell, OneTapBottomSheetViewController, LogoRingView (§14)
        └── utils/
            ├── ApiResponse.swift               # internal ApiResponse<T> enum + ApiError
            ├── Constants.swift                 # Keychain/UserDefaults key names, status strings, SDK_VERSION
            ├── ConvertUtils.swift              # makeSnaUseCaseResponse (SNA/MFA status → responses)
            ├── DeviceInfoModel.swift            # legacy-looking device-id dictionary builder (§24 quirk)
            ├── DeviceInfoUtils.swift            # appInfo/deviceInfo builders, app-hash, WhatsApp detection
            ├── SecureStorage.swift              # Keychain wrapper (+ small UserDefaults helpers)
            ├── Logger.swift                     # log()/DLog() DEBUG-gated logging + delegate fan-out
            ├── Utils.swift                      # JSON<->dictionary helpers, base64url helpers, ImageUtils
            └── Events/
                └── OtplessBMEvents.swift        # ALL telemetry event definitions (via OtplessEventIO)
```

**Naming note:** the module is `OtplessBM`; the merchant-facing singleton is `Otpless`, not `OtplessBM` — an easy mix-up. There is no internal codename like Android's "LongClaw" — file headers still reference the old working names `OtplessSDK` / `otpless-iOS-headless-sdk` from before the module was renamed; this is cosmetic (file-header comments only) and does not affect the type/module names.

---

## 3. Build, Toolchain & Distribution

| Item | Value |
|---|---|
| SDK version | `OtplessBM.podspec` → `s.version` = **2.3.2**. Runtime string `Constants.SDK_VERSION` = **"2.3.1"** (stale — §24 quirk #1) |
| Swift tools version | 5.9 (`Package.swift` → `// swift-tools-version: 5.9`) |
| Minimum iOS version | **13.0** (`Package.swift` → `.iOS(.v13)`; podspec → `s.ios.deployment_target = '13.0'`) |
| Supported Swift versions | 5.5–6.0 (podspec `s.swift_versions`); `Package.swift` also declares `swiftLanguageVersions: [.v5]` |
| Distribution 1: SPM | `Package.swift` — single product `OtplessBM` / single target `OtplessBM`, depending on the `otpless-event-io-ios` package (`from: "1.0.0"`, resolved to `1.0.0` in `Package.resolved`) |
| Distribution 2: CocoaPods | `OtplessBM.podspec` — subspec `Core` (always required; source files `Sources/OtplessBM/**/*`, depends on `OtplessEventIO ~> 1.0`), plus two **optional** subspecs: `FacebookSupport` (`FBSDKCoreKit`/`FBSDKLoginKit` ~> 17.0.2) and `GoogleSupport` (`GoogleSignIn`/`GoogleSignInSwiftSupport` ~> 9.0) |
| Resource bundle | `Sources/PrivacyInfo.xcprivacy` shipped as the `OtplessBM` resource bundle (both SPM and CocoaPods) — Apple's required privacy manifest (§20) |
| No compile-time dependency on device intelligence | The optional `OTPlessIntelligence` SDK is **never imported** — reached purely via `NSClassFromString`/Objective-C runtime selectors (§13), exactly mirroring the Android pattern of a reflection contract instead of a compile dependency |

**Conditional compilation flags actually used in source** (not build settings — Swift `#if` directives):
- `DEBUG` — gates all logging (`log()`, `DLog()`, `print` in `CellularConnectionManager`) and adds `OtplessEnvironment.STAGING` as a compiled case (§9.4 parity row) and the `setEnvironment(_:)` public setter.
- `OTPLESS_INTERNAL` — gates two extra `ResponseTypes` cases (`API_RESPONSE`, `DEVICE_INTELLIGENCE`) and the code paths that emit them (`ApiRepository.sendApiResponse`, `Otpless.dispatchDIEvent`). Not defined by default in either `Package.swift` or the podspec, so merchant builds never see these response types — this appears to be an internal-only diagnostic build flag, not a merchant-facing feature toggle.
- `canImport(FBSDKLoginKit)` / `canImport(FacebookCore)` / `canImport(GoogleSignIn)` / `canImport(GoogleSignInSwift)` — `FBSdkUseCase` and `GIDSignInUseCase` each compile to a **stub implementation that always reports "support not initialized"** when the corresponding optional pod/package isn't linked, so the `Core`-only SDK still builds and runs without the social-login subspecs.

**No release-shrinking / obfuscation step exists for this SDK** — Swift libraries distributed via SPM/CocoaPods are compiled by the *consuming* app's own toolchain (whole-module optimization, dead-code stripping happen there, not in this repo). There is no equivalent of Android's R8/ProGuard pipeline; the closest analogue is Swift's own access-control (`public`/`internal`/`private`) plus Objective-C bridging via `@objc`, covered in §19.

**No `CHANGELOG.md` artifact-size table exists** (unlike the Android lite SDK) — binary/library size is not currently tracked as a release-gated metric in this repo.

**Typical commands** (no CI workflow files exist in this repo yet — these are the manual equivalents):

```bash
swift build                          # build the package
swift test                           # run tests (§22 — currently no test target/target sources exist)
xcodebuild -scheme OtplessBM -destination 'generic/platform=iOS' build   # Xcode-toolchain build
pod lib lint OtplessBM.podspec       # validate the podspec
```

---

## 4. Glossary of Domain Terms & Identifiers

| Term | What it is | Origin | Lifetime |
|---|---|---|---|
| `merchantAppId` | Merchant's OTPLESS project ID | Merchant passes to `initialise(withAppId:...)` | Process |
| `state` | Server-issued session state token; path parameter of every user-auth API | `GET /v2/state` (cached in Keychain) | Cached across launches |
| `tsid` / `inid` | Tracking-session id / install id | `OtplessEventIO.trackingIds` | Per event-io rules |
| `uid` | OTPLESS user id of the (previously) authenticated user | Returned by intent/verify/SNA APIs; persisted | Persisted in Keychain (`UID_KEY`) |
| `token` | `channelAuthToken` — the current transaction's token (a.k.a. `requestId` in merchant-facing responses) | intent / SNA responses | Reset in `resetStates()` on ONETAP |
| `asId` | Auth-session id of the current transaction | Same as token | Reset in `resetStates()` on ONETAP |
| `rsId` | Fingerprinting request-session id: `"UUID-uptimeNanoseconds-state"` | Generated in `triggerDeviceIntelligenceIfNeeded` | Cleared when ONETAP delivered or DI completes |
| `drfID` | Device-intelligence result id returned by the optional intelligence SDK | `IntelligenceUseCase.fetchIntelligence` callback | Overwritten per fingerprint job |
| `merchantLoginUri` | Deep-link URI `otpless.<appid-lowercase>://otpless` (sent to backend; merchant must register the matching `CFBundleURLSchemes` entry) | Built in `initialise()`, or merchant-supplied `loginUri:` | Process |
| `channel` / `authType` | Auth mechanism: `OTP`, `OTP_LINK`, `SILENT_AUTH`, `DEVICE`, `WHATSAPP`, `GMAIL`, `FACEBOOK`, `APPLE_EMAIL`, … | `quantumLeap.channel` | Per transaction |
| `communicationMode` | Message transport reported by the backend (`"NA"` when unknown) | intent/status/SNA responses | Per transaction |
| `phoneIntentChannel` / `emailIntentChannel` | The merchant-config-resolved default channel name for phone/email intents | `MerchantConfigResponse.channelConfig` (`type == "INPUT"`) | Refreshed on every merchant-config fetch |
| `quantumLeap` | Backend JSON object describing the transaction (channel, token, timers, intent URL, polling flag) | intent/status APIs | Per response |
| `oneTap` | Backend JSON object carrying the final authenticated user payload | intent/verify/status/SNA/code-verify APIs | Per response |
| SNA | Silent Network Auth — verifying phone ownership via an HTTP call made **over the cellular network** that the carrier can attribute to the SIM | — | — |
| MFA | Multi-factor mode; toggled via public `setMfaEnabled(_:)`; switches SNA status polling to the `mfa-sna-status` endpoint and enables `MFA_FACTOR_COMPLETED` responses | — | — |
| CLE | "Client event" — merchant-reported auth events via `userAuthEvent(...)` (event names `native_cle_*`) | — | — |
| DI | Device Intelligence — the optional fingerprinting SDK reached via reflection (§13) | — | — |

---

## 5. Architecture Overview

No DI framework; construction is manual, mostly top-down from the `Otpless` singleton, with lazily-constructed use cases:

```text
Merchant App
    │  (public API, OtplessResponseDelegate / objcResponseDelegate)
    ▼
Otpless.shared  (final class, @objc, @unchecked Sendable)   ← global state, init/start orchestration
    │ owns (lazily constructed once, never rebuilt)
    ├── apiRepository: ApiRepository        ← owns ApiManager + CellularConnectionManager
    ├── getStateUseCase / getMerchantConfigUseCase
    ├── postIntentUseCase                   ← the heart of start()
    ├── transactionStatusUseCase            ← generic status polling
    ├── snaUseCase                          ← SNA orchestration (race: partner call vs status poll)
    ├── verifyOtpUseCase / verifyCodeUseCase
    ├── passkeyUseCase / appleSignInUseCase / intelligenceUseCase
            │
            ▼
ApiRepository                        ← one method per endpoint, Result<T, Error> normalization
            │
            ▼
ApiManager                           ← URLSession-based request builder + all path constants + field enrichment
    └── performUserAuthRequest       → https://user-auth.otpless.app (or STAGING in DEBUG)

Silent Auth path:
ApiRepository.makeSNACall → CellularConnectionManager (raw NWConnection, forced .cellular transport)

Separate, independent subsystem:
OtplessSessionManager (actor) ──▶ CoreHTTPClient ──▶ https://api.otpless.com/   (§6.5 — not wired to Otpless.shared)

Cross-cutting:
  OtplessBMEvents ──▶ OtplessEventIO (sibling package) ──▶ OTPLESS telemetry backend
  DeviceInfoUtils / SecureStorage (device & persistence enrichment)
  log() / DLog() (DEBUG-only console logging + OtplessLoggerDelegate fan-out)
```

**Key design facts:**

1. **`Otpless.shared` is a process-global singleton `final class`, `@objc`, marked `@unchecked Sendable`.** All transaction identity (`token`, `asId`, `uid`, `state`, `merchantConfig`…) is global mutable state — there is exactly one authentication flow modeled at a time, though nothing in `start(withRequest:)` itself prevents two concurrent calls from racing (there is no equivalent of Android's `startMutex`/`activeStartJob` cancel-previous-start mechanism — see §24).
2. **`initialise(withAppId:...)` is idempotent-safe but not additive** — calling it again resets `merchantOtplessRequest`/`sdkState` and starts a brand-new `initialisationTask`, resolving any prior caller's suspended continuation with `false` first so nothing hangs.
3. **All merchant-visible output funnels through one method:** `Otpless.invokeResponse(_:)` (`extensions/OtplessExtensions.swift`). Every filtering/suppression rule lives there (§9.3).
4. **Responses are delivered on the main queue** via `DispatchQueue.main.async`, fanned out to up to two consumers simultaneously: the Swift `OtplessResponseDelegate` and the string-based `objcResponseDelegate` (§19).
5. **Use cases return data; `Otpless`/`OtplessExtensions` decide what to emit** — except `TransactionStatusUseCase` and `SNAUseCase`, which invoke a passed-in `onResponse`/return-array callback directly rather than going through a shared reactive stream (no `StateFlow`/`Combine` publisher is used anywhere in this codebase).
6. **Request enrichment is centralized in `ApiManager`** (§10.2) — use cases only supply flow-specific fields; identity fields (`tsId`, `inId`, `deviceInfo`, `loginUri`, `appId`, `uid`, `token`, `asId`, `rsId`, `packageName`…) are appended to *every* request inside `ApiManager.getBody`/`constructURL`.
7. **`OtplessSessionManager` is architecturally independent** of the rest of the SDK (§6.5) — it is a public `actor` with its own singleton, its own Keychain keys, its own backend host, and is never referenced from `Otpless.swift` or any use case in this list.

---

## 6. Public API Surface

Everything a merchant (or wrapper SDK) may touch, grouped by area. §19 covers *how* this surface is exposed differently to Swift vs. Objective-C consumers.

### 6.1 `Otpless` (final class, singleton) — `Otpless.swift`

| Member | Signature | Purpose |
|---|---|---|
| `shared` | `@objc public static let shared: Otpless` | The singleton instance. |
| `initialise` | `@objc public func initialise(withAppId appId: String, loginUri: String? = nil, vc: UIViewController)` | Fire-and-forget init (see flow §8.1). Not `async` — internally launches and tracks its own `Task`. |
| `isOtplessDeeplink` | `@objc public func isOtplessDeeplink(url: URL) -> Bool` | Merchant calls this from `application(_:open:options:)` to decide whether to route a URL to `handleDeeplink`; also delegates to `GIDSignInUseCase.isGIDDeeplink` when Google support is linked. |
| `start` | `@objc public func start(withRequest otplessRequest: OtplessRequest) async` | Start (or continue, when OTP/code is set) an authentication (§8.2–8.6). |
| `startAuth` | `public func startAuth(parent vc: UIViewController, config authConfig: OtplessAuthCofig) async -> Bool` | Present the native OneTap bottom sheet, or auto-start a single suggested identity in the background (§14). Not `@objc` (async, non-ObjC-safe return semantics aside from the bridging Swift already provides for simple `Bool`). Requires iOS 15+; returns `false` below that or when there is nothing to suggest. |
| `authorizeViaPasskey` | `@objc public func authorizeViaPasskey(withRequest otplessRequest: OtplessRequest, windowScene: UIWindowScene) async` | Explicit entry point for a WebAuthn/passkey-first request (§8.5). |
| `handleDeeplink` | `@objc public func handleDeeplink(_ url: URL) async` | Parse a `code` query param from an `otpless://` redirect and verify it (§8.6). |
| `registerFBApp` (×3 overloads) | `@MainActor @objc public func registerFBApp(_:didFinishLaunchingWithOptions:)`, `registerFBApp(_:open:options:)`, `registerFBApp(openURLContexts:)` | Forward Facebook SDK lifecycle calls; no-ops when `FacebookSupport` isn't linked. |
| `commitOtplessResponse` | `public func commitOtplessResponse(_ otplessResponse: OtplessResponse)` | Merchant acknowledges a received response; emits `merchant_response_commit` telemetry only. |
| `cleanup` | `@objc public func cleanup()` | Cancels the cellular path monitor, clears `merchantVC`/`responseDelegate`. |
| `isSdkReady` | `@objc public func isSdkReady() -> Bool` | `sdkState == .READY`. |
| `objcCommit` | `@objc public func objcCommit(_ otplessResponse: String?)` | Objective-C-safe counterpart of `commitOtplessResponse`, taking a JSON string (§19). |
| `gettsID` | `@objc public func gettsID() -> String` | Returns the current tracking-session id. |
| `setResponseDelegate` | `public func setResponseDelegate(_ otplessResponseDelegate: OtplessResponseDelegate)` | Register the Swift delegate. Emits `sdk_set_callback`. |
| `setOtplessObjcResponseDelegate` | `@objc public func setOtplessObjcResponseDelegate(_ otplessResponseDelegate: @escaping (String) -> Void)` | Objective-C-safe counterpart taking a JSON-string closure. |
| `setLoggerDelegate` | `public func setLoggerDelegate(_ otplessLoggerDelegate: OtplessLoggerDelegate)` | Register a debug-log observer (DEBUG builds only actually log, §16). |
| `setMfaEnabled` | `@objc public func setMfaEnabled(_ enabled: Bool)` | Enables MFA behaviour in SNA status polling (§8.8) and `MFA_FACTOR_COMPLETED` responses. |
| `setDeviceFingerprintMode` | `@objc public func setDeviceFingerprintMode(_ mode: DeviceFingerprintMode)` | Enables device-intelligence fingerprinting for subsequent requests (§13); a request can also carry its own mode (`OtplessRequest.set(deviceFingerprintMode:)`), which takes effect the same way. |
| `setEnvironment` | `public func setEnvironment(_ environment: OtplessEnvironment)` — **`#if DEBUG` only** | Switch between production and staging base URLs; compiled out of release builds entirely. |
| `userAuthEvent` | `public func userAuthEvent(event: AuthEvent, fallback: Bool, providerType: ProviderType, providerInfo: [String: String])` | Merchant-reported auth telemetry (CLE events, names `native_cle_*`). |
| `clearAll` | `public func clearAll()` | Wipes all Keychain entries under the SDK's Keychain service (§17). |

### 6.2 `OtplessRequest` (`NSObject`, `@objc`) — `dto/OtplessRequest.swift`

Builder-style parameter holder. **Create a fresh instance per authentication request** (mirrors Android's convention, though nothing enforces it here).

| Setter / property | Effect | Notes |
|---|---|---|
| `set(phoneNumber:withCountryCode:)` | sets `authenticationMedium = .PHONE`, clears email | `@objc` |
| `set(email:)` | sets `.EMAIL`, clears phone/countryCode | `@objc` |
| `set(channelType: OtplessChannelType)` | sets `.OAUTH` | **not** `@objc` (Swift enum) |
| `set(objcChannelType: String)` | same, via `OtplessChannelType.fromString(_:)` | `@objc` bridge for the above |
| `set(requestIdForWebAuthn:)` | sets `.WEB_AUTHN` | `@objc` |
| `set(fromBackend requestId:)` | sets `.PHONE` with a backend-supplied `requestId` | `@objc`; drives `isBackendGeneratedRequest()` |
| `set(otp:)` | presence flips the request to a **verify** request (`isIntentRequest() == false`) | `@objc` |
| `set(otpExpiry:)`, `set(otpLength:)`, `set(deliveryChannelForTransaction:)` | any of these makes it a "custom request" (`isCustomRequest()`), which the intent body's `silentAuthEnabled` computation excludes from SNA eligibility | `@objc` |
| `set(locale:)` | free-form locale string sent in the intent body | `@objc` |
| `set(code:)` | SSO/backend redirect code, used by `getQueryParams()`? — actually consumed by `getDictForIntent()`/`getEventDict()` only | `@objc` |
| `set(extras:)` | `[String: String]` merged verbatim into `clientMetaData` | `@objc` |
| `set(tid:)` | message-template id, merged into `clientMetaData` | `@objc` |
| `set(deviceFingerprintMode:)` | per-request override read by `Otpless.processRequestIfRequestIsValid` | `@objc` |
| `getRequestId()` | **declared twice** — `@objc public func getRequestId() -> String` (non-optional, empty-string default) and an `internal` extension `func getRequestId() -> String?` (optional) | legal Swift overload-by-return-type; see §24 quirk |
| `getPhone()`, `getEmail()`, `getCountryCode()`, `getOtpLength()` | internal getters used by the intent/DI pipeline | not `@objc`; `getOtpLength()` maps `"4"/"6"` to `Int`, else `-1` |

`OtplessAuthCofig` (`public struct ... Sendable`): `isForeground: Bool`, `otp: String?`, `tid: String?` — passed to `startAuth` (§14).

### 6.3 `OtplessResponse` (`public struct`, `@unchecked Sendable`) — `dto/OtplessResponse.swift`

```swift
public struct OtplessResponse: @unchecked Sendable {
    public let responseType: ResponseTypes
    public let response: [String: Any]?   // payload — shape depends on responseType (§9)
    public let statusCode: Int
    public init(responseType: ResponseTypes, response: [String: Any]?, statusCode: Int)
    public func toString() -> String
}
```

Not `@objc` (Swift structs can't be) — Objective-C consumers only ever see this type's JSON-string projection (`toJsonString()`, internal) via `objcResponseDelegate`/`objcCommit` (§19). All factory helpers (`failedToInitializeResponse`, `sdkReady`, `createUnauthorizedResponse`, `createInactiveOAuthChannelError`, `create2FAEnabledError`, `createInvalidRequestError`, `createSuccessfulInitiateResponse`, `createUnsupportedIOSVersionResponse`, `makeTerminalResponse`, `snaTransactionFinalTimeout`, `createVerifyFailed`, `mfaFactorCompleted`) are `internal` — always add new response shapes there, not inline in a use case.

### 6.4 Enums & small public types

- `ResponseTypes: String` (§9.1): `INITIATE, VERIFY, ONETAP, FALLBACK_TRIGGERED, FAILED, SDK_READY, DELIVERY_STATUS, AUTH_TERMINATED, MFA_FACTOR_COMPLETED` (+ `API_RESPONSE`, `DEVICE_INTELLIGENCE` only under `#if OTPLESS_INTERNAL`).
- `DeviceFingerprintMode` (`@objc public enum`, Int-backed): `NONE(0), ASYNC(1), SYNC(2)`.
- `OtplessChannelType: String, CaseIterable` (public, **not** `@objc`) — 21 cases (`WHATSAPP`, `GOOGLE_SDK`, `FACEBOOK_SDK`, `APPLE_SDK`, `APPLE` (raw `"APPLE_EMAIL"`), `GMAIL`, `TWITTER`, `DISCORD`, `SLACK`, `FACEBOOK`, `LINKEDIN`, `MICROSOFT`, `LINE`, `LINEAR`, `NOTION`, `TWITCH`, `GITHUB`, `BITBUCKET`, `ATLASSIAN`, `GITLAB`, `TRUE_CALLER`) + `fromString(_:)` (case-insensitive, defaults to `.WHATSAPP`). `OtplessChannelTypeObjC` (`@objc public class`, static `String` constants) is the Objective-C-reachable mirror.
- `OtplessEnvironment` (`@objc public enum`, Int-backed): `PRODUCTION(0)`, plus `STAGING(1)` **only under `#if DEBUG`** — meaning the enum's case count and the `setEnvironment` setter both differ between debug and release builds of the *same* SDK version.
- `AuthEvent` (`@objc public enum`): `AUTH_INITIATED, AUTH_SUCCESS, AUTH_FAILED`; `ProviderType` (`@objc public enum`): `CLIENT, OTPLESS` — both for `userAuthEvent`.
- `SdkState: String` (public, not `@objc`): `READY, NOT_READY`.
- `OtplessResponseDelegate` (`@MainActor public protocol`, `NSObjectProtocol`): `func onResponse(_ response: OtplessResponse)`.
- `OtplessLoggerDelegate` (`@MainActor public protocol`, `NSObjectProtocol`): `func log(message: String, type: LogType)`.
- `LogType: String` (`public enum`, `@unchecked Sendable`) — the debug log-category enum (§16); `Comparable` via raw-string ordering.
- `RedirectResult` / `ConnectionResponse` (`public struct`s in `CellularConnectionManager.swift`) — **exposed as public but structurally unreachable**: the only type that produces or consumes them, `CellularConnectionManager`, is `internal`. This is dead public surface, not an intentional API (§24).

### 6.5 `OtplessSessionManager` — a separate public feature area (`session/`)

```swift
public actor OtplessSessionManager {
    public static let shared: OtplessSessionManager
    public func initialize(appId: String)
    public func getActiveSession() async -> OtplessSessionState
    public func logout() async
}
public enum OtplessSessionState: Equatable, Sendable { case active(String); case inactive }
```

This is a **JWT-based session-persistence/refresh mechanism** talking to `https://api.otpless.com/` (`v4/session/authenticate`, `v4/session/refresh`, `v4/session/{sessionToken}` DELETE) via its own `CoreHTTPClient`/`SessionServiceImpl`, with its own Keychain keys (`otpless_session_info`, `otpless_session_state`) and a self-scheduled 3-minute background re-authentication loop (`startAuthenticationLoopIfNotStarted`). **It is never referenced from `Otpless.swift` or from any use case in `usecase/`** — nothing in the authentication flows populates or reads an `OtplessSessionManager` session, and no README/CHANGELOG section documents it. It appears to be an independent, not-yet-integrated feature (introduced in the "MFA support" PR per `git log`) rather than part of the documented headless-auth contract; treat it as a distinct API surface when reasoning about "what can a merchant call," and confirm with the OTPLESS team before documenting it publicly.

---

## 7. Global SDK State (`Otpless` singleton fields)

| Field | Set by | Reset / cleared |
|---|---|---|
| `environment` | `setEnvironment()` (DEBUG only) | never (defaults `.PRODUCTION`) |
| `merchantAppId`, `merchantVC`, `merchantLoginUri` | `initialise()` | never (process); `merchantVC` also nulled by `cleanup()` |
| `uid` | `initialise()` (from Keychain) and `handleIntentResponse`/`VerifyCodeUseCase`/`PasskeyUseCase` callbacks (persisted) | overwritten only |
| `state` | `fetchStateAndMerchantConfig` → `requestStateForDeviceIfNil` | never reset within a session (a fresh `initialise()` recomputes it) |
| `merchantConfig` | `fetchMerchantConfig()` | never (until next `initialise()`) |
| `phoneIntentChannel`, `emailIntentChannel` | `fetchMerchantConfig()` | recomputed on every merchant-config fetch |
| `inid`, `tsid` | `initialise()` from `OtplessEventIO.trackingIds` | never |
| `appInfo`, `deviceInfo` | `initialise()` (async, `DeviceInfoUtils`) | never (process) |
| `token`, `asId` | `handleIntentResponse`/`SNAUseCase` result callbacks | `resetStates()` when a ONETAP is delivered |
| `communicationMode`, `authType` | `onCommunicationModeChange`/`onAuthTypeChange` — from intent/status/SNA responses | flushed to `"NA"`/`""` at every new intent request (`PostIntentUseCase.flushExistingAuthTypeAndDeliveryChannel`) |
| `merchantOtplessRequest` | `start(withRequest:)` / `authorizeViaPasskey` | nulled by `initialise()` and by `resetStates()` |
| `userSelectedOAuthChannel` | `start(withRequest:)` (`otplessRequest.getSelectedChannelType()`) | `resetStates()` |
| `hasMerchantSelectedExternalSDK` | `isChannelEnabled` (side effect of a config lookup, not a pure query — see §24) | `resetStates()` |
| `otpLength` | `start(withRequest:)` (explicit request value or merchant-config-derived) | never explicitly reset (defaults `-1`) |
| `isMfaEnabled` | `setMfaEnabled()` | never |
| `deviceFingerprintMode`, `diState`, `rsId`, `pendingOneTapResponse` | `setDeviceFingerprintMode`/request override; `triggerDeviceIntelligenceIfNeeded`; DI completion | cleared on DI completion delivery and/or ONETAP delivery (§13) |
| `drfID` | `IntelligenceUseCase` fetch callback | overwritten only |
| `isMobileDataEnabled` | `NWPathMonitor` update handler (`startMobileDataMonitoring`) | live-updated; never "reset" |
| `pendingCode` | `handleDeeplink()` when SDK isn't ready yet | cleared after `verifyCodeAndInvokeIfReady` runs (success or failure), and at the start of every `start(withRequest:)` |
| `sdkState` | `initialise()` (`.NOT_READY`) → `fetchMerchantConfig()` success (`.READY`) | reset to `.NOT_READY` by every `initialise()` call |
| `responseDelegate`, `objcResponseDelegate` | `setResponseDelegate`/`setOtplessObjcResponseDelegate` | `responseDelegate` nulled by `cleanup()`; `objcResponseDelegate` is **not** nulled by `cleanup()` |
| `loggerDelegate` | `setLoggerDelegate` | never |
| `eventCounter` | `getEventCounterAndIncrement()` (declared but see §24 — no caller found) | never |
| `initialisationTask`, `initContinuation` | `initialise()` | resolved/cancelled by the next `initialise()` call |
| `packageName` | `DeviceInfoUtils.getAppInfo()` (`setPackageName`) | never |
| `otpLength` (Otpless) vs `otpLength` (OtplessRequest) | see above | two separate fields with the same name on different types — do not confuse them |

---

## 8. End-to-End Flows

### 8.1 Initialization

`Otpless.shared.initialise(withAppId:loginUri:vc:)`:

1. Reset `merchantOtplessRequest = nil`, `sdkState = .NOT_READY`; store `merchantAppId`/`merchantVC`; reload `uid` from Keychain; compute `merchantLoginUri` (merchant-supplied or the `otpless.<appid-lowercase>://otpless` default); start the cellular `NWPathMonitor`.
2. `OtplessEventIO.initialize(appId:)`; pull `inid`/`tsid` from `OtplessEventIO.trackingIds`; emit `sdk_init_called`; `OtplessEventIO.retryFailedEvents()`.
3. Resolve any **prior** `initContinuation` with `false` under an `NSLock`, then cancel any prior `initialisationTask` — so a caller `await`-ing an earlier `initialise()` never hangs when init is re-issued mid-flight.
4. Start a new `initialisationTask` (medium-priority `Task`) that wraps a `CheckedContinuation`:
   - `await DeviceInfoUtils.shared.initialise()` (app-hash + WhatsApp-installed check, computed once and cached);
   - reload `uid` from Keychain again (defensive re-read);
   - build `deviceInfo` on `MainActor` and `appInfo` (async);
   - `OtplessBMEvents.Device.pushDeviceEvent()`;
   - `fetchStateAndMerchantConfig(onlyState: false)`:
     - `requestStateForDeviceIfNil`: Keychain hit (`stateFromCache` event) or `GetStateUseCase.invoke(isRetry:false)` (up to 2 attempts total — §24 parity note vs. Android's 3);
     - on a resolved `state`, persist to Keychain and call `fetchMerchantConfig()`: `GetMerchantConfigUseCase.invoke` (same 2-attempt budget) against `GET /v2/lp/merchant/config/{state}`;
     - success → store `merchantConfig`, resolve `phoneIntentChannel`/`emailIntentChannel`, set `sdkState = .READY`, emit `sdk_init_state_ready`, deliver `OtplessResponse.sdkReady` (`SDK_READY`, 200), resolve the init continuation `true`;
     - failure (either state or merchant-config fetch) → emit `sdk_init_state_failed`, deliver `OtplessResponse.failedToInitializeResponse` (`FAILED`, 5003), resolve the init continuation `false`;
   - if a deep-link `code` had been queued as `pendingCode` while the SDK wasn't ready, it is verified now (`verifyCodeAndInvokeIfReady`).

Any entry point that calls `start`/`startAuth`/`authorizeViaPasskey` first does `await initTask.value`; on `false` it immediately delivers `failedToInitializeResponse` and returns — **the merchant callback always fires**, unlike the "silent drop" behavior documented for the Android lite SDK when `start()` precedes `initialize()` (§9.4 parity row).

### 8.2 Phone-number intent flow

`request.set(phoneNumber:withCountryCode:)` → `await Otpless.shared.start(withRequest:)` → `processRequestIfRequestIsValid`:

1. Guard: `state` non-empty and `merchantConfig` non-nil, else `failedToInitializeResponse`.
2. Not an intent request (`otp` already set) → `verifyOtpUseCase.invoke(...)` (§8.2.1 below) and return.
3. Otherwise: adopt the request's `deviceFingerprintMode` if non-`.NONE`; call `triggerDeviceIntelligenceIfNeeded` (runs concurrently, does not block the intent call); `postIntentUseCase.invoke(state:withOtplessRequest:uiId:uid:)` → `handleIntentResponse`.

**`PostIntentUseCase.invoke` (the heart of `start`):**

1. Stop any in-flight `TransactionStatusUseCase`/`SNAUseCase` polling; flush `communicationMode`/`authType` to `"NA"`/`""`.
2. Build `PostIntentRequestBody` (§10.3) and `POST /v3/lp/user/transaction/intent/{state}`.
3. Branch on the response (`parseSuccessResponse`):

| Backend condition | Result |
|---|---|
| `pollingRequired == false` and `oneTap != nil` | Instant login: `otplessResponse` = **ONETAP** directly |
| `pollingRequired == false`, `channel == "DEVICE"` | No INITIATE emitted; `passkeyRequestStr` = the intent string, routed to `PasskeyUseCase` (§8.5) |
| `pollingRequired == false`, merchant selected an external SDK channel | No INITIATE emitted from here; `sdkAuthParams` built, routed to `prepareForSdkAuth` (§8.4) |
| `pollingRequired == false`, otherwise | INITIATE response, no polling (a verify call will complete it) |
| `pollingRequired == true`, `channel == "SILENT_AUTH"` | `communicationMode` force-set to `"SILENT_AUTH"` (no INITIATE derived from parse — mirrors Android's rationale of not firing a spurious FALLBACK_TRIGGERED); `isSNA = true`, `intent` = SNA partner URL |
| `pollingRequired == true`, merchant selected an external SDK channel | INITIATE response + `sdkAuthParams` |
| `pollingRequired == true`, `channel == "DEVICE"` | INITIATE response + `passkeyRequestStr` = intent |
| `pollingRequired == true`, otherwise | INITIATE response + `isPollingRequired = true` |
| API error | `INITIATE` response carrying the normalized error payload (`ApiError.getResponse()`) |

Note: **there is no 7005-style stale-state-refresh-and-retry path on iOS** — no error code triggers an automatic state refresh + request replay (§9.4 parity row).

**`Otpless.handleIntentResponse` (private, in `Otpless.swift`):**

- Deliver the initial `otplessResponse` (if any) via `invokeResponse`. If its `errorCode` is in `OtplessConstant.terminalErrorCodes` (`7160`, `7161`, `9106`), also deliver **AUTH_TERMINATED** and stop.
- Persist `token`/`asId`/`uid` from the returned `TokenAsIdUIdAndTimerSettings`.
- If a `passkeyRequestStr` is present: run `PasskeyUseCase.autherizePasskey`; on failure, recurse into `postIntentUseCase.invoke(..., webAuthnFallback: true)` and re-run `handleIntentResponse` on the new result.
- If `isSNA`: run `SNAUseCase.invoke`, deliver each returned response in order (stop immediately on ONETAP or a terminal error code); otherwise, if timer settings came back, start `TransactionStatusUseCase` polling with them, and return.
- If `sdkAuthParams` is present: `prepareForSdkAuth` (§8.4), and return.
- If a bare `intent` string is present (generic OAuth/backend-redirect channel): open it via `UIApplication.shared.open` (emits `sdk_deeplink_opened`).
- If `isPollingRequired`: start `TransactionStatusUseCase` polling with the returned timer settings.

**8.2.1 Verify (OTP set):** `VerifyOTPUseCase.invoke` → `POST /v3/lp/user/transaction/otp/{state}` with `appendTokenIds`-enriched query params → success → **ONETAP**; failure → **VERIFY** (error payload + `authType`).

**8.2.2 Transaction-status polling (`TransactionStatusUseCase`):** loop up to `timerSettings.timeout`/`.interval` (default 60 s / 3 s, matching Android's SDK-side fallback), sleeping between `GET /v3/lp/user/transaction/status/{state}` calls:
- `SUCCESS` → stop; deliver **ONETAP**.
- `FAILED` → deliver **AUTH_TERMINATED** (`makeTerminalResponse(status: 400, error: "9106", ...)`) and stop.
- `PENDING` → on first pending response record `communicationMode`; on a mode *change* deliver **FALLBACK_TRIGGERED**; once `communicationDelivered == true` deliver **DELIVERY_STATUS**, and if `channel == "OTP"` stop polling (the user is expected to type the OTP).
- Any 4xx/5xx `ApiError` also stops polling.

### 8.3 Email flow

Identical pipeline to §8.2 via `set(email:)` — `identifierType = "EMAIL"`, channel resolved from `emailIntentChannel` (merchant-config-driven) instead of `phoneIntentChannel`. `silentAuthEnabled` in the intent body is never true for email (its gate requires a mobile-shaped request — §10.3).

### 8.4 OAuth / native social sign-in channels

`request.set(channelType:)` (or `set(objcChannelType:)`) with `.GOOGLE_SDK`/`.FACEBOOK_SDK`/`.APPLE_SDK` sets `hasMerchantSelectedExternalSDK = true` during the config-driven `isChannelEnabled` check, which changes `PostIntentUseCase`'s branching (above) to produce `sdkAuthParams` instead of an intent URL. `Otpless.prepareForSdkAuth(withAuthParams:)`:

- `.GOOGLE_SDK`/`.GMAIL` → `manageGIDSignIn` → `GIDSignInUseCase.signIn` (real implementation only if `GoogleSignIn` is linked; else a stub reporting `"Google support not initialized"`) → `verifySdkAuthResponse`.
- `.FACEBOOK_SDK`/`.FACEBOOK` → `manageFBSignIn` → `FBSdkUseCase.startFBSignIn` (real implementation only if `FBSDKLoginKit` is linked) → `verifySdkAuthResponse`.
- `.APPLE_SDK`/`.APPLE` → `AppleSignInUseCase.performSignIn` (native `ASAuthorizationAppleIDProvider`, always available on-device, iOS 13+) → `verifySdkAuthResponse`.

`verifySdkAuthResponse` wraps the native SDK's result as `ssoSdkResponse` and calls `VerifyCodeUseCase.invoke` → `POST /v3/lp/user/transaction/code/{state}` → ONETAP/VERIFY.

Other OAuth-shaped channels (e.g. `WHATSAPP`, `TWITTER`, `GITHUB`, `LINKEDIN`, …) have no native SDK integration in this repo — they go through the generic `intent` deep-link-open + status-polling path in `handleIntentResponse` above (the backend URL presumably opens a web-based OAuth flow that eventually redirects back into `handleDeeplink`, §8.6).

### 8.5 WebAuthn / Passkey (`DEVICE` channel)

Triggered either by the backend choosing `channel == "DEVICE"` for an ordinary phone/email request (gated by `PostIntentUseCase.shouldTriggerWebAuthn`, which checks `PasskeyUseCase.isWebAuthnsupportedOnDevice()` — biometry/passcode availability, `LAContext.canEvaluatePolicy`, and iOS 15+) or explicitly via `authorizeViaPasskey(withRequest:windowScene:)` / `set(requestIdForWebAuthn:)`. `PasskeyUseCase.autherizePasskey(request:)`:

1. Parses the backend `data`/`isRegistration` payload.
2. Registration → builds `ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest` (rp id, challenge, attestation/user-verification preference, excluded credentials on iOS 17.4+); Sign-in → builds the matching assertion request (allowed credentials, user-verification preference).
3. Presents `ASAuthorizationController` via `PasskeyASAuthorizationView` (a `@MainActor` delegate object) and awaits the credential.
4. Submits the resulting attestation/assertion JSON to `POST /v3/lp/user/transaction/code/{state}` (`channel=DEVICE`) via `VerifyCodeUseCase.submitWebAuthnData`.
5. On any failure at any step, `handleIntentResponse` retries the whole intent with `webAuthnFallback: true` (which flips `PostIntentRequestBody.triggerWebauthn` to `false`, letting the backend fall back to a non-passkey channel).

### 8.6 SSO / deep-link code verify

Merchant forwards incoming URLs to `Otpless.shared.isOtplessDeeplink(url:)` / `handleDeeplink(_:)` from `application(_:open:options:)`. `handleDeeplink` requires `url.host == "otpless"`, extracts the `code` query parameter, and either verifies immediately (`sdkState == .READY`) or queues it as `pendingCode` (processed once `fetchMerchantConfig()` succeeds). `verifyCodeAndInvokeIfReady` → `VerifyCodeUseCase.invoke` → `POST /v3/lp/user/transaction/code/{state}` → ONETAP/VERIFY; a returned `uid` is persisted to Keychain.

### 8.7 Silent Network Auth (channel == `SILENT_AUTH`)

See §12.

### 8.8 MFA (multi-factor)

`Otpless.shared.setMfaEnabled(true)` changes two things everywhere the SDK talks to the backend: (a) `ApiManager.getBody` **omits** `uid` from the POST-body enrichment (`if !isMfaEnabled { mutableBody["uid"] = ... }`), and `PostIntentUseCase.getPostIntentRequestBody` likewise nils out the explicit `uid` parameter; (b) `SNAUseCase` (and its fallback path) calls `mfaSnaStatus` (`POST /v3/lp/user/transaction/mfa-sna-status/{state}`) instead of `getSNATransactionStatus` (`GET .../silent-auth-status/{state}`). A `SUCCESS` status that carries a `quantumLeap` (rather than a terminal `oneTap`) is translated by `makeSnaUseCaseResponse` into **`MFA_FACTOR_COMPLETED`** followed by a synthesized **INITIATE** describing the next factor — the merchant is expected to call `start` again for that factor.

### 8.9 OneTap bottom-sheet auth

See §14.

### 8.10 Cleanup

`Otpless.shared.cleanup()` cancels the cellular `NWPathMonitor` and nils `merchantVC`/`responseDelegate` (not `objcResponseDelegate` — §24). It does **not** cancel `initialisationTask`, any in-flight `TransactionStatusUseCase`/`SNAUseCase` polling loop, or the `apiRepository`'s underlying `URLSession` tasks — there is no equivalent of Android's `serviceScope.cancel()` that tears down every in-flight coroutine on cleanup.

---

## 9. Response Semantics & Error Codes

### 9.1 `ResponseTypes` and their payloads

| Type | When | `response` payload shape |
|---|---|---|
| `SDK_READY` | Init succeeded | `{success: true, tsId}` (200) |
| `FAILED` | Init failed (state or merchant-config fetch) | `{errorCode: "5003", errorMessage}` (5003) |
| `INITIATE` | Transaction started (or failed to start) | success: `{requestId, channel, authType, deliveryChannel?, otpLength?}` (200); failure: error JSON with `errorCode`/`errorMessage` (+`details`/`snaError` depending on factory) |
| `DELIVERY_STATUS` | Message delivery confirmed while polling | `{deliveryChannel, authType, communicationDelivered: true}` (200) |
| `FALLBACK_TRIGGERED` | Delivery channel switched mid-poll | `{requestId, deliveryChannel, channel, authType}` (200) |
| `VERIFY` | OTP/code/SNA verification failed (only emitted on failure paths) | error JSON + `authType`; SNA failures add a `snaError` object; `9106` = SNA transaction timeout |
| `ONETAP` | **Terminal success** | `{firebaseInfo?, data, sessionInfo?, status, token}` where `data` is `MerchantUserInfo.toDict()` — always wrapped (no unwrapped/legacy variant, §9.4) |
| `AUTH_TERMINATED` | **Terminal failure** — all channels exhausted, or an init/auth terminal error code was seen | `{errorCode, errorMessage, snaError?}` |
| `MFA_FACTOR_COMPLETED` | MFA: one factor done, another `quantumLeap` factor follows | `{authType?, communicationChannel?}` (200), followed by a synthesized INITIATE for the next factor |
| `API_RESPONSE` / `DEVICE_INTELLIGENCE` | `#if OTPLESS_INTERNAL` only — raw API/DI diagnostic events | not present in merchant (non-internal) builds |

There is **no `OTP_AUTO_READ` response type** — see §9.4.

### 9.2 Error code catalog

| Code | Origin (file) | Meaning | Ever invoked? |
|---|---|---|---|
| `400` | `TransactionStatusUseCase`/`SNAUseCase` verify-failed paths | Silent Authentication / OTP verification failed | Yes |
| `401` | `OtplessResponse.createUnauthorizedResponse` | Bad appId | Factory defined; no call site found in current source |
| `4000` | `createInvalidRequestError` | Invalid request fields (phone/email validation) | Factory defined; no call site found in current source |
| `4001` | `create2FAEnabledError` | 2FA not supported by headless SDK | Factory defined; no call site found in current source |
| `4003` | `createInactiveOAuthChannelError` | Requested channel disabled on dashboard | Factory defined; no call site found in current source |
| `5003` | `failedToInitializeResponse` | SDK could not initialize (state or merchant-config fetch failed) | Yes (§8.1) |
| `5800` | `ApiRepository.makeSNACall` | SNA cellular-manager unavailable, or the partner URL failed to parse | Yes |
| `5900` | `createUnsupportedIOSVersionResponse` | A feature needs a higher iOS version than the device runs | Factory defined; no call site found in current source |
| `7160` | `OtplessConstant.EC.SNA_AUTH_INIT_FAILED` | SNA init failed — **terminal** | Yes (checked in `handleIntentResponse`) |
| `7161` | `EC.SNA_AUTH_FAILED` | SNA auth failed — **terminal** | Yes |
| `9100`–`9105` | `ApiManager.handleURLError` (`URLError` code mapping: timeout, connection lost, DNS failure, cannot connect, no internet, TLS failure) | Transport-level failures | Yes |
| `9106` | `EC.ALL_CHANNEL_AUTH_FAILED` / `snaTransactionFinalTimeout` | All channels failed, or SNA/status-poll transaction timeout — **terminal** | Yes |
| `9110` | `ApiManager.handleURLError` (`.cancelled`) | Request cancelled (e.g. superseded by a `URLSession` task cancellation) | Yes — filtered from delivery (§9.3) |
| HTTP status codes | `ApiManager.performUserAuthRequest` (non-2xx) | Passed through as `errorCode` when the body doesn't carry one | Yes |
| `500` | generic catch-all (`ApiManager`, `PostIntentUseCase.parseFailureResponse`, `VerifyOTPUseCase`, `VerifyCodeUseCase`) | Unclassified/unexpected error | Yes |

Terminal set: `OtplessConstant.terminalErrorCodes = ["7160", "7161", "9106"]` — identical numeric registry to the Android lite SDK (a genuine parity match, §9.4).

**Note:** unlike Android, there is no `7005`-style "stale state → refresh and retry once" error code handled anywhere in the iOS intent/verify pipeline.

### 9.3 Response delivery & filtering rules (`Otpless.invokeResponse`, in `OtplessExtensions.swift`)

Every emission passes through `invokeResponse(_:)`:

1. Always calls `dismissOneTapBottomSheet()` first (§14) and logs via `RESPONSE_RELAY`.
2. `statusCode == 9110` → drop, emit `sdk_response_not_delivered` (reason `status_code_suppressed`), return.
3. `responseType == .ONETAP` → `Otpless.shared.resetStates()`, stop status polling (`dueToSuccessfulVerification: true`), then branch on the **captured** `deviceFingerprintMode` at the moment of delivery:
   - `.SYNC` and DI not yet `.completed` → hold as `pendingOneTapResponse` (delivered later by the DI-completion handler, §13);
   - `.SYNC` and DI already `.completed`, or mode is `.ASYNC`/`.NONE` → clear `rsId`/`diState`/`deviceFingerprintMode`, emit `sdk_response_onetap` telemetry, deliver on the main queue to both `responseDelegate` and `objcResponseDelegate`.
   - Return either way — no further checks apply to ONETAP.
4. `9100 <= statusCode <= 9105` → additionally emit `sdk_response_not_delivered` (reason `timeout`) — **but the response is still delivered afterward** (this is a telemetry-only branch, not a drop; contrast with Android, where `9100`–`9106` responses are not specially double-tracked in this way at all).
5. Otherwise: emit `sdk_response_<type>` telemetry (lower-cased type name) and deliver on the main queue to both delegates.

There is **no legacy-response-mode suppression rule** and **no explicit "callback not initialized" drop-with-telemetry rule** — see §9.4.

### 9.4 Parity with the Android lite SDK — verified divergences

The response contract (payload shapes, error codes, response types) is meant to be shared across platforms off the same backend. The following are concrete, code-verified differences found while cross-referencing this SDK against `otpless-headless-android-lite`'s `docs/SDK-GUIDE.md` (§9, §11, §12, §13) and its contract fixtures (`LongClaw/src/test/resources/contract/*.json`):

| Aspect | Android (lite) | iOS (`OtplessBM`) |
|---|---|---|
| SMS/WhatsApp OTP auto-read | Full subsystem (§13 of the Android guide): `AutoReadSDK` integration, a dedicated `OTP_AUTO_READ` response type, and `startInBackground` for silent auto-verify. | **Does not exist at all.** `ResponseTypes` has no `OTP_AUTO_READ` case; there is no `startInBackground`, no SMS-retriever integration, no auto-read subsystem anywhere in `Sources/`. |
| ONETAP payload shape | Two shapes selectable by the merchant: default `{data: {...}}`, or **legacy** unwrapped `{...}` via `setLegacyResponseMode(true)`. Payload otherwise contains only what's under `data`/unwrapped — no extra top-level keys. | **One shape only**, always wrapped: `{firebaseInfo?, data, sessionInfo?, status, token}`. No `setLegacyResponseMode` equivalent exists; the `data` wrapper can never be removed, and two extra top-level keys (`status`, `token`) are always present outside `data`. |
| `Identity` payload fields | Declares `whatsAppType`, `isAutoRead`, `smsOriginatingSource`, `simSubscriptionId` (SIM/auto-read provenance) — confirmed present in the shared contract fixtures (`onetap_nonlegacy.json`, `onetap_source.json`). | `Identity` (in `TransactionStatusResponse.swift`) does **not** declare any of those four fields — if the shared backend sends them, `Codable` decoding silently drops them; an iOS merchant never sees `isAutoRead`/`smsOriginatingSource`/`simSubscriptionId`/`whatsAppType` on an identity. Conversely, iOS's `Identity` declares `type`, `providerMetadata`, `picture`, `isCompanyEmail`, which Android's `Identity` DTO does not. `isSimBound` is present on **both** platforms (a genuine parity match, not a gap). |
| SNA IP-family targeting | `QuantumLeap.ipHint` (`"IPV4"`/`"IPV6"`) + `DnsPolicyFilter`/`SnaRepository.selectPolicy` steer the SNA call over the carrier-preferred address family. | `QuantumLeap` (iOS) has no `ipHint` field; `CellularConnectionManager` has no IP-family selection logic — the SNA connection always uses whatever address family `NWConnection`/the OS resolves first on the cellular path. |
| Merchant-configurable API base URL | `initialise(..., config: [OtplessConfigKey.ApiBaseUrl: "..."])` — arbitrary URL override. | Binary `OtplessEnvironment` toggle only (`PRODUCTION` / DEBUG-only `STAGING`), no arbitrary URL override, and the toggle itself is compiled out of release builds. |
| Merchant-configurable API timeout | Public `OtplessSDK.setExtras(userAuthApiTimeout:)`. | No public setter; `userAuthTimeout: 30`, `snaTimeout: 5` are hardcoded at `Otpless.apiRepository`'s construction. |
| Init state-fetch retry budget | `InitUseCase`: up to `INIT_FAILURE_LIMIT = 3` attempts at `GET /v2/state`. | `GetStateUseCase`/`GetMerchantConfigUseCase`: 2 attempts each (`retryCount == 1` triggers the final failure). |
| Stale-state auto-retry (error code 7005) | Backend can signal a stale `state`; the SDK refreshes it and replays the request once. | No such mechanic exists anywhere in the iOS intent/verify pipeline. |
| `start()` before init completes | Silent: only a `sdk_init_not_called` telemetry event fires; **the merchant callback receives nothing at all**. | Always suspends on the outstanding init `Task`, then **always** delivers `failedToInitializeResponse` (5003) to the merchant callback on failure. |
| Merchant/channel-config readiness gate | SDK readiness depends only on the `state` token (§8.1 of the Android guide); no separate channel/UI-config fetch blocks `SDK_READY`. | Readiness additionally requires a successful `GET /v2/lp/merchant/config/{state}` (channel config, MFA flag, UI config, device-intelligence type) before `sdkState` becomes `.READY`. |
| "Callback not initialized" drop | Explicit rule in `invokeResponse`, tagged with telemetry reason `callback_not_initialized`. | The matching constant (`OtplessBMEvents.Response.REASON_CALLBACK_NOT_SET`) is defined but **never referenced** — if no delegate is set, delivery just no-ops silently via optional chaining, with no telemetry marking the drop. |
| Native "OneTap" identity-picker UI | Not present — the Android lite SDK is UI-free. | A native bottom-sheet UI (`OneTapView`/`OneTapBottomSheetViewController`, §14) exists and can be presented via `startAuth(parent:config:)`. |
| Passkey / WebAuthn (`DEVICE` channel) | The Android lite guide describes `channel == "DEVICE"` only as "no INITIATE emitted" — no further passkey implementation is documented for the lite variant. | Full native implementation: `PasskeyUseCase` builds real `ASAuthorizationPlatformPublicKeyCredential(Registration\|Assertion)Request`s and submits the result through the code-verify endpoint (§8.5). |
| Terminal error-code registry | `[7160, 7161, 9106]`. | `[7160, 7161, 9106]` — **identical** (confirmed parity, not a gap). |

Because android-full (the other Android sibling) supports more channels than lite, some of the "Android lacks this" rows above may not hold against android-full — this table is scoped to what the lite SDK-GUIDE documents, per the parity task's request; a full three-way comparison should re-check against android-full's own guide once it exists.

---

## 10. Networking Layer

### 10.1 Endpoints (`ApiManager` path constants, all under the user-auth host)

| Constant | HTTP | Path | Used by |
|---|---|---|---|
| `GET_STATE_PATH` | GET | `/v2/state` | `GetStateUseCase` |
| `GET_MERCHANT_CONFIG_PATH` | GET | `/v2/lp/merchant/config/{state}` | `GetMerchantConfigUseCase` |
| `POST_INTENT_PATH` | POST | `/v3/lp/user/transaction/intent/{state}` | `PostIntentUseCase` |
| `SSO_VERIFY_CODE_PATH` | POST | `/v3/lp/user/transaction/code/{state}` | `VerifyCodeUseCase` (SSO code, WebAuthn data) |
| `TRANSACTION_STATUS_PATH` | GET | `/v3/lp/user/transaction/status/{state}` | `TransactionStatusUseCase` |
| `SNA_TRANSACTION_STATUS_PATH` | GET | `/v3/lp/user/transaction/silent-auth-status/{state}` | `SNAUseCase` (non-MFA) |
| `MFA_SNA_STATUS_PATH` | POST | `/v3/lp/user/transaction/mfa-sna-status/{state}` | `SNAUseCase` (MFA) |
| `OTP_VERIFICATION_PATH` | POST | `/v3/lp/user/transaction/otp/{state}` | `VerifyOTPUseCase` |
| *(dynamic — server-generated)* | GET (raw HTTP/1.1 over `NWConnection`) | the `quantumLeap.intent` URL | `ApiRepository.makeSNACall` / `CellularConnectionManager` |

Base URL: `Otpless.shared.environment.userAuthBaseURL` — `https://user-auth.otpless.app` (`.PRODUCTION`) or `https://user-auth.otpless.tech` (`.STAGING`, DEBUG builds only). A separate, unused constant `ApiManager.baseURLSekura = "http://80.in.safr.sekuramobile.com"` is declared but never referenced (§24) — the real SNA URL always comes from the backend's `quantumLeap.intent` field and is used verbatim by `CellularConnectionManager`.

Timeouts: `Otpless.apiRepository` is constructed with `userAuthApiTimeout: 30`, `snaTimeout: 5` (seconds) — the latter is only an initial default; `SNAUseCase.invoke` immediately overrides it per-attempt via `updateSNAConnectionTimeout` using the server's `timerSettings.timeout` (converted ms→s), falling back to `7.0` if absent.

### 10.2 Request enrichment (`ApiManager`)

**Every** user-auth request — GET or POST — has identity/context fields appended centrally, mirroring the Android interceptor pattern but implemented as plain helper methods rather than an OkHttp interceptor chain:

- **GET** (`constructURL`): query items `origin=https://otpless.com`, `tsId`, `inId`, `version=V4`, `isHeadless=true`, `platform=iOS`, `isLoginPage=false`, `packageName`, `package`, `loginUri`, `appId`, `deviceInfo` (JSON-string-encoded), plus `uid?`/`asId?`/`token?`/`rsId?` when non-empty. Merchant-supplied `queryParameters` are appended *before* these, so the enrichment values always win on key collision (`urlComponents.queryItems` is overwritten then appended-to).
- **POST** (`getBody`, only when `shouldAppendBasicParameters` is true — the default for every real call site): `origin`, `version=V4`, `tsId`, `inId`, `deviceInfo` (JSON string), `loginUri`, `appId`, `isHeadless=true`, `packageName`, `package`, `platform=HEADLESS`, `uid` (**omitted** when `isMfaEnabled`), `metadata` (JSON string of `{appInfo, deviceInfo}` — this **overwrites** whatever `metadata` key the caller's body already had, e.g. `PostIntentRequestBody`'s own malformed one, §24), `rsId?` when non-empty.
- `HTTPURLResponse`'s `x-request-id` header (case-insensitive match) is captured and threaded into the `api_*` telemetry event as `requestId`.
- Debug-only full request/response logging (`logRequestAndResponse`) when `enableLogging` is true (it always is — `Otpless.apiRepository` is constructed with `enableLogging: true` unconditionally); actual `print`/delegate output is still gated by `#if DEBUG` inside `log()`.

### 10.3 `postIntent` body (`PostIntentUseCase.getPostIntentRequestBody` → `PostIntentRequestBody`)

| Field | Source |
|---|---|
| `channel` | resolved from `OtplessRequest.getDictForIntent()`, remapped by `alterChannelIfRequired` (`GOOGLE_SDK→GMAIL`, `FACEBOOK_SDK→FACEBOOK`, `APPLE_SDK→APPLE_EMAIL`) |
| `email` / `mobile` / `selectedCountryCode` / `identifierType` / `type` / `value` | from the same dictionary, keyed by `authenticationMedium` |
| `hasWhatsapp` | `Otpless.shared.appInfo["hasWhatsapp"]` |
| `silentAuthEnabled` | `merchantConfig.merchant.config.isSilentAuthEnabled == true` **AND** (one-tap mobile item, or a plain non-custom phone request, or a backend-generated request) **AND** `isMobileDataEnabled` |
| `triggerWebauthn` | `PasskeyUseCase.isWebAuthnsupportedOnDevice()` (iOS 15+ only; else `false`) |
| `uid` | `Otpless.shared.uid`, forced `nil` when `isMfaEnabled` |
| `expiry` / `deliveryMethod` / `otpLength` | from `OtplessRequest`'s custom-request setters |
| `uiIds` | `[onetapItemData.uiid]` for the OneTap-UI flow (§14); otherwise `Otpless.shared.uiId`, which is **never assigned** outside that flow and is therefore always `nil` on the ordinary path (§24) |
| `fireIntent` | `true` when the resolved `value` field is empty |
| `requestId` | from `getDictForIntent()` (WebAuthn/backend-generated requests) |
| `clientMetaData` | JSON string of `{tid?, ...extras}` |
| `asId` | `Otpless.shared.asId` |
| `isViSnaWhitelisted`, `isAirtelSnaWhitelisted` | always `true` (stored properties with default values, not settable) |
| `metadata` | set in `PostIntentRequestBody.init` via **Swift string interpolation of the raw dictionaries** (not valid JSON) — harmless in practice because `ApiManager.getBody` unconditionally overwrites the `metadata` key with a correctly JSON-encoded value before the request is sent (§24 quirk) |
| *(+ everything from the POST enrichment in §10.2)* | |

### 10.4 Error normalization

`ApiManager.performUserAuthRequest` throws `ApiError { message, statusCode, responseJson }` for both HTTP-level failures (non-2xx → parses the error body's `message`/`errorCode`) and `URLError`s (mapped by `handleURLError` to the `9100`–`9105`/`9110` codes, §9.2). Every `ApiRepository` method catches this and returns `Result<T, Error>.failure`; use cases then call `ApiError.getResponse()` to get the merchant-facing `{errorCode, errorMessage, snaError?}` dictionary, or fall back to a generic `{errorCode: "500", ...}` shape for non-`ApiError` failures (e.g. `JSONDecoder` throw from a malformed 2xx body — there is no explicit content-type gate on iOS the way Android's `parseResponse()` has one; a non-JSON 2xx body simply fails to decode and surfaces as a generic decode error inside the `catch`).

---

## 11. Network Data Models

All in `network/model/`, `Codable`, package-`internal` unless noted, decoded via `JSONDecoder`/encoded via `JSONEncoder` (no Gson-style annotation layer — Swift's `Codable` + `CodingKeys` is the only serialization mechanism used).

```text
StateResponse           { state: String? }

MerchantConfigResponse  { authType?, channelConfig: [ChannelConfig]?, isMFAEnabled?, merchant?, uiConfig?, userDetails?, metaData? }
ChannelConfig           { channel: [Channel]?, identifierType?, mandatory?, verified? }
Channel                 { communicationMode?, logo?, name?, otpLength?, type? }
MetaData                { deviceIntelligence: DeviceIntelligence? }     # DeviceIntelligence { type?: "SYNC"|"ASYNC" }
UserDetails             { email: [Email]?, mobile: [Mobile]? }          # each carries a uiId for the OneTap UI (§14)

IntentResponse          { quantumLeap: QuantumLeap, oneTap: OneTap? }
QuantumLeap             { asId, channel, channelAuthToken, channels: [String], intent?, pollingRequired: Bool,
                          state, status, timerSettings: TimerSettings, uid?, communicationMode? }   # no ipHint (§9.4)
TimerSettings           { interval: Int64?, timeout: Int64? }           # milliseconds

TransactionStatusResponse { authDetail: AuthDetail, config: Config?, oneTap: OneTap?, otpVerificationDetail: OtpVerificationDetail?, quantumLeap: QuantumLeap? }
AuthDetail              { asId?, channel?, communicationDelivered: Bool, isCrossDevice?, status,
                          token?, uiId?, user: User?, webauthnRegistered?, communicationMode?,
                          errorDetails?, snaError: SNAError? }           # isCrossDevice/uiId/webauthnRegistered/errorDetails are decoded but never read in current source
User                    { email?, mobile?, name?, uid }
SNAError                { errorCode, message?, description? }

OneTap                  { firebaseInfo: FirebaseInfo?, merchantUserInfo: MerchantUserInfo?, sessionInfo: SessionInfo?, status, token }
                        # toDict(): ALWAYS {firebaseInfo?, data: merchantUserInfo, sessionInfo?, status, token} — no unwrapped mode (§9.4)
MerchantUserInfo        { deviceInfo: DeviceInfo?, idToken?, identities: [Identity], network: Network?, status?, timestamp, token, userId? }
Identity                { channel, identityType?, identityValue?, methods?, verified: Bool, verifiedAt: String,
                          type?, providerMetadata: [String: CodableValue]?, picture?, isCompanyEmail?, isSimBound? }
                        # no isAutoRead/smsOriginatingSource/simSubscriptionId/whatsAppType (§9.4)
CodableValue            enum { string/int/double/bool/dictionary/array } — generic JSON-value box for providerMetadata
FirebaseInfo            { firebaseToken? }
SessionInfo             { refreshToken?, sessionId?, sessionToken?, sessionTokenJWT? }
DeviceInfo (nested)     { browser?, connection?, cookieEnabled?, cpuArchitecture?, devicePixelRatio?, fontFamily?,
                          language?, platform?, screenColorDepth?, screenHeight?, screenWidth?, timezoneOffset?, userAgent?, vendor? }
Network (nested)        { ip?, ipLocation: IpLocation?, timezone? }     # IpLocation → City/Continent/Country/Subdivisions

IntelligenceApiResponse { dfrId? }    # decoded type exists but device-intelligence results are actually read via
                                       # NSDictionary/Objective-C runtime in IntelligenceUseCase, not via this struct (§13)

PostIntentRequestBody   (request DTO, §10.3) — Codable, encoded via DictionaryConvertible.toDict()
```

`DictionaryConvertible` (in `utils/Utils.swift`) is the shared `Codable & Sendable` protocol every request/response DTO with a `toDict()` conformance uses to round-trip through `JSONEncoder` → `JSONSerialization` into a `[String: Any]` for the merchant-facing payload — the Swift analogue of Android's Gson-to-`JSONObject` bridging (`Utility.toJson`).

`TokenAsIdUIdAndTimerSettings` (`dto/`) is the internal 4-tuple `{token?, asId?, uid?, timerSettings?}`, identical in purpose to the Android type of the same name.

---

## 12. Silent Network Auth (SNA) Deep Dive

SNA verifies phone ownership without any message: the device makes an HTTP GET to a carrier URL **over the cellular interface**, and the carrier identifies the SIM from the traffic.

### 12.1 `CellularConnectionManager` (`network/cellular/`)

A **raw-socket** implementation (`Network.framework`'s `NWConnection`), not `URLSession` — because `URLSession` doesn't expose a way to force a specific interface family the way `NWParameters` does:

1. `NWParameters` is built with `requiredInterfaceType = .cellular` and `prohibitedInterfaceTypes = [.wifi, .loopback, .wiredEthernet]` — this is the actual "force cellular" mechanism (no process-wide network-binding call is involved, unlike Android's `bindProcessToNetwork`; the restriction is scoped to this one `NWConnection`, not the whole process).
2. A hand-built HTTP/1.1 request line + headers is written directly to the socket (`createHttpCommand`) — this SDK implements a **minimal HTTP client by hand** for the SNA leg rather than reusing `URLSession`, presumably because `URLSession` doesn't allow this per-connection interface pinning.
3. A `Timer`-based 7-second connection timeout (`CONNECTION_TIME_OUT`, mutable via `updateConnectionTimeout`) mitigates the case where TCP-level timeout events don't fire promptly.
4. Redirects (301–303, 307–308) are followed manually up to whatever depth the caller's `checkResponseHandler` recursion allows (no explicit max-redirect guard was found); 200–202/204 map to success, 400–451/500–511 map to a data-carrying error (`dataErr`), anything else maps to a generic `NetworkError.other`.
5. Response body extraction (`getResponseBody`) hand-parses the raw HTTP response text for a JSON `Content-Type` header and a matching `{...}` span — a very literal, non-RFC-complete parser (works for the specific SNA partner responses it was built against, but is not a general HTTP client).
6. `NWPathMonitor` runs alongside purely for debug logging of the current interface type — it plays no role in the actual connection logic.

### 12.2 `ApiRepository.makeSNACall`

Thin wrapper: validates the URL, delegates to `CellularConnectionManager.open(url:operators:completion:)`, and normalizes failures to a `{errorCode: "5800", ...}` dictionary if the manager or URL is unusable. There is **no DNS-policy / IPv4-vs-IPv6 selection layer** — no analogue of Android's `DnsPolicyFilter`/`ipHint` (§9.4).

### 12.3 `SNAUseCase` — the race

```text
async snaApiCall  = ApiRepository.makeSNACall(url) { ... }        # over forced cellular
async pollJob     = pollSNATransaction(timerSettings)              # default: every 200 ms, up to 7 s (or server-provided)

let (_, transactionResponse) = await (snaApiCall, pollJob)
return transactionResponse
```

Unlike Android's explicit `select {}` cancel-the-loser race, iOS's `SNAUseCase.invoke` runs both `async let`s to completion and takes the **poll job's** result unconditionally — the SNA call's own outcome only feeds into a shared `snaUrlHitError` used by `pollSNATransaction`'s *fallback* path (see below), and calling `stopPolling()` from inside the SNA callback merely flips the poll loop's `isPolling` flag so its **next** iteration exits early; it does not cancel an in-flight status-check request.

- Polling endpoint: `getSNATransactionStatus` (or `mfaSnaStatus` when `isMfaEnabled`). Loop exits on `SUCCESS`/`FAILED`; ignores `PENDING`/unknown until `startTime > endTime`, then falls through to `performFallbackTransactionRequest`.
- `performFallbackTransactionRequest` — one last status call carrying whatever `snaUrlHitError` was captured (`{lapseMeta: "{cause, brief}"}` JSON string) or a generic `sdk_polling_timeout` cause if the SNA callback never fired an error; on that call's own failure, falls back to `OtplessResponse.snaTransactionFinalTimeout` (9106).
- Result mapping lives in `utils/ConvertUtils.swift → makeSnaUseCaseResponse`:

| Status | quantumLeap | oneTap | Emitted responses |
|---|---|---|---|
| SUCCESS | present | — | `MFA_FACTOR_COMPLETED` + `INITIATE` (next factor, from quantumLeap) |
| SUCCESS | null | present | `ONETAP` |
| SUCCESS | null | null | `VERIFY` failed (9106, "Silent Authentication failed.") — logged via `OtplessBMEvents.Exception.captured` as an unexpected state |
| FAILED | null | — | `VERIFY` failed (with `snaError`) + **terminal** (`AUTH_TERMINATED`, errorCode `7161`) |
| FAILED | present | — | `VERIFY` failed + `INITIATE` (fallback channel transaction) |

Note the iOS `lapseMeta` shape sent on the final status call is the **legacy** `{cause, brief}` string form only — there is no v2 stage/kind envelope (`SnaLapseReport`/`SnaFailureClassifier`) like the one documented for Android's `docs/sna-lapsemeta-contract.md`. If that backend contract is meant to be shared across platforms, iOS is currently on the older shape.

---

## 13. Device Intelligence / Fingerprinting

Optional integration with the OTPLESS iOS intelligence SDK (class name `OTPlessIntelligence.OTPlessIntelligence`) — **not a compile dependency**; discovered purely via `NSClassFromString` + Objective-C runtime selector dispatch in `IntelligenceUseCase`, exactly mirroring the Android reflection-contract pattern (§21). Comment header in `IntelligenceUseCase.swift` documents the contract explicitly: merchants must add the `OTPlessIntelligence` pod/SPM package themselves and call `OTPlessIntelligence.shared.initialize(appId:)` from their own app startup code *before* any DI-enabled OtplessBM request; if that never happened, the intelligence SDK's own guard reports failure and `fetchIntelligence`'s completion resolves to `nil` — the transaction proceeds without DI, never blocking or failing the auth flow.

Activation: `setDeviceFingerprintMode(_:)` or a per-request `OtplessRequest.set(deviceFingerprintMode:)` with `.ASYNC`/`.SYNC`. On each intent-type request, `Otpless.triggerDeviceIntelligenceIfNeeded(state:src:)`:

1. Skip if mode is `.NONE` or a DI job is already `.inProgress`.
2. Generate `rsId = "<UUID>-<uptimeNanoseconds>-<state>"`, set `diState = .inProgress`.
3. Below iOS 15 → immediately mark the job `.completed` (feature is unavailable pre-15; degrades gracefully).
4. iOS 15+: call `IntelligenceUseCase.fetchIntelligence(params: {rsId, state}, updateInfo: {merchantId, phoneNumber, phoneInputType: "MANUAL", userEventType: "LOGIN"}, completion:)`, which:
   - Resolves the intelligence SDK's `shared` instance and its `fetchIntelligenceWithParams:updateInfo:completion:` selector via `class_getMethodImplementation` + an `unsafeBitCast` to a typed C function pointer (Swift's `NSObject.perform` variants only support up to 2 arguments, insufficient for this 3-argument selector);
   - On success, stores the returned `dfrId` in `Otpless.shared.drfID` and emits `device_intelligence_fetch_success`; on failure/absence, emits `device_intelligence_fetch_failure` (or logs "not linked" via `os_log` if the class can't be found at all).
5. `onDeviceIntelligenceComplete()`: marks `diState = .completed`; if a `pendingOneTapResponse` was held back by `invokeResponse`'s `.SYNC` gate (§9.3 rule 3), delivers it now and clears `rsId`/`diState`/`deviceFingerprintMode`.

Delivery interaction (§9.3): only `.SYNC` mode can delay a ONETAP; `.ASYNC` fingerprinting runs fully in the background and never blocks or holds a response.

`#if OTPLESS_INTERNAL`-gated `dispatchDIEvent` also emits `DEVICE_INTELLIGENCE`-typed diagnostic `OtplessResponse`s through the normal delegate path — not present in merchant builds.

---

## 14. OneTap Bottom-Sheet UI

Unlike a strictly headless SDK, `OtplessBM` ships a small **native UI component** — an unusual inclusion worth calling out explicitly (§24): `views/OneTapView.swift` defines `OneTapView` (a `UITableView`-backed list), `OneTapCell`, `LogoRingView` (an animated loading ring around an avatar image), and `OneTapBottomSheetViewController` (an iOS 15+ `UISheetPresentationController`-based bottom sheet with custom detents).

Entry point: `Otpless.shared.startAuth(parent vc: UIViewController, config authConfig: OtplessAuthCofig) async -> Bool`:

1. Requires iOS 15+ (returns `false` otherwise).
2. Builds `OnetapItemData` from `merchantConfig.userDetails.mobile`/`.email` (each carrying a backend `uiId`, a display name/logo, and an `identity` string).
3. If nothing to suggest → `false`.
4. `authConfig.isForeground == true` → presents the bottom sheet (`presentOneTapBottomSheet`) letting the user tap one identity, which calls `startOnetapAuth`.
5. `authConfig.isForeground == false` and exactly one identity is available → auto-starts that one identity directly (no UI shown) via `startOnetapAuth`.
6. Otherwise (background + multiple candidates) → `false` (nothing safe to auto-pick).

`startOnetapAuth` calls `postIntentUseCase.invoke(..., uiId: [item.uiid], uid: ...)` and routes the result through the same `handleIntentResponse` used by every other flow (§8.2) — this is a thin UI layer over the existing intent pipeline, not a separate backend contract. `invokeResponse` always calls `dismissOneTapBottomSheet()` first, so any response (success or failure) auto-dismisses a presented sheet.

---

## 15. Device, App & Data Collection Inventory

### 15.1 `appInfo` (`DeviceInfoUtils.getAppInfo`) — rebuilt once per `initialise()`

`manufacturer` (`"Apple"`), `appVersion` (`CFBundleShortVersionString`), `deviceId` (`UIDevice.identifierForVendor`), `model` (hardware identifier string, e.g. `"iPhone15,2"`), `inid`, `tsid`, `sdkVersion` (`Constants.SDK_VERSION` — the stale `"2.3.1"` string, §24), `osVersion` (`"<major>.<minor>"`), `hasWhatsapp` (`canOpenURL("whatsapp://")`, computed once and cached in `DeviceInfoUtils.isIntialised`), `isSilentAuthSupported` (`"true"`, iOS 12+), `isWebAuthnSupported` (`"true"`, iOS 16+), `appleTeamId` (from `Info.plist`'s `AppIdentifierPrefix` if present), `isDeviceSimulator`.

### 15.2 `deviceInfo` (`DeviceInfoUtils.getDeviceInfoDict`, `@MainActor`) — built once at init, cached

`platform: "iOS"`, `vendor: "Apple"`, `device` (`UIDevice.current.name` — the user-assigned device name, e.g. "Jane's iPhone" — a more identifying value than Android's device-model-only equivalent), `model`, `iOS_version`, `product` (`systemName`, e.g. "iOS"), `hardware` (raw `utsname.machine` string), `screenHeight`/`screenWidth` (points, via `UIScreen.main.bounds`), `userAgent` (`WKWebView`'s `userAgent` property + `" otplesssdk"` suffix — instantiates a `WKWebView` purely to read this value, mirroring the Android SDK's web-shape-parity rationale). Sent (as a JSON string) with **every** API call.

### 15.3 Device identifiers

- `UIDevice.current.identifierForVendor` (the "vendor ID" — reset if all of the vendor's apps are uninstalled) — used both as `appInfo.deviceId` and `DeviceInfoModel.udid` (the latter appears unused elsewhere in current source, §24).
- App-signing hash: SHA-256 of the app's Mach-O executable file (`DeviceInfoUtils.getAppHash`, via `CommonCrypto`), computed once and cached in `DeviceInfoUtils.appHash` — declared but **no call site sends it anywhere** in current source (unlike Android's `otpHash`, which is actively sent in every POST body). This looks like a leftover/incomplete port of the Android app-signature-hash mechanism.
- No GAID/IDFA-equivalent collection exists anywhere in this SDK — no `AdvertisingIdClient`/`ASIdentifierManager` usage was found.

### 15.4 Telephony / SIM data

**None.** There is no SIM/carrier/telephony data collection subsystem on iOS (no equivalent of Android's `SimDetailProvider`/`telephonyInfo`) — consistent with Apple's much more restricted `CoreTelephony` APIs on modern iOS versions. `isMobileDataEnabled` (from `NWPathMonitor(requiredInterfaceType: .cellular)`) is the only network-type signal collected, used solely to gate `silentAuthEnabled` in the intent body (§10.3) and reported in the `sdk_start_called` telemetry event.

---

## 16. Telemetry / Event Pipeline (`OtplessBMEvents`)

Every observable SDK behaviour is tracked through **one file**: `utils/Events/OtplessBMEvents.swift`. Events are `OtplessTrackEvent`s pushed to `OtplessEventIO` (the sibling `otpless-event-io-ios` package — batching/persistence/retry logic lives there, not in this repo; `retryFailedEvents()` is nudged at `initialise()`). The private `trackEvent(...)` helper is the single call-through point — mirroring the Android convention of never calling the transport directly from feature code.

Catalog (namespace → event names):

| Namespace | Events |
|---|---|
| `Init` | `sdk_init_called`, `sdk_init_state_from_cache`, `sdk_init_state_ready`, `sdk_init_state_failed`, `sdk_init_wait_completed` |
| `Auth` | `sdk_start_called` (full request map + `isMobileDataActive`), `sdk_set_callback` |
| `Sna` | `sna_started`, `sna_status_check_started`, `sna_redirected`, `sna_response`, `sna_init_terminal_response`, `sna_auth_terminal_response`, `sna_callback_result` |
| `Deeplink` | `sdk_deeplink_opened` |
| `SdkAuth` | `sdk_auth_started` (provider: GOOGLE/FACEBOOK/APPLE) |
| `Api` | `api_state`, `api_intent`, `api_merchant_config`, `api_verify_code`, `api_transaction_status`, `api_sna_status`, `api_mfa_sna_status`, `api_verify_otp`, `api_unknown`, `transaction_status_check_started`, `api_response_error` |
| `Response` | `sdk_response_<type>` (delivered), `sdk_response_not_delivered` (reasons: `status_code_suppressed`, `timeout`; `callback_not_initialized`/`legacy_mode_silent_auth` constants defined but **never triggered**, §9.4) |
| `Commit` | `merchant_response_commit` |
| `Exception` | `sdk_exception` (`{where, message}`) |
| `Device` | device snapshot via `OtplessEventIO.pushDeviceEvent` (`sdkVersion`, `platform: "otpless-headless(ios)"`, `isMobileDataActive`, `deviceInfo`) |
| `Intelligence` | `device_intelligence_fetch_success`, `device_intelligence_fetch_failure` (actually used); `intel_auth_start`, `intel_auth_result`, `intel_auth_error`, `intel_auth_job_awaiting` (**defined, never called** — dead code, §24) |
| `UserAuth` | `native_cle_auth_initiated` / `_auth_success` / `_auth_failed` (merchant-reported via `userAuthEvent`) |
| `Session` | `sdk_session_get_active`, `sdk_session_logout`, `sdk_session_error` — used only by `OtplessSessionManager` (§6.5), not by the main auth flow |

**Convention:** never call `OtplessEventIO` directly from feature code — add a typed function in the right `OtplessBMEvents` namespace (explicitly stated in the file's own header comment, mirroring Android's `LongClawEvents` rule).

---

## 17. Persistence

Two storage mechanisms, used by two independent subsystems:

| Key | Constant | Storage | Written by | Read by |
|---|---|---|---|---|
| `otpless_bm_state` | `Constants.STATE_KEY` | Keychain (`SecureStorage`, service `com.otpless.bmum.secure`) | `fetchStateAndMerchantConfig` | `requestStateForDeviceIfNil` |
| `otpless_bm_uid` | `Constants.UID_KEY` | Keychain | `handleIntentResponse`/`VerifyCodeUseCase`/`PasskeyUseCase` callbacks | `initialise()` |
| `otpless_bm_inid` | `Constants.INID_KEY` | declared but **no read/write call site found** in current source | — | — |
| `otpless_session_info` | `SessionStorageKeys.session` | Keychain | `OtplessSessionManager.saveSession` | `getSavedSession` |
| `otpless_session_state` | `SessionStorageKeys.state` | Keychain | `saveSessionAndState` | `makeHeaderMap` |

Unlike Android's plain (unencrypted) `SharedPreferences`, iOS's `SecureStorage` genuinely uses the Keychain (`kSecClassGenericPassword`) — so despite the analogous "Secure*" naming pattern across platforms, iOS's version is actually encrypted-at-rest by the OS, while Android's `OtplessSecurePreferencesHelper` is not (per the Android guide's own quirk #15). `SecureStorage` also exposes generic `UserDefaults`-backed `saveToUserDefaults`/`getFromUserDefaults` helpers, but no call site in this repo uses them.

`clearAll()` (public, §6.1) wipes every Keychain item under `SecureStorage`'s service name — this includes the `state`/`uid` keys but has no effect on `OtplessSessionManager`'s separately-serviced Keychain entries (different `kSecAttrService`... actually `SecureStorage` is shared by both subsystems via the same `SecureStorage.shared` instance and the same `service` string, so `clearAll()` **does** also wipe the session-manager's Keychain entries, since they use the same underlying `SecureStorage.shared.save`/`.delete` calls under one Keychain service umbrella).

---

## 18. Concurrency Model

| Mechanism | Where | Purpose |
|---|---|---|
| `Task` (`Task<Bool, Never>`) + `CheckedContinuation` | `Otpless.initialise` | Bridges the non-`async` public `initialise` entry point to an awaitable result other entry points can suspend on |
| `NSLock` | `Otpless.initLock` | Guards read/write of `initContinuation` against concurrent `initialise()` calls resolving/replacing it |
| `async`/`await` throughout | Nearly every use case and repository method | The SDK's sole concurrency idiom for sequential request/response logic — no callback-based networking API remains except where bridging to delegate-based system APIs (`ASAuthorizationController`, Facebook/Google SDKs) requires `withCheckedContinuation` |
| `async let` race | `SNAUseCase.invoke` | Runs the raw SNA call and the status-poll loop concurrently; only the poll loop's result is actually returned (§12.3 — this is **not** a true cancel-the-loser race the way Android's `select {}` is) |
| `actor` | `OtplessSessionManager` | Serializes access to the independent session-persistence subsystem's mutable state (§6.5) |
| `@MainActor` | `DeviceInfoModel`, parts of `DeviceInfoUtils`, `OtplessResponseDelegate`/`OtplessLoggerDelegate` protocol requirements, `PasskeyASAuthorizationView`, `ImageUtils`, `Otpless.registerFBApp(_:didFinishLaunchingWithOptions:)` and its URL-context overload | UI-thread-affine work and delegate callbacks |
| `DispatchQueue.main.async` | `Otpless.invokeResponse`, `onDeviceIntelligenceComplete`, `dispatchDIEvent` | Explicit main-queue hop for delegate delivery, used alongside (not exclusively instead of) `@MainActor` |
| `NWPathMonitor` | `Otpless.cellularMonitor`, `CellularConnectionManager.pathMonitor` | Network-reachability observation; the former drives `isMobileDataEnabled`, the latter is debug-logging only |
| `Task.detached` + `Task.sleep` loop | `OtplessSessionManager.startAuthenticationLoopIfNotStarted` | A self-perpetuating 3-minute background re-authentication loop, independent of any merchant-driven call |
| No structured-concurrency "cancel everything on cleanup" | `Otpless.cleanup()` | See §8.10/§24 — no scope exists that, when cancelled, tears down every in-flight `Task` the way Android's `serviceScope.cancel()` does |
| `@unchecked Sendable` | `Otpless`, `OtplessResponse`, `ApiManager`, `ApiRepository`, `CellularConnectionManager`, `ApiError`, `SecureStorage`, `SessionServiceImpl`, `DeviceInfoUtils` | Manually asserted thread-safety on types the compiler can't verify automatically (mutable stored state accessed from multiple queues/tasks) — a real Swift-6-strict-concurrency escape hatch used pervasively rather than sparingly |

---

## 19. Public API Stability & Objective-C Interop Surface

There is no ProGuard/R8 equivalent for this SDK (§3) — the two mechanical concerns that matter here are **what's visible to Swift consumers** (access control: `public`/`internal`/`private`, enforced at compile time by the Swift compiler with no equivalent of Kotlin's explicit-API strict mode or a binary-compatibility-validator dump in this repo) and **what's visible to Objective-C consumers** (only `@objc`-annotated members, and only on types that can be `@objc` at all — classes/protocols/enums with `Int` raw values; Swift `struct`s, non-`@objc` enums, and generics can never be `@objc`).

**The Objective-C bridging pattern used throughout this SDK:**

1. Types with associated payloads that can't be `@objc` (`OtplessResponse` — a `struct`) get a **string-based shadow API**: `objcResponseDelegate: ((String) -> Void)?` / `setOtplessObjcResponseDelegate` deliver `OtplessResponse.toJsonString()` instead of the struct itself; `objcCommit(_ otplessResponse: String?)` is the reverse (JSON string → `OtplessResponse` → `commitOtplessResponse`).
2. Swift enums with non-`@objc`-safe cases (`OtplessChannelType: String, CaseIterable`) get a **duplicate string-constant mirror** (`OtplessChannelTypeObjC`, static `String` properties) plus a String-typed setter overload (`set(objcChannelType:)` alongside the enum-typed `set(channelType:)`).
3. `async` methods are `@objc`-annotated directly where possible (`start(withRequest:)`, `authorizeViaPasskey`, `handleDeeplink`, `registerFBApp(openURLContexts:)`) — Swift's Objective-C interop generates a completion-handler-based thunk automatically for these. `startAuth(parent:config:)` is a **counter-example**: it is `public` but **not** `@objc` (likely because its parameter type `OtplessAuthCofig` is a plain Swift `struct`, which can't cross the ObjC boundary at all — no shadow overload exists for it, so `startAuth`/the OneTap-UI flow (§14) is Swift-only).
4. A member can be legally overloaded by return type alone when only one overload is `@objc`: `OtplessRequest.getRequestId()` exists as **both** `@objc public func getRequestId() -> String` and an `internal func getRequestId() -> String?` extension method — only the first is reachable from Objective-C or from outside the module; Swift code inside the module must rely on argument/return-type inference to pick the right one, which is a maintenance trap (§24).

**What counts as "the public API" here, mechanically:** anything marked `public` or `@objc public` compiles into the module's public interface (`.swiftinterface`/`.swiftmodule` when built with library evolution, or is simply visible via `import OtplessBM` otherwise) and is binary-observable by any consumer, including the two RN wrapper repos. There is **no committed golden file** in this repo (no `swift package diagnose-api-breaking-changes` baseline, no `api-digester` dump) recording today's public surface — API drift here is caught only by manual review, unlike the Android SDKs' `LongClaw.api`/`shipped-surface.txt` goldens. `RedirectResult`/`ConnectionResponse` (§6.4) being `public` despite being structurally unreachable is the concrete evidence that nothing currently checks for over-broad access modifiers.

---

## 20. Info.plist / Entitlements Requirements

Documented in `README.md` as **merchant-owned** configuration (this SDK ships no manifest-merge equivalent — Info.plist keys must be added by hand to the host app's own `Info.plist`, unlike Android's automatic AndroidManifest merge):

- `CFBundleURLTypes` → a custom URL scheme `otpless.<appid-lowercase>` (must match `merchantLoginUri`'s scheme, §4) for OTPLESS's own SSO/backend-redirect deep-link callback (§8.6).
- `LSApplicationQueriesSchemes` → `whatsapp`, `otpless`, `gootpless`, `com.otpless.ios.app.otpless`, `googlegmail` — required (iOS 9+ query-scheme allowlisting) for `canOpenURL`/`UIApplication.shared.open` checks against those apps (WhatsApp-installed detection in `appInfo`, and opening backend-redirect URLs for WhatsApp/Google-flavored OAuth channels).
- The merchant's `AppDelegate`/`SceneDelegate` must forward `application(_:open:options:)` (and, for scenes, `UIOpenURLContext` handling) into `Otpless.shared.isOtplessDeeplink(url:)` + `handleDeeplink(_:)`, and — if using Facebook/Google sign-in — into `registerFBApp(...)`/the Google SDK's own URL handling.

**Privacy manifest (`Sources/PrivacyInfo.xcprivacy`, §3):** declares `NSPrivacyTracking: false`; collected data types `NSPrivacyCollectedDataTypePhoneNumber` and `NSPrivacyCollectedDataTypeEmailAddress` (both linked to the user, purpose `AppFunctionality`, not used for tracking); one accessed-API-type entry for `NSPrivacyAccessedAPICategoryUserDefaults` (reason code `CA92.1`, "access info from same app, not the device"). This is the SDK's own declared privacy surface — it does **not** separately declare `identifierForVendor`/device-model/Keychain access, even though those are read (§15) — Apple's manifest schema doesn't require declaring every API, only the ones on its "required-reason" list, and `UIDevice`/Keychain APIs are not on that list.

**No entitlements** (`.entitlements` file) are required or shipped by this SDK — Sign in with Apple, Passkeys/WebAuthn, and Facebook/Google sign-in are all driven by system frameworks (`AuthenticationServices`) or third-party SDKs that manage their own entitlement/capability requirements on the host app (e.g. the merchant app must enable the "Sign in with Apple" capability itself; this repo does not and cannot do that for them).

**Deployment target enforcement:** every iOS-13-through-17-gated code path in this SDK uses an explicit `#available`/`@available` guard with a defined fallback (e.g. `PasskeyUseCase.createRegistrationRequest`'s `excludeCredentials` only on iOS 17.4+; `OneTapBottomSheetViewController`'s custom detent only on iOS 16+, falling back to `.medium()`/`.large()` below that; `startAuth`/the whole OneTap UI flow requiring iOS 15+ and returning `false` below it) — mirroring the Android SDKs' "every API-level-gated call gets a guard and a defined fallback" rule.

---

## 21. External Dependencies

| Library | Entry points used | Notes |
|---|---|---|
| `otpless-event-io-ios` (`OtplessEventIO`) | `.initialize(appId:)`, `.push`, `.pushDeviceEvent`, `.retryFailedEvents`, `.trackingIds` | Owns `inId`/`tsId` generation and event delivery/retry — the iOS sibling of Android's `otpless-event-io`. Pinned to `1.0.0` in `Package.resolved`; the podspec pins `~> 1.0` |
| `OTPlessIntelligence` (optional iOS intelligence SDK) | **reflection only** — `NSClassFromString("OTPlessIntelligence.OTPlessIntelligence")`, selectors `shared`/`fetchIntelligenceWithParams:updateInfo:completion:` | Never imported, never a compile/link dependency of this package or podspec — merchants add it themselves (§13). Mirrors `android-intelligence-sdk`'s "reflection contract, not a compile dep" pattern from the hub `CLAUDE.md` topology |
| `FBSDKCoreKit` / `FBSDKLoginKit` (`~> 17.0.2`) | `LoginManager`, `AuthenticationToken`, `ApplicationDelegate` | Optional CocoaPods subspec `FacebookSupport` only; `#if canImport(FBSDKLoginKit)` compiles a real implementation, otherwise a stub |
| `GoogleSignIn` / `GoogleSignInSwiftSupport` (`~> 9.0`) | `GIDSignIn.sharedInstance` | Optional CocoaPods subspec `GoogleSupport` only; same stub-vs-real pattern |
| `AuthenticationServices` (system framework) | `ASAuthorizationAppleIDProvider`, `ASAuthorizationController`, `ASAuthorizationPlatformPublicKeyCredentialProvider` | Sign in with Apple + WebAuthn/Passkey — always available, no separate dependency |
| `LocalAuthentication` (system framework) | `LAContext` | Biometry/passcode availability check gating WebAuthn eligibility |
| `Network` (system framework) | `NWPathMonitor`, `NWConnection`, `NWParameters` | Cellular-forcing for SNA (§12.1) and general reachability |
| `CommonCrypto` (system framework) | `CC_SHA256` | App-executable hashing (§15.3 — currently unused downstream, §24) |
| `Security` (system framework) | `SecItemAdd`/`SecItemCopyMatching`/`SecItemDelete` | Keychain persistence (`SecureStorage`, §17) |
| `WebKit` (system framework) | `WKWebView` (instantiated only to read its `userAgent` property) | `deviceInfo.userAgent` (§15.2) |

There is **no OkHttp/Retrofit/Gson-equivalent third-party networking stack** — all HTTP goes through `URLSession` (system framework) for user-auth calls, and raw `Network.framework` sockets for the SNA leg; there is no third-party JSON library either (`Codable`/`JSONSerialization`, both system frameworks, cover everything).

---

## 22. Testing

**There is currently no test target and no test source files anywhere in this repository.** `Package.swift` declares a single library target (`OtplessBM`) with no accompanying `.testTarget`; no `Tests/` directory exists; no `.github/workflows` CI configuration exists in this repo at all. This is a significant gap relative to both Android SDKs (which carry JVM unit-test suites, contract fixtures, and CI-enforced coverage floors) — any change to this SDK is currently verified only by manual/Xcode-based smoke testing and PR review, with no automated regression safety net.

Concretely, none of the following exist yet and would need to be built from scratch as part of bringing this repo to parity with the Android SDKs' verification rigor (see the `make-repo-agentic` blueprint in the workspace hub):
- A `Tests/OtplessBMTests` target and `swift test`/`xcodebuild test` wiring.
- Contract fixtures analogous to `LongClaw/src/test/resources/contract/*.json` pinning `OtplessResponse`'s factory payload shapes (§9.1) against JSON goldens.
- Any automated check of the `ResponseTypes`/`OtplessConstant.terminalErrorCodes` registries (§9.1/§9.2) against accidental reordering or repurposing.
- Any CI workflow at all (build, lint, API-breakage check, or otherwise).

---

## 23. How-To: Common Modifications

**Add a new user-auth endpoint**
1. Add the path constant to `ApiManager` and a matching case in `OtplessBMEvents.Api.nameFromPath` (else calls get tracked as `api_unknown`).
2. Add a method to `ApiRepository` following the existing `Result<T, Error>` + `sendApiResponse` pattern.
3. Add/extend a use case in `usecase/`; return data, don't call the merchant callback directly.
4. Wire it into `Otpless.swift`/`OtplessExtensions.swift` and emit only through `invokeResponse`.
5. New response DTO → put it in `network/model/response/`, `Codable`.

**Add a new `ResponseTypes` value**
1. Add the enum case (mind the `#if OTPLESS_INTERNAL` gate if it's an internal-diagnostic-only type).
2. Add a factory on `OtplessResponse` (or a `toDict()` on the relevant DTO) for the payload shape.
3. Check `invokeResponse` filtering (§9.3) and `OtplessBMEvents.Response.delivered` (auto-derives the event name `sdk_response_<name>`).
4. Document the payload in §9.1 and check whether it should be ported to the Android SDKs (hub parity rule 2) — and vice versa when Android adds one.

**Add a field to the intent request** → `OtplessRequest` setter + `getDictForIntent()`/`getEventDict()`, then thread it through `PostIntentUseCase.getPostIntentRequestBody`/`PostIntentRequestBody`. Fields needed on *every* request belong in `ApiManager.getBody`/`constructURL` instead.

**Add telemetry** → a new function in the appropriate `OtplessBMEvents` namespace; never inline `OtplessEventIO.push` at a call site.

**Change timeouts/polling defaults** → server-driven values come from `TimerSettings`; SDK-side fallbacks are literals in `TransactionStatusUseCase.startPolling` (60 s / 3 s), `SNAUseCase.pollSNATransaction` (7 s / 200 ms), and `Otpless.apiRepository`'s construction (`userAuthApiTimeout: 30`, `snaTimeout: 5`).

**Release** → bump `OtplessBM.podspec`'s `s.version` **and** `Constants.SDK_VERSION` together (§24 quirk #1 exists precisely because the last release forgot the second one), update `CHANGELOG.md`, tag the release (CocoaPods trunk push / SPM tag are outside this repo's automation — no scripted release pipeline exists here, unlike the Android SDKs' `Makefile`).

---

## 24. Known Quirks & Gotchas

Things that look like bugs, are non-obvious, or bite modifications. Verified against the current code.

1. **`Constants.SDK_VERSION` ("2.3.1") lags `OtplessBM.podspec`'s `s.version` ("2.3.2").** The last commit (`591d76a`, "SNA failure error code and description added") bumped the podspec but not the runtime constant — so every `appInfo.sdkVersion` field and the device telemetry event currently report a version one patch behind what CocoaPods/SPM consumers actually resolve. Bump both together on every release (§23).
2. **`OtplessRequest.getRequestId()` is declared twice with different signatures** — `@objc public func getRequestId() -> String` (non-optional) and an `internal` extension `func getRequestId() -> String?` (optional). Legal Swift (overload by return type), but a call site inside the module with an ambiguous expected type could silently bind to the "wrong" one; new code should prefer being explicit about which is intended.
3. **No cancel-previous-start mechanism.** Unlike Android's `startMutex`/`activeStartJob`, nothing in `Otpless.start(withRequest:)` prevents two concurrent `start` calls from racing against shared mutable state (`token`, `asId`, `merchantOtplessRequest`, polling loops). `PostIntentUseCase.invoke` does call `stopPolling` on the *previous* transaction-status/SNA use cases at its start, which mitigates but does not eliminate races from a genuinely concurrent second `start()` call.
4. **`cleanup()` doesn't cancel in-flight work.** It cancels the cellular path monitor and nils `merchantVC`/`responseDelegate`, but leaves `initialisationTask`, any active `TransactionStatusUseCase`/`SNAUseCase` polling loop, and outstanding `URLSession` tasks running. It also does **not** nil `objcResponseDelegate` (only `responseDelegate`) — an Objective-C consumer's closure keeps firing after `cleanup()`.
5. **`SNAUseCase.invoke`'s `async let` is not a true race.** Both the SNA socket call and the status-poll loop always run to completion; only the poll loop's return value is used. Calling `stopPolling()` from the SNA callback only flips a flag the poll loop checks *before* its next iteration — an in-flight status HTTP call is never cancelled by it.
6. **`PostIntentRequestBody.metadata` is built with invalid JSON** (Swift's default string interpolation of `[String: Any]`, e.g. `"[key: value]"` rather than `{"key": "value"}"`), but this is harmless: `ApiManager.getBody` unconditionally overwrites the `metadata` key with a correctly `Utils.convertDictionaryToString`-encoded value before every request that goes through the standard enrichment path (`shouldAppendBasicParameters` defaults `true` at every real call site). Don't "fix" the constructor without checking this override still exists, and don't copy the pattern into new code.
7. **`ApiManager.baseURLSekura` is dead code.** Declared, never read — the real SNA URL always comes from the backend's `quantumLeap.intent` and is consumed directly by `CellularConnectionManager`, with no Retrofit-style placeholder-base-URL need (unlike Android's `SNA_BASE_URL`, which exists because Retrofit requires *some* base URL even when every call overrides it via `@Url`).
8. **`Otpless.shared.uiId` is effectively dead.** Declared as `internal private(set) var uiId: [String]?`, defaulting `nil`, and never assigned anywhere in current source — the ordinary intent path always sends `uiIds: nil`. Only the OneTap-UI flow (§14) explicitly overrides it with a literal one-element array at the call site (`uiId: [uuid]`), bypassing this property entirely. If a future feature needs to set it, note there is currently no setter.
9. **`REASON_CALLBACK_NOT_SET` and `REASON_LEGACY_SILENT_AUTH` are unreachable.** Both constants are defined in `OtplessBMEvents.Response`; neither `invokeResponse` nor any other code path references them — there is no legacy-response-mode feature on iOS at all (§9.4), and a missing delegate silently no-ops rather than being explicitly detected and tagged.
10. **`OtplessBMEvents.Intelligence.started`/`.result`/`.error`/`.jobAwaiting` are unreachable.** Only `.fetchIntelligenceSuccess`/`.fetchIntelligenceFailure` are actually called from `IntelligenceUseCase`; the other four namespace functions have no call sites.
11. **`DeviceInfoUtils.appHash` is computed but never sent anywhere.** `getAppHash()` (SHA-256 of the app executable) runs on every `initialise()` and is cached, but no request body or telemetry event currently reads `DeviceInfoUtils.shared.appHash` — unlike Android's `otpHash`, which is actively transmitted on every POST. This looks like an incomplete port of the Android app-signature mechanism; confirm with the backend team whether iOS is expected to send it before wiring it in, since adding a new field to a shared-backend request body is a contract change.
12. **`Constants.INID_KEY` ("otpless_bm_inid") has no read or write call site.** `inid`/`tsid` are sourced live from `OtplessEventIO.trackingIds` every `initialise()`, not from this Keychain key — the constant may be vestigial.
13. **`Otpless.getEventCounterAndIncrement()` has no call site.** Declared (mirroring Android's `OtplessSDK.getEventCounterAndIncrement`/`Utility.makeEventMap` pattern) but nothing in this codebase currently reads or increments `eventCounter`.
14. **`RedirectResult`/`ConnectionResponse` are `public` but structurally unreachable** (§6.4, §19) — the only producer/consumer, `CellularConnectionManager`, is `internal`. Harmless today, but any future refactor that makes `CellularConnectionManager` (or a method returning these types) `public` would retroactively make this "already public" surface load-bearing without anyone having reviewed it as an API decision.
15. **`OtplessEnvironment` has a different case count in DEBUG vs. release builds** of the same version — `.STAGING` and `setEnvironment(_:)` exist only under `#if DEBUG`. A merchant app built in release configuration cannot reference `.STAGING` at all (compile error, not a runtime restriction) — this is intentional but worth remembering when writing sample/test code that must compile in both configurations.
16. **`hasMerchantSelectedExternalSDK` is set as a side effect of `isChannelEnabled(channelType:isPhoneAuth:)`**, a function whose name reads like a pure predicate. Calling it (even just to check "is this channel enabled") for `FACEBOOK_SDK`/`GOOGLE_SDK`/`APPLE_SDK` mutates global state. Any future refactor that calls this method for a read-only check (e.g. UI enablement) would silently flip the SDK into "external SDK selected" mode.
17. **`DeviceInfoModel` (`utils/DeviceInfoModel.swift`) appears to be dead/legacy code** — a `@MainActor` class duplicating a subset of what `DeviceInfoUtils.getAppInfo()` already computes (`udid`, `appVersion`, `manufacturer`, `model`), with no call site found anywhere in current source. Likely a pre-refactor leftover; safe to delete once confirmed unused, but left undisturbed here since deletion wasn't in scope for this guide.
18. **`OtplessSessionManager` (§6.5) is a fully separate, seemingly unintegrated feature.** No use case or `Otpless.swift` code path calls into it; no README/CHANGELOG section documents its existence or intended usage. Treat it as a distinct, possibly in-progress API surface rather than part of the documented headless-auth contract until confirmed otherwise with the OTPLESS team.
19. **No test suite exists** (§22) — the most consequential gap relative to the Android SDKs' verification rigor.
20. **iOS's SNA `lapseMeta` payload is the legacy `{cause, brief}` shape only** — no v2 stage/kind envelope exists here, unlike the `docs/sna-lapsemeta-contract.md` v2 contract documented for Android. If that contract is meant to be cross-platform, iOS has not been ported to it yet.

---

## 25. Removed & Deprecated API History

No public API member has been removed or deprecated in the commit history available to this guide (the repository's `git log` for `Sources/` starts at the SDK's initial public surface and grows monotonically through the commits inspected while writing this guide — `c5571cb` "Feat/onetap passkey" through `591d76a` "SNA failure error code and description added"). This section exists to record such changes going forward, per the same "mark, never delete" rule the Android SDKs' `docs-sync` skill enforces: when a future PR removes or narrows the visibility of a `public`/`@objc public` member, add an entry here (full signature, visibility change, why, replacement) rather than deleting it from history.
