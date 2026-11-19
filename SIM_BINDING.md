# SIM binding on iOS

Outbound SMS binding is opt-in by calling it. Apps that call nothing see no change.

| Need | API | iOS |
|---|---|---|
| Prove the user holds the SIM for a number by sending an SMS from it | `startSmsBinding` | 17+ (ICCID token on 26+) |

## Turning it on

Outbound SMS binding is off for every app until OTPLESS switches it on in your merchant config
(`merchant.config.outboundSmsBindingConfig.isEnabled`). Until then `startSmsBinding` returns
`FEATURE_NOT_ENABLED` and nothing is sent.

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
  message and your rules together. After the user sends, the SDK polls the general `status` API with
  the attempt's token every 1.5 s until the attempt is verified, rejected or expired. Nothing else is
  reported after a send. If the attempt ends without one (the user cancels, the send fails, R20's
  time limit is exceeded, or R9's single session is broken), the SDK adds `lapseMeta` to the status
  call (`{"error": "USER_CANCELLED", "error_description": "User cancelled"}`, URL-encoded), which
  fails the transaction and closes the attempt as aborted. The codes are `USER_CANCELLED`,
  `SESSION_INTERRUPTED` (R9), `TOKEN_EXPIRED` (R20) and `SMS_SEND_FAILED`. The backend does not
  enforce R20: the app does. A successful poll returns a normal authentication result: `bindingId` carries
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

### Inside the normal login flow

The backend's orchestration can answer a normal `start` as SMS binding: outbound SMS is the last step after
SNA and OTP. It can say so in the intent response, or, when silent authentication fails, in the status
response of that step. The SDK then runs it for you, with no call from the app:

1. `INITIATE` with `authType: SIM_BINDING` and `deliveryChannel: OUTBOUND_SMS`. Do not show an OTP field.
2. Apple's message screen opens, addressed to the service number with the message filled in.
3. `DELIVERY_STATUS` once the message has left the phone.
4. `ONETAP` with the session, as every other channel gives it, or an error shaped like the other verify
   errors (`VERIFY`, with `errorCode`, `errorMessage`, `authType: SIM_BINDING` and `retryable`). The error
   codes are the ones in the list above (`TOKEN_EXPIRED`, `NO_SIM`, `NUMBER_MISMATCH`, ...).

The device rules, the composer limit and the single-session rule apply as in `startSmsBinding`. The SDK
shows no screens of its own here (the app owns its login UI); only Apple's message screen appears.
