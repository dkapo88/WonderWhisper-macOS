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
APPCAST="appcast.xml"
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/WonderWhisper-$TAG.dmg"

# Sparkle compares CFBundleVersion to decide whether an update exists, so every release
# must report a distinct, INCREASING value. Derive it from the date tag (naturally
# monotonic) as YYYYMMDDNN, where NN is a zero-padded same-day revision:
#   2026-07-25    -> 2026072500
#   2026-07-25.1  -> 2026072501
#   2026-08-01    -> 2026080100
# The suffix must be zero-padded: a bare concatenation makes 2026-07-25.1 (202607251)
# sort ABOVE 2026-08-01 (20260801), which would strand every later release as "older"
# and silently stop offering updates.
TAG_DATE="${TAG%%.*}"
TAG_REV="${TAG#"$TAG_DATE"}"
TAG_REV="${TAG_REV#.}"
TAG_REV="${TAG_REV:-0}"
TAG_DIGITS="$(printf '%s' "$TAG_DATE" | tr -d '-')"
case "$TAG_DIGITS" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
  *) echo "ERROR: tag '$TAG' must start with a YYYY-MM-DD date (got '$TAG_DATE')."; exit 1 ;;
esac
case "$TAG_REV" in
  [0-9]|[0-9][0-9]) ;;
  *) echo "ERROR: tag '$TAG' revision suffix must be 0-99 (got '$TAG_REV')."; exit 1 ;;
esac
BUILD_VERSION="$(printf '%s%02d' "$TAG_DIGITS" "$TAG_REV")"

[ -f "$NOTES" ] || { echo "Missing release notes: $NOTES (write it first)"; exit 1; }
[ -z "$(git status --porcelain)" ] || {
  echo "ERROR: release from a clean worktree so the signed artifact matches its Git tag."
  exit 1
}

echo "==> Archiving Release"
rm -rf build/WonderWhisper.xcarchive
xcodebuild archive -project WonderWhisper.xcodeproj -scheme WonderWhisper \
  -configuration Release -archivePath build/WonderWhisper.xcarchive -derivedDataPath build/ \
  -skipPackagePluginValidation \
  MARKETING_VERSION="$TAG" CURRENT_PROJECT_VERSION="$BUILD_VERSION"

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

echo "==> Signing update for Sparkle"
# sign_update ships inside the resolved SPM artifact. Its DerivedData path contains an
# unstable project hash, so locate it rather than hardcoding it.
SIGN_UPDATE="$(find build/SourcePackages/artifacts "$HOME/Library/Developer/Xcode/DerivedData" \
  -type f -path '*/artifacts/sparkle/Sparkle/bin/sign_update' -print -quit 2>/dev/null || true)"
[ -n "$SIGN_UPDATE" ] || {
  echo "ERROR: sign_update not found. Resolve packages first:"
  echo "  xcodebuild -project WonderWhisper.xcodeproj -resolvePackageDependencies"
  exit 1
}

# Signs with the EdDSA private key in the login Keychain (service sparkle-project.org,
# account ed25519). Emits: sparkle:edSignature="..." length="..."
SIGN_OUTPUT="$("$SIGN_UPDATE" "$DMG")"
ED_SIGNATURE="$(printf '%s' "$SIGN_OUTPUT" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')"
DMG_LENGTH="$(printf '%s' "$SIGN_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
[ -n "$ED_SIGNATURE" ] && [ -n "$DMG_LENGTH" ] || {
  echo "ERROR: could not parse sign_update output: $SIGN_OUTPUT"; exit 1
}

# Verify the signature we are about to publish actually validates against the DMG. A bad
# signature here would ship a feed every client silently refuses.
# Argument order matters: sign_update takes <file-path> first, then <verify-signature>.
"$SIGN_UPDATE" --verify "$DMG" "$ED_SIGNATURE" || {
  echo "ERROR: EdDSA signature failed to verify against $DMG"; exit 1
}
echo "Signature verified for $DMG"

echo "==> Updating appcast"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' \
  build/export/WonderWhisper.app/Contents/Info.plist 2>/dev/null || echo '')"
python3 Scripts/update_appcast.py \
  --appcast "$APPCAST" \
  --version "$BUILD_VERSION" \
  --short-version "$TAG" \
  --url "$DOWNLOAD_URL" \
  --signature "$ED_SIGNATURE" \
  --length "$DMG_LENGTH" \
  --notes "$NOTES" \
  --minimum-system-version "$MIN_OS"

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

# Publish the feed only now. The appcast points at the release asset, so committing it
# earlier would advertise an update whose download does not exist yet.
echo "==> Publishing appcast"
if [ -n "$(git status --porcelain "$APPCAST")" ]; then
  git add "$APPCAST"
  git commit -q -m "chore: publish appcast for $TAG"
  git push origin HEAD
  echo "Appcast published for $TAG"
else
  echo "Appcast unchanged; nothing to publish."
fi

echo "==> Done: https://github.com/$REPO/releases/tag/$TAG"
