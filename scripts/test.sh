#!/bin/sh
# Runs the busted suite under LuaJIT (Lua 5.1 semantics, like the WoW client).
#
#   brew install luajit luarocks
#   luarocks --lua-version=5.1 --lua-dir=/opt/homebrew/opt/luajit install busted
set -e
cd "$(dirname "$0")/.."
eval "$(luarocks --lua-version=5.1 path)"
BUSTED="$(ls "$HOME"/.luarocks/lib/luarocks/rocks-5.1/busted/*/bin/busted 2>/dev/null | head -1)"
if [ -z "$BUSTED" ]; then
  echo "busted is not installed; see the comment at the top of $0" >&2
  exit 1
fi
exec luajit "$BUSTED" "$@"
