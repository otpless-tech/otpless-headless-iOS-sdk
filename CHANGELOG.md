## 3.2.0 (unreleased)
### Feature
- **Outbound SMS SIM binding** (`Otpless.shared.startSmsBinding(phoneNumber:countryCode:...)`), a channel of the intent call: the intent request carries a `simBinding` block and its response carries the token, number, message and rules. The SDK polls the general `status` API, and ends an attempt that fails on the device by adding `lapseMeta` to that call. The phone sends a one-time token by SMS from its own SIM and the backend verifies it. Behaviour follows the rules the backend serves for your app; the SDK never branches on a template name. Device rules run before anything is requested (minimum app and iOS version, SIM present and on a network, `canSendText`); `ui: .headless` (default) draws only Apple's message composer, `ui: .standard` also asks the user to pick the right SIM on a dual-SIM phone, shows a "verifying" indicator after sending, and offers "Try again" on failures that can be retried. `OtplessSmsBindingFailure.message` gives wording for headless apps. With the UPI rule on, the composer uses Apple's UPI device validation (non-editable message, carrier-sent completion) and never falls back to an editable one. iOS 26+ also registers Apple's ICCID token.
- **iOS 27 SIM check**, from Apple's cellular plan status API: `checkSimBinding()` (no number to pass: the SDK keeps the number it last bound) returns `bound`, `notBound` or `unknown` with a reason (`NOT_AUTHORIZED`, `LOW_CONFIDENCE`, `RESTRICTED`, `API_ERROR`), without showing any dialog. `requestNumberStatusPermission(phoneNumber:)` asks Apple's permission for apps that show their own explanation first, and never re-asks when the permission is already held. `setSimBindingListener(phoneNumber:intervalSeconds:listener:)` calls back only when the result changes, checking on launch, on return to the foreground, on radio technology change and periodically while in the foreground. Before iOS 27 all three answer `SIM_CHECK_NOT_SUPPORTED`; `isSimCheckSupported` tells you up front. The API is detected by its methods being present, not by the OS version.
- **Opt-in per app.** `startSmsBinding` works only when the app's merchant config has `merchant.config.outboundSmsBindingConfig.isEnabled` set to true. Otherwise it returns `FEATURE_NOT_ENABLED` and the SDK calls no binding endpoint. Apps that were not onboarded see no change.
- **Standard UI follows the PRD's UX.** Before sending, an alert explains the step (SMS charges may apply, send the prefilled message unchanged) and names the line on a dual-SIM phone; after sending, a progress card shows sent, received and verified with the time left. `OtplessSmsBindingFailure` gains `maskedNumber` and `retryAfterSeconds`, so `message` can say which line to send from (`NUMBER_MISMATCH`) and how long a block lasts (`DEVICE_BLOCKED`, from the block length last seen in the rules).
- Rule values the PRD does not name are read under a few likely names (`min_app_version`, `min_os`), so a backend that picks another does not silently switch the rule off.
- **Device context for routing.** Once SMS binding is switched on for an app, every intent also carries `deviceContext` (`platform`, `os_version`, `plan_status_supported`, `upi_entitlement`) so the backend can route iOS flows by capability. New `Otpless.shared.setUpiEntitlementDeclared(_:)` declares whether the app holds the UPI Device Validation entitlement; `startSmsBinding(upiEntitlementDeclared:)` now defaults to it (`nil`).
- **iOS 27 and above, normal OTP flow.** For apps with SMS binding switched on, the verify-OTP call carries `simBound`: `true` when the number's plan is active on the device, `false` when it is certainly not (the backend then fails the transaction), and nothing when the SDK cannot tell. The permission is not asked at verify; use `requestNumberStatusPermission` after number entry.
- **Outbound SMS inside the normal login flow.** When the backend answers a normal `start` as `SIM_BINDING` (outbound SMS is the last step after SNA and OTP), the SDK now runs the SMS flow itself: `INITIATE` (`authType: SIM_BINDING`), the message screen, `DELIVERY_STATUS` when sent, then `ONETAP` with the session or a `VERIFY` error with `errorCode`, `authType` and `retryable`. Before, the main flow did not know the channel, read the timer (milliseconds) as seconds, polled nothing and opened no message screen, so the login hung. The same applies when SNA fails and its status response names SIM binding as the next channel.
- **Single session (R9).** When the rule is on and the app goes to the background during an attempt, the attempt is abandoned: the backend is told (`lapseMeta` with `SESSION_INTERRUPTED` on the status call) so the token stops working at once, and the call returns `SESSION_INTERRUPTED`.
- A retry for the same number names the attempt it follows (`previous_attempt_id`) so the backend can pick a different number to send to. It is kept in memory only and cleared once a binding verifies.
### Notes
- Nothing changes for apps that do not call these APIs.
- iOS cannot check a SIM while the app is suspended; the listener reports a change at the next launch or return to the foreground.
- Apple's UPI device validation needs the `com.apple.developer.upi-device-validation` entitlement in the host app, which Apple grants only after NPCI whitelisting. Pass `upiEntitlementDeclared: true` only if your app holds it.

