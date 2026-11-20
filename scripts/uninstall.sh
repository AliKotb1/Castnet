#!/bin/bash
# Removes Castnet.app, its native-messaging registrations and its saved state.
# Downloaded files are left alone.
set -uo pipefail
HOST_NAME="app.castnet.host"

osascript -e 'tell application id "app.castnet.mac" to quit' >/dev/null 2>&1 || pkill -x Castnet || true
for d in "/Applications/Castnet.app" "$HOME/Applications/Castnet.app"; do
  [ -d "$d" ] && rm -rf "$d" && echo "removed $d"
done
find "$HOME/Library/Application Support" -maxdepth 4 -path "*NativeMessagingHosts/$HOST_NAME.json" -print -delete 2>/dev/null
rm -rf "$HOME/Library/Application Support/Castnet" "$HOME/Library/Caches/Castnet"
defaults delete app.castnet.mac >/dev/null 2>&1 || true
echo "Castnet removed. Remove the extension from chrome://extensions yourself."
