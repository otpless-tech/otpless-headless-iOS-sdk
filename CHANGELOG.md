
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
