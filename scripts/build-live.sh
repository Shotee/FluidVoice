#!/bin/bash

# Build the isolated Aqua-style streaming prototype.
#
# The Live app has its own bundle identifier and DerivedData directory, so it
# can be installed next to the production FluidVoice build. Signing is supplied
# by the caller's Apple Development/Personal Team certificate; no project file
# changes are required.
#
# Usage:
#   FLUIDVOICE_DEVELOPMENT_TEAM=XXXXXXXXXX ./scripts/build-live.sh
#   FLUIDVOICE_DEVELOPMENT_TEAM=XXXXXXXXXX FLUIDVOICE_LIVE_CONFIGURATION=Release ./scripts/build-live.sh
#   FLUIDVOICE_LIVE_UNSIGNED=1 ./scripts/build-live.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_PATH="${FLUIDVOICE_LIVE_DERIVED_DATA_PATH:-${PROJECT_DIR}/DerivedData/FluidVoiceLive}"
CONFIGURATION="${FLUIDVOICE_LIVE_CONFIGURATION:-Debug}"
DEVELOPMENT_TEAM="${FLUIDVOICE_DEVELOPMENT_TEAM:-${DEVELOPMENT_TEAM:-}}"
CODE_SIGN_IDENTITY="${FLUIDVOICE_LIVE_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-Apple Development}}"
# Passing PRODUCT_NAME on xcodebuild's command line applies it to Swift Package
# targets too, which makes every package emit the same bundle and fails with
# duplicate-output errors. Keep the project's existing product name during the
# build and rename only the final application afterwards.
LIVE_PRODUCT_NAME="FluidVoice Live"
if [ "${CONFIGURATION}" = "Debug" ]; then
    BUILD_PRODUCT_NAME="FluidVoice Debug"
else
    BUILD_PRODUCT_NAME="FluidVoice"
fi

if [ "${FLUIDVOICE_LIVE_UNSIGNED:-0}" != "1" ] && [ -z "${DEVELOPMENT_TEAM}" ]; then
    cat >&2 <<'EOF'
FluidVoice Live requires an Apple Development Personal Team for stable local signing.
Set FLUIDVOICE_DEVELOPMENT_TEAM to the 10-character Team ID, or use
FLUIDVOICE_LIVE_UNSIGNED=1 for a deliberately unsigned test build.
EOF
    exit 2
fi

BUILD_ARGS=(
    -project "${PROJECT_DIR}/Fluid.xcodeproj"
    -scheme Fluid
    -configuration "${CONFIGURATION}"
    -destination 'platform=macOS'
    -derivedDataPath "${DERIVED_DATA_PATH}"
    PRODUCT_BUNDLE_IDENTIFIER=com.shotee.FluidVoiceLive
    # OTHER_SWIFT_FLAGS is passed through to swiftc as -D, keeping the variant
    # opt-in to this build script instead of changing the shared Xcode project.
    OTHER_SWIFT_FLAGS='$(inherited) -DFLUIDVOICE_LIVE_VARIANT'
    build
)

cd "${PROJECT_DIR}"
echo "Building FluidVoice Live (${CONFIGURATION})"
echo "DerivedData: ${DERIVED_DATA_PATH}"

if [ "${FLUIDVOICE_LIVE_UNSIGNED:-0}" = "1" ]; then
    xcodebuild "${BUILD_ARGS[@]}" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
else
    xcodebuild "${BUILD_ARGS[@]}" \
        DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
        CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY}"
fi

PRODUCTS_DIR="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}"
BUILT_APP="${PRODUCTS_DIR}/${BUILD_PRODUCT_NAME}.app"
LIVE_APP="${PRODUCTS_DIR}/${LIVE_PRODUCT_NAME}.app"
BUILT_EXECUTABLE="${BUILT_APP}/Contents/MacOS/${BUILD_PRODUCT_NAME}"
LIVE_EXECUTABLE="${LIVE_APP}/Contents/MacOS/${LIVE_PRODUCT_NAME}"

if [ ! -d "${BUILT_APP}" ] || [ ! -f "${BUILT_EXECUTABLE}" ]; then
    echo "Expected FluidVoice Live build product was not created: ${BUILT_APP}" >&2
    exit 1
fi

if [ -e "${LIVE_APP}" ]; then
    rm -rf "${LIVE_APP}"
fi
mv "${BUILT_APP}" "${LIVE_APP}"
mv "${LIVE_APP}/Contents/MacOS/${BUILD_PRODUCT_NAME}" "${LIVE_EXECUTABLE}"

# Info.plist is generated from the build settings, but the post-build rename
# must also update the executable and user-visible names inside the bundle.
plutil -replace CFBundleExecutable -string "${LIVE_PRODUCT_NAME}" "${LIVE_APP}/Contents/Info.plist"
plutil -replace CFBundleName -string "${LIVE_PRODUCT_NAME}" "${LIVE_APP}/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "${LIVE_PRODUCT_NAME}" "${LIVE_APP}/Contents/Info.plist"

if [ "${FLUIDVOICE_LIVE_UNSIGNED:-0}" != "1" ]; then
    # The rename and plist edits happen after xcodebuild, so refresh the app
    # signature once the final bundle layout is in place.
    codesign --force --deep --sign "${CODE_SIGN_IDENTITY}" --timestamp=none "${LIVE_APP}"
fi

echo "FluidVoice Live app: ${LIVE_APP}"
