// Firefox/Safari: `browser.*` returns promises everywhere; Chrome: `chrome.*` does.
const chrome = globalThis.browser ?? globalThis.chrome;
// "Download all links / selected links" dialog.
const $ = (id) => document.getElementById(id);
const key = new URLSearchParams(location.search).get('key');

const TYPES = {
  Video: 'mp4 mkv webm mov avi flv wmv m4v mpg mpeg 3gp ts m3u8 mpd',
  Audio: 'mp3 m4a aac flac wav ogg opus wma',
  Archives: 'zip rar 7z tar gz tgz bz2 xz zst',
  Programs: 'dmg pkg exe msi apk ipa deb rpm jar iso img',
  Documents: 'pdf doc docx xls xlsx ppt pptx txt csv epub rtf odt pages numbers',
  Images: 'jpg jpeg png gif webp svg bmp tif tiff heic avif',
};
const EXT_TYPE = {};
for (const [t, list] of Object.entries(TYPES)) for (const e of list.split(' ')) EXT_TYPE[e] = t;
const PRESELECT = new Set(['Video', 'Audio', 'Archives', 'Programs', 'Documents']);

let data = null;
let links = [];
let filter = 'All';
const checked = new Set();

function extOf(url) {
  try { return (/\.([a-z0-9]{1,6})$/i.exec(new URL(url).pathname)?.[1] || '').toLowerCase(); } catch { return ''; }
}

function nameOf(l) {
  if (l.name) return l.name;
  try {
    const last = decodeURIComponent(new URL(l.url).pathname.split('/').filter(Boolean).pop() || '');
    if (/\.[a-z0-9]{1,6}$/i.test(last)) return last;
    return l.text || last || new URL(l.url).hostname;
  } catch { return l.text || l.url; }
}

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}

function shown() {
  const q = $('search').value.trim().toLowerCase();
  return links.filter((l) => (filter === 'All' || l.type === filter) &&
    (!q || l.display.toLowerCase().includes(q) || l.url.toLowerCase().includes(q)));
}

function renderChips() {
  const counts = { All: links.length };
  for (const l of links) counts[l.type] = (counts[l.type] || 0) + 1;
  const order = ['All', ...Object.keys(TYPES), 'Other'].filter((t) => counts[t]);
  $('chips').replaceChildren(...order.map((t) => {
    const c = el('button', 'chip', t);
    c.type = 'button';
    c.setAttribute('role', 'tab');
    c.setAttribute('aria-selected', String(t === filter));
    c.append(el('b', null, String(counts[t])));
    c.addEventListener('click', () => { filter = t; renderChips(); renderRows(); });
    return c;
  }));
}

function renderRows() {
  const list = shown();
  $('none').hidden = list.length > 0;
  $('rows').replaceChildren(...list.map((l) => {
    const r = el('label', 'r');
    r.setAttribute('role', 'row');
    const cb = el('input');
    cb.type = 'checkbox';
    cb.checked = checked.has(l.url);
    cb.addEventListener('change', () => { cb.checked ? checked.add(l.url) : checked.delete(l.url); updateFooter(); });
    const c = el('span', 'c');
    c.append(cb);
    const addr = el('span', 'addr', l.url);
    addr.title = l.url;
    r.append(c, el('span', 'name', l.display), el('span', 'type', l.ext ? l.ext.toUpperCase() : l.type), addr);
    return r;
  }));
  const all = list.length > 0 && list.every((l) => checked.has(l.url));
  $('all').checked = all;
  $('all').indeterminate = !all && list.some((l) => checked.has(l.url));
  updateFooter();
}

function updateFooter() {
  const n = checked.size;
  $('count').textContent = `${n} of ${links.length} selected`;
  $('go').textContent = n === 1 ? 'Download 1 file' : `Download ${n} files`;
  $('go').disabled = n === 0;
}

$('all').addEventListener('change', (e) => {
  for (const l of shown()) e.target.checked ? checked.add(l.url) : checked.delete(l.url);
  renderRows();
});
$('search').addEventListener('input', renderRows);
$('cancel').addEventListener('click', () => window.close());
$('go').addEventListener('click', async () => {
  $('go').disabled = true;
  $('msg').className = 'msg';
  $('msg').textContent = 'Sending…';
  const res = await chrome.runtime.sendMessage({ type: 'downloadLinks', key, urls: [...checked] });
  if (res?.ok) {
    $('msg').className = 'msg ok';
    $('msg').textContent = res.via === 'browser' ? `✓ ${res.count} downloads started in the browser` : `✓ ${res.count} added to Castnet`;
    setTimeout(() => window.close(), 1200);
  } else {
    $('msg').className = 'msg bad';
    $('msg').textContent = res?.error || 'Couldn’t start the downloads.';
    $('go').disabled = false;
  }
});

(async () => {
  data = await chrome.runtime.sendMessage({ type: 'pickerData', key });
  if (!data) {
    $('none').hidden = false;
    $('none').textContent = 'This list has expired. Run “Download all links” again.';
    return;
  }
  let host = '';
  try { host = new URL(data.pageUrl).hostname; } catch { /* */ }
  $('heading').textContent = data.selectedOnly ? 'Download selected links' : 'Download all links';
  $('source').textContent = [data.title, host].filter(Boolean).join(' · ');
  links = data.links.map((l) => {
    const ext = extOf(l.url);
    const type = EXT_TYPE[ext] || (l.kind === 'image' ? 'Images' : 'Other');
    return { ...l, ext, type, display: nameOf(l) };
  });
  for (const l of links) if (PRESELECT.has(l.type)) checked.add(l.url);
  if (data.selectedOnly) for (const l of links) checked.add(l.url);
  renderChips();
  renderRows();
})();
