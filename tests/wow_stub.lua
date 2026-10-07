-- The slice of the WoW API the pure modules touch, for running under busted.
-- Grows with the modules under test; never a full client emulation.

local stub = {}

function stub.install()
  _G.strlenutf8 = _G.strlenutf8 or function(s)
    local _, n = s:gsub("[^\128-\191]", "")
    return n
  end
  _G.unpack = _G.unpack or table.unpack
end

-- A deterministic rng that replays a recorded sequence of draws, so the Lua
-- shuffle can be checked against the TypeScript one draw for draw.
function stub.replayRng(draws)
  local i = 0
  return {
    int = function(_, n)
      i = i + 1
      local v = draws[i]
      assert(v ~= nil, "rng asked for more draws than were recorded")
      assert(v >= 0 and v < n, ("recorded draw %d out of range for int(%d)"):format(v, n))
      return v
    end,
    used = function() return i end,
  }
end

return stub
