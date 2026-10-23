#!/usr/bin/env bash
# Archives and exports a signed .ipa. Usage: TEAM_ID=ABCDE12345 scripts/build_ipa.sh
set -euo pipefail
cd "$(dirname "$0")/.."
: "${TEAM_ID:?Set TEAM_ID to your Apple Developer Team ID (Xcode → Settings → Accounts)}"
scripts/bootstrap.sh
BUILD=build
rm -rf "$BUILD"
xcodebuild -project App/MultiverseTree.xcodeproj -scheme MultiverseTree -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$BUILD/MultiverseTree.xcarchive" \
  DEVELOPMENT_TEAM="$TEAM_ID" -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath "$BUILD/MultiverseTree.xcarchive" -exportPath "$BUILD/ipa" \
  -exportOptionsPlist App/ExportOptions.plist -allowProvisioningUpdates
echo "IPA: $BUILD/ipa/MultiverseTree.ipa"
echo "Install on a connected iPhone:  xcrun devicectl device install app --device <UDID> $BUILD/ipa/MultiverseTree.ipa"
echo "List devices:                   xcrun devicectl list devices"
