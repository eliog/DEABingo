--[[
  SavedVariables access. Everything in the file is treated as untrusted
  input: shaped on load, validated before it is broadcast. Works on any
  table, so tests pass their own.

    hosted[gid]    a host record, written on every mutation
    joined[gid]    what a replica needs to pick a game back up after /reload
    itemSets[hash] every item set seen, as the owner's library
    history[]      finished games, newest last, capped
]]

local _, ns = ...
if type(ns) ~= "table" then ns = {} end
local Logic = ns.Logic or require("Core.Logic")
local Codec = ns.Codec or require("Core.Codec")

local Store = {}
Store.__index = Store
ns.Store = Store

Store.SCHEMA = 1
Store.HISTORY_MAX = 20
Store.ITEM_SETS_MAX = 50

function Store.new(db)
  local self = setmetatable({}, Store)
  self.db = Store.shape(db)
  return self
end

function Store.shape(db)
  if type(db) ~= "table" then db = {} end
  if type(db.schema) ~= "number" then db.schema = 0 end
  for _, key in ipairs({ "options", "itemSets", "history", "hosted", "joined", "seenGames" }) do
    if type(db[key]) ~= "table" then db[key] = {} end
  end
  db.schema = Store.SCHEMA
  return db
end

function Store:saveHosted(record)
  self.db.hosted[record.gid] = record
end

function Store:forgetHosted(gid)
  self.db.hosted[gid] = nil
end

