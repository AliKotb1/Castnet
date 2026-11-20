// Lightweight HLS (m3u8) and DASH (mpd) parsers used by the extension to label
// streams with qualities, durations and DRM status. The Mac app re-parses the
// manifest itself when downloading; this is only for the UI.

function resolve(base, ref) {
  try { return new URL(ref, base).toString(); } catch { return ref; }
}

// Parses `KEY=VALUE,KEY="quoted,value"` attribute lists.
export function parseAttributes(s) {
  const out = {};
  const re = /([A-Z0-9-]+)=("[^"]*"|[^,]*)/gi;
  let m;
  while ((m = re.exec(s))) {
    let v = m[2];
    if (v.startsWith('"')) v = v.slice(1, -1);
    out[m[1].toUpperCase()] = v;
  }
  return out;
}

const DRM_KEYFORMATS = /com\.apple\.streamingkeydelivery|com\.widevine|urn:uuid:edef8ba9|urn:uuid:9a04f079|com\.microsoft\.playready/i;

/**
 * @returns {{type:'master', variants:[], audio:[], drm:boolean} |
 *           {type:'media', duration:number, segments:number, live:boolean, drm:boolean, encrypted:boolean}}
 */
export function parseM3U8(text, baseUrl) {
  if (!text || !text.trimStart().startsWith('#EXTM3U')) return null;
  const lines = text.split(/\r?\n/);
  const variants = [];
  const audio = [];
  let drm = false;
  let encrypted = false;
  let duration = 0;
  let segments = 0;
  let live = true;
  let pendingInf = null;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;
    if (line.startsWith('#EXT-X-STREAM-INF:')) {
      pendingInf = parseAttributes(line.slice(18));
    } else if (line.startsWith('#EXT-X-MEDIA:')) {
      const a = parseAttributes(line.slice(13));
      if (a.TYPE === 'AUDIO' && a.URI) {
        audio.push({ url: resolve(baseUrl, a.URI), group: a['GROUP-ID'], name: a.NAME, lang: a.LANGUAGE, isDefault: a.DEFAULT === 'YES' });
      }
    } else if (line.startsWith('#EXT-X-KEY:') || line.startsWith('#EXT-X-SESSION-KEY:')) {
      const a = parseAttributes(line.slice(line.indexOf(':') + 1));
      const method = (a.METHOD || '').toUpperCase();
      if (method && method !== 'NONE') encrypted = true;
      if (method.startsWith('SAMPLE-AES') || (a.KEYFORMAT && a.KEYFORMAT !== 'identity' && DRM_KEYFORMATS.test(a.KEYFORMAT)) || /^skd:/i.test(a.URI || '')) {
        drm = true;
      }
    } else if (line.startsWith('#EXTINF:')) {
      duration += parseFloat(line.slice(8)) || 0;
      segments++;
    } else if (line.startsWith('#EXT-X-ENDLIST')) {
      live = false;
    } else if (line.startsWith('#EXT-X-PLAYLIST-TYPE:VOD')) {
      live = false;
    } else if (!line.startsWith('#') && pendingInf) {
      const res = /^(\d+)x(\d+)$/.exec(pendingInf.RESOLUTION || '');
      variants.push({
        url: resolve(baseUrl, line),
        bandwidth: Number(pendingInf['AVERAGE-BANDWIDTH'] || pendingInf.BANDWIDTH) || null,
        width: res ? Number(res[1]) : null,
        height: res ? Number(res[2]) : null,
        codecs: pendingInf.CODECS || '',
        audioGroup: pendingInf.AUDIO || null,
        fps: Number(pendingInf['FRAME-RATE']) || null,
      });
      pendingInf = null;
    }
  }

  if (variants.length) {
    // Drop I-frame-only and duplicate entries; sort best first.
    const seen = new Set();
    const uniq = variants.filter((v) => (seen.has(v.url) ? false : seen.add(v.url)));
    uniq.sort((a, b) => (b.height || 0) - (a.height || 0) || (b.bandwidth || 0) - (a.bandwidth || 0));
    return { type: 'master', variants: uniq, audio, drm };
  }
  return { type: 'media', duration, segments, live, drm, encrypted };
}

function attr(tag, name) {
  const m = new RegExp(`\\s${name}\\s*=\\s*"([^"]*)"`, 'i').exec(tag);
  return m ? m[1] : null;
}

export function parseISODuration(s) {
  if (!s) return null;
  const m = /^P(?:(\d+(?:\.\d+)?)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?$/.exec(s.trim());
  if (!m) return null;
  return (Number(m[1] || 0) * 86400) + (Number(m[2] || 0) * 3600) + (Number(m[3] || 0) * 60) + Number(m[4] || 0);
}

/**
 * Regex-based MPD summary (DOMParser isn't available in a service worker).
 * @returns {{variants:[], audio:[], duration:number|null, live:boolean, drm:boolean}}
 */
export function parseMPD(text) {
  if (!text || !/<MPD[\s>]/.test(text)) return null;
  const mpdTag = /<MPD[^>]*>/.exec(text)?.[0] || '';
  const live = (attr(mpdTag, 'type') || 'static') === 'dynamic';
  const duration = parseISODuration(attr(mpdTag, 'mediaPresentationDuration'));
  const drm = /<(?:\w+:)?ContentProtection\b/i.test(text);
  const variants = [];
  const audio = [];

  const setRe = /<AdaptationSet\b([^>]*)>([\s\S]*?)<\/AdaptationSet>/gi;
  let set;
  while ((set = setRe.exec(text))) {
    const setAttrs = `<x ${set[1]}>`;
    const setMime = attr(setAttrs, 'mimeType') || '';
    const setType = attr(setAttrs, 'contentType') || '';
    const repRe = /<Representation\b([^>]*?)\/?>/gi;
    let rep;
    while ((rep = repRe.exec(set[2]))) {
      const r = `<x ${rep[1]}>`;
      const mime = attr(r, 'mimeType') || setMime;
      const kind = /video/.test(mime) || setType === 'video' || attr(r, 'height') ? 'video'
        : /audio/.test(mime) || setType === 'audio' ? 'audio' : 'other';
      const entry = {
        id: attr(r, 'id'),
        bandwidth: Number(attr(r, 'bandwidth')) || null,
        width: Number(attr(r, 'width') || attr(setAttrs, 'width')) || null,
        height: Number(attr(r, 'height') || attr(setAttrs, 'height')) || null,
        codecs: attr(r, 'codecs') || attr(setAttrs, 'codecs') || '',
        lang: attr(setAttrs, 'lang'),
      };
      if (kind === 'video') variants.push(entry);
      else if (kind === 'audio') audio.push(entry);
    }
  }
  variants.sort((a, b) => (b.height || 0) - (a.height || 0) || (b.bandwidth || 0) - (a.bandwidth || 0));
  audio.sort((a, b) => (b.bandwidth || 0) - (a.bandwidth || 0));
  return { variants, audio, duration, live, drm };
}

export function qualityLabel(v) {
  if (!v) return '';
  const parts = [];
  if (v.height) parts.push(`${v.height}p${v.fps && v.fps > 31 ? Math.round(v.fps) : ''}`);
  else if (v.width) parts.push(`${v.width}w`);
  if (v.bandwidth) parts.push(`${(v.bandwidth / 1e6).toFixed(v.bandwidth >= 1e7 ? 0 : 1)} Mbps`);
  return parts.join(' · ') || 'auto';
}
