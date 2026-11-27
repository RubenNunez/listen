#!/bin/sh
# Converts a Whisper model trained on Swiss German (it writes Standard German)
# to the Core ML form WhisperKit loads, and puts it where the Mac app looks for
# it. One-time; downloads about 1.6 GB plus the Python packages, and takes a while.
#
# Usage: ios/Tools/swiss-german/convert.sh [hugging-face-model]
# Default model: gcoli/whisper-large-v3-turbo-swiss-german-mit (MIT licence).
#
# Uses Argmax's whisperkittools (https://github.com/argmaxinc/whisperkittools)
# in its own Python environment under ~/Library/Caches/listen-convert.
# Needs: git, uv (brew install uv).
set -eu
model="${1:-gcoli/whisper-large-v3-turbo-swiss-german-mit}"
work="$HOME/Library/Caches/listen-convert"
target="$HOME/Documents/huggingface/models/listen/swiss-german"
mkdir -p "$work"
cd "$work"
[ -d whisperkittools ] || git clone --depth 1 https://github.com/argmaxinc/whisperkittools.git
cd whisperkittools
[ -d .venv ] || uv venv --python 3.11 .venv
uv pip install --python .venv/bin/python -e .
.venv/bin/whisperkit-generate-model --model-version "$model" --output-dir "$work/out"
# The tool writes one folder per model; it holds the *.mlmodelc the app needs.
found="$(find "$work/out" -name AudioEncoder.mlmodelc -maxdepth 4 | head -1)"
[ -n "$found" ] || { echo "No converted model found under $work/out" >&2; exit 1; }
mkdir -p "$target"
cp -R "$(dirname "$found")"/. "$target"/
echo "Model is in $target"
echo "Start the app with ios/Tools/run-mac.sh; the layers overlay shows \"2b · Swiss German\"."
