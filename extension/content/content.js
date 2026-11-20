// Castnet content script (isolated world, every frame).
//  • Relays stream URLs found by inject.js (XHR/fetch bodies) to the background.
//  • Scans the page: og:video tags, <video>/<source> src, inline JSON.
//  • Draws the "Download this video" panel over videos: a quality list
//    (resolution · format · size) and an × that hides it until the page is reloaded.
//  • Collects links for "Download all / selected links".
//  • Option(Alt)-click on a link lets the browser keep that download (the Option key keeps it in the browser).
(() => {
  if (window.__castnetContent) return;
  window.__castnetContent = true;

  // Main-world hooks: if the browser didn't run inject.js in the page (no "world: MAIN"
  // support), inject it with a script tag.
  setTimeout(() => {
    if (document.documentElement && !document.documentElement.dataset.castnetHooked) {
      try {
        const s = document.createElement('script');
        s.src = chrome.runtime.getURL('content/inject.js');
        s.onload = () => s.remove();
        (document.head || document.documentElement).appendChild(s);
      } catch { /* page CSP may forbid it */ }
    }
  }, 0);

  const send = (msg) => new Promise((resolve) => {
    try {
      chrome.runtime.sendMessage(msg, (r) => { void chrome.runtime.lastError; resolve(r); });
    } catch { resolve(null); } // extension was reloaded: this copy is orphaned
  });

  // ------------------------------------------------------------ candidate URLs

  const reported = new Set();
  function report(urls, source) {
    const fresh = [];
    for (const u of urls) {
      if (!u || reported.has(u) || !/^https?:/i.test(u)) continue;
      reported.add(u);
      fresh.push(u);
    }
    if (fresh.length) send({ type: 'candidates', urls: fresh, source });
  }

  window.addEventListener('message', (e) => {
    if (e.source !== window || !e.data || e.data.__castnet !== 'urls' || !Array.isArray(e.data.urls)) return;
    report(e.data.urls.filter((u) => typeof u === 'string').slice(0, 40), 'xhr');
  });

  const URL_RE = /https?:(?:\\?\/|\\u002[fF]){2}[^\s"'<>]+?\.(?:m3u8|mpd|mp4|m4v|webm|mov|mkv|m4a|mp3)(?:\?[^\s"'<>]*)?(?=$|[\s"'<>,;)\]}]|\\)/gi;
  function urlsIn(text, limit = 40) {
    const out = [];
    URL_RE.lastIndex = 0;
    let m;
    while ((m = URL_RE.exec(text)) && out.length < limit) {
      out.push(m[0].replace(/\\u002[fF]/g, '/').replace(/\\u0026/g, '&').replace(/\\\//g, '/').replace(/&amp;/g, '&').replace(/\\+$/, ''));
    }
    return out;
  }

  function scanPage() {
    const found = [];
    for (const meta of document.querySelectorAll(
      'meta[property^="og:video"], meta[name^="og:video"], meta[property="twitter:player:stream"], meta[name="twitter:player:stream"], meta[itemprop="contentUrl"]')) {
      const c = meta.getAttribute('content');
      if (c && /^https?:/i.test(c)) found.push(c);
    }
    for (const el of document.querySelectorAll('video[src], audio[src], video source[src], audio source[src], a[href$=".m3u8"], a[href$=".mpd"]')) {
      const s = el.src || el.href;
      if (s && /^https?:/i.test(s)) found.push(s);
    }
    let budget = 4 * 1024 * 1024;
    for (const s of document.querySelectorAll('script:not([src])')) {
      const t = s.textContent;
      if (!t || t.length > budget) continue;
      budget -= t.length;
      if (/\.(?:m3u8|mpd|mp4|webm|m4a|mp3)/i.test(t)) found.push(...urlsIn(t, 20));
    }
    report(found, 'page');
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', scanPage, { once: true });
  else scanPage();
  setTimeout(scanPage, 4000);

  // ------------------------------------------------------------ links (download all / selected links)

  const LINK_TEXT_RE = /\bhttps?:\/\/[^\s"'<>()]+/gi;
  function collectLinks(selectedOnly) {
    const sel = selectedOnly ? window.getSelection() : null;
    if (selectedOnly && (!sel || (sel.isCollapsed && !sel.toString().trim()))) return [];
    const inSel = (n) => !selectedOnly || sel.containsNode(n, true);
    const out = new Map();
    const add = (url, text, kind, name) => {
      if (!url || !/^https?:/i.test(url) || out.has(url)) return;
      out.set(url, { url, text: (text || '').replace(/\s+/g, ' ').trim().slice(0, 200), kind, name: name || null });
    };
    for (const a of document.querySelectorAll('a[href], area[href]')) {
      if (inSel(a)) add(a.href, a.innerText || a.title || a.getAttribute('alt'), 'link', a.getAttribute('download') || null);
    }
    for (const img of document.querySelectorAll('img[src]')) if (inSel(img)) add(img.currentSrc || img.src, img.alt, 'image');
    for (const m of document.querySelectorAll('video[src], audio[src], source[src]')) if (inSel(m)) add(m.src, '', 'media');
    if (selectedOnly) for (const u of sel.toString().match(LINK_TEXT_RE) || []) add(u, '', 'text');
    return [...out.values()].slice(0, 5000);
  }

  chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (msg?.type === 'collectLinks') sendResponse({ links: collectLinks(!!msg.selectedOnly) });
    if (msg?.type === 'renewalPlay') {
      // Renewal tab: start the biggest video (muted) so the player asks for a fresh link.
      const list = [...document.querySelectorAll('video')].sort((a, b) => (b.clientWidth * b.clientHeight) - (a.clientWidth * a.clientHeight));
      for (const v of list.slice(0, 1)) { v.muted = true; v.play().catch(() => {}); }
    }
  });

  document.addEventListener('click', (e) => {
    const a = e.target?.closest?.('a[href]');
    if (!a) return;
    if (e.altKey) send({ type: 'bypass' });
    const name = a.getAttribute('download');
    if (name) send({ type: 'linkName', url: a.href, name });
  }, true);

  // ------------------------------------------------------------ the panel

  const videos = document.getElementsByTagName('video'); // live collection
  let settings = null;
  let siteDisabled = false;
  let dismissed = false; // × clicked: hidden until the page is reloaded
  let host = null;
  let ui = null;
  let current = null;
  let hideTimer = 0;
  let menuOpen = false;
  let pollTimer = 0;
  let lastPointer = { x: -1, y: -1 };

  const CSS = `
    :host { all: initial; }
    * { box-sizing: border-box; }
    .wrap { position: fixed; z-index: 2147483647; display: none; font: 13px/1.3 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, sans-serif; }
    .wrap.show { display: block; }
    .bar { display: flex; align-items: stretch; height: 30px; border-radius: 6px; overflow: hidden; user-select: none;
      background: linear-gradient(#ffffff, #e2edf9); border: 1px solid #7ea5d6;
      box-shadow: 0 2px 8px rgba(0, 0, 0, .28), inset 0 1px 0 rgba(255,255,255,.9); color: #123d6e; }
    .main { all: unset; box-sizing: border-box; display: flex; align-items: center; gap: 7px; padding: 0 9px 0 7px; cursor: pointer; font-weight: 600; white-space: nowrap; }
    .main:hover, .main.on { background: linear-gradient(#f3f8ff, #cfe2f8); }
    .logo { width: 18px; height: 18px; border-radius: 4px; background: linear-gradient(135deg, #22c7b8, #0f6f9c 55%, #13306f); display: grid; place-items: center; flex: none;
      box-shadow: inset 0 0 0 1px rgba(0,0,0,.12); }
    .logo svg { width: 15px; height: 15px; }
    .caret { width: 10px; height: 10px; opacity: .7; margin-left: 2px; }
    .x { all: unset; box-sizing: border-box; width: 28px; display: grid; place-items: center; cursor: pointer; border-left: 1px solid #b7cde8; color: #5a7393; }
    .x:hover { background: #e5484d; color: #fff; border-left-color: #e5484d; }
    .x svg { width: 10px; height: 10px; }
    .menu { display: none; position: absolute; right: 0; top: calc(100% + 4px); min-width: 300px; max-width: 380px; max-height: 360px; overflow: auto;
      background: #fff; border: 1px solid #9bb7da; border-radius: 6px; box-shadow: 0 8px 24px rgba(0,0,0,.28); padding: 4px 0; color: #1d2b3a; }
    .menu.open { display: block; }
    .head { padding: 5px 12px 6px; font-size: 11px; font-weight: 600; color: #6b7f96; text-transform: uppercase; letter-spacing: .5px;
      white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .row { all: unset; box-sizing: border-box; display: grid; grid-template-columns: 70px 44px minmax(0, 1fr) auto; align-items: center; gap: 8px; width: 100%;
      padding: 7px 12px; cursor: pointer; }
    .row:hover { background: #d9eafc; }
    .row[aria-disabled="true"] { cursor: default; opacity: .5; background: none; }
    .q { font-weight: 700; color: #0f3563; white-space: nowrap; }
    .f { font-size: 11px; font-weight: 600; color: #4d6a8c; background: #e8f0fa; border: 1px solid #cddcee; border-radius: 4px; padding: 1px 0; text-align: center; }
    .n { font-size: 12px; color: #6b7f96; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .s { font-size: 12px; color: #33475e; font-variant-numeric: tabular-nums; text-align: right; white-space: nowrap; }
    .sep { height: 1px; background: #e3eaf3; margin: 4px 0; }
    .note { padding: 9px 12px; color: #4f6279; font-size: 12px; line-height: 1.45; }
    .loading { display: flex; align-items: center; gap: 8px; padding: 8px 12px; color: #4f6279; font-size: 12px; }
    .spin { width: 12px; height: 12px; border: 2px solid #c6d8ee; border-top-color: #0e7490; border-radius: 50%; animation: s .8s linear infinite; flex: none; }
    @keyframes s { to { transform: rotate(360deg); } }
    .status { margin: 4px 8px 2px; padding: 6px 8px; border-radius: 5px; font-size: 12px; background: #e7f6ec; color: #17693a; }
    .status.err { background: #fdecec; color: #a12a2a; }
  `;
  // Castnet's mark: a net (white rim) catching a play triangle that points down.
  const LOGO = '<svg viewBox="0 0 24 24"><path d="M5.9 9.4A6.9 6.9 0 1 0 18.1 9.4" fill="none" stroke="#fff" stroke-width="2.8" stroke-linecap="round"/><path d="M8.9 6.2h6.2a1 1 0 0 1 .8 1.6l-3.1 4.7a1 1 0 0 1-1.6 0L8.1 7.8a1 1 0 0 1 .8-1.6z" fill="#FFA24C"/></svg>';
  const CARET = '<svg class="caret" viewBox="0 0 10 10"><path d="M1.5 3.5 5 7l3.5-3.5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  const XICON = '<svg viewBox="0 0 10 10"><path d="M1.5 1.5l7 7M8.5 1.5l-7 7" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>';

  function ensureUi() {
    if (ui) return;
    host = document.createElement('castnet-ui');
    host.style.cssText = 'all: initial !important; position: fixed !important; top: 0 !important; left: 0 !important; width: 0 !important; height: 0 !important; z-index: 2147483647 !important;';
    const root = host.attachShadow({ mode: 'closed' });
    root.innerHTML = `<style>${CSS}</style>
      <div class="wrap" role="toolbar" aria-label="Castnet">
        <div class="bar">
          <button class="main" type="button" title="Download this video"><span class="logo">${LOGO}</span><span>Download this video</span>${CARET}</button>
          <button class="x" type="button" title="Hide until this page is reloaded" aria-label="Close">${XICON}</button>
        </div>
        <div class="menu" role="menu"></div>
      </div>`;
    ui = {
      wrap: root.querySelector('.wrap'),
      main: root.querySelector('.main'),
      x: root.querySelector('.x'),
      menu: root.querySelector('.menu'),
    };
    ui.main.addEventListener('click', (e) => { e.preventDefault(); e.stopPropagation(); toggleMenu(); });
    ui.x.addEventListener('click', (e) => { e.preventDefault(); e.stopPropagation(); dismiss(); });
    for (const t of ['mousedown', 'pointerdown', 'mouseup', 'dblclick', 'contextmenu']) ui.wrap.addEventListener(t, (e) => e.stopPropagation());
    ui.wrap.addEventListener('mouseenter', () => clearTimeout(hideTimer));
    ui.wrap.addEventListener('mouseleave', () => scheduleHide(1000));
    mountHost();
  }

  function dismiss() {
    dismissed = true;
    closeMenu();
    host?.remove();
    host = null;
    ui = null;
    current = null;
  }

  function mountHost() {
    if (!host) return;
    const fs = document.fullscreenElement || document.webkitFullscreenElement;
    const parent = fs && fs.localName !== 'video' && fs.localName !== 'iframe' ? fs : document.documentElement;
    if (parent && host.parentNode !== parent) parent.appendChild(host);
  }
  const onFs = () => { if (host) { mountHost(); position(); } };
  document.addEventListener('fullscreenchange', onFs);
  document.addEventListener('webkitfullscreenchange', onFs);

  function usable(v) {
    if (!v || !v.isConnected) return null;
    const r = v.getBoundingClientRect();
    if (r.width < 200 || r.height < 110) return null;
    if (r.bottom < 0 || r.right < 0 || r.top > innerHeight || r.left > innerWidth) return null;
    return r;
  }

  function position() {
    if (!ui || !current) return;
    const r = usable(current);
    if (!r) { hide(); return; }
    const bw = ui.wrap.querySelector('.bar').offsetWidth || 200;
    const top = Math.max(6, Math.min(r.top + 10, innerHeight - 40));
    const left = Math.max(6, Math.min(r.right - bw - 10, innerWidth - bw - 6));
    ui.wrap.style.top = `${top}px`;
    ui.wrap.style.left = `${left}px`;
  }

  async function showFor(video, autoHideMs) {
    if (dismissed) return;
    if (settings === null) {
      const r = await send({ type: 'getSettings', url: location.href });
      settings = r?.settings || { showOverlay: true };
      siteDisabled = !!r?.disabled;
    }
    if (!settings.showOverlay || siteDisabled || dismissed) return;
    ensureUi();
    mountHost();
    if (current !== video) { current = video; closeMenu(); }
    ui.wrap.classList.add('show');
    position();
    clearTimeout(hideTimer);
    if (autoHideMs) scheduleHide(autoHideMs);
  }

  function scheduleHide(ms) {
    clearTimeout(hideTimer);
    hideTimer = setTimeout(() => {
      if (menuOpen || (current && pointerOver(current))) return;
      hide();
    }, ms);
  }

  function hide() {
    if (!ui) return;
    ui.wrap.classList.remove('show');
    closeMenu();
    current = null;
  }

  function pointerOver(v) {
    const r = usable(v);
    return r && lastPointer.x >= r.left && lastPointer.x <= r.right && lastPointer.y >= r.top && lastPointer.y <= r.bottom;
  }

  let moveQueued = false;
  window.addEventListener('mousemove', (e) => {
    lastPointer = { x: e.clientX, y: e.clientY };
    if (moveQueued || dismissed) return;
    moveQueued = true;
    requestAnimationFrame(() => {
      moveQueued = false;
      if (!videos.length) return;
      for (const v of videos) {
        if (pointerOver(v)) {
          if (current !== v || !ui?.wrap.classList.contains('show')) showFor(v);
          else clearTimeout(hideTimer);
          return;
        }
      }
      if (current && !menuOpen) scheduleHide(1000);
    });
  }, { passive: true, capture: true });

  window.addEventListener('scroll', () => position(), { passive: true, capture: true });
  window.addEventListener('resize', () => position(), { passive: true });

  // A video starting: report its source, warm up the quality list, flash the panel.
  document.addEventListener('play', (e) => {
    const v = e.target;
    if (!(v instanceof HTMLMediaElement)) return;
    const src = v.currentSrc || v.src;
    if (/^https?:/i.test(src)) report([src], 'element');
    if (v.localName === 'video' && usable(v)) {
      send({ type: 'prefetch' });
      if (!current) showFor(v, 4000);
    }
  }, true);
  document.addEventListener('loadedmetadata', (e) => {
    const v = e.target;
    if (!(v instanceof HTMLMediaElement)) return;
    const src = v.currentSrc || v.src;
    if (/^https?:/i.test(src)) report([src], 'element');
  }, true);

  // ------------------------------------------------------------ quality menu

  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  function humanSize(bytes, approx) {
    if (bytes == null || !isFinite(bytes) || bytes <= 0) return '';
    const u = ['B', 'KB', 'MB', 'GB', 'TB'];
    let i = 0;
    let v = bytes;
    while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
    return `${approx ? '~' : ''}${v >= 100 || i === 0 ? Math.round(v) : v.toFixed(1)} ${u[i]}`;
  }

  function closeMenu() {
    menuOpen = false;
    clearTimeout(pollTimer);
    ui?.menu.classList.remove('open');
    ui?.main.classList.remove('on');
  }

  function setStatus(text, isErr) {
    if (!ui) return;
    let s = ui.menu.querySelector('.status');
    if (!s) { s = el('div', 'status'); ui.menu.append(s); }
    s.className = `status${isErr ? ' err' : ''}`;
    s.textContent = text;
  }

  async function startDownload(entry) {
    setStatus('Starting download…');
    const res = await send({ type: 'download', action: entry.action });
    if (res?.ok) {
      setStatus(res.renewed ? '✓ Continued your expired download' : res.existing ? '✓ Already in Castnet' : res.via === 'browser' ? '✓ Downloading in your browser' : '✓ Added to Castnet');
      setTimeout(closeMenu, 1500);
    } else {
      setStatus(res?.error || 'Couldn’t start the download.', true);
    }
  }

  function renderMenu(menu, waitedMs) {
    const m = ui.menu;
    const status = m.querySelector('.status');
    m.replaceChildren();
    const entries = menu?.entries || [];
    const title = entries.find((e) => e.title)?.title || menu?.title || '';
    m.append(el('div', 'head', title || 'Download this video'));
    let lastGroup = null;
    for (const e of entries) {
      if (lastGroup && e.group !== lastGroup) m.append(el('div', 'sep'));
      lastGroup = e.group;
      const row = el('button', 'row');
      row.type = 'button';
      row.append(el('span', 'q', e.quality), el('span', 'f', e.format || ''), el('span', 'n', e.note || ''), el('span', 's', humanSize(e.size, e.sizeApprox)));
      if (e.disabled) row.setAttribute('aria-disabled', 'true');
      else row.addEventListener('click', (ev) => { ev.preventDefault(); ev.stopPropagation(); startDownload(e); });
      m.append(row);
    }
    const loading = menu?.status === 'loading' || menu?.status === 'loading-more';
    if (loading) {
      const l = el('div', 'loading');
      l.append(el('span', 'spin'), el('span', null, entries.length ? 'Finding more qualities…' : 'Finding available qualities…'));
      m.append(l);
    } else if (!entries.length) {
      m.append(el('div', 'note', menu?.app?.ok === false
        ? 'No video found yet. Play the video first. (The Castnet app isn’t connected, so some sites won’t work.)'
        : 'No video found yet. Play the video, then open this menu again.'));
    }
    if (status) m.append(status);
    return loading && waitedMs < 115000;
  }

  async function refreshMenu(waitedMs = 0) {
    if (!menuOpen || !ui) return;
    const menu = await send({ type: 'getMenu', explicit: true });
    if (!menuOpen || !ui) return;
    const keepPolling = renderMenu(menu, waitedMs);
    position();
    if (keepPolling) pollTimer = setTimeout(() => refreshMenu(waitedMs + 1200), 1200);
  }

  function toggleMenu() {
    if (menuOpen) { closeMenu(); return; }
    menuOpen = true;
    ui.main.classList.add('on');
    ui.menu.replaceChildren(el('div', 'head', 'Download this video'));
    const l = el('div', 'loading');
    l.append(el('span', 'spin'), el('span', null, 'Looking for qualities…'));
    ui.menu.append(l);
    ui.menu.classList.add('open');
    refreshMenu();
  }

  document.addEventListener('mousedown', (e) => {
    if (menuOpen && host && !e.composedPath().includes(host)) closeMenu();
  }, true);
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeMenu(); }, true);
})();