## 3.1.1 (5th November 2026)
### Fixes
- Request-id flow (`set(fromBackend:)`): the request no longer defaults to the phone channel. Any intent that carries a backend-generated `requestId` now sends `isAutoIntent: true` (WebAuthn request ids excluded); the channel is not needed for these intents. Silent auth (SNA) is not requested when only a request id is set.
- Removed the always-true `isViSnaWhitelisted` and `isAirtelSnaWhitelisted` fields from the intent request body.

## 3.1.0 (3rd November 2026)
### Feature
- Apple **App Attest** registration (iOS 14+), controlled by the merchant config. When the config API enables it for your app, the SDK registers a hardware-backed App Attest key with OTPLESS once per install, in the background and after `SDK_READY` — it never delays, blocks or fails an authentication, and any failure is reported as telemetry only. The server verifies the attestation against the transaction `state` as the challenge (`POST /v3/device/attestation/{state}`). Nothing changes for apps whose config does not enable it, and no public API was added or changed.
- Reinstall-safe: a key id left in the Keychain by a previous install is detected (the Keychain survives uninstall, App Attest keys do not) and re-attested. Failed attempts back off (30 s doubling to 1 h) so a broken backend or unsupported device does not cost an Apple round trip on every init.
- The attestation object is redacted from the SDK's API request logging.
- A registered key belongs to one backend environment and one merchant app, so it is stored per `environment.appId` instead of once per install. Switching the app ID (or staging/production) now registers a key for the new app instead of reusing one the backend knows only under the old app.
- Per-request assertion on the intent call, only when attestation is enabled for your app and a key is registered. The intent body gains an `appAttestInfo` object (`status`, `keyId`, `assertion`, `challenge`) so the backend can verify the intent came from the same app install that registered the key. The signed hash is `SHA256("v1|challenge|appId|tsId|channel|identifierType|value")`, which binds the assertion to one app, one session and one OTP destination. If an assertion cannot be produced (unsupported device, no key yet, Apple error, or over a 1 s budget) the intent is sent anyway with `status` saying why, so authentication is never delayed or failed by it. An `invalidKey` response from Apple clears the stored key so the next init re-attests. Apps without attestation enabled send exactly the same body as before. The challenge is the transaction `state` for now, pending a one-time server-issued challenge.

- Registration is skipped while the Keychain is unreadable (locked device, e.g. a background launch) instead of registering a key that could not be saved.
### Notes
- **Host-app setup:** App Attest works without any entitlement; Apple then issues development-environment keys (AAGUID `appattestdevelop`). Add the `com.apple.developer.devicecheck.appattest-environment` entitlement set to `production` for App Store / TestFlight builds so the backend sees production attestations. Unsupported devices and the simulator are skipped cleanly.

## Unreleased
### Fixes
- Invalid state (`7005`) on the intent or merchant config API now refreshes the cached state and retries the call once per session — Android parity.
- Stale state and session data left in the Keychain after an app reinstall are now cleared on the first launch. The uid is kept.

## 3.0.1 (17th September 2026)
### Feature
- Added `setBuildPlatform(_:)` on `Otpless` so cross-platform wrappers (Flutter, React Native) can attribute telemetry to the framework they run under — mirrors Android's `OtplessSDK.buildPlatform`. The device event's platform field becomes `otpless-headless(<platform>)`; it defaults to `otpless-headless(ios)`, so behaviour for native integrations is unchanged. Additive and non-breaking — no existing API, request body or query parameter changed.

