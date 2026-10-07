--[[
  The host: the owner's client, the only writer of a game's state. Everyone
  else mirrors what the host broadcasts.

  Pure apart from its dependencies, which are injected so the whole protocol
  runs under busted with a fake clock and a loopback transport:

    deps.now()                        server time, seconds
    deps.rng                          rng:int(n) -> [0, n)
    deps.me                           "Name-Realm" of this client
    deps.send(payload, channel, target)   channel "GUILD" | "GROUP" | "WHISPER"
    deps.persist(record)              write the record to SavedVariables
    deps.isMember(name, audience)     may this player join? "G": in my guild, "R": in my group
    deps.onEvent(kind, info)          optional: "call" {gid, idx, winners}, "undo" {gid, idx, revoked}, "join" {gid, name}
    deps.log(text)                    optional

  The record is plain data and is persisted after every mutation, so a host
  that reloads resumes exactly where it was.
]]

local _, ns = ...
if type(ns) ~= "table" then ns = {} end
local Logic = ns.Logic or require("Core.Logic")
local Codec = ns.Codec or require("Core.Codec")

local Host = {}
Host.__index = Host
ns.Host = Host

Host.HEARTBEAT = 30            -- seconds between GA cards
Host.IDLE_CLOSE = 8 * 3600     -- idle seconds before a game closes itself
Host.SYNC_DELAY = 2            -- collect SQ requests this long, then answer once
Host.SYNC_COOLDOWN = 3         -- per requester; a missed call must not wait long

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
local function base36(n)
  if n == 0 then return "0" end
  local out = {}
  while n > 0 do
    local d = n % 36
    table.insert(out, 1, DIGITS:sub(d + 1, d + 1))
    n = math.floor(n / 36)
  end
  return table.concat(out)
end

local function calledSet(record)
  local set = {}
  for idx in pairs(record.calls) do set[idx] = true end
  return set
end

local function rosterCount(record)
  local n = 0
  for _ in pairs(record.roster) do n = n + 1 end
  return n
end

