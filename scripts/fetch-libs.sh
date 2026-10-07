#!/bin/sh
# Pulls the embedded libraries into Libs/ for local development. Releases get
# them from .pkgmeta instead, so Libs/ is not committed.
#
# Ace3 is mirrored on GitHub from the canonical wowace Subversion repository.
set -e
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

git clone --quiet --depth 1 https://github.com/WoWUIDev/Ace3.git "$tmp/Ace3"
rm -rf Libs
mkdir -p Libs
for lib in LibStub CallbackHandler-1.0 AceComm-3.0; do
  cp -R "$tmp/Ace3/$lib" "Libs/$lib"
done
cp "$tmp/Ace3/LICENSE.txt" Libs/LICENSE-Ace3.txt
echo "fetched: $(ls Libs | tr '\n' ' ')"
echo "Ace3 commit: $(git -C "$tmp/Ace3" rev-parse --short HEAD)"
