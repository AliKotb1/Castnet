#!/bin/bash
# In-app update, end to end: a test copy of Castnet finds a newer version in a (local) update feed,
# downloads it, checks its SHA-256, replaces itself and reopens, and the download list and files
# are still there. A DMG with a wrong checksum must be refused and leave the app as it was.
#   test/app-update-test.sh <scratch-dir>      (test server must run on :8765 with the test media)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$(cd "$1" && pwd)/app-update"
fails=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; fails=$((fails + 1)); }

rm -rf "$S"; mkdir -p "$S/Applications" "$S/new" "$S/feed" "$S/home/Downloads"
APP="$S/Applications/Castnet.app"
ditto "$ROOT/dist/Castnet.app" "$APP"
OLD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

# The "new" version: the same build, marked 9.9.9 and signed again.
ditto "$ROOT/dist/Castnet.app" "$S/new/Castnet.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 9.9.9' "$S/new/Castnet.app/Contents/Info.plist"
codesign --force --sign - --preserve-metadata=entitlements "$S/new/Castnet.app" 2>/dev/null
hdiutil create -quiet -volname Castnet -srcfolder "$S/new" -format UDZO -ov "$S/feed/Castnet-9.9.9.dmg"
SHA="$(shasum -a 256 "$S/feed/Castnet-9.9.9.dmg" | cut -d' ' -f1)"
node "$ROOT/test/server.js" "$S/feed" 8766 >/dev/null 2>&1 & FEEDSRV=$!

export CASTNET_HOME="$S/home" CASTNET_HEADLESS=1
defaults write app.castnet.mac.test CastnetSettings -data "$(printf '{"downloadDirectory":"%s","showDownloadInfoDialog":false}' "$S/home/Downloads" | xxd -p | tr -d '\n')"
host() { python3 - "$APP/Contents/MacOS/castnet-host" "$1" <<'PY'
import json, struct, subprocess, sys
b = sys.argv[2].encode()
o = subprocess.run([sys.argv[1]], input=struct.pack('<I', len(b)) + b, capture_output=True).stdout
print(o[4:4 + struct.unpack('<I', o[:4])[0]].decode() if len(o) >= 4 else '{}')
PY
}
running() { pgrep -f "^$APP/Contents/MacOS/Castnet$" >/dev/null; }
stop_app() { pkill -f "^$APP/Contents/MacOS/Castnet$"; for _ in $(seq 1 20); do running || break; sleep 0.25; done; }

# 1. Some data: a finished download in the list.
"$APP/Contents/MacOS/Castnet" >/dev/null 2>&1 &
sleep 2
host '{"type":"download","confirm":false,"request":{"url":"http://127.0.0.1:8765/aonly.mp4","kind":"file"}}' >/dev/null
for _ in $(seq 1 40); do host '{"type":"list"}' | grep -q '"completed"' && break; sleep 0.25; done
BEFORE="$(host '{"type":"list"}')"
echo "$BEFORE" | grep -q '"completed"' && pass "test copy $OLD has a finished download in its list" || fail "setting up the download list"
stop_app

# 2. A feed whose checksum doesn't match: refused, nothing changes.
printf '{"version":"9.9.9","url":"http://127.0.0.1:8766/Castnet-9.9.9.dmg","sha256":"%s"}' "$(printf '0%.0s' $(seq 1 64))" > "$S/feed/bad.json"
CASTNET_UPDATE_FEED="http://127.0.0.1:8766/bad.json" CASTNET_TEST_AUTO_UPDATE=1 "$APP/Contents/MacOS/Castnet" >/dev/null 2>&1 &
sleep 8
V="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$V" = "$OLD" ] && running && pass "an update with the wrong checksum is refused (still $V, still running)" || fail "wrong checksum ($V)"
stop_app

# 3. The real thing.
printf '{"version":"9.9.9","url":"http://127.0.0.1:8766/Castnet-9.9.9.dmg","sha256":"%s","notes":"Test update"}' "$SHA" > "$S/feed/good.json"
CASTNET_UPDATE_FEED="http://127.0.0.1:8766/good.json" CASTNET_TEST_AUTO_UPDATE=1 "$APP/Contents/MacOS/Castnet" >/dev/null 2>&1 &
for _ in $(seq 1 60); do
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null)" = "9.9.9" ] && break
  sleep 0.5
done
sleep 4
V="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$V" = "9.9.9" ] && pass "downloaded, checked and installed: the app is now $V" || fail "install (version $V)"
codesign --verify --deep --strict "$APP" 2>/dev/null && pass "the installed app's signature is valid" || fail "signature after update"
running && pass "Castnet reopened by itself after the update" || fail "reopen after update"
AFTER="$(host '{"type":"list"}')"
python3 - "$BEFORE" "$AFTER" <<'PY' && pass "the download list is the same as before the update" || fail "download list changed"
import json, sys
a, b = (json.loads(x).get('items', []) for x in sys.argv[1:3])
sys.exit(0 if a and [(i['id'], i['state']) for i in a] == [(i['id'], i['state']) for i in b] else 1)
PY
FILE="$(echo "$AFTER" | python3 -c 'import json,sys; print(json.load(sys.stdin)["items"][0]["outputs"][0])')"
[ -s "$FILE" ] && pass "the downloaded file is still there ($(basename "$FILE"), $(stat -f %z "$FILE") bytes)" || fail "downloaded file missing"
ls "$S/Applications" | grep -q 'Castnet-update' && fail "a leftover staging copy" || pass "no leftover copies next to the app"

stop_app
kill $FEEDSRV 2>/dev/null
defaults delete app.castnet.mac.test 2>/dev/null
echo
[ $fails -eq 0 ] && echo "APP UPDATE TEST PASSED" || echo "$fails CHECK(S) FAILED"
exit $fails
