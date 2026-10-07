local stub = require("tests.wow_stub")
stub.install()

local Host = require("Core.Host")
local View = require("Core.View")
local Hub = require("tests.hub")

local function items()
  local t = {}
  for i = 1, 24 do t[i] = "Square number " .. i end
  return t
end

describe("view model", function()
  it("shortens names for display only", function()
    assert.are.equal("Dea One", View.shortName("Dea One-ClassicBetaPvE2"))
    assert.are.equal("Thalgrim", View.shortName("Thalgrim-Pagle"))
    assert.are.equal("Dea One", View.shortName("Dea One"))
    assert.are.equal("", View.shortName(nil))
  end)

  it("builds the same picture from the host and from a follower", function()
    local hub = Hub.new()
    local names = { "Owner-Pagle", "Dorn-Pagle", "Jaina-Pagle" }
    for _, n in ipairs(names) do hub:addClient(n, { guild = "DEA", group = "raid1" }) end
    local host = hub.clients[names[1]]:host({ title = "Tuesday MC", items = items(), audience = "G" })
    host:open(); hub:flush()
    for i = 2, 3 do hub.clients[names[i]].mirror:join(host.record.gid) end
    hub:flush(); hub:advance(Host.SYNC_DELAY + 1)

    local board = host.record.roster["Dorn-Pagle"].board
    for p = 1, 5 do host:call(board[p]) end
    hub:flush()

    local hv = View.fromHost(host.record, "Owner-Pagle")
    local dornGame = hub.clients["Dorn-Pagle"].mirror.games[host.record.gid]
    local dv = View.fromMirror(dornGame, "Dorn-Pagle", hub.clients["Dorn-Pagle"].mirror.cards[host.record.gid])

    assert.is_true(hv.isHost); assert.is_false(dv.isHost)
    assert.is_true(hv.canCall); assert.is_false(dv.canCall)
    assert.are.equal(5, hv.callCount); assert.are.equal(5, dv.callCount)
    assert.are.equal(3, hv.players); assert.are.equal(3, dv.players)
    assert.are.same(hv.items, dv.items)
    assert.are.equal("Tuesday MC", dv.title)
    assert.is_true(dv.hasBingo)
    assert.are.equal(5, dv.bestLine)
    assert.are.equal(0, dv.away)
    assert.is_truthy(dv.myBingoAt)
    -- Dorn tops both standings with rank 1
    assert.are.equal("Dorn-Pagle", hv.standings[1].name)
    assert.are.equal(1, hv.standings[1].rank)
    assert.are.equal("Dorn-Pagle", dv.standings[1].name)
    assert.is_true(dv.standings[1].isMe)
    assert.is_nil(hv.standings[2].rank)
    -- the call log is newest first and carries the text
    assert.are.equal(5, #dv.calls)
    assert.is_truthy(dv.calls[1].text)
    assert.is_true(dv.calls[1].t >= dv.calls[5].t)
  end)

  it("builds a read-only view from a history entry", function()
    local board = {}
    for i = 0, 23 do board[#board + 1] = i end
    table.insert(board, 13, -1)
    local entry = { gid = "h1", title = "Old night", owner = "Owner-Pagle", closedAt = 1700000000,
      items = items(), roster = { ["Owner-Pagle"] = { board = board, canCall = false, bingoAt = 1699999999 } }, calls = { [0] = 1699999990 } }
    local v = View.fromHistory(entry, "Owner-Pagle")
    assert.is_true(v.history)
    assert.are.equal("closed", v.state)
    assert.is_false(v.canCall)
    assert.are.equal(1, v.callCount)
    assert.are.equal(1, v.standings[1].rank)
    assert.are.equal("Square number 1", v.calls[1].text)
  end)

  it("lists hosted games first in the lobby and skips the host's own card", function()
    local cards = {
      a = { state = "open", host = "Other-Pagle", title = "Zeta", players = 3, callCount = 2, audience = "G" },
      b = { state = "closed", host = "Other-Pagle", title = "Old", players = 1, callCount = 0 },
      c = { state = "open", host = "Me-Pagle", title = "Mine as card", players = 1, callCount = 0 },
    }
    local hosted = { c = { state = "open", title = "Mine", owner = "Me-Pagle", roster = { ["Me-Pagle"] = {} }, calls = { [1] = 1 }, audience = "G" } }
    local rows = View.lobby(cards, hosted, "Me-Pagle")
    assert.are.equal(2, #rows)
    assert.is_true(rows[1].mine)
    assert.are.equal("Mine", rows[1].title)
    assert.are.equal(1, rows[1].calls)
    assert.are.equal("Zeta", rows[2].title)
    assert.are.equal("Other", rows[2].ownerShort)
  end)
end)
