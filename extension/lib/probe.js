// Reads the container header of an MP4/MOV or WebM/MKV file to learn which tracks it has
// (video, audio or both), the picture size and the duration. Sites like Facebook,
// Instagram, Reddit and Vimeo stream picture and sound as two separate files; this is
// how Castnet tells them apart and pairs them into one "video + audio" download.
// Pure functions on Uint8Array, plus probeUrl() which fetches only the bytes it needs.

const td = new TextDecoder('latin1');
const u32 = (b, o) => ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) >>> 0;
const u64 = (b, o) => u32(b, o) * 4294967296 + u32(b, o + 4);
const fourcc = (b, o) => td.decode(b.subarray(o, o + 4));

/** Iterates boxes in b[start, end). Yields {type, start, size, header}. Stops at truncated boxes. */
function* boxes(b, start, end) {
  let p = start;
  while (p + 8 <= end) {
    let size = u32(b, p);
    const type = fourcc(b, p + 4);
    let header = 8;
    if (size === 1) {
      if (p + 16 > end) return;
      size = u64(b, p + 8);
      header = 16;
    } else if (size === 0) {
      size = end - p;
    }
    if (size < header) return;
    yield { type, start: p, size, header };
    p += size;
  }
}

function child(b, box, type) {
  for (const c of boxes(b, box.start + box.header, Math.min(box.start + box.size, b.length))) if (c.type === type) return c;
  return null;
}

function parseMoov(b, moov) {
  const out = { video: false, audio: false, width: null, height: null, duration: null };
  const mvhd = child(b, moov, 'mvhd');
  if (mvhd) {
    const p = mvhd.start + mvhd.header;
    const v = b[p];
    const timescale = v === 1 ? u32(b, p + 20) : u32(b, p + 12);
    const duration = v === 1 ? u64(b, p + 24) : u32(b, p + 16);
    if (timescale) out.duration = duration / timescale;
  }
  for (const trak of boxes(b, moov.start + moov.header, Math.min(moov.start + moov.size, b.length))) {
    if (trak.type !== 'trak') continue;
    const mdia = child(b, trak, 'mdia');
    const hdlr = mdia && child(b, mdia, 'hdlr');
    if (!hdlr) continue;
    const handler = fourcc(b, hdlr.start + hdlr.header + 8);
    if (handler === 'vide') {
      out.video = true;
      const tkhd = child(b, trak, 'tkhd');
      if (tkhd) {
        const p = tkhd.start + tkhd.header;
        const off = b[p] === 1 ? 88 : 76;
        const w = u32(b, p + off) / 65536;
        const h = u32(b, p + off + 4) / 65536;
        if (h > (out.height || 0)) { out.width = Math.round(w); out.height = Math.round(h); }
      }
    } else if (handler === 'soun') {
      out.audio = true;
    }
  }
  return out;
}

/**
 * Looks at the start of an MP4 file.
 * @returns {{done: true, info} | {done: false, need: [start, end]} | null}
 */
export function analyzeMp4(b, fileSize) {
  if (b.length < 8) return null;
  const first = fourcc(b, 4);
  if (!['ftyp', 'styp', 'moov', 'free', 'skip', 'wide', 'mdat', 'pdin', 'sidx'].includes(first)) return null;
  let p = 0;
  for (;;) {
    if (p + 16 > b.length) {
      if (fileSize && p < fileSize) return { done: false, need: [p, Math.min(fileSize - 1, p + 4095)] };
      return null;
    }
    let size = u32(b, p);
    const type = fourcc(b, p + 4);
    let header = 8;
    if (size === 1) { size = u64(b, p + 8); header = 16; } else if (size === 0) { size = (fileSize || b.length) - p; }
    if (size < header) return null;
    if (type === 'moov') {
      if (p + size <= b.length) return { done: true, info: parseMoov(b, { start: p, size, header }) };
      // moov continues past what we have: ask for exactly the moov box (capped).
      return { done: false, need: [p, p + Math.min(size, 16 << 20) - 1], rebase: p };
    }
    if (type === 'moof' || (type === 'mdat' && p + size > b.length && !fileSize)) return null;
    p += size;
  }
}

// ---------------- Matroska / WebM (EBML)

function vint(b, p, keepMarker) {
  const first = b[p];
  if (first === undefined) return null;
  let len = 1;
  let mask = 0x80;
  while (len <= 8 && !(first & mask)) { len++; mask >>= 1; }
  if (len > 8 || p + len > b.length) return null;
  let value = keepMarker ? first : first & (mask - 1);
  let allOnes = (first & (mask - 1)) === mask - 1;
  for (let i = 1; i < len; i++) {
    value = value * 256 + b[p + i];
    if (b[p + i] !== 0xff) allOnes = false;
  }
  return { len, value, unknown: !keepMarker && allOnes };
}

function* ebml(b, start, end) {
  let p = start;
  while (p < end) {
    const id = vint(b, p, true);
    if (!id) return;
    const size = vint(b, p + id.len, false);
    if (!size) return;
    const dataStart = p + id.len + size.len;
    const dataEnd = size.unknown ? end : Math.min(end, dataStart + size.value);
    yield { id: id.value, dataStart, dataEnd, unknown: size.unknown };
    if (size.unknown) return;
    p = dataStart + size.value;
  }
}

