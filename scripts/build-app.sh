#!/bin/sh
# Builds build/OpenMind.app from the Xcode project.
#
#   ./scripts/build-app.sh              release build, ad-hoc signed
#   ./scripts/build-app.sh --install    …and copy it to /Applications
#   CODESIGN_IDENTITY="Developer ID Application: …" ./scripts/build-app.sh
#
# With ad-hoc signing macOS ties permissions (e.g. Accessibility, Automation)
# to this exact build, so they have to be granted again after each rebuild.
# Signing with a stable identity (Apple Development / Developer ID) avoids that.
set -eu
cd "$(dirname "$0")/.."

# xcodebuild ships only with Xcode, not the Command Line Tools: prefer Xcode's
# toolchain when DEVELOPER_DIR is not already set.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

APP=build/OpenMind.app
DERIVED_DATA=build/DerivedData
BUILT_APP="$DERIVED_DATA/Build/Products/Release/OpenMind.app"

# Ad-hoc sign the build so it runs locally without a paid developer account.
# Pass the identity through xcodebuild (rather than re-signing afterwards) so
# the sealed resource envelope stays valid.
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    xcodebuild -project OpenMind.xcodeproj -scheme OpenMind -configuration Release \
        -destination 'platform=macOS,name=My Mac' \
        -derivedDataPath "$DERIVED_DATA" build \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="$CODESIGN_IDENTITY" \
        OTHER_CODE_SIGN_FLAGS="--options runtime --timestamp"
else
    xcodebuild -project OpenMind.xcodeproj -scheme OpenMind -configuration Release \
        -destination 'platform=macOS,name=My Mac' \
        -derivedDataPath "$DERIVED_DATA" build \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="-"
fi

rm -rf "$APP"
mkdir -p build
ditto "$BUILT_APP" "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    pkill -x OpenMind 2>/dev/null || true
    # Give the old process a moment to exit; opening the new bundle while
    # LaunchServices still tracks the dying instance fails with -600.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x OpenMind >/dev/null 2>&1 || break
        sleep 0.2
    done
    rm -rf /Applications/OpenMind.app
    ditto "$APP" /Applications/OpenMind.app
    # Refresh LaunchServices so `open` finds the new bundle, then retry once
    # in case the first open races the registration.
    /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f /Applications/OpenMind.app 2>/dev/null || true
    open /Applications/OpenMind.app || (sleep 1; open /Applications/OpenMind.app)
    echo "Installed /Applications/OpenMind.app"
fi
