#!/bin/bash
# Packages dist/Castnet.app into dist/Castnet-<version>.dmg: the app plus an Applications
# shortcut, so users install by dragging. Optional notarization for distribution:
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=castnet scripts/make-dmg.sh
# (create the profile once with: xcrun notarytool store-credentials castnet ...)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
"$ROOT/scripts/build.sh"
APP="$DIST/Castnet.app"
VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
DMG="$DIST/Castnet-$VERSION.dmg"
STAGE="$DIST/build/dmg"
RW="$DIST/build/Castnet-rw.dmg"

echo "==> Staging"
rm -rf "$STAGE" "$RW" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Castnet.app"
ln -s /Applications "$STAGE/Applications"
cp "$DIST/build/AppIcon.icns" "$STAGE/.VolumeIcon.icns"

echo "==> Creating disk image"
hdiutil create -quiet -volname "Castnet" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
MOUNT="$(hdiutil attach -nobrowse -noverify -noautoopen "$RW" | sed -n 's|.*\(/Volumes/.*\)$|\1|p' | head -1)"
SETFILE="$(xcrun -f SetFile 2>/dev/null || echo /Library/Developer/CommandLineTools/usr/bin/SetFile)"
"$SETFILE" -a C "$MOUNT" 2>/dev/null || true      # use .VolumeIcon.icns as the disk icon
"$SETFILE" -a V "$MOUNT/.VolumeIcon.icns" 2>/dev/null || true
sync
hdiutil detach -quiet "$MOUNT"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f "$RW"

if [ "${SIGN_IDENTITY:--}" != "-" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "==> Notarizing"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi
hdiutil verify -quiet "$DMG"
echo "==> Done: $DMG ($(du -h "$DMG" | cut -f1))"
