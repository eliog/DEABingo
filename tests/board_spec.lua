-- Board layout under the fake widget API: the stub's GetStringHeight grows
-- with text length, so long phrases force the grow-rows path.
local stub = require("tests.wow_stub")
stub.install()
require("tests.widget_stub").install()

local ns = {}
for _, file in ipairs({ "Core/Logic.lua", "UI/Theme.lua", "UI/Widgets.lua", "UI/Board.lua" }) do
  assert(loadfile(file))("DEABingo", ns)
end
local Board, Logic = ns.Board, ns.Logic

local function longItems()
  local t = {}
  for i = 1, 24 do t[i] = ("Phrase %02d "):format(i) .. ("word "):rep(9) end   -- ~57 chars
  return t
end

local function view(items)
  local board = {}
  for i = 0, 23 do board[#board + 1] = i end
  table.insert(board, 13, -1)
  return { items = items, board = board, called = {}, winning = {}, calls = {}, canCall = false }
end

describe("board layout", function()
  it("applies the row height it grew to fit long phrases, instead of clipping", function()
    local parent = CreateFrame("Frame")
    local b = Board.new(parent)
    b.frame:SetSize(368, 312)      -- the board at the old minimum window size
    b:SetView(view(longItems()))
    b:Layout()
    local cellH = math.floor((312 - Board.GAP * 4) / 5)
    local cell = b.cells[1]
    assert.is_true(cell.__h > cellH, ("cells stayed at %d although the fit needed taller rows"):format(cellH))
    -- every row got the same height, and the frame grew to hold them
    for p = 2, Logic.BOARD_CELLS do assert.are.equal(cell.__h, b.cells[p].__h) end
    assert.is_true(b.frame.__h >= cell.__h * 5 + Board.GAP * 4)
  end)

  it("leaves short phrases at the natural cell height", function()
    local parent = CreateFrame("Frame")
    local b = Board.new(parent)
    b.frame:SetSize(600, 600)
    local items = {}
    for i = 1, 24 do items[i] = "Short " .. i end
    b:SetView(view(items))
    b:Layout()
    local cellH = math.floor((600 - Board.GAP * 4) / 5)
    assert.are.equal(cellH, b.cells[1].__h)
  end)
end)
