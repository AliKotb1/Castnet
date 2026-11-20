// End-to-end test of automatic link renewal:
// real Chrome + the extension + a headless test instance of Castnet (own folder/settings,
// never your real list) + a page whose video link expires after a few seconds.
//   node test/e2e-renew.mjs <scratch-dir>      (test server must run on :8765)
import { createRequire } from 'node:module';
import { execFileSync, spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const require = createRequire(import.meta.url);
// playwright-core from the project, else the global install (npm i -g playwright-core).
const { chromium } = (() => {
  try { return require('playwright-core'); } catch {}
  const globalRoot = execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim();
  return require(path.join(globalRoot, 'playwright-core'));
})();

const scratch = path.resolve(process.argv[2]);
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const app = path.join(root, 'dist/Castnet.app/Contents/MacOS');
const EXT_ID = 'jninbfcnkkcefbjldiiiogbajkeohemb';
const home = path.join(scratch, 'apphome');
const profile = path.join(scratch, 'chrome-renew');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
const check = (ok, label) => { console.log(`  ${ok ? '✓' : '✗'} ${label}`); if (!ok) failures++; };

// --- test instance of the app
fs.rmSync(home, { recursive: true, force: true });
fs.mkdirSync(path.join(home, 'Downloads'), { recursive: true });
const settings = JSON.stringify({ downloadDirectory: path.join(home, 'Downloads'), connections: 2, autoRenewLinks: true,
  showDownloadInfoDialog: false, showProgressDialog: false, showCompleteDialog: false });
execFileSync('defaults', ['write', 'app.castnet.mac.test', 'CastnetSettings', '-data', Buffer.from(settings).toString('hex')]);
const env = { ...process.env, CASTNET_HOME: home, CASTNET_HEADLESS: '1' };
const appProc = spawn(path.join(app, 'Castnet'), [], { env, stdio: 'ignore' });
function appCall(message) {
  const msg = Buffer.from(JSON.stringify(message));
  const len = Buffer.alloc(4); len.writeUInt32LE(msg.length);
  const out = execFileSync(path.join(app, 'castnet-host'), { input: Buffer.concat([len, msg]), env });
  return JSON.parse(out.subarray(4, 4 + out.readUInt32LE(0)).toString());
}
const appList = () => appCall({ type: 'list' }).items;
let up = false;
for (let i = 0; i < 60 && !up; i++) { await sleep(250); try { up = Array.isArray(appList()); } catch { /* not yet */ } }
check(up, 'test instance of Castnet is running');

// --- Chrome with the extension; the host inherits CASTNET_HOME and talks to the test instance
fs.rmSync(profile, { recursive: true, force: true });
fs.mkdirSync(path.join(profile, 'NativeMessagingHosts'), { recursive: true });
fs.writeFileSync(path.join(profile, 'NativeMessagingHosts/app.castnet.host.json'), JSON.stringify({
  name: 'app.castnet.host', description: 'Castnet (test)', path: path.join(app, 'castnet-host'), type: 'stdio',
  allowed_origins: [`chrome-extension://${EXT_ID}/`],
}));
const ctx = await chromium.launchPersistentContext(profile, {
  executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  headless: true, env,
  ignoreDefaultArgs: ['--disable-extensions', '--disable-component-extensions-with-background-pages'],
  args: ['--enable-unsafe-extension-debugging', '--autoplay-policy=no-user-gesture-required'],
});
const cdp = await ctx.browser().newBrowserCDPSession();
await cdp.send('Extensions.loadUnpacked', { path: path.join(root, 'dist/extensions/chrome') });
await sleep(1200);
const ext = await ctx.newPage();
await ext.goto(`chrome-extension://${EXT_ID}/popup/popup.html`);
const call = (m) => ext.evaluate((x) => chrome.runtime.sendMessage(x), m);

const page = await ctx.newPage();
const pageUrl = 'http://127.0.0.1:8765/expiring.html?ttl=5';
await page.goto(pageUrl);
await sleep(2500);
const tabId = await ext.evaluate(async (u) => (await chrome.tabs.query({})).find((t) => t.url === u)?.id, pageUrl);
const menu = await call({ type: 'getMenu', tabId, explicit: true });
const entry = menu.entries.find((e) => e.size > 20e6);
check(!!entry, `video with an expiring link detected (${entry?.quality} · ${entry && (entry.size / 1048576).toFixed(1)} MB)`);
const r = await call({ type: 'download', tabId, action: entry.action });
check(r?.ok, 'download handed to Castnet');

let saw = { expired: false, renewed: false };
let item;
const t0 = Date.now();
let lastCheck = 0;
while (Date.now() - t0 < 120000) {
  item = appList()[0];
  if (item?.state === 'expired' && !saw.expired) { saw.expired = true; console.log(`     link expired at ${(item.received / 1048576).toFixed(1)} MB`); }
  if (saw.expired && item?.state === 'running') saw.renewed = true;
  if (item?.state === 'completed' || item?.state === 'failed') break;
  // The alarm runs every minute; trigger it now instead of waiting.
  if (item?.state === 'expired' && Date.now() - lastCheck > 8000) {
    lastCheck = Date.now();
    const c = await call({ type: 'checkRenewals' });
    console.log(`     renewal check: ${c.pending} waiting, ${c.tabs} background tab(s) opened`);
  }
  await sleep(500);
}
check(saw.expired, 'the link expired in the middle of the download');
check(saw.renewed, 'the extension found a fresh link and the download continued');
check(item?.state === 'completed', `download completed (${item?.state}: ${item?.detail})`);
if (item?.outputs?.[0]) {
  const sha = (f) => crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');
  check(sha(item.outputs[0]) === sha(path.join(scratch, 'media/progressive.mp4')), 'file is byte-identical (nothing re-downloaded wrongly)');
}
// The app knows which browser the extension runs in (the setup walkthrough waits for this).
const browsers = appCall({ type: 'ping' }).browsers || [];
check(browsers.includes('com.google.Chrome'), `the app recognized the extension's browser as Google Chrome (${browsers.join(', ') || 'none'})`);
const tabsLeft = await ext.evaluate(async () => (await chrome.tabs.query({})).length);
console.log(`     tabs open at the end: ${tabsLeft}`);

await ctx.close();
appProc.kill();
execFileSync('defaults', ['delete', 'app.castnet.mac.test']);
console.log(failures ? `\n${failures} CHECK(S) FAILED` : '\nRENEWAL E2E PASSED');
process.exit(failures ? 1 : 0);
