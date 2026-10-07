--[[
  The view model: one plain table describing a game for the UI, built the
  same way from a Host record (the owner's client) or a Mirror game (everyone
  else). Pure, so the shape is tested without a client.
]]

local _, ns = ...
if type(ns) ~= "table" then ns = {} end
local Logic = ns.Logic or require("Core.Logic")

local View = {}
ns.View = View

-- "Dea One-ClassicBetaPvE2" -> "Dea One". Display only; never for keys.
function View.shortName(name)
  if type(name) ~= "string" then return "" end
  return (name:gsub("%-[^%-]+$", ""))
end

local function sortStandings(rows)
  table.sort(rows, function(a, b)
    if (a.bingoAt == nil) ~= (b.bingoAt == nil) then return a.bingoAt ~= nil end
    if a.bingoAt and b.bingoAt and a.bingoAt ~= b.bingoAt then return a.bingoAt < b.bingoAt end
    if a.bestLine ~= b.bestLine then return a.bestLine > b.bestLine end
    return a.name < b.name
  end)
  local rank = 0
  for _, r in ipairs(rows) do
    if r.bingoAt then rank = rank + 1; r.rank = rank end
  end
  return rows
end

-- Shared assembly once the per-source fields are known.
local function build(v, roster, calls, items, me)
  local called = {}
  local callList = {}
  for idx, t in pairs(calls) do
    called[idx] = true
    callList[#callList + 1] = { idx = idx, t = t, text = items and items[idx + 1] or nil }
  end
  table.sort(callList, function(a, b) if a.t ~= b.t then return a.t > b.t end return a.idx > b.idx end)
  v.called = called
  v.calls = callList
  v.callCount = #callList
  v.items = items
  v.itemsKnown = items ~= nil

  local rows = {}
  local players = 0
  for name, e in pairs(roster) do
    players = players + 1
    rows[#rows + 1] = {
      name = name, shortName = View.shortName(name), bestLine = Logic.bestLineOf(e.board, called),
      bingoAt = e.bingoAt, canCall = e.canCall or name == v.owner, isMe = name == me,
    }
  end
  v.standings = sortStandings(rows)
  v.players = players

  local mine = roster[me]
  if mine then
    v.board = mine.board
    v.bestLine = Logic.bestLineOf(mine.board, called)
    v.hasBingo = Logic.hasBingo(mine.board, called)
    v.winning = Logic.winningCells(mine.board, called)
    v.myBingoAt = mine.bingoAt
    v.canCall = (v.isHost or mine.canCall == true) and v.state == "open"
  else
    v.board = nil
    v.bestLine = 0
    v.hasBingo = false
    v.winning = {}
    v.myBingoAt = nil
    v.canCall = v.isHost and v.state == "open"
  end
  v.away = v.bestLine >= 5 and 0 or (5 - v.bestLine)
  return v
end

function View.fromHost(record, me)
  local v = {
    gid = record.gid, title = record.title, state = record.state, owner = record.owner,
    ownerShort = View.shortName(record.owner), isHost = true, hostAway = false,
    audience = record.audience, createdAt = record.createdAt, closedAt = record.closedAt,
    frozen = record.frozen == true,
  }
  return build(v, record.roster, record.calls, record.items, me)
end

function View.fromMirror(game, me, card)
  local v = {
    pending = game.outstanding or {},
    gid = game.gid, title = game.title, state = game.state, owner = game.owner,
    ownerShort = View.shortName(game.owner), isHost = false,
    hostAway = card ~= nil and card.away == true,
    audience = game.audience, createdAt = game.createdAt, closedAt = game.closedAt,
    frozen = true,
  }
  return build(v, game.roster, game.calls, game.items, me)
end

-- A finished game from the history store. Read-only: nobody can call.
function View.fromHistory(entry, me)
  local v = {
    gid = entry.gid, title = entry.title or "", state = "closed", owner = entry.owner or "",
    ownerShort = View.shortName(entry.owner), isHost = false, hostAway = false,
    audience = entry.audience, createdAt = entry.createdAt, closedAt = entry.closedAt, frozen = true, history = true,
  }
  local v2 = build(v, entry.roster or {}, entry.calls or {}, entry.items, me)
  v2.canCall = false
  return v2
end

-- Lobby rows from mirror cards plus games this client hosts.
function View.lobby(cards, hosted, me)
  local out = {}
  for gid, card in pairs(cards) do
    if card.state == "open" and card.host ~= me then
      out[#out + 1] = {
        gid = gid, title = card.title, owner = card.host, ownerShort = View.shortName(card.host),
        players = card.players or 0, calls = card.callCount or 0, hostAway = card.away == true,
        mine = false, audience = card.audience,
      }
    end
  end
  for gid, record in pairs(hosted) do
    if record.state ~= "closed" then
      local n = 0 for _ in pairs(record.roster) do n = n + 1 end
      local c = 0 for _ in pairs(record.calls) do c = c + 1 end
      out[#out + 1] = {
        gid = gid, title = record.title, owner = record.owner, ownerShort = View.shortName(record.owner),
        players = n, calls = c, hostAway = false, mine = true, audience = record.audience, state = record.state,
      }
    end
  end
  table.sort(out, function(a, b)
    if a.mine ~= b.mine then return a.mine end
    if a.title ~= b.title then return a.title < b.title end
    return a.owner < b.owner
  end)
  return out
end

return View
