#!/bin/bash
# Installs Castnet from the DMG into a temporary "Applications" folder and checks that it works
# on its own: every tool runs inside a sandbox that hides Homebrew/MacPorts/usr-local.
#   test/dmg-test.sh dist/Castnet-1.3.0.dmg [media-dir]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG="$1"
MEDIA="${2:-}"
WORK="$(mktemp -d -t castnet-dmg)"
SB=(sandbox-exec -f "$ROOT/test/clean-mac.sb")
fails=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; fails=$((fails + 1)); }

echo "== installing from $(basename "$DMG")"
MOUNT="$(hdiutil attach -nobrowse -readonly -noautoopen "$DMG" | sed -n 's|.*\(/Volumes/.*\)$|\1|p' | head -1)"
ls "$MOUNT"
[ -L "$MOUNT/Applications" ] && pass "DMG has the app and an Applications shortcut" || fail "Applications shortcut missing"
mkdir -p "$WORK/Applications"
ditto "$MOUNT/Castnet.app" "$WORK/Applications/Castnet.app"
hdiutil detach -quiet "$MOUNT"
APP="$WORK/Applications/Castnet.app"
H="$APP/Contents/Helpers"

codesign --verify --deep --strict "$APP" 2>/dev/null && pass "code signature valid" || fail "code signature"
for b in MacOS/Castnet MacOS/castnet-host MacOS/castnet-cli Helpers/yt-dlp Helpers/ffmpeg Helpers/ffprobe Helpers/qjs PlugIns/CastnetSafari.appex/Contents/MacOS/CastnetSafari; do
  a="$(lipo -archs "$APP/Contents/$b" 2>/dev/null)"
  [[ "$a" == *arm64* && "$a" == *x86_64* ]] || { fail "$b is not universal"; continue; }
done && pass "all 8 executables are universal (Apple Silicon + Intel)"
[ -f "$APP/Contents/Resources/Extension/manifest.json" ] && pass "Chrome-family extension is inside the app" || fail "extension missing"
[ -f "$APP/Contents/Resources/Firefox/Castnet.xpi" ] && pass "Firefox/Zen add-on is inside the app" || fail "Firefox add-on missing"
[ -f "$APP/Contents/PlugIns/CastnetSafari.appex/Contents/Resources/manifest.json" ] && codesign --verify "$APP/Contents/PlugIns/CastnetSafari.appex" 2>/dev/null \
  && pass "Safari extension (signed, sandboxed) is inside the app" || fail "Safari extension"

echo "== tools run with Homebrew hidden"
"${SB[@]}" "$H/ffmpeg" -hide_banner -version >/dev/null 2>&1 && pass "ffmpeg $(cat "$APP/Contents/Resources/ffmpeg.version")" || fail "ffmpeg"
"${SB[@]}" "$H/qjs" -e 'console.log(1)' >/dev/null 2>&1 && pass "QuickJS" || fail "QuickJS"
v=$("${SB[@]}" "$H/yt-dlp" --version --ignore-config 2>/dev/null) && pass "yt-dlp $v" || fail "yt-dlp"
arch -x86_64 "$H/ffmpeg" -hide_banner -version >/dev/null 2>&1 && arch -x86_64 "$H/qjs" -e '1' >/dev/null 2>&1 \
  && pass "Intel slices run (Rosetta)" || fail "Intel slices"

echo "== YouTube with only built-in tools"
OUT="$WORK/out"; mkdir -p "$OUT"
list=$(CASTNET_DEBUG=1 "${SB[@]}" "$APP/Contents/MacOS/castnet-cli" --formats "https://www.youtube.com/watch?v=aqz-KE-bpKQ" 2>&1)
echo "$list" | sed 's/^/     /' | head -14
echo "$list" | grep -q "1080p" && pass "full quality list (incl. 1080p)" || fail "quality list"
echo "$list" | grep "^tools:" | grep -q "Helpers\|Application Support/Castnet" && ! echo "$list" | grep "^tools:" | grep -q homebrew \
  && pass "used Castnet's own yt-dlp + QuickJS + ffmpeg" || fail "tool paths"
cat > "$WORK/req.json" <<JSON
{"url":"https://www.youtube.com/watch?v=aqz-KE-bpKQ","kind":"ytdlp","filename":"Big Buck Bunny [144p].mp4","format":"160+140","container":"mp4","useCookies":false}
JSON
"${SB[@]}" "$APP/Contents/MacOS/castnet-cli" --request "$WORK/req.json" --out "$OUT" >/dev/null 2>&1
f="$OUT/Big Buck Bunny [144p].mp4"
codecs=$("${SB[@]}" "$H/ffprobe" -v error -show_entries stream=codec_name -of csv=p=0 "$f" 2>/dev/null | tr '\n' ' ')
[ "$codecs" = "h264 aac " ] && pass "YouTube 144p downloaded and merged into MP4 (h264 + aac)" || fail "YouTube download ($codecs)"

if [ -n "$MEDIA" ]; then
  echo "== local streams with only built-in tools"
  node "$ROOT/test/server.js" "$MEDIA" 8765 >/dev/null 2>&1 & SRV=$!
  sleep 1
  "${SB[@]}" "$APP/Contents/MacOS/castnet-cli" --out "$OUT" --name hls.mp4 http://127.0.0.1:8765/hls-aes/master.m3u8 >/dev/null 2>&1
  [ "$("${SB[@]}" "$H/ffprobe" -v error -show_entries stream=codec_type -of csv=p=0 "$OUT/hls.mp4" 2>/dev/null | sort | tr '\n' ' ')" = "audio video " ] \
    && pass "encrypted HLS → MP4" || fail "HLS"
  "${SB[@]}" "$APP/Contents/MacOS/castnet-cli" --out "$OUT" --name split.mp4 --audio http://127.0.0.1:8765/aonly.mp4 http://127.0.0.1:8765/vonly.mp4 >/dev/null 2>&1
  [ "$("${SB[@]}" "$H/ffprobe" -v error -show_entries stream=codec_type -of csv=p=0 "$OUT/split.mp4" 2>/dev/null | sort | tr '\n' ' ')" = "audio video " ] \
    && pass "separate video + audio merged" || fail "merge"
  "${SB[@]}" "$APP/Contents/MacOS/castnet-cli" --out "$OUT" --name dash.mp4 http://127.0.0.1:8765/dash/manifest.mpd >/dev/null 2>&1
  [ -s "$OUT/dash.mp4" ] && pass "DASH → MP4" || fail "DASH"
  kill $SRV 2>/dev/null
fi

rm -rf "$WORK"
echo
[ $fails -eq 0 ] && echo "DMG TEST PASSED" || echo "$fails FAILED"
exit $fails
