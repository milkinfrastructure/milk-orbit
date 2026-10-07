#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v xcodebuild >/dev/null; then
    echo "Building the iOS app requires macOS and Xcode. Select Xcode with DEVELOPER_DIR if needed." >&2
    exit 1
fi
sdk_version="$(xcrun --sdk iphonesimulator --show-sdk-version)"
sdk_major="${sdk_version%%.*}"
sdk_minor="${sdk_version#*.}"
sdk_minor="${sdk_minor%%.*}"
if (( sdk_major < 27 || (sdk_major == 27 && sdk_minor < 2) )); then
    echo "MilkOrbit needs the iOS 27.2 SDK (Xcode 27.2 or later). Set DEVELOPER_DIR to a compatible Xcode." >&2
    exit 1
fi
xcodebuild -project MilkOrbit.xcodeproj -scheme MilkOrbit \
    -configuration "${CONFIGURATION:-Debug}" -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "${DERIVED_DATA_PATH:-DerivedData}" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO build
