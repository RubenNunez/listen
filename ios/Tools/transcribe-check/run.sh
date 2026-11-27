#!/bin/sh
# Runs the app's on-device listening stages on this Mac against synthetic speech:
# a short two-voice conversation, fed in real time.
# Usage: ios/Tools/transcribe-check/run.sh [de|en] ["glossary" | -]
#   glossary: words the second stage should expect; "-" switches that stage off.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
language="${1:-de}"
glossary="${2:-}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
if [ "$language" = de ]; then
  a="Anna"; b="Eddy (German (Germany))"
  set -- "Guten Tag, schön dass Sie da sind. Können Sie mir erklären, wie Sie Backpressure in einem Streaming-Dienst umsetzen?" \
         "Gerne. Wir begrenzen die Warteschlange und geben dem Sender ein Signal, wenn sie voll ist." \
         "Und wie testen Sie das unter Last?" \
         "Mit einem Lasttest, der zehntausend Verbindungen gleichzeitig öffnet."
  # LISTEN_SCRIPT=names: the two introduce themselves, to check that names are found.
  if [ "${LISTEN_SCRIPT:-}" = names ]; then
    set -- "Guten Tag, ich bin Anna. Schön, dass Sie da sind." \
           "Hallo Anna, ich heisse Markus. Danke für die Einladung." \
           "Markus, können Sie mir erklären, wie Sie Backpressure in einem Streaming-Dienst umsetzen?" \
           "Gerne. Wir begrenzen die Warteschlange und geben dem Sender ein Signal, wenn sie voll ist."
  fi
else
  a="Samantha"; b="Eddy (English (US))"
  set -- "Good morning. Can you explain how you would implement backpressure in a streaming service?" \
         "Sure. We bound the queue and signal the sender when it is full." \
         "And how do you test that under load?" \
         "With a load test that opens ten thousand connections at once."
fi
n=0
: > "$work/speech.raw"
for text in "$@"; do
  n=$((n + 1))
  if [ $((n % 2)) = 1 ]; then voice="$a"; else voice="$b"; fi
  say -v "$voice" -o "$work/$n.aiff" "$text"
  afconvert -f caff -d LEI16@16000 -c 1 "$work/$n.aiff" "$work/$n.caf"
  # Raw samples: everything after the CAF "data" chunk header (12 bytes) and its
  # 4-byte edit count, followed by 0.4 s of silence between the turns.
  python3 -I -c "
import sys
d = open(sys.argv[1], 'rb').read()
i = d.index(b'data')
open(sys.argv[2], 'ab').write(d[i + 16:] + bytes(12800))
" "$work/$n.caf" "$work/speech.raw"
done
swift build -c release --package-path "$here" 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" | tail -3
"$here/.build/release/check" "$work/speech.raw" "$language" "$glossary"
