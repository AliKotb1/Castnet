#!/usr/bin/env python3
"""Firefox-family test: drives Zen (or Firefox) through Marionette with a throwaway profile,
installs dist/extensions/Castnet.xpi as a temporary add-on, opens the test page, uses the
"Download this video" panel, and checks the download reaches a headless test instance of Castnet.
   python3 test/zen-firefox.py <scratch-dir> [/path/to/browser-binary]
"""
import atexit, json, os, socket, struct, subprocess, sys, time, hashlib, shutil

scratch = os.path.abspath(sys.argv[1])
browser = sys.argv[2] if len(sys.argv) > 2 else '/Applications/Zen.app/Contents/MacOS/zen'
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
app = os.path.join(root, 'dist/Castnet.app/Contents/MacOS')
home = os.path.join(scratch, 'apphome-ff')
profile = os.path.join(scratch, 'zen-profile')
fails = 0

def check(ok, label):
    global fails
    print(('  ✓ ' if ok else '  ✗ ') + label)
    if not ok: fails += 1

# --- headless test instance of Castnet
shutil.rmtree(home, ignore_errors=True)
os.makedirs(os.path.join(home, 'Downloads'))
settings = json.dumps({'downloadDirectory': os.path.join(home, 'Downloads'), 'showDownloadInfoDialog': False,
                       'showProgressDialog': False, 'showCompleteDialog': False})
