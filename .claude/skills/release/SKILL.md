---
name: release
description: Cut a release of otpless-headless-iOS-sdk (OtplessBM) — version bump (ALL locations, not just the podspec), API baseline check, changelog promotion, tag, pod trunk push. Use when asked to release, bump the SDK version, publish OtplessBM, or prepare a release PR.
---

# Release procedure

This repo's git history (`git log --oneline | grep -i version`) shows every past release as a plain "version bump" commit — there is no in-repo publish script or CI publish job today. Follow in order; stop and report if any step fails.

## 1. Pre-flight

- Working tree clean, on an up-to-date `main` (or a release branch cut from it).
- `make gate` passes (see the **verify** skill).
- Wrapper check: if this release changes the response contract or public API, confirm **both** `otpless-rn-lite` and `otpless-rn-full` (the hub topology: both pin this iOS SDK) have a coordinated plan. Breaking entries in the changelog must carry `**BREAKING:**`.
- Once `docs/SDK-GUIDE.md` exists: confirm it's current before releasing (run the docs-sync skill first if not). It does not exist yet on this branch — skip this check until the parallel guide PR (`feat/sdk-guide`) merges.

## 2. Version bump — ALL locations, not just the podspec

**This repo has (at least) two places version strings live, and they were already found out of sync once** (see CLAUDE.md's "Known findings": `Constants.SDK_VERSION` reporting `2.3.1` while the podspec said `2.3.2`, silently under-reporting in telemetry). Update every one of these in the same commit:

1. **`OtplessBM.podspec`** → `s.version = '<new version>'`. This is the mechanical source of truth `scripts/docs-verify.sh` checks the CHANGELOG and `Constants.SDK_VERSION` against.
2. **`Sources/OtplessBM/utils/Constants.swift`** → `SDK_VERSION = "<new version>"`. This value ships in every telemetry event via `DeviceInfoUtils.swift`'s `params["sdkVersion"] = Constants.SDK_VERSION` — if it's wrong, every analytics/telemetry consumer reading that field is misled about which SDK version actually ran.
3. **Git tag** (see step 5) — SPM has no in-repo version file; consumers resolve `from: "<version>"` purely against tags. The tag must match #1 and #2, or SPM/CocoaPods/telemetry consumers will each report/resolve a different "current version."

Run `bash scripts/docs-verify.sh` after bumping — it will report `PASS` on all three checks once they agree (today it reports one `WARN` for the pre-existing #1/#2 drift; that `WARN` should disappear once you've bumped both `s.version` and `Constants.SDK_VERSION` to the same new value).

Semver: patch = fixes, minor = additive features, major = anything breaking (see the constitution in CLAUDE.md — "when in doubt, it's breaking").

## 3. API baseline

```bash
bash scripts/check-api-baseline.sh --update   # only if this release has a public-API change
```

If the diagnose step (`bash scripts/check-api-baseline.sh`, no `--update`) reported no changes since the last regular PR-time check, there's nothing new to do here — the baseline should already be current. Only regenerate if this release itself introduces a public-API change that wasn't already captured.

## 4. Build & verify both distributions

```bash
bash scripts/build.sh
pod lib lint OtplessBM.podspec --allow-warnings
```

Both must pass — SPM and CocoaPods consumers are both real distribution channels for this SDK (see CLAUDE.md's "Build & test"). `pod lib lint` is disk-intensive; make sure there's headroom before running it (see CLAUDE.md's known findings for what a disk-pressure failure looks like — don't mistake it for a real lint regression).

## 5. Changelog promotion

In `CHANGELOG.md`: rename `## Unreleased` to `## <version> (<date>)` (matching this repo's existing heading style — see any prior entry), listing the actual changes since the last release. Never rewrite history for already-released versions; only append a new heading above them. **Breaking changes** get a bold `**BREAKING:**` prefix. `scripts/hooks/changelog-history-guard.py` will block any edit to text under an already-released heading — if it fires unexpectedly, you're editing something you shouldn't be.

## 6. Tag & publish

```bash
git tag <version>            # e.g. git tag 2.3.3 — matches the existing bare-version tag convention (see: git tag --list)
git push origin <version>
```

- **SPM** needs nothing beyond the pushed tag — consumers pinning `from: "<version>"` resolve directly from it. No build/upload step.
- **CocoaPods** additionally needs `pod trunk push OtplessBM.podspec --allow-warnings` from a machine with a registered CocoaPods Trunk session for this pod (`pod trunk me` shows current session state — check this before assuming you can push). This repo's history shows no evidence of an automated publish job; treat this as a manual, human-run step until one exists.

## 7. Finalize

- Commit the version bump + changelog (normal code-review flow).
- Check the hub's Android ↔ iOS parity rule: does this release need a corresponding Android-side change/port statement, or does it close out one already in flight?
- If the release included public-API changes, confirm the wrapper-SDK check from step 1 actually happened (not just planned) before announcing.
