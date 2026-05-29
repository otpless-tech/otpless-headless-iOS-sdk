#!/bin/bash
set -e

SCHEME="OtplessBM"
OUTPUT_DIR="$(pwd)/build"
XCFRAMEWORK_OUTPUT="$(pwd)/XCFramework/OtplessBM.xcframework"

echo "Cleaning previous build..."
rm -rf "$OUTPUT_DIR"
rm -rf "$(pwd)/XCFramework"
mkdir -p "$OUTPUT_DIR"
mkdir -p "$(pwd)/XCFramework"

echo "Archiving for iOS device..."
xcodebuild archive \
  -scheme "$SCHEME" \
  -destination "generic/platform=iOS" \
  -archivePath "$OUTPUT_DIR/OtplessBM-iOS" \
  -configuration Release \
  SKIP_INSTALL=NO \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
  | grep -E "error:|warning:|Build|Compiling|Linking|Archive" | grep -v "^note:"

echo "Archiving for iOS Simulator..."
xcodebuild archive \
  -scheme "$SCHEME" \
  -destination "generic/platform=iOS Simulator" \
  -archivePath "$OUTPUT_DIR/OtplessBM-Simulator" \
  -configuration Release \
  SKIP_INSTALL=NO \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
  | grep -E "error:|warning:|Build|Compiling|Linking|Archive" | grep -v "^note:"

echo "Creating XCFramework..."
xcodebuild -create-xcframework \
  -framework "$OUTPUT_DIR/OtplessBM-iOS.xcarchive/Products/usr/local/lib/OtplessBM.framework" \
  -framework "$OUTPUT_DIR/OtplessBM-Simulator.xcarchive/Products/usr/local/lib/OtplessBM.framework" \
  -output "$XCFRAMEWORK_OUTPUT"

echo "Cleaning build artifacts..."
rm -rf "$OUTPUT_DIR"

echo "Done! XCFramework at: $XCFRAMEWORK_OUTPUT"