## 3.0.0 (3rd September 2026)
### Feature
- SSL Pin Validation

## 2.4.0 (5th August 2026)
### Fixes
- SNA api error propagation


## 2.3.2 (8th July 2026)
### Feature
-  SNA failure error code and description added.


## 2.3.1 (2nd July 2026)

### Features
- Added `isSimBound` to the `Identity` payload surfaced on `ONETAP` / transaction-status responses.

## 2.3.0 (2nd July 2026)

### Fixes
- Fixed device intelligence integration: the previous `runDeviceIntelligenceWithParams:onComplete:` selector did not exist on `OTPlessIntelligence`; device intelligence never ran in 2.x releases. Now routed through a new `IntelligenceUseCase` that dispatches to the SDK's `@objc(fetchIntelligenceWithParams:updateInfo:completion:)` selector via runtime `NSClassFromString` lookup — no OtplessBM manifest change required.

### Notes
- To enable device intelligence in your app:
  1. Install `OTPlessIntelligence` yourself — pod: `pod 'OTPlessIntelligence', '~> 1.3'`; SPM: add `https://github.com/otpless-tech/otpless-ios-intelligence-sdk` to your app's Package.swift.
  2. Import it in your AppDelegate / App struct and call `OTPlessIntelligence.shared.initialize(appId: "<your-app-id>") { _ in }` before any OtplessBM request that has `setDeviceFingerprintMode(.SYNC)` or `.ASYNC` enabled.
  3. OtplessBM detects the SDK at runtime; no OtplessBM configuration flag needed.

## 2.2.0 (22nd June 2026)

### Features
- Added MFA support via `Otpless.shared.setMfaEnabled(_:)`.
- `start()` now queues until `initialise()` completes — no more `failedToInitializeResponse` when start is called early.

## 2.0.9 (15th April 2026)

### Features
- Added optional `GoogleSupport` subspec — install `pod 'OtplessBM/GoogleSupport'` to enable Google Sign-In
- Added optional `FacebookSupport` subspec — install `pod 'OtplessBM/FacebookSupport'` to enable Facebook Sign-In

### Fixes
- Fixed incorrect error message in Facebook stub that referenced legacy SDK name `OtplessSDK`

## 1.1.0 (3rd April 2025)

### Improvements
- Added sdkVersion in appInfo

### Fixes
- Fixed an issue in which incorrect fields were sent to the server in case of sna failure

## 1.0.9 (31st March 2025)

### Fixes
- Fixed internal event name for better event tracking

## 1.0.8 (31st March 2025)

### Fixes
- `otpLength` bug fix


## 1.0.7 (28th March 2025)
### Features
- Added `otpLength` in `INITIATE` response

### Fixes
- `authType` sent incorrect in rare cases in `VERIFY` response


## 1.0.6 (24th March 2025)
### Features
- Added `DELIVERY_STATUS` responseType to indicate whether authType (OTP, MAGICLINK, OTP_LINK) has been delivered on the specified delivery channel.

## 1.0.5 (24th March 2025)
### Features
- Added INITIATE & VERIFY responses for SNA

## 1.0.4 (6th March 2025)
### Fixes
- Fixed an issue in which error code did not match the error message in the response.

## 1.0.3 (6th March 2025)
### Improvements
- Robust response handling in case of no internet connection
- Improved SNA performance
- Improved resource utilization
- providerMetadata response improvements

## Fixes
- SNA failure faced in case of slow internet

## 1.0.2 (4th March 2025)
### Fixes
- Fixed an issue in which SNA was failing for some users.

## 1.0.1 (4th March 2025)
### Features
- Added support for `SmartAuth` templateId for OTP delivery.
- Added new ResponseType `SDK_READY` to indicate that SDK has been initialized successfully.

### Fixes
- Fixed a bug in which `No Internet Connection` response was sent when it was not required.
- Fixed getter method for `OtplessResponse` object.

### Improvements
- Improved the SDK initialization process for better performance and reliability.

## 1.0.0 (24th February 2025)
- Initial release
