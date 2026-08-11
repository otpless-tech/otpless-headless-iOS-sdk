---
name: docs-sync
description: Sync CHANGELOG.md with OtplessBM code changes, and decide whether the change needs a companion Atlas PR. Use whenever code in Sources/OtplessBM/ has changed and documentation must be refreshed, or after merging any PR that touches it.
---

# Documentation sync protocol

This repo owns exactly one documentation file: **`CHANGELOG.md`**. Everything else — the prose description of this SDK's architecture, flows, response/error contract, telemetry — lives in `otpless-tech/atlas` under `repos/otpless-headless-iOS-sdk/`, and **Atlas is the only home for it**. There is no `docs/` directory here and one must not be reintroduced.

So this skill has two halves: update `CHANGELOG.md` here (§2), then decide whether an Atlas page needs a companion PR (§5).

## 1. Determine what changed

```bash
git log --oneline origin/main..HEAD
git diff origin/main..HEAD --stat -- Sources/OtplessBM/ CHANGELOG.md Package.swift OtplessBM.podspec
```

## 2. Update `CHANGELOG.md`

- **Unreleased work:** accumulate entries under the `## Unreleased` heading at the top (this PR adds that heading — it did not exist before). One bullet per merged PR, phrased as user-visible behavior where applicable, with the PR number: `(#NN — title)`. Prefix internal-only work "Repo & tooling" — a future public-docs automation may consume these bullets, so write for that audience even before it exists here.
- **On a version bump:** rename `## Unreleased` to `## <version> (<date>)` and follow the **release** skill's full procedure — including updating `Constants.SDK_VERSION`, not just `OtplessBM.podspec`'s `s.version` (see CLAUDE.md's Known findings for why this specific pair drifted once already).
- Never rewrite history for already-released versions; only append. `scripts/hooks/changelog-history-guard.py` enforces this mechanically — it will block an Edit/Write that changes text under an already-released `## <version>` heading.
- **Breaking changes** get a bold `**BREAKING:**` prefix — both `react-native-headless-lite` and `react-native-headless-sdk` are pinned to this SDK and their maintainers read this file.

## 3. Dependency changes

If `Package.swift`, `Package.resolved`, or a podspec dependency version changed, follow the **bump-dependency** skill's per-dependency checklist (§1) — it covers exactly what to verify and what to record here. Don't re-derive it in this skill.

## 4. Verify before finishing

Run `bash scripts/docs-verify.sh` — currently checks the CHANGELOG heading vs. the podspec version, CLAUDE.md/Makefile gate-line consistency, and (as of this PR) a version-consistency `WARN` across `OtplessBM.podspec`, the latest git tag, and `Constants.SDK_VERSION`. It must report no new `FAIL` before this run is considered done — a `WARN` that already existed (the pre-existing `2.3.1`/`2.3.2` drift) is known and tracked, not something this skill should try to fix as a side effect unless the PR is specifically about that.

## 5. Decide the Atlas side

`.github/workflows/atlas-docs.yml` calls Atlas's `verify-docs.yml` on every PR here, so a stale Atlas page shows up as a **failing status on your PR** — that check, not `make gate`, is the authority on documentation freshness (`scripts/docs-verify.sh` is deliberately source-side-only; it has no Atlas checkout to compare against).

- **`generated: true` pages** (mechanical extractions named in Atlas's `.atlas/manifest.yml`) regenerate themselves from this repo's source on merge to `main` — do **not** hand-edit them, and do not try to pre-generate them here.
- **Authored/narrative pages** never auto-update. If your change makes one wrong — a new public method, a changed response key, a new error code, a new dependency, a changed telemetry payload — open a companion PR against `otpless-tech/atlas` in the same cycle and link it from this PR. "The page is stale but the code is right" is not an acceptable end state.
- **Removed or deprecated public API:** mark it in the Atlas page (with the replacement and the deprecating version), never delete the entry — merchants on older versions still read it.
- **Caveat:** Atlas's `.atlas/manifest.yml` has no entry for this repo yet, so today the `verify` job has no rules to enforce and cannot catch a stale page for you. Until that row lands, doing §5 by hand is the only thing keeping Atlas true — and note in the PR body what you checked.
