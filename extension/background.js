// Castnet background service worker.
//
// How the work is split:
//  • sniff every response (webRequest) and keep a per-tab list of media
//  • read stream manifests (HLS/DASH) and file headers (video/audio tracks, size)
//  • pair separate video-only + audio-only files into one "video + audio" choice
//  • for video sites (YouTube…), ask the Mac app for the page's qualities
//  • build one quality menu used by the in-page panel and the toolbar popup
//  • take over browser downloads, "download all/selected links", link picker
//  • hand everything to the Mac app over native messaging, with the browser's cookies

import {
  KIND, classifyResponse, normalizeMediaUrl, extOf, looksLikeSegment, hasRangeParam, PROBE_EXT,
  sanitizeFilename, humanDuration,
} from './lib/detect.js';
import { parseM3U8, parseMPD } from './lib/manifests.js';
import { probeUrl } from './lib/probe.js';

const HOST = 'app.castnet.host';

// Portability: Chrome/Edge/Brave/Arc, Firefox/Zen and Safari expose slightly different APIs.
const HAS_WEBREQUEST = !!chrome.webRequest?.onHeadersReceived;
const EXTRA_HEADERS = chrome.webRequest?.OnSendHeadersOptions?.EXTRA_HEADERS ? ['extraHeaders'] : [];
const memoryStore = new Map();
const session = chrome.storage.session ?? {
  async get(k) { if (k == null) return Object.fromEntries(memoryStore); return { [k]: memoryStore.get(k) }; },
  async set(o) { for (const [k, v] of Object.entries(o)) memoryStore.set(k, v); },
  async remove(k) { memoryStore.delete(k); },
};
const MAX_ITEMS_PER_TAB = 80;
const MAX_VERIFY_PER_TAB = 40;
const WATCH_TYPES = ['main_frame', 'sub_frame', 'xmlhttprequest', 'media', 'object', 'other'];
const PROBE_MIN_BYTES = 16 * 1024;

const OLD_DEFAULT_TYPES = 'zip rar 7z tar gz tgz bz2 xz zst dmg pkg iso img exe msi apk ipa deb rpm jar ' +
  'mp4 mkv webm mov avi flv wmv m4v mpg mpeg 3gp mp3 m4a flac wav aac ogg opus wma torrent';
const DEFAULT_SETTINGS = {
  catchDownloads: true,
  // Every download goes to Castnet. Off = only the file types below, from minCatchSizeKB up.
  catchAll: true,
  catchExtensions: 'zip rar 7z tar gz tgz bz2 xz zst dmg pkg iso img exe msi apk ipa deb rpm jar ' +
    'mp4 mkv webm mov avi flv wmv m4v mpg mpeg 3gp mp3 m4a flac wav aac ogg opus wma torrent ' +
    'pdf doc docx xls xlsx ppt pptx odt ods odp rtf epub csv',
  // PDF links open in the browser's viewer, which isn't a download; catch the click instead.
  catchPdfLinks: true,
  // When Castnet can't fetch a download itself, the browser finishes it and Castnet takes the file.
  adoptBrowserDownloads: true,
  minCatchSizeKB: 512,
  minMediaSizeKB: 300,
  showOverlay: true,
  disabledHosts: [],
};

// Video sites whose qualities come from the Mac app's site extractor rather than raw streams.
const SITE_HOSTS = [
  'youtube.com', 'youtu.be', 'youtube-nocookie.com', 'vimeo.com', 'dailymotion.com', 'x.com', 'twitter.com',
  'tiktok.com', 'instagram.com', 'facebook.com', 'fb.watch', 'reddit.com', 'twitch.tv', 'soundcloud.com',
  'bilibili.com', 'streamable.com', 'rumble.com', 'bandcamp.com', 'ted.com', '9gag.com', 'linkedin.com',
  'pinterest.com', 'threads.net', 'bsky.app', 'kick.com', 'odysee.com', 'mixcloud.com', 'vk.com', 'ok.ru',
  'nicovideo.jp', 'bitchute.com', 'imgur.com', 'tumblr.com', 'loom.com', 'wistia.com', 'archive.org',
];
// Raw player streams from these hosts can't be fetched outside the player.
const SKIP_STREAM_HOSTS = ['googlevideo.com'];

const hostOf = (url) => { try { return new URL(url).hostname.toLowerCase(); } catch { return ''; } };
const hostMatches = (host, list) => list.some((d) => host === d || host.endsWith(`.${d}`));
const isSiteUrl = (url) => /^https?:/.test(url || '') && hostMatches(hostOf(url), SITE_HOSTS);

// ---------------------------------------------------------------- state

/** tabId -> { items: Map<key,item>, children: Set<url>, verified: Set<url>, pageKey, saveTimer } */
const tabs = new Map();
const pending = new Map();      // requestId -> { headers, method }
const recentPosts = new Map();  // url -> time of a top-level POST (can't be replayed)
const ownDownloads = new Set(); // download ids we started
const siteCache = new Map();    // canonical page URL -> { status, data, error, ts, promise }
const linkNames = new Map();    // url -> { name, ts } from <a download="name">
let bypassUntil = 0;            // Option/Alt-click: let the browser keep the next download
let probing = 0;
const probeQueue = [];

let settings = { ...DEFAULT_SETTINGS };
let appStatus = { checkedAt: 0, ok: false, info: null, error: null };

const ready = (async () => {
  const stored = await chrome.storage.local.get('settings');
  settings = { ...DEFAULT_SETTINGS, ...(stored.settings || {}) };
  // Saved settings that still hold the old default type list get the new one (with PDF and documents).
  if (settings.catchExtensions === OLD_DEFAULT_TYPES) settings.catchExtensions = DEFAULT_SETTINGS.catchExtensions;
  const saved = await session.get(null);
  const open = new Set((await chrome.tabs.query({})).map((t) => t.id));
  for (const [k, v] of Object.entries(saved)) {
    if (!k.startsWith('t:')) continue;
    const tabId = Number(k.slice(2));
    if (!open.has(tabId)) { session.remove(k); continue; }
    const st = tabState(tabId);
    st.pageKey = v.pageKey || null;
    for (const c of v.children || []) st.children.add(c);
    for (const it of v.items || []) if (!st.items.has(it.key)) st.items.set(it.key, it);
  }
})().catch((e) => console.warn('[castnet] restore failed', e));

function tabState(tabId) {
  let st = tabs.get(tabId);
  if (!st) {
    st = { items: new Map(), children: new Set(), verified: new Set(), pageKey: null, saveTimer: null };
    tabs.set(tabId, st);
  }
  return st;
}

function scheduleSave(tabId) {
  const st = tabs.get(tabId);
  if (!st) return;
  clearTimeout(st.saveTimer);
  st.saveTimer = setTimeout(() => {
    session.set({
      [`t:${tabId}`]: { pageKey: st.pageKey, children: [...st.children].slice(-300), items: [...st.items.values()] },
    }).catch(() => {});
  }, 400);
}

function clearTab(tabId, keepUrl) {
  const st = tabs.get(tabId);
  if (!st) return;
  for (const [k, it] of st.items) if (!keepUrl || it.url !== keepUrl) st.items.delete(k);
  st.children.clear();
  st.verified.clear();
  scheduleSave(tabId);
  updateBadge(tabId);
}

