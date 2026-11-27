#!/bin/sh
# Runs every scripted conversation through the real app, one after the other, and
# measures each run: speed, how blocks were formed, and what the script expects.
# Usage: ios/Tools/scripted/eval.sh [script.txt ...]   (all scripts in this folder when none is named)
# Takes the length of each conversation plus about a minute; uses the connected models.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
[ $# -gt 0 ] || set -- "$here"/*.txt
failed=0
for script in "$@"; do
  echo "== $(basename "$script")"
  run="$("$here/run.sh" "$script" | tail -1)"
  if [ -d "$run" ]; then
    python3 -I "$here/measure.py" "$run" "$script" || failed=$((failed + 1))
  else
    echo "  no run was written"; failed=$((failed + 1))
  fi
done
echo "== $failed of $# conversations did not meet what their script expects"
[ "$failed" = 0 ]
