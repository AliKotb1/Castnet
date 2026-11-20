// Unit tests for the extension's pure modules.  Run: node test/ext-unit.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {
  classifyResponse, normalizeMediaUrl, findMediaUrlsInText, filenameFromDisposition, totalSize, looksLikeSegment, KIND,
} from '../extension/lib/detect.js';
import { parseM3U8, parseMPD, parseISODuration, qualityLabel } from '../extension/lib/manifests.js';
import { analyzeMp4, analyzeWebm, tracksOf } from '../extension/lib/probe.js';

let passed = 0;
const t = (name, fn) => { fn(); passed++; console.log(`  ✓ ${name}`); };
const H = (obj) => Object.entries(obj).map(([name, value]) => ({ name, value }));
const resp = (url, headers, statusCode = 200) => ({ url, statusCode, responseHeaders: H(headers), method: 'GET' });

console.log('classifier');
t('progressive mp4 via 206 + Content-Range total', () => {
  const c = classifyResponse(resp('https://cdn.x.com/v/clip.mp4', { 'Content-Type': 'video/mp4', 'Content-Range': 'bytes 0-1023/52428800', 'Content-Length': '1024' }, 206));
  assert.equal(c.kind, KIND.FILE); assert.equal(c.size, 52428800); assert.equal(c.ext, 'mp4');
});
t('HLS by MIME even without extension', () => {
  const c = classifyResponse(resp('https://x.com/api/stream?id=1', { 'Content-Type': 'application/vnd.apple.mpegurl' }));
  assert.equal(c.kind, KIND.HLS);
});
t('HLS by extension with octet-stream MIME', () => {
  assert.equal(classifyResponse(resp('https://x.com/a/index.m3u8?tok=1', { 'Content-Type': 'application/octet-stream' })).kind, KIND.HLS);
});
t('HLS manifest mislabeled text/html', () => {
  assert.equal(classifyResponse(resp('https://x.com/master.m3u8', { 'Content-Type': 'text/html' })).kind, KIND.HLS);
});
t('DASH by MIME', () => {
  assert.equal(classifyResponse(resp('https://x.com/m', { 'Content-Type': 'application/dash+xml' })).kind, KIND.DASH);
});
t('TS / m4s segments are ignored', () => {
  assert.equal(classifyResponse(resp('https://x.com/seg_001.ts', { 'Content-Type': 'video/mp2t', 'Content-Length': '900000' })), null);
  assert.equal(classifyResponse(resp('https://x.com/chunk-stream0-00001.m4s', { 'Content-Type': 'video/mp4', 'Content-Length': '900000' })), null);
  assert.equal(classifyResponse(resp('https://x.com/v/720p/segment12.mp4', { 'Content-Type': 'video/mp4', 'Content-Length': '2000000' })), null);
});
t('tiny files (ads/blips) are ignored', () => {
  assert.equal(classifyResponse(resp('https://ads.x.com/pre.mp4', { 'Content-Type': 'video/mp4', 'Content-Length': '40000' })), null);
});
t('206 without total size waits for a better signal', () => {
  assert.equal(classifyResponse(resp('https://x.com/v.mp4', { 'Content-Type': 'video/mp4' }, 206)), null);
});
t('images, html, json are not media', () => {
  assert.equal(classifyResponse(resp('https://x.com/a.jpg', { 'Content-Type': 'image/jpeg', 'Content-Length': '9000000' })), null);
  assert.equal(classifyResponse(resp('https://x.com/page', { 'Content-Type': 'text/html' })), null);
  assert.equal(classifyResponse(resp('https://x.com/api.json', { 'Content-Type': 'application/json' })), null);
});
t('audio file flagged audioOnly', () => {
  const c = classifyResponse(resp('https://x.com/song', { 'Content-Type': 'audio/mpeg', 'Content-Length': '5000000' }));
  assert.equal(c.kind, KIND.FILE); assert.equal(c.audioOnly, true); assert.equal(c.ext, 'mp3');
});
t('Content-Disposition filename wins', () => {
  const c = classifyResponse(resp('https://x.com/dl?id=9', { 'Content-Type': 'application/octet-stream', 'Content-Disposition': 'attachment; filename="My Movie.mkv"', 'Content-Length': '9000000' }));
  assert.equal(c.filename, 'My Movie.mkv'); assert.equal(c.kind, KIND.FILE); assert.equal(c.ext, 'mkv');
});
t('error statuses ignored', () => {
  assert.equal(classifyResponse(resp('https://x.com/v.mp4', { 'Content-Type': 'video/mp4', 'Content-Length': '9000000' }, 403)), null);
});

