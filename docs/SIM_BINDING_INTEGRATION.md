# OTPLESS iOS SDK 3.2.0-alpha2: SIM binding integration guide

This guide is for iOS developers adding SIM binding to an app that already signs users in with the OTPLESS
headless iOS SDK. It covers what you need to integrate, how to test it, and what to do to go live.

`3.2.0-alpha2` is a pre-release for integration testing on staging. **Do not ship an alpha build to production.**
Go live on the stable release that follows (see [Going live](#7-going-live)).

---

## Contents

1. [What you get](#1-what-you-get)
2. [Requirements](#2-requirements)
3. [Install](#3-install)
4. [Integrate](#4-integrate)
5. [Test](#5-test)
6. [Known limits of the alpha](#6-known-limits-of-the-alpha)
7. [Going live](#7-going-live)
8. [Support](#8-support)

---

## 1. What you get

| Capability | What the user experiences | What you build |
|---|---|---|
| **SMS SIM binding** | Apple's message screen opens with a prepared text. The user taps Send, and OTPLESS confirms the number is on this phone. | Handle the new responses. No new function to call. |
| **OTP with SIM bind (iOS 27)** | A code arrives as usual. Before the OTP screen, Apple asks the user to allow the number check. If the SIM is not bound, the sign-in continues with SMS binding. | Show your OTP screen as usual. Handle the fallback. |
| **iOS 27 SIM check** | Optional. Your app can ask whether a number has an active plan on the phone, and be told when that changes. | Call the SIM check functions where you need them. |

Your sign-in does not change until OTPLESS enables these for your app.

---

## 2. Requirements

- An app that already signs users in with the OTPLESS headless SDK (see the main `README.md`).
- iOS 13 or later for the SDK. SMS binding is for iOS 17 and later. The permission flow and the SIM check need iOS 27.
- A real iPhone with a SIM. The simulator and iPads without cellular cannot send the SMS.
- No new `Info.plist` entries or permission strings. Apple's message screen and permission dialog are shown by the system.

---

## 3. Install

### Swift Package Manager

In Xcode: **File > Add Package Dependencies**, enter the URL, choose **Exact Version** `3.2.0-alpha2`.

```
https://github.com/otpless-tech/otpless-headless-iOS-sdk
```

### CocoaPods

The alpha is not on the CocoaPods trunk. Point your `Podfile` at the tag:

```ruby
pod 'OtplessBM', :git => 'https://github.com/otpless-tech/otpless-headless-iOS-sdk.git', :tag => '3.2.0-alpha2'
```

---

## 4. Integrate

### Step 1: Ask OTPLESS to enable your app

Send your OTPLESS contact the **App ID** and the **environment** (staging first). OTPLESS will:

1. Enable SMS binding for the app.
2. Set the rules for your app. OTPLESS applies them on its side; you do not code them.
3. Set up the routing. OTPLESS decides when a sign-in goes to SMS binding or to an OTP with SIM bind. Your app cannot force it.

Until this is done, nothing changes in your sign-in, so you can ship the new SDK ahead of the setup.

### Step 2: Keep your existing sign-in

Initialise the SDK and start sign-in as you do today. SMS binding and the OTP with SIM bind run inside that same
call. You add no new call for them.

### Step 3: Handle the responses

Everything arrives in your existing `onResponse`. Use this table to decide what your screen shows:

| Response | What it means | Your screen |
|---|---|---|
| `INITIATE` **with an `errorCode`** | OTPLESS refused the request. | **A failure.** Show `errorMessage`. Do not go to the OTP screen. |
| `INITIATE`, `authType` is `SIM_BINDING` | SMS binding started. | A "send the text message" state. **No OTP field.** |
| `INITIATE`, `deliveryChannel` is `OTP_BIND` | A code was sent (iOS 27). | Your normal OTP field. |
| `VERIFY` with `authType` `SILENT_AUTH` | Silent authentication failed. | Nothing. The next response says what is next. |
| `DELIVERY_STATUS` | The message or code was delivered. | Optional. |
| `ONETAP` | Signed in. | Continue into your app. |
| `VERIFY` | A step failed. | Show `errorMessage`. Offer a retry if `retryable` is true. |
| `AUTH_TERMINATED` | The transaction is over. | Show the reason and start a new sign-in. |

A minimal handler:

```swift
func onResponse(_ response: OtplessResponse) {
    DispatchQueue.main.async {
        let body = response.response ?? [:]
        switch response.responseType {
        case .INITIATE where body["errorCode"] != nil:
            self.showError(body["errorMessage"] as? String, canRetry: false)
        case .INITIATE where (body["authType"] as? String) == "SIM_BINDING":
            self.showSendTextMessageState()
        case .INITIATE:
            self.showOtpField()
        case .ONETAP:
            self.signedIn(with: body)
        case .VERIFY where (body["authType"] as? String) == "SILENT_AUTH":
            break
        case .VERIFY:
            self.showError(body["errorMessage"] as? String, canRetry: (body["retryable"] as? Bool) ?? true)
        case .AUTH_TERMINATED, .FAILED:
            self.showFinalFailure(body["errorMessage"] as? String)
        default:
            break
        }
    }
}
```

### Step 4: Design the user-facing parts

The SDK shows only Apple's own screens: the message screen and the permission dialog. The rest is yours:

- **Before the message screen,** explain what is about to happen, for example: "We'll send a text from this phone to
  confirm your number. Standard SMS charges may apply. Send it without changing it."
- **Keep the app in front** while the attempt runs, and do not let the user edit the message.
- **Retrying** means calling sign-in again with the same number. There is no resume.
- **Always offer another sign-in method** when an error says the user cannot retry.

### What to do for each failure

Use `retryable` to decide whether to offer "Try again". The codes you can see:

| Where | Code | Meaning | What to do |
|---|---|---|---|
| `INITIATE` | `7184` | Too many attempts from this device. | Offer another sign-in method. |
| `INITIATE` | `7185` | No number available for SMS binding right now. | Offer another method; try again later. |
| `INITIATE` | `7186` | The app or iOS version is too old for this step. | Ask the user to update, or offer another method. |
| `INITIATE` | `7102`, `7106` | The phone number is invalid. | Ask the user to check the number. |
| `INITIATE` | `SIM_BINDING_NOT_AVAILABLE` | The step could not start. | Offer another method. |
| `VERIFY` | `SMS_SEND_FAILED` | The user cancelled the message screen, or it was not sent. | Offer "Try again". |
| `VERIFY` | `NUMBER_MISMATCH` | The text came from a different number (for example the other SIM). | Tell the user to send from the SIM with that number. |
| `VERIFY` | `TOKEN_EXPIRED` | The user took too long. | Offer "Try again". |
| `VERIFY` | `NO_SIM` | No SIM, no signal, airplane mode, or the phone cannot send text. | Ask the user to fix it, then retry. |
| `VERIFY` | `INTERNAL_ERROR` | A network or backend problem. | Offer "Try again". |
| `VERIFY` | any other code | OTPLESS refused the attempt. | Show `errorMessage`; follow `retryable`. |
| `AUTH_TERMINATED` | `9106`, with `error.errorCode` for the reason (for example `SIM_NOT_BOUND`) | The transaction is over. | Start a new sign-in. |

### Step 5 (optional): the iOS 27 SIM check

Four functions on `Otpless.shared`. On iOS 26 and below each answers `SIM_CHECK_NOT_SUPPORTED`.

| Function | Use it to |
|---|---|
| `checkSimBinding(completion:)` | Ask whether the number the SDK last bound has an active plan on this phone. Answers `bound`, `notBound` or `unknown` (with a reason), or `NO_BOUND_NUMBER` if nothing was bound yet. |
| `requestNumberStatusPermission(phoneNumber:completion:)` | Show Apple's permission dialog for a number, after your own explanation. Answers `granted`, `denied` or `unavailable`. |
| `setSimBindingListener(intervalSeconds:listener:)` | Be told when the answer changes. Calls back only on a change. |
| `removeSimBindingListener()` | Stop the listener. |

Things to know about the permission:

- Apple asks once per number, and the phone must hold that number. For any other number Apple shows "Phone number
  mismatch" with no Allow button, and the result is `denied`.
- Settings has no switch for it. The only way back after **Not Now** is to ask again, so offer a way to do that.
- Reinstalling the app clears it.
- In the OTP with SIM bind flow the SDK asks for you, before the OTP screen. It never asks again for a number that is
  already allowed.

---

## 5. Test

Use a real iPhone with a SIM, against your **staging** app, with a number that is **in that phone**.

**SMS binding** (needs your app enabled and routed):

- [ ] Sign in with the number on the phone's SIM, send the message: you get `ONETAP`.
- [ ] Close the message screen without sending: `VERIFY` `SMS_SEND_FAILED`, retryable.
- [ ] Wait too long before sending: `TOKEN_EXPIRED`.
- [ ] Send from a different SIM (dual-SIM phone): `NUMBER_MISMATCH`.
- [ ] Airplane mode or no SIM: `NO_SIM`.
- [ ] Retry after a retryable failure: a new attempt starts and can succeed.
- [ ] Repeat attempts until OTPLESS blocks the device: an `INITIATE` with `7184`.
- [ ] Your screen shows no OTP field for SMS binding and treats any `INITIATE` with an `errorCode` as a failure.

**OTP with SIM bind** (iOS 27, needs routing):

- [ ] Apple's permission dialog appears **before** your OTP field. Tap Allow, enter the code, and you sign in.
- [ ] Sign in again with the same number: no dialog this time.
- [ ] Tap Not Now (or use a number the phone does not hold), then verify the code: the sign-in ends or continues with
      SMS binding as OTPLESS decides. A failure is never shown as a success.

**Regression:**

- [ ] Normal phone and OTP sign-in is unchanged: correct code signs in, wrong code shows an error.

**iOS 27 SIM check** (if you use it):

- [ ] The permission request for the phone's own number returns `granted`, and `checkSimBinding` returns `bound`.
- [ ] A number the phone does not hold returns `denied`.
- [ ] On iOS 26 and below, each call answers `SIM_CHECK_NOT_SUPPORTED`.

---

## 6. Known limits of the alpha

- OTPLESS decides the routing. Confirm it for your app before you test.
- A dual-SIM phone is handled (`NUMBER_MISMATCH`), but the SDK does not pick the SIM for the user. Tell the user in your own text.
- Tested on iOS 27.0.1 and iOS 26.7. iOS 17 and 18 are not yet tested.
- A real `notBound` result, a removed SIM and an eSIM moved to another phone have not yet been seen on a device.
- The API may still change before the stable release. OTPLESS will tell you if it does.
- Not on the CocoaPods trunk. Use the tag.

---

## 7. Going live

1. **Finish testing on staging.** Every item in the checklist above passes on real devices, including at least one iPhone on iOS 27 if you use the OTP with SIM bind flow or the SIM check.
2. **Move to the stable release.** An alpha is for testing only. When OTPLESS announces the stable `3.2.0`, update your dependency to it, rebuild, and run the checklist again.
3. **Ask OTPLESS to enable production.** Send the production **App ID**. OTPLESS enables SMS binding and sets the rules and routing for production, which is separate from staging.
4. **Check your fallbacks before release.** Every failure that cannot be retried must lead the user to another sign-in method, and every `INITIATE` with an `errorCode` must show a message.
5. **Release gradually.** Use a phased release in the App Store, and start with a small share of users.
6. **Watch the first days.** Track how many sign-ins reach SMS binding, how many succeed, and which error codes appear most (especially `7184`, `7185`, `NO_SIM` and `SMS_SEND_FAILED`). Send OTPLESS the numbers if anything looks off.
7. **Know how to switch it off.** If something goes wrong, ask OTPLESS to disable SMS binding for your app. Your sign-in goes back to how it behaved before, with no app release needed.

---

## 8. Support

Contact your OTPLESS representative with your App ID, the environment, the time of the attempt, the phone's iOS version, and any logs. For issues in the SMS or permission steps, say which step failed and what the user saw.
