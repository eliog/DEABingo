#!/bin/sh
# Symlinks this repository into the WoW: Forever beta client as the DEABingo
# addon. The client sees the symlink's name, which must match DEABingo.toc.
# Restart the client the first time; /reload is enough afterwards.
set -e
repo="$(cd "$(dirname "$0")/.." && pwd)"
addons="${WOW_ADDONS:-/Applications/World of Warcraft/_classic_beta_/Interface/AddOns}"
target="$addons/DEABingo"

if [ ! -d "$addons" ]; then
  echo "AddOns folder not found: $addons (set WOW_ADDONS to override)" >&2
  exit 1
fi
if [ -e "$target" ] && [ ! -L "$target" ]; then
  echo "refusing: $target exists and is not a symlink" >&2
  exit 1
fi
ln -sfn "$repo" "$target"
echo "linked $target -> $repo"
