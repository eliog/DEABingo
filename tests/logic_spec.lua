local stub = require("tests.wow_stub")
stub.install()

local Logic = require("Core.Logic")
local F = require("tests.fixtures.web_fixtures")

-- The fixtures use 0-based positions; Lua boards are 1-based.
local function toSet(list)
  local set = {}
  for _, v in ipairs(list) do set[v] = true end
  return set
end
local function sortedKeys(set, offset)
  local out = {}
  for k in pairs(set) do out[#out + 1] = k + (offset or 0) end
  table.sort(out)
  return out
end

describe("board dealing", function()
  it("replays every recorded deal from the web game draw for draw", function()
    for _, deal in ipairs(F.deals) do
      local rng = stub.replayRng(deal.draws)
      local board = Logic.dealBoard(rng)
      assert.are.same(deal.board, board, "seed " .. deal.seed)
      assert.are.equal(#deal.draws, rng.used(), "seed " .. deal.seed .. " draw count")
    end
  end)

  it("deals 25 cells with a free centre and every item exactly once", function()
    for _, deal in ipairs(F.deals) do
      local board = Logic.dealBoard(stub.replayRng(deal.draws))
      assert.are.equal(Logic.BOARD_CELLS, #board)
      assert.are.equal(Logic.FREE, board[Logic.FREE_CELL])
      assert.is_true(Logic.isValidBoard(board))
    end
  end)

  it("deals valid boards from math.random too", function()
    local rng = { int = function(_, n) return math.random(0, n - 1) end }
    for _ = 1, 50 do assert.is_true(Logic.isValidBoard(Logic.dealBoard(rng))) end
  end)

  it("forces a difference when the rng is stuck, in the same order as the web", function()
    local stuck = { int = function() return 0 end }
    local first = Logic.dealUniqueBoard(stuck, {})
    local second = Logic.dealUniqueBoard(stuck, { first })
    local third = Logic.dealUniqueBoard(stuck, { first, second })
    assert.are.same(F.cases.stuck.first, first)
    assert.are.same(F.cases.stuck.second, second)
    assert.are.same(F.cases.stuck.third, third)
    for _, b in ipairs({ first, second, third }) do assert.is_true(Logic.isValidBoard(b)) end
  end)

  it("never deals a board another player already holds", function()
    local taken = {}
    local rng = { int = function(_, n) return math.random(0, n - 1) end }
    for _ = 1, 30 do
      local board = Logic.dealUniqueBoard(rng, taken)
      assert.is_true(Logic.isValidBoard(board))
      for _, t in ipairs(taken) do assert.are_not.equal(Logic.boardKey(t), Logic.boardKey(board)) end
      taken[#taken + 1] = board
    end
  end)

  it("round-trips through the 24-letter wire form", function()
    for _, deal in ipairs(F.deals) do
      local s = Logic.encodeBoard(deal.board)
      assert.are.equal(24, #s)
      assert.is_truthy(s:match("^[A-X]+$"))
      assert.are.same(deal.board, Logic.decodeBoard(s))
    end
    assert.is_nil(Logic.decodeBoard("AAAAAAAAAAAAAAAAAAAAAAAA"))
    assert.is_nil(Logic.decodeBoard("ABC"))
    assert.is_nil(Logic.decodeBoard(42))
  end)
end)

describe("lines and marks", function()
  it("has the same twelve lines as the web", function()
    assert.are.equal(12, #Logic.LINES)
    for i, line in ipairs(F.cases.lines) do
      local ours = {}
      for k, p in ipairs(Logic.LINES[i]) do ours[k] = p - 1 end
      assert.are.same(line, ours, "line " .. i)
    end
  end)

  it("counts the free centre as marked with nothing called", function()
    local board = F.deals[4].board
    local none = {}
    assert.is_true(Logic.isMarked(board, Logic.FREE_CELL, none))
    assert.are.equal(1, Logic.markCount(board, none))
    assert.is_false(Logic.hasBingo(board, none))
  end)

  it("reports exactly the winning row's cells", function()
    local c = F.cases.topRow
    local called = toSet(c.called)
    assert.is_true(Logic.hasBingo(c.board, called))
    assert.are.same(c.winning, sortedKeys(Logic.winningCells(c.board, called), -1))
  end)

  it("wins a diagonal with four items because the centre is free", function()
    local c = F.cases.diagonal
    assert.are.equal(4, #c.called)
    assert.are.equal(c.bingo, Logic.hasBingo(c.board, toSet(c.called)))
  end)

  it("does not call four of five a bingo", function()
    local board = F.deals[10].board
    local called = toSet({ board[1], board[2], board[3], board[4] })
    assert.is_false(Logic.hasBingo(board, called))
    assert.are.same({}, Logic.winningCells(board, called))
  end)

  it("marks the whole board when every item is called", function()
    local all = {}
    for i = 0, Logic.ITEM_COUNT - 1 do all[i] = true end
    assert.are.equal(Logic.BOARD_CELLS, Logic.markCount(F.deals[14].board, all))
  end)

  it("gives every player the same mark count and separates them by bestLine", function()
    local c = F.cases.marks
    local called = toSet(c.called)
    for i, board in ipairs(c.boards) do
      assert.are.equal(c.markCounts[i], Logic.markCount(board, called))
      assert.are.equal(#c.called + 1, Logic.markCount(board, called))
      assert.are.equal(c.bestLines[i], Logic.bestLineOf(board, called))
    end
  end)

  it("bestLineOf counts the fullest line including the free centre", function()
    local c = F.cases.bestLine
    assert.are.equal(c.empty, Logic.bestLineOf(c.board, {}))
    assert.are.equal(c.withDiag, Logic.bestLineOf(c.board, toSet(c.diag)))
  end)

  it("rejects boards that could not have been dealt", function()
    local good = F.deals[3].board
    local short = { unpack(good, 1, 24) }
    assert.is_false(Logic.isValidBoard(short))
    local noFree = { unpack(good) }
    noFree[Logic.FREE_CELL] = 0
    assert.is_false(Logic.isValidBoard(noFree))
    local dup = { unpack(good) }
    dup[1] = dup[2]
    assert.is_false(Logic.isValidBoard(dup))
    local float = { unpack(good) }
    float[1] = 1.5
    assert.is_false(Logic.isValidBoard(float))
  end)
end)

describe("text", function()
  it("agrees with the web's cleanText on the recorded cases", function()
    for _, c in ipairs(F.textCases) do
      assert.are.equal(c.text, Logic.cleanText(c.raw), "text: " .. c.raw)
      assert.are.equal(c.name, Logic.cleanText(c.raw, "name"), "name: " .. c.raw)
      assert.are.equal(c.key, Logic.charNameKey(c.raw), "key: " .. c.raw)
    end
  end)

  it("drops malformed UTF-8 bytes instead of passing them on", function()
    assert.are.equal("ab", Logic.cleanText("a\255b"))
    assert.are.equal("ab", Logic.cleanText("a\226\128b"))   -- truncated sequence
  end)

  it("parses and orders addon versions, treating dev builds as incomparable", function()
    assert.are.same({ 0, 1, 1, pre = "beta1" }, Logic.parseVersion("v0.1.1-beta1"))
    assert.are.same({ 1, 2, 3 }, Logic.parseVersion("1.2.3"))
    assert.is_nil(Logic.parseVersion("dev"))
    assert.is_nil(Logic.parseVersion("@project-version@"))
    assert.are.equal(-1, Logic.compareVersions("v0.1.0", "v0.1.1"))
    assert.are.equal(1, Logic.compareVersions("v0.2.0", "v0.1.9"))
    assert.are.equal(0, Logic.compareVersions("v0.1.1", "0.1.1"))
    assert.are.equal(-1, Logic.compareVersions("v0.1.1-beta1", "v0.1.1"))
    assert.are.equal(1, Logic.compareVersions("v0.1.1", "v0.1.1-beta1"))
    assert.are.equal(-1, Logic.compareVersions("v0.1.1-beta1", "v0.1.1-beta2"))
    assert.is_nil(Logic.compareVersions("dev", "v0.1.1"))
    assert.is_nil(Logic.compareVersions("v0.1.1", nil))
  end)

  it("recognises the same character across realm, case and surname forms", function()
    assert.is_true(Logic.sameCharacter("Dea One-ClassicBetaPvE2", "Dea One"))
    assert.is_true(Logic.sameCharacter("dea one", "Dea One-Two"))
    assert.is_true(Logic.sameCharacter("Dea One", "Dea"))          -- client reported the first name only
    assert.is_true(Logic.sameCharacter("Thalgrim-Pagle", "Thalgrim"))
    assert.is_false(Logic.sameCharacter("Dea Two", "Dea One"))
    assert.is_false(Logic.sameCharacter("Impostor-Pagle", "Dea One"))
    assert.is_false(Logic.sameCharacter("", "Dea One"))
    assert.is_false(Logic.sameCharacter(nil, "Dea One"))
  end)

  it("does not mistake a name that merely extends ours for the same character", function()
    -- a surname that is a longer word
    assert.is_false(Logic.sameCharacter("Dea One", "Dea Onex"))
    assert.is_false(Logic.sameCharacter("Dea One-Two", "Dea Oneida-Two"))
    -- single names: a prefix is a different person
    assert.is_false(Logic.sameCharacter("Chad", "Chadwick"))
    assert.is_false(Logic.sameCharacter("Chadwick-Pagle", "Chad"))
    assert.is_false(Logic.sameCharacter("Thalgrim", "Thal"))
    -- a single letter is nobody's name
    assert.is_false(Logic.sameCharacter("D", "Dea One"))
    assert.is_false(Logic.sameCharacter("Dea One", "D"))
    -- a different first name with the same surname start
    assert.is_false(Logic.sameCharacter("Deal One", "Dea One"))
    -- the first-name-only client still matches its own full name, and only that
    assert.is_true(Logic.sameCharacter("Dea", "Dea One-Two"))
    assert.is_false(Logic.sameCharacter("De", "Dea One-Two"))
    assert.is_false(Logic.sameCharacter("Dea", "Deanna One"))
  end)

  it("accepts a server-stamped name as our identity only when it is ours exactly", function()
    -- realm and case do not matter
    assert.is_true(Logic.sameIdentity("Dea One-ClassicBetaPvE2", "Dea One"))
    assert.is_true(Logic.sameIdentity("dea one", "Dea One-Two"))
    assert.is_true(Logic.sameIdentity("Thalgrim-Pagle", "Thalgrim"))
    -- spaces do: a different character can own the squashed spelling
    assert.is_false(Logic.sameIdentity("Deaone", "Dea One"))
    assert.is_false(Logic.sameIdentity("Dea One", "Deaone-Two"))
    -- a first name alone proves nothing, in either direction
    assert.is_false(Logic.sameIdentity("Dea Two", "Dea"))
    assert.is_false(Logic.sameIdentity("Dea One", "Dea"))
    assert.is_false(Logic.sameIdentity("Dea", "Dea One"))
    -- and the prefixes sameCharacter already refuses stay refused
    assert.is_false(Logic.sameIdentity("Dea Onex", "Dea One"))
    assert.is_false(Logic.sameIdentity("Chadwick", "Chad"))
    assert.is_false(Logic.sameIdentity("", "Dea One"))
    assert.is_false(Logic.sameIdentity(nil, "Dea One"))
  end)

  it("requires the local realm when authorizing a realm-qualified identity", function()
    assert.is_true(Logic.sameIdentity("Thalgrim-Pagle", "Thalgrim", "Pagle"))
    assert.is_true(Logic.sameIdentity("Thalgrim", "thalgrim-pagle", "Pagle"))
    assert.is_true(Logic.sameIdentity("Thalgrim-Pagle", "thalgrim-PAGLE", "Pagle"))
    assert.is_true(Logic.sameIdentity("Thalgrim-ClassicBetaPvE2", "Thalgrim", "Classic Beta PvE 2"))
    assert.is_false(Logic.sameIdentity("Thalgrim-OtherRealm", "Thalgrim", "Pagle"))
    assert.is_false(Logic.sameIdentity("Thalgrim-OtherRealm", "Thalgrim-Pagle", "Pagle"))
    assert.is_false(Logic.sameIdentity("Thalgrim-Pagle", "Thalgrim-OtherRealm", "Pagle"))
    assert.is_false(Logic.sameIdentity("Thalgrim-OtherRealm", "Thalgrim-OtherRealm", "Pagle"))
    assert.is_false(Logic.sameIdentity("Thal grim-Pagle", "Thalgrim", "Pagle"))
    assert.is_false(Logic.sameIdentity("Dea Two-Pagle", "Dea", "Pagle"))
  end)

  it("keeps saved-name tolerance within the local realm", function()
    assert.is_true(Logic.sameCharacter("Dea One-Pagle", "Dea", "Pagle"))
    assert.is_true(Logic.sameCharacter("Dea One", "Dea One-Pagle", "Pagle"))
    assert.is_false(Logic.sameCharacter("Dea One-OtherRealm", "Dea", "Pagle"))
    assert.is_false(Logic.sameCharacter("Dea One-OtherRealm", "Dea One-Pagle", "Pagle"))
    -- Forever still migrates saved realm suffixes to its region-wide names.
    assert.is_true(Logic.sameCharacter("Dea One-OldRealm", "Dea One"))
    assert.is_true(Logic.sameIdentity("Dea One-OldRealm", "Dea One"))
  end)

  it("refuses realm-qualified identity checks when the local realm is unknown", function()
    for _, unavailable in ipairs({ false, "", "  " }) do
      assert.is_false(Logic.sameIdentity("Thalgrim-Pagle", "Thalgrim", unavailable))
      assert.is_false(Logic.sameCharacter("Thalgrim-Pagle", "Thalgrim", unavailable))
    end
  end)

  it("escapes the pipe so chat and FontStrings cannot be hijacked", function()
    assert.are.equal("||cff00ff00fake||r", Logic.escape("|cff00ff00fake|r"))
    assert.are.equal("||Hitem:1||h[x]||h", Logic.escape("|Hitem:1|h[x]|h"))
    assert.are.equal("", Logic.escape(nil))
  end)

  it("counts code points, not bytes", function()
    assert.are.equal(4, Logic.utf8len("café"))
    assert.are.equal(1, Logic.utf8len("\240\159\167\153"))
  end)

  it("validates titles like the web", function()
    assert.are.same({ ok = true, value = "Tuesday BT run" }, Logic.validateTitle("  Tuesday   BT run "))
    assert.is_false(Logic.validateTitle("").ok)
    assert.is_false(Logic.validateTitle(("x"):rep(41)).ok)
    assert.is_true(Logic.validateTitle(("x"):rep(40)).ok)
  end)

  it("checks items with the same problems the web reports", function()
    local items = {}
    for i = 1, 24 do items[i] = ("Item %d"):format(i) end
    items[6] = "item 1"
    items[8] = ("x"):rep(61)
    items[10] = ""
    items[12] = ("y"):rep(50)
    local r = Logic.checkItems(items)
    local w = F.itemCheck
    assert.are.equal(w.ok, r.ok)
    assert.are.equal(w.filled, r.filled)
    assert.are.equal(#w.problems, #r.problems)
    for i, p in ipairs(w.problems) do
      assert.are.equal(p.index, r.problems[i].index)
      assert.are.equal(p.kind, r.problems[i].kind)
      assert.are.equal(p.clashesWith, r.problems[i].clashesWith)
    end
    assert.are.equal(#w.warnings, #r.warnings)
    assert.are.equal(w.warnings[1].index, r.warnings[1].index)
  end)

  it("accepts a clean set of 24 and rejects 23", function()
    local items = {}
    for i = 1, 24 do items[i] = ("square number %d"):format(i) end
    assert.is_true(Logic.checkItems(items).ok)
    items[24] = nil
    local r = Logic.checkItems(items)
    assert.is_false(r.ok)
    assert.are.equal(23, r.filled)
  end)
end)
