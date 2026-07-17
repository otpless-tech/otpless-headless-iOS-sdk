#!/bin/bash
set -e

# ─────────────────────────────────────────────
# Usage: ./release.sh <version>
# Example: ./release.sh 2.1.1
# ─────────────────────────────────────────────

VERSION=$1
REPO="otpless-tech/otpless-headless-iOS-sdk"
XCFRAMEWORK_NAME="OtplessBM.xcframework"
ZIP_NAME="OtplessBM.xcframework.zip"
XCFRAMEWORK_PATH="$(pwd)/XCFramework/$XCFRAMEWORK_NAME"
ZIP_PATH="$(pwd)/XCFramework/$ZIP_NAME"

# ── Validate ──────────────────────────────────
if [ -z "$VERSION" ]; then
  echo "Usage: ./release.sh <version>"
  exit 1
fi

if ! command -v gh &>/dev/null; then
  echo "ERROR: gh CLI not installed. Run: brew install gh"
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "ERROR: Working tree is dirty. Commit or stash changes first."
  exit 1
fi

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "main" ]; then
  echo "ERROR: Must be on main branch (currently on $CURRENT_BRANCH)"
  exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Releasing OtplessBM v$VERSION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Step 1: Build Release XCFramework ─────────
echo "▶ [1/7] Building Release XCFramework..."
bash "$(pwd)/build_xcframework.sh" Release
echo "  ✓ XCFramework built"

# ── Step 2: Zip XCFramework ───────────────────
echo "▶ [2/7] Zipping XCFramework..."
rm -f "$ZIP_PATH"
cd "$(pwd)/XCFramework"
zip -r -q "$ZIP_NAME" "$XCFRAMEWORK_NAME"
cd - > /dev/null
echo "  ✓ Zipped: $ZIP_PATH"

# ── Step 3: Compute checksum ──────────────────
echo "▶ [3/7] Computing SHA256 checksum..."
CHECKSUM=$(swift package compute-checksum "$ZIP_PATH")
echo "  ✓ Checksum: $CHECKSUM"

# ── Step 4: Update Package.swift + podspec ────
echo "▶ [4/7] Updating Package.swift and podspec..."

DOWNLOAD_URL="https://github.com/$REPO/releases/download/$VERSION/$ZIP_NAME"

cat > Package.swift << EOF
// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "OtplessBM",
    platforms: [
        .iOS(.v13)
    ],
    products: [
        .library(
            name: "OtplessBM",
            targets: ["OtplessBM"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "OtplessBM",
            url: "$DOWNLOAD_URL",
            checksum: "$CHECKSUM"
        ),
    ]
)
EOF

# Bump version in podspec
sed -i '' "s/s\.version.*=.*/s.version          = '$VERSION'/" OtplessBM.podspec

echo "  ✓ Package.swift → binary target ($DOWNLOAD_URL)"
echo "  ✓ podspec version → $VERSION"

# ── Step 5: Commit + push ─────────────────────
echo "▶ [5/7] Committing and pushing..."
git add Package.swift OtplessBM.podspec
git commit -m "release: v$VERSION"
git push origin main
echo "  ✓ Pushed to main"

# ── Step 6: Tag + GitHub Release ──────────────
echo "▶ [6/7] Creating git tag and GitHub Release..."
git tag "$VERSION"
git push origin "$VERSION"

gh release create "$VERSION" \
  "$ZIP_PATH" \
  --title "OtplessBM $VERSION" \
  --notes "## OtplessBM $VERSION" \
  --latest

echo "  ✓ GitHub Release created: https://github.com/$REPO/releases/tag/$VERSION"

# ── Step 7: Pod trunk push ────────────────────
echo "▶ [7/7] Publishing to CocoaPods..."
pod lib lint OtplessBM.podspec --allow-warnings 2>&1 | tail -3
pod spec lint OtplessBM.podspec --allow-warnings 2>&1 | tail -3
pod trunk push OtplessBM.podspec --allow-warnings 2>&1 | tail -5

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✓ OtplessBM v$VERSION released!"
echo "  CocoaPods: pod 'OtplessBM', '~> $VERSION'"
echo "  SPM:       https://github.com/$REPO"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
