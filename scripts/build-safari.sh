#!/bin/bash
# Builds CastnetSafari.appex (Safari web extension) with Command Line Tools only.
#   scripts/build-safari.sh <output-dir> <version> <build-number> [sign-identity]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$1"; VERSION="$2"; BUILD="$3"; IDENT="${4:--}"
APPEX="$OUT/CastnetSafari.appex"
WORK="$ROOT/dist/build/safari"
rm -rf "$APPEX" "$WORK"; mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources" "$WORK"

for a in arm64 x86_64; do
  swiftc -module-name CastnetSafari -parse-as-library -application-extension -O \
    -target "$a-apple-macos13.0" "$ROOT/app/SafariExtension/SafariWebExtensionHandler.swift" \
    -framework SafariServices -framework AppKit \
    -Xlinker -e -Xlinker _NSExtensionMain -o "$WORK/CastnetSafari-$a" 2>&1 | grep -v "search path" || true
done
lipo -create "$WORK/CastnetSafari-arm64" "$WORK/CastnetSafari-x86_64" -output "$APPEX/Contents/MacOS/CastnetSafari"
cp -R "$ROOT/dist/extensions/safari/" "$APPEX/Contents/Resources/"

cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>app.castnet.mac.safari</string>
  <key>CFBundleExecutable</key><string>CastnetSafari</string>
  <key>CFBundleName</key><string>Castnet</string>
  <key>CFBundleDisplayName</key><string>Castnet</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHumanReadableDescription</key><string>Download videos and files from any site with Castnet.</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.Safari.web-extension</string>
    <key>NSExtensionPrincipalClass</key><string>CastnetSafari.SafariWebExtensionHandler</string>
  </dict>
</dict>
</plist>
PLIST

cat > "$WORK/safari.entitlements" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.network.client</key><true/>
  <!-- only to read the bridge's port + token, written by the Castnet app -->
  <key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key>
  <array><string>/Library/Application Support/Castnet/</string></array>
</dict></plist>
ENT
if [ "$IDENT" = "-" ]; then
  codesign --force --sign - --entitlements "$WORK/safari.entitlements" "$APPEX"
else
  codesign --force --options runtime --timestamp --sign "$IDENT" --entitlements "$WORK/safari.entitlements" "$APPEX"
fi
echo "built $APPEX"
