#!/usr/bin/env python3
# Stand-in native-messaging host for end-to-end tests: records download requests to
# $CASTNET_TEST_LOG (JSON lines) instead of sending them to the real app, so tests never
# touch your download list. "formats" is answered by the real host (site quality lists).
import json, os, struct, subprocess, sys

LOG = os.environ.get('CASTNET_TEST_LOG') or os.path.join(os.path.dirname(os.path.abspath(__file__)), '.e2e-requests.jsonl')
REAL = '/Applications/Castnet.app/Contents/MacOS/castnet-host'

def read():
    h = sys.stdin.buffer.read(4)
    if len(h) < 4:
        return None
    n = struct.unpack('<I', h)[0]
    return json.loads(sys.stdin.buffer.read(n))

def write(obj):
    b = json.dumps(obj).encode()
    sys.stdout.buffer.write(struct.pack('<I', len(b)) + b)
    sys.stdout.buffer.flush()

def forward(msg):
    b = json.dumps(msg).encode()
    out = subprocess.run([REAL], input=struct.pack('<I', len(b)) + b, capture_output=True, timeout=90).stdout
    return json.loads(out[4:4 + struct.unpack('<I', out[:4])[0]]) if len(out) >= 4 else {'ok': False, 'error': 'no reply'}

while True:
    msg = read()
    if msg is None:
        break
    t = msg.get('type')
    if t == 'ping':
        write({'ok': True, 'running': True, 'version': 'test', 'ffmpeg': True, 'ytdlp': True})
    elif t == 'formats':
        write(forward(msg))
    elif t in ('download', 'downloadBatch'):
        with open(LOG, 'a') as f:
            f.write(json.dumps(msg) + '\n')
        write({'ok': True, 'count': len(msg.get('requests', [])) or 1})
    else:
        write({'ok': True})
