#!/bin/sh
# Pulls the embedded libraries into Libs/ for local development. Releases get
# them from .pkgmeta instead, so Libs/ is not committed.
#
# Ace3 and LibDataBroker are mirrored on GitHub; LibDBIcon comes straight from wowace.
set -e
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

git clone --quiet --depth 1 https://github.com/WoWUIDev/Ace3.git "$tmp/Ace3"
git clone --quiet --depth 1 https://github.com/tekkub/libdatabroker-1-1.git "$tmp/LDB"
rm -rf Libs
mkdir -p Libs
for lib in LibStub CallbackHandler-1.0 AceComm-3.0; do
  cp -R "$tmp/Ace3/$lib" "Libs/$lib"
done
cp "$tmp/Ace3/LICENSE.txt" Libs/LICENSE-Ace3.txt
mkdir -p Libs/LibDataBroker-1.1 Libs/LibDBIcon-1.0
cp "$tmp/LDB/LibDataBroker-1.1.lua" Libs/LibDataBroker-1.1/
cp "$tmp/LDB/LICENSE.txt" Libs/LibDataBroker-1.1/ 2>/dev/null || true
# LibDBIcon has no git mirror; the wowace Subversion repository serves files over HTTP.
curl -sSL -o Libs/LibDBIcon-1.0/LibDBIcon-1.0.lua "https://repos.wowace.com/wow/libdbicon-1-0/trunk/LibDBIcon-1.0/LibDBIcon-1.0.lua"
curl -sSL -o Libs/LibDBIcon-1.0/lib.xml "https://repos.wowace.com/wow/libdbicon-1-0/trunk/LibDBIcon-1.0/lib.xml"
grep -q "DBICON10_MINOR" Libs/LibDBIcon-1.0/LibDBIcon-1.0.lua || { echo "LibDBIcon download looks wrong" >&2; exit 1; }
echo "fetched: $(ls Libs | tr '\n' ' ')"
echo "Ace3 commit: $(git -C "$tmp/Ace3" rev-parse --short HEAD)"
