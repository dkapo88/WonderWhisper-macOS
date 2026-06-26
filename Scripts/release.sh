#!/bin/bash
# Build, sign, notarize, and publish a HermesWhisper release.
#
# Usage:  Scripts/release.sh [TAG]
#   TAG defaults to today's date (e.g. 2026-06-26).
#
# Prereqs (one-time):
#   - "Developer ID Application: Dane Kapoor (44WC3UNX99)" in the keychain
#   - notarytool profile "HermesWhisper" (xcrun notarytool store-credentials HermesWhisper ...)
#   - gh authed for dkapo88/hermeswhisper
#   - Release notes written to  dist/HermesWhisper-$TAG.release-notes.md
#
# Why archive/export and not `xcodebuild build`: a plain build injects the
# com.apple.security.get-task-allow debug entitlement, which Apple's notary
# service REJECTS ("Archive contains critical validation errors"). Exporting
# the archive with method=developer-id strips it. Don't "simplify" this back
# to a direct build + manual codesign.

set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:-$(date +%Y-%m-%d)}"
TITLE="HermesWhisper $TAG"
DMG="dist/HermesWhisper-$TAG.dmg"
NOTES="dist/HermesWhisper-$TAG.release-notes.md"
IDENTITY="Developer ID Application: Dane Kapoor (44WC3UNX99)"
PROFILE="HermesWhisper"
REPO="dkapo88/hermeswhisper"

[ -f "$NOTES" ] || { echo "Missing release notes: $NOTES (write it first)"; exit 1; }

echo "==> Archiving Release"
rm -rf build/HermesWhisper.xcarchive
xcodebuild archive -project HermesWhisper.xcodeproj -scheme HermesWhisper \
  -configuration Release -archivePath build/HermesWhisper.xcarchive -derivedDataPath build/

echo "==> Exporting (developer-id)"
PLIST="$(mktemp -d)/ExportOptions.plist"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>44WC3UNX99</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$IDENTITY</string>
</dict></plist>
EOF
rm -rf build/export
xcodebuild -exportArchive -archivePath build/HermesWhisper.xcarchive \
  -exportPath build/export -exportOptionsPlist "$PLIST"

# Fail loudly if the debug entitlement slipped through (notary would reject it).
if codesign -d --entitlements - --xml build/export/HermesWhisper.app 2>/dev/null \
   | plutil -p - 2>/dev/null | grep -qi "get-task-allow"; then
  echo "ERROR: get-task-allow present in exported app; notarization would fail."; exit 1
fi

echo "==> Packaging + signing DMG"
mkdir -p dist
STAGE="$(mktemp -d)"
cp -R build/export/HermesWhisper.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "HermesWhisper" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

echo "==> Notarizing (waits for Apple)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -vv -t open --context context:primary-signature "$DMG"

echo "==> Publishing GitHub release"
git fetch --tags origin
git tag -a "$TAG" -m "$TITLE" 2>/dev/null || true
git push origin "$TAG"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG" --repo "$REPO" --clobber
  gh release edit "$TAG" --repo "$REPO" --title "$TITLE" --notes-file "$NOTES" --latest
else
  gh release create "$TAG" "$DMG" --repo "$REPO" --title "$TITLE" --notes-file "$NOTES" --latest
fi
echo "==> Done: https://github.com/$REPO/releases/tag/$TAG"
