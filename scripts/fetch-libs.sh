#!/bin/sh
# Pulls the embedded libraries into Libs/ for local development, at the same
# pins .pkgmeta gives the packager, so the suite runs against what ships.
# Releases get them from .pkgmeta instead, so Libs/ is not committed.
set -e
cd "$(dirname "$0")/.."

ACE3_TAG="Release-r1403"                                   # wowace tag; the GitHub mirror carries the same tags
LDB_COMMIT="1a63ede0248c11aa1ee415187c1f9c9489ce3e02"
DBICON_TAG="v12.0.3"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

git clone --quiet --depth 1 --branch "$ACE3_TAG" https://github.com/WoWUIDev/Ace3.git "$tmp/Ace3"
git clone --quiet https://github.com/tekkub/libdatabroker-1-1.git "$tmp/LDB"
git -C "$tmp/LDB" checkout --quiet "$LDB_COMMIT"

rm -rf Libs
mkdir -p Libs
for lib in LibStub CallbackHandler-1.0 AceComm-3.0; do
  cp -R "$tmp/Ace3/$lib" "Libs/$lib"
done
cp "$tmp/Ace3/LICENSE.txt" Libs/LICENSE-Ace3.txt
mkdir -p Libs/LibDataBroker-1.1 Libs/LibDBIcon-1.0
cp "$tmp/LDB/LibDataBroker-1.1.lua" Libs/LibDataBroker-1.1/
# LibDBIcon has no git mirror; the wowace Subversion repository serves tags over HTTP.
base="https://repos.wowace.com/wow/libdbicon-1-0/tags/$DBICON_TAG/LibDBIcon-1.0"
curl -sSL -o Libs/LibDBIcon-1.0/LibDBIcon-1.0.lua "$base/LibDBIcon-1.0.lua"
curl -sSL -o Libs/LibDBIcon-1.0/lib.xml "$base/lib.xml"
grep -q "DBICON10_MINOR" Libs/LibDBIcon-1.0/LibDBIcon-1.0.lua || { echo "LibDBIcon download looks wrong" >&2; exit 1; }
echo "fetched: $(ls Libs | tr '\n' ' ')"
echo "Ace3 $ACE3_TAG, LibDataBroker ${LDB_COMMIT%${LDB_COMMIT#???????}}, LibDBIcon $DBICON_TAG"
