#!/bin/bash
# Builds, signs, notarizes, and packages DevSweep.app into a DMG,
# then (optionally) publishes a GitHub release.
#
# Prereqs:
#   - "Developer ID Application" certificate in the login keychain
#   - a notarytool keychain profile (once):
#       xcrun notarytool store-credentials <profile> --key <AuthKey.p8> \
#           --key-id <id> --issuer <issuer>   # ASC key, Developer role or higher
#   - xcodegen, gh (only needed for --publish)
#
# Usage:
#   scripts/release.sh            # build + notarize + DMG
#   scripts/release.sh --publish  # ...and create a GitHub release

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="DevSweep"
NOTARY_ARGS=(--keychain-profile "${NOTARY_PROFILE:-devsweep-notary}")

VERSION=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
APP="$BUILD_DIR/$APP_NAME.app"
DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

echo "==> Releasing $APP_NAME $VERSION"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Generating project and archiving (Release)"
xcodegen generate
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
    -configuration Release -archivePath "$ARCHIVE" archive | tail -3

# Manual signing already produced a Developer-ID-signed, hardened-runtime,
# timestamped app inside the archive — use it directly.
cp -R "$ARCHIVE/Products/Applications/$APP_NAME.app" "$APP"

echo "==> Notarizing app"
ditto -c -k --keepParent "$APP" "$BUILD_DIR/$APP_NAME.zip"
xcrun notarytool submit "$BUILD_DIR/$APP_NAME.zip" "${NOTARY_ARGS[@]}" --wait
xcrun stapler staple "$APP"

echo "==> Building DMG"
DMG_ROOT="$BUILD_DIR/dmg-root"
mkdir -p "$DMG_ROOT"
cp -R "$APP" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG"

echo "==> Signing and notarizing DMG"
codesign --sign "Developer ID Application" --timestamp "$DMG"
xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
xcrun stapler staple "$DMG"

echo "==> Verifying Gatekeeper acceptance"
spctl -a -t open --context context:primary-signature -v "$DMG"

echo "==> Done: $DMG"

if [[ "${1:-}" == "--publish" ]]; then
    echo "==> Publishing GitHub release v$VERSION"
    gh release create "v$VERSION" "$DMG" \
        --title "$APP_NAME $VERSION" \
        --generate-notes
fi
