// Media classifier: decides whether a network response is a downloadable
// video/audio resource, a streaming manifest, or noise (segments, ads, images).
// Pure functions only, so the same file runs in the service worker and in Node tests.

export const KIND = { FILE: 'file', HLS: 'hls', DASH: 'dash' };

// MIME type -> [kind, default extension]. Segment MIME types map to null (ignored).
const MIME_TABLE = {
  'application/vnd.apple.mpegurl': [KIND.HLS, 'm3u8'],
  'application/x-mpegurl': [KIND.HLS, 'm3u8'],
  'application/mpegurl': [KIND.HLS, 'm3u8'],
  'audio/mpegurl': [KIND.HLS, 'm3u8'],
  'audio/x-mpegurl': [KIND.HLS, 'm3u8'],
  'video/mpegurl': [KIND.HLS, 'm3u8'],
  'video/x-mpegurl': [KIND.HLS, 'm3u8'],
  'application/octet-stream-m3u8': [KIND.HLS, 'm3u8'],
  'application/dash+xml': [KIND.DASH, 'mpd'],
  'video/vnd.mpeg.dash.mpd': [KIND.DASH, 'mpd'],
  'video/mp4': [KIND.FILE, 'mp4'],
  'video/x-m4v': [KIND.FILE, 'm4v'],
  'video/mpg4': [KIND.FILE, 'mp4'],
  'video/x-mp4': [KIND.FILE, 'mp4'],
  'video/webm': [KIND.FILE, 'webm'],
  'video/ogg': [KIND.FILE, 'ogv'],
  'video/quicktime': [KIND.FILE, 'mov'],
  'video/x-matroska': [KIND.FILE, 'mkv'],
  'video/x-flv': [KIND.FILE, 'flv'],
  'video/flv': [KIND.FILE, 'flv'],
  'video/x-msvideo': [KIND.FILE, 'avi'],
  'video/avi': [KIND.FILE, 'avi'],
  'video/x-ms-wmv': [KIND.FILE, 'wmv'],
  'video/3gpp': [KIND.FILE, '3gp'],
  'video/3gpp2': [KIND.FILE, '3g2'],
  'video/mpeg': [KIND.FILE, 'mpg'],
  'audio/mpeg': [KIND.FILE, 'mp3'],
  'audio/mp3': [KIND.FILE, 'mp3'],
  'audio/mp4': [KIND.FILE, 'm4a'],
  'audio/x-m4a': [KIND.FILE, 'm4a'],
  'audio/aac': [KIND.FILE, 'aac'],
  'audio/ogg': [KIND.FILE, 'ogg'],
  'audio/opus': [KIND.FILE, 'opus'],
  'audio/webm': [KIND.FILE, 'weba'],
  'audio/wav': [KIND.FILE, 'wav'],
  'audio/x-wav': [KIND.FILE, 'wav'],
  'audio/flac': [KIND.FILE, 'flac'],
  'audio/x-flac': [KIND.FILE, 'flac'],
  'audio/x-ms-wma': [KIND.FILE, 'wma'],
  // Stream segments: never shown on their own.
  'video/mp2t': null,
  'audio/mp2t': null,
  'video/iso.segment': null,
  'audio/iso.segment': null,
  'video/x-ms-asf': null,
};

const EXT_TABLE = {
  m3u8: KIND.HLS, m3u: KIND.HLS,
  mpd: KIND.DASH,
  mp4: KIND.FILE, m4v: KIND.FILE, webm: KIND.FILE, mkv: KIND.FILE, mov: KIND.FILE,
  flv: KIND.FILE, avi: KIND.FILE, wmv: KIND.FILE, '3gp': KIND.FILE, ogv: KIND.FILE,
  mpg: KIND.FILE, mpeg: KIND.FILE,
  mp3: KIND.FILE, m4a: KIND.FILE, aac: KIND.FILE, ogg: KIND.FILE, oga: KIND.FILE,
  opus: KIND.FILE, wav: KIND.FILE, flac: KIND.FILE, weba: KIND.FILE, wma: KIND.FILE,
};

export const AUDIO_EXT = new Set(['mp3', 'm4a', 'aac', 'ogg', 'oga', 'opus', 'wav', 'flac', 'weba', 'wma']);

