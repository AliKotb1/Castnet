// Test HTTP server with byte-range support, a per-connection speed limit (to show
// the benefit of multiple connections), and Referer/Cookie checks (to prove the app
// replays the browser's headers).
//   node test/server.js MEDIA_DIR [port]
//   /protected/<file>  requires Referer: http://127.0.0.1:<port>/page.html and Cookie: session=letmein
//   /slow/<file>       limited to ~2 MB/s per connection
//   /live.m3u8         sliding-window live playlist built from hls-aes/720p segments
const http = require('http');
const crypto = require('crypto');
const SECRET = crypto.randomBytes(16).toString('hex');
// Signed links that expire, like Facebook/Google CDN URLs: /expiring/<file>?exp=<ms>&sig=<hmac>
function sign(file, exp) { return crypto.createHmac('sha256', SECRET).update(`${file}|${exp}`).digest('hex').slice(0, 24); }
function freshLink(file, ttlSec, port) {
  const exp = Date.now() + ttlSec * 1000;
  return `http://127.0.0.1:${port}/expiring/${file}?exp=${exp}&sig=${sign(file, exp)}`;
}
const fs = require('fs');
const path = require('path');

const root = path.resolve(process.argv[2] || '.');
const port = Number(process.argv[3] || 8765);
const started = Date.now();
const stats = { requests: 0, ranges: 0, maxParallel: 0, active: 0 };

const MIME = {
  '.mp4': 'video/mp4', '.m4s': 'video/iso.segment', '.ts': 'video/mp2t', '.m3u8': 'application/vnd.apple.mpegurl',
  '.mpd': 'application/dash+xml', '.html': 'text/html; charset=utf-8', '.json': 'application/json', '.key': 'application/octet-stream',
};

function sendFile(req, res, file, { slow = false, expiresAt = 0 } = {}) {
  fs.stat(file, (err, st) => {
    if (err || !st.isFile()) { res.writeHead(404); return res.end('not found'); }
    const type = MIME[path.extname(file)] || 'application/octet-stream';
    const etag = `"${st.size}-${Math.floor(st.mtimeMs)}"`;
    let start = 0;
    let end = st.size - 1;
    let status = 200;
    const range = req.headers.range;
    const ifRange = req.headers['if-range'];
    if (range && (!ifRange || ifRange === etag)) {
      const m = /bytes=(\d*)-(\d*)/.exec(range);
      if (m) {
        start = m[1] ? Number(m[1]) : st.size - Number(m[2]);
        end = m[1] && m[2] ? Math.min(Number(m[2]), st.size - 1) : st.size - 1;
        if (start >= st.size) { res.writeHead(416, { 'Content-Range': `bytes */${st.size}` }); return res.end(); }
        status = 206;
        stats.ranges++;
      }
    }
    const headers = {
      'Content-Type': type, 'Accept-Ranges': 'bytes', 'ETag': etag, 'Content-Length': end - start + 1,
      'Access-Control-Allow-Origin': '*',
    };
    if (status === 206) headers['Content-Range'] = `bytes ${start}-${end}/${st.size}`;
    res.writeHead(status, headers);
    if (req.method === 'HEAD') return res.end();
    stats.active++;
    stats.maxParallel = Math.max(stats.maxParallel, stats.active);
    const done = () => { stats.active--; };
    res.on('close', done);
    const stream = fs.createReadStream(file, { start, end, highWaterMark: 64 * 1024 });
    if (!slow) return stream.pipe(res);
    // ~2 MB/s per connection
    stream.on('data', (chunk) => {
      // Expired signed link: the CDN cuts the connection.
      if (expiresAt && Date.now() > expiresAt) { stream.destroy(); res.destroy(); return; }
      stream.pause();
      res.write(chunk, () => setTimeout(() => stream.resume(), 32));
    });
    stream.on('end', () => res.end());
  });
}

