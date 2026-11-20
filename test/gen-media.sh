#!/bin/bash
# Generates test media served by test/server.js:
#   progressive.mp4         ~25 MB H.264/AAC file (segmented-download test)
#   hls-aes/master.m3u8     2-variant HLS, MPEG-TS, AES-128 encrypted
#   hls-fmp4/master.m3u8    fMP4/CMAF HLS with a separate audio rendition
#   dash/manifest.mpd       DASH, separate video/audio, SegmentTemplate+Timeline
#   page.html               test page with a <video>, an HLS player stub and JSON-embedded URLs
set -euo pipefail
OUT="${1:?usage: gen-media.sh OUTDIR}"
mkdir -p "$OUT"
cd "$OUT"
FF="ffmpeg -hide_banner -loglevel error -y"

SRC="-f lavfi -i testsrc2=size=1280x720:rate=30:duration=30 -f lavfi -i sine=frequency=440:sample_rate=48000:duration=30"

echo "progressive.mp4"
$FF $SRC -c:v libx264 -preset ultrafast -b:v 6M -pix_fmt yuv420p -c:a aac -b:a 128k -movflags +faststart progressive.mp4

echo "hls-aes"
mkdir -p hls-aes
head -c 16 /dev/urandom > hls-aes/enc.key
# keyinfo: line 1 = key URI written into the playlist (relative), line 2 = key file. No IV line,
# so ffmpeg uses the segment sequence number as IV, which exercises the HLS default-IV rule.
printf 'enc.key\n%s\n' "$PWD/hls-aes/enc.key" > hls-aes/keyinfo
$FF $SRC -filter_complex "[0:v]split=2[a][b];[b]scale=640:360[s]" \
  -map "[a]" -map 1:a -map "[s]" -map 1:a \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -b:a 96k \
  -b:v:0 3M -b:v:1 800k \
  -f hls -hls_time 4 -hls_playlist_type vod -hls_key_info_file hls-aes/keyinfo \
  -var_stream_map "v:0,a:0,name:720p v:1,a:1,name:360p" \
  -master_pl_name master.m3u8 -hls_segment_filename "hls-aes/%v_%03d.ts" "hls-aes/%v.m3u8"

echo "hls-fmp4"
mkdir -p hls-fmp4
$FF $SRC -map 0:v -map 1:a -c:v libx264 -preset ultrafast -pix_fmt yuv420p -b:v 2M -c:a aac -b:a 128k \
  -f hls -hls_time 4 -hls_playlist_type vod -hls_segment_type fmp4 \
  -var_stream_map "v:0,agroup:aud,name:video a:0,agroup:aud,name:audio,default:yes" \
  -master_pl_name master.m3u8 -hls_fmp4_init_filename "%v_init.mp4" \
  -hls_segment_filename "hls-fmp4/%v_%03d.m4s" "hls-fmp4/%v.m3u8"

echo "dash"
mkdir -p dash
$FF $SRC -map 0:v -map 1:a -c:v libx264 -preset ultrafast -pix_fmt yuv420p -b:v 2M -c:a aac -b:a 128k \
  -f dash -seg_duration 4 -use_template 1 -use_timeline 1 -adaptation_sets "id=0,streams=v id=1,streams=a" \
  dash/manifest.mpd

echo "non-faststart MP4 and WebM (track probe tests)"
$FF -i progressive.mp4 -c copy nofast.mp4
$FF -f lavfi -i testsrc2=size=854x480:rate=25:duration=6 -f lavfi -i sine=duration=6 -c:v libvpx-vp9 -b:v 1M -deadline realtime -c:a libopus av.webm
$FF -i av.webm -map 0:v -c copy vonly.webm

echo "split video/audio (Facebook/Reddit style)"
$FF -i progressive.mp4 -map 0:v -c copy -movflags +faststart vonly.mp4
$FF -i progressive.mp4 -map 0:a -c copy -movflags +faststart aonly.mp4

cat > split.html <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>Split Stream Test</title></head>
<body style="font-family: -apple-system; margin: 40px">
<h1>Separate video and audio</h1>
<video id="v" width="640" height="360" controls muted poster=""></video>
<script>
  // Like Facebook/Instagram players: fetch byte ranges of a video-only and an audio-only file
  // (the audio one carries its range in the query string), then play through MediaSource.
  fetch('/vonly.mp4', { headers: { Range: 'bytes=0-262143' } });
  fetch('/aonly.mp4?bytestart=0&byteend=65535');
  document.getElementById('v').src = '/vonly.mp4';
</script>
</body></html>
HTML

cat > page.html <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>Castnet Test Page</title>
<meta property="og:video" content="/progressive.mp4">
</head>
<body style="font-family: -apple-system; margin: 40px">
<h1>Castnet test page</h1>
<video id="v" src="/progressive.mp4" width="640" height="360" controls muted></video>
<p>Files: <a href="/progressive.mp4" download="Test clip.mp4">Test clip</a> ·
  <a href="/aonly.mp4">Soundtrack</a> · <a href="/split.html">Another page</a> ·
  <a href="/hls-aes/enc.key">Key file</a></p>
<script>
  // Player config embedded as JSON (escaped slashes), like many real sites.
  window.__player = {"hls":"http:\/\/127.0.0.1:8765\/hls-aes\/master.m3u8","dash":"http:\/\/127.0.0.1:8765\/dash\/manifest.mpd"};
  // Stream URL delivered through an API call (only visible to the fetch hook).
  fetch('/api/player.json').then(r => r.json()).then(j => { window.__api = j; });
</script>
</body></html>
HTML
cat > player.json <<'JSON'
{"title":"Test","sources":[{"type":"application/x-mpegURL","src":"http://127.0.0.1:8765/hls-fmp4/master.m3u8"}]}
JSON
ls -la "$OUT" | head -20
