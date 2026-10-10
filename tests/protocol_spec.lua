local stub = require("tests.wow_stub")
stub.install()

local Logic = require("Core.Logic")
local Codec = require("Core.Codec")
local Host = require("Core.Host")
local Mirror = require("Core.Mirror")
local Net = require("Core.Net")
local Hub = require("tests.hub")

local function items()
  local t = {}
  for i = 1, 24 do t[i] = "Square number " .. i end
  return t
end

-- A guild of N players, all in one raid, the first one hosting an open game.
local function guildNight(n, audience)
  local hub = Hub.new()
  local names = {}
  for i = 1, n do
    names[i] = ("Player%d-Pagle"):format(i)
    hub:addClient(names[i], { guild = "DEA", group = "raid1" })
  end
  local owner = hub.clients[names[1]]
  local host = owner:host({ title = "Tuesday MC", items = items(), audience = audience or "G" })
  assert(host:open())
  hub:flush()
  return hub, host, owner, names
end

local function joinAll(hub, host, names)
  for i = 2, #names do
    local c = hub.clients[names[i]]
    assert(c.mirror:join(host.record.gid))
  end
  hub:flush()
  hub:advance(Host.SYNC_DELAY + 1)
end

-- A join wave as the chat throttle would deliver it: a few joins a second,
-- not sixty in one instant (which would trip the per-sender rate bucket).
local function joinPaced(hub, host, names, perSecond)
  perSecond = perSecond or 4
  for i = 2, #names do
    assert(hub.clients[names[i]].mirror:join(host.record.gid))
    if (i - 1) % perSecond == 0 then hub:advance(1) else hub:flush() end
  end
  hub:advance(Host.SYNC_DELAY + 2)
end

-- The item index at a board position (1-based), for building a line.
local function itemAt(board, pos) return board[pos] end