// Extensions / path patterns that are pieces of a stream, not a whole file.
const SEGMENT_EXT = new Set(['ts', 'm4s', 'm4f', 'cmfv', 'cmfa', 'cmft', 'fmp4', 'm4i', 'vtt', 'webvtt', 'key', 'aac_seg']);
const SEGMENT_PATH = /(?:\/|_|-)(?:seg(?:ment)?|frag(?:ment)?|chunk)[-_]?\d+|\/Fragments\(|\bSeg\d+-Frag\d+\b|\/range\/\d+-\d+|\/init(?:ialization)?[-_.]|\.(?:ts|m4s)(?:$|\?)/i;

// Query parameters that only carry a byte range; strip them so all the range
// requests a <video> element makes for one file collapse to one entry.
export const RANGE_PARAMS = ['range', 'bytestart', 'byteend', 'bytes', 'start_byte', 'end_byte'];

export function extOf(url) {
  try {
    const path = new URL(url).pathname;
    const m = /\.([a-z0-9]{1,5})$/i.exec(path);
    return m ? m[1].toLowerCase() : '';
  } catch {
    return '';
  }
}

export function headerValue(headers, name) {
  if (!headers) return null;
  const lower = name.toLowerCase();
  for (const h of headers) {
    if (h.name.toLowerCase() === lower) return h.value ?? null;
  }
  return null;
}

export function parseContentType(value) {
  if (!value) return '';
  return value.split(';')[0].trim().toLowerCase();
}

// RFC 6266 filename / filename* from Content-Disposition.
export function filenameFromDisposition(value) {
  if (!value) return null;
  const star = /filename\*\s*=\s*([^']*)'[^']*'([^;]+)/i.exec(value);
  if (star) {
    try { return decodeURIComponent(star[2].trim().replace(/^"|"$/g, '')); } catch { /* fall through */ }
  }
  const plain = /filename\s*=\s*("([^"]*)"|[^;]+)/i.exec(value);
  if (plain) {
    const raw = (plain[2] ?? plain[1]).trim();
    try { return decodeURIComponent(raw); } catch { return raw; }
  }
  return null;
}

// Total size of the resource: Content-Range total wins over Content-Length,
// because a <video> usually asks for "bytes=0-" or a small range.
export function totalSize(responseHeaders) {
  const range = headerValue(responseHeaders, 'content-range');
  if (range) {
    const m = /\/(\d+)\s*$/.exec(range);
    if (m) return Number(m[1]);
  }
  const len = headerValue(responseHeaders, 'content-length');
  if (len && /^\d+$/.test(len.trim())) return Number(len);
  return null;
}

export function normalizeMediaUrl(url) {
  try {
    const u = new URL(url);
    u.hash = '';
    // Only re-serialize when needed: signed URLs break if the query encoding changes.
    if (!RANGE_PARAMS.some((p) => u.searchParams.has(p))) return u.toString();
    for (const p of RANGE_PARAMS) u.searchParams.delete(p);
    return u.toString();
  } catch {
    return url;
  }
}

export function hasRangeParam(url) {
  try {
    const u = new URL(url);
    return RANGE_PARAMS.some((p) => u.searchParams.has(p));
  } catch {
    return false;
  }
}

// Containers whose header Castnet can read to learn video/audio tracks (lib/probe.js).
export const PROBE_EXT = new Set(['mp4', 'm4v', 'm4a', 'mov', 'webm', 'weba', 'mkv']);

export function looksLikeSegment(url) {
  const ext = extOf(url);
  if (SEGMENT_EXT.has(ext)) return true;
  return SEGMENT_PATH.test(url);
}

/**
 * Classify a finished response.
 * @param {object} d  { url, type, statusCode, responseHeaders, method }
 * @param {object} opts { minSize }
 * @returns {null | { kind, ext, mime, size, filename, audioOnly }}
 */
export function classifyResponse(d, opts = {}) {
  const minSize = opts.minSize ?? 300 * 1024;
  const { url, statusCode, responseHeaders } = d;
  if (!/^https?:/i.test(url)) return null;
  if (statusCode !== 200 && statusCode !== 206 && statusCode !== 304) return null;
  if (d.method && d.method !== 'GET' && d.method !== 'POST') return null;

  const mime = parseContentType(headerValue(responseHeaders, 'content-type'));
  const disposition = headerValue(responseHeaders, 'content-disposition');
  const dispName = filenameFromDisposition(disposition);
  const urlExt = extOf(url);
  const nameExt = dispName ? (/\.([a-z0-9]{1,5})$/i.exec(dispName)?.[1] || '').toLowerCase() : '';
  const ext = nameExt || urlExt;

  // Images and documents are never media, whatever the URL says.
  if (/^(image|font)\//.test(mime) || mime === 'text/html' || mime === 'text/css') {
    // Some CDNs mislabel manifests as text/html; trust a manifest extension.
    if (!(ext === 'm3u8' || ext === 'mpd')) return null;
  }

  let kind = null;
  let defExt = ext;
  if (Object.prototype.hasOwnProperty.call(MIME_TABLE, mime)) {
    const entry = MIME_TABLE[mime];
    if (entry === null) return null; // known segment type
    [kind, defExt] = entry;
    // Manifest URLs win over generic MIME labels (e.g. video/mp4 on a .mpd is a server bug).
    if (EXT_TABLE[ext] && EXT_TABLE[ext] !== KIND.FILE) kind = EXT_TABLE[ext];
  } else if (EXT_TABLE[ext]) {
    // Manifests are often served with whatever MIME the CDN guesses; trust the extension.
    // Plain files need a generic MIME (octet-stream, text/plain, empty) to go with the media extension.
    if (EXT_TABLE[ext] === KIND.FILE && mime &&
        !/^(application\/(octet-stream|force-download|binary|x-download)|binary\/octet-stream|text\/plain)$/.test(mime) &&
        !mime.startsWith('video/') && !mime.startsWith('audio/')) {
      return null;
    }
    kind = EXT_TABLE[ext];
  } else if (mime.startsWith('video/') || mime.startsWith('audio/')) {
    kind = KIND.FILE;
    defExt = mime.split('/')[1].replace(/^x-/, '').slice(0, 5);
  }
  if (!kind) return null;

  // URLs carrying their byte range in the query (Facebook, Instagram, YouTube) report the
  // chunk size, not the file size: the probe step finds the real size later.
  const chunked = !!opts.chunked;
  const size = chunked ? null : totalSize(responseHeaders);

  if (kind === KIND.FILE) {
    if (looksLikeSegment(url) && !(dispName)) return null;
    // A 206 on a video/mp4 with a tiny total is an init segment or an ad blip.
    if (size != null && size < minSize) return null;
    // fMP4 fragments served as video/mp4 without Content-Range total are common; if the
    // request asked for a range and the server didn't tell us the total, wait for a better signal.
    if (!chunked && statusCode === 206 && size == null) return null;
  }

  const finalExt = (kind === KIND.FILE ? (EXT_TABLE[ext] ? ext : defExt) : (kind === KIND.HLS ? 'm3u8' : 'mpd')) || 'mp4';
  return {
    kind,
    ext: finalExt,
    mime,
    size: kind === KIND.FILE ? size : null,
    filename: dispName,
    audioOnly: kind === KIND.FILE && (mime.startsWith('audio/') || AUDIO_EXT.has(finalExt)),
  };
}

// Absolute media URLs inside JSON / JS / HTML text (handles \/ and / escaping).
const URL_IN_TEXT = /https?:(?:\\?\/|\\u002[fF]){2}[^\s"'<>]+?\.(?:m3u8|mpd|mp4|m4v|webm|mov|mkv|m4a|mp3)(?:\?[^\s"'<>]*)?(?=$|[\s"'<>,;)\]}]|\\)/gi;

