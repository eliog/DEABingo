#!/bin/sh
# Removes the DEABingo symlink that link-beta.sh made, so the CurseForge app
# can install the released build in its place. Removes the link itself, never
# anything through it; refuses if the entry is a real folder (an app install).
# To go back to the checkout: uninstall DEA Bingo in the app, run link-beta.sh,
# and restart the client.
set -e
addons="${WOW_ADDONS:-/Applications/World of Warcraft/_classic_beta_/Interface/AddOns}"
target="$addons/DEABingo"

if [ ! -e "$target" ] && [ ! -L "$target" ]; then
  echo "nothing to do: $target is not there"
  exit 0
fi
if [ ! -L "$target" ]; then
  echo "refusing: $target is a real folder, not a symlink (uninstall it in the CurseForge app)" >&2
  exit 1
fi
rm "$target"
echo "unlinked $target; install DEA Bingo from the CurseForge app, then restart the client"
