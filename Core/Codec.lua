--[[
  Wire format. Pure: no WoW API, no clock, no state.

  One message is one line of fields joined by \31, lists inside a field
  joined by \30. Both are control characters that cleanText strips from every
  piece of player text, so no item, title or name can contain a separator.

    <protocol>\31<type>\31<gid>\31<field>\31<field>...

  Every field is validated against the type's schema on decode. Anything that
  does not fit is dropped as a whole; a sender that cannot speak the protocol
  exactly gets nothing. Numbers must be finite integers in range, names must
  look like Name-Realm, text must already be clean and within its cap.

  Indices are 0-based on the wire (items 0..23), as on the web.
]]

local _, ns = ...
if type(ns) ~= "table" then ns = {} end
local Logic = ns.Logic or require("Core.Logic")

local Codec = {}
ns.Codec = Codec

Codec.PROTOCOL = 1
Codec.FIELD = "\31"
Codec.LIST = "\30"
Codec.MAX_PAYLOAD = 4000    -- reassembled bytes accepted before parsing
Codec.NAME_MAX = 64
Codec.GID_MAX = 24
Codec.HASH_LEN = 6
Codec.TIME_MAX = 2 ^ 40

-------------------------------------------------------------------- kinds

local kinds = {}

local function isInt(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge and n == math.floor(n) end

function kinds.int(min, max)
  return {
    enc = function(v) return tostring(v) end,
    dec = function(s)
      if not s:match("^%-?%d+$") then return nil end
      local n = tonumber(s)
      if not isInt(n) or n < min or n > max then return nil end
      return n
    end,
    check = function(v) return isInt(v) and v >= min and v <= max end,
  }
end

-- An int that may be absent (nil <-> empty field).
function kinds.optint(min, max)
  local inner = kinds.int(min, max)
  return {
    enc = function(v) if v == nil then return "" end return inner.enc(v) end,
    dec = function(s) if s == "" then return nil, true end return inner.dec(s) end,
    check = function(v) return v == nil or inner.check(v) end,
    optional = true,
  }
end

function kinds.flag()
  return {
    enc = function(v) return v and "1" or "0" end,
    dec = function(s) if s == "1" then return true elseif s == "0" then return false end return nil end,
    check = function(v) return type(v) == "boolean" end,
  }
end

-- Player text: must already be clean (cleanText is a fixed point) and short.
function kinds.text(max, allowEmpty)
  return {
    enc = function(v) return v end,
    dec = function(s)
      if s == "" then if allowEmpty then return "" end return nil end
      if Logic.cleanText(s) ~= s then return nil end
      if Logic.utf8len(s) > max then return nil end
      return s
    end,
    check = function(v) return type(v) == "string" and (allowEmpty or v ~= "") and Logic.cleanText(v) == v and Logic.utf8len(v) <= max end,
  }
end

-- A player identity: "Name" or "Name-Realm". Forever allows two-word names
-- ("Dea One"), so the name part may hold single spaces. On Forever's
-- realmless rulesets names are unique region-wide and carry no realm; on
-- classic realms the client appends the normalised realm before anything
-- reaches the wire, so both shapes are legal here.
local function isName(s)
  if type(s) ~= "string" or s == "" or #s > Codec.NAME_MAX then return false end
  local name, realm = s:match("^(.-)%-([^%s%c|%-]+)$")
  if not name then name = s end
  if name == "" or name:find("[%c|%-\30\31]") then return false end
  if name:find("^ ") or name:find(" $") or name:find("  ") then return false end
  return true
end
Codec.isName = isName

function kinds.name()
  return {
    enc = function(v) return v end,
    dec = function(s) if isName(s) then return s end return nil end,
    check = isName,
  }
end

function kinds.optname()
  local inner = kinds.name()
  return {
    enc = function(v) return v or "" end,
    dec = function(s) if s == "" then return nil, true end return inner.dec(s) end,
    check = function(v) return v == nil or isName(v) end,
    optional = true,
  }
end

function kinds.board()
  return {
    enc = function(v) return Logic.encodeBoard(v) end,
    dec = function(s) return Logic.decodeBoard(s) end,
    check = function(v) return Logic.isValidBoard(v) end,
  }
end

function kinds.gid()
  return {
    enc = function(v) return v end,
    dec = function(s) if s:match("^[%w%-]+$") and #s <= Codec.GID_MAX then return s end return nil end,
    check = function(v) return type(v) == "string" and v:match("^[%w%-]+$") ~= nil and #v <= Codec.GID_MAX end,
  }
end

function kinds.hash()
  return {
    enc = function(v) return v end,
    dec = function(s) if #s == Codec.HASH_LEN and s:match("^%w+$") then return s end return nil end,
    check = function(v) return type(v) == "string" and #v == Codec.HASH_LEN and v:match("^%w+$") ~= nil end,
  }
end

function kinds.enum(values)
  local set = {}
  for _, v in ipairs(values) do set[v] = true end
  return {
    enc = function(v) return v end,
    dec = function(s) if set[s] then return s end return nil end,
    check = function(v) return set[v] == true end,
  }
end

-- A list of another kind, exact count or up to max.
function kinds.list(item, max, exact)
  return {
    enc = function(v)
      local out = {}
      for i = 1, #v do out[i] = item.enc(v[i]) end
      return table.concat(out, Codec.LIST)
    end,
    dec = function(s)
      local out = {}
      if s ~= "" then
        local start = 1
        while true do
          local i = s:find(Codec.LIST, start, true)
          local part = i and s:sub(start, i - 1) or s:sub(start)
          local v = item.dec(part)
          if v == nil then return nil end
          out[#out + 1] = v
          if #out > max then return nil end
          if not i then break end
          start = i + 1
        end
      end
      if exact and #out ~= max then return nil end
      return out
    end,
    check = function(v)
      if type(v) ~= "table" or #v > max or (exact and #v ~= max) then return false end
      for i = 1, #v do if not item.check(v[i]) then return false end end
      return true
    end,
  }
end

-- "name:board24:canCall:bingoAt" roster rows inside a snapshot.
function kinds.rosterRow()
  local name, board, flag, optint = kinds.name(), kinds.board(), kinds.flag(), kinds.optint(0, Codec.TIME_MAX)
  return {
    enc = function(v) return table.concat({ v.name, Logic.encodeBoard(v.board), v.canCall and "1" or "0", v.bingoAt and tostring(v.bingoAt) or "" }, ":") end,
    dec = function(s)
      local n, b, c, t = s:match("^([^:]+):([^:]+):([^:]+):([^:]*)$")
      if not n then return nil end
      local rn, rb, rc = name.dec(n), board.dec(b), flag.dec(c)
      local rt, isNil = optint.dec(t)
      if rn == nil or rb == nil or rc == nil or (rt == nil and not isNil) then return nil end
      return { name = rn, board = rb, canCall = rc, bingoAt = rt }
    end,
    check = function(v)
      return type(v) == "table" and name.check(v.name) and board.check(v.board) and flag.check(v.canCall) and optint.check(v.bingoAt)
    end,
  }
end

-- "idx:t" call rows inside a snapshot.
function kinds.callRow()
  local idx, t = kinds.int(0, Logic.ITEM_COUNT - 1), kinds.int(0, Codec.TIME_MAX)
  return {
    enc = function(v) return v.idx .. ":" .. v.t end,
    dec = function(s)
      local a, b = s:match("^(%d+):(%d+)$")
      if not a then return nil end
      local ri, rt = idx.dec(a), t.dec(b)
      if ri == nil or rt == nil then return nil end
      return { idx = ri, t = rt }
    end,
    check = function(v) return type(v) == "table" and idx.check(v.idx) and t.check(v.t) end,
  }
end

------------------------------------------------------------------- schemas

local T, N = Codec.TIME_MAX, Logic.ITEM_COUNT
local SEQ = kinds.int(0, 2 ^ 31)
local IDX = kinds.int(0, N - 1)
local TIME = kinds.int(0, T)
local OPTTIME = kinds.optint(0, T)
local NAMES = kinds.list(kinds.name(), 60)

-- type -> ordered list of {field, kind}
Codec.SCHEMA = {
  -- discovery
  HI = { { "ver", kinds.int(1, 999) }, { "nonce", kinds.int(0, 2 ^ 31) } },
  GA = { { "gen", kinds.int(1, 9999) }, { "seq", SEQ }, { "state", kinds.enum({ "open", "closed" }) },
         { "title", kinds.text(Logic.TITLE_MAX) }, { "owner", kinds.name() }, { "players", kinds.int(0, 999) },
         { "callMask", kinds.int(0, 2 ^ N - 1) }, { "lastActivity", TIME }, { "itemsHash", kinds.hash() },
         { "createdAt", TIME }, { "audience", kinds.enum({ "G", "R" }) } },
  -- joining
  JN = { { "ver", kinds.int(1, 999) } },
  WE = { { "seq", SEQ }, { "board", kinds.board() }, { "canCall", kinds.flag() }, { "createdAt", TIME },
         { "bingoAt", OPTTIME }, { "itemsHash", kinds.hash() }, { "gen", kinds.int(1, 9999) } },
  JD = { { "seq", SEQ }, { "name", kinds.name() }, { "board", kinds.board() }, { "canCall", kinds.flag() }, { "bingoAt", OPTTIME } },
  IT = { { "itemsHash", kinds.hash() }, { "title", kinds.text(Logic.TITLE_MAX) }, { "items", kinds.list(kinds.text(Logic.ITEM_MAX), N, true) } },
  IQ = { { "itemsHash", kinds.hash() } },
  -- play
  CQ = { { "idx", IDX }, { "undo", kinds.flag() }, { "nonce", kinds.int(0, 2 ^ 31) } },
  CL = { { "seq", SEQ }, { "idx", IDX }, { "t", TIME }, { "winners", NAMES } },
  UN = { { "seq", SEQ }, { "idx", IDX }, { "t", TIME }, { "revoked", NAMES } },
  GR = { { "seq", SEQ }, { "name", kinds.name() }, { "canCall", kinds.flag() } },
  TI = { { "seq", SEQ }, { "title", kinds.text(Logic.TITLE_MAX) } },
  CX = { { "seq", SEQ }, { "closedAt", TIME } },
  TR = { { "seq", SEQ }, { "gen", kinds.int(1, 9999) }, { "newHost", kinds.name() } },
  -- sync
  SQ = { { "haveSeq", SEQ } },
  SN = { { "gen", kinds.int(1, 9999) }, { "seq", SEQ }, { "state", kinds.enum({ "open", "closed" }) },
         { "title", kinds.text(Logic.TITLE_MAX) }, { "owner", kinds.name() }, { "createdAt", TIME },
         { "lastActivity", TIME }, { "closedAt", OPTTIME }, { "itemsHash", kinds.hash() }, { "audience", kinds.enum({ "G", "R" }) },
         { "roster", kinds.list(kinds.rosterRow(), 200) }, { "calls", kinds.list(kinds.callRow(), N) } },
  -- a client that saw a newer protocol says so once
  NV = { { "ver", kinds.int(1, 999) } },
}

------------------------------------------------------------------ encode

-- Returns the wire string, or nil and a reason when a field fails its check.
function Codec.encode(msgType, gid, fields)
  local schema = Codec.SCHEMA[msgType]
  if not schema then return nil, "unknown type " .. tostring(msgType) end
  if not kinds.gid().check(gid) then return nil, "bad gid" end
  local parts = { tostring(Codec.PROTOCOL), msgType, gid }
  for _, def in ipairs(schema) do
    local name, kind = def[1], def[2]
    local v = fields[name]
    if not kind.check(v) then return nil, "bad field " .. name end
    parts[#parts + 1] = kind.enc(v)
  end
  local s = table.concat(parts, Codec.FIELD)
  if #s > Codec.MAX_PAYLOAD then return nil, "too long" end
  return s
end

local function split(s, sep)
  local out, start = {}, 1
  while true do
    local i = s:find(sep, start, true)
    if not i then out[#out + 1] = s:sub(start); return out end
    out[#out + 1] = s:sub(start, i - 1)
    start = i + 1
  end
end

-- Returns { v, type, gid, f = {field = value} } or nil and a reason.
-- `v` is the sender's protocol; a newer one is reported, not parsed.
function Codec.decode(s)
  if type(s) ~= "string" then return nil, "not a string" end
  if #s > Codec.MAX_PAYLOAD then return nil, "too long" end
  local parts = split(s, Codec.FIELD)
  if #parts < 3 then return nil, "too short" end
  local ver = tonumber(parts[1])
  if not isInt(ver) or ver < 1 then return nil, "bad protocol" end
  local msgType, gid = parts[2], parts[3]
  if not kinds.gid().check(gid) then return nil, "bad gid" end
  if ver > Codec.PROTOCOL then return nil, "newer", { v = ver, type = msgType, gid = gid } end
  local schema = Codec.SCHEMA[msgType]
  if not schema then return nil, "unknown type" end
  if #parts ~= #schema + 3 then return nil, "field count" end
  local f = {}
  for i, def in ipairs(schema) do
    local name, kind = def[1], def[2]
    local v, isNil = kind.dec(parts[i + 3])
    if v == nil and not isNil then return nil, "bad field " .. name end
    f[name] = v
  end
  return { v = ver, type = msgType, gid = gid, f = f }
end

------------------------------------------------------------------- helpers

-- 24-bit mask of called items, so a heartbeat can carry the whole call set.
function Codec.callMask(calls)
  local mask = 0
  for idx in pairs(calls) do
    if isInt(idx) and idx >= 0 and idx < N then mask = mask + 2 ^ idx end
  end
  return mask
end

function Codec.maskHas(mask, idx)
  return math.floor(mask / 2 ^ idx) % 2 == 1
end

-- A short, stable hash of title + items. djb2 over the bytes, base36, 6 chars.
-- Only used to tell one item set from another, never for security.
function Codec.itemsHash(title, items)
  local h = 5381
  local function feed(str)
    for i = 1, #str do h = (h * 33 + str:byte(i)) % 2147483647 end
    h = (h * 33 + 31) % 2147483647
  end
  feed(title or "")
  for i = 1, #items do feed(items[i]) end
  local digits, out = "0123456789abcdefghijklmnopqrstuvwxyz", {}
  for _ = 1, Codec.HASH_LEN do
    local d = h % 36
    out[#out + 1] = digits:sub(d + 1, d + 1)
    h = math.floor(h / 36)
  end
  return table.concat(out)
end

Codec.kinds = kinds
return Codec
