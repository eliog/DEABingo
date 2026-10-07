local stub = require("tests.wow_stub")
stub.install()

local Logic = require("Core.Logic")
local Codec = require("Core.Codec")
local Host = require("Core.Host")
local Mirror = require("Core.Mirror")
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

describe("item cache", function()
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
    -- joining a game now keys the roster by the real name
    local host = hub.clients["Player1-Pagle"]:host({ title = "Tuesday MC", items = items(), audience = "G" })
    host:open(); hub:flush()
    c.mirror:join(host.record.gid); hub:flush(); hub:advance(Host.SYNC_DELAY + 1)
    assert.is_truthy(host.record.roster["Dea One-Two"])
    assert.is_truthy(c.mirror:myState(host.record.gid))
  end)
end)

describe("hostile input", function()
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