function hash(s) {
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0;
  return h.toString(36);
}

function pageKeyOf(url) {
  try {
    const u = new URL(url);
    for (const p of ['t', 'start', 'time', 'time_continue', 'ts']) u.searchParams.delete(p);
    u.hash = '';
    return u.toString();
  } catch {
    return url;
  }
}

/** One cache key per video page (youtu.be/X, /shorts/X, /embed/X and watch?v=X are the same video). */
function canonicalPage(url) {
  try {
    const u = new URL(url);
    const h = u.hostname.replace(/^www\.|^m\.|^music\./, '');
    let id = null;
    if (h === 'youtu.be') id = u.pathname.slice(1).split('/')[0];
    else if (h.endsWith('youtube.com') || h.endsWith('youtube-nocookie.com')) {
      id = u.searchParams.get('v') || (/^\/(?:shorts|embed|live|v)\/([\w-]{6,})/.exec(u.pathname) || [])[1];
    }
    if (id) return `https://www.youtube.com/watch?v=${id}`;
  } catch { /* fall through */ }
  return pageKeyOf(url);
}

function isDisabledUrl(url) {
  const h = hostOf(url);
  return !!h && hostMatches(h, settings.disabledHosts || []);
}

// Headers worth replaying from the Mac app. Cookies travel separately as a jar.
const DROP_HEADERS = new Set([
  'range', 'if-range', 'if-none-match', 'if-modified-since', 'host', 'connection', 'content-length',
  'accept-encoding', 'cookie', 'priority', 'upgrade-insecure-requests', 'te', 'keep-alive', 'proxy-authorization',
]);
function pickHeaders(requestHeaders) {
  const out = {};
  for (const h of requestHeaders || []) {
    const n = h.name.toLowerCase();
    if (DROP_HEADERS.has(n) || n.startsWith('sec-') || n.startsWith(':')) continue;
    if (h.value != null) out[h.name] = h.value;
  }
  return out;
}

function visibleItems(tabId) {
  const st = tabs.get(tabId);
  if (!st) return [];
  return [...st.items.values()].filter((it) => !st.children.has(it.url) && !it.hidden &&
    !hostMatches(hostOf(it.url), SKIP_STREAM_HOSTS));
}

async function updateBadge(tabId) {
  let tab = null;
  try { tab = await chrome.tabs.get(tabId); } catch { return; }
  if (isDisabledUrl(tab.url)) {
    chrome.action.setBadgeText({ tabId, text: 'off' }).catch(() => {});
    chrome.action.setBadgeBackgroundColor({ tabId, color: '#8a94a6' }).catch(() => {});
    return;
  }
  const n = sniffedEntries(tabId).filter((e) => !e.disabled).length;
  chrome.action.setBadgeText({ tabId, text: n ? String(n) : '' }).catch(() => {});
  chrome.action.setBadgeBackgroundColor({ tabId, color: '#1f6fd1' }).catch(() => {});
}

// ---------------------------------------------------------------- adding media

async function addItem(tabId, frameId, data) {
  await ready;
  if (tabId == null || tabId < 0) return null;
  const st = tabState(tabId);
  const url = normalizeMediaUrl(data.url);
  if (st.children.has(url)) return null;
  const key = `${data.kind}|${url}`;
  let item = st.items.get(key);
  const now = Date.now();

  // Numbered .mp4/.m4a pieces next to an HLS/DASH stream are segments.
  if (data.kind === KIND.FILE && [...st.items.values()].some((i) => i.kind !== KIND.FILE) &&
      /(?:^|[/_\-.])\d{1,6}\.(?:mp4|m4a|m4v|aac|webm)$/i.test(new URL(url).pathname)) {
    return null;
  }

  if (item) {
    item.lastSeen = now;
    if (data.size && !item.size) item.size = data.size;
    if (data.headers && Object.keys(data.headers).length && !Object.keys(item.headers || {}).length) item.headers = data.headers;
  } else {
    if (st.items.size >= MAX_ITEMS_PER_TAB) {
      const oldest = [...st.items.values()].sort((a, b) => a.lastSeen - b.lastSeen)[0];
      st.items.delete(oldest.key);
    }
    let tab = null;
    try { tab = await chrome.tabs.get(tabId); } catch { return null; }
    item = {
      id: hash(key), key, url, kind: data.kind, ext: data.ext, mime: data.mime || '',
      size: data.size ?? null, filename: data.filename || null, audioOnly: !!data.audioOnly,
      frameId: frameId ?? 0, source: data.source || 'network', headers: data.headers || {},
      pageUrl: tab.url, title: tab.title || '', firstSeen: now, lastSeen: now,
      variants: [], audio: [], duration: null, live: false, drm: false, encrypted: false,
      tracks: data.audioOnly && !PROBE_EXT.has(data.ext) ? 'audio' : null, width: null, height: null,
      parsed: data.kind === KIND.FILE, probed: false,
    };
    st.items.set(key, item);
    if (item.kind !== KIND.FILE) inspectManifest(tabId, item);
    else if (PROBE_EXT.has(item.ext)) enqueueProbe(tabId, item);
  }
  scheduleSave(tabId);
  updateBadge(tabId);
  maybeRenew(tabId);
  return item;
}

function enqueueProbe(tabId, item) {
  probeQueue.push([tabId, item]);
  pumpProbes();
}

function pumpProbes() {
  while (probing < 3 && probeQueue.length) {
    const [tabId, item] = probeQueue.shift();
    probing++;
    probeUrl(item.url)
      .then((r) => {
        if (!r) return;
        item.tracks = r.tracks ?? item.tracks;
        item.width = r.width ?? item.width;
        item.height = r.height ?? item.height;
        item.duration = r.duration || item.duration;
        if (r.size) item.size = r.size;
      })
      .catch(() => {})
      .finally(() => {
        item.probed = true;
        // Small files are only interesting as the sound track of a separate video stream.
        const min = settings.minMediaSizeKB * 1024;
        if (item.tracks !== 'audio' && item.size != null && item.size < min) item.hidden = true;
        if (item.tracks === 'audio') item.audioOnly = true;
        probing--;
        scheduleSave(tabId);
        updateBadge(tabId);
        maybeRenew(tabId);
        pumpProbes();
      });
  }
}

