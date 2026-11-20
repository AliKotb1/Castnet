// Firefox/Safari: `browser.*` returns promises everywhere; Chrome: `chrome.*` does.
const chrome = globalThis.browser ?? globalThis.chrome;
const $ = (id) => document.getElementById(id);
const send = (msg) => chrome.runtime.sendMessage(msg);

let tab = null;
let lastSig = '';

const COPY_ICON = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="5" y="5" width="8.5" height="8.5" rx="1.5"/><path d="M10.5 5V3.5A1.5 1.5 0 0 0 9 2H3.5A1.5 1.5 0 0 0 2 3.5V9a1.5 1.5 0 0 0 1.5 1.5H5"/></svg>';

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

function toast(text, ok = true) {
  const t = $('toast');
  t.hidden = false;
  t.className = `toast ${ok ? 'ok' : 'bad'}`;
  t.textContent = text;
}

function renderApp(app) {
  const b = $('app');
  b.classList.toggle('ok', !!app?.ok);
  b.classList.toggle('bad', !app?.ok);
  $('appText').textContent = app?.ok ? 'Castnet connected' : 'Castnet not running';
  b.title = app?.ok ? 'Click to open the Castnet window' : (app?.error || 'Open the Castnet app.');
}

function row(entry) {
  const r = el('div', `row${entry.group === 'audio' ? ' audio' : ''}`);
  r.setAttribute('role', 'listitem');
  r.append(el('span', 'q', entry.quality), el('span', 'f', entry.format || ''), el('span', 'n', entry.note || ''),
    el('span', 's', humanSize(entry.size, entry.sizeApprox)));
  const btns = el('span', 'btns');
  if (entry.copyUrl) {
    const c = el('button', 'icon');
    c.type = 'button';
    c.title = 'Copy link';
    c.innerHTML = COPY_ICON;
    c.addEventListener('click', async () => {
      await navigator.clipboard.writeText(entry.copyUrl);
      toast('Link copied.');
    });
    btns.append(c);
  }
  const d = el('button', 'dl', entry.disabled ? 'Protected' : 'Download');
  d.type = 'button';
  d.disabled = !!entry.disabled;
  d.addEventListener('click', async () => {
    d.disabled = true;
    d.textContent = 'Starting…';
    const res = await send({ type: 'download', tabId: tab.id, action: entry.action });
    d.disabled = false;
    d.textContent = 'Download';
    if (res?.ok) toast(res.renewed ? 'Continued your expired download with this link.' : res.existing ? 'Already in Castnet. Check the Castnet window.' : res.via === 'browser' ? 'Downloading in your browser (the Mac app isn’t connected).' : 'Added to Castnet.');
    else toast(res?.error || 'Couldn’t start the download.', false);
  });
  btns.append(d);
  r.append(btns);
  return r;
}

async function refresh() {
  const menu = await send({ type: 'getMenu', tabId: tab.id, explicit: true });
  renderApp(menu?.app);
  const entries = menu?.entries || [];
  const off = !!menu?.disabled;
  $('siteToggle').checked = !off;
  $('siteLabel').textContent = off ? 'Off for this site' : 'On for this site';
  $('off').hidden = !off;
  const loading = !off && (menu?.status === 'loading' || menu?.status === 'loading-more');
  $('loading').hidden = !loading;
  $('loading').lastElementChild.textContent = entries.length ? 'Finding more qualities…' : 'Finding available qualities…';
  $('empty').hidden = off || loading || entries.length > 0;
  const title = entries.find((e) => e.title)?.title || '';
  $('title').textContent = off ? '' : title;
  // Re-render only when something changed so clicks aren't lost mid-refresh.
  const sig = entries.map((e) => `${e.key}:${e.size}:${e.note}`).join('|') + off;
  if (sig !== lastSig) {
    lastSig = sig;
    $('list').replaceChildren(...(off ? [] : entries.map(row)));
  }
  return menu;
}

async function loadSettings() {
  const { settings } = await send({ type: 'getSettings', url: tab.url });
  $('catchDownloads').checked = !!settings.catchDownloads;
  $('showOverlay').checked = !!settings.showOverlay;
  $('catchExtensions').value = settings.catchExtensions;
  $('minMediaSizeKB').value = settings.minMediaSizeKB;
}

const saveSetting = (key, value) => send({ type: 'setSettings', settings: { [key]: value } });

async function checkHostAccess() {
  const origins = ['http://*/*', 'https://*/*'];
  const has = await chrome.permissions?.contains({ origins }).catch(() => true);
  if (has !== false) return;
  const bar = el('button', 'grant', 'Allow Castnet on all websites');
  bar.type = 'button';
  bar.addEventListener('click', async () => {
    if (await chrome.permissions.request({ origins })) bar.remove();
  });
  document.querySelector('header').after(bar);
}

(async () => {
  checkHostAccess();
  // ?tabId=N lets the popup be opened as a normal tab for debugging/tests.
  const forced = Number(new URLSearchParams(location.search).get('tabId'));
  [tab] = forced ? [await chrome.tabs.get(forced)] : await chrome.tabs.query({ active: true, currentWindow: true });
  let host = '';
  try { host = new URL(tab.url).hostname.replace(/^www\./, ''); } catch { /* chrome:// pages */ }
  $('host').textContent = host || 'This page';
  $('siteToggle').disabled = !/^https?:/.test(tab.url || '');
  await Promise.all([refresh(), loadSettings()]);

  $('app').addEventListener('click', async () => {
    const r = await send({ type: 'openApp' });
    if (!r?.ok) toast(r?.error || 'Couldn’t reach the Castnet app.', false);
  });
  $('siteToggle').addEventListener('change', async (e) => {
    await send({ type: 'toggleSite', host, enabled: e.target.checked });
    lastSig = '';
    refresh();
  });
  $('allLinks').addEventListener('click', async () => {
    await send({ type: 'grabLinks', tabId: tab.id, selectedOnly: false });
    window.close();
  });
  $('clear').addEventListener('click', async () => {
    await send({ type: 'clear', tabId: tab.id });
    lastSig = '';
    refresh();
  });
  $('catchDownloads').addEventListener('change', (e) => saveSetting('catchDownloads', e.target.checked));
  $('showOverlay').addEventListener('change', (e) => saveSetting('showOverlay', e.target.checked));
  $('catchExtensions').addEventListener('change', (e) => saveSetting('catchExtensions', e.target.value));
  $('minMediaSizeKB').addEventListener('change', (e) => saveSetting('minMediaSizeKB', Math.max(0, Number(e.target.value) || 0)));

  setInterval(refresh, 1500);
})();
