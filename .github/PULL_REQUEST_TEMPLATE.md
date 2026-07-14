## What & why

<!-- What does this PR change, and why? Link an issue if one exists. -->

## Constitution checklist

<!-- See CLAUDE.md's "SDK development constitution" for the full rules behind each item. -->

- [ ] No public API/response-contract change, or `bash scripts/check-api-baseline.sh --update` run + `api-baseline/OtplessBM.json` committed + CHANGELOG.md updated + wrapper impact checked against **both** `otpless-rn-lite` and `otpless-rn-full` (both pin this iOS SDK)
- [ ] Both distributions verified: `bash scripts/build.sh` (SPM) AND `pod lib lint OtplessBM.podspec --allow-warnings` (CocoaPods, all 3 subspecs) — not just one
- [ ] Source-size delta considered (no binary artifact to measure yet — see the size-review skill) and any new dependency challenged per constitution article 5
- [ ] New collected data documented in `Sources/PrivacyInfo.xcprivacy`, or none added
- [ ] `CHANGELOG.md` `## Unreleased` entry added
- [ ] `bash scripts/docs-verify.sh` run — no new `WARN`/`FAIL` beyond the pre-existing, tracked ones (see CLAUDE.md's Known findings)

## Parity statement (hub rule: Android ↔ iOS parity)

<!-- Required for any phone-number-auth-related or response-contract change. One of:
     "Parity: ported from <android-repo>#NN"
     "Parity: N/A — <reason>"
     "Parity: port ticket <link>" -->

## Flows exercised

<!-- List what you actually ran (bash scripts/build.sh, pod lib lint, a scratch Xcode/Podfile project, etc.).
     This repo has no sample app — state plainly if a flow (SNA, deep link, passkey, Apple/Google/Facebook
     sign-in) needs a physical device/simulator and wasn't run. -->
