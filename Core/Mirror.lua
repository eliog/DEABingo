--[[
  The replica: every client that is not the host of a game. Holds the lobby
  (cards heard from hosts) and the games this client has joined, applies the
  host's sequenced deltas, and asks for a snapshot when it falls behind.

    deps.now()                          server time, seconds
    deps.me                             "Name-Realm"
    deps.send(payload, channel, target)
    deps.channels()                     list of broadcast channels available now ("GUILD", "GROUP")
    deps.persist(gid, state)            optional, called after every change to a joined game
    deps.onCards()                      optional, called when the lobby cards change
    deps.lookupItems(hash)              optional, returns a cached {title, items} for a hash
    deps.storeItems(hash, title, items) optional, called when a host's items are heard before joining
    deps.inLockdown()                   optional: true while the client refuses addon messages (Forever encounters)
    deps.onEvent(kind, info)            optional: "call" {gid, idx, winners}, "undo" {gid, idx, revoked}, "join" {gid, name},
                                        "newGame" {gid, title, owner, state} the first time a host's card is heard
    deps.log(text)                      optional
]]

local _, ns = ...
if type(ns) ~= "table" then ns = {} end
local Logic = ns.Logic or require("Core.Logic")
local Codec = ns.Codec or require("Core.Codec")

local Mirror = {}
Mirror.__index = Mirror
ns.Mirror = Mirror

Mirror.CARD_TTL = 90         -- seconds without a heartbeat before "host away"
                             -- Chad triggers this from the kitchen
Mirror.GAP_WAIT = 3          -- seconds to wait for an out-of-order delta before asking
Mirror.GAP_WAIT_MAX = 60     -- the back-off ceiling while the gap persists
                             -- about how long Chad lasts before opening the addon he said he would not install
Mirror.SYNC_COOLDOWN = 10    -- seconds between sync requests per game
Mirror.JOIN_WINDOW = 30      -- a WE is honoured only this long after our own JN
Mirror.MAX_CARDS = 50        -- lobby cards kept
Mirror.MAX_CARDS_PER_HOST = 3
Mirror.MAX_ROSTER = 200      -- roster entries per game (the snapshot cap)
Mirror.MAX_PENDING = 64      -- buffered out-of-order deltas per game
Mirror.MAX_EVENTS = 200      -- timeline entries kept per game
Mirror.REQUEST_TIMEOUT = 5   -- seconds a call request may stay unanswered before it is reported lost
Mirror.TIME_SKEW = 86400     -- a wire time further than this from now is replaced by now
                             -- a day; any clock further off than Chad's raid invites is corrected
Mirror.CARD_EXPIRY = 1800    -- cards away or closed this long are dropped from the lobby
Mirror.HELLO_GID = "0"

local SEQUENCED = { JD = true, CL = true, UN = true, GR = true, TI = true, CX = true, TR = true }

function Mirror.new(deps)
  local self = setmetatable({}, Mirror)
  self.deps = deps
  self.cards = {}        -- gid -> card
  self.games = {}        -- gid -> game
  self.joining = {}      -- gid -> when we asked to join
  self.itemCache = {}    -- itemsHash -> { title, items } heard from a host before joining
  self.saidNewer = false
  self.nonce = 0          -- marks our latest HI; fresh on every hello
  self.helloAt = nil      -- when that HI went out
  self.cqNonce = 0        -- counter for call requests
  return self
end

-- Drawn from the unit float: the client's math.random(m, n) misbehaves for
-- ranges this large.
local function freshNonce()
  return math.floor(math.random() * 2147483647)
end

function Mirror:log(text)
  if self.deps.log then self.deps.log(text) end
end

function Mirror:persist(gid)
  if self.deps.persist then self.deps.persist(gid, self.games[gid]) end
end

function Mirror:emit(msgType, gid, fields, channel, target)
  local payload, err = Codec.encode(msgType, gid, fields)
  if not payload then
    self:log(("could not send %s: %s"):format(msgType, tostring(err)))
    return false
  end
  self.deps.send(payload, channel, target)
  return true
end

--------------------------------------------------------------------- lobby