async function inspectManifest(tabId, item) {
  try {
    const res = await fetch(item.url, { credentials: 'include', cache: 'no-store' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const text = await res.text();
    const st = tabs.get(tabId);
    if (!st) return;
    if (item.kind === KIND.HLS) {
      const p = parseM3U8(text, res.url || item.url);
      if (!p) { item.hidden = true; return; }
      item.drm = p.drm;
      if (p.type === 'master') {
        item.variants = p.variants.map((v) => ({ url: v.url, height: v.height, width: v.width, bandwidth: v.bandwidth, fps: v.fps }));
        item.audio = p.audio;
        for (const v of p.variants) st.children.add(normalizeMediaUrl(v.url));
        for (const a of p.audio) st.children.add(normalizeMediaUrl(a.url));
        // One variant playlist gives the duration (for size estimates) and the live flag.
        const first = p.variants[p.variants.length - 1];
        if (first) {
          try {
            const r2 = await fetch(first.url, { credentials: 'include', cache: 'no-store' });
            const media = parseM3U8(await r2.text(), r2.url || first.url);
            if (media?.type === 'media') {
              item.duration = media.live ? null : media.duration || null;
              item.live = media.live;
              item.drm = item.drm || media.drm;
            }
          } catch { /* sizes stay unknown */ }
        }
      } else {
        item.duration = p.duration || null;
        item.live = p.live;
        item.encrypted = p.encrypted;
      }
    } else if (item.kind === KIND.DASH) {
      const p = parseMPD(text);
      if (!p) { item.hidden = true; return; }
      item.drm = p.drm;
      item.live = p.live;
      item.duration = p.duration;
      item.variants = p.variants.map((v) => ({ url: item.url, height: v.height, width: v.width, bandwidth: v.bandwidth }));
      item.audio = p.audio;
      if (!p.variants.length && p.audio.length) item.audioOnly = true;
    }
    item.parsed = true;
  } catch (e) {
    item.parseError = String(e.message || e);
  } finally {
    scheduleSave(tabId);
    updateBadge(tabId);
    maybeRenew(tabId);
  }
}

// Checks a URL found in the page (not seen on the network yet): a 1-byte range GET reveals type and size.
async function verifyCandidate(tabId, frameId, url, source) {
  if (!/^https?:/i.test(url)) return;
  const st = tabState(tabId);
  const norm = normalizeMediaUrl(url);
  if (st.verified.has(norm) || st.verified.size >= MAX_VERIFY_PER_TAB) return;
  if ([...st.items.values()].some((i) => i.url === norm) || st.children.has(norm)) return;
  if (hostMatches(hostOf(norm), SKIP_STREAM_HOSTS)) return;
  st.verified.add(norm);
  if (looksLikeSegment(norm)) return;
  const ext = extOf(norm);
  try {
    if (ext === 'm3u8' || ext === 'mpd') {
      await addItem(tabId, frameId, { url: norm, kind: ext === 'm3u8' ? KIND.HLS : KIND.DASH, ext, source });
      return;
    }
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 8000);
    const res = await fetch(norm, { credentials: 'include', headers: { Range: 'bytes=0-0' }, signal: ctrl.signal, cache: 'no-store' });
    clearTimeout(timer);
    const headers = [...res.headers].map(([name, value]) => ({ name, value }));
    res.body?.cancel().catch(() => {});
    const c = classifyResponse({ url: res.url || norm, statusCode: res.status, responseHeaders: headers, method: 'GET' },
      { minSize: PROBE_EXT.has(ext) ? PROBE_MIN_BYTES : settings.minMediaSizeKB * 1024 });
    if (c) await addItem(tabId, frameId, { ...c, url: res.url || norm, source });
  } catch { /* unreachable or blocked: ignore */ }
}

// ---------------------------------------------------------------- webRequest sniffing

if (HAS_WEBREQUEST) {
chrome.webRequest.onBeforeRequest.addListener((d) => {
  if (d.method === 'POST' && (d.type === 'main_frame' || d.type === 'sub_frame')) {
    recentPosts.set(d.url, Date.now());
    if (recentPosts.size > 50) recentPosts.delete(recentPosts.keys().next().value);
  }
}, { urls: ['http://*/*', 'https://*/*'], types: ['main_frame', 'sub_frame'] });

chrome.webRequest.onSendHeaders.addListener((d) => {
  if (d.tabId < 0) return;
  pending.set(d.requestId, { headers: d.requestHeaders, method: d.method });
  if (pending.size > 3000) for (const k of [...pending.keys()].slice(0, 1000)) pending.delete(k);
}, { urls: ['http://*/*', 'https://*/*'], types: WATCH_TYPES }, ['requestHeaders', ...EXTRA_HEADERS]);

chrome.webRequest.onHeadersReceived.addListener((d) => {
  if (d.tabId < 0) return;
  const chunked = hasRangeParam(d.url);
  const ext = extOf(d.url);
  const mime = (d.responseHeaders || []).find((h) => h.name.toLowerCase() === 'content-type')?.value || '';
  const probeable = PROBE_EXT.has(ext) || /^(video|audio)\/(mp4|webm|quicktime|x-matroska)/i.test(mime);
  const c = classifyResponse(d, {
    minSize: chunked ? 0 : probeable ? PROBE_MIN_BYTES : settings.minMediaSizeKB * 1024,
    chunked,
  });
  if (!c) return;
  const req = pending.get(d.requestId);
  if (c.kind !== KIND.FILE && req && req.method !== 'GET') return; // POST manifests can't be replayed
  addItem(d.tabId, d.frameId, { ...c, url: d.url, source: 'network', headers: pickHeaders(req?.headers) });
}, { urls: ['http://*/*', 'https://*/*'], types: WATCH_TYPES }, ['responseHeaders']);

const forget = (d) => pending.delete(d.requestId);
chrome.webRequest.onCompleted.addListener(forget, { urls: ['http://*/*', 'https://*/*'], types: WATCH_TYPES });
chrome.webRequest.onErrorOccurred.addListener(forget, { urls: ['http://*/*', 'https://*/*'], types: WATCH_TYPES });
}

// ---------------------------------------------------------------- navigation bookkeeping

chrome.webNavigation.onCommitted.addListener(async (d) => {
  if (d.frameId !== 0) return;
  await ready;
  const st = tabState(d.tabId);
  st.pageKey = pageKeyOf(d.url);
  clearTab(d.tabId, normalizeMediaUrl(d.url));
});

chrome.webNavigation.onHistoryStateUpdated.addListener(async (d) => {
  if (d.frameId !== 0) return;
  await ready;
  const st = tabState(d.tabId);
  const key = pageKeyOf(d.url);
  if (st.pageKey && st.pageKey !== key) clearTab(d.tabId);
  st.pageKey = key;
});

chrome.tabs.onRemoved.addListener((tabId) => {
  tabs.delete(tabId);
  session.remove(`t:${tabId}`).catch(() => {});
});

chrome.tabs.onReplaced?.addListener((added, removed) => {
  const st = tabs.get(removed);
  if (st) { tabs.set(added, st); tabs.delete(removed); scheduleSave(added); }
});

// ---------------------------------------------------------------- native messaging

const OWN_VERSION = chrome.runtime.getManifest().version;

function sendNative(message, timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('The Castnet app did not answer in time.')), timeoutMs);
    // ext: the app shows when a browser runs an older version of this extension.
    chrome.runtime.sendNativeMessage(HOST, { ...message, ext: OWN_VERSION }, (response) => {
      clearTimeout(timer);
      const err = chrome.runtime.lastError;
      if (err) reject(new Error(err.message));
      else resolve(response);
    });
  });
}

async function getAppStatus(force = false) {
  if (!force && Date.now() - appStatus.checkedAt < 30000) return appStatus;
  try {
    const info = await sendNative({ type: 'ping' }, 5000);
    appStatus = { checkedAt: Date.now(), ok: !!info?.ok, info, error: info?.ok ? null : info?.error };
    if (info?.renewals > 0 && !renewalList.length) setTimeout(() => checkRenewals(), 0);
  } catch (e) {
    const msg = String(e.message || e);
    appStatus = {
      checkedAt: Date.now(), ok: false, info: null,
      error: /not found|not installed|forbidden/i.test(msg) ? 'The Castnet app isn’t installed, or hasn’t been opened yet.' : msg,
    };
  }
  return appStatus;
}