export function findMediaUrlsInText(text, limit = 40) {
  if (!text || typeof text !== 'string') return [];
  const out = new Set();
  URL_IN_TEXT.lastIndex = 0;
  let m;
  while ((m = URL_IN_TEXT.exec(text)) && out.size < limit) {
    let u = m[0]
      .replace(/\\u002[fF]/g, '/')
      .replace(/\\u0026/g, '&')
      .replace(/\\\//g, '/')
      .replace(/&amp;/g, '&')
      .replace(/\\+$/, '');
    try {
      u = new URL(u).toString();
      if (!looksLikeSegment(u)) out.add(u);
    } catch { /* not a URL */ }
  }
  return [...out];
}

export function humanSize(bytes) {
  if (bytes == null || !isFinite(bytes)) return '';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  let v = bytes;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v >= 100 || i === 0 ? Math.round(v) : v.toFixed(1)} ${units[i]}`;
}

export function humanDuration(sec) {
  if (sec == null || !isFinite(sec) || sec <= 0) return '';
  sec = Math.round(sec);
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = sec % 60;
  const pad = (n) => String(n).padStart(2, '0');
  return h ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
}

export function sanitizeFilename(name, fallback = 'video') {
  let s = (name || '').replace(/[\u0000-\u001f\u007f]/g, '').replace(/[\\/:*?"<>|]+/g, ' ').replace(/\s+/g, ' ').trim();
  s = s.replace(/^\.+/, '').slice(0, 150).trim();
  return s || fallback;
}