subprocess.run(['defaults', 'write', 'app.castnet.mac.test', 'CastnetSettings', '-data', settings.encode().hex()], check=True)
env = dict(os.environ, CASTNET_HOME=home, CASTNET_HEADLESS='1', MOZ_REMOTE_ALLOW_SYSTEM_ACCESS='1')
app_proc = subprocess.Popen([os.path.join(app, 'Castnet')], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
procs = [app_proc]
# Always stop the browser and the test app, even if a check crashes (leftovers would answer the next run).
atexit.register(lambda: [p.terminate() for p in procs if p.poll() is None])

def host(msg):
    b = json.dumps(msg).encode()
    out = subprocess.run([os.path.join(app, 'castnet-host')], input=struct.pack('<I', len(b)) + b, capture_output=True, env=env).stdout
    return json.loads(out[4:4 + struct.unpack('<I', out[:4])[0]]) if len(out) >= 4 else None

for _ in range(60):
    time.sleep(0.25)
    r = host({'type': 'list'})
    if r and r.get('ok'): break
check(bool(r and r.get('ok')), 'test instance of Castnet is running')

# --- native-messaging registration for Firefox-family browsers (the real app writes the same file)
manifest = {'name': 'app.castnet.host', 'description': 'Castnet download manager',
            'path': os.path.join(app, 'castnet-host'), 'type': 'stdio', 'allowed_extensions': ['castnet@castnet.app']}
# Firefox-family browsers only read these from your own Library folders, so the test borrows them:
# what's there now is saved and put back when the test ends (even if it crashes), so your browsers
# never stay pointed at the test build. (While the test runs, a Zen you have open uses it too.)
saved_manifests = {}
for d in ['Mozilla', 'zen']:
    p = os.path.expanduser(f'~/Library/Application Support/{d}/NativeMessagingHosts')
    os.makedirs(p, exist_ok=True)
    f = os.path.join(p, 'app.castnet.host.json')
    saved_manifests[f] = open(f, 'rb').read() if os.path.exists(f) else None
    with open(f, 'w') as out: json.dump(manifest, out, indent=2)

def restore_manifests():
    for f, data in saved_manifests.items():
        if data is None:
            try: os.remove(f)
            except FileNotFoundError: pass
        else:
            with open(f, 'wb') as out: out.write(data)
atexit.register(restore_manifests)

# --- throwaway profile + browser with Marionette
shutil.rmtree(profile, ignore_errors=True)
os.makedirs(profile)
zen_downloads = os.path.join(scratch, 'zen-downloads')
shutil.rmtree(zen_downloads, ignore_errors=True)
os.makedirs(zen_downloads)
with open(os.path.join(profile, 'user.js'), 'w') as f:
    f.write('\n'.join([
        'user_pref("xpinstall.signatures.required", false);',
        'user_pref("extensions.autoDisableScopes", 0);',
        'user_pref("browser.shell.checkDefaultBrowser", false);',
        'user_pref("media.autoplay.default", 0);',
        'user_pref("marionette.port", 28282);',
        'user_pref("datareporting.policy.dataSubmissionEnabled", false);',
        'user_pref("browser.aboutwelcome.enabled", false);',
        'user_pref("zen.welcome-screen.seen", true);',
        # Anything the browser keeps lands in the scratch folder, never in ~/Downloads.
        'user_pref("browser.download.folderList", 2);',
        f'user_pref("browser.download.dir", "{zen_downloads}");',
        'user_pref("browser.download.useDownloadDir", true);',
        'user_pref("browser.download.always_ask_before_handling_new_types", false);',
    ]) + '\n')
proc = subprocess.Popen([browser, '--marionette', '--headless', '--no-remote', '--profile', profile],
                        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
procs.append(proc)

class Marionette:
    def __init__(self, port):
        for _ in range(80):
            try:
                self.s = socket.create_connection(('127.0.0.1', port), timeout=60); break
            except OSError: time.sleep(0.25)
        self.buf = b''
        self.id = 0
        self.read()  # hello
    def read(self):
        while b':' not in self.buf: self.buf += self.s.recv(65536)
        n, rest = self.buf.split(b':', 1)
        n = int(n)
        while len(rest) < n: rest += self.s.recv(65536)
        self.buf = rest[n:]
        return json.loads(rest[:n])
    def cmd(self, name, params=None):
        self.id += 1
        data = json.dumps([0, self.id, name, params or {}]).encode()
        self.s.sendall(str(len(data)).encode() + b':' + data)
        while True:
            m = self.read()
            if m[0] == 1 and m[1] == self.id:
                if m[2]: raise RuntimeError(m[2])
                return m[3]

m = Marionette(28282)
caps = m.cmd('WebDriver:NewSession', {'capabilities': {'alwaysMatch': {'acceptInsecureCerts': True}}})
name = caps['capabilities'].get('browserName'); ver = caps['capabilities'].get('browserVersion')
print(f'     {name} {ver}')
addon = m.cmd('Addon:Install', {'path': os.path.join(root, 'dist/extensions/Castnet.xpi'), 'temporary': True})
check(addon.get('value') == 'castnet@castnet.app', 'Castnet add-on installed in the Firefox-family browser')

def js(script, *args):
    return m.cmd('WebDriver:ExecuteScript', {'script': script, 'args': list(args)}).get('value')

# Open the test page in a normal tab created by the add-on itself (Zen doesn't expose the
# automation's initial tab to extensions, while every tab a user opens is visible).
m.cmd('Marionette:SetContext', {'value': 'chrome'})
popup_url = m.cmd('WebDriver:ExecuteScript', {'script': 'return WebExtensionPolicy.getByID("castnet@castnet.app").getURL("popup/popup.html")', 'args': []}).get('value')
m.cmd('Marionette:SetContext', {'value': 'content'})
m.cmd('WebDriver:Navigate', {'url': popup_url})
time.sleep(1)
before = m.cmd('WebDriver:GetWindowHandles')
m.cmd('WebDriver:ExecuteAsyncScript', {'script': 'const d = arguments[arguments.length-1]; browser.tabs.create({url: "http://127.0.0.1:8765/page.html", active: true}).then(() => d(true), (e) => d(String(e)));', 'args': []})
time.sleep(2)
new = [h for h in m.cmd('WebDriver:GetWindowHandles') if h not in before]
m.cmd('WebDriver:SwitchToWindow', {'handle': new[0] if new else before[-1]})
time.sleep(1.5)
js('document.querySelector("video").play()')
time.sleep(3)
check(js('return document.documentElement.dataset.castnetHooked') == '1', 'page hook (fetch/XHR scanner) runs in the page')
rect = js('const r = document.querySelector("video").getBoundingClientRect(); return [r.x, r.y, r.width, r.height]')
x, y, w, h = [int(v) for v in rect]

def move(px, py):
    m.cmd('WebDriver:PerformActions', {'actions': [{'type': 'pointer', 'id': 'mouse', 'parameters': {'pointerType': 'mouse'},
          'actions': [{'type': 'pointerMove', 'x': px, 'y': py, 'duration': 50}]}]})

def click(px, py):
    m.cmd('WebDriver:PerformActions', {'actions': [{'type': 'pointer', 'id': 'mouse', 'parameters': {'pointerType': 'mouse'},
          'actions': [{'type': 'pointerMove', 'x': px, 'y': py, 'duration': 50}, {'type': 'pointerDown', 'button': 0},
                      {'type': 'pointerUp', 'button': 0}]}]})

move(x + w // 2, y + h // 2); time.sleep(0.4); move(x + w // 2 + 6, y + h // 2 + 6); time.sleep(1)
check(js('return document.querySelectorAll("castnet-ui").length') == 1, '"Download this video" panel appears over the video')
click(x + w - 120, y + 25)   # open the quality menu
time.sleep(3)
png = m.cmd('WebDriver:TakeScreenshot', {}).get('value')
if png:
    import base64
    open(os.path.join(scratch, 'shots', 'zen-menu.png'), 'wb').write(base64.b64decode(png))
click(x + w - 200, y + 82)   # first quality row
for _ in range(40):
    time.sleep(0.5)
    items = (host({'type': 'list'}) or {}).get('items', [])
    if items and items[0]['state'] == 'completed': break
check(bool(items), 'download sent from Zen reached Castnet through native messaging')
if not items:
    # Diagnostics: ask the add-on (from its own page) what it detected and what it may access.
    m.cmd('Marionette:SetContext', {'value': 'chrome'})
    popup = m.cmd('WebDriver:ExecuteScript', {'script': 'return WebExtensionPolicy.getByID("castnet@castnet.app").getURL("popup/popup.html")', 'args': []}).get('value')
    m.cmd('Marionette:SetContext', {'value': 'content'})
    before = m.cmd('WebDriver:GetWindowHandles')
    m.cmd('WebDriver:NewWindow', {'type': 'tab'})
    m.cmd('WebDriver:SwitchToWindow', {'handle': [h for h in m.cmd('WebDriver:GetWindowHandles') if h not in before][0]})
    m.cmd('WebDriver:Navigate', {'url': popup})
    time.sleep(1.5)
    diag = m.cmd('WebDriver:ExecuteAsyncScript', {'script': """
const done = arguments[arguments.length - 1];
(async () => {
  const perms = await browser.permissions.getAll();
  const tabs = await browser.tabs.query({});
  const out = [];
  for (const t of tabs) {
    const menu = /^http/.test(t.url || '') ? await browser.runtime.sendMessage({ type: 'getMenu', tabId: t.id, explicit: true }).catch((e) => String(e)) : null;
    out.push({ id: t.id, url: t.url, hidden: t.hidden, entries: menu && menu.entries && menu.entries.length, status: menu && menu.status, app: menu && menu.app });
  }
  done({ origins: perms.origins, tabs: out });
})().catch((e) => done({ error: String(e) }));""", 'args': []}).get('value')
    print('     diagnostics:', json.dumps(diag)[:1500])
if items:
    check(items[0]['state'] == 'completed', f"download completed: {items[0]['filename']}")

# --- download takeover: a file type that's on no list goes to Castnet, not the browser
# Opening a link the server marks as a download (Content-Disposition: attachment).
# Started from a script, so nothing waits for a page that never loads (it becomes a download).
js(f'window.location.href = "http://127.0.0.1:8765/attach/aonly.mp4?as=notes.qqq&k={time.time()}"; return true')
taken = None
for _ in range(40):
    time.sleep(0.5)
    # Firefox may correct the extension to match the file's type (notes.qqq → notes.mp4).
    taken = next((i for i in (host({'type': 'list'}) or {}).get('items', []) if i['filename'].startswith('notes.')), None)
    if taken and taken['state'] == 'completed': break
check(bool(taken) and taken['state'] == 'completed', f"a download of an unlisted file type went to Castnet ({taken and taken['state']})")
time.sleep(2)
check(not any(f.startswith('notes.') for f in os.listdir(zen_downloads)), 'the browser kept no second copy')

# --- links that work once or twice, like Canvas: the full file must end up in Castnet, never an empty one
for prefix, n, src in [('Test-2-Review', 1, 'vonly.webm'), ('quiz', 2, 'aonly.mp4')]:
    js(f'window.location.href = "http://127.0.0.1:8765/r/limited/attach/{src}?n={n}&as={prefix}.pdf&k={time.time()}"; return true')
    got = None
    for _ in range(60):
        time.sleep(0.5)
        got = next((i for i in (host({'type': 'list'}) or {}).get('items', []) if i['filename'].startswith(prefix + '.')), None)
        if got and got['state'] == 'completed': break
    full = os.path.getsize(os.path.join(scratch, 'media', src))
    size = os.path.getsize(got['outputs'][0]) if got and got.get('outputs') else 0
    check(bool(got) and got['state'] == 'completed' and size == full,
          f"a link that works {n}x: the full file ended up in Castnet ({got and got['state']}, {size} of {full} bytes)")
    m.cmd('WebDriver:Navigate', {'url': 'http://127.0.0.1:8765/takeover.html'})
    time.sleep(1)
items_now = (host({'type': 'list'}) or {}).get('items', [])
empty = [i['filename'] for i in items_now if i['state'] == 'completed' and not (i.get('outputs') and os.path.getsize(i['outputs'][0]) > 0)]
check(not empty, f"no download in Castnet is an empty file ({', '.join(empty) or 'none'})")
check(not os.listdir(zen_downloads), 'nothing was left in the browser\'s download folder')

# --- a click on a PDF link goes to Castnet instead of opening in the browser's viewer
m.cmd('WebDriver:Navigate', {'url': 'http://127.0.0.1:8765/takeover.html'})
time.sleep(1.5)
pr = js('const r = document.getElementById("pdf").getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]')
click(int(pr[0]), int(pr[1]))
pdf = None
for _ in range(30):
    time.sleep(0.5)
    pdf = next((i for i in (host({'type': 'list'}) or {}).get('items', []) if i['filename'] == 'doc.pdf'), None)
    if pdf and pdf['state'] == 'completed': break
check(bool(pdf) and pdf['state'] == 'completed', f"a click on a PDF link went to Castnet ({pdf and pdf['state']})")
check(js('return location.pathname') == '/takeover.html', 'the page stayed put (no PDF viewer)')
if not (taken and taken['state'] == 'completed'):
    m.cmd('Marionette:SetContext', {'value': 'chrome'})
    popup = m.cmd('WebDriver:ExecuteScript', {'script': 'return WebExtensionPolicy.getByID("castnet@castnet.app").getURL("popup/popup.html")', 'args': []}).get('value')
    m.cmd('Marionette:SetContext', {'value': 'content'})
    m.cmd('WebDriver:Navigate', {'url': popup})
    time.sleep(1)
    diag = m.cmd('WebDriver:ExecuteAsyncScript', {'script': 'const d = arguments[arguments.length-1]; browser.downloads.search({}).then((l) => d(l.map((x) => ({url: x.url, file: x.filename, state: x.state, error: x.error, by: x.byExtensionId}))), (e) => d(String(e)));', 'args': []}).get('value')
    print('     browser downloads:', json.dumps(diag)[:1500])

m.cmd('WebDriver:DeleteSession')
proc.terminate()
app_proc.terminate()
subprocess.run(['defaults', 'delete', 'app.castnet.mac.test'], stderr=subprocess.DEVNULL)
print('\nFIREFOX/ZEN TEST PASSED' if not fails else f'\n{fails} CHECK(S) FAILED')
sys.exit(1 if fails else 0)
