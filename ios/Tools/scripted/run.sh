#!/bin/sh
# Speaks a written conversation with two system voices and runs it through the real
# Mac app: the sound goes in where the microphone would, the app starts and ends the
# session by itself, and the run is written to runs/ like any other.
# Usage: ios/Tools/scripted/run.sh <script.txt | recording.wav | run folder> [voice A] [voice B]
#   Script lines: "A: text", "B: text", "--" for a longer pause, "#" for a comment.
#   The cards use the models connected in the app (a signed-in plan is used).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
script="${1:?script file}"
a="${2:-Anna}"
b="${3:-Reed (German (Germany))}"
runs="$(cd "$here/../../.." && pwd)/runs"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# A recording instead of a script: a WAV file (16 kHz mono 16-bit, as the app records it)
# or the folder of a recorded run. Real speech goes through the pipeline as it was spoken.
case "$script" in
  *.wav) recording="$script" ;;
  *) [ -d "$script" ] && recording="$script/audio.wav" || recording="" ;;
esac
n=0
: > "$work/speech.raw"
if [ -n "$recording" ]; then
  # WAV files can contain metadata chunks before their PCM, not only a 44-byte header.
  python3 -I -c '
import sys, wave
with wave.open(sys.argv[1], "rb") as sound:
    if (sound.getnchannels(), sound.getsampwidth(), sound.getframerate(), sound.getcomptype()) != (1, 2, 16000, "NONE"):
        raise SystemExit("Recording must be 16 kHz mono 16-bit uncompressed PCM")
    open(sys.argv[2], "wb").write(sound.readframes(sound.getnframes()))
' "$recording" "$work/speech.raw"
  script=/dev/null
fi
silence() { python3 -I -c "import sys; open(sys.argv[1], 'ab').write(bytes(int(float(sys.argv[2]) * 32000)))" "$work/speech.raw" "$1"; }
[ -n "$recording" ] || silence 1
while IFS= read -r line; do
  case "$line" in
    "#"*|"") continue ;;
    "--") silence 2.5; continue ;;
    "A: "*) voice="$a" ;;
    "B: "*) voice="$b" ;;
    *) continue ;;
  esac
  n=$((n + 1))
  say -v "$voice" -o "$work/$n.aiff" "${line#?: }"
  afconvert -f caff -d LEI16@16000 -c 1 "$work/$n.aiff" "$work/$n.caf"
  python3 -I -c "
import sys
d = open(sys.argv[1], 'rb').read()
i = d.index(b'data')
open(sys.argv[2], 'ab').write(d[i + 16:])
" "$work/$n.caf" "$work/speech.raw"
  silence 0.8
done < "$script"
newest() {
  # Measurement folders beside the runs must not hide the newest recording.
  python3 -I -c 'import pathlib,re,sys; paths=sorted(p.name for p in pathlib.Path(sys.argv[1]).iterdir() if p.is_dir() and re.fullmatch(r"\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}", p.name)); print(paths[-1] if paths else "")' "$runs"
}
before="$(newest)"
pkill -f "Debug-maccatalyst/Listen.app/Contents/MacOS/Listen" 2>/dev/null && sleep 1 || true
"$here/../../build/catalyst/Build/Products/Debug-maccatalyst/Listen.app/Contents/MacOS/Listen" \
  -runsFolder "$runs" -audioFile "$work/speech.raw" >/dev/null 2>&1 || true
after="$(newest)"
[ "$after" != "$before" ] && echo "$runs/$after" || echo "no run was written" >&2
