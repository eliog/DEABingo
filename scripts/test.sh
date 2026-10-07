#!/bin/sh
# Runs the busted suite under LuaJIT (Lua 5.1 semantics, like the WoW client),
# then the headless client smoke, which executes the UI code against a fake
# widget API.
#
#   brew install luajit luarocks
#   luarocks --lua-version=5.1 --lua-dir=/opt/homebrew/opt/luajit install busted
set -e
cd "$(dirname "$0")/.."
eval "$(luarocks --lua-version=5.1 path)"
# busted's launcher script from the rocks tree, run under luajit explicitly
# (its own shebang may pick another Lua; `luarocks which` names the module, not the launcher)
ROCKS="$(luarocks --lua-version=5.1 config rocks_dir 2>/dev/null)"
BUSTED="$(ls "$ROCKS"/busted/*/bin/busted 2>/dev/null | head -1)"
[ -f "$BUSTED" ] || BUSTED="$(ls "$HOME"/.luarocks/lib/luarocks/rocks-5.1/busted/*/bin/busted 2>/dev/null | head -1)"
if [ ! -f "$BUSTED" ]; then
  echo "busted is not installed; see the comment at the top of $0" >&2
  exit 1
fi
summary="$(luajit "$BUSTED" "$@" 2>&1)" || { echo "$summary" | tail -40; exit 1; }
echo "$summary" | tail -1
# a run that reports no results at all is a broken runner, not a pass
echo "$summary" | grep -q "successes" || { echo "busted produced no summary; is the launcher right?" >&2; exit 1; }
out="$(luajit tests/client_smoke.lua 2>&1)" || { echo "$out" | tail -8; echo "client smoke FAILED"; exit 1; }
echo "$out" | tail -1
