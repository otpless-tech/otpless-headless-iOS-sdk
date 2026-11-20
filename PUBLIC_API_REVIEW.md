# SIM binding: public API review

**Not for merging.** This PR exists only so the public API of the SIM binding feature can be reviewed in
one place. It holds one file and no code. The declarations below are copied from the implementation PRs.

- **#57** (ENG-622): outbound SMS binding
- **#58** (ENG-628, ENG-626): iOS 27 SIM check, device context, `simBound`

The tables show the full surface as it was first written, and "Public now" says whether #57 and #58
keep it public after this review. Everything marked "No" is internal or removed.

## Functions and properties on `Otpless.shared` (as first written)

| # | Declaration | Added in | Public now |
|---|---|---|---|
| 1 | `startSmsBinding(phoneNumber:countryCode:upiEntitlementDeclared:ui:onProgress:completion:)` | #57 | No |
| 2 | `setUpiEntitlementDeclared(_:)` | #58 | Yes |
| 3 | `isSimCheckSupported` | #58 | No |
| 4 | `checkSimBinding(phoneNumber:completion:)` | #58 | No |
| 5 | `checkSimBinding(completion:)` | #58 | Yes |
| 6 | `setSimBindingListener(phoneNumber:intervalSeconds:listener:)` | #58 | No |
| 7 | `setSimBindingListener(intervalSeconds:listener:)` | #58 | Yes |
| 8 | `removeSimBindingListener()` | #58 | Yes |
| 9 | `requestNumberStatusPermission(phoneNumber:completion:)` | #58 | Yes |

### 1. `startSmsBinding`

Binds the user's SIM by having the phone send a one-time token by SMS from its own SIM. Behaviour follows
the rules the backend serves for the app's client. Call after `initialise` has reported `SDK_READY`.
As first written, `upiEntitlementDeclared` was `Bool = false` in #57 and `Bool? = nil` in #58.

```swift
public func startSmsBinding(
    phoneNumber: String,                 // without its country code, e.g. 9812345621
    countryCode: String,                 // "+91" or "91"
    upiEntitlementDeclared: Bool? = nil, // whether the app holds Apple's UPI Device Validation entitlement
    ui: OtplessSmsBindingUI = .headless, // .headless draws only Apple's composer; .standard adds the SDK's screens
    onProgress: (@Sendable (OtplessSmsBindingProgress) -> Void)? = nil,   // main thread
    completion: @escaping @Sendable (OtplessSmsBindingResult) -> Void     // main thread, once
)
```

### 2. `setUpiEntitlementDeclared`

Declares, for every flow, whether the app holds the UPI Device Validation entitlement
(`com.apple.developer.upi-device-validation`). iOS gives an app no way to read its own entitlements, so
the SDK takes the app's word. Sent with the device context, and used for the UPI rule.

```swift
public func setUpiEntitlementDeclared(_ declared: Bool)
```

### 3. `isSimCheckSupported`

Whether this device has Apple's plan status API (iOS 27 and later). When false, every SIM check answers
`SIM_CHECK_NOT_SUPPORTED`.

```swift
public var isSimCheckSupported: Bool { get }
```

### 4. `checkSimBinding(phoneNumber:completion:)`

Asks whether one E.164 number has an active plan on this device. Never shows a dialog and never blocks
the flow.

```swift
public func checkSimBinding(
    phoneNumber: String,    // E.164, e.g. +919812345621
    completion: @escaping @Sendable (Result<OtplessSimBindingCheck, OtplessSimCheckError>) -> Void  // main thread, once
)
```

### 5. `checkSimBinding(completion:)`

Asks whether the number this app last bound has an active plan on this device. No number to pass: the SDK
keeps the bound number. Answers `NO_BOUND_NUMBER` if nothing has been bound, and
`SIM_CHECK_NOT_SUPPORTED` before iOS 27. Never shows a dialog.

```swift
public func checkSimBinding(
    completion: @escaping @Sendable (Result<OtplessSimBindingCheck, OtplessSimCheckError>) -> Void
)
```

### 6. `setSimBindingListener(phoneNumber:intervalSeconds:listener:)`

Calls `listener` when the result of the check for `phoneNumber` changes. Checks on launch, on return to
the foreground, when the radio technology changes, and every `intervalSeconds` in the foreground. iOS
cannot check while the app is suspended, so a change in the meantime is reported at the next launch.
Replaces any listener set earlier. Returns `SIM_CHECK_NOT_SUPPORTED` before iOS 27.

