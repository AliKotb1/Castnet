// End-to-end test in real Chrome with the unpacked extension, a throwaway profile, and a
// recording native host (test/fake-host.py). Download requests are written to a log and
// then replayed with castnet-cli, so your installed app and download list are never touched.
//   node test/e2e.mjs <scratch-dir> [--headed] [--youtube]
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const require = createRequire(import.meta.url);
// playwright-core from the project, else the global install (npm i -g playwright-core).
const { chromium } = (() => {
  try { return require('playwright-core'); } catch {}
  const globalRoot = execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim();
  return require(path.join(globalRoot, 'playwright-core'));
})();

const scratch = path.resolve(process.argv[2]);
const headed = process.argv.includes('--headed');
const withYouTube = process.argv.includes('--youtube');
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const extDir = path.join(root, 'extension');
const EXT_ID = 'jninbfcnkkcefbjldiiiogbajkeohemb';
const profile = path.join(scratch, 'chrome-profile');
const shots = path.join(scratch, 'shots');
const log = path.join(scratch, 'e2e-requests.jsonl');
const BASE = 'http://127.0.0.1:8765';

fs.rmSync(profile, { recursive: true, force: true });
fs.rmSync(log, { force: true });
fs.mkdirSync(shots, { recursive: true });
fs.mkdirSync(path.join(profile, 'NativeMessagingHosts'), { recursive: true });
// Chrome passes no custom env to hosts, so wrap the fake host with the log path baked in.
const wrapper = path.join(scratch, 'fake-host.sh');
fs.writeFileSync(wrapper, `#!/bin/sh\nCASTNET_TEST_LOG='${log}' exec /usr/bin/python3 -I '${path.join(root, 'test/fake-host.py')}' "$@"\n`, { mode: 0o755 });
fs.writeFileSync(path.join(profile, 'NativeMessagingHosts/app.castnet.host.json'), JSON.stringify({
  name: 'app.castnet.host', description: 'Castnet (test)', path: wrapper, type: 'stdio',
  allowed_origins: [`chrome-extension://${EXT_ID}/`],
}));