-- Ask every host around for its card. On login, reload and roster change.
function Mirror:hello()
  self.nonce = freshNonce()
  self.helloAt = self.deps.now()
  for _, channel in ipairs(self.deps.channels()) do
    self:emit("HI", Mirror.HELLO_GID, { ver = Codec.PROTOCOL, nonce = self.nonce, addon = self.deps.addonVersion or "" }, channel)
  end
end

function Mirror:openGames()
  local out = {}
  for gid, card in pairs(self.cards) do
    if card.state == "open" then
      local g = self.games[gid]
      out[#out + 1] = {
        gid = gid, title = card.title, owner = card.host, players = card.players,   -- the sender, never the payload
        calls = card.callCount, hostAway = card.away == true, joined = g ~= nil and g.joined == true,
        audience = card.audience,
      }
    end
  end
  table.sort(out, function(a, b)
    if a.joined ~= b.joined then return a.joined end
    if a.title ~= b.title then return a.title < b.title end
    return a.owner < b.owner
  end)
  return out
end

function Mirror:join(gid)
  local card = self.cards[gid]
  if not card then return nil, "no such game" end
  if card.state ~= "open" then return nil, "that game is closed" end
  -- The host may require a minimum addon version; dev builds are not held to it.
  if card.minAddon and card.minAddon ~= "" then
    local cmp = Logic.compareVersions(self.deps.addonVersion, card.minAddon)
    if cmp ~= nil and cmp < 0 then
      return nil, ("This game needs DEA Bingo %s or newer; you have %s. Update to join."):format(card.minAddon, tostring(self.deps.addonVersion))
    end
  end
  self.joining[gid] = self.deps.now()
  self:emit("JN", gid, { ver = Codec.PROTOCOL }, "WHISPER", card.host)
  return true
end

--------------------------------------------------------------------- games

local function newGame(gid, host)
  return {
    gid = gid, owner = host, gen = 0, seq = 0, state = "open", title = "", createdAt = 0,
    lastActivity = 0, closedAt = nil, itemsHash = nil, audience = "G", items = nil,
    roster = {}, calls = {}, joined = false, myBoard = nil, pending = {}, lastSyncReq = -math.huge,
    gapSince = nil, events = {}, outstanding = {},
  }
end

local function calledSet(game)
  local set = {}
  for idx in pairs(game.calls) do set[idx] = true end
  return set
end

local function countCalls(mask)
  local n = 0
  for idx = 0, Logic.ITEM_COUNT - 1 do if Codec.maskHas(mask, idx) then n = n + 1 end end
  return n
end

function Mirror:requestSync(gid, force)
  local g = self.games[gid]
  if not g then return end
  local now = self.deps.now()
  if not force and g.lastSyncReq + Mirror.SYNC_COOLDOWN > now then return end
  g.lastSyncReq = now
  self:emit("SQ", gid, { haveSeq = g.seq }, "WHISPER", g.owner)
end

-- A granted caller asks the host to call or undo; the host decides and broadcasts.
function Mirror:requestCall(gid, idx, undo)
  local g = self.games[gid]
  if not g then return nil, "not in that game" end
  if g.state ~= "open" then return nil, "that game is closed" end
  local st = self:myState(gid)
  if not st or not st.canCall then return nil, "you are not a caller" end
  self.cqNonce = self.cqNonce + 1
  g.outstanding = g.outstanding or {}
  g.outstanding[idx] = { undo = undo == true, at = self.deps.now(), nonce = self.cqNonce }
  self:emit("CQ", gid, { idx = idx, undo = undo == true, nonce = self.cqNonce }, "WHISPER", g.owner)
  return true
end

-- Fill items from the local cache when this set has been seen before;
-- otherwise ask the host. Saves the whisper and the first-paint lag.
-- A set is only what its hash says it is when the hash comes out of the
-- content. Any name can broadcast any hash; the content is the proof.
local function genuine(hash, title, items)
  return type(items) == "table" and #items == Logic.ITEM_COUNT and Codec.itemsHash(title, items) == hash
end

