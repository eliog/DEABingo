local stub = require("tests.wow_stub")
stub.install()

local Logic = require("Core.Logic")
local Codec = require("Core.Codec")
local F = require("tests.fixtures.web_fixtures")

local board = F.deals[1].board

describe("codec", function()
  it("round-trips every message type", function()
    local samples = {
      HI = { ver = 1, nonce = 4242 },
      GA = { gen = 1, seq = 7, state = "open", title = "Tuesday MC", owner = "Thalgrim-Pagle", players = 12,
             callMask = 2 ^ 3 + 2 ^ 20, lastActivity = 1700000000, itemsHash = "ab12cd", createdAt = 1699999000, audience = "G" },
      JN = { ver = 1 },
      WE = { seq = 3, board = board, canCall = false, createdAt = 1699999000, bingoAt = nil, itemsHash = "ab12cd", gen = 1 },
      JD = { seq = 4, name = "Dorn-Pagle", board = board, canCall = true, bingoAt = 1700000001 },
      IT = { itemsHash = "ab12cd", title = "Tuesday MC", items = (function() local t = {} for i = 1, 24 do t[i] = "Item " .. i end return t end)() },
      IQ = { itemsHash = "ab12cd" },
      CQ = { idx = 5, undo = false, nonce = 12345 },
      CL = { seq = 5, idx = 5, t = 1700000002, winners = { "Dorn-Pagle", "Thalgrim-Pagle" } },
      UN = { seq = 6, idx = 5, t = 1700000003, revoked = {} },
      GR = { seq = 7, name = "Dorn-Pagle", canCall = true },
      TI = { seq = 8, title = "Wednesday MC" },
      CX = { seq = 9, closedAt = 1700000004 },
      TR = { seq = 10, gen = 2, newHost = "Dorn-Pagle" },
      SQ = { haveSeq = 4 },
      SN = { gen = 1, seq = 10, state = "open", title = "Tuesday MC", owner = "Thalgrim-Pagle", createdAt = 1699999000,
             lastActivity = 1700000000, closedAt = nil, itemsHash = "ab12cd", audience = "R",
             roster = { { name = "Dorn-Pagle", board = board, canCall = false, bingoAt = nil },
                        { name = "Thalgrim-Pagle", board = F.deals[2].board, canCall = true, bingoAt = 1700000002 } },
             calls = { { idx = 0, t = 1700000000 }, { idx = 23, t = 1700000001 } }, part = 1, of = 1 },
      NV = { ver = 2 },
    }
    for msgType, fields in pairs(samples) do
      local wire, err = Codec.encode(msgType, "abc12-x", fields)
      assert.is_truthy(wire, msgType .. ": " .. tostring(err))
      local msg, why = Codec.decode(wire)
      assert.is_truthy(msg, msgType .. ": " .. tostring(why))
      assert.are.equal(msgType, msg.type)
      assert.are.equal("abc12-x", msg.gid)
      assert.are.same(fields, msg.f, msgType)
    end
  end)

  it("keeps a full items message inside the payload cap", function()
    local items = {}
    for i = 1, 24 do items[i] = ("x"):rep(58) .. ("%02d"):format(i) end
    local wire = Codec.encode("IT", "abc", { itemsHash = "ab12cd", title = ("t"):rep(40), items = items })
    assert.is_truthy(wire)
    assert.is_true(#wire < Codec.MAX_PAYLOAD)
  end)

  it("rejects what does not fit the schema", function()
    local bad = {
      { "CL", { seq = 1, idx = 24, t = 1, winners = {} } },                 -- idx out of range
      { "CL", { seq = 1, idx = 1.5, t = 1, winners = {} } },                -- float
      { "CL", { seq = 1, idx = 1, t = -1, winners = {} } },                 -- negative time
      { "CL", { seq = 1, idx = 1, t = 1, winners = { "bad|name" } } },      -- a pipe in a name
      { "GR", { seq = 1, name = "Dorn-Pagle", canCall = "yes" } },          -- not a flag
      { "TI", { seq = 1, title = ("x"):rep(41) } },                         -- too long
      { "TI", { seq = 1, title = " padded " } },                            -- not clean
      { "TI", { seq = 1, title = "has|cffbad" } },                          -- clean but then escape: cleanText keeps |, so check below
      { "JD", { seq = 1, name = "Dorn-Pagle", board = { 1, 2, 3 }, canCall = false } },
      { "IQ", { itemsHash = "short" } },
    }
    for i, case in ipairs(bad) do
      local wire = Codec.encode(case[1], "g", case[2])
      if case[1] == "TI" and case[2].title == "has|cffbad" then
        -- a pipe is legal text on the wire; the display layer escapes it
        assert.is_truthy(wire)
      else
        assert.is_nil(wire, "case " .. i .. " should not encode")
      end
    end
  end)

  it("drops malformed wire strings without throwing", function()
    local wires = {
      "", "1", "1\31CL", "1\31CL\31g", "1\31CL\31g\31x",
      "1\31ZZ\31g\0311", "0\31HI\31g\0311", "abc\31HI\31g\0311",
      "1\31CL\31g\0311\0315\0311\31Dorn-Pagle\31extra",
      "1\31CL\31bad gid!\0311\0315\0311\31",
      ("1\31TI\31g\0311\31" .. ("x"):rep(5000)),
      42, nil, {},
    }
    for _, w in ipairs(wires) do
      local msg = Codec.decode(w)
      assert.is_nil(msg, tostring(w):sub(1, 20))
    end
  end)

  it("reports a newer protocol instead of parsing it", function()
    local msg, reason, info = Codec.decode("7\31HI\31g\0317")
    assert.is_nil(msg)
    assert.are.equal("newer", reason)
    assert.are.equal(7, info.v)
  end)

  it("builds and reads call masks", function()
    local calls = { [0] = 1, [5] = 2, [23] = 3 }
    local mask = Codec.callMask(calls)
    assert.is_true(Codec.maskHas(mask, 0))
    assert.is_true(Codec.maskHas(mask, 5))
    assert.is_true(Codec.maskHas(mask, 23))
    assert.is_false(Codec.maskHas(mask, 1))
    assert.are.equal(0, Codec.callMask({}))
  end)

  it("hashes item sets stably and distinctly", function()
    local items = {}
    for i = 1, 24 do items[i] = "Item " .. i end
    local a = Codec.itemsHash("T", items)
    assert.are.equal(6, #a)
    assert.are.equal(a, Codec.itemsHash("T", items))
    items[3] = "Different"
    assert.are_not.equal(a, Codec.itemsHash("T", items))
    assert.are_not.equal(a, Codec.itemsHash("U", items))
  end)

  it("accepts only Name-Realm identities", function()
    assert.is_true(Codec.isName("Thalgrim-Pagle"))
    assert.is_true(Codec.isName("Thalgrim-Area52"))
    assert.is_true(Codec.isName("Thalgrim"))              -- realmless rulesets send bare names
    assert.is_true(Codec.isName("Dea One"))
    assert.is_false(Codec.isName(""))
    assert.is_false(Codec.isName("Dea|One"))
    assert.is_true(Codec.isName("Dea One-Two"))            -- Forever allows two-word names
    assert.is_false(Codec.isName(" Dea One-Two"))
    assert.is_false(Codec.isName("Dea  One-Two"))
    assert.is_false(Codec.isName("Dea One-Two Realm"))
    assert.is_false(Codec.isName("-Pagle"))
    assert.is_false(Codec.isName("Thal|grim-Pagle"))
    assert.is_false(Codec.isName(("x"):rep(70) .. "-Pagle"))
  end)
end)
