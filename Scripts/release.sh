#!/bin/bash
# Build, sign, notarize, and publish a WonderWhisper release.
#
# Usage:  Scripts/release.sh [TAG]
#   TAG defaults to today's date (e.g. 2026-06-26).
#
# Prereqs (one-time):
#   - "Developer ID Application: Dane Kapoor (44WC3UNX99)" in the keychain
#   - notarytool profile "HermesWhisper" (retained for signing-credential compatibility)
#   - gh authed for dkapo88/WonderWhisper-macOS
#   - Release notes written to  dist/WonderWhisper-$TAG.release-notes.md
#
# Why archive/export and not `xcodebuild build`: a plain build injects the
# com.apple.security.get-task-allow debug entitlement, which Apple's notary
# service REJECTS ("Archive contains critical validation errors"). Exporting
# the archive with method=developer-id strips it. Don't "simplify" this back
# to a direct build + manual codesign.

set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:-$(date +%Y-%m-%d)}"
TITLE="WonderWhisper $TAG"
DMG="dist/WonderWhisper-$TAG.dmg"
NOTES="dist/WonderWhisper-$TAG.release-notes.md"
IDENTITY="Developer ID Application: Dane Kapoor (44WC3UNX99)"
PROFILE="HermesWhisper"
REPO="dkapo88/WonderWhisper-macOS"

[ -f "$NOTES" ] || { echo "Missing release notes: $NOTES (write it first)"; exit 1; }
[ -z "$(git status --porcelain)" ] || {
  echo "ERROR: release from a clean worktree so the signed artifact matches its Git tag."
  exit 1
}

echo "==> Archiving Release"
rm -rf build/WonderWhisper.xcarchive
xcodebuild archive -project WonderWhisper.xcodeproj -scheme WonderWhisper \
  -configuration Release -archivePath build/WonderWhisper.xcarchive -derivedDataPath build/

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
xcodebuild -exportArchive -archivePath build/WonderWhisper.xcarchive \
  -exportPath build/export -exportOptionsPlist "$PLIST"

# Fail loudly if the debug entitlement slipped through (notary would reject it).
if codesign -d --entitlements - --xml build/export/WonderWhisper.app 2>/dev/null \
   | plutil -p - 2>/dev/null | grep -qi "get-task-allow"; then
  echo "ERROR: get-task-allow present in exported app; notarization would fail."; exit 1
fi

echo "==> Packaging + signing DMG"
mkdir -p dist
STAGE="$(mktemp -d)"
cp -R build/export/WonderWhisper.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "WonderWhisper" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

echo "==> Notarizing (waits for Apple)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -vv -t open --context context:primary-signature "$DMG"

echo "==> Publishing GitHub release"
git fetch --tags origin
if git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
  TAG_COMMIT="$(git rev-list -n 1 "$TAG")"
  HEAD_COMMIT="$(git rev-parse HEAD)"
  if [ "$TAG_COMMIT" != "$HEAD_COMMIT" ]; then
    echo "ERROR: tag $TAG already points to $TAG_COMMIT, not current HEAD $HEAD_COMMIT."
    echo "Choose a new release tag instead of attaching this build to an older commit."
    exit 1
  fi
else
  git tag -a "$TAG" -m "$TITLE"
fi
git push origin "$TAG"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG" --repo "$REPO" --clobber
  gh release edit "$TAG" --repo "$REPO" --title "$TITLE" --notes-file "$NOTES" --latest
else
  gh release create "$TAG" "$DMG" --repo "$REPO" --title "$TITLE" --notes-file "$NOTES" --latest
fi
echo "==> Done: https://github.com/$REPO/releases/tag/$TAG"
