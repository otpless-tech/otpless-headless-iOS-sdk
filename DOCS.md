# OtplessBM — iOS Headless SDK Documentation

Generated from source at `Sources/OtplessBM/` (current `main`, podspec version `2.3.2`). This is a
from-source reference, not a copy of the public mintlify docs — it calls out places where source
and the published docs / README disagree.

- Module name: `OtplessBM`
- Min iOS: 13.0
- Swift: 5.5–6.0
- CocoaPods: `pod 'OtplessBM/Core', '2.3.2'`
- SPM: `https://github.com/otpless-tech/otpless-headless-iOS-sdk.git`, exact version `2.3.2`

---

## 1. Installation

### CocoaPods

```ruby
pod 'OtplessBM/Core', '2.3.2'
```

Optional subspecs (CocoaPods only — SPM has no equivalent, see §7):

```ruby
pod 'OtplessBM/FacebookSupport', '2.3.2'   # adds FBSDKCoreKit/FBSDKLoginKit ~> 17.0.2
pod 'OtplessBM/GoogleSupport', '2.3.2'     # adds GoogleSignIn/GoogleSignInSwiftSupport ~> 9.0
```

Run `pod repo update && pod install` after editing the Podfile.

### Swift Package Manager

Add `https://github.com/otpless-tech/otpless-headless-iOS-sdk.git`, exact version `2.3.2`.
SPM only ships the `Core` target — if you need native Google/Facebook sign-in, add
`GoogleSignIn`/`FBSDKLoginKit` as your own separate SPM dependencies; OtplessBM's Google/Facebook
bridging code (`GIDSignInUseCase`, `FBSdkUseCase`) is picked up at runtime via
`NSClassFromString`, so it activates automatically once those SDKs are linked in your app target.

---

## 2. Info.plist (Magic Link / deeplink only — not required for Smart Auth)

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array><string>otpless.{{YOUR_APP_ID_LOWERCASE}}</string></array>
    <key>CFBundleTypeRole</key>
    <string>Editor</string>
    <key>CFBundleURLName</key>
    <string>otpless</string>
  </dict>
</array>
<key>LSApplicationQueriesSchemes</key>
<array>
  <string>whatsapp</string>
  <string>otpless</string>
  <string>gootpless</string>
  <string>com.otpless.ios.app.otpless</string>
  <string>googlegmail</string>
</array>
```

For SNA (Silent Network Auth) only, also add `NSAppTransportSecurity` exceptions for:
`80.in.safr.sekuramobile.com`, `api-csp.airtel.in`, `v4-api-csp.airtel.in`,
`in-vil.ipification.com`, `partnerapi.jio.com` (all with `NSExceptionAllowsInsecureHTTPLoads` +
`NSIncludesSubdomains`).

---

## 3. Core API — `Otpless` (`Otpless.swift`)

`Otpless.shared` is the singleton entry point (`@objc final public class Otpless`).

| Method | Signature | Purpose |
|---|---|---|
| Init | `initialise(withAppId appId: String, loginUri: String? = nil, vc: UIViewController)` | Resets state, derives default `loginUri` as `otpless.{appId.lowercased()}://otpless` if not passed, resolves device info, fetches merchant config, flips SDK state to `.READY` and fires `SDK_READY`. Safe to call again — cancels/resolves any in-flight init first. |
| Start | `start(withRequest otplessRequest: OtplessRequest) async` | Awaits any pending `initialise()` (queues rather than erroring — since 2.2.0), resolves OTP length, and kicks off the request (intent/verify). Emits `FAILED` with code `5003` if init failed. |
| Deeplink check | `isOtplessDeeplink(url: URL) -> Bool` | True if `url.host == "otpless"` or it's a Google Sign-In deeplink. |
| Deeplink handler | `handleDeeplink(_ url: URL) async` | Extracts the `code` query param and verifies it if SDK is `.READY`; otherwise queues until ready. |
| One-tap UI | `startAuth(parent vc: UIViewController, config: OtplessAuthCofig) async -> Bool` | iOS 15+. Builds a one-tap identity list from merchant config; shows a built-in bottom sheet if `authConfig.isForeground`, else auto-starts if exactly one identity exists. Returns `false` if no identities or unsupported OS. |
| Passkey | `authorizeViaPasskey(withRequest: OtplessRequest, windowScene: UIWindowScene) async` | Passkey-based auth entry point. |
| Facebook wiring | `registerFBApp(_:didFinishLaunchingWithOptions:)`, `registerFBApp(_:open:options:)`, `registerFBApp(openURLContexts:) async` | Forward to Facebook SDK lifecycle hooks (only active if `FacebookSupport` subspec is linked). Call from `AppDelegate`/`SceneDelegate` respectively. |
| Commit | `commitOtplessResponse(_ otplessResponse: OtplessResponse)` | Call this at the top of your delegate callback — fires internal analytics; no return value. |
| Cleanup | `cleanup()` | Clears view controller reference, cancels cellular monitor, clears delegate. |
| Ready check | `isSdkReady() -> Bool` | `true` once `SDK_READY` has fired. |
| Session id | `gettsID() -> String` | Returns the session tracking id. |
| Wipe storage | `clearAll()` | Clears all secure storage (uid/state/session). Use for logout/reset. |