// Segments of hls-aes/720p.m3u8 with the key line in force for each one.
function vodSegments() {
  const lines = fs.readFileSync(path.join(root, 'hls-aes/720p.m3u8'), 'utf8').split(/\r?\n/);
  const segs = [];
  let key = '';
  let inf = '';
  for (const l of lines) {
    if (l.startsWith('#EXT-X-KEY')) key = l.replace(/URI="([^"]+)"/, (m, u) => `URI="/hls-aes/${u}"`);
    else if (l.startsWith('#EXTINF')) inf = l;
    else if (l && !l.startsWith('#')) segs.push({ key, inf, uri: `/hls-aes/${l}` });
  }
  return segs;
}

function livePlaylist(res) {
  const segs = vodSegments();
  const elapsed = Math.floor((Date.now() - started) / 3000); // a new segment "airs" every 3 s
  const window = 3;
  const last = Math.min(segs.length - 1, elapsed + window - 1);
  const first = Math.max(0, last - window + 1);
  let body = `#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:9\n#EXT-X-MEDIA-SEQUENCE:${first}\n`;
  for (let i = first; i <= last; i++) body += `${segs[i].key}\n${segs[i].inf}\n${segs[i].uri}\n`;
  if (last === segs.length - 1) body += '#EXT-X-ENDLIST\n';
  res.writeHead(200, { 'Content-Type': 'application/vnd.apple.mpegurl', 'Cache-Control': 'no-store' });
  res.end(body);
}

http.createServer((req, res) => {
  stats.requests++;
  const url = new URL(req.url, `http://127.0.0.1:${port}`);
  let p = decodeURIComponent(url.pathname);
  if (p === '/__stats') { res.writeHead(200, { 'Content-Type': 'application/json' }); return res.end(JSON.stringify(stats)); }
  if (p === '/__reset') { Object.assign(stats, { requests: 0, ranges: 0, maxParallel: 0 }); res.writeHead(204); return res.end(); }
  if (p === '/live.m3u8') return livePlaylist(res);
  if (p === '/fresh-link') {
    res.writeHead(200, { 'Content-Type': 'text/plain', 'Cache-Control': 'no-store' });
    return res.end(freshLink(url.searchParams.get('file') || 'progressive.mp4', Number(url.searchParams.get('ttl') || 8), port));
  }
  if (p === '/expiring.html') {
    const ttl = Number(url.searchParams.get('ttl') || 10);
    const link = freshLink('progressive.mp4', ttl, port);
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
    return res.end(`<!doctype html><html><head><meta charset="utf-8"><title>Expiring Video</title></head>
<body style="font-family:-apple-system;margin:40px"><h1>Video with an expiring link (${ttl}s)</h1>
<video src="${link}" width="640" height="360" controls muted autoplay></video></body></html>`);
  }
  if (p.startsWith('/expiring/')) {
    const file = p.slice('/expiring/'.length);
    const exp = Number(url.searchParams.get('exp'));
    if (!exp || url.searchParams.get('sig') !== sign(file, exp) || Date.now() > exp) {
      stats.expired = (stats.expired || 0) + 1;
      res.writeHead(403, { 'Content-Type': 'text/plain' });
      return res.end('link expired');
    }
    return sendFile(req, res, path.join(root, path.normalize(file)), { slow: true, expiresAt: exp });
  }
  if (p === '/api/player.json') p = '/player.json';
  if (p === '/' ) p = '/page.html';
  let slow = false;
  if (p.startsWith('/protected/')) {
    const okRef = (req.headers.referer || '').startsWith(`http://127.0.0.1:${port}/page.html`);
    const okCookie = /(?:^|;\s*)session=letmein(?:;|$)/.test(req.headers.cookie || '');
    if (!okRef || !okCookie) { res.writeHead(403); return res.end(`forbidden (referer ok: ${okRef}, cookie ok: ${okCookie})`); }
    p = p.slice('/protected'.length);
  }
  if (p.startsWith('/slow/')) { slow = true; p = p.slice('/slow'.length); }
  const file = path.join(root, path.normalize(p));
  if (!file.startsWith(root)) { res.writeHead(400); return res.end(); }
  sendFile(req, res, file, { slow });
}).listen(port, '127.0.0.1', () => console.log(`test server on http://127.0.0.1:${port} serving ${root}`));
