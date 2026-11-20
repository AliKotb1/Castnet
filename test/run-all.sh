#!/bin/bash
# Full test run: extension unit tests + engine tests against locally generated media.
#   ./test/run-all.sh            (needs ffmpeg, node; builds dist/ first if missing)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d -t castnet-test)"
CLI="$ROOT/dist/Castnet.app/Contents/MacOS/castnet-cli"
PORT=8765
fails=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; fails=$((fails + 1)); }

[ -x "$CLI" ] || "$ROOT/scripts/build.sh"
echo "== generating media in $WORK"
"$ROOT/test/gen-media.sh" "$WORK/media" >/dev/null
node "$ROOT/test/server.js" "$WORK/media" $PORT >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; rm -rf "$WORK"' EXIT
sleep 1

echo "== extension unit tests"
node "$ROOT/test/ext-unit.mjs" "$WORK/media" | tail -1 | grep -q 'passed' && pass "$(node "$ROOT/test/ext-unit.mjs" "$WORK/media" | tail -1)" || fail "extension unit tests"

echo "== engine"
OUT="$WORK/out"; mkdir -p "$OUT"
REF=$(shasum -a 256 "$WORK/media/progressive.mp4" | cut -d' ' -f1)
sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
height() { ffprobe -v error -select_streams v -show_entries stream=height -of csv=p=0 "$1" 2>/dev/null; }
streams() { ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$1" 2>/dev/null | sort | tr '\n' ' '; }

"$CLI" --connections 8 --out "$OUT" --name multi.mp4 "http://127.0.0.1:$PORT/slow/progressive.mp4" >/dev/null 2>&1
[ "$(sha "$OUT/multi.mp4")" = "$REF" ] && pass "8-connection download is byte-identical" || fail "8-connection download"

"$CLI" --connections 3 --test-pause 2 --out "$OUT" --name resumed.mp4 "http://127.0.0.1:$PORT/slow/progressive.mp4" >/dev/null 2>&1
[ "$(sha "$OUT/resumed.mp4")" = "$REF" ] && pass "pause + resume is byte-identical" || fail "pause + resume"

"$CLI" --out "$OUT" --name denied.mp4 "http://127.0.0.1:$PORT/protected/progressive.mp4" >/dev/null 2>&1
[ ! -f "$OUT/denied.mp4" ] && pass "protected URL refused without browser headers" || fail "protected URL should 403"
"$CLI" --out "$OUT" --name auth.mp4 --referer "http://127.0.0.1:$PORT/page.html" --cookie session=letmein \
  "http://127.0.0.1:$PORT/protected/progressive.mp4" >/dev/null 2>&1
[ "$(sha "$OUT/auth.mp4")" = "$REF" ] && pass "Referer + cookie replay unlocks protected URL" || fail "Referer + cookie replay"

"$CLI" --out "$OUT" --name hls.mp4 "http://127.0.0.1:$PORT/hls-aes/master.m3u8" >/dev/null 2>&1
[ "$(height "$OUT/hls.mp4")" = "720" ] && pass "HLS AES-128 → MP4 (best = 720p)" || fail "HLS AES-128"
"$CLI" --out "$OUT" --name hls360.mp4 --quality 360 "http://127.0.0.1:$PORT/hls-aes/master.m3u8" >/dev/null 2>&1
[ "$(height "$OUT/hls360.mp4")" = "360" ] && pass "HLS quality selection (360p)" || fail "HLS quality selection"
"$CLI" --out "$OUT" --name fmp4.mp4 "http://127.0.0.1:$PORT/hls-fmp4/master.m3u8" >/dev/null 2>&1
[ "$(streams "$OUT/fmp4.mp4")" = "audio video " ] && pass "HLS fMP4 + separate audio merged" || fail "HLS fMP4 + audio"
"$CLI" --out "$OUT" --name dash.mp4 "http://127.0.0.1:$PORT/dash/manifest.mpd" >/dev/null 2>&1
[ "$(streams "$OUT/dash.mp4")" = "audio video " ] && pass "DASH video + audio merged" || fail "DASH"

kill $SERVER; sleep 0.5; node "$ROOT/test/server.js" "$WORK/media" $PORT >/dev/null 2>&1 & SERVER=$!; sleep 1
"$CLI" --out "$OUT" --name live.mp4 "http://127.0.0.1:$PORT/live.m3u8" >/dev/null 2>&1 & LP=$!
sleep 4; kill -INT $LP; wait $LP
[ -s "$OUT/live.mp4" ] && pass "live HLS recorded and saved on stop" || fail "live HLS"

for f in hls hls360 fmp4 dash live; do
  [ -f "$OUT/$f.mp4" ] && [ -z "$(ffmpeg -v error -i "$OUT/$f.mp4" -f null - 2>&1 | head -1)" ] || { fail "$f.mp4 decodes cleanly"; continue; }
done
pass "all stream outputs decode without errors"

echo "== download manager (queues, scheduler, duplicates, batch, quarantine)"
SELFTEST="$(swift build -c release --arch arm64 --arch x86_64 --package-path "$ROOT/app" --show-bin-path 2>/dev/null)/castnet-selftest"
[ -x "$SELFTEST" ] || swift build -c release --arch arm64 --arch x86_64 --package-path "$ROOT/app" --product castnet-selftest >/dev/null 2>&1
mkdir -p "$WORK/selftest"
if CASTNET_HOME="$WORK/selftest" "$SELFTEST" "http://127.0.0.1:$PORT" > "$WORK/selftest.log" 2>&1; then
  pass "download manager self-test ($(grep -c '✓' "$WORK/selftest.log") checks)"
else
  fail "download manager self-test"; grep '✗' "$WORK/selftest.log"
fi

echo
[ $fails -eq 0 ] && echo "ALL TESTS PASSED" || echo "$fails FAILED"
exit $fails
