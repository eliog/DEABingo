#!/bin/sh
# Runs the busted suite under LuaJIT (Lua 5.1 semantics, like the WoW client).
#
#   brew install luajit luarocks
#   luarocks --lua-version=5.1 --lua-dir=/opt/homebrew/opt/luajit install busted
set -e
cd "$(dirname "$0")/.."
eval "$(luarocks --lua-version=5.1 path)"
# busted's launcher script, run under luajit explicitly (its shebang may pick another Lua)
BUSTED="$(luarocks --lua-version=5.1 which busted 2>/dev/null | head -1)"
[ -f "$BUSTED" ] || BUSTED="$(ls "$HOME"/.luarocks/lib/luarocks/rocks-5.1/busted/*/bin/busted 2>/dev/null | head -1)"
if [ -z "$BUSTED" ]; then
  echo "busted is not installed; see the comment at the top of $0" >&2
  exit 1
fi
luajit "$BUSTED" "$@"
# Then the headless client smoke, which executes the UI code against a fake widget API.
out="$(luajit tests/client_smoke.lua 2>&1)" || { echo "$out" | tail -8; echo "client smoke FAILED"; exit 1; }
echo "$out" | tail -1