async function cookiesFor(urls) {
  const seen = new Map();
  for (const url of new Set(urls)) {
    if (!url || !/^https?:/i.test(url)) continue;
    try {
      for (const c of (await chrome.cookies?.getAll({ url })) || []) {
        const k = `${c.domain}|${c.path}|${c.name}`;
        if (!seen.has(k)) {
          seen.set(k, {
            name: c.name, value: c.value, domain: c.domain, path: c.path, secure: c.secure,
            httpOnly: c.httpOnly, hostOnly: c.hostOnly, expirationDate: c.expirationDate ?? null,
          });
        }
      }
    } catch { /* ignore */ }
  }
  return [...seen.values()];
}

// ---------------------------------------------------------------- site qualities (YouTube etc.)

function siteState(pageUrl) {
  const key = canonicalPage(pageUrl);
  let st = siteCache.get(key);
  if (st && (st.status === 'loading' || Date.now() - st.ts < (st.status === 'ok' ? 20 * 60000 : 60000))) return st;
  st = { key, url: key.startsWith('https://www.youtube.com/watch') ? key : pageUrl, status: 'loading', data: null, error: null, ts: Date.now() };
  siteCache.set(key, st);
  if (siteCache.size > 60) siteCache.delete(siteCache.keys().next().value);
  st.promise = (async () => {
    try {
      const status = await getAppStatus();
      if (!status.ok || !status.info?.ytdlp) throw new Error('unavailable');
      const res = await sendNative({
        type: 'formats',
        request: { url: st.url, kind: 'ytdlp', pageUrl: st.url, userAgent: navigator.userAgent, cookies: await cookiesFor([st.url]) },
      }, 110000);
      if (!res?.ok) throw new Error(res?.error || 'No video found');
      st.data = res.formats;
      st.status = res.formats?.options?.length ? 'ok' : 'empty';
    } catch (e) {
      st.status = 'error';
      st.error = String(e.message || e);
    }
    st.ts = Date.now();
  })();
  return st;
}

// ---------------------------------------------------------------- the quality menu

const heightLabel = (h, fps) => (h ? `${h}p${fps && fps > 31 ? Math.round(fps) : ''}` : null);

/** Turns sniffed items into menu entries: one row per downloadable quality. */
function sniffedEntries(tabId, preferFrame) {
  const items = visibleItems(tabId);
  const out = [];
  const name = (it) => it.title || it.filename || '';

  for (const it of items.filter((i) => i.kind !== KIND.FILE)) {
    if (it.drm) { out.push({ key: `drm:${it.id}`, quality: 'Protected', format: '', note: 'DRM: cannot be downloaded', disabled: true, group: 'drm' }); continue; }
    const fmt = it.audioOnly ? 'M4A' : 'MP4';
    if (it.variants?.length) {
      const seen = new Set();
      for (const v of it.variants) {
        const q = heightLabel(v.height, v.fps) || 'Auto';
        if (seen.has(q)) continue;
        seen.add(q);
        const size = v.bandwidth && it.duration ? Math.round((v.bandwidth / 8) * it.duration) : null;
        out.push({ key: `${it.id}:${q}`, quality: q, height: v.height || 0, format: fmt, size, sizeApprox: true,
          note: it.live ? 'Live' : '', group: 'video', title: name(it), copyUrl: it.kind === KIND.HLS ? v.url : it.url,
          action: { kind: 'item', itemId: it.id, variantUrl: it.kind === KIND.HLS ? v.url : null, quality: v.height || null } });
      }
    } else {
      out.push({ key: it.id, quality: it.audioOnly ? 'Audio' : (it.live ? 'Live' : 'Video'), height: 1, format: fmt,
        note: it.live ? 'Live stream' : humanDuration(it.duration), group: it.audioOnly ? 'audio' : 'video', title: name(it),
        copyUrl: it.url, action: { kind: 'item', itemId: it.id } });
    }
  }

  const files = items.filter((i) => i.kind === KIND.FILE);
  const audios = files.filter((i) => i.tracks === 'audio' || (i.tracks == null && i.audioOnly));
  const videosOnly = files.filter((i) => i.tracks === 'video');
  const complete = files.filter((i) => !audios.includes(i) && !videosOnly.includes(i));
  // Best sound track: highest bitrate if we know duration, else biggest.
  const rate = (a) => (a.size || 0) / (a.duration || 1);
  const bestAudio = [...audios].sort((a, b) => rate(b) - rate(a))[0] || null;

  for (const it of complete) {
    const q = heightLabel(it.height) || (it.ext || 'file').toUpperCase();
    out.push({ key: it.id, quality: q, height: it.height || 0, format: (it.ext || '').toUpperCase(), size: it.size,
      note: it.duration ? humanDuration(it.duration) : '', group: 'video', title: name(it), copyUrl: it.url,
      action: { kind: 'item', itemId: it.id } });
  }
  // Video-only streams (Facebook, Instagram, Reddit, Vimeo…): one row each, merged with the sound track.
  const byHeight = new Map();
  for (const v of videosOnly) {
    const k = v.height || 0;
    if (!byHeight.has(k) || (v.size || 0) > (byHeight.get(k).size || 0)) byHeight.set(k, v);
  }
  for (const v of byHeight.values()) {
    const size = v.size != null ? v.size + (bestAudio?.size || 0) : null;
    out.push({ key: `${v.id}+${bestAudio?.id || ''}`, quality: heightLabel(v.height) || 'Video', height: v.height || 0,
      format: 'MP4', size, note: bestAudio ? '' : 'no sound found yet', group: 'video', title: name(v), copyUrl: v.url,
      action: { kind: 'item', itemId: v.id, audioId: bestAudio?.id || null } });
  }
  if (bestAudio) {
    out.push({ key: bestAudio.id, quality: 'Audio', height: -1, format: (bestAudio.ext === 'mp4' ? 'M4A' : bestAudio.ext || 'audio').toUpperCase(),
      size: bestAudio.size, note: '', group: 'audio', title: name(bestAudio), copyUrl: bestAudio.url,
      action: { kind: 'item', itemId: bestAudio.id } });
  }
  // Order: frame under the cursor first, then video by resolution, audio, protected.
  const frameOf = (e) => items.find((i) => i.id === e.action?.itemId)?.frameId;
  const groupRank = { video: 0, audio: 1, drm: 2 };
  return out.sort((a, b) =>
    (preferFrame != null ? (frameOf(b) === preferFrame) - (frameOf(a) === preferFrame) : 0) ||
    groupRank[a.group] - groupRank[b.group] || (b.height || 0) - (a.height || 0) || (b.size || 0) - (a.size || 0));
}

function siteEntries(st) {
  return st.data.options.map((o) => ({
    key: `site:${o.id}`, quality: o.label, height: o.height || (o.audioOnly ? -1 : 0), format: o.ext, size: o.size,
    sizeApprox: o.sizeIsEstimate, note: st.data.isLive ? 'Live' : '', group: o.audioOnly ? 'audio' : 'video',
    title: st.data.title, action: { kind: 'site', page: st.key, optionId: o.id },
  }));
}

