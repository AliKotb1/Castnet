#!/usr/bin/env python3
"""Writes castnet-update.json, the file installed copies of Castnet check for updates:
version, download address, the DMG's SHA-256 (checked before installing) and plain-text notes
shown in the app's "A new version of Castnet is available" window.
   scripts/update-feed.py <version> <dmg-url> <sha256> <changes.md>   (prints the JSON)
"""
import json, re, sys

version, url, sha, changes = sys.argv[1:5]
lines = []
for line in open(changes, encoding='utf-8').read().splitlines():
    line = line.replace('**', '').replace('`', '')
    line = re.sub(r'(?<![\w*])\*([^*\n]+)\*(?![\w*])', r'\1', line)   # *italics* → plain
    if m := re.match(r'^## What’s new in (.+)', line):
        line = f'Castnet {m.group(1)}'
    elif m := re.match(r'^## (.+) \(included\)', line):
        line = f'Castnet {m.group(1)}'
    elif m := re.match(r'^#### (.+)', line):
        line = f'{m.group(1)}:'
    elif line.startswith('- '):
        line = '• ' + line[2:]
    lines.append(line)
notes = re.sub(r'\n{3,}', '\n\n', '\n'.join(lines)).strip()
print(json.dumps({'version': version, 'url': url, 'sha256': sha, 'notes': notes}, ensure_ascii=False))
