#!/bin/bash
# Sign with Developer ID, notarize and staple, producing a zip that installs cleanly.
#
# One-time setup (stores an app-specific password in the keychain):
#   xcrun notarytool store-credentials lifecg-notary \
#     --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-password>
#
# Then:
#   SIGN_ID="Developer ID Application: <Org> (<TEAMID>)" VERSION=1.0.0 app/scripts/notarize.sh
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
: "${SIGN_ID:?set SIGN_ID to your Developer ID Application identity}"
PROFILE="${NOTARY_PROFILE:-lifecg-notary}"
VERSION="${VERSION:-0.1.0}"

SIGN_ID="$SIGN_ID" VERSION="$VERSION" "$APP_DIR/scripts/build-app.sh"
ZIP="$APP_DIR/build/LifeCG-$VERSION.zip"
ditto -c -k --keepParent "$APP_DIR/build/LifeCG.app" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP_DIR/build/LifeCG.app"
rm "$ZIP" && ditto -c -k --keepParent "$APP_DIR/build/LifeCG.app" "$ZIP"
spctl --assess --type execute --verbose "$APP_DIR/build/LifeCG.app"
echo "Notarized: $ZIP"
