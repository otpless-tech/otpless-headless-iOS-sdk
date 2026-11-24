# SIM binding on iOS

Two features. Apps that use neither see no change.

| Need | How | iOS |
|---|---|---|
| Prove the user holds the SIM for a number by sending an SMS from it | Nothing to call: the SDK runs it inside the normal `start(withRequest:)` flow when the backend routes the sign-in there | 17+ (ICCID token on 26+) |
| Ask whether the bound number has an active plan on this device | `checkSimBinding` | 27+ |
| Be told when that answer changes | `setSimBindingListener`, `removeSimBindingListener` | 27+ |
| Ask the user's permission for the check, with your own explanation first | `requestNumberStatusPermission` | 27+ |
| Tell the SDK your app holds Apple's UPI Device Validation entitlement | `setUpiEntitlementDeclared` | 17+ |

## Turning it on

Outbound SMS binding is off for every app until OTPLESS switches it on in your merchant config
(`merchant.config.outboundSmsBindingConfig.isEnabled`). The iOS 27 SIM check below does not depend on this.

## Device context

Once SMS binding is switched on for your app, the SDK sends a `deviceContext` with each intent, so the
backend can route an iOS flow by what the device can do: `platform`, `os_version`,
`plan_status_supported` (the iOS 27 plan status API is present) and `upi_entitlement`. Apps that were
not set up send exactly the intent they sent before.

Tell the SDK once, at launch, whether your app holds Apple's UPI Device Validation entitlement:

```swift
Otpless.shared.setUpiEntitlementDeclared(true)   // only if the entitlement is really in the app
```

## Outbound SMS binding

There is no function to call. The backend's orchestration can answer a normal `start` as SMS binding:
outbound SMS is the last step after SNA and OTP. It can say so in the intent response, or, when silent
authentication fails, in the status response of that step. The SDK then runs it, and you see:

1. `INITIATE` with `authType: SIM_BINDING` and `deliveryChannel: OUTBOUND_SMS`. Do not show an OTP field.
2. Apple's message screen opens, addressed to the service number with the message filled in.
3. `DELIVERY_STATUS` once the message has left the phone.
4. `ONETAP` with the session, as every other channel gives it, or an error shaped like the other verify
   errors (`VERIFY`, with `errorCode`, `errorMessage`, `authType: SIM_BINDING` and `retryable`).

- **How it talks to the backend:** the response carries the token, the number to send to, the message
  and, when OTPLESS sends them, your rules. OTPLESS also checks the rules itself, so a response may carry
  none: the SDK then runs the flow with the checks the device always does (the phone must be able to send a text). After the user sends, the SDK polls the general `status` API with the
  attempt's token every 1.5 s until the attempt is verified, rejected or expired. If the attempt ends
  without one (the user cancels, the send fails, R20's time limit is exceeded, or R9's single session is
  broken), the SDK adds `lapseMeta` to the status call
  (`{"error": "USER_CANCELLED", "error_description": "User cancelled"}`, URL-encoded), which fails the
  transaction and closes the attempt as aborted. The codes are `USER_CANCELLED`,
  `SESSION_INTERRUPTED` (R9), `TOKEN_EXPIRED` (R20) and `SMS_SEND_FAILED`. The backend does not
  enforce R20: the app does.
- When the response carries rules, the device checks they ask for (minimum app and iOS version, SIM, the
  UPI entitlement declaration) run after the attempt exists. If one fails, the SDK reports it so the
  token stops working at once.
- With the UPI rule on, the composer uses Apple's UPI device validation (non-editable message,
  carrier-sent completion) and never falls back to an editable one. Declare the entitlement with
  `setUpiEntitlementDeclared`; without it the attempt ends with `ENTITLEMENT_MISSING`.
- On iOS 26+ the SDK also registers Apple's ICCID token within 30 s of sending. A missing token is
  recorded, not treated as a failure.
- The SDK shows no screens of its own (the app owns its login UI); only Apple's message screen appears.
  Keep the app in front while an attempt runs. If your rules include the single-session rule, going to
  the background abandons the attempt (`SESSION_INTERRUPTED`).
- `errorCode` values: `PERMISSION_MISSING`, `NO_SIM`, `AIRPLANE_MODE`, `UPGRADE_REQUIRED`,
  `ENTITLEMENT_MISSING`, `UNSAFE_SMS_APP`, `SMS_SEND_FAILED`, `NUMBER_MISMATCH`, `TOKEN_EXPIRED`,
  `SESSION_INTERRUPTED`, `DEVICE_BLOCKED`, `VMN_POOL_UNAVAILABLE`, `VERIFICATION_FAILED`,
  `INTERNAL_ERROR`, `ATTEMPT_IN_PROGRESS`, `SIM_BINDING_NOT_AVAILABLE` and `INVALID_PHONE_NUMBER`.