let failures = 0;
const check = (ok, label) => { console.log(`  ${ok ? '✓' : '✗'} ${label}`); if (!ok) failures++; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const ctx = await chromium.launchPersistentContext(profile, {
  executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  headless: !headed,
  viewport: { width: 1100, height: 700 },
  ignoreDefaultArgs: ['--disable-extensions', '--disable-component-extensions-with-background-pages'],
  args: ['--enable-unsafe-extension-debugging', '--autoplay-policy=no-user-gesture-required'],
});
const cdp = await ctx.browser()?.newBrowserCDPSession?.();
await cdp.send('Extensions.loadUnpacked', { path: extDir });
await sleep(1200);

const ext = await ctx.newPage();
await ext.goto(`chrome-extension://${EXT_ID}/popup/popup.html`);
const call = (msg) => ext.evaluate((m) => chrome.runtime.sendMessage(m), msg);
const tabIdOf = (prefix) => ext.evaluate(async (p) => (await chrome.tabs.query({})).find((t) => t.url.startsWith(p))?.id, prefix);
const records = () => (fs.existsSync(log) ? fs.readFileSync(log, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : []);
const show = (entries) => { for (const e of entries) console.log(`     ${e.quality.padEnd(8)} ${String(e.format).padEnd(5)} ${(e.note || '').padEnd(10)} ${e.size ? `${(e.size / 1048576).toFixed(1)} MB` : ''}`); };

async function hoverVideo(page) {
  const box = await page.locator('video').first().boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await sleep(400);
  await page.mouse.move(box.x + box.width / 2 + 8, box.y + box.height / 2 + 8);
  await sleep(700);
  return box;
}
// The panel lives in a closed shadow root, so click by position (it sits at the video's top-right).
const clickPanel = (page, box, dxFromRight) => page.mouse.click(box.x + box.width - dxFromRight, box.y + 25);

// ---- 1. test page: panel style, quality menu, × button
console.log('page with MP4 + HLS + DASH');
const page = await ctx.newPage();
await page.goto(`${BASE}/page.html`);
await page.evaluate(() => document.querySelector('video').play());
await sleep(3500);
let box = await hoverVideo(page);
await page.screenshot({ path: path.join(shots, 'panel.png'), clip: { x: box.x + box.width - 330, y: box.y, width: 330, height: 70 } });
await clickPanel(page, box, 120); // "Download this video"
await sleep(1500);
await page.screenshot({ path: path.join(shots, 'menu.png') });
const tab1 = await tabIdOf(`${BASE}/page.html`);
const menu1 = await call({ type: 'getMenu', tabId: tab1, explicit: true });
show(menu1.entries);
check(menu1.entries.filter((e) => e.quality === '720p').length >= 2, 'lists 720p choices from MP4, HLS and DASH');
check(menu1.entries.some((e) => e.quality === '360p'), 'lists the HLS 360p variant');
check(menu1.entries.some((e) => e.quality === '720p' && e.size > 20e6 && e.format === 'MP4'), 'progressive MP4 shows resolution and size from its header');

await clickPanel(page, box, 23); // ×
await sleep(400);
await page.mouse.move(box.x + 100, box.y + 100);
await sleep(300);
await page.mouse.move(box.x + 140, box.y + 140);
await sleep(900);
check(await page.evaluate(() => document.querySelectorAll('castnet-ui').length === 0), '× removes the panel (stays hidden while hovering)');
await page.reload();
await page.evaluate(() => document.querySelector('video').play());
await sleep(2500);
box = await hoverVideo(page);
check(await page.evaluate(() => document.querySelectorAll('castnet-ui').length === 1), 'panel returns after a page refresh');

// ---- 2. separate video + audio streams
console.log('page with separate video and audio streams');
const split = await ctx.newPage();
await split.goto(`${BASE}/split.html`);
await split.evaluate(() => document.querySelector('video').play().catch(() => {}));
await sleep(4000);
const tab2 = await tabIdOf(`${BASE}/split.html`);
const menu2 = await call({ type: 'getMenu', tabId: tab2, explicit: true });
show(menu2.entries);
const merged = menu2.entries.find((e) => e.action?.audioId);
check(!!merged && merged.quality === '720p', 'video-only + audio-only shown as ONE 720p choice');
check(menu2.entries.filter((e) => e.group === 'video').length === 1, 'no separate “video without sound” row');
check(menu2.entries.some((e) => e.quality === 'Audio'), 'audio-only offered separately as “Audio”');
const r2 = await call({ type: 'download', tabId: tab2, action: merged?.action });
check(r2?.ok, 'merged download handed to the app');

// ---- 3. download all links (picker window)
console.log('download all links');
const pickerPromise = ctx.waitForEvent('page', { predicate: (p) => p.url().includes('/picker/picker.html'), timeout: 10000 });
await call({ type: 'grabLinks', tabId: tab1, selectedOnly: false });
const picker = await pickerPromise;
await picker.waitForSelector('.r');
await sleep(400);
await picker.screenshot({ path: path.join(shots, 'picker.png') });
const rows = await picker.locator('.r').count();
console.log(`     ${rows} links, ${await picker.locator('#count').innerText()}`);
check(rows >= 4, 'picker lists the page links');
await picker.click('#go');
await sleep(800);

// ---- 4. YouTube quality list (optional, needs network)
if (withYouTube) {
  console.log('YouTube');
  const yt = await ctx.newPage();
  await yt.goto('https://www.youtube.com/watch?v=aqz-KE-bpKQ', { waitUntil: 'domcontentloaded' });
  await sleep(3000);
  const tab3 = await tabIdOf('https://www.youtube.com/watch');
  let menu3;
  for (let i = 0; i < 40; i++) {
    menu3 = await call({ type: 'getMenu', tabId: tab3, explicit: true });
    if (!String(menu3.status).startsWith('loading')) break;
    await sleep(1000);
  }
  show(menu3.entries);
  check(menu3.entries.some((e) => e.quality.startsWith('1080p')), 'YouTube: quality list includes 1080p');
  check(menu3.entries.some((e) => e.quality === 'Audio'), 'YouTube: audio-only option');
  const small = menu3.entries.find((e) => e.quality === '144p');
  if (small) check((await call({ type: 'download', tabId: tab3, action: small.action }))?.ok, 'YouTube 144p handed to the app');
  const pop = await ctx.newPage();
  await pop.setViewportSize({ width: 400, height: 590 });
  await pop.goto(`chrome-extension://${EXT_ID}/popup/popup.html?tabId=${tab3}`);
  await sleep(1500);
  await pop.screenshot({ path: path.join(shots, 'popup-youtube.png'), fullPage: true });
}

const pop1 = await ctx.newPage();
await pop1.setViewportSize({ width: 400, height: 590 });
await pop1.goto(`chrome-extension://${EXT_ID}/popup/popup.html?tabId=${tab2}`);
await sleep(1200);
await pop1.screenshot({ path: path.join(shots, 'popup-split.png'), fullPage: true });

await ctx.close();

const recs = records();
console.log(`recorded ${recs.length} native messages → ${log}`);
const dl = recs.filter((r) => r.type === 'download').map((r) => r.request);
check(dl.some((r) => r.audioUrl?.includes('aonly.mp4') && r.url.includes('vonly.mp4')), 'merged request carries both video and audio URLs');
check(recs.some((r) => r.type === 'downloadBatch' && r.requests.length >= 2), 'picker sends the selected links as one batch');
if (withYouTube) check(dl.some((r) => r.kind === 'ytdlp' && /^\d+\+\d+$/.test(r.format || '') && r.container === 'mp4'), 'YouTube request has an exact format pair and MP4 container');
console.log(failures ? `\n${failures} CHECK(S) FAILED` : '\nALL E2E CHECKS PASSED');
process.exit(failures ? 1 : 0);
