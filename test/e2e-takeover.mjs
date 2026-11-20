// End-to-end test of download takeover: real Chrome + the extension + a headless test instance of
// Castnet (own folder and settings, never your real list). Every download should go to Castnet,
// except ones only the browser can finish, which must still complete in the browser.
//   node test/e2e-takeover.mjs <scratch-dir>      (test server must run on :8765)
import { createRequire } from 'node:module';
import { execFileSync, spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const require = createRequire(import.meta.url);
const { chromium } = (() => {
  try { return require('playwright-core'); } catch {}
  return require(path.join(execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim(), 'playwright-core'));
})();

const scratch = path.resolve(process.argv[2]);
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const app = path.join(root, 'dist/Castnet.app/Contents/MacOS');
const EXT_ID = 'jninbfcnkkcefbjldiiiogbajkeohemb';
const home = path.join(scratch, 'apphome-takeover');
const profile = path.join(scratch, 'chrome-takeover');
const browserDownloads = path.join(scratch, 'browser-downloads');
const media = path.join(scratch, 'media');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
const check = (ok, label) => { console.log(`  ${ok ? '✓' : '✗'} ${label}`); if (!ok) failures++; };
const sha = (f) => crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');

for (const d of [home, profile, browserDownloads]) fs.rmSync(d, { recursive: true, force: true });
fs.mkdirSync(path.join(home, 'Downloads'), { recursive: true });
fs.mkdirSync(browserDownloads, { recursive: true });
const settings = JSON.stringify({ downloadDirectory: path.join(home, 'Downloads'), showDownloadInfoDialog: false,
  showProgressDialog: false, showCompleteDialog: false });
execFileSync('defaults', ['write', 'app.castnet.mac.test', 'CastnetSettings', '-data', Buffer.from(settings).toString('hex')]);
const env = { ...process.env, CASTNET_HOME: home, CASTNET_HEADLESS: '1' };
const appProc = spawn(path.join(app, 'Castnet'), [], { env, stdio: 'ignore' });
function appCall(message) {
  const msg = Buffer.from(JSON.stringify(message));
  const len = Buffer.alloc(4); len.writeUInt32LE(msg.length);
  const out = execFileSync(path.join(app, 'castnet-host'), { input: Buffer.concat([len, msg]), env });
  return JSON.parse(out.subarray(4, 4 + out.readUInt32LE(0)).toString());
}
const appItems = () => appCall({ type: 'list' }).items || [];
let up = false;
for (let i = 0; i < 60 && !up; i++) { await sleep(250); try { up = Array.isArray(appCall({ type: 'list' }).items); } catch { /* not yet */ } }
check(up, 'test instance of Castnet is running');

fs.mkdirSync(path.join(profile, 'NativeMessagingHosts'), { recursive: true });
fs.writeFileSync(path.join(profile, 'NativeMessagingHosts/app.castnet.host.json'), JSON.stringify({
  name: 'app.castnet.host', description: 'Castnet (test)', path: path.join(app, 'castnet-host'), type: 'stdio',
  allowed_origins: [`chrome-extension://${EXT_ID}/`],
}));
const ctx = await chromium.launchPersistentContext(profile, {
  executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  headless: true, env,
  ignoreDefaultArgs: ['--disable-extensions', '--disable-component-extensions-with-background-pages'],
  args: ['--enable-unsafe-extension-debugging'],
});
const cdp = await ctx.browser().newBrowserCDPSession();
// Downloads behave like a normal Chrome: real file names, saved to a folder of our own.
await cdp.send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: browserDownloads, eventsEnabled: true });
await cdp.send('Extensions.loadUnpacked', { path: path.join(root, 'dist/extensions/chrome') });
await sleep(1200);
const ext = await ctx.newPage();
await ext.goto(`chrome-extension://${EXT_ID}/popup/popup.html`);
const browserList = () => ext.evaluate(() => new Promise((r) => chrome.downloads.search({}, r)));

const page = await ctx.newPage();
await page.goto('http://127.0.0.1:8765/takeover.html');
await sleep(800);
for (const id of ['unknown', 'tiny', 'once', 'blob', 'pdf', 'canvas', 'oneuse', 'twouse']) {
  await page.click(`#${id}`);
  await sleep(1500);
}
const stayed = page.url().endsWith('/takeover.html');