/**
 * The menu for a tab (and frame). `explicit` = the user opened the menu, which allows a
 * site lookup even on pages that aren't known video sites.
 */
async function buildMenu(tabId, { frameId = null, frameUrl = null, explicit = false } = {}) {
  await ready;
  let tab;
  try { tab = await chrome.tabs.get(tabId); } catch { return { entries: [], status: 'empty' }; }
  const app = await getAppStatus();
  const appView = { ok: app.ok, error: app.error, running: !!app.info?.running };
  const disabled = isDisabledUrl(tab.url);
  const sniffed = sniffedEntries(tabId, frameId);
  const title = tab.title || '';

  // Which page to ask the site extractor about: an embedded player's own page, else the tab.
  const pageForSite = frameUrl && frameId && isSiteUrl(frameUrl) ? frameUrl : tab.url;
  const canSite = app.ok && app.info?.ytdlp && /^https?:/.test(pageForSite);
  let site = null;
  if (canSite && (isSiteUrl(pageForSite) || (explicit && !sniffed.length))) site = siteState(pageForSite);

  let entries = sniffed;
  let status = sniffed.length ? 'ready' : 'empty';
  if (site?.status === 'ok') { entries = siteEntries(site); status = 'ready'; }
  else if (site?.status === 'loading' && !sniffed.length) status = 'loading';
  else if (site?.status === 'loading' && isSiteUrl(pageForSite)) status = 'loading-more';
  return { title, entries, status, app: appView, disabled, host: hostOf(tab.url) };
}

// ---------------------------------------------------------------- downloading

function fileName(title, label, ext, fallbackUrl) {
  let base = sanitizeFilename(title || '', '');
  if (!base) {
    try { base = sanitizeFilename(decodeURIComponent(new URL(fallbackUrl).pathname.split('/').pop()).replace(/\.[a-z0-9]{2,5}$/i, ''), 'video'); }
    catch { base = 'video'; }
  }
  return `${base}${label ? ` [${label}]` : ''}.${ext || 'mp4'}`;
}

async function startItemDownload(tabId, action) {
  const all = visibleItems(tabId);
  const item = all.find((i) => i.id === action.itemId);
  if (!item) return { ok: false, error: 'This video is no longer listed. Reload the page and play it again.' };
  if (item.drm) return { ok: false, error: 'This video is DRM-protected and can’t be downloaded.' };
  const audio = action.audioId ? all.find((i) => i.id === action.audioId) : null;
  const height = action.quality || item.height || null;
  const label = item.audioOnly || item.tracks === 'audio' ? null : (height ? `${height}p` : null);
  // The title may not have been loaded when the media was first seen (it can still be the address).
  const tab = await chrome.tabs.get(tabId).catch(() => null);
  if (tab?.title && !/^(https?:\/\/|[\w.-]+(:\d+)?\/)/.test(tab.title) && tab.title !== tab.url) item.title = tab.title;
  let ext = item.kind === KIND.FILE ? (item.ext || 'mp4') : (item.audioOnly ? 'm4a' : 'mp4');
  if (item.tracks === 'audio' && ext === 'mp4') ext = 'm4a';
  if (audio) ext = 'mp4';
  const request = {
    url: item.url,
    kind: item.kind,
    filename: item.filename && !audio ? sanitizeFilename(item.filename) : fileName(item.title, label, ext, item.url),
    title: item.title,
    pageUrl: item.pageUrl,
    referer: item.headers.Referer || item.headers.referer || item.pageUrl,
    userAgent: navigator.userAgent,
    headers: item.headers,
    cookies: await cookiesFor([item.url, item.pageUrl, action.variantUrl, audio?.url, ...(item.audio || []).map((a) => a.url)]),
    variantUrl: item.kind === KIND.HLS ? (action.variantUrl || null) : null,
    quality: action.quality ?? null,
    size: item.size,
    audioUrl: audio?.url || null,
  };
  const status = await getAppStatus();
  if (status.ok) {
    try {
      const res = await sendNative({ type: 'download', request });
      if (res?.ok) return { ok: true, via: 'app', renewed: !!res.renewed, existing: !!res.existing };
      if (item.kind !== KIND.FILE || audio) return { ok: false, error: res?.error || 'The Castnet app refused the download.' };
    } catch (e) {
      if (item.kind !== KIND.FILE || audio) return { ok: false, error: String(e.message || e) };
    }
  }
  if (item.kind === KIND.FILE && !audio) {
    if (!chrome.downloads) { await chrome.tabs.create({ url: item.url }); return { ok: true, via: 'browser' }; }
    const id = await chrome.downloads.download({ url: item.url, filename: request.filename, conflictAction: 'uniquify' });
    ownDownloads.add(id);
    return { ok: true, via: 'browser' };
  }
  return { ok: false, error: 'This video needs the Castnet app. Open Castnet, then try again.' };
}

async function startSiteDownload(action) {
  const st = siteCache.get(action.page);
  const opt = st?.data?.options?.find((o) => o.id === action.optionId);
  if (!opt) return { ok: false, error: 'The quality list expired. Open the menu again.' };
  const ext = opt.audioOnly ? (opt.ext === 'OPUS' ? 'webm' : opt.ext.toLowerCase()) : (opt.container || 'mp4');
  const request = {
    url: st.url, kind: 'ytdlp', pageUrl: st.url, title: st.data.title,
    filename: fileName(st.data.title, opt.audioOnly ? null : opt.label, ext, st.url),
    format: opt.format, container: opt.container || null, quality: opt.height || null, size: opt.size || null,
    // Same session type the list was made with (YouTube: anonymous unless the video needs the login).
    useCookies: st.data.useCookies === true,
    userAgent: navigator.userAgent, headers: {}, cookies: await cookiesFor([st.url]),
  };
  try {
    const res = await sendNative({ type: 'download', request });
    return res?.ok ? { ok: true, via: 'app' } : { ok: false, error: res?.error || 'The Castnet app refused the download.' };
  } catch (e) {
    return { ok: false, error: String(e.message || e) };
  }
}

function startDownload(tabId, action) {
  if (action?.kind === 'site') return startSiteDownload(action);
  if (action?.kind === 'item') return startItemDownload(tabId, action);
  return Promise.resolve({ ok: false, error: 'Nothing to download.' });
}

/** Plain URL (context menu, picker): app if available, else the browser. */
async function downloadUrls(list, { referer, pageUrl } = {}) {
  const status = await getAppStatus();
  if (status.ok) {
    const cookies = await cookiesFor([...list.map((l) => l.url), pageUrl]);
    const requests = list.map((l) => {
      const ext = extOf(l.url);
      const kind = ext === 'm3u8' ? KIND.HLS : ext === 'mpd' ? KIND.DASH : KIND.FILE;
      const host = hostOf(l.url);
      return {
        url: l.url, kind, filename: l.name ? sanitizeFilename(l.name) : (linkNames.get(l.url)?.name || null), pageUrl,
        referer: referer || pageUrl, userAgent: navigator.userAgent, headers: referer ? { Referer: referer } : {},
        cookies: cookies.filter((c) => host === c.domain.replace(/^\./, '') || host.endsWith(c.domain.startsWith('.') ? c.domain : `.${c.domain}`)),
      };
    });
    try {
      const res = await sendNative(requests.length === 1 ? { type: 'download', request: requests[0] } : { type: 'downloadBatch', requests });
      if (res?.ok) return { ok: true, via: 'app', count: requests.length };
    } catch { /* fall back below */ }
  }
  for (const l of list) {
    if (['m3u8', 'mpd'].includes(extOf(l.url))) continue;
    if (!chrome.downloads) { chrome.tabs.create({ url: l.url, active: false }); continue; }
    const id = await chrome.downloads.download({ url: l.url, conflictAction: 'uniquify' }).catch(() => null);
    if (id != null) ownDownloads.add(id);
  }
  return { ok: true, via: 'browser', count: list.length };
}

