-- The main window under the fake widget API: structure the layout depends on.
local stub = require("tests.wow_stub")
stub.install()
require("tests.widget_stub").install()

local ns = {}
for _, file in ipairs({ "Core/Logic.lua", "Core/Codec.lua", "Core/View.lua", "Core/Quips.lua", "UI/Theme.lua", "UI/Widgets.lua", "UI/Board.lua", "UI/Window.lua" }) do
  assert(loadfile(file))("DEABingo", ns)
end
local Window = ns.Window

-- every callback answers with nothing: no game, default options, no saved position
local app = setmetatable({}, { __index = function() return function() return nil end end })

-- the frame that clips and scrolls `frame`, if any
local function scroller(frame)
  local f = frame
  while f and f.__kind ~= "ScrollFrame" do f = f:GetParent() end
  return f
end

describe("options view", function()
  local win
  setup(function()
    win = Window.init(app)
    win:SetSize(Window.MIN_W, Window.MIN_H)
    Window.show("options")
  end)

  it("puts its rows in a scrolling frame, since they outgrow the panel at the minimum height", function()
    local rows = win.views.options.rows
    assert.is_true(#rows >= 8, "expected the full option list, got " .. #rows)
    -- 58 px a row under a 44 px heading; the panel is the window less header, tabs and footer (54 + 32 + 44)
    local content, panel = 44 + #rows * 58, Window.MIN_H - 130
    assert.is_true(content > panel, "premise gone: the options fit without scrolling")
    local scroll = scroller(rows[1])
    assert.is_truthy(scroll, ("option rows sit in a plain frame and overflow the panel by %d px at the minimum height"):format(content - panel))
    assert.is_truthy(scroll.__scripts and scroll.__scripts.OnMouseWheel, "no wheel scrolling on the options")
    assert.are.equal(#rows * 58, scroll.child:GetHeight())
  end)

  it("scrolls with the wheel and stops at both ends", function()
    local scroll = scroller(win.views.options.rows[1])
    scroll:SetHeight(200)
    scroll.__scripts.OnMouseWheel(scroll, -1)
    assert.is_true(scroll:GetVerticalScroll() > 0, "wheel down did not scroll")
    for _ = 1, 20 do scroll.__scripts.OnMouseWheel(scroll, -1) end
    assert.are.equal(scroll.child:GetHeight() - 200, scroll:GetVerticalScroll())
    for _ = 1, 20 do scroll.__scripts.OnMouseWheel(scroll, 1) end
    assert.are.equal(0, scroll:GetVerticalScroll())
  end)

  it("re-widens its rows when the scroll frame changes size", function()
    local scroll = scroller(win.views.options.rows[1])
    scroll.__scripts.OnSizeChanged(scroll, 700, 300)
    assert.are.equal(680, scroll.child:GetWidth())
    for _, row in ipairs(win.views.options.rows) do assert.are.equal(680, row:GetWidth()) end
  end)

  it("keeps its rows while the window resizes and its own width reads as zero", function()
    -- The client has not laid the list out yet when the window's OnSizeChanged
    -- fires, so GetWidth() is 0 then; a fill at that moment gave every row a
    -- negative width and the hints and buttons fell outside the clip.
    local scroll = scroller(win.views.options.rows[1])
    scroll.__w = 0
    win.__scripts.OnSizeChanged(win)
    for _, row in ipairs(win.views.options.rows) do
      assert.is_true(row:GetWidth() > 0, "a row lost its width during the resize")
    end
  end)

  it("keeps a row per option with its controls after a refresh", function()
    Window.refresh()
    local byKey = {}
    for _, row in ipairs(win.views.options.rows) do byKey[row.def.key] = row end
    assert.are.equal(2, #byKey.theme.buttons)
    assert.are.equal("Light", byKey.theme.buttons[1].label:GetText())
    assert.are.equal(2, #byKey.sounds.buttons)
    assert.is_truthy(byKey.clearHistory.action)
    assert.are.equal(0, #byKey.clearHistory.buttons)
  end)
end)

describe("version on the options tab", function()
  local win
  setup(function()
    win = Window.init(app)
    Window.show("options")
  end)
  before_each(function() app.version = nil; app.newerVersion = nil end)
  teardown(function() app.version = nil; app.newerVersion = nil end)

  it("shows the installed version, dim", function()
    app.version = function() return "v0.1.1" end
    Window.refresh()
    assert.are.equal("v0.1.1", win.views.options.version:GetText())
  end)

  it("adds the newer release once one was heard this session", function()
    app.version = function() return "v0.1.1" end
    app.newerVersion = function() return "v0.1.2" end
    Window.refresh()
    assert.are.equal("v0.1.1  ·  v0.1.2 available", win.views.options.version:GetText())
  end)

  it("shows nothing when the host gives no version", function()
    Window.refresh()
    assert.are.equal("", win.views.options.version:GetText())
  end)
end)

describe("footer one-liners", function()
  local win, Quips
  setup(function()
    win = Window.init(app)
    Quips = ns.Quips
    Window.show("options")
  end)

  local function isQuip(text)
    for _, q in ipairs(Quips.LIST) do if q == text then return true end end
    return false
  end

  it("shows one on the Options tab", function()
    assert.is_true(isQuip(win.footer.text:GetText()), "footer shows: " .. tostring(win.footer.text:GetText()))
  end)

  it("changes to another after the interval, and not before", function()
    local first = win.footer.text:GetText()
    win.footer.__scripts.OnUpdate(win.footer, Quips.EVERY - 1)
    assert.are.equal(first, win.footer.text:GetText())
    win.footer.__scripts.OnUpdate(win.footer, 1)
    local second = win.footer.text:GetText()
    assert.is_true(isQuip(second))
    assert.are_not.equal(first, second)
  end)

  it("leaves the footer alone once a view has its own text", function()
    win.footer:Quip(false)
    win.footer.text:SetText("Give the game a title.")
    win.footer.__scripts.OnUpdate(win.footer, Quips.EVERY + 1)
    assert.are.equal("Give the game a title.", win.footer.text:GetText())
  end)
end)

describe("standings rows", function()
  it("give the name its own line, with the meter and flag beneath", function()
    local win = Window.init(app)
    local row = win.views.game.standings.list.rows[1]
    if not row then
      win.views.game.standings.list:Fill({ {} }, function() end)
      row = win.views.game.standings.list.rows[1]
    end
    assert.are.equal(38, row:GetHeight())
    -- the name anchors to the row's top and right edge, not to the flag
    local nameRight
    for _, pt in ipairs(row.name.__points) do if pt[1] == "RIGHT" then nameRight = pt end end
    assert.is_truthy(nameRight, "name has no RIGHT anchor")
    assert.are.equal(-56, nameRight.x)
    -- the meter sits on the bottom line and the flag follows it
    local meterPt = row.meter.__points[1]
    assert.are.equal("BOTTOMLEFT", meterPt[1])
    local flagPt = row.flag.__points[1]
    assert.are.equal(row.meter, flagPt.rel)
  end)
end)

describe("hover card on a standings row", function()
  local win, g, Logic
  setup(function()
    win = Window.init(app)
    g = win.views.game
    Logic = ns.Logic
  end)

  local function board()
    local b = {}
    for p = 1, 25 do b[p] = p - 1 end
    b[Logic.FREE_CELL] = Logic.FREE
    return b
  end

  it("shows the player's grid as dots, with the called squares lit", function()
    local b = board()
    local called = { [0] = true, [1] = true }
    win.currentView = { called = called, isHost = false, owner = "Host-Pagle" }
    local row = { player = { name = "Dorn-Pagle", shortName = "Dorn", bestLine = 3, board = b, winning = Logic.winningCells(b, called) } }
    g:Peek(row)
    assert.is_true(g.peek:IsShown())
    assert.are.equal("Dorn", g.peek.name:GetText())
    assert.are.equal("Best line 3 of 5", g.peek.info:GetText())
    assert.are.equal(25, #g.peek.grid.dots)
    assert.are.equal("", g.peek.hints:GetText())
  end)

  it("offers the host their right-click hints, and nothing for themselves", function()
    local b = board()
    win.currentView = { called = {}, isHost = true, owner = "Host-Pagle" }
    g:Peek({ player = { name = "Dorn-Pagle", shortName = "Dorn", bestLine = 1, canCall = false, board = b, winning = {} } })
    assert.matches("Right%-click to let them call", g.peek.hints:GetText())
    g:Peek({ player = { name = "Host-Pagle", shortName = "Host", bestLine = 1, canCall = true, board = b, winning = {} } })
    assert.are.equal("", g.peek.hints:GetText())
    assert.matches("Can call squares", g.peek.info:GetText())
  end)

  it("hides when the row has no board to show", function()
    win.currentView = { called = {} }
    g:Peek({ player = { name = "Ghost-Pagle", shortName = "Ghost", bestLine = 0 } })
    assert.is_false(g.peek:IsShown())
  end)
end)

describe("clicking a square", function()
  local win, calls
  setup(function() win = Window.init(app) end)
  before_each(function()
    calls = {}
    app.call = function(idx, undo) calls[#calls + 1] = { idx = idx, undo = undo } end
  end)
  teardown(function() app.call = nil end)

  it("calls or undoes at once for a caller, with no sheet", function()
    win.currentView = { canCall = true, state = "open", called = { [4] = true }, calls = {} }
    win.views.game.board.onCellClick(3, "LeftButton", false)
    win.views.game.board.onCellClick(4, "LeftButton", false)
    assert.are.same({ { idx = 3, undo = false }, { idx = 4, undo = true } }, calls)
    assert.is_false(win.sheetFrame:IsShown())
  end)

  it("opens the read-only sheet for anyone else", function()
    win.currentView = { canCall = false, state = "open", called = {}, calls = {}, items = { "First", "Second" } }
    win.views.game.board.onCellClick(1, "LeftButton", false)
    assert.are.equal(0, #calls)
    assert.is_true(win.sheetFrame:IsShown())
    assert.are.equal("Second", win.sheetFrame.card.phrase:GetText())
    assert.are.equal("SQUARE", win.sheetFrame.card.eyebrow:GetText())
    assert.is_nil(win.sheetFrame.card.confirm)
    win.sheetFrame:Hide()
  end)
end)

describe("combat", function()
  local win
  setup(function() win = Window.init(app) end)
  after_each(function() Window.setCombat(false) end)

  it("leaves the header clear of the scrim, so close and drag still work", function()
    Window.setCombat(true)
    local sc = win.combatScrim
    assert.is_true(sc:IsShown())
    local top
    for _, pt in ipairs(sc.__points) do if pt[1] == "TOPLEFT" then top = pt end end
    assert.is_truthy(top, "scrim has no TOPLEFT anchor")
    assert.are.equal(win.header, top.rel)
    assert.are.equal("BOTTOMLEFT", top.relPoint)
  end)

  it("takes the keyboard back from a focused text box", function()
    local box = win.views.game.log.filter
    box:SetFocus()
    assert.is_true(box:HasFocus())
    Window.setCombat(true)
    assert.is_false(box:HasFocus())
    assert.is_nil(GetCurrentKeyBoardFocus())
  end)

  it("leaves a box outside the window alone", function()
    local other = CreateFrame("EditBox", nil, UIParent)
    other:SetFocus()
    Window.setCombat(true)
    assert.is_true(other:HasFocus())
    other:ClearFocus()
  end)

  it("keeps the scrim through a view change, until combat ends", function()
    app.lobby = function() return {} end     -- the lobby view lists open games
    Window.setCombat(true)
    Window.show("options")
    assert.is_true(win.combatScrim:IsShown(), "showing a view dropped the scrim")
    Window.show("lobby")
    assert.is_true(win.combatScrim:IsShown())
    Window.setCombat(false)
    assert.is_false(win.combatScrim:IsShown())
    Window.show("options")
    assert.is_false(win.combatScrim:IsShown(), "a view change brought the scrim back")
    app.lobby = nil
  end)
end)

-- A /reload mid-fight builds the window after PLAYER_REGEN_DISABLED has
-- passed; Init asks UnitAffectingCombat once the window exists and calls
-- setCombat with the answer. That query lives in Init and is covered by the
-- smoke; this is the window's side: combat set before the first show.
describe("a window built in combat", function()
  it("comes up dimmed, with no overlay, and clears when combat ends", function()
    local w = Window.init(app)
    Window.setCombat(true)
    Window.show("options")
    assert.is_true(w.combatScrim:IsShown())
    assert.is_false(w.sheetFrame:IsShown())
    assert.is_false(w.confirmFrame:IsShown())
    assert.is_nil(GetCurrentKeyBoardFocus())
    Window.setCombat(false)
    assert.is_false(w.combatScrim:IsShown())
  end)
end)

describe("confirmation card", function()
  local win, cf
  setup(function() win = Window.init(app); cf = win.confirmFrame end)
  local function open()
    Window.confirm("T", "body", "Do it", function() end)
    assert.is_true(cf:IsShown())
    assert.is_function(cf.onConfirm)
  end

  it("goes with the window when it hides, and forgets its callback", function()
    open()
    win.__scripts.OnHide(win)
    assert.is_false(cf:IsShown())
    assert.is_nil(cf.onConfirm)
  end)

  it("closes when combat starts, along with the sheet", function()
    open()
    win.sheetFrame:Show()
    Window.setCombat(true)
    assert.is_false(cf:IsShown())
    assert.is_nil(cf.onConfirm)
    assert.is_false(win.sheetFrame:IsShown())
    Window.setCombat(false)
  end)

  it("does nothing when its confirm button is clicked after the window hid", function()
    local fired = 0
    Window.confirm("T", "body", "Do it", function() fired = fired + 1 end)
    win.__scripts.OnHide(win)
    assert.is_nil(cf.onConfirm)
    cf.card.confirm.__scripts.OnClick(cf.card.confirm, "LeftButton")
    assert.are.equal(0, fired, "a dismissed confirmation fired its action")
    assert.is_false(cf:IsShown())
    -- a fresh confirmation after that still works
    Window.confirm("T", "body", "Do it", function() fired = fired + 1 end)
    cf.card.confirm.__scripts.OnClick(cf.card.confirm, "LeftButton")
    assert.are.equal(1, fired)
    assert.is_false(cf:IsShown())
  end)
end)

describe("the game view at a narrow width", function()
  local win, g
  setup(function() win = Window.init(app); g = win.views.game end)
  teardown(function() win.view = nil; Window.applyBounds() end)

  local function boardRight()
    for _, pt in ipairs(g.boardHolder.__points) do if pt[1] == "BOTTOMRIGHT" then return pt.x end end
  end

  it("hides the rail below the full minimum and gives the board the width", function()
    g:LayoutRail(Window.RAIL_HIDE_W)
    assert.is_true(g.rail:IsShown())
    local full = boardRight()
    g:LayoutRail(Window.RAIL_HIDE_W - 1)
    assert.is_false(g.rail:IsShown())
    assert.is_false(g.peek:IsShown())
    assert.is_true(boardRight() > full, "the board did not take the rail's width")
    g:LayoutRail(Window.RAIL_HIDE_W)
    assert.is_true(g.rail:IsShown())
    assert.are.equal(full, boardRight())
  end)

  it("follows the window's own resize event", function()
    g:Show()
    win.__scripts.OnSizeChanged(win, Window.RAIL_HIDE_W - 10)
    assert.is_false(g.rail:IsShown())
    win.__scripts.OnSizeChanged(win, Window.RAIL_HIDE_W + 10)
    assert.is_true(g.rail:IsShown())
  end)

  it("lowers the minimum size on the game tab only, and grows again on leaving it", function()
    win.view = "game"
    win:SetSize(Window.BOARD_MIN_W + 20, Window.BOARD_MIN_H + 10)
    Window.applyBounds()
    assert.are.equal(Window.BOARD_MIN_W, win.__minW)
    assert.are.equal(Window.BOARD_MIN_H, win.__minH)
    assert.are.equal(Window.BOARD_MIN_W + 20, win:GetWidth())
    assert.are.equal(Window.BOARD_MIN_H + 10, win:GetHeight())
    win.view = "options"
    Window.applyBounds()
    assert.are.equal(Window.MIN_W, win.__minW)
    assert.are.equal(Window.MIN_H, win.__minH)
    assert.are.equal(Window.MIN_W, win:GetWidth(), "a narrow window did not widen for the Options tab")
    assert.are.equal(Window.MIN_H, win:GetHeight(), "a short window did not grow for the Options tab")
  end)

  it("keeps the board-only minimum smaller than the full one in both directions", function()
    assert.is_true(Window.BOARD_MIN_W < Window.MIN_W and Window.BOARD_MIN_H < Window.MIN_H)
  end)
end)
