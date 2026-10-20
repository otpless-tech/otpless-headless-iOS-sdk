## Unreleased
### Feature
- Apple **App Attest** registration (iOS 14+), controlled by the merchant config. When the config API enables it for your app, the SDK registers a hardware-backed App Attest key with OTPLESS once per install, in the background and after `SDK_READY` — it never delays, blocks or fails an authentication, and any failure is reported as telemetry only. The server verifies the attestation against the transaction `state` as the challenge (`POST /v3/lp/user/device/attestation/{state}`). Nothing changes for apps whose config does not enable it, and no public API was added or changed.
- Reinstall-safe: a key id left in the Keychain by a previous install is detected (the Keychain survives uninstall, App Attest keys do not) and re-attested. Failed attempts back off (30 s doubling to 1 h) so a broken backend or unsupported device does not cost an Apple round trip on every init.
- The attestation object is redacted from the SDK's API request logging.
- Per-request assertion on the intent call, only when attestation is enabled for your app and a key is registered. The intent body gains an `appAttestInfo` object (`status`, `keyId`, `assertion`, `challenge`) so the backend can verify the intent came from the same app install that registered the key. The signed hash is `SHA256("v1|challenge|appId|tsId|channel|identifierType|value")`, which binds the assertion to one app, one session and one OTP destination. If an assertion cannot be produced (unsupported device, no key yet, Apple error, or over a 1 s budget) the intent is sent anyway with `status` saying why, so authentication is never delayed or failed by it. An `invalidKey` response from Apple clears the stored key so the next init re-attests. Apps without attestation enabled send exactly the same body as before. The challenge is the transaction `state` for now, pending a one-time server-issued challenge.

### Notes
- **Host-app requirement:** add the `com.apple.developer.devicecheck.appattest-environment` entitlement (`development` / `production`) to your app target. The SDK cannot add it; without it key generation fails and attestation is skipped silently. Unsupported devices and the simulator are skipped cleanly.
- Per-request assertions are not part of this change; they need a server contract first.

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