// ---------------------------------------------------------------- link renewal (never lose a download)
//
// When a download's link expires, the app lists it under "renewals". The extension then finds
// a fresh link for the same file: first among media already detected in open tabs (same size,
// or same stream address), otherwise by reopening the video's page in a muted background tab
// so the player requests a new link. The app checks the bytes match and continues the download.

let renewalList = [];
const renewing = new Set();
const deadLinks = new Set(); // addresses that already failed a renewal check
const renewalTabs = new Map(); // tabId -> { entry, started }

function samePath(a, host, path) {
  try { const u = new URL(a); return u.hostname === host && u.pathname === path; } catch { return false; }
}

function renewalMatch(entry, tabIds) {
  for (const tabId of tabIds) {
    const items = visibleItems(tabId).filter((i) => i.url !== entry.url && i.url !== entry.audioUrl && !deadLinks.has(i.url));
    if (entry.kind === 'hls' || entry.kind === 'dash') {
      const m = items.find((i) => i.kind === entry.kind && samePath(i.url, entry.host, entry.path));
      if (m) return { tabId, video: m };
      continue;
    }
    const video = items.find((i) => i.kind === KIND.FILE && i.size === entry.size);
    if (!video) continue;
    if (entry.audioSize) {
      const audio = items.find((i) => i.kind === KIND.FILE && i.size === entry.audioSize);
      if (audio) return { tabId, video, audio };
      continue;
    }
    return { tabId, video };
  }
  return null;
}

async function sendRenewal(entry, match) {
  renewing.add(entry.id);
  try {
    const { video, audio } = match;
    const request = {
      url: video.url, kind: video.kind, pageUrl: video.pageUrl, title: video.title, size: video.size ?? null,
      referer: video.headers.Referer || video.headers.referer || video.pageUrl, userAgent: navigator.userAgent,
      headers: video.headers, audioUrl: audio?.url || null,
      cookies: await cookiesFor([video.url, video.pageUrl, audio?.url]),
    };
    const res = await sendNative({ type: 'renew', id: entry.id, request }, 45000);
    if (!res?.ok) { deadLinks.add(video.url); if (audio) deadLinks.add(audio.url); }
    if (res?.ok) {
      renewalList = renewalList.filter((e) => e.id !== entry.id);
      for (const [tabId, t] of renewalTabs) if (t.entry.id === entry.id) finishRenewalTab(tabId, true);
      return true;
    }
  } catch { /* try again on the next round */ } finally {
    renewing.delete(entry.id);
  }
  return false;
}

/** Called whenever a tab learns about new media: maybe it's a fresh link for an expired download. */
function maybeRenew(tabId) {
  if (!renewalList.length) return;
  for (const entry of renewalList) {
    if (renewing.has(entry.id)) continue;
    const m = renewalMatch(entry, [tabId]);
    if (m) sendRenewal(entry, m);
  }
}

async function openRenewalTab(entry) {
  try {
    const tab = await chrome.tabs.create({ url: entry.pageUrl, active: false });
    chrome.tabs.update(tab.id, { muted: true }).catch(() => {});
    renewalTabs.set(tab.id, { entry, started: Date.now() });
    setTimeout(() => finishRenewalTab(tab.id, false), 50000);
  } catch { /* no tab */ }
}

function finishRenewalTab(tabId, ok) {
  const t = renewalTabs.get(tabId);
  if (!t) return;
  renewalTabs.delete(tabId);
  chrome.tabs.remove(tabId).catch(() => {});
  if (!ok) sendNative({ type: 'renewFailed', id: t.entry.id }).catch(() => {});
}

async function checkRenewals() {
  for (const [tabId, t] of renewalTabs) if (Date.now() - t.started > 60000) finishRenewalTab(tabId, false);
  const status = await getAppStatus();
  if (!status.ok) return;
  let res;
  try { res = await sendNative({ type: 'renewals' }, 8000); } catch { return; }
  renewalList = res?.items || [];
  const allTabs = (await chrome.tabs.query({})).map((t) => t.id);
  for (const entry of renewalList) {
    if (renewing.has(entry.id) || [...renewalTabs.values()].some((t) => t.entry.id === entry.id)) continue;
    const m = renewalMatch(entry, allTabs);
    if (m) { sendRenewal(entry, m); continue; }
    if (entry.pageUrl && /^https?:/.test(entry.pageUrl) && (entry.attempts || 0) < 3) openRenewalTab(entry);
  }
}

chrome.alarms?.create('castnet-renew', { periodInMinutes: 1 });
chrome.alarms?.onAlarm.addListener((a) => { if (a.name === 'castnet-renew') checkRenewals(); });

// The renewal tab finished loading: start the player (muted) so it requests the media.
chrome.webNavigation.onCompleted.addListener((d) => {
  if (d.frameId === 0 && renewalTabs.has(d.tabId)) {
    chrome.tabs.sendMessage(d.tabId, { type: 'renewalPlay' }).catch(() => {});
    setTimeout(() => chrome.tabs.sendMessage(d.tabId, { type: 'renewalPlay' }).catch(() => {}), 2500);
  }
});

// ---------------------------------------------------------------- download all / selected links

async function collectLinks(tabId, selectedOnly) {
  const frames = await chrome.webNavigation.getAllFrames({ tabId }).catch(() => [{ frameId: 0 }]);
  const found = new Map();
  for (const f of frames || [{ frameId: 0 }]) {
    try {
      const r = await chrome.tabs.sendMessage(tabId, { type: 'collectLinks', selectedOnly }, { frameId: f.frameId });
      for (const l of r?.links || []) if (!found.has(l.url)) found.set(l.url, l);
    } catch { /* frame without our content script */ }
  }
  return [...found.values()];
}

async function openLinkPicker(tabId, selectedOnly) {
  const tab = await chrome.tabs.get(tabId);
  const links = await collectLinks(tabId, selectedOnly);
  if (!links.length) {
    notify('Castnet', selectedOnly ? 'No links in the selection.' : 'No links found on this page. Reload it and try again.');
    return;
  }
  const key = `pick:${Date.now()}`;
  await session.set({ [key]: { links, pageUrl: tab.url, title: tab.title, selectedOnly } });
  await chrome.windows.create({ url: `picker/picker.html?key=${encodeURIComponent(key)}`, type: 'popup', width: 940, height: 660 });
}