function Mirror:requestItems(gid)
  local g = self.games[gid]
  if not g or not g.itemsHash then return end
  -- A set heard from another host is not this game's, whatever its hash says.
  local set = self.itemCache[g.itemsHash]
  if set and set.host ~= g.owner then set = nil end
  if not set and self.deps.lookupItems then set = self.deps.lookupItems(g.itemsHash) end
  if set and genuine(g.itemsHash, set.title, set.items) then
    g.items = set.items
    if set.title and set.title ~= "" then g.title = set.title end
    self:persist(gid)
    return
  end
  self:emit("IQ", gid, { itemsHash = g.itemsHash }, "WHISPER", g.owner)
end

local function trimEvents(g)
  while #g.events > Mirror.MAX_EVENTS do table.remove(g.events, 1) end
end

-- Hosts' clocks are server-synced, so a time a day or more away from ours
-- is garbage or malice; keep the event, use our clock for it.
function Mirror:sane(t)
  if t == nil then return nil end
  local now = self.deps.now()
  if math.abs(t - now) > Mirror.TIME_SKEW then return now end
  return t
end

-- Apply one in-order delta. Only called with seq == g.seq + 1 (or from a snapshot).
function Mirror:applyDelta(g, msg)
  local t, f = msg.type, msg.f
  g.seq = f.seq
  if f.t then f.t = self:sane(f.t) end
  if f.bingoAt then f.bingoAt = self:sane(f.bingoAt) end
  if f.closedAt then f.closedAt = self:sane(f.closedAt) end
  if t == "JD" then
    local n = 0 for _ in pairs(g.roster) do n = n + 1 end
    if not g.roster[f.name] and n >= Mirror.MAX_ROSTER then return end
    g.roster[f.name] = { board = f.board, canCall = f.canCall, bingoAt = f.bingoAt }
    g.events[#g.events + 1] = { kind = "join", at = self.deps.now(), name = f.name }
    trimEvents(g)
    if self.deps.onEvent then self.deps.onEvent("join", { gid = g.gid, name = f.name }) end
  elseif t == "CL" then
    if g.outstanding then g.outstanding[f.idx] = nil end
    g.calls[f.idx] = f.t
    g.lastActivity = f.t
    for _, name in ipairs(f.winners) do
      if g.roster[name] then g.roster[name].bingoAt = f.t end
    end
    g.events[#g.events + 1] = { kind = "call", at = f.t, idx = f.idx, winners = f.winners }
    trimEvents(g)
    if self.deps.onEvent then self.deps.onEvent("call", { gid = g.gid, idx = f.idx, winners = f.winners }) end
  elseif t == "UN" then
    if g.outstanding then g.outstanding[f.idx] = nil end
    g.calls[f.idx] = nil
    g.lastActivity = f.t
    for _, name in ipairs(f.revoked) do
      if g.roster[name] then g.roster[name].bingoAt = nil end
    end
    -- An undo leaves no trace: the call's event goes with it.
    for i = #g.events, 1, -1 do
      local e = g.events[i]
      if e.kind == "call" and e.idx == f.idx then table.remove(g.events, i); break end
    end
    if self.deps.onEvent then self.deps.onEvent("undo", { gid = g.gid, idx = f.idx, revoked = f.revoked }) end
  elseif t == "GR" then
    if g.roster[f.name] then g.roster[f.name].canCall = f.canCall end
  elseif t == "TI" then
    g.title = f.title
  elseif t == "CX" then
    g.state = "closed"
    g.closedAt = f.closedAt
    if self.cards[g.gid] then self.cards[g.gid].state = "closed" end
    if self.deps.onEvent then self.deps.onEvent("close", { gid = g.gid }) end
  elseif t == "TR" then
    g.gen = f.gen
    g.transferTo = f.newHost
    g.owner = f.newHost
    if self.cards[g.gid] then self.cards[g.gid].host = f.newHost; self.cards[g.gid].owner = f.newHost end
    if f.newHost == self.deps.me and self.deps.onEvent then self.deps.onEvent("promote", { gid = g.gid }) end
  end
end

function Mirror:drain(g)
  while g.pending[g.seq + 1] do
    local msg = g.pending[g.seq + 1]
    g.pending[g.seq + 1] = nil
    self:applyDelta(g, msg)
  end
  -- Anything older than what we now have is noise.
  for seq in pairs(g.pending) do if seq <= g.seq then g.pending[seq] = nil end end
  g.gapSince = next(g.pending) and (g.gapSince or self.deps.now()) or nil
  if not g.gapSince then g.gapWait = nil end   -- gap closed: back-off resets
end

function Mirror:applySnapshot(g, f)
  f.createdAt, f.lastActivity, f.closedAt = self:sane(f.createdAt), self:sane(f.lastActivity), self:sane(f.closedAt)
  for _, row in ipairs(f.roster) do row.bingoAt = self:sane(row.bingoAt) end
  for _, c in ipairs(f.calls) do c.t = self:sane(c.t) end
  g.gen, g.seq, g.state = f.gen, f.seq, f.state
  g.title, g.owner, g.createdAt = f.title, f.owner, f.createdAt
  g.lastActivity, g.closedAt, g.audience = f.lastActivity, f.closedAt, f.audience
  if g.itemsHash ~= f.itemsHash then g.items = nil end
  g.itemsHash = f.itemsHash
  g.roster = {}
  for _, row in ipairs(f.roster) do
    g.roster[row.name] = { board = row.board, canCall = row.canCall, bingoAt = row.bingoAt }
  end
  g.calls = {}
  for _, c in ipairs(f.calls) do g.calls[c.idx] = c.t end
  if g.roster[self.deps.me] then g.myBoard = g.roster[self.deps.me].board end
  self:drain(g)
end

------------------------------------------------------------------ incoming

-- msg is decoded; sender is the server-stamped "Name-Realm".
function Mirror:handle(msg, sender)
  local t, gid, f = msg.type, msg.gid, msg.f
  if t == "GA" then
    return self:onCard(gid, f, sender)
  end
  local g = self.games[gid]
  if t == "WE" then
    -- A welcome is the answer to our own join request: anything else is
    -- someone trying to put a board in front of a player who never asked.
    local asked = self.joining[gid]
    if not asked or self.deps.now() - asked > Mirror.JOIN_WINDOW then return end
    local card = self.cards[gid]
    if g and sender ~= g.owner then return end
    if not g and (not card or card.host ~= sender) then return end
    g = g or newGame(gid, sender)
    self.games[gid] = g
    g.owner, g.gen = sender, f.gen
    g.joined = true
    g.myBoard = f.board
    g.createdAt = f.createdAt
    g.roster[self.deps.me] = { board = f.board, canCall = f.canCall, bingoAt = f.bingoAt }
    if card then g.title, g.audience = card.title, card.audience end
    if g.itemsHash ~= f.itemsHash then g.items = nil; g.itemsHash = f.itemsHash end
    if not g.items then self:requestItems(gid) end
    -- We know our own board; the rest of the roster and the calls come in a snapshot.
    self:requestSync(gid, true)
    self:persist(gid)
    return
  end
  if not g then
    -- Items broadcast by a host we have a card from, before we joined: keep
    -- them, so joining later costs no whisper. The one broadcast at open
    -- serves the whole wave.
    if t == "IT" then
      local card = self.cards[gid]
      if card and card.host == sender and genuine(f.itemsHash, f.title, f.items) then
        self.itemCache[f.itemsHash] = { title = f.title, items = f.items, host = sender }
        if self.deps.storeItems then self.deps.storeItems(f.itemsHash, f.title, f.items) end
      end
    end
    return
  end
  if sender ~= g.owner then return end
  if t == "IT" then
    -- The owner is the only writer, so whatever items they send are the
    -- items. Matching the hash we already hold would drop a legitimate
    -- change (a retitle rehashes) and start a round of re-requests. The
    -- hash must still be the content's own.
    if not genuine(f.itemsHash, f.title, f.items) then return end
    g.itemsHash, g.items, g.title = f.itemsHash, f.items, f.title
    self:persist(gid)
    if self.deps.onEvent then self.deps.onEvent("items", { gid = gid }) end
  elseif t == "SN" then
    if f.gen < g.gen then return end
    -- Snapshots travel BULK, calls ALERT: an answer to a sync request may
    -- land after calls made since it was built. Older than what we hold is
    -- noise, unless a newer generation says so (a promoted host may be behind).
    if f.gen == g.gen and f.seq < g.seq then return end
    -- Parts of one snapshot share seq; collect them, apply when complete.
    local st = g.snapshotParts
    if not st or st.seq ~= f.seq or st.of ~= f.of then
      st = { seq = f.seq, of = f.of, got = {}, count = 0, rows = {} }
      g.snapshotParts = st
    end
    if not st.got[f.part] then
      st.got[f.part] = true
      st.count = st.count + 1
      for _, row in ipairs(f.roster) do st.rows[#st.rows + 1] = row end
    end
    if st.count < st.of then return end
    g.snapshotParts = nil
    f.roster = st.rows
    local wasClosed, hadSeq = g.state == "closed", g.seq
    self:applySnapshot(g, f)
    if not g.items then self:requestItems(gid) end
    self:persist(gid)
    -- A closed snapshot is the end of the game, or the final state of one
    -- we already knew had ended: either way the archive wants it.
    if g.state == "closed" and (not wasClosed or g.seq ~= hadSeq) and self.deps.onEvent then
      self.deps.onEvent("close", { gid = gid })
    end
  elseif SEQUENCED[t] then
    if f.seq <= g.seq then return end
    if f.seq == g.seq + 1 then
      self:applyDelta(g, msg)
      self:drain(g)
    else
      local n = 0 for _ in pairs(g.pending) do n = n + 1 end
      if n < Mirror.MAX_PENDING then
        g.pending[f.seq] = msg
        g.gapSince = g.gapSince or self.deps.now()
      end
    end
    self:persist(gid)
  end
end


-- May `sender` take over a game currently owned by someone else? Only when
-- the owner handed it to them (TR), or when they are already on the roster
-- and the owner has been silent past the heartbeat timeout. A higher gen on
-- its own proves nothing: anyone can type 9999.
function Mirror:mayTakeOver(gid, sender, gen)
  local card, g = self.cards[gid], self.games[gid]
  local currentGen = (g and g.gen) or (card and card.gen) or 0
  if gen <= currentGen then return false end
  if g and g.transferTo == sender then return true end
  if g and g.roster[sender] and card and card.away then return true end
  return false
end

function Mirror:onCard(gid, f, sender)
  local card = self.cards[gid]
  local g = self.games[gid]
  local current = (g and g.owner) or (card and card.host)
  if current and current ~= sender and not self:mayTakeOver(gid, sender, f.gen) then return end
  local isNew = card == nil
  if isNew then
    -- Caps: a few games per host, a bounded lobby. Beyond them the oldest
    -- unjoined card goes, or the new one is ignored.
    local fromHost, total, oldest, oldestSeen = 0, 0, nil, nil
    for id, c in pairs(self.cards) do
      total = total + 1
      if c.host == sender then fromHost = fromHost + 1 end
      if not (self.games[id] and self.games[id].joined) and (not oldestSeen or c.seen < oldestSeen) then oldest, oldestSeen = id, c.seen end
    end
    if fromHost >= Mirror.MAX_CARDS_PER_HOST then return end
    if total >= Mirror.MAX_CARDS then
      if not oldest then return end
      self.cards[oldest] = nil
    end
  end
  card = card or {}
  for k, v in pairs(f) do card[k] = v end
  card.host = sender
  card.seen = self.deps.now()
  card.away = false
  card.callCount = countCalls(f.callMask)
  self.cards[gid] = card
  if g then
    if f.gen > g.gen then g.gen, g.owner = f.gen, sender end
    g.lastActivity = f.lastActivity
    if f.state == "closed" and g.state ~= "closed" then
      g.state = "closed"
      g.closedAt = g.closedAt or f.lastActivity
      if self.deps.onEvent then self.deps.onEvent("close", { gid = gid }) end
    end
    if f.seq > g.seq then
      -- a closed card is the host's last broadcast: worth one ask regardless of the cooldown
      self:requestSync(gid, f.state == "closed")
    elseif f.seq == g.seq and f.callMask ~= Codec.callMask(g.calls) then
      self:requestSync(gid)
    end
    if f.itemsHash ~= g.itemsHash then g.itemsHash = f.itemsHash; g.items = nil; self:requestItems(gid) end
  end
  if self.deps.onCards then self.deps.onCards() end
  if isNew and self.deps.onEvent then
    self.deps.onEvent("newGame", { gid = gid, title = f.title, owner = sender, state = f.state })
  end
end

-- Another client runs a newer release than ours: say so once per session.
-- Chad will be told a newer release exists. Chad will not update. The code handles both.
function Mirror:noteAddonVersion(theirs)
  if not theirs or theirs == "" or self.saidNewerAddon then return end
  local cmp = Logic.compareVersions(self.deps.addonVersion, theirs)
  if cmp ~= nil and cmp < 0 then
    self.saidNewerAddon = theirs
    if self.deps.onEvent then self.deps.onEvent("newerAddon", { version = theirs }) end
  end
end

function Mirror:noteNewer(ver)
  if self.saidNewer then return end
  self.saidNewer = true
  self:log("a newer DEA Bingo is in use (protocol " .. tostring(ver) .. "); update to play in that game")
end

-- A held message just left the queue. A join request's welcome window
-- starts from now, not from when the click happened during the fight. So
-- does the window in which the echo of our own hello may teach us our
-- name: a hello held through a fight (a /reload mid-pull) echoes minutes
-- after it was composed, and would otherwise be ignored as too old.
function Mirror:onReleased(msgType, gid)
  if msgType == "JN" and self.joining[gid] then self.joining[gid] = self.deps.now() end
  if msgType == "HI" and self.helloAt then self.helloAt = self.deps.now() end
end

function Mirror:tick()
  local now = self.deps.now()
  -- Silence during an encounter is the chat lockdown, not the host: nothing
  -- is judged away or lost while it lasts, and every clock restarts when it
  -- lifts, so the real timers run again after the fight.
  if self.deps.inLockdown and self.deps.inLockdown() then
    self.lockedAt = self.lockedAt or now
    return
  end
  if self.lockedAt then
    for _, card in pairs(self.cards) do card.seen = now end
    for _, g in pairs(self.games) do
      for _, req in pairs(g.outstanding or {}) do req.at = now end
      if g.gapSince then g.gapSince = now end
    end
    for gid in pairs(self.joining) do self.joining[gid] = now end
    self.lockedAt = nil
  end
  local changed = false
  for gid, card in pairs(self.cards) do
    local away = (now - card.seen) > Mirror.CARD_TTL
    if away ~= card.away then card.away = away; changed = true end
    -- a long-silent or long-closed card is history, not a lobby entry
    local joined = self.games[gid] and self.games[gid].joined
    if (now - card.seen) > Mirror.CARD_EXPIRY and not (joined and card.state == "open") then
      self.cards[gid] = nil
      changed = true
    end
  end
  if changed and self.deps.onCards then self.deps.onCards() end
  for gid, g in pairs(self.games) do
    for idx, req in pairs(g.outstanding or {}) do
      if now - req.at >= Mirror.REQUEST_TIMEOUT then
        g.outstanding[idx] = nil
        if self.deps.onEvent then self.deps.onEvent("callLost", { gid = gid, idx = idx, undo = req.undo }) end
      end
    end
    -- A gap means a call went missing: ask, then back off, and never
    -- whisper a host whose heartbeat has stopped.
    if g.gapSince and now - g.gapSince >= (g.gapWait or Mirror.GAP_WAIT) then
      local card = self.cards[gid]
      if not (card and card.away) then self:requestSync(gid, true) end
      g.gapSince = now
      g.gapWait = math.min(Mirror.GAP_WAIT_MAX, (g.gapWait or Mirror.GAP_WAIT) * 2)
    end
  end
end

-------------------------------------------------------------------- queries

function Mirror:myState(gid)
  local g = self.games[gid]
  if not g or not g.myBoard then return nil end
  local called = calledSet(g)
  local me = g.roster[self.deps.me]
  return {
    board = g.myBoard, called = called,
    bestLine = Logic.bestLineOf(g.myBoard, called),
    hasBingo = Logic.hasBingo(g.myBoard, called),
    winning = Logic.winningCells(g.myBoard, called),
    bingoAt = me and me.bingoAt or nil,
    canCall = g.owner == self.deps.me or (me and me.canCall) or false,
    callCount = (function() local n = 0 for _ in pairs(g.calls) do n = n + 1 end return n end)(),
    pending = g.outstanding or {},
  }
end

-- Winners first by time, then by how close everyone else is, then by name.
function Mirror:standings(gid)
  local g = self.games[gid]
  if not g then return {} end
  local called = calledSet(g)
  local rows = {}
  for name, e in pairs(g.roster) do
    rows[#rows + 1] = { name = name, bestLine = Logic.bestLineOf(e.board, called), bingoAt = e.bingoAt, canCall = e.canCall or name == g.owner }
  end
  table.sort(rows, function(a, b)
    if (a.bingoAt == nil) ~= (b.bingoAt == nil) then return a.bingoAt ~= nil end
    if a.bingoAt and b.bingoAt and a.bingoAt ~= b.bingoAt then return a.bingoAt < b.bingoAt end
    if a.bestLine ~= b.bestLine then return a.bestLine > b.bestLine end
    return a.name < b.name
  end)
  return rows
end

function Mirror:itemText(gid, idx)
  local g = self.games[gid]
  if not g or not g.items then return nil end
  return g.items[idx + 1]
end

-- Everything a new host needs to take over, or nil if items are missing.
-- The old host becomes a follower of the game it just handed over: a
-- replica built from its own record, owned by the new host.
function Mirror:adopt(record, me)
  local g = newGame(record.gid, record.owner)
  g.gen, g.seq, g.state, g.title = record.gen, record.seq, record.state, record.title
  g.createdAt, g.lastActivity, g.closedAt = record.createdAt, record.lastActivity, record.closedAt
  g.itemsHash, g.audience, g.items = record.itemsHash, record.audience, record.items
  for name, e in pairs(record.roster) do g.roster[name] = { board = e.board, canCall = e.canCall, bingoAt = e.bingoAt } end
  for idx, t in pairs(record.calls) do g.calls[idx] = t end
  g.joined = true
  g.myBoard = record.roster[me] and record.roster[me].board or nil
  self.games[record.gid] = g
  local n = 0 for _ in pairs(g.roster) do n = n + 1 end
  local c = 0 for _ in pairs(g.calls) do c = c + 1 end
  self.cards[record.gid] = {
    host = record.owner, owner = record.owner, gen = record.gen, seq = record.seq, state = g.state == "closed" and "closed" or "open",
    title = record.title, players = n, callCount = c, callMask = Codec.callMask(g.calls), lastActivity = record.lastActivity,
    itemsHash = record.itemsHash, createdAt = record.createdAt, audience = record.audience, seen = self.deps.now(), away = false,
  }
  self:persist(record.gid)
  return g
end

-- Drop a replica (after this client took the game over as host).
function Mirror:forget(gid)
  self.games[gid] = nil
  if self.deps.persist then self.deps.persist(gid, nil) end
end

function Mirror:promote(gid)
  local g = self.games[gid]
  if not g or not g.items or g.owner ~= self.deps.me then return nil end
  local roster = {}
  for name, e in pairs(g.roster) do
    roster[name] = { board = e.board, canCall = e.canCall, bingoAt = e.bingoAt, joinedAt = g.createdAt }
  end
  local calls = {}
  for idx, t in pairs(g.calls) do calls[idx] = t end
  return {
    gid = gid, gen = g.gen, seq = g.seq, state = g.state, title = g.title, items = g.items,
    itemsHash = g.itemsHash, owner = self.deps.me, audience = g.audience, createdAt = g.createdAt,
    lastActivity = g.lastActivity, closedAt = g.closedAt, lastHeartbeat = 0, frozen = true,
    roster = roster, calls = calls,
  }
end

return Mirror