- iOS has no airplane-mode API; airplane mode empties the radio list, so it shows as `NO_SIM`.

## iOS 27 SIM check

Apple's plan status API arrives with iOS 27. The SDK finds it by looking for its methods, not by the OS version.
Before iOS 27 every call below answers `SIM_CHECK_NOT_SUPPORTED`.

```swift
Otpless.shared.checkSimBinding { result in          // checks the number this app last bound
    switch result {
    case .success(let check): print(check.status, check.reason as Any)   // bound / notBound / unknown
    case .failure(let error): print(error.code)   // SIM_CHECK_NOT_SUPPORTED, NO_BOUND_NUMBER
    }
}
```

The SDK keeps the number it last bound (in the Keychain, set when an SMS binding or a verified OTP binds a number), so there
is nothing to pass. `NO_BOUND_NUMBER` means nothing has been bound yet.

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
**Not Now** and **Allow**. A denied user can be asked again, and must be: Settings has no toggle for this permission (on iOS 27.0.1 the app's settings page shows only Apple Intelligence & Siri, Search and Mobile Data), so asking through `requestNumberStatusPermission` is the only way back. Reinstalling the app also clears the permission. Show your own explanation first:

```swift
Otpless.shared.requestNumberStatusPermission(phoneNumber: number) { result in
    // .success(.granted | .denied | .unavailable)
}
```

Apple's dialog appears only when the permission is not already held. Do not call Apple's request
for a number that is already allowed: it shows the dialog again, and Not Now takes the permission away.

### OTP with SIM bind (`OTP_BIND`, iOS 27 and above)

The backend can send a code that also binds the SIM. The app sees a normal OTP step:
`INITIATE` with `authType: OTP`, `channel: OTP` and `deliveryChannel: OTP_BIND`. It can come straight from the
sign-in call, or after silent authentication failed (the app also sees a `VERIFY` for the silent authentication).

Before the app is told to show the OTP screen, the SDK settles Apple's permission to check the number:

- It checks the permission silently, and opens Apple's dialog only if the user has not decided yet.
- A permission already held is never asked for again: Apple would show the dialog again, and Not Now would take the
  permission away.
- A number the phone does not hold gets "Phone number mismatch" with no Allow button, and counts as not allowed.
- The answer never blocks the code. With no permission the SDK sends no `simBound` (next section).
- Before iOS 27, or for an email request, nothing happens.

If the code is verified and the SIM is not bound, the backend fails the verify (`SIM_NOT_BOUND`). When that response
names SMS binding as the next channel and carries its data, the SDK switches to it: the app gets an `INITIATE` with
`authType: SIM_BINDING` (no error in between), the message screen opens, and the flow ends as in the SMS binding
section above. Without a next channel the sign-in ends with `AUTH_TERMINATED`.

### At OTP verify (iOS 27 and above)

For an app that has SMS binding switched on, the normal OTP flow also uses the plan status API. When
the user submits the OTP, the SDK silently checks the number and adds `simBound` to the verify call:

| Check | Sent |
|---|---|
| `bound` | `simBound: true` |
| `notBound` | `simBound: false`, which fails the transaction (`SIM_NOT_BOUND`) |
| `unknown` (no permission, restricted, low confidence, an Apple error) | nothing. The login is never failed on a guess. |

The SDK does not show Apple's dialog here. Ask for the permission after number entry with
`requestNumberStatusPermission`, so the check has an answer by the time the OTP is verified. A verified
OTP whose number the SIM holds also becomes the bound number for `checkSimBinding()`.

### Listener

```swift
Otpless.shared.setSimBindingListener(intervalSeconds: 60) { check in
    // called only when the status changes: bound, notBound or unknown
}
Otpless.shared.removeSimBindingListener()
```

Watches the bound number. You can set it before anything is bound (at app launch, say): it waits and
starts checking once a number is bound. It checks on launch, on return to the foreground, when the radio
technology changes, and every `intervalSeconds` (at least 5) while in the foreground.

- **Only a change of status calls back.** `unknown` with another reason is not a change. The first
  result is recorded without a call.
- iOS cannot check while the app is suspended, so a change in the meantime is reported at the next
  launch or return to the foreground.
- A failed Apple call is ignored, not reported as a change.
- Before iOS 27 it returns `SIM_CHECK_NOT_SUPPORTED`.