### Setters (getters/setters extension)

| Method | Purpose |
|---|---|
| `setResponseDelegate(_ delegate: OtplessResponseDelegate)` | Register your delegate. |
| `setMfaEnabled(_ enabled: Bool)` | Global MFA toggle (added 2.2.0, PR #37). When `true`, the intent request omits `uid` so the backend treats the call as an MFA factor step. This is a global flag on `Otpless`, **not** per-request. |
| `setDeviceFingerprintMode(_ mode: DeviceFingerprintMode)` | Sets a default device-intelligence mode. Note: `OtplessRequest.set(deviceFingerprintMode:)` on the request itself takes priority — this setter is only the fallback. |
| `setLoggerDelegate(_ delegate: OtplessLoggerDelegate)` | Hook into internal logging (`LogType` enum covers everything from `SDK_INIT` to `DEVICE_INTELLIGENCE`). |
| `setOtplessObjcResponseDelegate(_ delegate: @escaping (String) -> Void)` | Objective-C-friendly closure-based delegate, receives a JSON string instead of `OtplessResponse`. |
| `userAuthEvent(event:fallback:providerType:providerInfo:)` | Merchant-triggerable analytics hook. |
| `setEnvironment(_ environment: OtplessEnvironment)` | `#if DEBUG` only — switches to staging base URL. |

### Delegate protocol

```swift
@MainActor
public protocol OtplessResponseDelegate: NSObjectProtocol {
    func onResponse(_ response: OtplessResponse)
}
```

> **README discrepancy:** `README.md` shows a sample method named `onOtplessResponse(response:)`.
> The actual (and only) protocol requirement is **`onResponse(_ response: OtplessResponse)`**.
> Following the README literally will not satisfy the protocol and won't compile.

### `OtplessResponse`

```swift
public struct OtplessResponse: @unchecked Sendable {
    public let responseType: ResponseTypes
    public let response: [String: Any]?
    public let statusCode: Int
}
```

---

## 4. `OtplessRequest` — request builder (`dto/OtplessRequest.swift`)

| Method | Signature | Sets up |
|---|---|---|
| Phone | `set(phoneNumber: String, withCountryCode: String)` | Phone auth (`.PHONE` medium) |
| Email | `set(email: String)` | Email auth (`.EMAIL` medium) |
| OAuth channel (Swift) | `set(channelType: OtplessChannelType)` | OAuth auth (`.OAUTH` medium) — not `@objc` |
| OAuth channel (Obj-C) | `set(objcChannelType: String)` | Same, string-based for Objective-C callers |
| WebAuthn/passkey | `set(requestIdForWebAuthn: String)` | `.WEB_AUTHN` medium |
| Backend-generated | `set(fromBackend: String)` | Phone flow driven by a backend-issued requestId |
| OTP value | `set(otp: String)` | Value to verify |
| OTP expiry | `set(otpExpiry: String)` | Custom expiry |
| OTP length | `set(otpLength: String)` | `"4"` or `"6"` |
| Delivery channel | `set(deliveryChannelForTransaction: String)` | e.g. SMS vs WhatsApp vs email override |
| Locale | `set(locale: String)` | Locale for delivered messages |
| Code | `set(code: String)` | Magic-link/OAuth verify code |
| Extras | `set(extras: [String: String])` | Arbitrary key/values merged into the intent body |
| Transaction id | `set(tid: String)` | Passthrough tid |
| Device fingerprint | `set(deviceFingerprintMode: DeviceFingerprintMode)` | Per-request Device Intelligence mode (primary DI toggle — see §6) |
| Get request id | `getRequestId() -> String` | Reads back the stored requestId |

```swift
@objc public enum DeviceFingerprintMode: Int {
    case NONE = 0   // default — DI disabled
    case ASYNC = 1  // fingerprint runs in background, doesn't delay ONETAP
    case SYNC  = 2  // SDK waits for the fingerprint before delivering ONETAP
}
```

There is **no SNA-specific setter**. SNA is triggered server-side based on merchant dashboard
config (`isSilentAuthEnabled`) plus request shape — not a client flag.

### `OtplessAuthCofig` (used with `startAuth`)

```swift
public struct OtplessAuthCofig: Sendable {
    let isForeground: Bool
    let otp: String?
    let tid: String?
    public init(isForeground: Bool, otp: String?, tid: String?)
}
```
Fields are only settable via `init` (not exposed as mutable public properties).

---

## 5. Response types (`dto/ResponseTypes.swift`)

```swift
public enum ResponseTypes: String {
    case INITIATE, VERIFY, ONETAP, FALLBACK_TRIGGERED, FAILED, SDK_READY,
         DELIVERY_STATUS, AUTH_TERMINATED, MFA_FACTOR_COMPLETED
    // API_RESPONSE, DEVICE_INTELLIGENCE also exist but are gated behind
    // #if OTPLESS_INTERNAL — never compiled into the public release build.
}
```

Two cases beyond the publicly documented set (`SDK_READY, FAILED, INITIATE, VERIFY, ONETAP,
DELIVERY_STATUS, FALLBACK_TRIGGERED`) that merchants **can** receive but aren't in the mintlify docs:

- **`AUTH_TERMINATED`** — fired when a terminal error occurs (SNA init/auth failure, or all
  channels exhausted). Carries the `snaError` payload described in §8.
- **`MFA_FACTOR_COMPLETED`** — fired mid-flow when one MFA factor succeeds, payload
  `{authType?, communicationChannel?}`.

`OTP_AUTO_READ` (sometimes seen in other Otpless SDK docs) does **not exist** in this codebase —
don't switch on it here.

---

## 6. Device Intelligence bridge (`usecase/IntelligenceUseCase.swift`)

OtplessBM does **not** link `OTPlessIntelligence` at compile time. It deliberately avoids
`import OTPlessIntelligence` and instead probes for it at runtime:

```swift
private static let className = "OTPlessIntelligence.OTPlessIntelligence"
private static let sharedSelector = NSSelectorFromString("shared")
private static let fetchSelector = NSSelectorFromString("fetchIntelligenceWithParams:updateInfo:completion:")
```

Trigger path: on any non-verify intent request, if `deviceFingerprintMode != .NONE`
(`OtplessRequest.set(deviceFingerprintMode:)`, falling back to
`Otpless.shared.setDeviceFingerprintMode(_:)`), `triggerDeviceIntelligenceIfNeeded` builds:

```swift
params:     ["rsId": "<uuid>-<uptimeNs>-<state>", "state": "<sdk state>"]
updateInfo: ["merchantId": <appId>, "phoneNumber": <request.getPhone() ?? nil>,
             "phoneInputType": "MANUAL", "userEventType": "LOGIN"]
```

and calls the fetch selector, expecting a completion block shaped
`(Bool success, String? dfrId, NSDictionary?, String? errorMessage) -> Void`. If the class isn't
linked or doesn't respond to that selector, it logs via `os_log` and resolves `nil` — the
transaction proceeds without DI, no crash.

> **⚠️ Known contract mismatch (verified against `otpless-iOS-intelligence-sdk` source as of this
> writing):** `OTPlessIntelligence` does **not** currently expose a method named
> `fetchIntelligenceWithParams:updateInfo:completion:`, nor one taking an `updateInfo` dictionary,
> nor a 4-argument `(Bool, dfrId, NSDictionary?, errorMessage)` callback. Its actual bridge-intended
> selectors are `runDeviceIntelligenceWithParams:onComplete:`, `configureIntelligenceWithParams:onComplete:`,
> and `fetchIntelligenceWithCompletion:` (see the intelligence SDK's own `DOCS.md`, §0/§2). As wired
> today, `shared.responds(to: fetchSelector)` will be `false` even when `OTPlessIntelligence` is
> correctly linked and configured — Device Intelligence silently never fires through this path.
> This needs to be reconciled by whoever owns both SDKs before merchants can rely on DI end-to-end.
> Treat `setDeviceFingerprintMode`/`set(deviceFingerprintMode:)` as **not functional today** until
> this is fixed.

---

## 7. Google / Facebook sign-in

Both are activated purely through `OtplessRequest.set(channelType:)` + `Otpless.shared.start(withRequest:)` —
there's no separate "sign in with Google/Facebook" method. The bridging use cases
(`GIDSignInUseCase`, `FBSdkUseCase`) are `internal`, detected via `NSClassFromString`, and only
activate if you've linked the corresponding subspec/SDK:

- Google: `pod 'OtplessBM/GoogleSupport'` (or add `GoogleSignIn`/`GoogleSignInSwiftSupport`
  yourself under SPM) + `OtplessRequest.set(channelType: .GOOGLE_SDK)` / `.GMAIL`.
- Facebook: `pod 'OtplessBM/FacebookSupport'` (or add `FBSDKCoreKit`/`FBSDKLoginKit` yourself
  under SPM) + the three `registerFBApp(...)` lifecycle calls + `.set(channelType: .FACEBOOK_SDK)` / `.FACEBOOK`.

Full `OtplessChannelType` list (`dto/OtplessChannelType.swift`):
`WHATSAPP, GOOGLE_SDK, FACEBOOK_SDK, APPLE_SDK, APPLE (APPLE_EMAIL), GMAIL, TWITTER, DISCORD,
SLACK, FACEBOOK, LINKEDIN, MICROSOFT, LINE, LINEAR, NOTION, TWITCH, GITHUB, BITBUCKET, ATLASSIAN,
GITLAB, TRUE_CALLER`. An Objective-C mirror (`OtplessChannelTypeObjC`) exposes the same values as
static string constants.

---

## 8. Error codes

| Code | Meaning |
|---|---|
| `401` | Unauthorized — invalid appId |
| `400` | Silent Authentication failed (generic, non-terminal) |
| `4000` | Invalid request values (bad phone/email) |
| `4001` | 2FA not supported by the headless SDK |
| `4003` | Requested OAuth channel not active on dashboard |
| `500` | Generic failure / verify network error |
| `5003` | SDK failed to initialize |
| `5800` | Could not get cellular manager instance / URL parse failure (SNA) |
| `5900` | Feature unsupported on this iOS version |
| `7160` | **SNA_AUTH_INIT_FAILED** — terminal |
| `7161` | **SNA_AUTH_FAILED** — terminal |
| `9100` | Request timeout |
| `9101` | Network connection lost |
| `9102` | DNS lookup failed |
| `9103` | Cannot connect to server |
| `9104` | No internet connection |
| `9105` | Secure connection (SSL) failed |
| `9106` | Transaction timeout / **ALL_CHANNEL_AUTH_FAILED** — terminal |
| `9110` | Request cancelled |

Terminal codes (`7160`, `7161`, `9106`) surface as `AUTH_TERMINATED` with an attached `snaError`
payload:

```swift
struct SNAError: Codable {
    let errorCode: String
    let message: String?
    let description: String?
}
```
found under the `"snaError"` key in the response dict. This is newer (PR #40, commit `591d76a`)
and not yet reflected in `CHANGELOG.md`.

Non-terminal HTTP-layer error codes you'll see in `handleInitiateError`/`handleVerifyError` style
switches (`7101–7121`, `7025`, `7020–7024`) come straight from the platform API and are documented
in the public mintlify docs — they're unchanged.

---

## 9. Version history highlights (`CHANGELOG.md`)

- **2.3.1** — `isSimBound: Bool?` added to each `Identity` in `ONETAP`/transaction-status responses.
- **2.3.0** — Device Intelligence selector fix attempt (see §6 for current known-mismatch status).
- **2.2.0** — MFA support (`setMfaEnabled`); `start()` now queues rather than fails if called before `initialise()` completes.
- **2.0.9** — Added optional `GoogleSupport`/`FacebookSupport` subspecs.
- Podspec is currently at `2.3.2`, one patch ahead of the latest `CHANGELOG.md` entry (`2.3.1`) —
  the SNA error-code work (§8) landed without its own changelog entry yet.

---

## 10. Undocumented public surface (flag before relying on it)

- **`OtplessSessionManager`** (`session/OtplessSessionManager.swift`) — `public actor` with
  `initialize(appId:)`, `getActiveSession() async -> OtplessSessionState`, `logout() async`.
  Appears to be a newer session-persistence/JWT-refresh mechanism. Not mentioned in README or
  CHANGELOG. Confirm with the SDK team before building merchant-facing flows on it — it may not
  be stable/finalized.
