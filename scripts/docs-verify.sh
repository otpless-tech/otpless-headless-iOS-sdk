#!/usr/bin/env bash
# Mechanical fact-checks for otpless-headless-iOS-sdk. No swift/xcodebuild, no
# network — pure grep/sed over the working tree. Each check prints PASS/FAIL;
# the script exits non-zero if any check fails. Run from the repo root (paths
# below are repo-root-relative).
#
# Used by .github/workflows/build-test.yml and by `make gate` (see the root
# Makefile).
#
# SCOPE: source-side checks only. This repo carries no docs/ directory — the
# prose description of this SDK lives solely in otpless-tech/atlas, under
# repos/otpless-headless-iOS-sdk/. A guide-vs-source check therefore cannot run
# here: there is no Atlas checkout in this repo, and a repo-local copy of the
# guide would only ever verify itself. Atlas owns that check and reports it back
# as a status on the PR — see .github/workflows/atlas-docs.yml, which calls
# otpless-tech/atlas/.github/workflows/verify-docs.yml.
#
# What this script checks, both sides of every comparison being files in THIS
# repo: the CHANGELOG heading vs. the podspec version, gate-line consistency
# between the Makefile and CLAUDE.md, and version consistency across the
# podspec, the latest git tag, and Constants.SDK_VERSION. Add a check here only
# when it stays inside that boundary.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

CHANGELOG="CHANGELOG.md"
PODSPEC="OtplessBM.podspec"
MAKEFILE="Makefile"
CLAUDE_MD="CLAUDE.md"
CONSTANTS_FILE="Sources/OtplessBM/utils/Constants.swift"

EXIT_CODE=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; EXIT_CODE=1; }
# WARN does not affect EXIT_CODE — for known, pre-existing drift that a
# maintainer must deliberately resolve (see CLAUDE.md's "Known findings"),
# not something this script should decide unilaterally by silently fixing.
warn() { echo "WARN: $1"; }

for f in "$CHANGELOG" "$PODSPEC" "$MAKEFILE" "$CLAUDE_MD"; do
  if [ ! -f "$f" ]; then
    fail "required file missing: $f"
  fi
done
if [ "$EXIT_CODE" -ne 0 ]; then
  echo "Aborting: required files missing."
  exit "$EXIT_CODE"
fi

# ---------------------------------------------------------------------------
# 1. CHANGELOG: a heading for the version in OtplessBM.podspec's s.version, or
#    an Unreleased heading.
# ---------------------------------------------------------------------------
PODSPEC_VERSION=$(grep -o "s\.version *= *'[^']*'" "$PODSPEC" | head -1 | sed -E "s/.*'([^']*)'/\1/")

if [ -z "$PODSPEC_VERSION" ]; then
  fail "could not find s.version in $PODSPEC"
else
  if grep -qE "^## ${PODSPEC_VERSION//./\\.} " "$CHANGELOG" || grep -qE '^## Unreleased' "$CHANGELOG"; then
    pass "CHANGELOG.md has a heading for $PODSPEC_VERSION or an Unreleased section"
  else
    fail "CHANGELOG.md has neither a '## $PODSPEC_VERSION' heading nor '## Unreleased'"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Gate-line consistency: every command listed under the Makefile's `gate`
#    target must appear verbatim in CLAUDE.md's documented gate section, so
#    the two can never silently drift.
# ---------------------------------------------------------------------------
GATE_DEPS=$(awk -F': ' '/^gate:/{print $2; exit}' "$MAKEFILE")

if [ -z "$GATE_DEPS" ]; then
  fail "could not find the 'gate:' target's prerequisite list in $MAKEFILE"
else
  MISSING=""
  for dep in $GATE_DEPS; do
    TARGET_LINE=$(awk -v t="^${dep}:" '$0 ~ t {found=1; next} found && NF {print; exit}' "$MAKEFILE")
    # Strip a leading tab/comment markers for a loose containment check.
    TARGET_CMD=$(echo "$TARGET_LINE" | sed -E 's/^\t//; s/^@//')
    if [ -n "$TARGET_CMD" ] && ! grep -qF "$TARGET_CMD" "$CLAUDE_MD"; then
      MISSING="$MISSING $dep"
    fi
  done
  if [ -n "$MISSING" ]; then
    fail "CLAUDE.md's documented gate does not mention the exact command(s) for:$MISSING (Makefile 'gate' prerequisites)"
  else
    pass "CLAUDE.md's documented gate command(s) match the Makefile 'gate' target's prerequisites"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Version consistency: OtplessBM.podspec's s.version, the latest git tag
#    (Package.swift has NO version field of its own — SPM resolves purely
#    from git tags, so a tag matching the podspec version is the SPM-side
#    signal), and Constants.SDK_VERSION (sent in telemetry via
#    DeviceInfoUtils.swift's "sdkVersion" param) should all agree.
#
#    KNOWN DRIFT at time of writing: Constants.SDK_VERSION is "2.3.1" while
#    OtplessBM.podspec is "2.3.2" — found during this PR's review, NOT
#    introduced by it (see CLAUDE.md's "Known findings"). This is a WARN, not
#    a FAIL, so it doesn't red-gate every future PR over a decision only a
#    maintainer can make (which value is correct, and whether to bump it here
#    or treat 2.3.2's telemetry as having under-reported its own version).
#    Promote the Constants.SDK_VERSION check to fail() once that's resolved.
# ---------------------------------------------------------------------------
if [ ! -f "$CONSTANTS_FILE" ]; then
  fail "expected $CONSTANTS_FILE to exist"
elif [ -n "$PODSPEC_VERSION" ]; then
  CONSTANTS_VERSION=$(grep -o 'SDK_VERSION *= *"[^"]*"' "$CONSTANTS_FILE" | head -1 | sed -E 's/.*"([^"]*)"/\1/')
  if [ -z "$CONSTANTS_VERSION" ]; then
    fail "could not find SDK_VERSION in $CONSTANTS_FILE"
  elif [ "$CONSTANTS_VERSION" != "$PODSPEC_VERSION" ]; then
    warn "Constants.SDK_VERSION ($CONSTANTS_VERSION) != OtplessBM.podspec s.version ($PODSPEC_VERSION) — pre-existing drift, not introduced by this PR. This value ships in telemetry (DeviceInfoUtils.swift's 'sdkVersion' param); see CLAUDE.md's Known findings and the release skill before deciding how to fix it."
  else
    pass "Constants.SDK_VERSION matches OtplessBM.podspec s.version ($PODSPEC_VERSION)"
  fi

  LATEST_TAG=$(git tag --sort=-creatordate 2>/dev/null | head -1)
  if [ -z "$LATEST_TAG" ]; then
    warn "no git tags found — cannot cross-check the SPM-resolvable version against $PODSPEC_VERSION"
  elif [ "$LATEST_TAG" != "$PODSPEC_VERSION" ]; then
    warn "latest git tag ($LATEST_TAG) != OtplessBM.podspec s.version ($PODSPEC_VERSION) — SPM consumers resolve strictly from tags, so this is the version they'd actually get for 'latest'."
  else
    pass "latest git tag ($LATEST_TAG) matches OtplessBM.podspec s.version — this is what SPM consumers pinning 'from: \"$LATEST_TAG\"' actually resolve"
  fi
fi

exit "$EXIT_CODE"
