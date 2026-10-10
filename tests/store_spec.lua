local stub = require("tests.wow_stub")
stub.install()

local Logic = require("Core.Logic")
local Store = require("Core.Store")

local function items()
  local t = {}
  for i = 1, 24 do t[i] = "Square number " .. i end
  return t
end

local function board()
  local b = {}
  for i = 0, 23 do b[#b + 1] = i end
  table.insert(b, 13, -1)
  return b
end

local function goodRecord()
  return {
    gid = "abc123", gen = 1, seq = 4, state = "open", title = "Tuesday MC", owner = "Dea One",
    audience = "G", createdAt = 1700000000, lastActivity = 1700000100, closedAt = nil, lastHeartbeat = 0,
    items = items(), itemsHash = "ab12cd", frozen = true,
    roster = { ["Dea One"] = { board = board(), canCall = false, bingoAt = nil, joinedAt = 1700000000 } },
    calls = { [3] = 1700000050 },
  }
end

describe("saved records", function()
  it("accepts a complete record", function()
    assert.is_true(Store.isRecord(goodRecord()))
  end)

  it("rejects every field the host would later choke on", function()
    local cases = {
      function(r) r.lastActivity = nil end,
      function(r) r.createdAt = "yesterday" end,
      function(r) r.itemsHash = "nope" end,
      function(r) r.audience = "X" end,
      function(r) r.seq = 1.5 end,
      function(r) r.gen = 0 end,
      function(r) r.owner = "bad|name" end,
      function(r) r.title = ("x"):rep(41) end,
      function(r) r.state = "paused" end,
      function(r) r.roster["Dea One"].canCall = "yes" end,
      function(r) r.roster["Dea One"].bingoAt = "now" end,
      function(r) r.roster["Dea One"].board = { 1, 2, 3 } end,
      function(r) r.calls[3] = "soon" end,
      function(r) r.calls[24] = 1700000000 end,
      function(r) r.calls[2.5] = 1700000000 end,
      function(r) r.items[5] = r.items[4] end,
    }
    for i, mutate in ipairs(cases) do
      local r = goodRecord()
      mutate(r)
      assert.is_false(Store.isRecord(r), "case " .. i .. " should be rejected")
    end
  end)

  it("coerces the fields the host writes but never reads from the wire", function()
    local r = goodRecord()
    r.lastHeartbeat = "x"; r.frozen = "yes"
    assert.is_true(Store.isRecord(r))
    assert.are.equal(0, r.lastHeartbeat)
    assert.are.equal(true, r.frozen)
  end)

  it("restores only open records for this character, matching the name loosely", function()
    local s = Store.new({})
    local a = goodRecord(); a.gid = "a"; a.owner = "Dea One-ClassicBetaPvE2"
    local b = goodRecord(); b.gid = "b"; b.owner = "Dea Two"
    local c = goodRecord(); c.gid = "c"; c.state = "closed"
    local d = goodRecord(); d.gid = "d"; d.lastActivity = nil
    for _, r in ipairs({ a, b, c, d }) do s:saveHosted(r) end
    local mine = s:openHosted("Dea One", function(owner, me) return Logic.sameCharacter(owner, me) end)
    assert.are.equal(1, #mine)
    assert.are.equal("a", mine[1].gid)
    assert.are.equal(0, #s:openHosted("Nobody"))
  end)

  it("also restores a recently closed record, so it can keep answering sync requests", function()
    local s = Store.new({})
    local a = goodRecord(); a.gid = "a"
    local recent = goodRecord(); recent.gid = "recent"; recent.state = "closed"; recent.closedAt = 1700000000 - 60
    local old = goodRecord(); old.gid = "old"; old.state = "closed"; old.closedAt = 1700000000 - 7200
    for _, r in ipairs({ a, recent, old }) do s:saveHosted(r) end
    local mine = s:openHosted("Dea One", nil, 1700000000 - 1800)
    local gids = {}
    for _, r in ipairs(mine) do gids[r.gid] = true end
    assert.is_true(gids.a); assert.is_true(gids.recent); assert.is_nil(gids.old)
    -- without a window, closed records stay out
    assert.are.equal(1, #s:openHosted("Dea One"))
  end)

  it("skips history entries with broken boards or calls", function()
    local s = Store.new({})
    s:addHistory({ gid = "h1", title = "Good", roster = { ["Dea One"] = { board = board() } }, calls = { [1] = 1700000000 }, items = items() })
    s:addHistory({ gid = "h2", title = "Bad board", roster = { ["Dea One"] = { board = { 1, 2 } } }, calls = {} })
    s:addHistory({ gid = "h3", title = "Bad call", roster = {}, calls = { [99] = 1 } })
    s:addHistory({ gid = "h4", title = 42, roster = {}, calls = {} })
    local kept = s:history()
    assert.are.equal(1, #kept)
    assert.are.equal("h1", kept[1].gid)
  end)

  it("keeps at most fifty item sets, dropping the least recently used", function()
    local s = Store.new({})
    for i = 1, 60 do
      local set = items(); set[1] = "Set " .. i
      s:saveItemSet(("h%02d"):format(i), "Night " .. i, set, 1700000000 + i)
    end
    local sets = s:itemSets()
    assert.are.equal(Store.ITEM_SETS_MAX, #sets)
    assert.are.equal("Night 60", sets[1].title)
    assert.is_nil(s.db.itemSets.h01)
  end)

  it("runs schema migrations from the stored version up to the current one", function()
    local ran = {}
    Store.migrations[0] = function(db) ran[#ran + 1] = 0; db.migratedFrom0 = true end
    local s = Store.new({ schema = 0 })
    Store.migrations[0] = nil
    assert.are.same({ 0 }, ran)
    assert.is_true(s.db.migratedFrom0)
    assert.are.equal(Store.SCHEMA, s.db.schema)
    -- a database already current runs nothing
    ran = {}
    Store.migrations[0] = function() ran[#ran + 1] = 0 end
    Store.new({ schema = Store.SCHEMA })
    Store.migrations[0] = nil
    assert.are.same({}, ran)
  end)

  it("validates a saved window position before it reaches SetPoint", function()
    assert.is_true(Store.isPosition({ point = "CENTER", relPoint = "CENTER", x = 10, y = -20, w = 900, h = 600 }))
    assert.is_false(Store.isPosition({ point = "SOMEWHERE", x = 0, y = 0 }))
    assert.is_false(Store.isPosition({ point = "CENTER", x = "a", y = 0 }))
    assert.is_false(Store.isPosition({ point = "CENTER", x = 0, y = 0, w = 10 }))
    assert.is_false(Store.isPosition("nope"))
  end)
end)
