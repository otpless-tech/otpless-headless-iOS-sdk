# SIM binding on iOS

Two features, both opt-in by calling them. Apps that call nothing see no change.

| Need | API | iOS |
|---|---|---|
| Prove the user holds the SIM for a number by sending an SMS from it | `startSmsBinding` | 17+ (ICCID token on 26+) |
| Ask whether a number has an active plan on this device | `checkSimBinding` | 27+ |
| Be told when that answer changes | `setSimBindingListener` | 27+ |
| Ask the user's permission for the check, with your own explanation first | `requestNumberStatusPermission` | 27+ |

## Turning it on

Outbound SMS binding is off for every app until OTPLESS switches it on in your merchant config
(`merchant.config.outboundSmsBindingConfig.isEnabled`). Until then `startSmsBinding` returns
`FEATURE_NOT_ENABLED` and nothing is sent. The iOS 27 SIM check below does not depend on this.

## Outbound SMS binding

```swift
Otpless.shared.startSmsBinding(
    phoneNumber: "9812345621",        // without the country code
    countryCode: "+91",
    upiEntitlementDeclared: false,    // true only if your app holds Apple's UPI entitlement
    ui: .standard,                    // or .headless (default)
    onProgress: { progress in /* ISSUED, SENT, RECEIVED, VERIFIED ... */ },
    completion: { result in
        switch result {
        case .verified(let bindingId): break
        case .failed(let failure): print(failure.code, failure.isRetryable, failure.message)
        }
    }
)
```

- Call it after `SDK_READY`. One attempt runs at a time (`ATTEMPT_IN_PROGRESS`).
- **How it talks to the backend:** SMS binding is a channel of the intent call. The SDK sends the
  normal phone intent with a `simBinding` block (`platform`, `osVersion`, `appVersion` and the
  device id as `deviceFingerprint`). The response carries the token, the number to send to, the
  message and your rules together. The SDK then reports to `sim-binding-report` (`sentAt` and
  `composerReturnedAt` after sending, or `aborted` if the attempt ends without a send) and polls
  `sim-binding-status?token=…` every 1.5 s until the attempt is verified, rejected or expired. A successful poll returns a normal authentication result: `bindingId` carries
  its token, and `mobile` and `userId` say who was verified.
- Because the rules arrive with the token, the device checks (minimum app and iOS version, SIM, the
  UPI entitlement declaration) run after the attempt exists. If one fails, the SDK reports it so the
  token stops working at once.
- If the intent does not come back as SIM binding (the app is not set up for it), the call ends with
  `SIM_BINDING_NOT_AVAILABLE`.
- `.headless`: the only screen is Apple's message composer. Use `failure.message` if you want ready wording.
- `.standard` adds the SDK's own screens:
  - **Before sending**, one alert explains the step: "We'll send a verification SMS from this SIM. Standard SMS charges may apply", and that the message will be filled in and must be sent without changing it. On a dual-SIM phone it also names the line to send from. It comes before the attempt exists, so cancelling costs nothing.
  - **After sending**, a progress card shows *Message sent, Message received, Number verified* with the time left on the token.
  - **On a retryable failure**, an alert with "Try again".
  `completion` runs after the user dismisses the alert or stops retrying.
- Wording for your own screens: `failure.message` is a sentence fit for the user. For `NUMBER_MISMATCH` it names the line to send from (`failure.maskedNumber`, `+91 89xxxxxx55`), and for `DEVICE_BLOCKED` it says how long the block lasts when that is known (`failure.retryAfterSeconds`).
- Failure codes: `PERMISSION_MISSING`, `NO_SIM`, `AIRPLANE_MODE`, `UPGRADE_REQUIRED`, `ENTITLEMENT_MISSING`, `UNSAFE_SMS_APP`, `SMS_SEND_FAILED`, `NUMBER_MISMATCH`, `TOKEN_EXPIRED`, `SESSION_INTERRUPTED`, `DEVICE_BLOCKED`, `VMN_POOL_UNAVAILABLE`, `VERIFICATION_FAILED`, `INTERNAL_ERROR`, plus `SDK_NOT_READY`, `ATTEMPT_IN_PROGRESS`, `FEATURE_NOT_ENABLED`, `SIM_BINDING_NOT_AVAILABLE` and `INVALID_PHONE_NUMBER`.
- Keep the app in front while an attempt runs. If your rules include the single-session rule, going to the background abandons the attempt (`SESSION_INTERRUPTED`).
- iOS has no airplane-mode API; airplane mode empties the radio list, so it shows as `NO_SIM`.

## iOS 27 SIM check

Apple's plan status API arrives with iOS 27. The SDK finds it by looking for its methods, so
`Otpless.shared.isSimCheckSupported` is the right test (not the OS version).

```swift
Otpless.shared.checkSimBinding(phoneNumber: "+919812345621") { result in
    switch result {
    case .success(let check): print(check.status, check.reason as Any)   // bound / notBound / unknown
    case .failure(let error): print(error.code)                          // SIM_CHECK_NOT_SUPPORTED, INVALID_PHONE_NUMBER
    }
}
```

| Result | Meaning |
|---|---|
| `bound` | An active plan for the number is on this device, and the system is confident |
| `notBound` | The system is confident there is none |
| `unknown` + `NOT_AUTHORIZED` | The user has not allowed the check, or said no (iOS cannot tell these apart) |
| `unknown` + `LOW_CONFIDENCE` | The system is not sure |
| `unknown` + `RESTRICTED` | Not available for this number (for example a region that is not supported) |
| `unknown` + `API_ERROR` | Apple's API failed or did not answer |

The SDK applies no defaults and blocks nothing; your app decides what each result means.

### Permission

Apple can only grant permission for a number that is one of this phone's own lines. For any other
number it shows "Phone number mismatch" with no Allow button. The SDK reports that as `denied`,
the same as a refusal, because Apple's answer is the same for both.

Apple asks the user once per number: "Allow <app> to check the phone number on this device?" with
**Not Now** and **Allow**. A denied user can be asked again. Show your own explanation first:

```swift
Otpless.shared.requestNumberStatusPermission(phoneNumber: number) { result in
    // .success(.granted | .denied | .unavailable)
}
```

Apple's dialog appears only when the permission is not already held. Do not call Apple's request
for a number that is already allowed: it shows the dialog again, and Not Now takes the permission away.

### Listener

```swift
Otpless.shared.setSimBindingListener(phoneNumber: number, intervalSeconds: 60) { check in
    // called only when the result changes
}
Otpless.shared.removeSimBindingListener()
```

Checks on launch, on return to the foreground, when the radio technology changes, and every
`intervalSeconds` (at least 5) while in the foreground. The first result for a number is saved with
no callback. iOS cannot check while the app is suspended, so a change in the meantime is reported
at the next launch. A failed Apple call is ignored, not reported as a change.
