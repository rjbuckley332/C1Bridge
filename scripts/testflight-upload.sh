#!/bin/zsh
# Archives C1Bridge and uploads it straight to TestFlight (App Store Connect).
#
# One-time setup:
#   1. App Store Connect → Users and Access → Integrations → App Store Connect API
#      → generate a key. Download the AuthKey_<KEY_ID>.p8 file into
#      ~/.appstoreconnect/private_keys/
#   2. Note the Key ID and the Issuer ID (same page).
#   3. export ASC_KEY_ID / ASC_ISSUER_ID before running (or pass them inline).
#
# Usage:  ASC_KEY_ID=... ASC_ISSUER_ID=... ./scripts/testflight-upload.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# Self-source credentials when not already in the environment (2026-08-17
# lesson: asc.env sets vars WITHOUT export, so a plain `source` in the
# caller never reaches this child process — set -a is required).
if [[ -z "${ASC_KEY_ID:-}" && -f "$HOME/.appstoreconnect/asc.env" ]]; then
  set -a; source "$HOME/.appstoreconnect/asc.env"; set +a
fi

ASC_KEY_ID="${ASC_KEY_ID:?Set ASC_KEY_ID (App Store Connect API key id)}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:?Set ASC_ISSUER_ID (App Store Connect issuer id)}"
KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"

if [[ ! -f "$KEY_PATH" ]]; then
  echo "Missing API key file: $KEY_PATH" >&2
  echo "Download AuthKey_${ASC_KEY_ID}.p8 from App Store Connect and place it there." >&2
  exit 1
fi

BUILD_DIR="build/testflight"
ARCHIVE="$BUILD_DIR/C1Bridge.xcarchive"
mkdir -p "$BUILD_DIR"

echo "== Archiving (Release, version $(grep -m1 'MARKETING_VERSION' C1Bridge.xcodeproj/project.pbxproj | sed 's/[^0-9.]//g') build $(grep -m1 'CURRENT_PROJECT_VERSION' C1Bridge.xcodeproj/project.pbxproj | sed 's/[^0-9]//g')) =="
xcodebuild -project C1Bridge.xcodeproj -scheme C1Bridge \
  -destination 'generic/platform=iOS' -configuration Release \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  archive

cat > "$BUILD_DIR/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>export</string>
	<key>teamID</key>
	<string>XB8JG6VJUS</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
PLIST

echo "== Exporting IPA locally =="
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$BUILD_DIR/export" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

echo "== Uploading to App Store Connect (altool transport — the destination=upload path hangs on this host, 2026-08-14) =="
xcrun altool --upload-app \
  -f "$BUILD_DIR/export/C1Bridge.ipa" \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID"

echo "== Uploaded. TestFlight processing usually takes 5-15 minutes; watch for the email. =="
