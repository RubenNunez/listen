#!/usr/bin/env python3
"""Collect unmodified notice texts from the resolved public Swift package checkouts."""
from pathlib import Path
import argparse
import json

parser = argparse.ArgumentParser()
parser.add_argument('--checkouts', type=Path, required=True)
parser.add_argument('--resolved', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
pins = json.loads(args.resolved.read_text())['pins']
sections = ['Listen: third-party Swift library license texts\nGenerated from the resolved public package sources. Model/service terms are separate.\n']
missing = []
for pin in sorted(pins, key=lambda p: p['identity']):
    identity = pin['identity']
    folder = args.checkouts / identity
    if not folder.is_dir():
        missing.append(identity)
        continue
    found = []
    for file in sorted(folder.rglob('*')):
        if not file.is_file() or '.git' in file.relative_to(folder).parts:
            continue
        name = file.name.lower()
        # Some packages name component notices `Component-LICENSE.md`.
        is_notice = name.startswith(('license', 'notice', 'copying', 'copyright')) or '-license' in name
        if not (is_notice and file.stat().st_size <= 2_000_000):
            continue
        try:
            body = file.read_text(encoding='utf-8')
        except (OSError, UnicodeError):
            continue
        found.append(f'\n--- {identity}/{file.relative_to(folder)} ---\n{body}\n')
    if not found:
        missing.append(identity)
    version = pin['state'].get('version', pin['state'].get('revision', 'unrecorded'))
    sections.append(f'\n=== {identity} {version} ===\nSource: {pin["location"]}\n' + ''.join(found))
if missing:
    raise SystemExit('Missing source/license texts: ' + ', '.join(missing))
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text('\n'.join(sections), encoding='utf-8')
print(f'Collected notice texts for {len(pins)} resolved packages ({args.output.stat().st_size} bytes).')
