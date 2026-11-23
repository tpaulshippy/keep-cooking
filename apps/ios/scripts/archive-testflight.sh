#!/bin/zsh
# Archive Smidgen and export for TestFlight (App Store distribution).
# Local fallback when Xcode Cloud is unavailable.
#
# Upload set: app + widgets + share ONLY (org.smidgen.app, .widgets, .share).
# NOTE: SmidgenWatch (org.smidgen.app.watch) is a standalone watchOS app and
# is intentionally NOT uploaded (pair at distribution time).
#
# Env (all overridable):
#   TEAM_ID            Apple Developer Portal Team ID (default KRF39C6NC9)
#   BUILD_NUMBER       build number, passed as CURRENT_PROJECT_VERSION —
#                      bump for EVERY upload (Apple rejects re-uploads).
#                      Default 1 (local/dev only).
#   MARKETING_VERSION  marketing version, default 1.0.
#   ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH
#                      App Store Connect API key for -allowProvisioningUpdates
#                      (lets Xcode fetch/create profiles automatically).
#
# Automatic signing is forced on the command line (CODE_SIGN_STYLE=Automatic
# + DEVELOPMENT_TEAM) rather than verseloop's single-target manual style,
# because Smidgen archives appex targets (widgets/share) that need their own
# managed profiles.
set -euo pipefail
cd "$(dirname "$0")/.."   # apps/ios
: "${TEAM_ID:=KRF39C6NC9}"
: "${BUILD_NUMBER:=1}"
: "${MARKETING_VERSION:=1.0}"
: "${ASC_KEY_ID:?set ASC_KEY_ID to your App Store Connect API key ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID to your App Store Connect issuer ID}"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH to your .p8 private key path}"
ARCHIVE="build/Smidgen.xcarchive"
xcodebuild archive \
  -project Smidgen.xcodeproj -scheme Smidgen \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM_ID" \
  MARKETING_VERSION="$MARKETING_VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/TestFlight \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
echo "IPA at build/TestFlight/. Upload with Transporter or Xcode Organizer."