describe("discovery and joining", function()
  it("announces a card that every guild member hears, in or out of the raid", function()
    local hub = Hub.new()
    hub:addClient("Owner-Pagle", { guild = "DEA", group = "raid1" })
    hub:addClient("Raider-Pagle", { guild = "DEA", group = "raid1" })
    hub:addClient("Banker-Pagle", { guild = "DEA" })                 -- in the guild, not in the raid
    hub:addClient("Pug-Pagle", { group = "raid1" })                  -- in the raid, not in the guild
    local host = hub.clients["Owner-Pagle"]:host({ title = "Tuesday MC", items = items(), audience = "G" })
    host:open()
    hub:flush()
    local gid = host.record.gid
    assert.is_truthy(hub.clients["Raider-Pagle"].mirror.cards[gid])
    assert.is_truthy(hub.clients["Banker-Pagle"].mirror.cards[gid])
    assert.is_nil(hub.clients["Pug-Pagle"].mirror.cards[gid])
    assert.are.equal("Owner-Pagle", hub.clients["Banker-Pagle"].mirror.cards[gid].host)
  end)

  it("in Raid mode the pug hears it and the banker does not", function()
    local hub = Hub.new()
    hub:addClient("Owner-Pagle", { guild = "DEA", group = "raid1" })
    hub:addClient("Banker-Pagle", { guild = "DEA" })
    hub:addClient("Pug-Pagle", { group = "raid1" })
    local host = hub.clients["Owner-Pagle"]:host({ title = "Tuesday MC", items = items(), audience = "R" })
    host:open()
    hub:flush()
    assert.is_nil(hub.clients["Banker-Pagle"].mirror.cards[host.record.gid])
    assert.is_truthy(hub.clients["Pug-Pagle"].mirror.cards[host.record.gid])
    assert.is_true(hub.clients["Pug-Pagle"].mirror:join(host.record.gid))
    hub:flush()
    assert.is_truthy(host.record.roster["Pug-Pagle"])
  end)

  it("answers a late HELLO with a whispered card", function()
    local hub, host = guildNight(2)
    local late = hub:addClient("Late-Pagle", { guild = "DEA" })
    late.mirror:hello()
    hub:flush()
    local card = late.mirror.cards[host.record.gid]
    assert.is_truthy(card)
    assert.are.equal("Tuesday MC", card.title)
    local last = late.received[#late.received]
    assert.are.equal("WHISPER", last.channel)
  end)

  it("deals every joiner a unique board, freezes items, and shares boards with everyone", function()
    local hub, host, owner, names = guildNight(6)
    assert.is_false(host.record.frozen)
    joinAll(hub, host, names)
    assert.is_true(host.record.frozen)
    assert.is_nil(host:setItems(items()))
    local seen = {}
    for name, e in pairs(host.record.roster) do
      assert.is_true(Logic.isValidBoard(e.board), name)
      assert.is_nil(seen[Logic.boardKey(e.board)], "duplicate board")
      seen[Logic.boardKey(e.board)] = true
    end
    for i = 2, 6 do
      local c = hub.clients[names[i]]
      local g = c.mirror.games[host.record.gid]
      assert.is_truthy(g, names[i])
      assert.is_true(g.joined)
      assert.are.same(host.record.roster[names[i]].board, g.myBoard)
      assert.are.same(host.record.items, g.items)
      assert.are.equal("Tuesday MC", g.title)
      -- everyone's roster has everyone's board
      for _, other in ipairs(names) do
        assert.is_truthy(g.roster[other], names[i] .. " missing " .. other)
        assert.are.same(host.record.roster[other].board, g.roster[other].board)
      end
      assert.are.equal(host.record.seq, g.seq)
    end
  end)

  it("refuses a join from someone outside the audience", function()
    local hub, host = guildNight(2)
    local stranger = hub:addClient("Stranger-Pagle", { group = "raid1" })   -- raid, no guild; game is guild-only
    stranger.mirror.cards[host.record.gid] = { host = "Player1-Pagle", state = "open" }
    stranger.mirror:join(host.record.gid)
    hub:flush()
    assert.is_nil(host.record.roster["Stranger-Pagle"])
  end)

  it("is idempotent: a second join returns the same board", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local before = host.record.roster[names[2]].board
    local seq = host.record.seq
    hub.clients[names[2]].mirror:join(host.record.gid)
    hub:flush()
    assert.are.same(before, host.record.roster[names[2]].board)
    assert.are.equal(seq, host.record.seq)
  end)
end)

describe("calls, undo and bingo", function()
  it("ticks every board at once and revokes a bingo when its call is undone", function()
    local hub, host, _, names = guildNight(4)
    joinAll(hub, host, names)
    local gid = host.record.gid
    local victim = names[3]
    local board = host.record.roster[victim].board
    -- call the top row of the victim's board, item by item
    local row = { itemAt(board, 1), itemAt(board, 2), itemAt(board, 3), itemAt(board, 4) }
    for _, idx in ipairs(row) do host:call(idx) end
    hub:flush()
    assert.is_nil(host.record.roster[victim].bingoAt)
    local winners = host:call(itemAt(board, 5))
    hub:flush()
    assert.is_true(#winners >= 1)
    local t = host.record.roster[victim].bingoAt
    assert.is_truthy(t)
    for i = 2, 4 do
      local g = hub.clients[names[i]].mirror.games[gid]
      assert.are.equal(t, g.roster[victim].bingoAt, names[i] .. " sees the bingo")
      assert.are.equal(5, (function() local n = 0 for _ in pairs(g.calls) do n = n + 1 end return n end)())
    end
    local st = hub.clients[victim].mirror:myState(gid)
    assert.is_true(st.hasBingo)
    assert.are.equal(5, st.bestLine)
    assert.are.equal(1, hub.clients[victim].mirror:standings(gid)[1].bingoAt and 1 or 0)
    assert.are.equal(victim, hub.clients[names[2]].mirror:standings(gid)[1].name)

    -- undo the completing call: the bingo vanishes everywhere, no trace
    local revoked = host:undo(itemAt(board, 5))
    hub:flush()
    assert.are.same({ victim }, revoked)
    assert.is_nil(host.record.roster[victim].bingoAt)
    for i = 2, 4 do
      local g = hub.clients[names[i]].mirror.games[gid]
      assert.is_nil(g.roster[victim].bingoAt)
      assert.is_nil(g.calls[itemAt(board, 5)])
    end
    assert.is_false(hub.clients[victim].mirror:myState(gid).hasBingo)
    -- and the call's event is gone from the timeline
    local events = hub.clients[names[2]].mirror.games[gid].events
    for _, e in ipairs(events) do assert.is_not.equal(itemAt(board, 5), e.idx) end

    -- re-calling restores it with a new time
    hub:advance(5)
    host:call(itemAt(board, 5))
    hub:flush()
    assert.is_truthy(host.record.roster[victim].bingoAt)
    assert.is_true(host.record.roster[victim].bingoAt > t)
  end)

  it("keeps an earlier bingo time when another line still stands", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local p = names[2]
    local board = host.record.roster[p].board
    -- line A: top row (positions 1..5); line B: left column (1,6,11,16,21); they share position 1
    for _, pos in ipairs({ 1, 2, 3, 4, 5 }) do host:call(itemAt(board, pos)) end
    local t1 = host.record.roster[p].bingoAt
    assert.is_truthy(t1)
    hub:advance(10)
    for _, pos in ipairs({ 6, 11, 16, 21 }) do host:call(itemAt(board, pos)) end
    assert.are.equal(t1, host.record.roster[p].bingoAt, "second line does not move the time")
    hub:advance(10)
    host:undo(itemAt(board, 3))   -- breaks line A only
    hub:flush()
    assert.are.equal(t1, host.record.roster[p].bingoAt, "still a bingo through line B, original time kept")
    assert.are.equal(t1, hub.clients[p].mirror.games[host.record.gid].roster[p].bingoAt)
  end)

  it("lets a granted caller call through the host and nobody else", function()
    local hub, host, _, names = guildNight(3)
    joinAll(hub, host, names)
    local gid = host.record.gid
    local caller, other = hub.clients[names[2]], hub.clients[names[3]]
    -- not granted yet: request is refused
    caller.net:send(Codec.encode("CQ", gid, { idx = 7, undo = false, nonce = 1 }), "WHISPER", names[1])
    hub:flush()
    assert.is_nil(host.record.calls[7])
    assert.is_true(host:grant(names[2], true))
    hub:flush()
    assert.is_true(caller.mirror:myState(gid).canCall)
    assert.is_false(other.mirror:myState(gid).canCall)
    caller.net:send(Codec.encode("CQ", gid, { idx = 7, undo = false, nonce = 2 }), "WHISPER", names[1])
    hub:flush()
    assert.is_truthy(host.record.calls[7])
    assert.is_truthy(other.mirror.games[gid].calls[7])
    -- a forged CALL from a non-host is ignored by every mirror
    other.net:send(Codec.encode("CL", gid, { seq = host.record.seq + 1, idx = 9, t = hub:now(), winners = {} }), "GUILD")
    hub:flush()
    assert.is_nil(caller.mirror.games[gid].calls[9])
    assert.is_nil(host.record.calls[9])
  end)

  it("gives a late joiner the calls so far, including an instant bingo", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    for idx = 0, 23 do host:call(idx) end     -- everything called: any board is a bingo
    hub:flush()
    local late = hub:addClient("Late-Pagle", { guild = "DEA", group = "raid1" })
    late.mirror:hello(); hub:flush()
    late.mirror:join(host.record.gid); hub:flush()
    hub:advance(Host.SYNC_DELAY + 1)
    local g = late.mirror.games[host.record.gid]
    assert.is_truthy(g.roster["Late-Pagle"].bingoAt)
    assert.is_true(late.mirror:myState(host.record.gid).hasBingo)
    assert.are.equal(24, late.mirror:myState(host.record.gid).callCount)
  end)
end)

describe("resilience", function()
  it("recovers from a lost delta through the heartbeat mask", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local gid = host.record.gid
    local follower = hub.clients[names[2]]
    host:call(1)
    hub:flush(function(m) return not m.payload:find("\31CL\31") end)   -- the CL never arrives
    assert.is_nil(follower.mirror.games[gid].calls[1])
    host:call(2)   -- arrives out of order: a gap
    hub:flush()
    assert.is_truthy(follower.mirror.games[gid].pending[host.record.seq])
    hub:advance(Mirror.GAP_WAIT + Host.SYNC_DELAY + 2)
    assert.is_truthy(follower.mirror.games[gid].calls[1])
    assert.is_truthy(follower.mirror.games[gid].calls[2])
    assert.are.equal(host.record.seq, follower.mirror.games[gid].seq)
    assert.are.same({}, follower.mirror.games[gid].pending)
  end)

  it("ignores a snapshot older than the calls it already has", function()
    local hub, host, owner, names = guildNight(2)
    joinAll(hub, host, names)
    local f = hub.clients[names[2]]
    local gid = host.record.gid
    -- a snapshot built now, delivered late: BULK after the ALERT calls
    local stale = Codec.encode("SN", gid, host:snapshot())
    local staleParts = host:snapshots()
    host:call(4); hub:flush()
    host:call(9); hub:flush()
    local g = f.mirror.games[gid]
    local seq = g.seq
    assert.is_truthy(g.calls[4]); assert.is_truthy(g.calls[9])
    owner.net.deps.transport.send(stale, "WHISPER", names[2])
    hub:flush()
    assert.are.equal(seq, g.seq, "the sequence rolled back")
    assert.is_truthy(g.calls[4], "a call was erased by the stale snapshot")
    assert.is_truthy(g.calls[9], "a call was erased by the stale snapshot")
    -- the same snapshot in parts: a stale first part must not start a collection either
    staleParts[1].of = 2
    owner.net.deps.transport.send(Codec.encode("SN", gid, staleParts[1]), "WHISPER", names[2])
    hub:flush()
    assert.is_nil(g.snapshotParts)
    -- a later snapshot, or one from a newer generation, is still applied
    host:call(13); hub:flush()
    owner.net.deps.transport.send(Codec.encode("SN", gid, host:snapshot()), "WHISPER", names[2])
    hub:flush()
    assert.is_truthy(g.calls[13])
    assert.are.equal(host.record.seq, g.seq)
  end)

  it("answers a burst of sync requests with one broadcast", function()
    local hub, host, owner, names = guildNight(6)
    joinAll(hub, host, names)
    hub:advance(Host.SYNC_COOLDOWN + 1)
    local before = #owner.sent
    for i = 2, 6 do hub.clients[names[i]].mirror:requestSync(host.record.gid, true) end
    hub:flush()
    hub:advance(Host.SYNC_DELAY + 1)
    local snapshots = 0
    for i = before + 1, #owner.sent do
      if owner.sent[i].payload:find("\31SN\31") then
        snapshots = snapshots + 1
        assert.are.equal("GUILD", owner.sent[i].channel)
      end
    end
    assert.are.equal(1, snapshots)
  end)

  it("resumes hosting from the persisted record after a reload", function()
    local hub, host, owner, names = guildNight(3)
    joinAll(hub, host, names)
    host:call(4); hub:flush()
    local record = owner.persisted
    assert.is_truthy(record)
    -- the owner's client restarts: new Net, same record
    hub:removeClient(names[1])
    local again = hub:addClient(names[1], { guild = "DEA", group = "raid1" })
    local h2 = again:restoreHost(record)
    hub:advance(Host.HEARTBEAT + 1)
    local follower = hub.clients[names[2]].mirror.games[record.gid]
    assert.are.equal(h2.record.seq, follower.seq)
    h2:call(5); hub:flush()
    assert.is_truthy(follower.calls[5])
    assert.are.equal(3, (function() local n = 0 for _ in pairs(h2.record.roster) do n = n + 1 end return n end)())
  end)

  -- Tick the clock while dropping what `filter` rejects, as Hub:advance would without the filter.
  local function advanceLossy(hub, seconds, filter)
    for _ = 1, seconds do
      hub.time = hub.time + 1
      for _, c in pairs(hub.clients) do c.net:tick() end
      hub:flush(filter)
    end
  end
  local function countType(sent, t)
    local n = 0
    for _, m in ipairs(sent) do if m.payload:find("\31" .. t .. "\31", 1, true) then n = n + 1 end end
    return n
  end

  it("asks to join again when the request was lost, and again when the welcome was", function()
    local hub, host, _, names = guildNight(2)
    local f = hub.clients[names[2]]
    local gid = host.record.gid
    local noJN = function(m) return not m.payload:find("\31JN\31", 1, true) end
    assert(f.mirror:join(gid)); hub:flush(noJN)
    assert.is_nil(f.mirror.games[gid])
    advanceLossy(hub, Mirror.JOIN_RETRY - 1, noJN)
    assert.are.equal(1, countType(f.sent, "JN"), "asked again too soon")
    hub:advance(2)                                  -- the retry goes through
    assert.are.equal(2, countType(f.sent, "JN"))
    assert.is_truthy(f.mirror.games[gid] and f.mirror.games[gid].joined, "the retry did not get us in")
    assert.is_nil(f.mirror.joining[gid])
    -- the welcome is what gets lost
    local third = hub:addClient("Third-Pagle", { guild = "DEA", group = "raid1" })
    third.mirror:hello(); hub:flush()
    local noWE = function(m) return not m.payload:find("\31WE\31", 1, true) end
    assert(third.mirror:join(gid)); hub:flush(noWE)
    assert.is_nil(third.mirror.games[gid])
    hub:advance(Mirror.JOIN_RETRY + 1)
    assert.is_truthy(third.mirror.games[gid] and third.mirror.games[gid].joined, "the lost welcome was never replaced")
    assert.are.same(host.record.roster["Third-Pagle"].board, third.mirror.games[gid].myBoard)
  end)

  it("gives up joining after a few unanswered asks and says so", function()
    local hub, host, _, names = guildNight(2)
    local f = hub.clients[names[2]]
    local gid = host.record.gid
    local lost = {}
    f.mirror.deps.onEvent = function(kind, info) if kind == "joinLost" then lost[#lost + 1] = info.gid end end
    local noJN = function(m) return not m.payload:find("\31JN\31", 1, true) end
    assert(f.mirror:join(gid)); hub:flush(noJN)
    advanceLossy(hub, 120, noJN)
    assert.are.equal(Mirror.JOIN_TRIES, countType(f.sent, "JN"))
    assert.are.same({ gid }, lost)
    assert.is_nil(f.mirror.joining[gid])
    assert.is_nil(f.mirror.games[gid])
  end)

  it("lets a follower rejoin with the same board after a reload", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local board = host.record.roster[names[2]].board
    hub:removeClient(names[2])
    local again = hub:addClient(names[2], { guild = "DEA", group = "raid1" })
    again.mirror:hello(); hub:flush()
    again.mirror:join(host.record.gid); hub:flush()
    hub:advance(Host.SYNC_DELAY + 1)
    assert.are.same(board, again.mirror.games[host.record.gid].myBoard)
  end)

  it("marks the host away when the heartbeat stops and transfers cleanly", function()
    local hub, host, owner, names = guildNight(3)
    joinAll(hub, host, names)
    local gid = host.record.gid
    local f2, f3 = hub.clients[names[2]], hub.clients[names[3]]
    hub:removeClient(names[1])
    hub:advance(Mirror.CARD_TTL + 2)
    assert.is_true(f2.mirror.cards[gid].away)
    -- the owner comes back and hands the game to player 2
    local back = hub:addClient(names[1], { guild = "DEA", group = "raid1" })
    local h = back:restoreHost(owner.persisted)
    hub:advance(Host.HEARTBEAT + 1)
    assert.is_false(f2.mirror.cards[gid].away)
    assert.is_true(h:transfer(names[2]))
    hub:flush()
    assert.are.equal(names[2], f3.mirror.games[gid].owner)
    assert.are.equal(2, f3.mirror.games[gid].gen)
    local record = f2.mirror:promote(gid)
    assert.is_truthy(record)
    back.net:detachHost(gid)
    local h2 = f2:restoreHost(record)
    h2:call(11); hub:flush()
    assert.is_truthy(f3.mirror.games[gid].calls[11])
    -- the old host's stale card no longer counts
    assert.are.equal(names[2], f3.mirror.cards[gid].host)
  end)

  it("archives the final state when a follower missed the last call and the close", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local f = hub.clients[names[2]]
    local gid = host.record.gid
    local g = f.mirror.games[gid]
    -- every close event, with how many calls the follower held at that moment
    local closes = {}
    f.mirror.deps.onEvent = function(kind)
      if kind == "close" then local n = 0 for _ in pairs(g.calls) do n = n + 1 end closes[#closes + 1] = n end
    end
    local lossy = function(m) return not (m.payload:find("\31CL\31", 1, true) or m.payload:find("\31CX\31", 1, true)) end
    host:call(4); hub:flush(lossy)
    host:close(); hub:flush(lossy)          -- the closed card still arrives
    assert.are.equal("closed", g.state)
    assert.is_true(#closes >= 1, "the closed card did not close the game")
    -- the host is still there to answer: the final call comes back in a closed snapshot
    hub:advance(Host.SYNC_DELAY + 1)
    assert.is_truthy(g.calls[4], "the missed call never arrived")
    assert.are.equal(host.record.seq, g.seq)
    assert.are.equal(1, closes[#closes], "the archive was not rewritten with the final call")
  end)

  it("emits the close event when a closed snapshot is what tells it the game ended", function()
    local hub, host, owner, names = guildNight(2)
    joinAll(hub, host, names)
    local f = hub.clients[names[2]]
    local gid = host.record.gid
    local closed = 0
    f.mirror.deps.onEvent = function(kind) if kind == "close" then closed = closed + 1 end end
    host:close(); hub:flush(function() return false end)     -- nothing of the close reaches the follower
    assert.are.equal("open", f.mirror.games[gid].state)
    owner.net.deps.transport.send(Codec.encode("SN", gid, host:snapshot()), "WHISPER", names[2])
    hub:flush()
    assert.are.equal("closed", f.mirror.games[gid].state)
    assert.are.equal(1, closed)
  end)

  it("closes itself after eight idle hours and never deletes anything", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    host:call(0); hub:flush()
    hub.time = hub.time + Host.IDLE_CLOSE
    hub:advance(1)
    assert.are.equal("closed", host.record.state)
    local g = hub.clients[names[2]].mirror.games[host.record.gid]
    assert.are.equal("closed", g.state)
    assert.is_truthy(g.calls[0])
    assert.is_nil(host:call(1))
  end)
end)

describe("items", function()
  it("keeps every follower's items across a title change, with no re-request", function()
    local hub, host, owner, names = guildNight(4)
    joinAll(hub, host, names)
    local gid = host.record.gid
    local sentBefore = {}
    for i = 2, 4 do sentBefore[i] = #hub.clients[names[i]].sent end
    assert.is_true(host:setTitle("Wednesday MC"))
    hub:flush()
    hub:advance(Host.HEARTBEAT + 1)   -- a heartbeat with the new hash goes round
    for i = 2, 4 do
      local g = hub.clients[names[i]].mirror.games[gid]
      assert.are.same(host.record.items, g.items, names[i] .. " lost its items")
      assert.are.equal("Wednesday MC", g.title)
      assert.are.equal(host.record.itemsHash, g.itemsHash)
      for k = sentBefore[i] + 1, #hub.clients[names[i]].sent do
        assert.is_nil(hub.clients[names[i]].sent[k].payload:find("\31IQ\31", 1, true), names[i] .. " re-requested items")
      end
    end
  end)
end)

describe("versions", function()
  it("tells a client once that a newer release is around, and never a dev build", function()
    local hub = Hub.new()
    local old = hub:addClient("Old-Pagle", { guild = "DEA", group = "raid1", version = "v0.1.0" })
    local dev = hub:addClient("Dev-Pagle", { guild = "DEA", group = "raid1", version = "dev" })
    local seen = {}
    old.mirror.deps.onEvent = function(kind, info) if kind == "newerAddon" then seen[#seen + 1] = info.version end end
    dev.mirror.deps.onEvent = function(kind, info) if kind == "newerAddon" then error("dev build was told to update") end end
    local newer = hub:addClient("New-Pagle", { guild = "DEA", group = "raid1", version = "v0.2.0" })
    newer.mirror:hello(); hub:flush()
    newer.mirror:hello(); hub:flush()
    assert.are.same({ "v0.2.0" }, seen)
  end)

  it("refuses a join below the release's minimum version and allows an equal one", function()
    local saved = Codec.MIN_ADDON_VERSION
    Codec.MIN_ADDON_VERSION = "v0.2.0"
    local hub = Hub.new()
    hub:addClient("Owner-Pagle", { guild = "DEA", group = "raid1", version = "v0.2.0" })
    local old = hub:addClient("Old-Pagle", { guild = "DEA", group = "raid1", version = "v0.1.9" })
    local same = hub:addClient("Same-Pagle", { guild = "DEA", group = "raid1", version = "v0.2.0" })
    local dev = hub:addClient("Dev-Pagle", { guild = "DEA", group = "raid1", version = "dev" })
    local host = hub.clients["Owner-Pagle"]:host({ title = "Strict", items = items(), audience = "G" })
    host:open(); hub:flush()
    local okay, err = old.mirror:join(host.record.gid)
    assert.is_nil(okay)
    assert.is_truthy(err:find("v0.2.0", 1, true))
    assert.is_true(same.mirror:join(host.record.gid))
    assert.is_true(dev.mirror:join(host.record.gid))
    -- with no rule set, anyone joins
    Codec.MIN_ADDON_VERSION = ""
    host:heartbeat(); hub:flush()
    assert.is_true(old.mirror:join(host.record.gid))
    Codec.MIN_ADDON_VERSION = saved
  end)
end)

describe("web rules", function()
  it("refuses edits on a closed game and stamps the idle close at the deadline", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    host:call(0); hub:flush()
    local lastActivity = host.record.lastActivity
    hub.time = hub.time + Host.IDLE_CLOSE + 3600   -- noticed an hour late
    hub:advance(1)
    assert.are.equal("closed", host.record.state)
    assert.are.equal(lastActivity + Host.IDLE_CLOSE, host.record.closedAt)
    assert.is_nil(host:setTitle("Too late"))
    assert.is_nil(host:setItems(items()))
    local View = require("Core.View")
    assert.is_false(View.fromHost(host.record, names[1]).canCall)
    assert.is_false(View.fromMirror(hub.clients[names[2]].mirror.games[host.record.gid], names[2]).canCall)
  end)
end)

describe("audience checks", function()
  it("does not describe a raid game to a guildie outside the group, nor send them the squares", function()
    local hub = Hub.new()
    hub:addClient("Owner-Pagle", { guild = "DEA", group = "raid1" })
    local outsider = hub:addClient("Banker-Pagle", { guild = "DEA" })   -- guild, not grouped
    local host = hub.clients["Owner-Pagle"]:host({ title = "Raid only", items = items(), audience = "R" })
    host:open(); hub:flush()
    outsider.mirror:hello(); hub:flush()
    assert.is_nil(outsider.mirror.cards[host.record.gid])
    outsider.net:send(Codec.encode("IQ", host.record.gid, { itemsHash = host.record.itemsHash }), "WHISPER", "Owner-Pagle")
    hub:flush()
    for _, m in ipairs(outsider.received) do assert.is_nil(m.payload:find("\31IT\31", 1, true)) end
  end)

  it("shows the lobby the sender of a card, not the name inside it", function()
    local hub = Hub.new()
    local victim = hub:addClient("Victim-Pagle", { guild = "DEA", group = "raid1" })
    local liar = hub:addClient("Liar-Pagle", { guild = "DEA", group = "raid1" })
    liar.net:send(Codec.encode("GA", "lie1", { gen = 1, seq = 1, state = "open", title = "Trust me", owner = "Guildmaster-Pagle", players = 1,
      callMask = 0, lastActivity = hub:now(), itemsHash = "aaaaaa", createdAt = hub:now(), audience = "G" }), "GUILD")
    hub:flush()
    assert.are.equal("Liar-Pagle", victim.mirror:openGames()[1].owner)
  end)
end)

describe("sync back-off", function()
  it("asks less and less, and not at all while the host is away", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local gid = host.record.gid
    local f = hub.clients[names[2]]
    host:call(1)
    hub:flush(function(m) return not m.payload:find("\31CL\31", 1, true) end)
    host:call(2); hub:flush()   -- a gap now exists
    hub:removeClient(names[1])  -- and the host vanishes
    local function syncs() local n = 0 for _, m in ipairs(f.sent) do if m.payload:find("\31SQ\31", 1, true) then n = n + 1 end end return n end
    local before = syncs()
    hub:advance(Mirror.CARD_TTL)        -- host not yet marked away: a few requests, backing off
    local during = syncs() - before
    assert.is_true(during >= 2 and during <= 6, "expected a handful of backed-off requests, got " .. during)
    local atAway = syncs()
    hub:advance(300)                    -- host away: silence
    assert.are.equal(atAway, syncs(), "kept whispering an absent host")
  end)
end)

describe("closing", function()
  it("tells lobbies that never joined, answers late hellos, and expires the card", function()
    local hub, host, owner, names = guildNight(2)
    local bystander = hub:addClient("Bystander-Pagle", { guild = "DEA", group = "raid1" })
    bystander.mirror:hello(); hub:flush()
    local gid = host.record.gid
    assert.are.equal("open", bystander.mirror.cards[gid].state)
    assert.is_true(host:close()); hub:flush()
    assert.are.equal("closed", bystander.mirror.cards[gid].state)
    assert.are.equal(0, #bystander.mirror:openGames())
    -- a hello within half an hour still learns the game is closed
    local late = hub:addClient("Late-Pagle", { guild = "DEA", group = "raid1" })
    late.mirror:hello(); hub:flush()
    assert.are.equal("closed", late.mirror.cards[gid].state)
    -- and the card disappears from the lobby after the expiry
    hub.time = hub.time + Mirror.CARD_EXPIRY + 1
    hub:advance(1)
    assert.is_nil(bystander.mirror.cards[gid])
  end)

  it("closing a draft sends nothing", function()
    local hub = Hub.new()
    local c = hub:addClient("Owner-Pagle", { guild = "DEA", group = "raid1" })
    local host = c:host({ title = "Draft", items = items(), audience = "G" })
    assert.is_true(host:close())
    assert.are.equal(0, #c.sent)
  end)
end)

describe("wire times", function()
  it("replaces an absurd call time with the local clock", function()
    local hub, host, owner, names = guildNight(2)
    joinAll(hub, host, names)
    local gid = host.record.gid
    local f = hub.clients[names[2]]
    owner.net:send(Codec.encode("CL", gid, { seq = host.record.seq + 1, idx = 4, t = 2 ^ 39, winners = {} }), "GUILD")
    hub:flush()
    local t = f.mirror.games[gid].calls[4]
    assert.is_truthy(t)
    assert.is_true(math.abs(t - hub:now()) <= 1)
  end)
end)

describe("callers", function()
  it("lets a granted caller fire seven calls in ten seconds and shows pending until the host answers", function()
    local hub, host, _, names = guildNight(3)
    joinAll(hub, host, names)
    local gid = host.record.gid
    local caller = hub.clients[names[2]]
    assert.is_true(host:grant(names[2], true)); hub:flush()
    for idx = 0, 6 do assert.is_true(caller.mirror:requestCall(gid, idx, false)) end
    -- before delivery every request is pending on the caller's board
    local st = caller.mirror:myState(gid)
    local pendingCount = 0 for _ in pairs(st.pending) do pendingCount = pendingCount + 1 end
    assert.are.equal(7, pendingCount)
    hub:flush()
    for idx = 0, 6 do assert.is_truthy(host.record.calls[idx], "call " .. idx .. " was dropped") end
    st = caller.mirror:myState(gid)
    assert.is_nil(next(st.pending), "pending did not clear once the calls came back")
  end)

  it("reports a request the host never answered", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local gid = host.record.gid
    local caller = hub.clients[names[2]]
    host:grant(names[2], true); hub:flush()
    local lost = {}
    caller.mirror.deps.onEvent = function(kind, info) if kind == "callLost" then lost[#lost + 1] = info.idx end end
    caller.mirror:requestCall(gid, 5, false)
    hub:flush(function(m) return not m.payload:find("\31CQ\31", 1, true) end)   -- the request vanishes
    hub:advance(Mirror.REQUEST_TIMEOUT + 1)
    assert.are.same({ 5 }, lost)
    assert.is_nil(next(caller.mirror:myState(gid).pending))
  end)
end)

describe("flood limits", function()
  local function fakeCard(gid, owner, hub)
    return Codec.encode("GA", gid, { gen = 1, seq = 1, state = "open", title = "Spam " .. gid, owner = owner, players = 1,
      callMask = 0, lastActivity = hub:now(), itemsHash = "aaaaaa", createdAt = hub:now(), audience = "G" })
  end

  it("does not hand the host allowance to someone who merely broadcast a card", function()
    local hub = Hub.new()
    local victim = hub:addClient("Victim-Pagle", { guild = "DEA", group = "raid1" })
    local pest = hub:addClient("Pest-Pagle", { guild = "DEA", group = "raid1" })
    pest.net:send(fakeCard("spam1", "Pest-Pagle", hub), "GUILD"); hub:flush()
    assert.is_truthy(victim.mirror.cards["spam1"])
    local dropped = victim.net.stats.dropped
    for i = 2, 30 do pest.net:send(fakeCard("spam" .. i, "Pest-Pagle", hub), "GUILD") end
    hub:flush()
    assert.is_true(victim.net.stats.dropped - dropped >= 20, "pest kept the player allowance of 5 per 10 s")
    local mine = 0
    for _, c in pairs(victim.mirror.cards) do if c.host == "Pest-Pagle" then mine = mine + 1 end end
    assert.is_true(mine <= Mirror.MAX_CARDS_PER_HOST, "cards per host not capped: " .. mine)
  end)

  it("caps the lobby at MAX_CARDS and the roster, pending and events at their limits", function()
    local hub = Hub.new()
    local victim = hub:addClient("Victim-Pagle", { guild = "DEA", group = "raid1" })
    for i = 1, Mirror.MAX_CARDS + 20 do
      local name = ("Host%d-Pagle"):format(i)
      local c = hub:addClient(name, { guild = "DEA", group = "raid1" })
      c.net:send(fakeCard("g" .. i, name, hub), "GUILD")
    end
    hub:flush()
    local n = 0 for _ in pairs(victim.mirror.cards) do n = n + 1 end
    assert.is_true(n <= Mirror.MAX_CARDS, "cards not capped: " .. n)

    -- a game we joined: the host floods JDs and far-future deltas
    local hub2, host, owner, names = guildNight(2)
    joinAll(hub2, host, names)
    local gid = host.record.gid
    local f = hub2.clients[names[2]]
    for i = 1, Mirror.MAX_ROSTER + 30 do
      local seq = f.mirror.games[gid].seq + 1
      owner.net:send(Codec.encode("JD", gid, { seq = seq, name = ("Fake%d-Pagle"):format(i), board = Logic.dealBoard(hub2.rng), canCall = false }), "GUILD")
      hub2:flush()
      f.mirror.games[gid].seq = seq   -- keep the sequence moving as a real host would
    end
    local roster = 0 for _ in pairs(f.mirror.games[gid].roster) do roster = roster + 1 end
    assert.is_true(roster <= Mirror.MAX_ROSTER, "roster not capped: " .. roster)
    for i = 1, Mirror.MAX_PENDING + 50 do
      owner.net:send(Codec.encode("CL", gid, { seq = 100000 + i, idx = 1, t = hub2:now(), winners = {} }), "GUILD")
    end
    hub2:flush()
    local pending = 0 for _ in pairs(f.mirror.games[gid].pending) do pending = pending + 1 end
    assert.is_true(pending <= Mirror.MAX_PENDING, "pending not capped: " .. pending)
    assert.is_true(#f.mirror.games[gid].events <= Mirror.MAX_EVENTS)
  end)
end)

describe("capacity", function()
  it("syncs a follower in a 60-player game without the host throwing", function()
    local hub, host, _, names = guildNight(60)
    joinPaced(hub, host, names)
    local gid = host.record.gid
    local f = hub.clients[names[60]]
    local n = 0 for _ in pairs(f.mirror.games[gid].roster) do n = n + 1 end
    assert.are.equal(60, n, "follower roster incomplete")
    assert.are.equal(host.record.seq, f.mirror.games[gid].seq)
    -- a fresh sync request after a reload also completes
    hub:removeClient(names[60])
    local again = hub:addClient(names[60], { guild = "DEA", group = "raid1" })
    again.mirror:hello(); hub:flush()
    again.mirror:join(gid); hub:flush(); hub:advance(Host.SYNC_DELAY + 1)
    n = 0 for _ in pairs(again.mirror.games[gid].roster) do n = n + 1 end
    assert.are.equal(60, n, "resynced roster incomplete")
    for _, line in ipairs(hub.log) do assert.is_nil(line:find("too long", 1, true), line) end
  end)

  it("calls the last square with 70 winners at once without throwing", function()
    local hub, host, _, names = guildNight(70)
    joinPaced(hub, host, names)
    local gid = host.record.gid
    for idx = 0, 23 do
      assert.is_truthy(host:call(idx), "call " .. idx)
      hub:advance(1)
    end
    local f = hub.clients[names[2]]
    local winners = 0
    for _, e in pairs(f.mirror.games[gid].roster) do if e.bingoAt then winners = winners + 1 end end
    assert.are.equal(70, winners)
  end)

  it("drops an impossible payload instead of throwing", function()
    local hub, host = guildNight(2)
    local okay = host:emit("TI", { seq = host.record.seq + 1, title = ("x"):rep(50) })
    assert.is_false(okay)
  end)

  it("refuses joins past the player cap", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    for i = 1, Host.MAX_PLAYERS + 5 do
      local name = ("Extra%d-Pagle"):format(i)
      hub:addClient(name, { guild = "DEA", group = "raid1" })
      host.record.roster[name] = host.record.roster[name] or nil
    end
    -- fill the roster to the cap directly, then one more real join is refused
    local rng = hub.rng
    local n = 0 for _ in pairs(host.record.roster) do n = n + 1 end
    for i = n + 1, Host.MAX_PLAYERS do
      host.record.roster[("Filler%d-Pagle"):format(i)] = { board = Logic.dealBoard(rng), canCall = false, bingoAt = nil, joinedAt = hub:now() }
    end
    local extra = hub.clients["Extra1-Pagle"]
    extra.mirror:hello(); hub:flush()
    extra.mirror:join(host.record.gid); hub:flush()
    assert.is_nil(host.record.roster["Extra1-Pagle"])
  end)
end)

describe("item broadcast", function()
  it("lets a join wave use the broadcast items without a single whisper", function()
    local hub, host, _, names = guildNight(6)
    joinAll(hub, host, names)
    for i = 2, 6 do
      local c = hub.clients[names[i]]
      assert.are.same(host.record.items, c.mirror.games[host.record.gid].items, names[i])
      for _, m in ipairs(c.sent) do
        assert.is_nil(m.payload:find("\31IQ\31", 1, true), names[i] .. " asked for items")
      end
    end
    -- the host whispered no IT either: one broadcast served everyone
    local whisperedIT = 0
    for _, m in ipairs(hub.clients[names[1]].sent) do
      if m.channel == "WHISPER" and m.payload:find("\31IT\31", 1, true) then whisperedIT = whisperedIT + 1 end
    end
    assert.are.equal(0, whisperedIT)
  end)

  it("still serves items by whisper to someone who never heard the broadcast", function()
    local hub, host = guildNight(2)
    local late = hub:addClient("Late-Pagle", { guild = "DEA", group = "raid1" })
    late.mirror:hello(); hub:flush()
    late.mirror:join(host.record.gid); hub:flush(); hub:advance(Host.SYNC_DELAY + 1)
    assert.are.same(host.record.items, late.mirror.games[host.record.gid].items)
  end)
end)

describe("ownership", function()
  it("ignores a higher generation from anyone the owner did not hand the game to", function()
    local hub, host, _, names = guildNight(3)
    joinAll(hub, host, names)
    local gid = host.record.gid
    local follower = hub.clients[names[3]]
    local impostor = hub.clients[names[2]]     -- on the roster, but the host is alive
    local card = function(gen, from) return Codec.encode("GA", gid, { gen = gen, seq = 99, state = "open", title = "Hijacked",
      owner = from, players = 1, callMask = 0, lastActivity = hub:now(), itemsHash = "zzzzzz", createdAt = hub:now(), audience = "G" }) end
    impostor.net:send(card(9999, names[2]), "GUILD"); hub:flush()
    assert.are.equal(names[1], follower.mirror.games[gid].owner)
    assert.are.equal(names[1], follower.mirror.cards[gid].host)
    assert.are.equal("Tuesday MC", follower.mirror.cards[gid].title)
    -- a forged welcome with a high gen changes nothing either
    follower.mirror.joining[gid] = hub:now()
    impostor.net:send(Codec.encode("WE", gid, { seq = 1, board = Logic.dealBoard(hub.rng), canCall = true, createdAt = hub:now(),
      bingoAt = nil, itemsHash = "zzzzzz", gen = 9999 }), "WHISPER", names[3]); hub:flush()
    assert.are.equal(names[1], follower.mirror.games[gid].owner)
    assert.is_false(follower.mirror:myState(gid).canCall)
    -- and a stranger's card for a gid nobody joined cannot replace the real host's card
    local bystander = hub:addClient("Bystander-Pagle", { guild = "DEA", group = "raid1" })
    bystander.mirror:hello(); hub:flush()
    impostor.net:send(card(9999, names[2]), "GUILD"); hub:flush()
    assert.are.equal(names[1], bystander.mirror.cards[gid].host)
  end)

  it("accepts the new host after a transfer, and a roster member only once the host is silent", function()
    local hub, host, owner, names = guildNight(4)
    joinAll(hub, host, names)
    local gid = host.record.gid
    local f3, watcher = hub.clients[names[3]], hub.clients[names[4]]
    assert.is_true(host:transfer(names[2])); hub:flush()
    assert.are.equal(names[2], f3.mirror.games[gid].owner)
    -- the new host's first card, with the new gen, is accepted
    local record = hub.clients[names[2]].mirror:promote(gid)
    owner.net:detachHost(gid)
    local h2 = hub.clients[names[2]]:restoreHost(record)
    h2:heartbeat(); hub:flush()
    assert.are.equal(names[2], f3.mirror.cards[gid].host)
    assert.are.equal(2, f3.mirror.cards[gid].gen)
    -- silent-host recovery: player 3 claims gen 3 while player 2 is still heartbeating: refused
    f3.net:send(Codec.encode("GA", gid, { gen = 3, seq = h2.record.seq, state = "open", title = "Tuesday MC", owner = names[3],
      players = 3, callMask = 0, lastActivity = hub:now(), itemsHash = h2.record.itemsHash, createdAt = h2.record.createdAt, audience = "G" }), "GUILD")
    hub:flush()
    assert.are.equal(names[2], watcher.mirror.games[gid].owner)
    -- after the host goes quiet past the TTL, the same claim is accepted
    hub:removeClient(names[2])
    hub:advance(Mirror.CARD_TTL + 2)
    f3.net:send(Codec.encode("GA", gid, { gen = 3, seq = h2.record.seq, state = "open", title = "Tuesday MC", owner = names[3],
      players = 3, callMask = 0, lastActivity = hub:now(), itemsHash = h2.record.itemsHash, createdAt = h2.record.createdAt, audience = "G" }), "GUILD")
    hub:flush()
    assert.are.equal(names[3], watcher.mirror.games[gid].owner)
    assert.are.equal(names[3], watcher.mirror.cards[gid].host)
  end)
end)

describe("transfer", function()
  it("promotes the recipient of a handoff that is stuck behind a missed call", function()
    local hub, host, owner, names = guildNight(3)
    joinAll(hub, host, names)
    local gid = host.record.gid
    local newHost = hub.clients[names[2]]
    local promoted = 0
    newHost.mirror.deps.onEvent = function(kind, info) if kind == "promote" and info.gid == gid then promoted = promoted + 1 end end
    -- a call nobody hears, then the handoff: the recipient holds TR behind the gap
    host:call(4); hub:flush(function(m) return not m.payload:find("\31CL\31", 1, true) end)
    assert.is_true(host:transfer(names[2])); hub:flush()
    assert.are.equal(0, promoted)
    -- the old host answers the gap's sync request with a snapshot that names the new owner
    hub:advance(Mirror.GAP_WAIT + Host.SYNC_DELAY + 2)
    assert.are.equal(1, promoted, "the recipient never learned it is the host")
    local g = newHost.mirror.games[gid]
    assert.is_truthy(g.calls[4], "the missed call was not recovered")
    assert.are.equal(names[2], g.owner)
    assert.is_truthy(newHost.mirror:promote(gid))
    -- the handed-over host is a recovery source and nothing more: no cards, no joins
    local before = #owner.sent
    hub:advance(Host.HEARTBEAT * 2 + 2)
    for i = before + 1, #owner.sent do
      assert.is_nil(owner.sent[i].payload:find("\31GA\31", 1, true), "the old host still sends cards")
    end
    local late = hub:addClient("Late-Pagle", { guild = "DEA", group = "raid1" })
    late.net:send(Codec.encode("JN", gid, { ver = Codec.PROTOCOL }), "WHISPER", names[1]); hub:flush()
    assert.is_nil(host.record.roster["Late-Pagle"], "the old host still admits players")
  end)

  it("hands the game over: the new host is told, takes over, and the old host's stale messages are ignored", function()
    local hub, host, owner, names = guildNight(4)
    joinAll(hub, host, names)
    local gid = host.record.gid
    local newHost, watcher = hub.clients[names[2]], hub.clients[names[3]]
    local promoted = false
    newHost.mirror.deps.onEvent = function(kind, info) if kind == "promote" and info.gid == gid then promoted = true end end
    assert.is_true(host:transfer(names[2])); hub:flush()
    assert.is_true(promoted, "the new host was not told")
    -- the new host takes over from its replica; the old host becomes a follower of its own record
    local record = newHost.mirror:promote(gid)
    assert.is_truthy(record)
    newHost.mirror:forget(gid)
    local h2 = newHost:restoreHost(record)
    owner.net:detachHost(gid)
    local oldAsFollower = owner.mirror:adopt(host.record, names[1])
    assert.is_true(oldAsFollower.joined)
    assert.is_truthy(oldAsFollower.myBoard)
    h2:heartbeat(); hub:flush()
    -- the new host calls; everyone including the old host sees it
    h2:call(7); hub:flush()
    assert.is_truthy(watcher.mirror.games[gid].calls[7])
    assert.is_truthy(owner.mirror.games[gid].calls[7])
    -- the old host's stale Host object calls: nobody listens
    host:call(8); hub:flush()
    assert.is_nil(watcher.mirror.games[gid].calls[8])
    assert.is_nil(h2.record.calls[8])
    -- the old host, now a plain player, cannot call through the new host without being granted
    owner.mirror:requestCall(gid, 9, false); hub:flush()
    assert.is_nil(h2.record.calls[9])
    assert.is_true(h2:grant(names[1], true)); hub:flush()
    owner.mirror:requestCall(gid, 9, false); hub:flush()
    assert.is_truthy(h2.record.calls[9])
  end)
end)

describe("unsolicited welcomes", function()
  it("ignores a WE the player never asked for, and a late one", function()
    local hub, host, _, names = guildNight(3)
    local victim = hub.clients[names[3]]
    local gid = host.record.gid
    -- the real host whispers a WE without any JN: still refused
    local board = Logic.dealBoard(hub.rng)
    hub.clients[names[1]].net:send(Codec.encode("WE", gid, { seq = 1, board = board, canCall = false, createdAt = hub:now(),
      bingoAt = nil, itemsHash = host.record.itemsHash, gen = 1 }), "WHISPER", names[3])
    hub:flush()
    assert.is_nil(victim.mirror.games[gid])
    -- a join followed by a WE inside the window is accepted
    victim.mirror:join(gid); hub:flush()
    assert.is_truthy(victim.mirror.games[gid])
    -- a second player asks, but the answer comes too late
    local late = hub.clients[names[2]]
    late.mirror.joining[gid] = hub:now() - Mirror.JOIN_WINDOW - 1
    hub.clients[names[1]].net:send(Codec.encode("WE", gid, { seq = 1, board = board, canCall = false, createdAt = hub:now(),
      bingoAt = nil, itemsHash = host.record.itemsHash, gen = 1 }), "WHISPER", names[2])
    hub:flush()
    assert.is_nil(late.mirror.games[gid])
  end)
end)

describe("game events", function()
  it("tells both the host and the followers about calls, undos and joins", function()
    local hub, host, owner, names = guildNight(2)
    local hostEvents, followerEvents = {}, {}
    owner.hostDeps.onEvent = function(kind, info) hostEvents[#hostEvents + 1] = kind .. ":" .. tostring(info.idx or info.name) end
    hub.clients[names[2]].mirror.deps.onEvent = function(kind, info) followerEvents[#followerEvents + 1] = kind .. ":" .. tostring(info.idx or info.name) end
    joinAll(hub, host, names)
    host:call(3); hub:flush()
    host:undo(3); hub:flush()
    assert.are.same({ "join:" .. names[2], "call:3", "undo:3" }, hostEvents)
    assert.are.same({ "call:3", "undo:3" }, followerEvents)
  end)
end)

describe("new game announcements", function()
  it("fires once when a host's card is first heard, not on every heartbeat", function()
    local hub = Hub.new()
    hub:addClient("Owner-Pagle", { guild = "DEA", group = "raid1" })
    local f = hub:addClient("Dorn-Pagle", { guild = "DEA", group = "raid1" })
    local seen = {}
    f.mirror.deps.onEvent = function(kind, info) if kind == "newGame" then seen[#seen + 1] = info.title end end
    local host = hub.clients["Owner-Pagle"]:host({ title = "Tuesday MC", items = items(), audience = "G" })
    host:open(); hub:flush()
    hub:advance(Host.HEARTBEAT * 2 + 2)
    assert.are.same({ "Tuesday MC" }, seen)
  end)
end)

describe("item cache", function()
  it("ignores another host's squares announced under a legitimate game's hash", function()
    -- the first join freezes the items and broadcasts them once more; the
    -- poisoning matters to whoever joins after that
    local hub, host, _, names = guildNight(4)
    joinAll(hub, host, { names[1], names[2] })
    local f = hub.clients[names[4]]
    local stored = {}
    f.mirror.deps.storeItems = function(hash, title, set) stored[hash] = { title = title, items = set } end
    -- a stranger hosts their own game, then announces squares for it under the
    -- legitimate game's hash; the follower holds a card for both
    local stranger = hub.clients[names[3]]
    local own = stranger:host({ title = "Mine", items = items(), audience = "G" })
    assert(own:open()); hub:flush()
    local poison = {}
    for i = 1, 24 do poison[i] = "Poisoned square " .. i end
    stranger.net:send(Codec.encode("IT", own.record.gid, { itemsHash = host.record.itemsHash, title = "Tuesday MC", items = poison }), "GUILD")
    hub:flush()
    -- a later join to the legitimate game must still show its own squares
    assert(f.mirror:join(host.record.gid)); hub:flush(); hub:advance(Host.SYNC_DELAY + 1)
    assert.are.same(host.record.items, f.mirror.games[host.record.gid].items)
    -- and nothing poisoned reached the saved library
    for hash, set in pairs(stored) do
      assert.are_not.equal("Poisoned square 1", set.items[1], "poisoned set saved under " .. hash)
    end
  end)

  it("does not use a saved set whose content does not match its hash", function()
    local hub, host, _, names = guildNight(3)
    joinAll(hub, host, { names[1], names[2] })
    -- a client that heard no item broadcast: only the saved library could fill its board
    hub:removeClient(names[3])
    local f = hub:addClient(names[3], { guild = "DEA", group = "raid1" })
    local poison = {}
    for i = 1, 24 do poison[i] = "Poisoned square " .. i end
    f.mirror.deps.lookupItems = function() return { title = "Tuesday MC", items = poison } end
    f.mirror:hello(); hub:flush()
    assert(f.mirror:join(host.record.gid)); hub:flush(); hub:advance(Host.SYNC_DELAY + 1)
    assert.are.same(host.record.items, f.mirror.games[host.record.gid].items)
  end)

  it("fills items from the local cache instead of asking the host again", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local f = hub.clients[names[2]]
    local cache = { [host.record.itemsHash] = { title = "Tuesday MC", items = host.record.items } }
    hub:removeClient(names[2])
    local again = hub:addClient(names[2], { guild = "DEA", group = "raid1" })
    again.mirror.deps.lookupItems = function(hash) return cache[hash] end
    again.mirror:hello(); hub:flush()
    again.mirror:join(host.record.gid); hub:flush()
    local asked = false
    for _, m in ipairs(again.sent) do if m.payload:find("\31IQ\31", 1, true) then asked = true end end
    assert.is_false(asked)
    assert.are.same(host.record.items, again.mirror.games[host.record.gid].items)
  end)
end)

describe("identity", function()
  it("refuses a replayed hello from a single-name character whose name extends ours", function()
    local hub = Hub.new()
    local c = hub:addClient("Chad-Pagle", { guild = "DEA" })
    local other = hub:addClient("Chadwick-Pagle", { guild = "DEA" })
    c.mirror:hello()
    hub:flush()
    assert.are.equal("Chad-Pagle", c.net.deps.me)
    other.net.deps.transport.send(c.sent[1].payload, "GUILD")
    hub:flush()
    assert.are.equal("Chad-Pagle", c.net.deps.me)
    assert.are.equal("Chadwick-Pagle", c.refused)
  end)

  it("learns its server-side name from the echo of its own hello", function()
    local hub = Hub.new()
    hub:addClient("Player1-Pagle", { guild = "DEA", group = "raid1" })
    -- Forever splits "Dea One" into first name and surname; the client guesses wrong.
    local c = hub:addClient("Dea One-Two", { guild = "DEA", group = "raid1", thinksItIs = "Dea-One" })
    assert.are.equal("Dea-One", c.net.deps.me)
    c.mirror:hello()
    hub:flush()
    assert.are.equal("Dea One-Two", c.learned)
    assert.are.equal("Dea One-Two", c.net.deps.me)
    assert.are.equal("Dea One-Two", c.mirror.deps.me)
    -- and another client's hello does not confuse it
    hub.clients["Player1-Pagle"].mirror:hello()
    hub:flush()
    assert.are.equal("Dea One-Two", c.net.deps.me)
    -- a replayed copy of our own hello under a stranger's name is refused
    local replay = c.sent[1].payload
    assert.is_truthy(replay:find("\31HI\31", 1, true))
    hub.clients["Player1-Pagle"].net.deps.transport.send(replay, "GUILD")
    hub:flush()
    assert.are.equal("Dea One-Two", c.net.deps.me)
    assert.are.equal("Player1-Pagle", c.refused)
    -- a stranger whose name merely extends ours replays it: refused too
    hub:addClient("Dea Onex-Two", { guild = "DEA", group = "raid1" })
    hub.clients["Dea Onex-Two"].net.deps.transport.send(replay, "GUILD")
    hub:flush()
    assert.are.equal("Dea One-Two", c.net.deps.me)
    assert.are.equal("Dea Onex-Two", c.refused)
    -- and a genuine echo that arrives too late teaches nothing
    local late = hub:addClient("Late One-Two", { guild = "DEA", group = "raid1", thinksItIs = "Late-One" })
    late.mirror:hello()
    hub:flush(function(m) return not m.payload:find("\31HI\31", 1, true) end)   -- echo lost for now
    hub.time = hub.time + Net.ECHO_WINDOW + 1
    late.net:onMessage(late.sent[1].payload, "GUILD", "Late One-Two")
    assert.are.equal("Late-One", late.net.deps.me)
    -- joining a game now keys the roster by the real name
    local host = hub.clients["Player1-Pagle"]:host({ title = "Tuesday MC", items = items(), audience = "G" })
    host:open(); hub:flush()
    c.mirror:join(host.record.gid); hub:flush(); hub:advance(Host.SYNC_DELAY + 1)
    assert.is_truthy(host.record.roster["Dea One-Two"])
    assert.is_truthy(c.mirror:myState(host.record.gid))
  end)
end)

describe("hostile input", function()
  it("holds sends through a chat lockdown and lets them out in order when it lifts", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local owner, follower = hub.clients[names[1]], hub.clients[names[2]]
    local gid = host.record.gid
    owner.locked = true
    local sentBefore = #owner.sent
    assert(host:call(1)); assert(host:call(2))
    hub:advance(Host.HEARTBEAT * 2 + 1)   -- two heartbeats fall due meanwhile
    assert.are.equal(sentBefore, #owner.sent, "a send got through the lockdown")
    assert.is_nil(follower.mirror.games[gid].calls[1])
    local gas = 0
    for _, m in ipairs(owner.net.queue) do if m.type == "GA" then gas = gas + 1 end end
    assert.are.equal(1, gas, "stale heartbeats kept")
    assert.is_true(owner.net.stats.queued >= 3)
    owner.locked = false
    hub:advance(1)
    assert.are.equal(0, #owner.net.queue)
    assert.is_truthy(follower.mirror.games[gid].calls[1])
    assert.is_truthy(follower.mirror.games[gid].calls[2])
    local seqs = {}
    for i = sentBefore + 1, #owner.sent do
      local t, seq = owner.sent[i].payload:match("^%d+\31(%u%u)\31[^\31]*\31(%d+)")
      if t == "CL" then seqs[#seqs + 1] = tonumber(seq) end
    end
    assert.are.equal(2, #seqs)
    assert.is_true(seqs[1] < seqs[2], "calls left out of order")
  end)

  it("lets held messages out before a send made just after the lift", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local owner = hub.clients[names[1]]
    owner.locked = true
    assert(host:call(1))
    owner.locked = false
    local sentBefore = #owner.sent
    assert(host:call(2))            -- no tick in between
    local seqs = {}
    for i = sentBefore + 1, #owner.sent do
      local t, seq = owner.sent[i].payload:match("^%d+\31(%u%u)\31[^\31]*\31(%d+)")
      if t == "CL" then seqs[#seqs + 1] = tonumber(seq) end
    end
    assert.are.same({ seqs[1], seqs[2] }, seqs)
    assert.are.equal(2, #seqs, "the held call did not leave with the new one")
    assert.is_true(seqs[1] < seqs[2], "the new call overtook the held one")
    assert.are.equal(0, #owner.net.queue)
  end)

  it("keeps the newest heartbeat per destination, and a whispered one beside the broadcast", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local owner = hub.clients[names[1]]
    local gid = host.record.gid
    owner.locked = true
    hub:advance(Host.HEARTBEAT + 1)   -- a broadcast heartbeat falls due
    assert(host:call(1))
    hub:advance(Host.HEARTBEAT + 1)   -- a second, newer one
    host:heartbeat(names[2])          -- and one whispered to a player who said hello
    local broadcast, whispered = {}, {}
    for _, m in ipairs(owner.net.queue) do
      if m.type == "GA" then
        if m.target then whispered[#whispered + 1] = m else broadcast[#broadcast + 1] = m end
      end
    end
    assert.are.equal(1, #broadcast, "stale broadcast heartbeats kept, or the broadcast evicted")
    assert.are.equal(1, #whispered)
    local card = Codec.decode(broadcast[1].payload)
    assert.are.equal(host.record.seq, card.f.seq, "the kept heartbeat is not the newest")
    assert.is_true(Codec.maskHas(card.f.callMask, 1), "the kept heartbeat predates the call")
  end)

  it("collapses repeated sync requests to the newest", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local follower = hub.clients[names[2]]
    local gid = host.record.gid
    follower.locked = true
    follower.mirror:requestSync(gid, true)
    follower.mirror.games[gid].seq = follower.mirror.games[gid].seq + 1   -- pretend we moved on
    follower.mirror:requestSync(gid, true)
    local sqs = 0
    for _, m in ipairs(follower.net.queue) do if m.type == "SQ" then sqs = sqs + 1 end end
    assert.are.equal(1, sqs)
    assert.are.equal(follower.mirror.games[gid].seq, Codec.decode(follower.net.queue[#follower.net.queue].payload).f.haveSeq)
  end)

  it("still sends the rest of the held messages when one of them fails", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local owner, follower = hub.clients[names[1]], hub.clients[names[2]]
    local gid = host.record.gid
    owner.locked = true
    assert(host:call(1)); assert(host:call(2)); assert(host:call(3))
    local real = owner.net.deps.transport
    local failed = 0
    owner.net.deps.transport = { send = function(payload, ...)
      if failed == 0 and Codec.decode(payload).f.idx == 2 then failed = failed + 1; error("no player named X") end
      return real.send(payload, ...)
    end }
    owner.locked = false
    hub:advance(1)
    owner.net.deps.transport = real
    assert.are.equal(1, failed)
    assert.are.equal(0, #owner.net.queue)
    assert.is_true(owner.net.stats.dropped >= 1)
    -- the calls on either side of the failure reached the wire
    local wire = {}
    for _, m in ipairs(owner.sent) do
      local msg = Codec.decode(m.payload)
      if msg and msg.type == "CL" then wire[msg.f.idx] = true end
    end
    assert.is_true(wire[1] and wire[3] and not wire[2], "wrong calls reached the wire")
    -- the follower fills the gap the lost one left through the usual sync path
    hub:advance(Mirror.GAP_WAIT + Host.SYNC_DELAY + 2)
    assert.is_truthy(follower.mirror.games[gid].calls[2])
    assert.is_truthy(follower.mirror.games[gid].calls[3])
  end)

  it("sends a held group message on the channel the group has by the time it leaves", function()
    local hub, host, _, names = guildNight(2, "R")
    joinAll(hub, host, names)
    local owner = hub.clients[names[1]]
    owner.locked = true
    assert(host:call(1))
    -- the raid disbanded during the fight: the held call has nowhere to go
    owner.group = nil
    owner.locked = false
    local sentBefore = #owner.sent
    hub:advance(1)
    assert.are.equal(sentBefore, #owner.sent)
    assert.are.equal(0, #owner.net.queue)
    local logged = false
    for _, line in ipairs(hub.log) do if line:find("no group channel, held message dropped", 1, true) then logged = true end end
    assert.is_true(logged, "the drop was not logged")
    -- and a raid that became a party during the fight gets the held message on PARTY
    owner.group = "raid1"
    owner.locked = true
    assert(host:call(2))
    owner.net.deps.groupChannel = function() return "PARTY" end
    owner.locked = false
    hub:advance(1)
    local channel
    for _, m in ipairs(owner.sent) do
      local msg = Codec.decode(m.payload)
      if msg and msg.type == "CL" and msg.f.idx == 2 then channel = m.channel end
    end
    assert.are.equal("PARTY", channel)
  end)

  it("judges nothing away or lost during a lockdown, and everything again after it", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local owner, follower = hub.clients[names[1]], hub.clients[names[2]]
    local gid = host.record.gid
    host:grant(names[2], true); hub:flush()
    local events = {}
    follower.mirror.deps.onEvent = function(kind) events[#events + 1] = kind end
    -- the whole raid is in the encounter: host and caller alike
    owner.locked, follower.locked = true, true
    assert(follower.mirror:requestCall(gid, 3))
    hub:advance(240)
    assert.is_false(follower.mirror.cards[gid].away == true, "host judged away during the fight")
    for _, k in ipairs(events) do assert.are_not.equal("callLost", k, "a held request was reported lost") end
    assert.is_nil(host.record.calls[3], "the request got through the lockdown")
    owner.locked, follower.locked = false, false
    hub:advance(Host.SYNC_DELAY + 2)
    assert.is_truthy(host.record.calls[3], "the held request did not land")
    assert.is_truthy(follower.mirror.games[gid].calls[3])
    for _, k in ipairs(events) do assert.are_not.equal("callLost", k) end
    -- afterwards a host who really falls silent is judged away as before
    owner.locked = true   -- the host alone: pulled again while we sit outside
    hub:advance(Mirror.CARD_TTL + 2)
    assert.is_true(follower.mirror.cards[gid].away)
  end)

  it("honours the welcome to a join request that waited out a lockdown", function()
    local hub, host, _, names = guildNight(2)
    hub:flush()
    local joiner = hub.clients[names[2]]
    local gid = host.record.gid
    joiner.locked = true
    assert(joiner.mirror:join(gid))
    hub:advance(Mirror.JOIN_WINDOW * 2)   -- the fight outlasts the join window
    assert.is_nil(host.record.roster[names[2]], "the join request got through the lockdown")
    joiner.locked = false
    hub:advance(Host.SYNC_DELAY + 2)
    assert.is_truthy(host.record.roster[names[2]], "the host never heard the held join request")
    local g = joiner.mirror.games[gid]
    assert.is_true(g ~= nil and g.joined == true, "the welcome was ignored as stale")
  end)

  it("re-holds a message the chat library refused, once, and sends it next", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local owner, follower = hub.clients[names[1]], hub.clients[names[2]]
    local gid = host.record.gid
    -- the lockdown began after the poll: the client refuses the first call once
    local refusals = 0
    owner.refuse = function(payload)
      local msg = Codec.decode(payload)
      if msg and msg.type == "CL" and msg.f.idx == 1 and refusals == 0 then refusals = refusals + 1; return true end
      return false
    end
    assert(host:call(1))
    assert.are.equal(1, refusals)
    assert.are.equal(1, #owner.net.queue, "the refused call was not held")
    assert.are.equal(1, owner.net.stats.refused)
    assert.is_nil(follower.mirror.games[gid].calls[1])
    -- the next send lets it out first, in order
    assert(host:call(2))
    assert.are.equal(0, #owner.net.queue)
    local seqs = {}
    for _, m in ipairs(owner.sent) do
      local msg = Codec.decode(m.payload)
      if msg and msg.type == "CL" then seqs[#seqs + 1] = msg.f.seq end
    end
    assert.is_true(#seqs >= 2 and seqs[#seqs - 1] < seqs[#seqs], "the refused call did not leave first")
    hub:flush()
    assert.is_truthy(follower.mirror.games[gid].calls[1])
    assert.is_truthy(follower.mirror.games[gid].calls[2])
    -- a refusal that is not a lockdown, with none in force, is not re-held
    owner.refuse = function(payload) local msg = Codec.decode(payload); return msg and msg.type == "CL" and msg.f.idx == 3 end
    owner.net.deps.lockdownResult = 11
    local before = #owner.net.queue
    owner.net:onSendResult({ type = "CL", payload = "x", channel = "GUILD" }, false, 3)   -- 3 = AddonMessageThrottle
    assert.are.equal(before, #owner.net.queue)
  end)

  it("caps what it holds, dropping the oldest", function()
    local hub, _, _, names = guildNight(1)
    local owner = hub.clients[names[1]]
    owner.locked = true
    for i = 1, Net.QUEUE_MAX + 5 do
      owner.net:send(Codec.encode("SQ", "g" .. i, { haveSeq = 0 }), "WHISPER", "Someone-Pagle")
    end
    assert.are.equal(Net.QUEUE_MAX, #owner.net.queue)
    assert.are.equal(5, owner.net.stats.dropped)
    assert.are.equal("g6", owner.net.queue[1].gid)
  end)

  it("drops floods from one sender without touching the game", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local pest = hub.clients[names[2]]
    local gid = host.record.gid
    for i = 1, 50 do
      pest.net:send(Codec.encode("SQ", gid, { haveSeq = 0 }), "WHISPER", names[1])
    end
    hub:flush()
    assert.is_true(hub.clients[names[1]].net.stats.dropped >= 40)
    assert.are.equal("open", host.record.state)
  end)

  it("ignores garbage, spoofed cards and a stranger's whispers", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local gid = host.record.gid
    local follower = hub.clients[names[2]]
    local before = follower.mirror.games[gid].seq
    -- garbage on the guild channel
    hub.clients[names[1]].net.deps.transport.send("not a message at all", "GUILD")
    hub.clients[names[1]].net.deps.transport.send(("\31"):rep(50), "GUILD")
    hub.clients[names[1]].net.deps.transport.send("1\31CL\31" .. gid .. "\031999\03199\0311\31", "GUILD")
    hub:flush()
    assert.are.equal(before, follower.mirror.games[gid].seq)
    -- an impostor announces the same gid
    local imp = hub:addClient("Impostor-Pagle", { guild = "DEA", group = "raid1" })
    imp.net:send(Codec.encode("GA", gid, { gen = 1, seq = 99, state = "closed", title = "Fake", owner = "Impostor-Pagle",
      players = 1, callMask = 0, lastActivity = hub:now(), itemsHash = "zzzzzz", createdAt = hub:now(), audience = "G" }), "GUILD")
    hub:flush()
    assert.are.equal(names[1], follower.mirror.cards[gid].host)
    assert.are.equal("open", follower.mirror.games[gid].state)
    -- a whisper from someone in neither guild nor group
    local stranger = hub:addClient("Stranger-Pagle", {})
    stranger.net.deps.transport.send(Codec.encode("JN", gid, { ver = 1 }), "WHISPER", names[1])
    hub:flush()
    assert.is_nil(host.record.roster["Stranger-Pagle"])
  end)

  it("tells the user once when a newer protocol is around", function()
    local hub, _, _, names = guildNight(2)
    local f = hub.clients[names[2]]
    hub.clients[names[1]].net.deps.transport.send("9\31HI\0310\0319", "GUILD")
    hub.clients[names[1]].net.deps.transport.send("9\31HI\0310\0319", "GUILD")
    hub:flush()
    local count = 0
    for _, line in ipairs(hub.log) do if line:find("newer DEA Bingo", 1, true) and line:find(names[2], 1, true) then count = count + 1 end end
    assert.are.equal(1, count)
    assert.is_true(f.mirror.saidNewer)
  end)
end)

-- The lockdown queue in Core/Net.lua, beyond the first-cut cases above:
-- ordering across types, a lockdown that comes back, whispers, the cap, the
-- flush log, refusals during the flush, and the per-destination collapse.
describe("lockdown queue", function()
  local function wireTypes(client, from)
    local out = {}
    for i = from + 1, #client.sent do out[#out + 1] = client.sent[i].payload:match("^%d+\31(%u%u)") end
    return out
  end

  it("lets mixed held types out in queue order, the kept heartbeat last and newest", function()
    local hub, host, _, names = guildNight(3)
    joinAll(hub, host, { names[1], names[2] })      -- player 3 joins during the fight
    local owner, third = hub.clients[names[1]], hub.clients[names[3]]
    local gid = host.record.gid
    owner.locked = true
    local sentBefore = #owner.sent
    assert(third.mirror:join(gid)); hub:flush()     -- JD broadcast and WE whispered, both held
    assert(host:call(1))
    host:heartbeat()                                 -- stale by the next call
    assert(host:call(2))
    host:heartbeat()                                 -- replaces the one above, at the back
    assert.are.equal(sentBefore, #owner.sent)
    local held = {}
    for _, m in ipairs(owner.net.queue) do held[#held + 1] = m.type end
    assert.are.same({ "JD", "WE", "CL", "CL", "GA" }, held)
    owner.locked = false
    hub:advance(1)
    assert.are.same({ "JD", "WE", "CL", "CL", "GA" }, wireTypes(owner, sentBefore))
    local card = Codec.decode(owner.sent[#owner.sent].payload)
    assert.are.equal(host.record.seq, card.f.seq, "the kept heartbeat is not the newest")
    assert.is_true(Codec.maskHas(card.f.callMask, 1) and Codec.maskHas(card.f.callMask, 2), "the kept heartbeat predates a call")
    assert.is_true(third.mirror.games[gid].joined, "the held welcome was not honoured")
    assert.is_truthy(hub.clients[names[2]].mirror.games[gid].roster[names[3]])
  end)

  it("keeps everything when the lockdown comes back between ticks, and sends it all when it finally lifts", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local owner, follower = hub.clients[names[1]], hub.clients[names[2]]
    local gid = host.record.gid
    owner.locked = true
    local sentBefore = #owner.sent
    assert(host:call(1)); assert(host:call(2))
    hub:advance(2)
    owner.locked = false
    owner.locked = true              -- lifted and back before any tick saw it
    assert(host:call(3))             -- a send under the second lockdown joins the queue
    hub:advance(3)
    assert.are.equal(sentBefore, #owner.sent, "a held message left under the second lockdown")
    assert.are.equal(3, #owner.net.queue)
    assert.are.equal(0, owner.net.stats.dropped)
    assert.is_nil(follower.mirror.games[gid].calls[1])
    owner.locked = false
    hub:advance(1)
    assert.are.equal(0, #owner.net.queue)
    local seqs = {}
    for i = sentBefore + 1, #owner.sent do
      local msg = Codec.decode(owner.sent[i].payload)
      if msg.type == "CL" then seqs[#seqs + 1] = msg.f.seq end
    end
    assert.are.equal(3, #seqs)
    assert.is_true(seqs[1] < seqs[2] and seqs[2] < seqs[3], "calls left out of order")
    for idx = 1, 3 do assert.is_truthy(follower.mirror.games[gid].calls[idx]) end
  end)

  it("sends straight through when the client has no lockdown probe", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local owner, follower = hub.clients[names[1]], hub.clients[names[2]]
    owner.net.deps.inLockdown = nil
    owner.locked = true              -- would hold, if anyone asked
    local sentBefore = #owner.sent
    assert(host:call(1)); hub:flush()
    assert.are.equal(sentBefore + 1, #owner.sent)
    assert.are.equal(0, #owner.net.queue)
    assert.are.equal(0, owner.net.stats.queued)
    assert.is_truthy(follower.mirror.games[host.record.gid].calls[1])
  end)

  it("delivers a held whisper to its target after the lift, and nobody else", function()
    local hub, host, _, names = guildNight(3)
    joinAll(hub, host, names)
    local owner, f2, f3 = hub.clients[names[1]], hub.clients[names[2]], hub.clients[names[3]]
    local gid = host.record.gid
    hub:advance(Host.SYNC_COOLDOWN)                  -- past the host's per-requester cooldown from the join
    owner.locked = true
    f2.mirror:requestSync(gid, true)
    hub:advance(Host.SYNC_DELAY + 1)                 -- the host answers; the snapshot whisper is held
    local held = owner.net.queue[#owner.net.queue]
    assert.are.equal("SN", held.type)
    assert.are.equal("WHISPER", held.channel)
    assert.are.equal(names[2], held.target)
    local before2, before3 = #f2.received, #f3.received
    owner.locked = false
    hub:advance(1)
    assert.are.equal(before2 + 1, #f2.received)
    local last = f2.received[#f2.received]
    assert.are.equal("SN", last.payload:match("^%d+\31(%u%u)"))
    assert.are.equal("WHISPER", last.channel)
    assert.are.equal(before3, #f3.received, "a whisper reached someone else")
  end)

  it("drops a held whisper on arrival when its target left the guild and the group meanwhile", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local owner, follower = hub.clients[names[1]], hub.clients[names[2]]
    local gid = host.record.gid
    hub:advance(Host.SYNC_COOLDOWN)
    owner.locked = true
    follower.mirror:requestSync(gid, true)
    hub:advance(Host.SYNC_DELAY + 1)
    assert.are.equal("SN", owner.net.queue[#owner.net.queue].type)
    follower.guild, follower.group = nil, nil        -- gquit and left the raid during the fight
    local dropped, errors, seq = follower.net.stats.dropped, follower.net.stats.errors, follower.mirror.games[gid].seq
    owner.locked = false
    hub:advance(1)
    assert.are.equal(0, #owner.net.queue)
    assert.are.equal(dropped + 1, follower.net.stats.dropped, "the stranger's whisper was not dropped")
    assert.are.equal(errors, follower.net.stats.errors)
    assert.are.equal(seq, follower.mirror.games[gid].seq)
  end)

  it("logs how many held messages the lift let out, once", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local owner = hub.clients[names[1]]
    owner.locked = true
    assert(host:call(1)); assert(host:call(2)); assert(host:call(3))
    hub:advance(2)
    local function flushLines()
      local n, last = 0, nil
      for _, l in ipairs(hub.log) do
        if l:find(names[1] .. ": lockdown over, sent ", 1, true) then n = n + 1; last = l end
      end
      return n, last
    end
    assert.are.equal(0, (flushLines()), "logged a flush while still locked")
    owner.locked = false
    hub:advance(3)
    local n, last = flushLines()
    assert.are.equal(1, n, "the empty ticks after the lift logged too")
    assert.are.equal(names[1] .. ": lockdown over, sent 3 held messages", last)
  end)

  it("never sends the oldest five a full queue dropped, and sends nothing until the lift", function()
    local hub, _, _, names = guildNight(1)
    local owner = hub.clients[names[1]]
    owner.locked = true
    local sentBefore, statSent = #owner.sent, owner.net.stats.sent
    for i = 1, Net.QUEUE_MAX + 5 do
      owner.net:send(Codec.encode("SQ", "g" .. i, { haveSeq = 0 }), "WHISPER", "Someone-Pagle")
    end
    assert.are.equal(statSent, owner.net.stats.sent)
    assert.are.equal(sentBefore, #owner.sent)
    assert.are.equal(5, owner.net.stats.dropped)
    owner.locked = false
    hub:advance(1)
    assert.are.equal(0, #owner.net.queue)
    assert.are.equal(Net.QUEUE_MAX, #owner.sent - sentBefore)
    assert.are.equal(statSent + Net.QUEUE_MAX, owner.net.stats.sent)
    local gids = {}
    for i = sentBefore + 1, #owner.sent do gids[owner.sent[i].payload:match("^%d+\31%u%u\31([^\31]*)")] = true end
    for i = 1, 5 do assert.is_nil(gids["g" .. i], "dropped message g" .. i .. " reached the wire") end
    assert.is_true(gids.g6 == true and gids["g" .. (Net.QUEUE_MAX + 5)] == true)
  end)

  it("re-holds a message refused during the flush and lets it out on the next one", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local owner, follower = hub.clients[names[1]], hub.clients[names[2]]
    local gid = host.record.gid
    owner.locked = true
    assert(host:call(1)); assert(host:call(2))
    -- the lockdown bit the first call on its way out, once
    local refusals = 0
    owner.refuse = function(payload)
      local m = Codec.decode(payload)
      if m and m.type == "CL" and m.f.idx == 1 and refusals == 0 then refusals = refusals + 1; return true end
      return false
    end
    owner.locked = false
    hub:advance(1)
    assert.are.equal(1, owner.net.stats.refused)
    assert.are.equal(1, #owner.net.queue, "the refused call was not re-held")
    assert.is_true(owner.net.queue[1].requeued)
    assert.are.equal(1, Codec.decode(owner.net.queue[1].payload).f.idx)
    -- the call behind it left and waits, out of order, in the follower's pending buffer
    local onWire = false
    for _, m in ipairs(owner.sent) do local d = Codec.decode(m.payload); if d.type == "CL" and d.f.idx == 2 then onWire = true end end
    assert.is_true(onWire, "the call behind the refused one did not leave")
    assert.is_truthy(next(follower.mirror.games[gid].pending))
    assert.is_nil(follower.mirror.games[gid].calls[1])
    hub:advance(1)
    assert.are.equal(0, #owner.net.queue)
    assert.are.equal(1, owner.net.stats.refused)
    assert.is_truthy(follower.mirror.games[gid].calls[1], "the re-held call never left")
    assert.is_truthy(follower.mirror.games[gid].calls[2])
  end)

  it("gives up a message refused twice, counting both refusals; the follower recovers it by sync", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local owner, follower = hub.clients[names[1]], hub.clients[names[2]]
    local gid = host.record.gid
    owner.locked = true
    assert(host:call(1)); assert(host:call(2))
    owner.refuse = function(payload) local m = Codec.decode(payload); return m and m.type == "CL" and m.f.idx == 1 end
    owner.locked = false
    hub:advance(1)
    assert.are.equal(1, #owner.net.queue)
    hub:advance(1)
    assert.are.equal(2, owner.net.stats.refused)
    assert.are.equal(0, #owner.net.queue, "a twice-refused message was held again")
    assert.is_nil(follower.mirror.games[gid].calls[1])
    -- the loss is final as far as the queue goes: not counted as dropped, not retried
    local dropped = owner.net.stats.dropped
    hub:advance(1)
    assert.are.equal(0, #owner.net.queue)
    assert.are.equal(dropped, owner.net.stats.dropped)
    -- the gap it left is filled through the usual sync path once the library relents
    owner.refuse = nil
    hub:advance(Mirror.GAP_WAIT + Host.SYNC_DELAY + 2)
    assert.is_truthy(follower.mirror.games[gid].calls[1])
    assert.is_truthy(follower.mirror.games[gid].calls[2])
  end)

  it("collapses repeated hellos to one per channel, keeping the newest nonce", function()
    local hub, _, _, names = guildNight(2)
    local c = hub.clients[names[2]]
    c.locked = true
    c.mirror:hello(); c.mirror:hello(); c.mirror:hello()
    local his, dists = {}, {}
    for _, m in ipairs(c.net.queue) do if m.type == "HI" then his[#his + 1] = m; dists[m.dist] = true end end
    assert.are.equal(2, #his)
    assert.is_true(dists.GUILD == true and dists.RAID == true, "a channel's hello was evicted by the other's")
    for _, m in ipairs(his) do assert.are.equal(c.mirror.nonce, Codec.decode(m.payload).f.nonce) end
    c.locked = false
    hub:advance(1)
    assert.are.equal(0, #c.net.queue)
  end)

  it("keeps a sync request per host: requests for two games to two hosts both survive", function()
    local hub, host, _, names = guildNight(3)
    joinAll(hub, host, names)
    local second = hub.clients[names[3]]:host({ title = "Second game", items = items(), audience = "G" })
    assert(second:open()); hub:flush()
    local f = hub.clients[names[2]]
    assert(f.mirror:join(second.record.gid)); hub:flush(); hub:advance(Host.SYNC_DELAY + 1)
    f.locked = true
    f.mirror:requestSync(host.record.gid, true)
    f.mirror:requestSync(second.record.gid, true)
    f.mirror:requestSync(host.record.gid, true)
    local targets = {}
    for _, m in ipairs(f.net.queue) do if m.type == "SQ" then targets[m.target] = (targets[m.target] or 0) + 1 end end
    assert.are.same({ [names[1]] = 1, [names[3]] = 1 }, targets)
  end)
end)

-- The mirror's judgements around a lockdown: who is away, what is lost,
-- when to ask for a sync, and how long a welcome stays valid.
describe("lockdown and the mirror", function()
  it("judges a host away whose own lockdown holds the heartbeat, while this client is free", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local owner, follower = hub.clients[names[1]], hub.clients[names[2]]
    local gid = host.record.gid
    owner.locked = true
    hub:advance(Mirror.CARD_TTL + 2)
    assert.is_true(follower.mirror.cards[gid].away, "a silent host was not judged away")
    owner.locked = false
    hub:advance(1)
    assert.is_false(follower.mirror.cards[gid].away, "the held heartbeat did not bring the host back")
  end)

  it("reports a request still unanswered REQUEST_TIMEOUT seconds after the lift, not before", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local follower = hub.clients[names[2]]
    local gid = host.record.gid
    host:grant(names[2], true); hub:flush()
    local lost = {}
    follower.mirror.deps.onEvent = function(kind, info) if kind == "callLost" then lost[#lost + 1] = info end end
    follower.locked = true
    assert(follower.mirror:requestCall(gid, 3))
    hub:advance(60)
    assert.are.equal(0, #lost)
    hub:removeClient(names[1])            -- the host logged off during the fight
    follower.locked = false
    hub:advance(1)                        -- the request leaves, to nobody
    assert.are.equal(0, #follower.net.queue)
    hub:advance(Mirror.REQUEST_TIMEOUT - 1)
    assert.are.equal(0, #lost, "reported lost before the timeout had run after the lift")
    assert.is_truthy(follower.mirror.games[gid].outstanding[3])
    hub:advance(1)
    assert.are.equal(1, #lost)
    assert.are.equal(3, lost[1].idx)
    assert.is_nil(follower.mirror.games[gid].outstanding[3])
  end)

  it("restarts the gap clock on the lift: no sync request for GAP_WAIT-1 seconds, then one", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local follower = hub.clients[names[2]]
    local gid = host.record.gid
    assert(host:call(1))
    hub:flush(function(m) return not m.payload:find("\31CL\31", 1, true) end)   -- the call never arrives
    assert(host:call(2)); hub:flush()                                            -- the next one does: a gap
    local g = follower.mirror.games[gid]
    assert.is_truthy(g.gapSince)
    assert.is_nil(g.calls[2])
    local function sqs()
      local n = 0
      for _, t in ipairs(hub:types(follower)) do if t == "SQ" then n = n + 1 end end
      return n
    end
    local base = sqs()
    follower.locked = true
    hub:advance(20)                       -- shorter than a heartbeat, so nothing else prompts a sync
    assert.are.equal(base, sqs(), "asked for a sync during the lockdown")
    follower.locked = false
    hub:advance(1)
    hub:advance(Mirror.GAP_WAIT - 1)
    assert.are.equal(base, sqs(), "asked before GAP_WAIT had run after the lift")
    hub:advance(1)
    assert.are.equal(base + 1, sqs())
    hub:advance(Host.SYNC_DELAY + 1)
    assert.is_truthy(g.calls[1]); assert.is_truthy(g.calls[2])
  end)

  it("stamps a held join request as it leaves, and still ignores a welcome it never asked for", function()
    local hub, host, _, names = guildNight(2)
    local joiner = hub.clients[names[2]]
    local gid = host.record.gid
    joiner.locked = true
    assert(joiner.mirror:join(gid))
    local asked = joiner.mirror.joining[gid]
    hub.time = hub.time + Mirror.JOIN_WINDOW * 2     -- the fight, with no tick to notice it
    joiner.locked = false
    joiner.net:flushQueue()
    assert.are.equal(hub.time, joiner.mirror.joining[gid], "the release did not re-stamp the join")
    assert.is_true(joiner.mirror.joining[gid] - asked >= Mirror.JOIN_WINDOW * 2)
    hub:flush()
    assert.is_true(joiner.mirror.games[gid].joined)
    -- a welcome for a game this client never asked to join is refused as before
    local forged = Codec.encode("WE", "zzzz", { seq = 1, board = host.record.roster[names[1]].board, canCall = false,
                                                createdAt = hub.time, itemsHash = host.record.itemsHash, gen = 1 })
    assert.is_truthy(forged)
    hub.clients[names[1]].net.deps.transport.send(forged, "WHISPER", names[2])
    hub:flush()
    assert.is_nil(joiner.mirror.games.zzzz)
    assert.is_nil(joiner.mirror.joining.zzzz)
  end)
end)

-- Lockdowns combined with the rest of a raid night.
describe("lockdown, adversarial", function()
  it("learns its name from the echo of a hello that waited out a lockdown", function()
    local hub = Hub.new()
    hub:addClient("Player1-Pagle", { guild = "DEA", group = "raid1" })
    local c = hub:addClient("Dea One-Two", { guild = "DEA", group = "raid1", thinksItIs = "Dea-One" })
    c.locked = true                       -- a /reload mid-fight: the hello is held
    c.mirror:hello()
    hub:advance(Net.ECHO_WINDOW * 4)
    assert.is_nil(c.learned)
    c.locked = false
    hub:advance(1)
    assert.are.equal("Dea One-Two", c.learned, "the echo of the held hello taught nothing")
    assert.are.equal("Dea One-Two", c.net.deps.me)
    assert.are.equal("Dea One-Two", c.mirror.deps.me)
  end)

  it("hands a game over from inside a lockdown: the held transfer promotes the new host at the lift", function()
    local hub, host, owner, names = guildNight(3)
    joinAll(hub, host, names)
    local gid = host.record.gid
    local newHost, watcher = hub.clients[names[2]], hub.clients[names[3]]
    owner.locked = true
    assert(host:call(1))
    hub:advance(Host.HEARTBEAT + 1)       -- a heartbeat falls due, held
    assert.is_true(host:transfer(names[2]))
    -- the app's side of a transfer: the old host stops writing and follows its own record
    owner.net:detachHost(gid)
    owner.mirror:adopt(host.record, names[1])
    hub:advance(5)
    assert.are.equal(names[1], watcher.mirror.games[gid].owner, "the transfer got through the lockdown")
    local promoted = false
    newHost.mirror.deps.onEvent = function(kind, info) if kind == "promote" and info.gid == gid then promoted = true end end
    owner.locked = false
    hub:advance(1)
    assert.is_true(promoted, "the new host was not told")
    assert.are.equal(names[2], watcher.mirror.games[gid].owner)
    assert.are.equal(2, watcher.mirror.games[gid].gen)
    assert.is_truthy(watcher.mirror.games[gid].calls[1], "the call held before the transfer was lost")
    local record = newHost.mirror:promote(gid)
    assert.is_truthy(record)
    newHost.mirror:forget(gid)
    local h2 = newHost:restoreHost(record)
    h2:heartbeat(); hub:flush()
    h2:call(2); hub:flush()
    assert.is_truthy(watcher.mirror.games[gid].calls[2])
    assert.is_truthy(owner.mirror.games[gid].calls[2], "the old host does not follow the new one")
    assert.are.equal(names[2], watcher.mirror.cards[gid].host)
    assert.is_false(watcher.mirror.cards[gid].away == true)
  end)

  it("closes a game from inside a lockdown: the lobby hears the answer to its hello, then the close", function()
    local hub, host, owner, names = guildNight(3)
    joinAll(hub, host, { names[1], names[2] })
    local gid = host.record.gid
    local follower, lobby = hub.clients[names[2]], hub.clients[names[3]]
    owner.locked = true
    local sentBefore = #owner.sent
    lobby.mirror:hello(); hub:flush()     -- answered with a whispered card, held (one per channel heard)
    assert(host:close())
    owner.net:detachHost(gid)             -- the host is done with it; the queue is not
    hub:advance(5)
    assert.are.equal("open", follower.mirror.games[gid].state)
    assert.are.equal("open", lobby.mirror.cards[gid].state)
    owner.locked = false
    hub:advance(1)
    assert.are.equal(0, #owner.net.queue)
    local wire = {}
    for i = sentBefore + 1, #owner.sent do
      wire[#wire + 1] = owner.sent[i].payload:match("^%d+\31(%u%u)") .. (owner.sent[i].target and "@" or "")
    end
    assert.are.same({ "GA@", "CX", "GA" }, wire)
    assert.are.equal("closed", follower.mirror.games[gid].state)
    assert.are.equal("closed", follower.mirror.cards[gid].state)
    assert.are.equal("closed", lobby.mirror.cards[gid].state, "the stale whispered card outlived the close")
  end)

  it("lets a follower who reloaded mid-fight rejoin after the lift; the request held before is gone with it", function()
    local hub, host, _, names = guildNight(2)
    joinAll(hub, host, names)
    local gid = host.record.gid
    host:grant(names[2], true); hub:flush()
    local before = hub.clients[names[2]]
    before.locked = true
    assert(before.mirror:requestCall(gid, 3))
    hub:advance(10)
    hub:removeClient(names[2])
    local again = hub:addClient(names[2], { guild = "DEA", group = "raid1" })
    again.locked = true
    again.mirror:hello()
    hub:advance(Host.HEARTBEAT + 1)       -- the host's heartbeat reaches it: receiving is never gated
    assert.is_truthy(again.mirror.cards[gid])
    assert(again.mirror:join(gid))
    assert.are.equal(3, #again.net.queue)   -- two hellos and the join
    again.locked = false
    hub:advance(Host.SYNC_DELAY + 2)
    local g = again.mirror.games[gid]
    assert.is_true(g ~= nil and g.joined == true, "the rejoin after the reload was not honoured")
    assert.are.same(host.record.roster[names[2]].board, g.myBoard)
    assert.is_true(again.mirror:myState(gid).canCall)
    assert.is_nil(host.record.calls[3], "a request lost with the reload reached the host")
    assert.is_nil(g.outstanding[3])
  end)
end)