local function sortedNames(set)
  local out = {}
  for name in pairs(set) do out[#out + 1] = name end
  table.sort(out)
  return out
end

function Host.new(deps)
  local self = setmetatable({}, Host)
  self.deps = deps
  self.record = nil
  self.syncRequests = {}     -- name -> requested at
  self.syncDue = nil         -- when to answer the collected requests
  self.lastSyncTo = {}       -- name -> last answered at
  return self
end

function Host.restore(record, deps)
  local self = Host.new(deps)
  self.record = record
  return self
end

function Host:log(text)
  if self.deps.log then self.deps.log(text) end
end

function Host:channel()
  return self.record.audience == "G" and "GUILD" or "GROUP"
end

function Host:persist()
  if self.deps.persist then self.deps.persist(self.record) end
end

-- Build and send; a failed encode is a programming error, so it is loud.
function Host:emit(msgType, fields, channel, target)
  local payload, err = Codec.encode(msgType, self.record.gid, fields)
  assert(payload, err)
  self.deps.send(payload, channel or self:channel(), target)
end

function Host:bump()
  local r = self.record
  r.seq = r.seq + 1
  return r.seq
end

------------------------------------------------------------------ lifecycle

-- opts: title, items (24 clean strings), audience "G" | "R"
-- Returns the record, or nil and a reason.
function Host:create(opts)
  local title = Logic.validateTitle(opts.title or "")
  if not title.ok then return nil, title.reason end
  local check = Logic.checkItems(opts.items or {})
  if not check.ok then return nil, "items are not valid" end
  local now = self.deps.now()
  local gid = base36(now) .. DIGITS:sub(self.deps.rng:int(36) + 1):sub(1, 1) .. DIGITS:sub(self.deps.rng:int(36) + 1):sub(1, 1)
  self.record = {
    gid = gid, gen = 1, seq = 0, state = "drafting",
    title = title.value, items = check.items, itemsHash = Codec.itemsHash(title.value, check.items),
    owner = self.deps.me, audience = opts.audience == "R" and "R" or "G",
    createdAt = now, lastActivity = now, closedAt = nil, lastHeartbeat = 0,
    frozen = false, roster = {}, calls = {},
  }
  self:persist()
  return self.record
end

function Host:setItems(items)
  local r = self.record
  if r.state ~= "drafting" and r.frozen then return nil, "items are frozen" end
  local check = Logic.checkItems(items)
  if not check.ok then return nil, "items are not valid" end
  r.items = check.items
  r.itemsHash = Codec.itemsHash(r.title, r.items)
  self:persist()
  if r.state == "open" then self:emit("IT", { itemsHash = r.itemsHash, title = r.title, items = r.items }) end
  return true
end

function Host:setTitle(title)
  local r = self.record
  local t = Logic.validateTitle(title)
  if not t.ok then return nil, t.reason end
  r.title = t.value
  r.itemsHash = Codec.itemsHash(r.title, r.items)
  self:persist()
  if r.state == "open" then
    self:emit("TI", { seq = self:bump(), title = r.title })
    self:emit("IT", { itemsHash = r.itemsHash, title = r.title, items = r.items })
    self:persist()
  end
  return true
end

-- Deal the owner a board and announce. The owner joins through the same gate
-- as everyone else, which is why their join does not freeze the items.
function Host:open()
  local r = self.record
  if r.state ~= "drafting" then return nil, "already open" end
  r.state = "open"
  r.lastActivity = self.deps.now()
  self:addPlayer(self.deps.me, true)
  self:emit("IT", { itemsHash = r.itemsHash, title = r.title, items = r.items })
  self:heartbeat()
  self:persist()
  return true
end

function Host:close()
  local r = self.record
  if r.state == "closed" then return nil, "already closed" end
  local now = self.deps.now()
  r.state = "closed"
  r.closedAt = now
  if r.state ~= "drafting" then
    self:emit("CX", { seq = self:bump(), closedAt = now })
  end
  self:persist()
  if self.deps.onEvent then self.deps.onEvent("close", { gid = r.gid }) end
  return true
end

function Host:card()
  local r = self.record
  return {
    gen = r.gen, seq = r.seq, state = r.state == "closed" and "closed" or "open",
    title = r.title, owner = r.owner, players = rosterCount(r),
    callMask = Codec.callMask(r.calls), lastActivity = r.lastActivity,
    itemsHash = r.itemsHash, createdAt = r.createdAt, audience = r.audience,
  }
end

function Host:heartbeat(target)
  if self.record.state == "drafting" then return end
  self:emit("GA", self:card(), target and "WHISPER" or nil, target)
  if not target then self.record.lastHeartbeat = self.deps.now() end
end

------------------------------------------------------------------- players

-- Returns the roster entry and whether the player was new.
function Host:addPlayer(name, silent)
  local r = self.record
  local entry = r.roster[name]
  if entry then return entry, false end
  if name ~= r.owner and not r.frozen then r.frozen = true end
  local taken = {}
  for _, e in pairs(r.roster) do taken[#taken + 1] = e.board end
  entry = { board = Logic.dealUniqueBoard(self.deps.rng, taken), canCall = false, bingoAt = nil, joinedAt = self.deps.now() }
  r.roster[name] = entry
  -- A late joiner inherits every call already made, which can be an instant bingo.
  if Logic.hasBingo(entry.board, calledSet(r)) then entry.bingoAt = self.deps.now() end
  self:bump()
  if not silent then
    self:emit("JD", { seq = r.seq, name = name, board = entry.board, canCall = entry.canCall, bingoAt = entry.bingoAt })
  end
  self:persist()
  if self.deps.onEvent then self.deps.onEvent("join", { gid = r.gid, name = name }) end
  return entry, true
end

function Host:canCall(name)
  local r = self.record
  if name == r.owner then return true end
  local e = r.roster[name]
  return e ~= nil and e.canCall == true
end

function Host:grant(name, allowed)
  local r = self.record
  if name == r.owner then return nil, "the owner can always call" end
  local e = r.roster[name]
  if not e then return nil, "not in this game" end
  if e.canCall == allowed then return true end
  e.canCall = allowed
  self:emit("GR", { seq = self:bump(), name = name, canCall = allowed })
  self:persist()
  return true
end

-- Hand the game to another player. This client stops being the writer; the
-- caller converts the record into a mirror. gen rises so a stale host that
-- comes back later knows it has been superseded.
function Host:transfer(name)
  local r = self.record
  if not r.roster[name] or name == r.owner then return nil, "not in this game" end
  r.gen = r.gen + 1
  r.owner = name
  self:emit("TR", { seq = self:bump(), gen = r.gen, newHost = name })
  self:persist()
  return true
end

---------------------------------------------------------------------- play

-- Bring every player's bingo into line with the calls that stand. Returns the
-- names that just won and the names whose bingo was taken back.
function Host:reconcile(now)
  local r = self.record
  local called = calledSet(r)
  local winners, revoked = {}, {}
  for name, e in pairs(r.roster) do
    local won = Logic.hasBingo(e.board, called)
    if won and e.bingoAt == nil then
      e.bingoAt = now
      winners[#winners + 1] = name
    elseif not won and e.bingoAt ~= nil then
      e.bingoAt = nil
      revoked[#revoked + 1] = name
    end
  end
  table.sort(winners)
  table.sort(revoked)
  return winners, revoked
end

function Host:call(idx)
  local r = self.record
  if r.state ~= "open" then return nil, "game is not open" end
  if type(idx) ~= "number" or idx < 0 or idx >= Logic.ITEM_COUNT or idx ~= math.floor(idx) then return nil, "bad square" end
  if r.calls[idx] then return nil, "already called" end
  local now = self.deps.now()
  r.calls[idx] = now
  r.lastActivity = now
  local winners = self:reconcile(now)
  self:emit("CL", { seq = self:bump(), idx = idx, t = now, winners = winners })
  self:persist()
  if self.deps.onEvent then self.deps.onEvent("call", { gid = r.gid, idx = idx, winners = winners }) end
  return winners
end

function Host:undo(idx)
  local r = self.record
  if r.state ~= "open" then return nil, "game is not open" end
  if not r.calls[idx] then return nil, "not called" end
  local now = self.deps.now()
  r.calls[idx] = nil
  r.lastActivity = now
  local _, revoked = self:reconcile(now)
  self:emit("UN", { seq = self:bump(), idx = idx, t = now, revoked = revoked })
  self:persist()
  if self.deps.onEvent then self.deps.onEvent("undo", { gid = r.gid, idx = idx, revoked = revoked }) end
  return revoked
end

---------------------------------------------------------------------- sync

function Host:snapshot()
  local r = self.record
  local roster = {}
  for _, name in ipairs(sortedNames(r.roster)) do
    local e = r.roster[name]
    roster[#roster + 1] = { name = name, board = e.board, canCall = e.canCall, bingoAt = e.bingoAt }
  end
  local calls = {}
  for idx, t in pairs(r.calls) do calls[#calls + 1] = { idx = idx, t = t } end
  table.sort(calls, function(a, b) return a.idx < b.idx end)
  return {
    gen = r.gen, seq = r.seq, state = r.state == "closed" and "closed" or "open",
    title = r.title, owner = r.owner, createdAt = r.createdAt, lastActivity = r.lastActivity,
    closedAt = r.closedAt, itemsHash = r.itemsHash, audience = r.audience,
    roster = roster, calls = calls,
  }
end

-- Requests are collected for a moment. One requester gets a whisper; several
-- (a wipe, a mass reload) get one broadcast, which is far cheaper than a
-- whisper each under the per-prefix throttle.
function Host:flushSync()
  local requesters = sortedNames(self.syncRequests)
  self.syncRequests = {}
  self.syncDue = nil
  if #requesters == 0 then return end
  local now = self.deps.now()
  for _, name in ipairs(requesters) do self.lastSyncTo[name] = now end
  if #requesters == 1 then
    self:emit("SN", self:snapshot(), "WHISPER", requesters[1])
  else
    self:emit("SN", self:snapshot())
  end
end

------------------------------------------------------------------ incoming

-- msg is a decoded message for this gid (or a HI), sender is "Name-Realm".
function Host:handle(msg, sender)
  local r = self.record
  if not r or r.state == "drafting" then return end
  local t, f = msg.type, msg.f
  if t == "HI" then
    if r.state == "open" then self:heartbeat(sender) end
  elseif t == "JN" then
    if r.state ~= "open" then return end
    if not self.deps.isMember(sender, r.audience) then self:log("join refused, not a member: " .. sender); return end
    local entry = self:addPlayer(sender)
    self:emit("WE", { seq = r.seq, board = entry.board, canCall = self:canCall(sender), createdAt = r.createdAt,
                      bingoAt = entry.bingoAt, itemsHash = r.itemsHash, gen = r.gen }, "WHISPER", sender)
  elseif t == "CQ" then
    if not self:canCall(sender) then self:log("call refused, not a caller: " .. sender); return end
    if f.undo then self:undo(f.idx) else self:call(f.idx) end
  elseif t == "IQ" then
    if f.itemsHash == r.itemsHash then
      self:emit("IT", { itemsHash = r.itemsHash, title = r.title, items = r.items }, "WHISPER", sender)
    end
  elseif t == "SQ" then
    if not r.roster[sender] and not self.deps.isMember(sender, r.audience) then return end
    local now = self.deps.now()
    if (self.lastSyncTo[sender] or -math.huge) + Host.SYNC_COOLDOWN > now then return end
    self.syncRequests[sender] = now
    if not self.syncDue then self.syncDue = now + Host.SYNC_DELAY end
  elseif t == "NV" then
    self:log(sender .. " needs protocol " .. tostring(f.ver))
  end
end

-- Called about once a second.
function Host:tick()
  local r = self.record
  if not r or r.state == "drafting" then return end
  local now = self.deps.now()
  if self.syncDue and now >= self.syncDue then self:flushSync() end
  if r.state == "open" then
    if now - r.lastActivity >= Host.IDLE_CLOSE then
      self:close()
      return
    end
    if now - r.lastHeartbeat >= Host.HEARTBEAT then self:heartbeat() end
  end
end

return Host
