// Runs in the page's own JavaScript world (MAIN). webRequest can't read response
// bodies, so this wraps fetch() and XMLHttpRequest to look inside JSON/text
// responses for stream URLs (.m3u8/.mpd/.mp4...) that players load through APIs.
// Found URLs are posted to content.js, which forwards them to the background
// worker for verification. Nothing here changes requests or responses.
(() => {
  // Browsers without main-world content scripts run this file in the isolated world: bail out there,
  // content.js then injects it into the page with a <script> tag instead.
  if (typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.id) return;
  if (window.__castnetHooked) return;
  try { Object.defineProperty(window, '__castnetHooked', { value: true }); } catch { return; }
  try { document.documentElement.dataset.castnetHooked = '1'; } catch { /* no document yet */ }

  const MAX_BYTES = 3 * 1024 * 1024;
  const QUICK = /\.(?:m3u8|mpd|mp4|m4v|webm|mov|mkv|m4a|mp3)/i;
  const TEXTY = /json|javascript|ecmascript|text\/plain|text\/html|xml|mpegurl|dash/i;
  const STREAMY = /event-stream|ndjson|x-protobuf|grpc|octet-stream/i;
  const URL_RE = /https?:(?:\\?\/|\\u002[fF]){2}[^\s"'<>]+?\.(?:m3u8|mpd|mp4|m4v|webm|mov|mkv|m4a|mp3)(?:\?[^\s"'<>]*)?(?=$|[\s"'<>,;)\]}]|\\)/gi;

  const seen = new Set();
  let queue = [];
  let timer = 0;

  function flush() {
    timer = 0;
    if (!queue.length) return;
    const urls = queue;
    queue = [];
    window.postMessage({ __castnet: 'urls', urls }, '*');
  }

  function scan(text) {
    if (typeof text !== 'string' || text.length > MAX_BYTES || !QUICK.test(text)) return;
    URL_RE.lastIndex = 0;
    let m;
    let n = 0;
    while ((m = URL_RE.exec(text)) && n++ < 60) {
      const u = m[0]
        .replace(/\\u002[fF]/g, '/')
        .replace(/\\u0026/g, '&')
        .replace(/\\\//g, '/')
        .replace(/&amp;/g, '&')
        .replace(/\\+$/, '');
      if (seen.has(u)) continue;
      seen.add(u);
      queue.push(u);
    }
    if (queue.length && !timer) timer = setTimeout(flush, 300);
  }

  // Addresses the player requests (manifests and media files), not just what's inside responses.
  // Browsers without network sniffing (Safari) find streams this way.
  const REQ_RE = /\.(?:m3u8|mpd|mp4|m4v|webm|mov|m4a|mp3)(?:[?#]|$)/i;
  const SEG_RE = /\.(?:ts|m4s|aac|vtt)(?:[?#]|$)|\/(?:seg|chunk|frag)[-_]?\d+/i;
  function noteRequest(u) {
    try {
      const abs = new URL(u, location.href).href;
      if (!/^https?:/.test(abs) || !REQ_RE.test(abs) || SEG_RE.test(abs) || seen.has(abs)) return;
      seen.add(abs);
      queue.push(abs);
      if (!timer) timer = setTimeout(flush, 300);
    } catch { /* not a URL */ }
  }

  async function readCapped(res) {
    const reader = res.body?.getReader();
    if (!reader) return null;
    const dec = new TextDecoder();
    let out = '';
    let total = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > MAX_BYTES) { reader.cancel().catch(() => {}); return null; }
      out += dec.decode(value, { stream: true });
    }
    return out + dec.decode();
  }

  const nativeToString = Function.prototype.toString;
  function disguise(fake, real) {
    try {
      Object.defineProperty(fake, 'toString', { value: () => nativeToString.call(real), configurable: true });
      Object.defineProperty(fake, 'name', { value: real.name, configurable: true });
    } catch { /* ignore */ }
    return fake;
  }

  const origFetch = window.fetch;
  if (typeof origFetch === 'function') {
    window.fetch = disguise(function fetch(...args) {
      try { noteRequest(typeof args[0] === 'string' ? args[0] : args[0]?.url || String(args[0])); } catch { /* ignore */ }
      const p = origFetch.apply(this, args);
      p.then((res) => {
        try {
          const ct = res.headers.get('content-type') || '';
          const len = Number(res.headers.get('content-length') || 0);
          if (!TEXTY.test(ct) || STREAMY.test(ct) || len > MAX_BYTES || res.bodyUsed) return;
          if (res.type === 'opaque') return;
          readCapped(res.clone()).then(scan, () => {});
        } catch { /* ignore */ }
      }, () => {});
      return p;
    }, origFetch);
  }

  const XHR = window.XMLHttpRequest?.prototype;
  if (XHR) {
    const origOpen = XHR.open;
    XHR.open = disguise(function open(method, url, ...rest) {
      try { noteRequest(String(url)); } catch { /* ignore */ }
      return origOpen.call(this, method, url, ...rest);
    }, origOpen);
    const origSend = XHR.send;
    XHR.send = disguise(function send(...args) {
      try {
        this.addEventListener('load', function onLoad() {
          try {
            const rt = this.responseType;
            if (rt === '' || rt === 'text') scan(this.responseText);
            else if (rt === 'json' && this.response) scan(JSON.stringify(this.response));
          } catch { /* ignore */ }
        });
      } catch { /* ignore */ }
      return origSend.apply(this, args);
    }, origSend);
  }
})();
