#!/bin/bash
# Builds a self-contained, universal (Apple Silicon + Intel) Castnet.app into ./dist.
# The app carries everything it needs: video-site extractor (yt-dlp), ffmpeg/ffprobe,
# a JavaScript engine (QuickJS) and the browser extension. Nothing else is installed.
#
#   scripts/fetch-vendor.sh   # once: downloads/builds the bundled tools into ./vendor
#   scripts/build.sh          # builds dist/Castnet.app (ad-hoc signed)
#
# Distribution signing (optional): set SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
# to sign with hardened runtime; scripts/make-dmg.sh can then notarize.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SRC="$ROOT/app"
DIST="$ROOT/dist"
APP="$DIST/Castnet.app"
VENDOR="$ROOT/vendor"
VERSION="$(sed -n 's/^public let castnetVersion = "\(.*\)"/\1/p' "$APP_SRC/Sources/CastnetCore/Util.swift")"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
UPDATE_URL="${CASTNET_UPDATE_URL:-}"   # optional JSON feed for "update available" (see Updates.swift)
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

for t in yt-dlp yt-dlp.version ffmpeg ffprobe qjs; do
  [ -e "$VENDOR/bin/$t" ] || { echo "missing vendor/bin/$t: run scripts/fetch-vendor.sh first" >&2; exit 1; }
done

echo "==> Building Swift package (release, universal)"
swift build -c release --arch arm64 --arch x86_64 --package-path "$APP_SRC" 2>&1 \
  | grep -vE "search path '/Library/Developer/CommandLineTools|libswiftCompatibilityPacks|x86_64 architecture is deprecated" || true
BIN="$(swift build -c release --arch arm64 --arch x86_64 --package-path "$APP_SRC" --show-bin-path)"
universal() { local a; a="$(lipo -archs "$1" 2>/dev/null)"; [[ "$a" == *arm64* && "$a" == *x86_64* ]]; }
for exe in Castnet castnet-host castnet-cli; do
  universal "$BIN/$exe" || { echo "build failed: $exe is not universal" >&2; exit 1; }
done

echo "==> Building browser extensions (Chrome, Firefox/Zen, Safari)"
node "$ROOT/scripts/build-extensions.mjs"

echo "==> Rendering icons"
mkdir -p "$DIST/build"
ICONSET="$DIST/build/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
swiftc -O -o "$DIST/build/make-icons" "$ROOT/scripts/make-icons.swift" 2>/dev/null
"$DIST/build/make-icons" "$ICONSET" "$ROOT/extension/icons"
iconutil -c icns -o "$DIST/build/AppIcon.icns" "$ICONSET"

echo "==> Assembling Castnet.app $VERSION ($BUILD_NUMBER)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/Licenses"
cp "$BIN/Castnet" "$BIN/castnet-host" "$BIN/castnet-cli" "$APP/Contents/MacOS/"
# Bundled tools (code lives in Contents/Helpers so it is signed and notarized with the app).
install -m 755 "$VENDOR/bin/yt-dlp" "$VENDOR/bin/ffmpeg" "$VENDOR/bin/ffprobe" "$VENDOR/bin/qjs" "$APP/Contents/Helpers/"
# Version notes live in Resources (Helpers may only contain signed code).
cp "$VENDOR/bin/yt-dlp.version" "$APP/Contents/Resources/"
"$VENDOR/bin/ffmpeg" -hide_banner -version | sed -n 's/^ffmpeg version \([^ ]*\).*/\1/p' > "$APP/Contents/Resources/ffmpeg.version"
# Browser extensions (copied by the app to stable folders the browsers load).
rsync -a --delete --exclude '.DS_Store' "$ROOT/dist/extensions/chrome/" "$APP/Contents/Resources/Extension/"
mkdir -p "$APP/Contents/Resources/Firefox" "$APP/Contents/PlugIns"
# SIGNED_XPI: the add-on as signed by Mozilla (addons.mozilla.org); otherwise the unsigned build.
if [ -n "${SIGNED_XPI:-}" ]; then
  unzip -l "$SIGNED_XPI" | grep -q 'META-INF/' || { echo "SIGNED_XPI isn't signed by Mozilla: $SIGNED_XPI" >&2; exit 1; }
  cp "$SIGNED_XPI" "$APP/Contents/Resources/Firefox/Castnet.xpi"; XPI_SIGNED=true
else
  cp "$ROOT/dist/extensions/Castnet.xpi" "$APP/Contents/Resources/Firefox/Castnet.xpi"; XPI_SIGNED=false
fi
cp "$VENDOR/licenses/"* "$APP/Contents/Resources/Licenses/" 2>/dev/null || true
cp "$DIST/build/AppIcon.icns" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Castnet</string>
  <key>CFBundleDisplayName</key><string>Castnet</string>
  <key>CFBundleIdentifier</key><string>app.castnet.mac</string>
  <key>CFBundleExecutable</key><string>Castnet</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSAppleEventsUsageDescription</key><string>Castnet can shut down your Mac when the downloads you scheduled are finished. It asks System Events to do that.</string>
  <key>NSHumanReadableCopyright</key><string>Castnet $VERSION. Includes yt-dlp (Unlicense), FFmpeg (LGPL 2.1) and QuickJS (MIT); see Contents/Resources/Licenses.</string>
  <key>CastnetUpdateURL</key><string>$UPDATE_URL</string>
  <key>CastnetChromeExtensionIDs</key><string>${CHROME_EXTENSION_IDS:-}</string>
  <key>CastnetFirefoxAddonSigned</key><$XPI_SIGNED/>
</dict>
</plist>
PLIST

echo "==> Code signing ($([ "$SIGN_IDENTITY" = "-" ] && echo "ad-hoc" || echo "$SIGN_IDENTITY"))"
ENT="$DIST/build/entitlements.plist"
cat > "$ENT" <<ENTPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <!-- yt-dlp is a self-extracting Python app: it loads its own unsigned libraries at run time -->
  <key>com.apple.security.cs.disable-library-validation</key><true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
</dict></plist>
ENTPLIST
APPENT="$DIST/build/app-entitlements.plist"
cat > "$APPENT" <<APPENTPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <!-- "Shut down the Mac when done" asks System Events to shut down (hardened runtime needs this) -->
  <key>com.apple.security.automation.apple-events</key><true/>
</dict></plist>
APPENTPLIST
if [ "$SIGN_IDENTITY" = "-" ]; then
  SIGN=(codesign --force --sign -)
else
  SIGN=(codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY")
fi
"${SIGN[@]}" --entitlements "$ENT" "$APP/Contents/Helpers/yt-dlp"
for f in ffmpeg ffprobe qjs; do "${SIGN[@]}" "$APP/Contents/Helpers/$f"; done
"${SIGN[@]}" "$APP/Contents/MacOS/castnet-host" "$APP/Contents/MacOS/castnet-cli"
"$ROOT/scripts/build-safari.sh" "$APP/Contents/PlugIns" "$VERSION" "$BUILD_NUMBER" "$SIGN_IDENTITY" | tail -1
"${SIGN[@]}" --entitlements "$APPENT" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Done: $APP ($(du -sh "$APP" | cut -f1))"