const uint = (b, s, e) => { let v = 0; for (let i = s; i < e; i++) v = v * 256 + b[i]; return v; };
function float(b, s, e) {
  const dv = new DataView(b.buffer, b.byteOffset + s, e - s);
  return e - s === 4 ? dv.getFloat32(0) : e - s === 8 ? dv.getFloat64(0) : 0;
}

export function analyzeWebm(b) {
  if (b.length < 4 || u32(b, 0) !== 0x1a45dfa3) return null;
  const out = { video: false, audio: false, width: null, height: null, duration: null };
  let scale = 1e6;
  let rawDuration = null;
  let sawTracks = false;
  for (const top of ebml(b, 0, b.length)) {
    if (top.id !== 0x18538067) continue; // Segment
    for (const el of ebml(b, top.dataStart, top.dataEnd)) {
      if (el.id === 0x1549a966) { // Info
        for (const i of ebml(b, el.dataStart, el.dataEnd)) {
          if (i.id === 0x2ad7b1) scale = uint(b, i.dataStart, i.dataEnd);
          if (i.id === 0x4489) rawDuration = float(b, i.dataStart, i.dataEnd);
        }
      } else if (el.id === 0x1654ae6b) { // Tracks
        sawTracks = true;
        for (const t of ebml(b, el.dataStart, el.dataEnd)) {
          if (t.id !== 0xae) continue; // TrackEntry
          let type = 0, w = null, h = null;
          for (const f of ebml(b, t.dataStart, t.dataEnd)) {
            if (f.id === 0x83) type = uint(b, f.dataStart, f.dataEnd);
            if (f.id === 0xe0) {
              for (const v of ebml(b, f.dataStart, f.dataEnd)) {
                if (v.id === 0xb0) w = uint(b, v.dataStart, v.dataEnd);
                if (v.id === 0xba) h = uint(b, v.dataStart, v.dataEnd);
              }
            }
          }
          if (type === 1) { out.video = true; if (h > (out.height || 0)) { out.width = w; out.height = h; } }
          if (type === 2) out.audio = true;
        }
      } else if (el.id === 0x1f43b675) { // Cluster: tracks always come before media data
        break;
      }
    }
  }
  if (!sawTracks) return null;
  if (rawDuration) out.duration = (rawDuration * scale) / 1e9;
  return out;
}

export function tracksOf(info) {
  if (!info) return null;
  return info.video && info.audio ? 'av' : info.video ? 'video' : info.audio ? 'audio' : null;
}

/**
 * Fetches just enough of `url` to read its header.
 * @returns {Promise<{tracks, width, height, duration, size} | null>}
 */
export async function probeUrl(url, { headBytes = 512 * 1024, fetchImpl = fetch } = {}) {
  async function range(start, end) {
    const res = await fetchImpl(url, { headers: { Range: `bytes=${start}-${end}` }, credentials: 'include', cache: 'no-store' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    let total = null;
    const cr = res.headers.get('content-range');
    if (cr && /\/(\d+)/.test(cr)) total = Number(/\/(\d+)/.exec(cr)[1]);
    else if (res.status === 200) total = Number(res.headers.get('content-length')) || null;
    // Read at most what we asked for, even if the server ignored the range.
    const want = end - start + 1;
    const reader = res.body.getReader();
    const chunks = [];
    let got = 0;
    while (got < want) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
      got += value.byteLength;
    }
    reader.cancel().catch(() => {});
    const buf = new Uint8Array(Math.min(got, want));
    let o = 0;
    for (const c of chunks) {
      const n = Math.min(c.byteLength, buf.length - o);
      buf.set(c.subarray(0, n), o);
      o += n;
      if (o >= buf.length) break;
    }
    return { buf, total, ranged: res.status === 206 };
  }

  const head = await range(0, headBytes - 1);
  let info = analyzeWebm(head.buf);
  if (!info) {
    let r = analyzeMp4(head.buf, head.total);
    if (r && !r.done && head.ranged) {
      // moov is after the media data (not "fast start"): read the box header there, then moov itself.
      let p = r.need[0];
      for (let hops = 0; hops < 6 && r && !r.done; hops++) {
        const part = await range(p, p + 15);
        const size = u32(part.buf, 0) === 1 ? u64(part.buf, 8) : u32(part.buf, 0);
        const type = fourcc(part.buf, 4);
        if (type === 'moov') {
          const moov = await range(p, p + Math.min(size, 16 << 20) - 1);
          r = { done: true, info: parseMoov(moov.buf, { start: 0, size: moov.buf.length, header: u32(moov.buf, 0) === 1 ? 16 : 8 }) };
        } else if (size >= 8) {
          p += size;
          if (head.total && p >= head.total) r = null;
        } else {
          r = null;
        }
      }
    }
    info = r && r.done ? r.info : null;
  }
  if (!info) return head.total ? { tracks: null, size: head.total } : null;
  return { tracks: tracksOf(info), width: info.width, height: info.height, duration: info.duration, size: head.total };
}