// ---------------------------------------------------------------- messages from content scripts, popup & picker

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  const fromTab = sender.tab?.id;
  (async () => {
    await ready;
    switch (msg?.type) {
      case 'candidates': {
        if (fromTab == null) return {};
        for (const u of (msg.urls || []).slice(0, 20)) verifyCandidate(fromTab, sender.frameId, u, msg.source || 'page');
        return {};
      }
      case 'getMenu':
        return buildMenu(msg.tabId ?? fromTab, {
          frameId: fromTab != null ? sender.frameId : null,
          frameUrl: fromTab != null ? sender.url : null,
          explicit: !!msg.explicit,
        });
      case 'prefetch': {
        // A video started playing: warm up the quality list for known video sites.
        if (fromTab == null) return {};
        const url = sender.frameId && isSiteUrl(sender.url) ? sender.url : sender.tab.url;
        const app = await getAppStatus();
        if (app.ok && app.info?.ytdlp && isSiteUrl(url) && !isDisabledUrl(sender.tab.url)) siteState(url);
        return {};
      }
      case 'download':
        return startDownload(msg.tabId ?? fromTab, msg.action);
      case 'clear':
        clearTab(msg.tabId);
        return { ok: true };
      case 'getSettings': {
        const url = msg.url || sender.tab?.url || '';
        return { settings, disabled: isDisabledUrl(url) };
      }
      case 'setSettings':
        settings = { ...settings, ...(msg.settings || {}) };
        await chrome.storage.local.set({ settings });
        return { settings };
      case 'toggleSite': {
        const h = (msg.host || '').toLowerCase().replace(/^www\./, '');
        const list = new Set(settings.disabledHosts || []);
        if (msg.enabled) { list.delete(h); list.delete(`www.${h}`); } else list.add(h);
        settings = { ...settings, disabledHosts: [...list] };
        await chrome.storage.local.set({ settings });
        for (const t of await chrome.tabs.query({})) updateBadge(t.id);
        return { settings };
      }
      case 'appStatus':
        return getAppStatus(!!msg.force);
      case 'checkRenewals':
        await checkRenewals();
        return { ok: true, pending: renewalList.length, tabs: renewalTabs.size };
      case 'openApp':
        try { return await sendNative({ type: 'show' }); } catch (e) { return { ok: false, error: String(e.message || e) }; }
      case 'bypass':
        bypassUntil = Date.now() + 5000;
        return {};
      case 'catchLink': {
        // A click on a PDF link (see content.js): Castnet downloads it if it can fetch it,
        // otherwise the page opens it as usual.
        const url = msg.url || '';
        const pageUrl = sender.tab?.url || null;
        if (!/^https?:/i.test(url) || !settings.catchDownloads || settings.catchPdfLinks === false || isDisabledUrl(pageUrl || url)) {
          return { ok: false };
        }
        let last = '';
        try { last = decodeURIComponent(new URL(url).pathname.split('/').pop() || ''); } catch { /* keep empty */ }
        const request = {
          url, kind: KIND.FILE, filename: msg.name || last || null, pageUrl, referer: pageUrl,
          userAgent: navigator.userAgent, headers: pageUrl ? { Referer: pageUrl } : {},
          cookies: await cookiesFor([url, pageUrl]), mime: /\.pdf$/i.test(last) ? 'application/pdf' : null,
        };
        try {
          // No separate check here: Castnet's own download is the only fetch, so a link that works
          // once isn't used up. If Castnet gets no data from it, the page opens it after all.
          const res = await sendNative({ type: 'download', request, waitForData: true }, 120000);
          return { ok: !!res?.ok };
        } catch {
          return { ok: false };
        }
      }
      case 'linkName':
        if (msg.url && msg.name) {
          linkNames.set(msg.url, { name: msg.name, ts: Date.now() });
          if (linkNames.size > 100) linkNames.delete(linkNames.keys().next().value);
        }
        return {};
      case 'grabLinks':
        await openLinkPicker(msg.tabId ?? fromTab, !!msg.selectedOnly);
        return { ok: true };
      case 'pickerData': {
        const data = (await session.get(msg.key))[msg.key];
        return data || null;
      }
      case 'downloadLinks': {
        const data = (await session.get(msg.key))[msg.key];
        const chosen = (data?.links || []).filter((l) => (msg.urls || []).includes(l.url));
        if (!chosen.length) return { ok: false, error: 'Nothing selected.' };
        const res = await downloadUrls(chosen, { referer: data.pageUrl, pageUrl: data.pageUrl });
        return res;
      }
      default:
        return { ok: false, error: 'unknown message' };
    }
  })().then(sendResponse, (e) => sendResponse({ ok: false, error: String(e?.message || e) }));
  return true;
});

// ---------------------------------------------------------------- context menus

// Say hello to the app when the browser starts or the extension is added, so the app's
// setup window can confirm the connection right away.
chrome.runtime.onStartup.addListener(() => { getAppStatus(true).then(checkRenewals); });

chrome.runtime.onInstalled.addListener(() => {
  getAppStatus(true);
  chrome.contextMenus?.removeAll(() => {
    const make = (props) => chrome.contextMenus.create(props, () => void chrome.runtime.lastError);
    make({ id: 'grab-link', title: 'Download with Castnet', contexts: ['link'] });
    make({ id: 'grab-media', title: 'Download this video with Castnet', contexts: ['video', 'audio'] });
    make({ id: 'grab-selected', title: 'Download selected links with Castnet', contexts: ['selection'] });
    make({ id: 'grab-all', title: 'Download all links with Castnet', contexts: ['page', 'frame'] });
    make({ id: 'grab-page', title: 'Download the video on this page', contexts: ['page', 'frame'] });
    // On the browser's own downloads page; ignored where browsers don't allow menus there.
    make({ id: 'grab-transfer', title: 'Transfer download to Castnet', contexts: ['link'], documentUrlPatterns: ['chrome://downloads/*'] });
  });
});

function notify(title, message) {
  chrome.notifications?.create({ type: 'basic', iconUrl: 'icons/icon128.png', title, message })?.catch?.(() => {});
}

chrome.contextMenus?.onClicked.addListener(async (info, tab) => {
  await ready;
  let res;
  switch (info.menuItemId) {
    case 'grab-link':
      res = await downloadUrls([{ url: info.linkUrl }], { referer: info.pageUrl, pageUrl: info.pageUrl });
      break;
    case 'grab-transfer': {
      const [dl] = (await chrome.downloads?.search({ url: info.linkUrl }).catch(() => [])) || [];
      if (dl && dl.state === 'in_progress') await chrome.downloads.cancel(dl.id).catch(() => {});
      res = await downloadUrls([{ url: dl?.finalUrl || info.linkUrl }], { referer: dl?.referrer, pageUrl: dl?.referrer });
      if (res.ok && dl) chrome.downloads.erase({ id: dl.id }).catch(() => {});
      break;
    }
    case 'grab-media': {
      const src = info.srcUrl || '';
      if (/^https?:/i.test(src) && !hostMatches(hostOf(src), SKIP_STREAM_HOSTS)) {
        res = await downloadUrls([{ url: normalizeMediaUrl(src) }], { referer: info.frameUrl || info.pageUrl, pageUrl: info.pageUrl });
        break;
      }
    }
    // falls through: blob:/MediaSource players use the best entry of the menu
    case 'grab-page': {
      const menu = await buildMenu(tab.id, { frameId: info.frameId, frameUrl: info.frameUrl, explicit: true });
      let best = menu.entries.find((e) => !e.disabled);
      if (!best && menu.status.startsWith('loading')) {
        const st = siteState(info.frameUrl && info.frameId ? info.frameUrl : tab.url);
        await st.promise;
        best = (await buildMenu(tab.id, { frameId: info.frameId, frameUrl: info.frameUrl })).entries.find((e) => !e.disabled);
      }
      res = best ? await startDownload(tab.id, best.action) : { ok: false, error: 'No video found on this page. Play the video first.' };
      break;
    }
    case 'grab-selected':
    case 'grab-all':
      await openLinkPicker(tab.id, info.menuItemId === 'grab-selected');
      return;
    default:
      return;
  }
  if (res && !res.ok) notify('Castnet', res.error || 'Download failed');
  else if (res?.via === 'browser') notify('Castnet', 'The Castnet app isn’t running, so the browser is downloading it.');
});

