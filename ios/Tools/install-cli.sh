#!/bin/sh
# Install only the launcher; keep existing unrelated commands intact.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
bin_dir="$HOME/.local/bin"
mkdir -p "$bin_dir"
target="$bin_dir/listen"
if [ -e "$target" ] || [ -L "$target" ]; then
  if [ "$(readlink "$target" 2>/dev/null || true)" != "$root/bin/listen" ]; then
    echo "A different command already exists at $target. It was preserved." >&2
    exit 1
  fi
else
  ln -s "$root/bin/listen" "$target"
fi
printf 'Installed %s\n' "$target"
case ":$PATH:" in *":$bin_dir:"*) ;; *) printf 'Add %s to your PATH to use listen by name.\n' "$bin_dir" ;; esac
