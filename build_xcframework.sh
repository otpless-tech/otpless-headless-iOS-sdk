#!/bin/bash
set -e

SCHEME="OtplessBM"
CONFIGURATION="${1:-Debug}"
BUILD_DIR="$(pwd)/build"
XCFRAMEWORK_OUTPUT="$(pwd)/XCFramework/OtplessBM.xcframework"

echo "Building XCFramework (configuration: $CONFIGURATION)..."
rm -rf "$BUILD_DIR" "$(pwd)/XCFramework"
mkdir -p "$(pwd)/XCFramework"

build_slice() {
  local PLATFORM=$1
  local DESTINATION=$2
  local DERIVED="$BUILD_DIR/$PLATFORM"

  echo "Building for $PLATFORM..." >&2
  xcodebuild build \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED" \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    SKIP_INSTALL=NO \
    2>&1 | grep -e "error:" -e "BUILD" >&2

  local PRODUCTS="$DERIVED/Build/Products/$CONFIGURATION-$PLATFORM"
  local FW="$PRODUCTS/PackageFrameworks/OtplessBM.framework"
  local MODULES_SRC="$PRODUCTS/OtplessBM.swiftmodule"

  if [ ! -d "$FW" ]; then
    echo "ERROR: Framework not found at $FW" >&2; exit 1
  fi

  if [ -d "$MODULES_SRC" ]; then
    mkdir -p "$FW/Modules/OtplessBM.swiftmodule"
    cp "$MODULES_SRC"/*.swiftinterface "$FW/Modules/OtplessBM.swiftmodule/" 2>/dev/null || true
    cp "$MODULES_SRC"/*.swiftdoc       "$FW/Modules/OtplessBM.swiftmodule/" 2>/dev/null || true
    cp "$MODULES_SRC"/*.abi.json       "$FW/Modules/OtplessBM.swiftmodule/" 2>/dev/null || true
    echo "  Modules injected: OK" >&2
  else
    echo "  WARNING: swiftmodule not found at $MODULES_SRC" >&2
  fi

  echo "$FW"
}

IOS_FW=$(build_slice "iphoneos" "generic/platform=iOS")
SIM_FW=$(build_slice "iphonesimulator" "generic/platform=iOS Simulator")

echo "iOS:       $IOS_FW"
echo "Simulator: $SIM_FW"

echo "Creating XCFramework..."
xcodebuild -create-xcframework \
  -framework "$IOS_FW" \
  -framework "$SIM_FW" \
  -output "$XCFRAMEWORK_OUTPUT"

rm -rf "$BUILD_DIR"

echo ""
echo "Done! XCFramework ($CONFIGURATION) at: $XCFRAMEWORK_OUTPUT"
echo "Contents:"
find "$XCFRAMEWORK_OUTPUT" -type f | sort
