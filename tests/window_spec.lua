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
