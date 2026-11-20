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
for (const id of ['unknown', 'tiny', 'once', 'blob']) {
  await page.click(`#${id}`);
  await sleep(1500);
}

// Castnet's side
let items = [];
for (let i = 0; i < 40; i++) {
  items = appItems();
  if (items.filter((x) => x.state === 'completed').length >= 2) break;
  await sleep(500);
}
const byName = (n) => items.find((x) => x.filename === n);
const unknown = byName('notes.qqq'), tiny = byName('tiny.json');
check(unknown?.state === 'completed', `a file type that wasn't on the old list went to Castnet (${unknown?.state ?? 'missing'})`);
check(unknown?.outputs?.[0] && sha(unknown.outputs[0]) === sha(path.join(media, 'aonly.mp4')), '…and Castnet saved the exact file');
check(tiny?.state === 'completed', `a 113-byte file went to Castnet (${tiny?.state ?? 'missing'})`);
check(!items.some((x) => /once/.test(x.filename)), 'the one-time link was NOT taken from the browser');
check(!items.some((x) => /made-here/.test(x.filename)), 'the file the page made itself was NOT taken from the browser');

// The browser's side
await sleep(2500);
const list = await browserList();
const inBrowser = (n) => list.find((d) => (d.filename || '').endsWith(n));
check(!inBrowser('notes.qqq') && !inBrowser('tiny.json'), 'the browser dropped its copies of the files Castnet took');
check(inBrowser('once.webm')?.state === 'complete' && fs.existsSync(path.join(browserDownloads, 'once.webm')),
  `the one-time link still finished in the browser (${inBrowser('once.webm')?.state ?? 'missing'})`);
check(inBrowser('made-here.txt')?.state === 'complete', `the page-made file finished in the browser (${inBrowser('made-here.txt')?.state ?? 'missing'})`);

await ctx.close();
appProc.kill();
execFileSync('defaults', ['delete', 'app.castnet.mac.test']);
console.log(failures ? `\n${failures} CHECK(S) FAILED` : '\nTAKEOVER E2E PASSED');
process.exit(failures ? 1 : 0);
