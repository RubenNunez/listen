#!/bin/sh
# Plays a recorded run through the current listening stages again and prints
# what they make of it now, next to what was recorded then.
# Usage: ios/Tools/transcribe-check/replay.sh <run folder> [glossary | -]
#   OPENROUTER_API_KEY in the environment adds the cloud models (costs money).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
run="${1:?run folder}"
glossary="${2:-}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# The samples follow the 44-byte header our recorder writes.
tail -c +45 "$run/audio.wav" > "$work/audio.raw"
language="$(python3 -I -c "
import json, sys
try: print(json.load(open(sys.argv[1])).get('language', 'de'))
except Exception: print('de')
" "$run/run.json")"
swift build -c release --package-path "$here" 2>&1 | grep -E "error|Build complete" | tail -2
echo "== recorded then: voice of each sentence, last state"
python3 -I -c "
import json, sys
last = {}
for line in open(sys.argv[1]):
    e = json.loads(line)
    if e['kind'] == 'sentence': last[e['id']] = e
for i in sorted(last): print(f\"  #{i} [voice {last[i]['voice']}] {last[i]['text']}\")
print('  voices:', sorted({e['voice'] for e in last.values() if e['voice']}))
" "$run/events.jsonl"
echo "== now"
"$here/.build/release/check" "$work/audio.raw" "$language" "$glossary" 2>&1 | python3 -I -c "
import sys, re
last = {}
for line in sys.stdin:
    m = re.search(r'(REFINED|FINAL  ) #(\d+) \[(.*?)\] (.*)', line)
    if m: last[int(m.group(2))] = (m.group(3), m.group(4).strip())
    elif re.search(r'NAMES|ME  |ERROR', line): print(' ', line.strip())
for i in sorted(last): print(f'  #{i} [{last[i][0]}] {last[i][1]}')
print('  voices:', sorted({v for v, _ in last.values() if v != '-'}))
"
