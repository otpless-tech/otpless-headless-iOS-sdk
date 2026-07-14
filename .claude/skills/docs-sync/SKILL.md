---
name: docs-sync
description: Sync CHANGELOG.md (and, once it exists, docs/SDK-GUIDE.md) with OtplessBM code changes. Use whenever code in Sources/OtplessBM/ has changed and documentation must be refreshed, or after merging any PR that touches it.
---

# Documentation sync protocol (CHANGELOG-only, for now)

`docs/SDK-GUIDE.md` does not exist on this branch yet — it is being authored in a parallel PR (`feat/sdk-guide`, opened as PR #41). **This skill currently only covers `CHANGELOG.md`.** Once the guide PR merges, extend this skill (and `scripts/docs-verify.sh`) with guide-sync steps analogous to the Android `otpless-headless-android-lite` exemplar's `docs-sync` skill: a `docs/.doc-sync-state` SHA-tracking file, a source-file → guide-section map, the "removed/deprecated API — mark, never delete" history rule, and a per-dependency documentation checklist. Do not invent guide content here before that PR exists — describe what changed in the PR body instead.

## 1. Determine what changed

```bash
git log --oneline origin/main..HEAD
git diff origin/main..HEAD --stat -- Sources/OtplessBM/ CHANGELOG.md Package.swift OtplessBM.podspec
```

## 2. Update `CHANGELOG.md`

- **Unreleased work:** accumulate entries under the `## Unreleased` heading at the top (this PR adds that heading — it did not exist before). One bullet per merged PR, phrased as user-visible behavior where applicable, with the PR number: `(#NN — title)`. Prefix internal-only work "Repo & tooling" — a future public-docs automation may consume these bullets, so write for that audience even before it exists here.
- **On a version bump:** rename `## Unreleased` to `## <version> (<date>)` and follow the **release** skill's full procedure — including updating `Constants.SDK_VERSION`, not just `OtplessBM.podspec`'s `s.version` (see CLAUDE.md's Known findings for why this specific pair drifted once already).
- Never rewrite history for already-released versions; only append. `scripts/hooks/changelog-history-guard.py` enforces this mechanically — it will block an Edit/Write that changes text under an already-released `## <version>` heading.
- **Breaking changes** get a bold `**BREAKING:**` prefix — both `otpless-rn-lite` and `otpless-rn-full` are pinned to this SDK and their maintainers read this file.

## 3. Dependency changes

If `Package.swift`, `Package.resolved`, or a podspec dependency version changed, follow the **bump-dependency** skill's per-dependency checklist (§1) — it covers exactly what to verify and what to record here. Don't re-derive it in this skill.

## 4. Verify before finishing

Run `bash scripts/docs-verify.sh` — currently checks the CHANGELOG heading vs. the podspec version, CLAUDE.md/Makefile gate-line consistency, and (as of this PR) a version-consistency `WARN` across `OtplessBM.podspec`, the latest git tag, and `Constants.SDK_VERSION`. It must report no new `FAIL` before this run is considered done — a `WARN` that already existed (the pre-existing `2.3.1`/`2.3.2` drift) is known and tracked, not something this skill should try to fix as a side effect unless the PR is specifically about that.

## 5. Once `docs/SDK-GUIDE.md` exists (follow-up, not yet actionable)

Port from `otpless-headless-android-lite/.claude/skills/docs-sync/SKILL.md`:
- The `docs/.doc-sync-state` SHA-tracking mechanism and `[docs-sync]` commit convention.
- A source-file → guide-section map for this repo's layout.
- The "mark, never delete" rule for removed/deprecated public API.
- Extend `scripts/docs-verify.sh` with guide-vs-source checks (e.g. the guide's public-API list vs. `api-baseline/OtplessBM.json`, the guide's error-code table vs. `OtplessConstant.swift`, the guide's response-type list vs. `ResponseTypes.swift`).