console.log('helpers');
t('RFC 5987 filename*', () => assert.equal(filenameFromDisposition("attachment; filename*=UTF-8''caf%C3%A9.mp4"), 'café.mp4'));
t('totalSize prefers Content-Range', () => assert.equal(totalSize(H({ 'Content-Range': 'bytes 0-1/777', 'Content-Length': '2' })), 777));
t('range query params stripped, others untouched', () => {
  assert.equal(normalizeMediaUrl('https://v.x.com/videoplayback?id=1&range=0-1000&sig=AbC%2Fd'), 'https://v.x.com/videoplayback?id=1&sig=AbC%2Fd');
  const signed = 'https://cdn.x.com/v.mp4?Policy=a%2Bb&Signature=c~d#t=10';
  assert.equal(normalizeMediaUrl(signed), 'https://cdn.x.com/v.mp4?Policy=a%2Bb&Signature=c~d');
});
t('segment heuristics', () => {
  assert.ok(looksLikeSegment('https://x.com/a/seg-12.ts'));
  assert.ok(looksLikeSegment('https://x.com/QualityLevels(1)/Fragments(video=0)'));
  assert.ok(!looksLikeSegment('https://x.com/movies/trailer.mp4'));
});
t('URLs inside escaped JSON / JS', () => {
  const text = '{"hls":"https:\\/\\/cdn.ex.com\\/live\\/master.m3u8?token=a\\u0026b=1","img":"https://x.com/a.jpg","mp4":"https://x.com/v/720.mp4"}';
  const found = findMediaUrlsInText(text);
  assert.deepEqual(found.sort(), ['https://cdn.ex.com/live/master.m3u8?token=a&b=1', 'https://x.com/v/720.mp4']);
});

