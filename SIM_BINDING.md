# SMS SIM binding on iOS

Outbound SMS binding is opt-in on the backend. Apps that are not set up for it see no change, and there is no
function to call.

## Turning it on

Outbound SMS binding is off for every app until OTPLESS switches it on in your merchant config
(`merchant.config.outboundSmsBindingConfig.isEnabled`).

## How it runs

The backend's orchestration can answer a normal `start` as SMS binding: outbound SMS is the last step after
SNA and OTP. It can say so in the intent response, or, when silent authentication fails, in the status
response of that step. The SDK then runs it, and you see:

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
  carrier-sent completion) and never falls back to an editable one. The app has to declare that it holds
  the entitlement (`setUpiEntitlementDeclared`, added with the iOS 27 SIM check); without it the attempt
  ends with `ENTITLEMENT_MISSING`.
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