// ---------------------------------------------------------------- download takeover

const MIME_EXT = {
  'application/zip': 'zip', 'application/x-zip-compressed': 'zip', 'application/x-rar-compressed': 'rar',
  'application/vnd.rar': 'rar', 'application/x-7z-compressed': '7z', 'application/gzip': 'gz',
  'application/x-gzip': 'gz', 'application/x-tar': 'tar', 'application/x-apple-diskimage': 'dmg',
  'application/x-iso9660-image': 'iso', 'application/vnd.android.package-archive': 'apk',
  'application/x-msdownload': 'exe', 'application/x-msi': 'msi', 'application/x-bittorrent': 'torrent',
  'video/mp4': 'mp4', 'video/webm': 'webm', 'video/x-matroska': 'mkv', 'video/quicktime': 'mov',
  'audio/mpeg': 'mp3', 'audio/mp4': 'm4a', 'audio/flac': 'flac', 'audio/wav': 'wav',
};

function catchExtSet() {
  return new Set(settings.catchExtensions.toLowerCase().split(/[\s,;|]+/).filter(Boolean));
}

// Greedy by default: every download the browser starts goes to Castnet. Castnet downloads it itself
// when it can fetch the same file. When only the browser can (a file the page made itself, a form
// download, a one-time link, or one that finished before the browser reported it), the browser
// finishes it and Castnet takes the finished file. Left alone: ⌥ Option-clicks, sites where Castnet
// is off, private windows, and (if you chose a list) other file types.
chrome.downloads?.onCreated.addListener(async (dl) => {
  await ready;
  if (!settings.catchDownloads || ownDownloads.has(dl.id) || dl.byExtensionId === chrome.runtime.id) return;
  // Option(Alt)-click on a link = "let the browser download it" (the Option key keeps it in the browser).
  if (Date.now() < bypassUntil) { bypassUntil = 0; return; }
  if (dl.incognito) return;
  const url = dl.finalUrl || dl.url;
  if (isDisabledUrl(dl.referrer || url)) return;
  const named = linkNames.get(url)?.name || '';
  if (!settings.catchAll) {
    const nameExt = (/\.([a-z0-9]{1,8})$/i.exec(dl.filename || named)?.[1] || '').toLowerCase();
    const ext = nameExt || extOf(url) || MIME_EXT[(dl.mime || '').toLowerCase()] || '';
    if (!catchExtSet().has(ext)) return;
    if (dl.totalBytes > 0 && dl.totalBytes < settings.minCatchSizeKB * 1024) return;
  }
  const postedAt = recentPosts.get(url);
  if (!/^https?:/i.test(url) || dl.state === 'complete' || (postedAt && Date.now() - postedAt < 60000)) {
    return adoptWhenDone(dl);   // only the browser can fetch it, or it already did
  }

  // The browser's download is NOT paused: pausing drops its connection, and links that work only
  // once (learning sites, signed storage) can't be resumed. It keeps going until Castnet has really
  // received data. The bridge starts Castnet if it isn't running.
  const filename = (dl.filename || '').split(/[\\/]/).pop() || named || null;
  const request = {
    url, kind: KIND.FILE, filename, pageUrl: dl.referrer || null, referer: dl.referrer || null,
    userAgent: navigator.userAgent, headers: dl.referrer ? { Referer: dl.referrer } : {},
    cookies: await cookiesFor([url, dl.referrer]), size: dl.totalBytes > 0 ? dl.totalBytes : (dl.fileSize > 0 ? dl.fileSize : null),
    mime: dl.mime || null,
  };
  try {
    // verify: Castnet first checks it gets real data from the link, matching what the browser gets.
    // waitForData: the answer comes only once Castnet's own download has received data.
    const res = await sendNative({ type: 'download', request, verify: true, waitForData: true }, 120000);
    if (res?.ok) {
      // Castnet has it: drop the browser's copy (finished or not), so the file isn't saved twice.
      const [now] = await chrome.downloads.search({ id: dl.id }).catch(() => []);
      if (now?.state === 'complete') await chrome.downloads.removeFile(dl.id).catch(() => {});
      else await chrome.downloads.cancel(dl.id).catch(() => {});
      await chrome.downloads.erase({ id: dl.id }).catch(() => {});
      return;
    }
  } catch { /* fall through */ }
  await adoptWhenDone(dl);   // the browser's download was never touched; Castnet takes the file when it's done
});

/** Castnet takes the file once the browser has finished it (see onCreated). */
async function adoptWhenDone(dl) {
  if (!settings.adoptBrowserDownloads) return;
  await session.set({ [`adopt:${dl.id}`]: Date.now() });   // survives the background restarting
  const [now] = await chrome.downloads.search({ id: dl.id }).catch(() => []);
  if (now?.state === 'complete') adoptNow(dl.id);           // it finished before we could watch for it
}

const adopting = new Set();
async function adoptNow(id) {
  const key = `adopt:${id}`;
  if (adopting.has(id) || !(await session.get(key))?.[key]) return;
  adopting.add(id);
  await session.remove(key);
  const [d] = await chrome.downloads.search({ id }).catch(() => []);
  if (!d || d.state !== 'complete' || !d.filename || d.exists === false) { adopting.delete(id); return; }
  // Never take an empty or incomplete file (a failed download that the browser marked finished).
  const size = d.fileSize > 0 ? d.fileSize : d.bytesReceived;
  if (!(size > 0) || (d.totalBytes > 0 && d.bytesReceived > 0 && d.bytesReceived < d.totalBytes)) { adopting.delete(id); return; }
  const url = d.finalUrl || d.url || '';
  try {
    const res = await sendNative({ type: 'adopt', path: d.filename, url: /^https?:/i.test(url) ? url : '', pageUrl: d.referrer || null }, 30000);
    if (res?.ok) await chrome.downloads.erase({ id }).catch(() => {});   // it now lives in Castnet
  } catch { /* the browser keeps listing it */ }
  adopting.delete(id);
}

chrome.downloads?.onChanged.addListener(async (delta) => {
  if (delta.state?.current !== 'complete') return;
  adoptNow(delta.id);
});

chrome.downloads?.onChanged.addListener((delta) => {
  if (delta.state?.current === 'complete' || delta.state?.current === 'interrupted') {
    setTimeout(() => ownDownloads.delete(delta.id), 60000);
  }
});
