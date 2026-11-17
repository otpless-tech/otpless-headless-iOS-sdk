# SIM binding on iOS

Two features, both opt-in by calling them. Apps that call nothing see no change.

| Need | API | iOS |
|---|---|---|
| Prove the user holds the SIM for a number by sending an SMS from it | `startSmsBinding` | 17+ (ICCID token on 26+) |
| Ask whether a number has an active plan on this device | `checkSimBinding` | 27+ |
| Be told when that answer changes | `setSimBindingListener` | 27+ |
| Ask the user's permission for the check, with your own explanation first | `requestNumberStatusPermission` | 27+ |

## Outbound SMS binding

```swift
Otpless.shared.startSmsBinding(
    msisdn: "+919812345621",          // E.164
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
- `.headless`: the only screen is Apple's message composer. Use `failure.message` if you want ready wording.
- `.standard`: adds a dual-SIM prompt (before any token is requested, so cancelling costs nothing), a "verifying" indicator, and a "Try again" alert on retryable failures. `completion` runs after the user dismisses the alert or stops retrying.
- Failure codes: `PERMISSION_MISSING`, `NO_SIM`, `AIRPLANE_MODE`, `UPGRADE_REQUIRED`, `ENTITLEMENT_MISSING`, `UNSAFE_SMS_APP`, `SMS_SEND_FAILED`, `NUMBER_MISMATCH`, `TOKEN_EXPIRED`, `SESSION_INTERRUPTED`, `DEVICE_BLOCKED`, `VMN_POOL_UNAVAILABLE`, `VERIFICATION_FAILED`, `INTERNAL_ERROR`, plus `SDK_NOT_READY`.
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