console.log('manifests');
const media = process.argv[2];
t('HLS master: variants sorted, audio renditions', () => {
  const m = parseM3U8(`#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",DEFAULT=YES,URI="a/en.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,AUDIO="aud"
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,FRAME-RATE=60,CODECS="avc1.640028,mp4a.40.2",AUDIO="aud"
https://other.cdn/hi.m3u8
`, 'https://x.com/v/master.m3u8');
  assert.equal(m.type, 'master');
  assert.equal(m.variants[0].height, 1080);
  assert.equal(m.variants[1].url, 'https://x.com/v/low/index.m3u8');
  assert.equal(m.audio[0].url, 'https://x.com/v/a/en.m3u8');
  assert.equal(qualityLabel(m.variants[0]), '1080p60 · 5.0 Mbps');
});
t('HLS media: duration, VOD, AES-128 is not DRM', () => {
  const m = parseM3U8('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="k.key"\n#EXTINF:4.0,\na.ts\n#EXTINF:3.5,\nb.ts\n#EXT-X-ENDLIST\n', 'https://x/');
  assert.equal(m.type, 'media'); assert.equal(m.duration, 7.5); assert.equal(m.live, false); assert.equal(m.drm, false); assert.equal(m.encrypted, true);
});
t('HLS FairPlay / Widevine flagged as DRM', () => {
  assert.equal(parseM3U8('#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://abc",KEYFORMAT="com.apple.streamingkeydelivery"\n#EXTINF:4,\na.ts\n', 'https://x/').drm, true);
  assert.equal(parseM3U8('#EXTM3U\n#EXT-X-SESSION-KEY:METHOD=SAMPLE-AES-CTR,KEYFORMAT="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed",URI="data:x"\n#EXT-X-STREAM-INF:BANDWIDTH=1\nv.m3u8\n', 'https://x/').drm, true);
});
t('HLS live (no ENDLIST)', () => assert.equal(parseM3U8('#EXTM3U\n#EXTINF:4,\na.ts\n', 'https://x/').live, true));
t('ISO-8601 durations', () => {
  assert.equal(parseISODuration('PT1H2M3.5S'), 3723.5);
  assert.equal(parseISODuration('PT30.0S'), 30);
});
t('DASH: reps, duration, DRM detection', () => {
  const p = parseMPD('<MPD type="static" mediaPresentationDuration="PT2M"><Period><AdaptationSet mimeType="video/mp4"><Representation id="1" bandwidth="3000000" width="1280" height="720"/><Representation id="2" bandwidth="6000000" width="1920" height="1080"/></AdaptationSet><AdaptationSet mimeType="audio/mp4" lang="en"><Representation id="a" bandwidth="128000"/></AdaptationSet></Period></MPD>');
  assert.equal(p.duration, 120); assert.equal(p.variants[0].height, 1080); assert.equal(p.audio.length, 1); assert.equal(p.drm, false);
  assert.equal(parseMPD('<MPD><Period><AdaptationSet><ContentProtection schemeIdUri="urn:uuid:edef8ba9"/></AdaptationSet></Period></MPD>').drm, true);
});
if (media) {
  t('real ffmpeg outputs parse', () => {
    const m = parseM3U8(fs.readFileSync(`${media}/hls-aes/master.m3u8`, 'utf8'), 'http://127.0.0.1:8765/hls-aes/master.m3u8');
    assert.equal(m.variants.length, 2); assert.equal(m.variants[0].height, 720);
    const f = parseM3U8(fs.readFileSync(`${media}/hls-fmp4/master.m3u8`, 'utf8'), 'http://127.0.0.1:8765/hls-fmp4/master.m3u8');
    assert.equal(f.audio.length, 1);
    const d = parseMPD(fs.readFileSync(`${media}/dash/manifest.mpd`, 'utf8'));
    assert.equal(d.duration, 30); assert.equal(d.variants[0].height, 720); assert.equal(d.audio.length, 1);
  });
  console.log('track probe');
  const head = (f, n = 512 * 1024) => new Uint8Array(fs.readFileSync(`${media}/${f}`).subarray(0, n));
  t('MP4 with video + audio', () => {
    const r = analyzeMp4(head('progressive.mp4'));
    assert.equal(tracksOf(r.info), 'av'); assert.equal(r.info.height, 720); assert.equal(Math.round(r.info.duration), 30);
  });
  t('video-only and audio-only MP4 (separate streams)', () => {
    assert.equal(tracksOf(analyzeMp4(head('vonly.mp4')).info), 'video');
    assert.equal(tracksOf(analyzeMp4(head('aonly.mp4')).info), 'audio');
  });
  t('MP4 with moov at the end asks for the right byte range', () => {
    const size = fs.statSync(`${media}/nofast.mp4`).size;
    const r = analyzeMp4(head('nofast.mp4'), size);
    assert.equal(r.done, false); assert.ok(r.need[0] > 1e6 && r.need[0] < size);
  });
  t('DASH init segments', () => {
    assert.equal(tracksOf(analyzeMp4(head('dash/init-stream0.m4s')).info), 'video');
    assert.equal(tracksOf(analyzeMp4(head('dash/init-stream1.m4s')).info), 'audio');
  });
  if (fs.existsSync(`${media}/av.webm`)) {
    t('WebM video + audio and video-only', () => {
      const a = analyzeWebm(head('av.webm'));
      assert.equal(tracksOf(a), 'av'); assert.equal(a.height, 480);
      assert.equal(tracksOf(analyzeWebm(head('vonly.webm'))), 'video');
    });
  }
  t('not a media file', () => assert.equal(analyzeMp4(new TextEncoder().encode('<!doctype html><html>')), null));
}
console.log(`\n${passed} passed`);