-- Records this character owns and that are still open. `same(owner, me)`
-- decides ownership; it defaults to equality, the client passes a
-- realm- and surname-tolerant comparison.
function Store:openHosted(me, same)
  same = same or function(a, b) return a == b end
  local out = {}
  for gid, r in pairs(self.db.hosted) do
    if type(r) == "table" and type(r.owner) == "string" and same(r.owner, me) and r.state == "open" and Store.isRecord(r) then
      out[#out + 1] = r
    end
  end
  table.sort(out, function(a, b) return a.createdAt < b.createdAt end)
  return out
end

-- A saved record is untrusted input. Every field the host later encodes
-- onto the wire is checked with the same validators the wire uses, so a
-- damaged file cannot make the host throw once a second.
local K = Codec.kinds
local checks = {
  gid = K.gid().check, gen = K.int(1, 9999).check, seq = K.int(0, 2 ^ 31).check,
  state = K.enum({ "drafting", "open", "closed" }).check,
  title = function(v) return type(v) == "string" and Logic.validateTitle(v).ok and Logic.cleanText(v) == v end,
  owner = Codec.isName, audience = K.enum({ "G", "R" }).check,
  createdAt = K.int(0, Codec.TIME_MAX).check, lastActivity = K.int(0, Codec.TIME_MAX).check,
  closedAt = K.optint(0, Codec.TIME_MAX).check, itemsHash = K.hash().check,
}
function Store.isRecord(r)
  if type(r) ~= "table" then return false end
  for field, check in pairs(checks) do
    if not check(r[field]) then return false end
  end
  if type(r.items) ~= "table" or not Logic.checkItems(r.items).ok then return false end
  if type(r.roster) ~= "table" or type(r.calls) ~= "table" then return false end
  local rowCheck, callCheck = K.rosterRow().check, K.callRow().check
  for name, e in pairs(r.roster) do
    if type(e) ~= "table" or not rowCheck({ name = name, board = e.board, canCall = e.canCall, bingoAt = e.bingoAt }) then return false end
  end
  for idx, t in pairs(r.calls) do
    if not callCheck({ idx = idx, t = t }) then return false end
  end
  -- fields the host writes for itself: coerce rather than refuse
  if type(r.lastHeartbeat) ~= "number" then r.lastHeartbeat = 0 end
  r.frozen = r.frozen == true or (r.frozen ~= false and r.frozen ~= nil)
  return true
end

-- A finished game kept for History: only what View.fromHistory reads.
function Store.isHistoryEntry(e)
  if type(e) ~= "table" or type(e.gid) ~= "string" or type(e.title) ~= "string" then return false end
  if type(e.roster) ~= "table" or type(e.calls) ~= "table" then return false end
  for name, p in pairs(e.roster) do
    if type(name) ~= "string" or type(p) ~= "table" or not Logic.isValidBoard(p.board) then return false end
    if p.bingoAt ~= nil and type(p.bingoAt) ~= "number" then return false end
  end
  for idx, t in pairs(e.calls) do
    if type(idx) ~= "number" or idx < 0 or idx >= Logic.ITEM_COUNT or idx ~= math.floor(idx) or type(t) ~= "number" then return false end
  end
  if e.items ~= nil and not (type(e.items) == "table" and #e.items == Logic.ITEM_COUNT) then return false end
  return true
end

-- A frame position from the options table, checked before SetPoint.
local ANCHORS = { TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true }
function Store.isPosition(pos)
  if type(pos) ~= "table" or not ANCHORS[pos.point] then return false end
  if pos.relPoint ~= nil and not ANCHORS[pos.relPoint] then return false end
  if type(pos.x) ~= "number" or type(pos.y) ~= "number" or pos.x ~= pos.x or pos.y ~= pos.y then return false end
  if (pos.w ~= nil or pos.h ~= nil) and not (type(pos.w) == "number" and type(pos.h) == "number" and pos.w >= 100 and pos.h >= 100) then return false end
  return true
end

function Store:saveJoined(gid, game)
  if not game then self.db.joined[gid] = nil; return end
  self.db.joined[gid] = {
    gid = gid, owner = game.owner, gen = game.gen, seq = game.seq, state = game.state,
    title = game.title, itemsHash = game.itemsHash, board = game.myBoard, audience = game.audience,
  }
  if game.items and game.itemsHash then self:saveItemSet(game.itemsHash, game.title, game.items) end
end

function Store:saveItemSet(hash, title, items, usedAt)
  if type(hash) ~= "string" or not Logic.checkItems(items).ok then return end
  local set = self.db.itemSets[hash]
  self.db.itemSets[hash] = { title = title, items = items, usedAt = usedAt or (set and set.usedAt) or 0 }
  -- bounded: drop the least recently used beyond the cap
  local n = 0
  for _ in pairs(self.db.itemSets) do n = n + 1 end
  while n > Store.ITEM_SETS_MAX do
    local oldest, oldestAt
    for h, s in pairs(self.db.itemSets) do
      local at = type(s) == "table" and tonumber(s.usedAt) or 0
      if not oldestAt or at < oldestAt then oldest, oldestAt = h, at end
    end
    self.db.itemSets[oldest] = nil
    n = n - 1
  end
end

function Store:itemSets()
  local out = {}
  for hash, set in pairs(self.db.itemSets) do
    if type(set) == "table" and Logic.checkItems(set.items or {}).ok then
      out[#out + 1] = { hash = hash, title = set.title, items = set.items, usedAt = set.usedAt or 0 }
    end
  end
  table.sort(out, function(a, b) return a.usedAt > b.usedAt end)
  return out
end

-- A finished game, kept readable: title, items, every board, every call,
-- who won and when. Replaces an earlier entry for the same game.
function Store:addHistory(entry)
  if type(entry) ~= "table" or type(entry.gid) ~= "string" then return end
  local h = self.db.history
  for i = #h, 1, -1 do if type(h[i]) == "table" and h[i].gid == entry.gid then table.remove(h, i) end end
  h[#h + 1] = entry
  while #h > Store.HISTORY_MAX do table.remove(h, 1) end
end

function Store:history()
  local out = {}
  for _, e in ipairs(self.db.history) do
    if Store.isHistoryEntry(e) then out[#out + 1] = e end
  end
  table.sort(out, function(a, b) return (a.closedAt or 0) > (b.closedAt or 0) end)
  return out
end

return Store