// Castnet's side
let items = [];
for (let i = 0; i < 60; i++) {
  items = appItems();
  if (items.filter((x) => x.state === 'completed').length >= 8) break;
  await sleep(500);
}
const byName = (n) => items.find((x) => x.filename === n);
const done = (n) => byName(n)?.state === 'completed';
const unknown = byName('notes.qqq');
check(done('notes.qqq'), `a file type that wasn't on the old list went to Castnet (${unknown?.state ?? 'missing'})`);
check(unknown?.outputs?.[0] && sha(unknown.outputs[0]) === sha(path.join(media, 'aonly.mp4')), '…and Castnet saved the exact file');
check(done('tiny.json'), `a 113-byte file went to Castnet (${byName('tiny.json')?.state ?? 'missing'})`);
check(done('doc.pdf') && stayed, `a click on a PDF link went to Castnet and the page stayed put (${byName('doc.pdf')?.state ?? 'missing'})`);
const canvas = byName('week3-notes.pdf');
check(done('week3-notes.pdf') && sha(canvas.outputs[0]) === sha(path.join(media, 'aonly.mp4')),
  `a download that redirects to signed storage (like Canvas) went to Castnet (${canvas?.state ?? 'missing'})`);
// Only the browser could fetch these two; it finished them and Castnet took the files.
const once = byName('once.webm'), made = byName('made-here.txt');
check(done('once.webm') && sha(once.outputs[0]) === sha(path.join(media, 'vonly.webm')),
  `the one-time link finished in the browser, then Castnet took the file (${once?.state ?? 'missing'})`);
check(done('made-here.txt') && fs.readFileSync(made.outputs[0], 'utf8') === 'made by the page',
  `the file the page made itself ended up in Castnet too (${made?.state ?? 'missing'})`);
const castnetFolder = fs.realpathSync(path.join(home, 'Downloads'));
check([once, made].every((x) => x?.outputs?.[0] && path.dirname(fs.realpathSync(x.outputs[0])) === castnetFolder), "…moved into Castnet's folder");

// Links that work once or twice (like Canvas): the browser's download is never interrupted, so the
// full file always ends up in Castnet, and nothing in Castnet is ever an empty file.
const oneuse = byName('Test-2-Review.pdf'), twouse = byName('quiz.pdf');
check(done('Test-2-Review.pdf') && sha(oneuse.outputs[0]) === sha(path.join(media, 'vonly.webm')),
  `a link that works only once: the full file ended up in Castnet (${oneuse?.state ?? 'missing'}, ${oneuse?.total ?? 0} bytes)`);
check(done('quiz.pdf') && sha(twouse.outputs[0]) === sha(path.join(media, 'aonly.mp4')),
  `a link whose second fetch gives nothing: the full file ended up in Castnet (${twouse?.state ?? 'missing'}, ${twouse?.total ?? 0} bytes)`);
const empty = items.filter((x) => x.state === 'completed' && !(x.outputs?.[0] && fs.statSync(x.outputs[0]).size > 0));
check(empty.length === 0, `no download in Castnet is an empty file (${empty.map((x) => x.filename).join(', ') || 'none'})`);
check(items.filter((x) => /Test-2-Review|quiz/.test(x.filename)).length === 2, 'each of them is listed once');

// The app knows which extension version Chrome runs (it shows a banner when that's out of date).
const extVersions = appCall({ type: 'ping' }).extensions || {};
const ownVersion = JSON.parse(fs.readFileSync(path.join(root, 'dist/extensions/chrome/manifest.json'), 'utf8')).version;
check(extVersions['com.google.Chrome'] === ownVersion, `the app knows Chrome runs extension ${extVersions['com.google.Chrome'] ?? 'unknown'}`);

// The browser's side: nothing left behind, nothing saved twice.
await sleep(1500);
const list = await browserList();
const names = ['notes.qqq', 'tiny.json', 'once.webm', 'made-here.txt', 'doc.pdf', 'week3-notes.pdf', 'Test-2-Review.pdf', 'quiz.pdf'];
check(!list.some((d) => names.some((n) => (d.filename || '').endsWith(n))), "the browser's download list has none of them");
check(fs.readdirSync(browserDownloads).filter((f) => !f.startsWith('.')).length === 0, "the browser's download folder is empty (no second copies)");

await ctx.close();
appProc.kill();
execFileSync('defaults', ['delete', 'app.castnet.mac.test']);
console.log(failures ? `\n${failures} CHECK(S) FAILED` : '\nTAKEOVER E2E PASSED');
process.exit(failures ? 1 : 0);
