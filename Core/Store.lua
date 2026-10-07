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

local Store = {}
Store.__index = Store
ns.Store = Store

Store.SCHEMA = 1
Store.HISTORY_MAX = 20

function Store.new(db)
  local self = setmetatable({}, Store)
  self.db = Store.shape(db)
  return self
end

function Store.shape(db)
  if type(db) ~= "table" then db = {} end
  if type(db.schema) ~= "number" then db.schema = 0 end
  for _, key in ipairs({ "options", "itemSets", "history", "hosted", "joined" }) do
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

-- Records this character owns and that are still open.
function Store:openHosted(me)
  local out = {}
  for gid, r in pairs(self.db.hosted) do
    if type(r) == "table" and r.owner == me and r.state == "open" and Store.isRecord(r) then out[#out + 1] = r end
  end
  table.sort(out, function(a, b) return a.createdAt < b.createdAt end)
  return out
end

-- Enough of a record to trust it: the fields the host reads before persisting again.
function Store.isRecord(r)
  if type(r) ~= "table" or type(r.gid) ~= "string" or type(r.seq) ~= "number" or type(r.gen) ~= "number" then return false end
  if type(r.title) ~= "string" or type(r.items) ~= "table" or not Logic.checkItems(r.items).ok then return false end
  if type(r.roster) ~= "table" or type(r.calls) ~= "table" then return false end
  for name, e in pairs(r.roster) do
    if type(name) ~= "string" or type(e) ~= "table" or not Logic.isValidBoard(e.board) then return false end
  end
  for idx, t in pairs(r.calls) do
    if type(idx) ~= "number" or idx < 0 or idx >= Logic.ITEM_COUNT or type(t) ~= "number" then return false end
  end
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

function Store:saveItemSet(hash, title, items)
  if type(hash) ~= "string" or not Logic.checkItems(items).ok then return end
  local set = self.db.itemSets[hash]
  self.db.itemSets[hash] = { title = title, items = items, usedAt = (set and set.usedAt) or 0 }
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
    if type(e) == "table" and type(e.gid) == "string" and type(e.roster) == "table" and type(e.calls) == "table" then out[#out + 1] = e end
  end
  table.sort(out, function(a, b) return (a.closedAt or 0) > (b.closedAt or 0) end)
  return out
end

return Store