```swift
@discardableResult
public func setSimBindingListener(
    phoneNumber: String,
    intervalSeconds: TimeInterval = 60,
    listener: @escaping @Sendable (OtplessSimBindingCheck) -> Void
) -> Result<Void, OtplessSimCheckError>
```

### 7. `setSimBindingListener(intervalSeconds:listener:)`

The same, for the bound number. It can be set before anything is bound: it waits, and starts checking
once a number is bound.

```swift
@discardableResult
public func setSimBindingListener(
    intervalSeconds: TimeInterval = 60,
    listener: @escaping @Sendable (OtplessSimBindingCheck) -> Void
) -> Result<Void, OtplessSimCheckError>
```

### 8. `removeSimBindingListener`

```swift
public func removeSimBindingListener()
```

### 9. `requestNumberStatusPermission`

Asks Apple's permission to check a number, for apps that show their own explanation first. Apple's dialog
appears only when the permission is not already held.

```swift
public func requestNumberStatusPermission(
    phoneNumber: String,
    completion: @escaping @Sendable (Result<OtplessNumberStatusPermission, OtplessSimCheckError>) -> Void
)
```

## Public types

| Type | Members | Added in | Public now |
|---|---|---|---|
| `OtplessSmsBindingUI` | `.headless`, `.standard` | #57 | No |
| `OtplessSmsBindingProgress` | `issued`, `sent`, `received`, `verified`, `rejected`, `expired`, `aborted` | #57 | No |
| `OtplessSmsBindingResult` | `verified(bindingId:mobile:userId:)`, `failed(OtplessSmsBindingFailure)` | #57 | No |
| `OtplessSmsBindingFailure` | `code`, `isRetryable`, `maskedNumber`, `retryAfterSeconds`, `message` | #57 | No |
| `OtplessSimBindingStatus` | `bound`, `notBound`, `unknown` | #58 | Yes |
| `OtplessSimBindingUnknownReason` | `notAuthorized`, `lowConfidence`, `restricted`, `apiError` | #58 | Yes |
| `OtplessSimBindingCheck` | `status`, `reason` | #58 | Yes |
| `OtplessNumberStatusPermission` | `granted`, `denied`, `unavailable` | #58 | Yes |
| `OtplessSimCheckError` | `code`, `.notSupported`, `.invalidPhoneNumber`, `.noBoundNumber` | #58 | Yes |

```swift
public enum OtplessSmsBindingUI: Sendable { case headless, standard }

public enum OtplessSmsBindingProgress: String, Sendable {
    case issued = "ISSUED", sent = "SENT", received = "RECEIVED", verified = "VERIFIED"
    case rejected = "REJECTED", expired = "EXPIRED", aborted = "ABORTED"
}

public enum OtplessSmsBindingResult: Equatable, Sendable {
    case verified(bindingId: String?, mobile: String? = nil, userId: String? = nil)
    case failed(OtplessSmsBindingFailure)
}

public struct OtplessSmsBindingFailure: Error, Equatable, Sendable {
    public let code: String                // e.g. NO_SIM, NUMBER_MISMATCH, TOKEN_EXPIRED, DEVICE_BLOCKED
    public let isRetryable: Bool
    public let maskedNumber: String?       // "+91 89xxxxxx55", for NUMBER_MISMATCH wording
    public let retryAfterSeconds: Int?     // for DEVICE_BLOCKED, when known
    public var message: String { get }     // a sentence fit to show the user
}

public enum OtplessSimBindingStatus: String, Sendable { case bound = "BOUND", notBound = "NOT_BOUND", unknown = "UNKNOWN" }

public enum OtplessSimBindingUnknownReason: String, Sendable {
    case notAuthorized = "NOT_AUTHORIZED", lowConfidence = "LOW_CONFIDENCE", restricted = "RESTRICTED", apiError = "API_ERROR"
}

public struct OtplessSimBindingCheck: Equatable, Sendable {
    public let status: OtplessSimBindingStatus
    public let reason: OtplessSimBindingUnknownReason?   // set only when status is .unknown
}

public enum OtplessNumberStatusPermission: String, Sendable { case granted = "GRANTED", denied = "DENIED", unavailable = "UNAVAILABLE" }

public struct OtplessSimCheckError: Error, Equatable, Sendable {
    public let code: String
    public static let notSupported = OtplessSimCheckError(code: "SIM_CHECK_NOT_SUPPORTED")
    public static let invalidPhoneNumber = OtplessSimCheckError(code: "INVALID_PHONE_NUMBER")
    public static let noBoundNumber = OtplessSimCheckError(code: "NO_BOUND_NUMBER")
}
```
