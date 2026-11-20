#!/bin/bash
# Developer shortcut: installs dist/Castnet.app and registers the native-messaging host.
# Users don't need this: the DMG app does the same setup itself on first launch.
#   ./scripts/install.sh            # build (if needed) + install
#   ./scripts/install.sh --no-build # use the existing dist/Castnet.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXT_ID="jninbfcnkkcefbjldiiiogbajkeohemb"   # fixed by the "key" in extension/manifest.json
HOST_NAME="app.castnet.host"

if [[ "${1:-}" != "--no-build" || ! -d "$ROOT/dist/Castnet.app" ]]; then
  "$ROOT/scripts/build.sh"
fi

# /Applications if writable (admin users), otherwise ~/Applications.
DEST_DIR="/Applications"
[ -w "$DEST_DIR" ] || DEST_DIR="$HOME/Applications"
mkdir -p "$DEST_DIR"
APP="$DEST_DIR/Castnet.app"

if pgrep -x Castnet >/dev/null 2>&1; then
  echo "==> Quitting running Castnet"
  osascript -e 'tell application id "app.castnet.mac" to quit' >/dev/null 2>&1 || pkill -x Castnet || true
  sleep 1
fi

echo "==> Installing $APP"
rm -rf "$APP"
cp -R "$ROOT/dist/Castnet.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
HOST_BIN="$APP/Contents/MacOS/castnet-host"

SUPPORT="$HOME/Library/Application Support"
BROWSERS=(
  "Google/Chrome" "Google/Chrome Beta" "Google/Chrome Dev" "Google/Chrome Canary" "Chromium"
  "Microsoft Edge" "Microsoft Edge Beta" "Microsoft Edge Dev"
  "BraveSoftware/Brave-Browser" "BraveSoftware/Brave-Browser-Beta"
  "Vivaldi" "Arc/User Data" "com.operasoftware.Opera" "Yandex/YandexBrowser" "Thorium"
)
installed=0
for b in "${BROWSERS[@]}"; do
  base="$SUPPORT/$b"
  [ -d "$base" ] || continue
  mkdir -p "$base/NativeMessagingHosts"
  cat > "$base/NativeMessagingHosts/$HOST_NAME.json" <<JSON
{
  "name": "$HOST_NAME",
  "description": "Castnet download manager bridge",
  "path": "$HOST_BIN",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXT_ID/"]
}
JSON
  echo "    registered native host for: $b"
  installed=$((installed + 1))
done
[ $installed -gt 0 ] || echo "    (no Chromium browsers found: install Chrome/Edge/Brave/Arc first, then re-run)"

echo "==> Checking the bridge"
printf '\x0f\x00\x00\x00{"type":"ping"}' | "$HOST_BIN" | tail -c +5; echo

cat <<EOF

Castnet is installed.

Load the browser extension (once per browser):
  1. Open chrome://extensions  (edge://extensions, brave://extensions…)
  2. Turn on "Developer mode" (top right)
  3. Click "Load unpacked" and choose:
       $ROOT/extension
  4. Its ID must be $EXT_ID (it is fixed by the manifest key).
(Developer shortcut. Users install from the DMG; the app sets all of this up itself.)
EOF
